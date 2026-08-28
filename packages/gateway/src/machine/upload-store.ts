import { createHash, randomUUID } from "node:crypto";
import { constants, createReadStream, type ReadStream } from "node:fs";
import {
  chmod, copyFile, link, lstat, mkdir, open, readFile, readdir, realpath,
  rename, rm, stat, statfs,
} from "node:fs/promises";
import { basename, dirname, extname, join } from "node:path";
import type { ImageContent } from "@earendil-works/pi-ai";
import { GatewayError } from "../errors.js";
import { atomicWriteJson, readJson } from "../util/json.js";
import { isGatewayTimestamp } from "../util/timestamp.js";
import type { PromptAttachmentState } from "../protocol/types.js";

const UPLOAD_METADATA_MAX_BYTES = 64 * 1_024;
const DEFAULT_MAXIMUM_STAGING_ENTRIES = 1_024;
const DEFAULT_MAXIMUM_RETAINED_ENTRIES = 16_384;
const DEFAULT_MINIMUM_FREE_BYTES = 1_024 * 1_048_576;
const DIGEST_PATTERN = /^[0-9a-f]{64}$/;

interface UploadMetadataV1 {
  version: 1;
  id: string;
  name: string;
  mimeType: string;
  size: number;
  path: string;
  createdAt: string;
  sessionId?: string;
}

interface UploadMetadataV2 extends Omit<UploadMetadataV1, "version"> {
  version: 2;
  digest: string;
}

type UploadMetadata = UploadMetadataV1 | UploadMetadataV2;

interface StagedUpload {
  id: string;
  folder: string;
  path: string;
  reservedBytes: number;
}

export interface UploadImportLease {
  path: string;
  release(): Promise<void>;
}

export interface UploadLease {
  name: string;
  mimeType: string;
  size: number;
  stream: ReadStream;
  release(): Promise<void>;
}

interface UploadStoreOptions {
  maximumStagingEntries?: number;
  maximumRetainedEntries?: number;
  maximumRetainedLogicalBytes?: number;
  maximumStagingBytes?: number;
  minimumFreeBytes?: number;
  maximumUnclaimedAgeMs?: number;
  now?: () => number;
  uuid?: () => string;
  availableDiskBytes?: () => Promise<number>;
}

export interface UploadCapacityStatus {
  entryCount: number;
  logicalBytes: number;
  stagingEntryCount: number;
  maximumStagingEntries: number;
  stagingLogicalBytes: number;
  maximumStagingBytes: number;
  stagingAvailableBytes: number;
  unclaimedCount: number;
  unclaimedBytes: number;
  claimedCount: number;
  claimedBytes: number;
  maximumRetainedEntries: number;
  maximumRetainedLogicalBytes: number;
  retainedAvailableBytes: number;
  stagedCount: number;
  stagedBytes: number;
  activeImportLeaseCount: number;
  activeImportLeaseBytes: number;
  objectCount: number;
  objectBytes: number;
  deduplicatedBytes: number;
  orphanObjectCount: number;
  orphanObjectBytes: number;
  unavailableObjectCount: number;
  unavailableObjectBytes: number;
  diskAvailableBytes: number;
  minimumFreeBytes: number;
  storagePressure: "normal" | "low" | "exhausted";
  activeBodyAdmissions: number;
  maximumConcurrentBodies: number;
  pendingSessionCleanupCount: number;
  observedAt: string;
}

function safeName(input: string): string {
  const name = basename(input).replace(/[\u0000-\u001f\u007f]/g, "").slice(0, 160);
  return name || "attachment";
}

function xml(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
}

function isConfirmedUploadCorruption(error: unknown): boolean {
  if (error instanceof GatewayError) return error.code === "conflict" || error.code === "not_found";
  const code = (error as NodeJS.ErrnoException)?.code;
  return code === "ENOENT" || code === "ENOTDIR" || code === "ELOOP";
}

function isUploadMetadata(value: unknown, expectedID: string, maximumBytes: number): value is UploadMetadata {
  if (typeof value !== "object" || value === null) return false;
  const metadata = value as Record<string, unknown>;
  const version = metadata.version;
  const expectedKeys = [
    "version", "id", "name", "mimeType", "size", "path", "createdAt",
    ...(version === 2 ? ["digest"] : []),
    ...(metadata.sessionId === undefined ? [] : ["sessionId"]),
  ];
  const keys = Object.keys(metadata);
  return (version === 1 || version === 2)
    && keys.length === expectedKeys.length && keys.every((key) => expectedKeys.includes(key))
    && metadata.id === expectedID
    && typeof metadata.name === "string" && metadata.name === safeName(metadata.name)
    && typeof metadata.mimeType === "string" && metadata.mimeType.length > 0 && metadata.mimeType.length <= 200
    && !/[\u0000-\u001f\u007f]/.test(metadata.mimeType)
    && typeof metadata.path === "string" && metadata.path.length > 0 && metadata.path.length <= 8_192
    && typeof metadata.createdAt === "string" && isGatewayTimestamp(metadata.createdAt)
    && new Date(metadata.createdAt).toISOString() === metadata.createdAt
    && Number.isSafeInteger(metadata.size) && (metadata.size as number) > 0
    && (metadata.size as number) <= maximumBytes
    && (metadata.sessionId === undefined || (typeof metadata.sessionId === "string"
      && metadata.sessionId.length > 0 && metadata.sessionId.length <= 200))
    && (version !== 2 || (typeof metadata.digest === "string" && DIGEST_PATTERN.test(metadata.digest)));
}

