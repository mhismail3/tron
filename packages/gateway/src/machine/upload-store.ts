import { randomUUID } from "node:crypto";
import { constants } from "node:fs";
import { copyFile, lstat, mkdir, open, readFile, readdir, realpath, rename, rm, stat } from "node:fs/promises";
import { basename, dirname, extname, join } from "node:path";
import type { ImageContent } from "@earendil-works/pi-ai";
import { GatewayError } from "../errors.js";
import { atomicWriteJson, readJson } from "../util/json.js";
import { isGatewayTimestamp } from "../util/timestamp.js";

const UPLOAD_METADATA_MAX_BYTES = 64 * 1_024;
const DEFAULT_MAXIMUM_ENTRIES = 1_024;

interface UploadMetadata {
  version: 1;
  id: string;
  name: string;
  mimeType: string;
  size: number;
  path: string;
  createdAt: string;
  sessionId?: string;
}

interface StagedUpload {
  id: string;
  folder: string;
  path: string;
  reservedBytes: number;
}

interface UploadStoreOptions {
  maximumEntries?: number;
  maximumAggregateBytes?: number;
  maximumUnclaimedAgeMs?: number;
  now?: () => number;
  uuid?: () => string;
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
  const metadata = value as Partial<UploadMetadata>;
  const keys = Object.keys(metadata);
  const expectedKeys = metadata.sessionId === undefined
    ? ["version", "id", "name", "mimeType", "size", "path", "createdAt"]
    : ["version", "id", "name", "mimeType", "size", "path", "createdAt", "sessionId"];
  return keys.length === expectedKeys.length && keys.every((key) => expectedKeys.includes(key))
    && metadata.version === 1
    && metadata.id === expectedID
    && typeof metadata.name === "string" && metadata.name === safeName(metadata.name)
    && typeof metadata.mimeType === "string" && metadata.mimeType.length > 0 && metadata.mimeType.length <= 200
    && !/[\u0000-\u001f\u007f]/.test(metadata.mimeType)
    && typeof metadata.path === "string" && metadata.path.length > 0 && metadata.path.length <= 8_192
    && typeof metadata.createdAt === "string" && isGatewayTimestamp(metadata.createdAt)
    && new Date(metadata.createdAt).toISOString() === metadata.createdAt
    && Number.isSafeInteger(metadata.size) && (metadata.size ?? 0) > 0 && (metadata.size ?? 0) <= maximumBytes
    && (metadata.sessionId === undefined || (typeof metadata.sessionId === "string" && metadata.sessionId.length > 0 && metadata.sessionId.length <= 200));
}

export class UploadStore {
  private readonly directory: string;
  private readonly bodyDirectory: string;
  private readonly maximumEntries: number;
  private readonly maximumAggregateBytes: number;
  private readonly maximumUnclaimedAgeMs: number;
  private readonly now: () => number;
  private readonly uuid: () => string;
  private readonly pendingSessionRemovals = new Set<string>();
  private readonly maximumConcurrentBodies: number;
  private activeBodyAdmissions = 0;
  private readonly stagedUploads = new Map<string, number>();
  private mutationTail = Promise.resolve();