export class UploadStore {
  private readonly directory: string;
  private readonly bodyDirectory: string;
  private readonly importDirectory: string;
  private readonly objectDirectory: string;
  private readonly maximumStagingEntries: number;
  private readonly maximumRetainedEntries: number;
  private readonly maximumRetainedLogicalBytes: number;
  private readonly maximumStagingBytes: number;
  private readonly minimumFreeBytes: number;
  private readonly maximumUnclaimedAgeMs: number;
  private readonly now: () => number;
  private readonly uuid: () => string;
  private readonly availableDiskBytes: () => Promise<number>;
  private readonly pendingSessionRemovals = new Set<string>();
  private readonly maximumConcurrentBodies: number;
  private activeBodyAdmissions = 0;
  private readonly stagedUploads = new Map<string, number>();
  private readonly activeImportLeases = new Map<string, number>();
  /** Rebuildable physical attachment index; canonical session ownership remains JSONL/catalog authority. */
  private readonly logicalIndex = new Map<string, UploadMetadataV2>();
  private readonly unclaimedIndex = new Set<string>();
  private indexedUnclaimedBytes = 0;
  private indexedClaimedCount = 0;
  private indexedClaimedBytes = 0;
  private readonly pendingOrphanObjects = new Map<string, number>();
  private readonly verifiedObjectDigests = new Set<string>();
  private readonly unavailableObjectDigests = new Map<string, number>();
  private integrityAuditCursor = 0;
  private inventoryInitialized = false;
  private mutationTail = Promise.resolve();

  constructor(
    tronHome: string,
    private readonly maximumBytes: number,
    options: UploadStoreOptions = {},
  ) {
    this.directory = join(tronHome, "gateway", "uploads");
    this.bodyDirectory = join(tronHome, "gateway", "upload-bodies");
    this.importDirectory = join(tronHome, "gateway", "upload-imports");
    this.objectDirectory = join(tronHome, "gateway", "upload-objects");
    // Staging is bounded independently from canonical session ownership. Old
    // conversations can consume retained storage but can never starve a new
    // draft while the filesystem still has its configured safety floor.
    this.maximumStagingEntries = options.maximumStagingEntries ?? DEFAULT_MAXIMUM_STAGING_ENTRIES;
    this.maximumRetainedEntries = options.maximumRetainedEntries ?? DEFAULT_MAXIMUM_RETAINED_ENTRIES;
    this.maximumRetainedLogicalBytes = options.maximumRetainedLogicalBytes
      ?? maximumBytes * this.maximumRetainedEntries;
    this.maximumStagingBytes = options.maximumStagingBytes ?? maximumBytes * 8;
    this.minimumFreeBytes = options.minimumFreeBytes ?? DEFAULT_MINIMUM_FREE_BYTES;
    this.maximumUnclaimedAgeMs = options.maximumUnclaimedAgeMs ?? 24 * 60 * 60_000;
    this.maximumConcurrentBodies = Math.max(1, Math.floor(this.maximumStagingBytes / maximumBytes / 2));
    this.now = options.now ?? Date.now;
    this.uuid = options.uuid ?? randomUUID;
    this.availableDiskBytes = options.availableDiskBytes ?? (async () => {
      const values = await statfs(dirname(this.directory));
      return values.bavail * values.bsize;
    });
    if (![maximumBytes, this.maximumStagingEntries, this.maximumRetainedEntries,
      this.maximumRetainedLogicalBytes, this.maximumStagingBytes, this.minimumFreeBytes,
      this.maximumUnclaimedAgeMs].every(Number.isSafeInteger)
      || maximumBytes < 1 || this.maximumStagingEntries < 1 || this.maximumRetainedEntries < 1
      || this.maximumRetainedLogicalBytes < maximumBytes
      || this.maximumStagingBytes < maximumBytes || this.minimumFreeBytes < 0
      || this.maximumUnclaimedAgeMs < 1) {
      throw new Error("Upload store bounds are invalid");
    }
  }

  beginBodyAdmission(): () => void {
    if (this.activeBodyAdmissions >= this.maximumConcurrentBodies) {
      throw new GatewayError("busy", "Concurrent upload bodies reached their bounded capacity", true);
    }
    this.activeBodyAdmissions += 1;
    let released = false;
    return () => {
      if (released) return;
      released = true;
      this.activeBodyAdmissions = Math.max(0, this.activeBodyAdmissions - 1);
    };
  }

  async withBodyAdmission<T>(operation: () => Promise<T>): Promise<T> {
    const release = this.beginBodyAdmission();
    try {
      return await operation();
    } finally {
      release();
    }
  }

  async save(nameInput: string, mimeType: string, body: Buffer): Promise<UploadMetadata> {
    return this.saveStream(nameInput, mimeType, [body], body.length);
  }

  async saveStream(
    nameInput: string,
    mimeTypeInput: string,
    body: AsyncIterable<Uint8Array> | Iterable<Uint8Array>,
    declaredBytes?: number,
  ): Promise<UploadMetadata> {
    if (declaredBytes !== undefined
      && (!Number.isSafeInteger(declaredBytes) || declaredBytes < 0 || declaredBytes > this.maximumBytes)) {
      throw new GatewayError("invalid_request", "Request body is too large");
    }
    const staged = await this.reserveStagedUpload(declaredBytes ?? this.maximumBytes);
    let committed = false;
    let size = 0;
    const digest = createHash("sha256");
    try {
      const handle = await open(staged.path, "wx", 0o600);
      try {
        for await (const value of body) {
          const chunk = Buffer.isBuffer(value) ? value : Buffer.from(value);
          size += chunk.length;
          if (size > this.maximumBytes || (declaredBytes !== undefined && size > declaredBytes)) {
            throw new GatewayError("invalid_request", "Request body is too large");
          }
          digest.update(chunk);
          let offset = 0;
          while (offset < chunk.length) {
            const { bytesWritten } = await handle.write(chunk, offset);
            if (bytesWritten < 1) throw new GatewayError("internal", "Upload body could not be written");
            offset += bytesWritten;
          }
        }
        await handle.sync();
      } finally {
        await handle.close();
      }
      if (size === 0 || (declaredBytes !== undefined && size !== declaredBytes)) {
        throw new GatewayError("invalid_request", declaredBytes === undefined
          ? `Upload must contain 1 through ${this.maximumBytes} bytes`
          : "Request body size did not match Content-Length");
      }

      const metadata = await this.commitStagedUpload(
        staged, nameInput, mimeTypeInput, size, digest.digest("hex"),
      );
      committed = true;
      return metadata;
    } finally {
      if (!committed) await this.releaseStagedUpload(staged);
    }
  }

  private async reserveStagedUpload(reservedBytes: number): Promise<StagedUpload> {
    return this.serialize(async () => {
      await this.refreshIndexedExpiry();
      const uploadDirectory = await this.ensureUploadDirectory();
      const bodyDirectory = await this.ensureBodyDirectory();
      await this.cleanupStagedUploads(bodyDirectory);
      const stagedBytes = [...this.stagedUploads.values()].reduce((total, size) => total + size, 0);
      const stagingLogicalBytes = this.indexedUnclaimedBytes + stagedBytes;
      const stagingEntryCount = this.unclaimedIndex.size + this.stagedUploads.size;
      const diskAvailableBytes = await this.readAvailableDiskBytes();
      const stagingEntriesFull = stagingEntryCount >= this.maximumStagingEntries;
      const stagingBytesFull = reservedBytes > this.maximumStagingBytes - stagingLogicalBytes;
      // Reservations account for bodies that have not reached disk yet. This is
      // deliberately conservative; already-written staged bytes may be counted
      // twice, but the configured filesystem floor can never be crossed.
      const diskFloorReached = reservedBytes + this.outstandingDiskReservations()
        > Math.max(0, diskAvailableBytes - this.minimumFreeBytes);
      if (stagingEntriesFull || stagingBytesFull || diskFloorReached) {
        const reason = stagingEntriesFull ? "staging_entries"
          : stagingBytesFull ? "staging_bytes"
            : "disk";
        throw new GatewayError(
          "busy",
          reason === "disk"
            ? "Attachment storage is preserving the Mac free-space floor"
            : "Attachment staging capacity is full; remove pending attachments or wait for cleanup",
          true,
          {
            reason,
            stagingEntryCount,
            maximumStagingEntries: this.maximumStagingEntries,
            retainedEntryCount: this.indexedClaimedCount,
            maximumRetainedEntries: this.maximumRetainedEntries,
            stagingLogicalBytes,
            maximumStagingBytes: this.maximumStagingBytes,
            stagingAvailableBytes: Math.max(0, this.maximumStagingBytes - stagingLogicalBytes),
            diskAvailableBytes,
            minimumFreeBytes: this.minimumFreeBytes,
          },
        );
      }

      for (let attempt = 0; attempt < 4; attempt += 1) {
        const id = this.uuid();
        this.validateID(id);
        try {
          await stat(join(uploadDirectory, id));
          continue;
        } catch (error) {
          if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
        }
        const folder = join(bodyDirectory, id);
        try {
          await mkdir(folder, { recursive: false, mode: 0o700 });
          const staged = { id, folder, path: join(folder, "content"), reservedBytes };
          this.stagedUploads.set(id, reservedBytes);
          return staged;
        } catch (error) {
          if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
        }
      }
      throw new GatewayError("busy", "Could not allocate an upload identity", true);
    });
  }

  private async commitStagedUpload(
    staged: StagedUpload,
    nameInput: string,
    mimeTypeInput: string,
    size: number,
    digest: string,
  ): Promise<UploadMetadata> {
    return this.serialize(async () => {
      if (this.stagedUploads.get(staged.id) !== staged.reservedBytes || size > staged.reservedBytes) {
        throw new GatewayError("conflict", "Upload staging reservation was lost");
      }
      const stagedInfo = await stat(staged.path);
      if (!stagedInfo.isFile() || stagedInfo.size !== size) {
        throw new GatewayError("conflict", "Upload body changed before it could be committed");
      }

      const name = safeName(nameInput);
      const mimeType = mimeTypeInput.replace(/[\u0000-\u001f\u007f]/g, "").slice(0, 200)
        || "application/octet-stream";
      const uploadDirectory = await this.ensureUploadDirectory();
      const folder = join(uploadDirectory, staged.id);
      await mkdir(folder, { recursive: false, mode: 0o700 });
      try {
        const objectPath = await this.adoptStagedObject(staged.path, digest, size);
        const path = join(folder, `content${extname(name).slice(0, 20)}`);
        await link(objectPath, path);
        const actual = await realpath(path);
        const ownedDirectory = await realpath(folder);
        const info = await stat(actual);
        const objectInfo = await stat(objectPath);
        if (!actual.startsWith(`${ownedDirectory}/`) || !info.isFile() || info.size !== size
          || info.dev !== objectInfo.dev || info.ino !== objectInfo.ino) {
          throw new GatewayError("conflict", "Upload content escaped its owned object or changed size");
        }
        const metadata: UploadMetadataV2 = {
          version: 2,
          id: staged.id,
          name,
          mimeType,
          size,
          path: actual,
          digest,
          createdAt: new Date(this.now()).toISOString(),
        };
        await this.durableWriteMetadata(join(folder, "metadata.json"), metadata);
        await this.syncDirectory(uploadDirectory);
        await this.syncDirectory(dirname(uploadDirectory));
        this.installIndexedMetadata(metadata);
        this.verifiedObjectDigests.add(digest);
        this.inventoryInitialized = true;
        this.stagedUploads.delete(staged.id);
        // Publication is already durable. Stale body-directory cleanup is
        // recoverable maintenance and cannot turn success into a ghost index.
        await rm(staged.folder, { recursive: true, force: true }).catch(() => {});
        return metadata;
      } catch (error) {
        await rm(folder, { recursive: true, force: true });
        await this.cleanupReleasedObject(digest, size);
        throw error;
      }
    });
  }

  private async releaseStagedUpload(staged: StagedUpload): Promise<void> {
    await this.serialize(async () => {
      this.stagedUploads.delete(staged.id);
      await rm(staged.folder, { recursive: true, force: true });
    });
  }

  private ensureBodyDirectory(): Promise<string> {
    return this.ensureOwnedDirectory(this.bodyDirectory, "Upload staging directory is not owned by the Gateway");
  }

  private ensureImportDirectory(): Promise<string> {
    return this.ensureOwnedDirectory(
      this.importDirectory,
      "Session import staging directory is not owned by the Gateway",
    );
  }

  private ensureUploadDirectory(): Promise<string> {
    return this.ensureOwnedDirectory(this.directory, "Upload directory is not owned by the Gateway");
  }

  private ensureObjectDirectory(): Promise<string> {
    return this.ensureOwnedDirectory(
      this.objectDirectory,
      "Attachment object directory is not owned by the Gateway",
    );
  }

  private async objectPath(digest: string): Promise<string> {
    if (!DIGEST_PATTERN.test(digest)) throw new GatewayError("conflict", "Attachment digest is invalid");
    const root = await this.ensureObjectDirectory();
    const shard = await this.ensureOwnedDirectory(
      join(root, digest.slice(0, 2)),
      "Attachment object shard is not owned by the Gateway",
    );
    return join(shard, digest);
  }