  constructor(
    tronHome: string,
    private readonly maximumBytes: number,
    options: UploadStoreOptions = {},
  ) {
    this.directory = join(tronHome, "gateway", "uploads");
    this.bodyDirectory = join(tronHome, "gateway", "upload-bodies");
    // The aggregate byte bound is the primary storage limit. A 128-entry cap
    // fragments that capacity when users attach many small photos or imported
    // documents, even while substantial byte capacity remains. Keep the item
    // bound high but finite so metadata/inventory work remains bounded.
    this.maximumEntries = options.maximumEntries ?? DEFAULT_MAXIMUM_ENTRIES;
    this.maximumAggregateBytes = options.maximumAggregateBytes ?? maximumBytes * 8;
    this.maximumUnclaimedAgeMs = options.maximumUnclaimedAgeMs ?? 24 * 60 * 60_000;
    this.maximumConcurrentBodies = Math.max(1, Math.floor(this.maximumAggregateBytes / maximumBytes / 2));
    this.now = options.now ?? Date.now;
    this.uuid = options.uuid ?? randomUUID;
    if (![maximumBytes, this.maximumEntries, this.maximumAggregateBytes, this.maximumUnclaimedAgeMs].every(Number.isSafeInteger)
      || maximumBytes < 1 || this.maximumEntries < 1 || this.maximumAggregateBytes < maximumBytes || this.maximumUnclaimedAgeMs < 1) {
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
    try {
      const handle = await open(staged.path, "wx", 0o600);
      try {
        for await (const value of body) {
          const chunk = Buffer.isBuffer(value) ? value : Buffer.from(value);
          size += chunk.length;
          if (size > this.maximumBytes || (declaredBytes !== undefined && size > declaredBytes)) {
            throw new GatewayError("invalid_request", "Request body is too large");
          }
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

      const metadata = await this.commitStagedUpload(staged, nameInput, mimeTypeInput, size);
      committed = true;
      return metadata;
    } finally {
      if (!committed) await this.releaseStagedUpload(staged);
    }
  }

  private async reserveStagedUpload(reservedBytes: number): Promise<StagedUpload> {
    return this.serialize(async () => {
      const inventory = await this.inventory();
      const uploadDirectory = await this.ensureUploadDirectory();
      const bodyDirectory = await this.ensureBodyDirectory();
      await this.cleanupStagedUploads(bodyDirectory);
      const aggregateBytes = inventory.reduce((total, item) => total + item.size, 0)
        + [...this.stagedUploads.values()].reduce((total, size) => total + size, 0);
      if (inventory.length + this.stagedUploads.size >= this.maximumEntries
        || reservedBytes > this.maximumAggregateBytes - aggregateBytes) {
        throw new GatewayError("busy", "Stored uploads reached their bounded capacity; remove an imported session or try again later", true);
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
        const path = join(folder, `content${extname(name).slice(0, 20)}`);
        await rename(staged.path, path);
        const actual = await realpath(path);
        const ownedDirectory = await realpath(folder);
        const info = await stat(actual);
        if (!actual.startsWith(`${ownedDirectory}/`) || !info.isFile() || info.size !== size) {
          throw new GatewayError("conflict", "Upload content escaped its owned directory or changed size");
        }
        const metadata: UploadMetadata = {
          version: 1,
          id: staged.id,
          name,
          mimeType,
          size,
          path: actual,
          createdAt: new Date(this.now()).toISOString(),
        };
        await atomicWriteJson(join(folder, "metadata.json"), metadata);
        this.stagedUploads.delete(staged.id);
        await rm(staged.folder, { recursive: true, force: true });
        return metadata;
      } catch (error) {
        await rm(folder, { recursive: true, force: true });
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

  private ensureUploadDirectory(): Promise<string> {
    return this.ensureOwnedDirectory(this.directory, "Upload directory is not owned by the Gateway");
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

  async prepareSessionImport(id: string): Promise<string> {
    return this.serialize(async () => {
      const metadata = await this.metadata(id);
      const { actual, ownedDirectory } = await this.ownedPath(metadata);
      const importPath = join(ownedDirectory, `tron-import-${id}.jsonl`);
      await rm(importPath, { recursive: true, force: true });
      await copyFile(actual, importPath, constants.COPYFILE_EXCL);
      const staged = await realpath(importPath);
      const stagedInfo = await stat(staged);
      if (!staged.startsWith(`${ownedDirectory}/`) || !stagedInfo.isFile() || stagedInfo.size !== metadata.size) {
        await rm(importPath, { force: true });
        throw new GatewayError("conflict", "Import staging escaped its upload or changed size");
      }
      return staged;
    });
  }

  async remove(id: string): Promise<void> {
    this.validateID(id);
    await this.serialize(async () => {
      const uploadDirectory = await this.ensureUploadDirectory();
      await rm(join(uploadDirectory, id), { recursive: true, force: true });
    }).catch(() => {});
  }

  async removeSession(sessionId: string): Promise<void> {
    this.pendingSessionRemovals.add(sessionId);
    await this.serialize(async () => { await this.inventory(); }).catch(() => {});
  }

  async materialize(ids: string[], sessionId: string): Promise<{ images: ImageContent[]; envelope: string }> {
    if (ids.length > 10) throw new GatewayError("invalid_request", "At most 10 attachments may be sent with one prompt");
    if (new Set(ids).size !== ids.length) throw new GatewayError("invalid_request", "Prompt attachment ids must be unique");
    return this.serialize(async () => {
      const metadata = await Promise.all(ids.map((id) => this.metadata(id)));
      if (metadata.some((value) => value.sessionId !== undefined && value.sessionId !== sessionId)) {
        throw new GatewayError("conflict", "An attachment is already owned by another session");
      }
      const totalBytes = metadata.reduce((total, value) => total + value.size, 0);
      if (totalBytes > this.maximumBytes) {
        throw new GatewayError("invalid_request", `Prompt attachments may total at most ${this.maximumBytes} bytes`);
      }

      const owned = await Promise.all(metadata.map((value) => this.ownedPath(value)));
      const images: ImageContent[] = [];
      const envelopes: string[] = [];
      for (const [index, value] of metadata.entries()) {
        const actual = owned[index]!.actual;
        if (value.mimeType.startsWith("image/")) {
          images.push({ type: "image", data: (await readFile(actual)).toString("base64"), mimeType: value.mimeType });
        } else {
          envelopes.push(`<attachment name="${xml(value.name)}" mime-type="${xml(value.mimeType)}" size="${value.size}" path="${xml(actual)}" />`);
        }
      }
      await Promise.all(metadata.map((value, index) => atomicWriteJson(
        join(owned[index]!.ownedDirectory, "metadata.json"),
        { ...value, sessionId },
      )));
      return { images, envelope: envelopes.join("\n") };
    });
  }

  private async inventory(): Promise<UploadMetadata[]> {
    const uploadDirectory = await this.ensureUploadDirectory();
    const entries = await readdir(uploadDirectory, { withFileTypes: true });
    const result: UploadMetadata[] = [];
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
        || (metadata.sessionId === undefined && Date.parse(metadata.createdAt) <= cutoff)) {
        await rm(folder, { recursive: true, force: true });
        continue;
      }
      try {
        await this.ownedPath(metadata);
        if (metadata.sessionId !== undefined && pendingRemovals.has(metadata.sessionId)) {
          try {
            await rm(folder, { recursive: true, force: true });
          } catch {
            failedRemovals.add(metadata.sessionId);
            result.push(metadata);
          }
        } else {
          result.push(metadata);
        }
      } catch (error) {
        if (!isConfirmedUploadCorruption(error)) throw error;
        await rm(folder, { recursive: true, force: true });
      }
    }
    for (const sessionId of pendingRemovals) {
      if (!failedRemovals.has(sessionId)) this.pendingSessionRemovals.delete(sessionId);
    }
    return result;
  }

  private async metadata(id: string): Promise<UploadMetadata> {
    this.validateID(id);
    const uploadDirectory = await this.ensureUploadDirectory();
    const folder = join(uploadDirectory, id);
    try { await this.ownedUploadDirectory(id, uploadDirectory); }
    catch {
      await rm(folder, { recursive: true, force: true });
      throw new GatewayError("not_found", "Upload was not found");
    }
    const metadata = await this.readMetadata(join(folder, "metadata.json"));
    if (!isUploadMetadata(metadata, id, this.maximumBytes)
      || (metadata.sessionId === undefined && Date.parse(metadata.createdAt) <= this.now() - this.maximumUnclaimedAgeMs)) {
      await rm(folder, { recursive: true, force: true });
      throw new GatewayError("not_found", "Upload was not found");
    }
    try {
      await this.ownedPath(metadata);
    } catch (error) {
      if (!isConfirmedUploadCorruption(error)) throw error;
      await rm(join(uploadDirectory, id), { recursive: true, force: true });
      throw new GatewayError("not_found", "Upload content is missing or invalid");
    }
    return metadata;
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

  private async ownedPath(metadata: UploadMetadata): Promise<{ actual: string; ownedDirectory: string }> {
    const actual = await realpath(metadata.path);
    const ownedDirectory = await this.ownedUploadDirectory(metadata.id);
    const info = await stat(actual);
    if (!actual.startsWith(`${ownedDirectory}/`) || !info.isFile() || info.size !== metadata.size) {
      throw new GatewayError("conflict", "Upload content escaped its owned directory or changed size");
    }
    return { actual, ownedDirectory };
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