  private async hashFile(path: string): Promise<{ digest: string; size: number }> {
    const hash = createHash("sha256");
    let size = 0;
    for await (const chunk of createReadStream(path)) {
      const value = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      size += value.length;
      if (size > this.maximumBytes) {
        throw new GatewayError("conflict", "Attachment object exceeds its bounded size");
      }
      hash.update(value);
    }
    return { digest: hash.digest("hex"), size };
  }

  private async syncPath(path: string): Promise<void> {
    const handle = await open(path, "r");
    try { await handle.sync(); }
    finally { await handle.close(); }
  }

  private async syncDirectory(path: string): Promise<void> {
    const handle = await open(path, "r");
    try { await handle.sync(); }
    finally { await handle.close(); }
  }

  private async durableWriteMetadata(path: string, value: UploadMetadataV2): Promise<void> {
    await atomicWriteJson(path, value);
    await this.syncPath(path);
    await this.syncDirectory(dirname(path));
  }

  private async adoptStagedObject(stagedPath: string, digest: string, size: number): Promise<string> {
    const target = await this.objectPath(digest);
    try {
      const existing = await lstat(target);
      if (!existing.isFile() || existing.isSymbolicLink() || existing.size !== size) {
        throw new GatewayError("conflict", "Matching attachment object is invalid");
      }
      const verified = await this.hashFile(target);
      if (verified.digest !== digest || verified.size !== size) {
        throw new GatewayError("conflict", "Matching attachment object failed integrity verification");
      }
      await rm(stagedPath, { force: true });
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      await rename(stagedPath, target);
    }
    await chmod(target, 0o400);
    await this.syncPath(target);
    await this.syncDirectory(dirname(target));
    await this.syncDirectory(dirname(dirname(target)));
    await this.syncDirectory(dirname(dirname(dirname(target))));
    return realpath(target);
  }

  private async ensureOwnedDirectory(path: string, message: string): Promise<string> {
    await mkdir(path, { recursive: true, mode: 0o700 });
    const info = await lstat(path);
    const actual = await realpath(path);
    const expected = join(await realpath(dirname(path)), basename(path));
    if (!info.isDirectory() || info.isSymbolicLink() || actual !== expected) {
      throw new GatewayError("conflict", message);
    }
    return actual;
  }

  private async cleanupStagedUploads(bodyDirectory: string): Promise<void> {
    const entries = await readdir(bodyDirectory, { withFileTypes: true });
    await Promise.all(entries.map(async (entry) => {
      if (!this.stagedUploads.has(entry.name)) {
        await rm(join(bodyDirectory, entry.name), { recursive: true, force: true });
      }
    }));
  }

  private async cleanupImportDirectory(): Promise<void> {
    const root = await this.ensureImportDirectory();
    const entries = await readdir(root, { withFileTypes: true });
    for (const entry of entries) {
      const path = join(root, entry.name);
      if (!this.activeImportLeases.has(path)) {
        await rm(path, { recursive: true, force: true });
      }
    }
  }

  private outstandingDiskReservations(): number {
    return [...this.stagedUploads.values(), ...this.activeImportLeases.values()]
      .reduce((total, size) => total + size, 0);
  }

  private async cleanupObjectDirectory(referencedDigests: ReadonlySet<string>): Promise<void> {
    const root = await this.ensureObjectDirectory();
    const shards = await readdir(root, { withFileTypes: true });
    for (const shard of shards) {
      const shardPath = join(root, shard.name);
      if (!shard.isDirectory() || shard.isSymbolicLink() || !/^[0-9a-f]{2}$/.test(shard.name)) {
        await rm(shardPath, { recursive: true, force: true });
        continue;
      }
      const entries = await readdir(shardPath, { withFileTypes: true });
      for (const entry of entries) {
        const path = join(shardPath, entry.name);
        if (!entry.isFile() || entry.isSymbolicLink() || !DIGEST_PATTERN.test(entry.name)
          || entry.name.slice(0, 2) !== shard.name || !referencedDigests.has(entry.name)) {
          await rm(path, { recursive: true, force: true });
        }
      }
      if ((await readdir(shardPath)).length === 0) await rm(shardPath, { recursive: true, force: true });
    }
  }

  private async removeObjectIfUnreferenced(digest: string): Promise<void> {
    const path = await this.objectPath(digest);
    try {
      const info = await stat(path);
      if (info.isFile() && info.nlink <= 1) {
        await rm(path, { force: true });
        this.verifiedObjectDigests.delete(digest);
        this.unavailableObjectDigests.delete(digest);
        const shard = dirname(path);
        if ((await readdir(shard)).length === 0) await rm(shard, { recursive: true, force: true });
      }
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
  }

  private async cleanupReleasedObject(digest: string, size: number): Promise<void> {
    try {
      await this.removeObjectIfUnreferenced(digest);
      this.pendingOrphanObjects.delete(digest);
    } catch {
      this.pendingOrphanObjects.set(digest, size);
    }
  }

  private async retryPendingObjectCleanup(): Promise<void> {
    for (const [digest, size] of [...this.pendingOrphanObjects]) {
      await this.cleanupReleasedObject(digest, size);
    }
  }

  private async auditNextObject(inventory: readonly UploadMetadataV2[]): Promise<void> {
    const objects = new Map<string, number>();
    for (const metadata of inventory) objects.set(metadata.digest, metadata.size);
    const values = [...objects];
    if (values.length === 0) {
      this.integrityAuditCursor = 0;
      return;
    }
    const [digest, size] = values[this.integrityAuditCursor % values.length]!;
    this.integrityAuditCursor = (this.integrityAuditCursor + 1) % values.length;
    try {
      const path = await this.objectPath(digest);
      const verified = await this.hashFile(path);
      if (verified.digest !== digest || verified.size !== size) {
        throw new GatewayError("conflict", "Attachment object failed integrity audit");
      }
      this.verifiedObjectDigests.add(digest);
      this.unavailableObjectDigests.delete(digest);
    } catch {
      this.verifiedObjectDigests.delete(digest);
      this.unavailableObjectDigests.set(digest, size);
    }
  }

  async prepareSessionImport(id: string): Promise<UploadImportLease> {
    return this.serialize(async () => {
      const metadata = await this.metadata(id);
      const { actual } = await this.ownedLogicalPath(metadata);
      const importDirectory = await this.ensureImportDirectory();
      const importPath = join(importDirectory, `tron-import-${id}-${randomUUID()}.jsonl`);
      const diskAvailableBytes = await this.readAvailableDiskBytes();
      if (metadata.size + this.outstandingDiskReservations()
        > Math.max(0, diskAvailableBytes - this.minimumFreeBytes)) {
        throw new GatewayError(
          "busy",
          "Session import staging is preserving the Mac free-space floor",
          true,
          {
            reason: "disk",
            diskAvailableBytes,
            minimumFreeBytes: this.minimumFreeBytes,
            requestedBytes: metadata.size,
            reservedBytes: this.outstandingDiskReservations(),
          },
        );
      }
      this.activeImportLeases.set(importPath, metadata.size);
      try {
        await copyFile(actual, importPath, constants.COPYFILE_EXCL);
        const staged = await realpath(importPath);
        const stagedInfo = await stat(staged);
        if (!staged.startsWith(`${importDirectory}/`) || !stagedInfo.isFile()
          || stagedInfo.size !== metadata.size) {
          throw new GatewayError("conflict", "Import staging escaped its owned directory or changed size");
        }
        let released = false;
        return {
          path: staged,
          release: async () => {
            if (released) return;
            released = true;
            await this.serialize(async () => {
              this.activeImportLeases.delete(importPath);
              await rm(importPath, { force: true });
            });
          },
        };
      } catch (error) {
        this.activeImportLeases.delete(importPath);
        await rm(importPath, { force: true });
        throw error;
      }
    });
  }

  /** Discards client staging only. Canonical prompt ownership is immutable. */
  async discard(id: string): Promise<void> {
    this.validateID(id);
    await this.serialize(async () => {
      const metadata = await this.metadata(id);
      if (metadata.sessionId !== undefined) {
        throw new GatewayError("conflict", "A prompt-owned attachment cannot be discarded");
      }
      const uploadDirectory = await this.ensureUploadDirectory();
      await rm(join(uploadDirectory, id), { recursive: true, force: true });
      this.removeIndexedMetadata(id);
      await this.cleanupReleasedObject(metadata.digest, metadata.size);
    });
  }

  async remove(id: string): Promise<void> {
    this.validateID(id);
    await this.serialize(async () => {
      const metadata = await this.metadata(id);
      const uploadDirectory = await this.ensureUploadDirectory();
      await rm(join(uploadDirectory, id), { recursive: true, force: true });
      this.removeIndexedMetadata(id);
      await this.cleanupReleasedObject(metadata.digest, metadata.size);
    }).catch(() => {});
  }

  async acquire(id: string): Promise<UploadLease> {
    this.validateID(id);
    const metadata = await this.metadata(id);
    // Unclaimed uploads are private staging state and cannot become arbitrary
    // authenticated file reads. Only a prompt-owned canonical attachment is
    // eligible for its bounded mobile preview.
    if (!metadata.sessionId) throw new GatewayError("not_found", "Attachment is not available");
    const owned = await this.ownedLogicalPath(metadata);
    const handle = await open(owned.actual, "r");
    let released = false;
    try {
      const actual = await handle.stat();
      if (!actual.isFile() || actual.size !== metadata.size) {
        throw new GatewayError("conflict", "Attachment changed after prompt admission");
      }
      const stream = createReadStream(owned.actual, {
        fd: handle.fd,
        autoClose: false,
        start: 0,
        end: Math.max(0, metadata.size - 1),
      });
      return {
        name: metadata.name,
        mimeType: metadata.mimeType,
        size: metadata.size,
        stream,
        release: async () => {
          if (released) return;
          released = true;
          stream.destroy();
          await handle.close().catch(() => {});
        },
      };
    } catch (error) {
      await handle.close().catch(() => {});
      throw error;
    }
  }

  async removeSession(sessionId: string): Promise<void> {
    this.pendingSessionRemovals.add(sessionId);
    await this.serialize(async () => { await this.reconcileIndexedOwnership(); });
  }

  /** Runs bounded maintenance without weakening canonical attachment ownership.
   * Startup rebuilds physical truth once. Later passes use the rebuildable
   * index, so retained history is never reparsed every ten minutes. */
  async maintain(liveSessionIds?: ReadonlySet<string>): Promise<UploadCapacityStatus> {
    return this.serialize(async () => {
      const bodyDirectory = await this.ensureBodyDirectory();
      await this.cleanupStagedUploads(bodyDirectory);
      await this.cleanupImportDirectory();
      const inventory = this.inventoryInitialized
        ? await this.reconcileIndexedOwnership(liveSessionIds)
        : await this.rebuildInventory(liveSessionIds);
      await this.retryPendingObjectCleanup();
      await this.auditNextObject(inventory);
      return this.capacityStatus(inventory);
    });
  }

  async status(): Promise<UploadCapacityStatus> {
    return this.serialize(async () => this.capacityStatus(await this.currentInventory()));
  }

  private async capacityStatus(inventory: readonly UploadMetadataV2[]): Promise<UploadCapacityStatus> {
    const unclaimed = inventory.filter((item) => item.sessionId === undefined);
    const claimed = inventory.filter((item) => item.sessionId !== undefined);
    const logicalBytes = inventory.reduce((total, item) => total + item.size, 0);
    const unclaimedBytes = unclaimed.reduce((total, item) => total + item.size, 0);
    const claimedBytes = claimed.reduce((total, item) => total + item.size, 0);
    const stagedBytes = [...this.stagedUploads.values()].reduce((total, size) => total + size, 0);
    const stagingLogicalBytes = unclaimedBytes + stagedBytes;
    const objectSizes = new Map<string, number>();
    for (const item of inventory) objectSizes.set(item.digest, item.size);
    const objectBytes = [...objectSizes.values()].reduce((total, size) => total + size, 0);
    const diskAvailableBytes = await this.readAvailableDiskBytes();
    const storagePressure = diskAvailableBytes <= this.minimumFreeBytes ? "exhausted"
      : diskAvailableBytes <= this.minimumFreeBytes + this.maximumStagingBytes ? "low"
        : "normal";
    return {
      entryCount: inventory.length,
      logicalBytes,
      stagingEntryCount: unclaimed.length + this.stagedUploads.size,
      maximumStagingEntries: this.maximumStagingEntries,
      stagingLogicalBytes,
      maximumStagingBytes: this.maximumStagingBytes,
      stagingAvailableBytes: Math.max(0, this.maximumStagingBytes - stagingLogicalBytes),
      unclaimedCount: unclaimed.length,
      unclaimedBytes,
      claimedCount: claimed.length,
      claimedBytes,
      maximumRetainedEntries: this.maximumRetainedEntries,
      maximumRetainedLogicalBytes: this.maximumRetainedLogicalBytes,
      retainedAvailableBytes: Math.max(0, this.maximumRetainedLogicalBytes - claimedBytes),
      stagedCount: this.stagedUploads.size,
      stagedBytes,
      activeImportLeaseCount: this.activeImportLeases.size,
      activeImportLeaseBytes: [...this.activeImportLeases.values()]
        .reduce((total, size) => total + size, 0),
      objectCount: objectSizes.size,
      objectBytes,
      deduplicatedBytes: Math.max(0, logicalBytes - objectBytes),
      orphanObjectCount: this.pendingOrphanObjects.size,
      orphanObjectBytes: [...this.pendingOrphanObjects.values()]
        .reduce((total, size) => total + size, 0),
      unavailableObjectCount: this.unavailableObjectDigests.size,
      unavailableObjectBytes: [...this.unavailableObjectDigests.values()]
        .reduce((total, size) => total + size, 0),
      diskAvailableBytes,
      minimumFreeBytes: this.minimumFreeBytes,
      storagePressure,
      activeBodyAdmissions: this.activeBodyAdmissions,
      maximumConcurrentBodies: this.maximumConcurrentBodies,
      pendingSessionCleanupCount: this.pendingSessionRemovals.size,
      observedAt: new Date(this.now()).toISOString(),
    };
  }

  async materialize(ids: string[], sessionId: string): Promise<{
    images: ImageContent[];
    envelope: string;
    photoCount: number;
    fileAttachmentCount: number;
    attachments: PromptAttachmentState[];
  }> {
    if (ids.length > 10) throw new GatewayError("invalid_request", "At most 10 attachments may be sent with one prompt");
    if (new Set(ids).size !== ids.length) throw new GatewayError("invalid_request", "Prompt attachment ids must be unique");
    return this.serialize(async () => {
      const metadata = await Promise.all(ids.map((id) => this.metadata(id)));
      if (metadata.some((value) => value.sessionId !== undefined && value.sessionId !== sessionId)) {
        throw new GatewayError("conflict", "An attachment is already owned by another session");
      }
      const newClaims = metadata.filter((value) => value.sessionId === undefined);
      const projectedRetainedCount = this.indexedClaimedCount + newClaims.length;
      const projectedRetainedBytes = this.indexedClaimedBytes
        + newClaims.reduce((total, value) => total + value.size, 0);
      if (projectedRetainedCount > this.maximumRetainedEntries
        || projectedRetainedBytes > this.maximumRetainedLogicalBytes) {
        const reason = projectedRetainedCount > this.maximumRetainedEntries
          ? "retained_entries"
          : "retained_bytes";
        throw new GatewayError(
          "busy",
          "Retained attachment history is full; remove an unused canonical session",
          true,
          {
            reason,
            retainedEntryCount: this.indexedClaimedCount,
            maximumRetainedEntries: this.maximumRetainedEntries,
            retainedLogicalBytes: this.indexedClaimedBytes,
            maximumRetainedLogicalBytes: this.maximumRetainedLogicalBytes,
          },
        );
      }
      const totalBytes = metadata.reduce((total, value) => total + value.size, 0);
      if (totalBytes > this.maximumBytes) {
        throw new GatewayError("invalid_request", `Prompt attachments may total at most ${this.maximumBytes} bytes`);
      }

      const owned = await Promise.all(metadata.map((value) => this.ownedLogicalPath(value)));
      const images: ImageContent[] = [];
      const envelopes: string[] = [];
      let photoCount = 0;
      let fileAttachmentCount = 0;
      for (const [index, value] of metadata.entries()) {
        const actual = owned[index]!.actual;
        if (value.mimeType.startsWith("image/")) {
          photoCount += 1;
          images.push({ type: "image", data: (await readFile(actual)).toString("base64"), mimeType: value.mimeType });
        } else {
          fileAttachmentCount += 1;
          envelopes.push(`<attachment name="${xml(value.name)}" mime-type="${xml(value.mimeType)}" size="${value.size}" path="${xml(actual)}" />`);
        }
      }
      const claimedMetadata = metadata.map((value) => ({ ...value, sessionId }));
      for (const [index, value] of claimedMetadata.entries()) {
        await this.durableWriteMetadata(
          join(owned[index]!.ownedDirectory, "metadata.json"),
          value,
        );
        // Each durable claim immediately updates the rebuildable index. A later
        // write failure can be retried by the same session without memory/disk
        // ownership diverging or allowing another session to steal the prefix.
        this.installIndexedMetadata(value);
      }
      return {
        images,
        envelope: envelopes.join("\n"),
        photoCount,
        fileAttachmentCount,
        attachments: metadata.map(({ id, name, mimeType, size }) => ({
          id: `upload:${id}`, name, mimeType, size,
        })),
      };
    });
  }

  private async migrateMetadata(metadata: UploadMetadata): Promise<UploadMetadataV2> {
    const owned = await this.ownedLogicalPath(metadata);
    if (metadata.version === 2) {
      const objectPath = await this.objectPath(metadata.digest);
      try {
        const [logicalInfo, objectInfo] = await Promise.all([stat(owned.actual), lstat(objectPath)]);
        if (objectInfo.isFile() && !objectInfo.isSymbolicLink()
          && objectInfo.size === metadata.size
          && logicalInfo.dev === objectInfo.dev && logicalInfo.ino === objectInfo.ino) {
          return metadata;
        }
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      }
    }

    // Legacy migration and crash repair are exceptional paths. Hash them once,
    // then ordinary inventory validates only inode/size ownership.
    const verified = await this.hashFile(owned.actual);
    const digest = metadata.version === 2 ? metadata.digest : verified.digest;
    if (verified.size !== metadata.size || verified.digest !== digest) {
      throw new GatewayError("conflict", "Attachment content failed integrity verification");
    }
    const objectPath = await this.objectPath(digest);
    let objectExists = false;
    try {
      const objectInfo = await lstat(objectPath);
      if (!objectInfo.isFile() || objectInfo.isSymbolicLink() || objectInfo.size !== metadata.size) {
        throw new GatewayError("conflict", "Attachment object is invalid");
      }
      const objectHash = await this.hashFile(objectPath);
      if (objectHash.digest !== digest || objectHash.size !== metadata.size) {
        throw new GatewayError("conflict", "Attachment object failed integrity verification");
      }
      objectExists = true;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
    if (!objectExists) await link(owned.actual, objectPath);
    const [logicalInfo, objectInfo] = await Promise.all([stat(owned.actual), stat(objectPath)]);
    if (logicalInfo.dev !== objectInfo.dev || logicalInfo.ino !== objectInfo.ino) {
      const replacement = join(owned.ownedDirectory, `.object-${randomUUID()}`);
      try {
        await link(objectPath, replacement);
        await rename(replacement, owned.actual);
      } finally {
        await rm(replacement, { force: true });
      }
    }
    await chmod(objectPath, 0o400);
    await this.syncPath(objectPath);
    await this.syncDirectory(dirname(objectPath));
    await this.syncDirectory(dirname(dirname(objectPath)));
    await this.syncDirectory(dirname(dirname(dirname(objectPath))));
    await this.syncDirectory(owned.ownedDirectory);
    this.verifiedObjectDigests.add(digest);
    this.unavailableObjectDigests.delete(digest);
    if (metadata.version === 2) return metadata;
    const migrated: UploadMetadataV2 = { ...metadata, version: 2, digest };
    await this.durableWriteMetadata(join(owned.ownedDirectory, "metadata.json"), migrated);
    return migrated;
  }

  private async reconcileIndexedOwnership(
    liveSessionIds?: ReadonlySet<string>,
  ): Promise<UploadMetadataV2[]> {
    await this.refreshIndexedExpiry();
    const failedRemovals = new Set<string>();
    for (const [id, metadata] of [...this.logicalIndex]) {
      if (metadata.sessionId === undefined) continue;
      const shouldRemove = this.pendingSessionRemovals.has(metadata.sessionId)
        || (liveSessionIds !== undefined && !liveSessionIds.has(metadata.sessionId));
      if (!shouldRemove) continue;
      try {
        await rm(join(this.directory, id), { recursive: true, force: true });
        this.removeIndexedMetadata(id);
      } catch {
        failedRemovals.add(metadata.sessionId);
        continue;
      }
      await this.cleanupReleasedObject(metadata.digest, metadata.size);
    }
    for (const sessionId of [...this.pendingSessionRemovals]) {
      if (!failedRemovals.has(sessionId)) this.pendingSessionRemovals.delete(sessionId);
    }
    return [...this.logicalIndex.values()];
  }

  private installIndexedMetadata(metadata: UploadMetadataV2): void {
    this.removeIndexedMetadata(metadata.id);
    this.logicalIndex.set(metadata.id, metadata);
    if (metadata.sessionId === undefined) {
      this.unclaimedIndex.add(metadata.id);
      this.indexedUnclaimedBytes += metadata.size;
    } else {
      this.indexedClaimedCount += 1;
      this.indexedClaimedBytes += metadata.size;
    }
  }

  private removeIndexedMetadata(id: string): void {
    const existing = this.logicalIndex.get(id);
    if (!existing) return;
    this.logicalIndex.delete(id);
    if (existing.sessionId === undefined) {
      this.unclaimedIndex.delete(id);
      this.indexedUnclaimedBytes = Math.max(0, this.indexedUnclaimedBytes - existing.size);
    } else {
      this.indexedClaimedCount = Math.max(0, this.indexedClaimedCount - 1);
      this.indexedClaimedBytes = Math.max(0, this.indexedClaimedBytes - existing.size);
    }
  }

  private async refreshIndexedExpiry(): Promise<void> {
    if (!this.inventoryInitialized) await this.rebuildInventory();
    const cutoff = this.now() - this.maximumUnclaimedAgeMs;
    for (const id of [...this.unclaimedIndex]) {
      const metadata = this.logicalIndex.get(id)!;
      if (Date.parse(metadata.createdAt) <= cutoff) {
        await rm(join(this.directory, id), { recursive: true, force: true });
        this.removeIndexedMetadata(id);
        await this.cleanupReleasedObject(metadata.digest, metadata.size);
      }
    }
  }

  private async currentInventory(): Promise<UploadMetadataV2[]> {
    await this.refreshIndexedExpiry();
    return [...this.logicalIndex.values()];
  }

  private async rebuildInventory(liveSessionIds?: ReadonlySet<string>): Promise<UploadMetadataV2[]> {
    this.verifiedObjectDigests.clear();
    const uploadDirectory = await this.ensureUploadDirectory();
    const entries = await readdir(uploadDirectory, { withFileTypes: true });
    const result: UploadMetadataV2[] = [];
    const pendingRemovals = new Set(this.pendingSessionRemovals);
    const failedRemovals = new Set<string>();
    const cutoff = this.now() - this.maximumUnclaimedAgeMs;
    for (const entry of entries) {
      const folder = join(uploadDirectory, entry.name);
      if (!entry.isDirectory()) {
        await rm(folder, { recursive: true, force: true });
        continue;
      }
      const metadata = await this.readMetadata(join(folder, "metadata.json"));
      if (!isUploadMetadata(metadata, entry.name, this.maximumBytes)
        || (metadata.sessionId === undefined && Date.parse(metadata.createdAt) <= cutoff)
        || (metadata.sessionId !== undefined
          && liveSessionIds !== undefined
          && !liveSessionIds.has(metadata.sessionId))) {
        await rm(folder, { recursive: true, force: true });
        continue;
      }
      try {
        if (metadata.sessionId !== undefined && pendingRemovals.has(metadata.sessionId)) {
          try {
            await rm(folder, { recursive: true, force: true });
          } catch {
            failedRemovals.add(metadata.sessionId);
            const migrated = await this.migrateMetadata(metadata);
            result.push(migrated);
          }
        } else {
          const migrated = await this.migrateMetadata(metadata);
          result.push(migrated);
        }
      } catch (error) {
        if (!isConfirmedUploadCorruption(error)) throw error;
        await rm(folder, { recursive: true, force: true });
      }
    }
    for (const sessionId of pendingRemovals) {
      if (!failedRemovals.has(sessionId)) this.pendingSessionRemovals.delete(sessionId);
    }
    const referencedDigests = new Set(result.map((item) => item.digest));
    await this.cleanupObjectDirectory(referencedDigests);
    for (const digest of [...this.unavailableObjectDigests.keys()]) {
      if (!referencedDigests.has(digest)) this.unavailableObjectDigests.delete(digest);
    }
    this.pendingOrphanObjects.clear();
    this.logicalIndex.clear();
    this.unclaimedIndex.clear();
    this.indexedUnclaimedBytes = 0;
    this.indexedClaimedCount = 0;
    this.indexedClaimedBytes = 0;
    for (const metadata of result) this.installIndexedMetadata(metadata);
    this.inventoryInitialized = true;
    return result;
  }

  private async metadata(id: string): Promise<UploadMetadataV2> {
    this.validateID(id);
    const uploadDirectory = await this.ensureUploadDirectory();
    const folder = join(uploadDirectory, id);
    try { await this.ownedUploadDirectory(id, uploadDirectory); }
    catch {
      await rm(folder, { recursive: true, force: true });
      this.removeIndexedMetadata(id);
      throw new GatewayError("not_found", "Upload was not found");
    }
    const metadata = await this.readMetadata(join(folder, "metadata.json"));
    if (!isUploadMetadata(metadata, id, this.maximumBytes)
      || (metadata.sessionId === undefined && Date.parse(metadata.createdAt) <= this.now() - this.maximumUnclaimedAgeMs)) {
      await rm(folder, { recursive: true, force: true });
      this.removeIndexedMetadata(id);
      throw new GatewayError("not_found", "Upload was not found");
    }
    try {
      const migrated = await this.migrateMetadata(metadata);
      await this.ownedPath(migrated);
      this.installIndexedMetadata(migrated);
      return migrated;
    } catch (error) {
      if (!isConfirmedUploadCorruption(error)) throw error;
      if (metadata.version === 2 && this.unavailableObjectDigests.has(metadata.digest)) {
        throw new GatewayError("not_found", "Attachment content is unavailable after integrity failure");
      }
      await rm(join(uploadDirectory, id), { recursive: true, force: true });
      this.removeIndexedMetadata(id);
      if (metadata.version === 2) await this.cleanupReleasedObject(metadata.digest, metadata.size);
      throw new GatewayError("not_found", "Upload content is missing or invalid");
    }
  }

  private async readMetadata(path: string): Promise<unknown> {
    try {
      return await readJson<unknown>(path, null, UPLOAD_METADATA_MAX_BYTES);
    } catch (error) {
      if (error instanceof SyntaxError || error instanceof RangeError) return null;
      throw error;
    }
  }

  private async ownedUploadDirectory(id: string, knownUploadDirectory?: string): Promise<string> {
    const uploadDirectory = knownUploadDirectory ?? await this.ensureUploadDirectory();
    const candidate = join(uploadDirectory, id);
    const info = await lstat(candidate);
    const actual = await realpath(candidate);
    if (!info.isDirectory() || info.isSymbolicLink() || dirname(actual) !== uploadDirectory) {
      throw new GatewayError("conflict", "Upload directory escaped Gateway ownership");
    }
    return actual;
  }

  private async ownedLogicalPath(
    metadata: UploadMetadata,
  ): Promise<{ actual: string; ownedDirectory: string }> {
    const actual = await realpath(metadata.path);
    const ownedDirectory = await this.ownedUploadDirectory(metadata.id);
    const info = await stat(actual);
    if (!actual.startsWith(`${ownedDirectory}/`) || !info.isFile() || info.size !== metadata.size) {
      throw new GatewayError("conflict", "Upload content escaped its owned directory or changed size");
    }
    return { actual, ownedDirectory };
  }

  private async ownedPath(metadata: UploadMetadata): Promise<{ actual: string; ownedDirectory: string }> {
    const migrated = await this.migrateMetadata(metadata);
    const owned = await this.ownedLogicalPath(migrated);
    const objectPath = await this.objectPath(migrated.digest);
    const [logicalInfo, objectInfo] = await Promise.all([stat(owned.actual), stat(objectPath)]);
    if (!objectInfo.isFile() || objectInfo.size !== migrated.size
      || logicalInfo.dev !== objectInfo.dev || logicalInfo.ino !== objectInfo.ino) {
      throw new GatewayError("conflict", "Attachment logical path is not backed by its owned object");
    }
    if (this.unavailableObjectDigests.has(migrated.digest)) {
      throw new GatewayError("conflict", "Attachment object is unavailable after integrity failure");
    }
    if (!this.verifiedObjectDigests.has(migrated.digest)) {
      const verified = await this.hashFile(owned.actual);
      if (verified.size !== migrated.size || verified.digest !== migrated.digest) {
        this.unavailableObjectDigests.set(migrated.digest, migrated.size);
        throw new GatewayError("conflict", "Attachment object failed read-time integrity verification");
      }
      this.verifiedObjectDigests.add(migrated.digest);
    }
    return owned;
  }

  private async readAvailableDiskBytes(): Promise<number> {
    const value = await this.availableDiskBytes();
    if (!Number.isSafeInteger(value) || value < 0) {
      throw new GatewayError("internal", "Attachment filesystem capacity is invalid");
    }
    return value;
  }

  private validateID(id: string): void {
    if (!/^[0-9a-f-]{36}$/.test(id)) throw new GatewayError("invalid_request", "Upload id is invalid");
  }

  private async serialize<T>(operation: () => Promise<T>): Promise<T> {
    const previous = this.mutationTail;
    let release!: () => void;
    this.mutationTail = new Promise<void>((resolve) => { release = resolve; });
    await previous;
    try {
      return await operation();
    } finally {
      release();
    }
  }
}
