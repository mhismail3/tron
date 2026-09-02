import { createHash, randomUUID } from "node:crypto";
import { constants, createReadStream, createWriteStream, type ReadStream } from "node:fs";
import {
  chmod, link, lstat, mkdir, open, readFile, readdir, realpath, rm, stat, statfs,
} from "node:fs/promises";
import { basename, dirname, extname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import { GatewayError } from "../errors.js";
import { atomicWriteJson, readJson } from "../util/json.js";
import type { BlobByteRange, BlobLease } from "../sessions/blob-store.js";

const METADATA_MAX_BYTES = 64 * 1_024;
const DIGEST_PATTERN = /^[0-9a-f]{64}$/;
const ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export const DISPLAY_MAXIMUM_ARTIFACT_BYTES = 2 * 1_024 * 1_024 * 1_024;
const DEFAULT_MAXIMUM_LOGICAL_BYTES = 32 * 1_024 * 1_024 * 1_024;
const DEFAULT_MAXIMUM_ITEMS = 16_384;
const DEFAULT_MINIMUM_FREE_BYTES = 1 * 1_024 * 1_024 * 1_024;

export type DisplayArtifactKind =
  | "image" | "markdown" | "text" | "code" | "pdf" | "html"
  | "video" | "audio" | "document";

export interface DisplayArtifactDescriptor {
  id: string;
  name: string;
  mimeType: string;
  size: number;
  kind: DisplayArtifactKind;
}

interface DisplayArtifactMetadata extends DisplayArtifactDescriptor {
  version: 1;
  digest: string;
  owners: string[];
  createdAt: string;
}

interface DisplayArtifactStoreOptions {
  maximumItemBytes?: number;
  maximumLogicalBytes?: number;
  maximumItems?: number;
  minimumFreeBytes?: number;
  maximumReaders?: number;
  maximumIngests?: number;
  now?: () => number;
  uuid?: () => string;
}

function inside(root: string, candidate: string): boolean {
  const delta = relative(root, candidate);
  return delta === "" || (!delta.startsWith(`..${sep}`) && delta !== ".." && !isAbsolute(delta));
}

function safeName(input: string): string {
  const value = basename(input).replace(/[\u0000-\u001f\u007f]/g, "").slice(0, 160);
  return value || "artifact";
}

function validIdentity(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= 200
    && !/[\u0000-\u001f\u007f]/.test(value);
}

function isMetadata(value: unknown, expectedID: string, maximumItemBytes: number): value is DisplayArtifactMetadata {
  if (!value || typeof value !== "object") return false;
  const item = value as Record<string, unknown>;
  const expectedKeys = ["version", "id", "name", "mimeType", "size", "kind", "digest", "owners", "createdAt"];
  return Object.keys(item).length === expectedKeys.length
    && Object.keys(item).every((key) => expectedKeys.includes(key))
    && item.version === 1
    && item.id === expectedID && typeof item.id === "string" && ID_PATTERN.test(item.id)
    && typeof item.name === "string" && item.name === safeName(item.name)
    && typeof item.mimeType === "string" && item.mimeType.length > 0 && item.mimeType.length <= 200
    && !/[\u0000-\u001f\u007f]/.test(item.mimeType)
    && Number.isSafeInteger(item.size) && (item.size as number) > 0 && (item.size as number) <= maximumItemBytes
    && ["image", "markdown", "text", "code", "pdf", "html", "video", "audio", "document"].includes(String(item.kind))
    && typeof item.digest === "string" && DIGEST_PATTERN.test(item.digest)
    && Array.isArray(item.owners) && item.owners.length > 0 && item.owners.length <= 512
    && new Set(item.owners).size === item.owners.length && item.owners.every(validIdentity)
    && typeof item.createdAt === "string" && Number.isFinite(Date.parse(item.createdAt))
    && new Date(item.createdAt).toISOString() === item.createdAt;
}

function extensionClassification(path: string): { mimeType: string; kind: DisplayArtifactKind } {
  switch (extname(path).toLowerCase()) {
    case ".png": return { mimeType: "image/png", kind: "image" };
    case ".jpg": case ".jpeg": return { mimeType: "image/jpeg", kind: "image" };
    case ".gif": return { mimeType: "image/gif", kind: "image" };
    case ".webp": return { mimeType: "image/webp", kind: "image" };
    case ".svg": return { mimeType: "image/svg+xml", kind: "html" };
    case ".md": case ".markdown": return { mimeType: "text/markdown; charset=utf-8", kind: "markdown" };
    case ".txt": case ".log": case ".csv": return { mimeType: "text/plain; charset=utf-8", kind: "text" };
    case ".json": return { mimeType: "application/json", kind: "code" };
    case ".html": case ".htm": return { mimeType: "text/html; charset=utf-8", kind: "html" };
    case ".pdf": return { mimeType: "application/pdf", kind: "pdf" };
    case ".mp4": return { mimeType: "video/mp4", kind: "video" };
    case ".mov": return { mimeType: "video/quicktime", kind: "video" };
    case ".m4v": return { mimeType: "video/x-m4v", kind: "video" };
    case ".mp3": return { mimeType: "audio/mpeg", kind: "audio" };
    case ".m4a": return { mimeType: "audio/mp4", kind: "audio" };
    case ".wav": return { mimeType: "audio/wav", kind: "audio" };
    case ".swift": case ".ts": case ".tsx": case ".js": case ".css": case ".py":
    case ".go": case ".rs": case ".java": case ".kt": case ".sh": case ".sql":
    case ".xml": case ".yaml": case ".yml": case ".toml":
      return { mimeType: "text/plain; charset=utf-8", kind: "code" };
    default: return { mimeType: "application/octet-stream", kind: "document" };
  }
}

function maximumBytesForKind(kind: DisplayArtifactKind): number {
  switch (kind) {
    case "html": case "markdown": case "text": case "code": return 5 * 1_024 * 1_024;
    case "image": case "pdf": case "document": return 25 * 1_024 * 1_024;
    case "video": case "audio": return DISPLAY_MAXIMUM_ARTIFACT_BYTES;
  }
}

function signatureMatches(prefix: Buffer, classification: { mimeType: string; kind: DisplayArtifactKind }): boolean {
  const ascii = prefix.toString("utf8");
  switch (classification.mimeType) {
    case "image/png": return prefix.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));
    case "image/jpeg": return prefix[0] === 0xff && prefix[1] === 0xd8 && prefix[2] === 0xff;
    case "image/gif": return ascii.startsWith("GIF87a") || ascii.startsWith("GIF89a");
    case "image/webp": return ascii.startsWith("RIFF") && ascii.slice(8, 12) === "WEBP";
    case "application/pdf": return ascii.startsWith("%PDF-");
    case "video/mp4": case "video/quicktime": case "video/x-m4v":
    case "audio/mp4": return prefix.length >= 12 && prefix.subarray(4, 8).toString("ascii") === "ftyp";
    case "audio/mpeg": return ascii.startsWith("ID3") || (prefix[0] === 0xff && (prefix[1] ?? 0) >= 0xe0);
    case "audio/wav": return ascii.startsWith("RIFF") && ascii.slice(8, 12) === "WAVE";
    default:
      if (classification.kind === "text" || classification.kind === "markdown"
        || classification.kind === "code" || classification.kind === "html") {
        return !prefix.includes(0);
      }
      return true;
  }
}

export class DisplayArtifactStore {
  private readonly root: string;
  private readonly artifactDirectory: string;
  private readonly objectDirectory: string;
  private readonly stagingDirectory: string;
  private readonly maximumItemBytes: number;
  private readonly maximumLogicalBytes: number;
  private readonly maximumItems: number;
  private readonly minimumFreeBytes: number;
  private readonly maximumReaders: number;
  private readonly maximumIngests: number;
  private readonly now: () => number;
  private readonly uuid: () => string;
  private readonly index = new Map<string, DisplayArtifactMetadata>();
  private readonly activeReaderCounts = new Map<string, number>();
  private readonly verifiedDigests = new Set<string>();
  private readonly verificationFlights = new Map<string, Promise<void>>();
  private activeReaders = 0;
  private activeIngests = 0;
  private logicalBytes = 0;
  private mutationTail = Promise.resolve();
  private initialized = false;

  constructor(tronHome: string, options: DisplayArtifactStoreOptions = {}) {
    this.root = join(tronHome, "gateway", "display-artifacts");
    this.artifactDirectory = join(this.root, "artifacts");
    this.objectDirectory = join(this.root, "objects");
    this.stagingDirectory = join(this.root, "staging");
    this.maximumItemBytes = options.maximumItemBytes ?? DISPLAY_MAXIMUM_ARTIFACT_BYTES;
    this.maximumLogicalBytes = options.maximumLogicalBytes ?? DEFAULT_MAXIMUM_LOGICAL_BYTES;
    this.maximumItems = options.maximumItems ?? DEFAULT_MAXIMUM_ITEMS;
    this.minimumFreeBytes = options.minimumFreeBytes ?? DEFAULT_MINIMUM_FREE_BYTES;
    this.maximumReaders = options.maximumReaders ?? 4;
    this.maximumIngests = options.maximumIngests ?? 2;
    this.now = options.now ?? Date.now;
    this.uuid = options.uuid ?? randomUUID;
    if (![this.maximumItemBytes, this.maximumLogicalBytes, this.maximumItems, this.minimumFreeBytes,
      this.maximumReaders, this.maximumIngests].every(Number.isSafeInteger)
      || this.maximumItemBytes < 1 || this.maximumLogicalBytes < this.maximumItemBytes
      || this.maximumItems < 1 || this.minimumFreeBytes < 0 || this.maximumReaders < 1
      || this.maximumIngests < 1) throw new Error("Display artifact store bounds are invalid");
  }

  async initialize(liveSessionIDs?: ReadonlySet<string>): Promise<void> {
    await this.serialize(async () => {
      await this.ensureDirectories();
      await rm(this.stagingDirectory, { recursive: true, force: true });
      await mkdir(this.stagingDirectory, { recursive: true, mode: 0o700 });
      this.index.clear();
      this.verifiedDigests.clear();
      this.logicalBytes = 0;
      const entries = await readdir(this.artifactDirectory, { withFileTypes: true });
      for (const entry of entries) {
        const folder = join(this.artifactDirectory, entry.name);
        if (!entry.isDirectory() || !ID_PATTERN.test(entry.name)) {
          await rm(folder, { recursive: true, force: true });
          continue;
        }
        try {
          if (this.index.size >= this.maximumItems) {
            await rm(folder, { recursive: true, force: true });
            continue;
          }
          const metadata = await readJson<unknown>(join(folder, "metadata.json"), undefined, METADATA_MAX_BYTES);
          if (!isMetadata(metadata, entry.name, this.maximumItemBytes)) throw new Error("invalid metadata");
          const owners = liveSessionIDs ? metadata.owners.filter((id) => liveSessionIDs.has(id)) : metadata.owners;
          if (owners.length === 0) {
            await rm(folder, { recursive: true, force: true });
            continue;
          }
          const [ownedFolder, ownedObjectDirectory] = await Promise.all([
            realpath(folder), realpath(this.objectDirectory),
          ]);
          const content = await realpath(join(folder, "content"));
          const info = await stat(content);
          const object = await realpath(this.objectPath(metadata.digest));
          const objectInfo = await stat(object);
          if (!inside(ownedFolder, content) || !info.isFile() || info.size !== metadata.size
            || !inside(ownedObjectDirectory, object) || !objectInfo.isFile()
            || info.dev !== objectInfo.dev || info.ino !== objectInfo.ino) throw new Error("invalid object");
          await chmod(object, 0o400);
          const admitted = owners.length === metadata.owners.length ? metadata : { ...metadata, owners };
          if (admitted !== metadata) await this.writeMetadata(join(folder, "metadata.json"), admitted);
          this.index.set(admitted.id, admitted);
          this.logicalBytes += admitted.size;
        } catch {
          await rm(folder, { recursive: true, force: true });
        }
      }
      this.initialized = true;
      await this.removeOrphanObjects();
    });
  }

  async ingest(workspace: string, requestedPath: string, sessionID: string): Promise<DisplayArtifactDescriptor> {
    this.assertInitialized();
    if (this.activeIngests >= this.maximumIngests) {
      throw new GatewayError("busy", "Concurrent display artifact ingestion reached its bounded capacity", true);
    }
    this.activeIngests += 1;
    try {
      return await this.ingestOwned(workspace, requestedPath, sessionID);
    } finally {
      this.activeIngests = Math.max(0, this.activeIngests - 1);
    }
  }

  private async ingestOwned(workspace: string, requestedPath: string, sessionID: string): Promise<DisplayArtifactDescriptor> {
    if (!validIdentity(sessionID)) throw new GatewayError("invalid_request", "Display session identity is invalid");
    if (!requestedPath || requestedPath.length > 4_096 || isAbsolute(requestedPath) || requestedPath.includes("\0")) {
      throw new GatewayError("invalid_request", "Display path must be relative to the session workspace");
    }
    const components = requestedPath.split(/[\\/]/);
    if (components.some((value) => !value || value === "." || value === ".." || value.startsWith("."))) {
      throw new GatewayError("invalid_request", "Display path must be a visible relative path inside the session workspace");
    }
    const root = await realpath(resolve(workspace));
    const rootInfo = await lstat(root);
    if (!rootInfo.isDirectory() || rootInfo.isSymbolicLink()) {
      throw new GatewayError("conflict", "The session workspace is no longer a directory", true);
    }
    let source = root;
    for (const component of components) {
      source = join(source, component);
      const info = await lstat(source);
      if (info.isSymbolicLink()) throw new GatewayError("invalid_request", "Display paths cannot contain symbolic links");
    }
    const opened = await open(source, constants.O_RDONLY | constants.O_NOFOLLOW);
    let staging: string | undefined;
    try {
      const before = await opened.stat();
      const actualSource = await realpath(source);
      if (!inside(root, actualSource) || !before.isFile() || before.size < 1 || before.size > this.maximumItemBytes) {
        throw new GatewayError("conflict", `Display artifacts may contain 1 through ${this.maximumItemBytes} bytes`);
      }
      await this.reserve(before.size);
      const available = await statfs(this.root);
      const free = available.bavail * available.bsize;
      if (!Number.isSafeInteger(free) || free < before.size + this.minimumFreeBytes) {
        throw new GatewayError("busy", "Display artifact storage is preserving the Mac free-space floor", true);
      }
      staging = join(this.stagingDirectory, this.uuid());
      const digest = createHash("sha256");
      const prefixChunks: Buffer[] = [];
      let prefixBytes = 0;
      let copied = 0;
      const meter = new Transform({
        transform(chunk: Buffer, _encoding, callback) {
          copied += chunk.length;
          if (copied > before.size) return callback(new GatewayError("conflict", "Display source changed during ingestion"));
          digest.update(chunk);
          if (prefixBytes < 4_096) {
            const value = chunk.subarray(0, 4_096 - prefixBytes);
            prefixChunks.push(value);
            prefixBytes += value.length;
          }
          callback(null, chunk);
        },
      });
      await pipeline(
        opened.createReadStream({ autoClose: false }),
        meter,
        createWriteStream(staging, { flags: "wx", mode: 0o600 }),
      );
      const stagedHandle = await open(staging, "r+");
      try { await stagedHandle.sync(); }
      finally { await stagedHandle.close(); }
      const after = await opened.stat();
      const current = await lstat(source);
      if (!after.isFile() || current.isSymbolicLink() || !current.isFile()
        || before.dev !== after.dev || before.ino !== after.ino || before.size !== after.size
        || before.mtimeMs !== after.mtimeMs || current.dev !== before.dev || current.ino !== before.ino
        || copied !== before.size) {
        throw new GatewayError("conflict", "Display source changed during ingestion", true);
      }
      const classification = extensionClassification(source);
      if (copied > maximumBytesForKind(classification.kind)) {
        throw new GatewayError("conflict", "Display artifact exceeds the limit for this content type");
      }
      const prefix = Buffer.concat(prefixChunks);
      if (!signatureMatches(prefix, classification)) {
        throw new GatewayError("invalid_request", "Display file contents do not match the supported file type");
      }
      if (classification.kind === "text" || classification.kind === "markdown"
        || classification.kind === "code" || classification.kind === "html") {
        const text = await readFile(staging);
        if (text.includes(0) || !new TextDecoder("utf-8", { fatal: true }).decode(text)) {
          throw new GatewayError("invalid_request", "Display text artifacts must contain valid UTF-8 text without NUL bytes");
        }
      }
      const descriptor = await this.publish({
        source: staging,
        digest: digest.digest("hex"),
        name: safeName(source),
        size: copied,
        classification,
        sessionID,
      });
      staging = undefined;
      return descriptor;
    } finally {
      await opened.close().catch(() => {});
      if (staging) await rm(staging, { force: true });
    }
  }

  private async reserve(size: number): Promise<void> {
    await this.serialize(async () => {
      this.assertInitialized();
      if (this.index.size >= this.maximumItems || size > this.maximumLogicalBytes - this.logicalBytes) {
        throw new GatewayError("busy", "Retained display artifact storage is full; remove an unused session", true);
      }
    });
  }

  private async publish(input: {
    source: string;
    digest: string;
    name: string;
    size: number;
    classification: { mimeType: string; kind: DisplayArtifactKind };
    sessionID: string;
  }): Promise<DisplayArtifactDescriptor> {
    return this.serialize(async () => {
      if (this.index.size >= this.maximumItems || input.size > this.maximumLogicalBytes - this.logicalBytes) {
        throw new GatewayError("busy", "Retained display artifact storage is full; remove an unused session", true);
      }
      const object = this.objectPath(input.digest);
      await mkdir(dirname(object), { recursive: true, mode: 0o700 });
      try {
        await link(input.source, object);
        await chmod(object, 0o400);
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
        const info = await stat(object);
        if (!info.isFile() || info.size !== input.size) throw new GatewayError("conflict", "Display object digest collision");
        await this.verify(input.digest, input.size, object, true);
      }
      await rm(input.source, { force: true });
      const id = this.uuid();
      if (!ID_PATTERN.test(id) || this.index.has(id)) throw new GatewayError("busy", "Could not allocate a display artifact identity", true);
      const folder = join(this.artifactDirectory, id);
      await mkdir(folder, { recursive: false, mode: 0o700 });
      try {
        await link(object, join(folder, "content"));
        const metadata: DisplayArtifactMetadata = {
          version: 1,
          id,
          name: input.name,
          mimeType: input.classification.mimeType,
          size: input.size,
          kind: input.classification.kind,
          digest: input.digest,
          owners: [input.sessionID],
          createdAt: new Date(this.now()).toISOString(),
        };
        await this.writeMetadata(join(folder, "metadata.json"), metadata);
        this.index.set(id, metadata);
        this.verifiedDigests.add(metadata.digest);
        this.logicalBytes += metadata.size;
        return { id, name: metadata.name, mimeType: metadata.mimeType, size: metadata.size, kind: metadata.kind };
      } catch (error) {
        await rm(folder, { recursive: true, force: true });
        await this.removeObjectIfUnreferenced(input.digest);
        throw error;
      }
    });
  }

  async grant(id: string, sessionID: string, sourceSessionID: string): Promise<void> {
    this.validateID(id);
    if (!validIdentity(sessionID) || !validIdentity(sourceSessionID)) {
      throw new GatewayError("invalid_request", "Display session identity is invalid");
    }
    await this.serialize(async () => {
      const metadata = this.index.get(id);
      if (!metadata?.owners.includes(sourceSessionID)) {
        throw new GatewayError("not_found", "Display artifact is unavailable");
      }
      if (metadata.owners.includes(sessionID)) return;
      if (metadata.owners.length >= 512) throw new GatewayError("busy", "Display artifact ownership reached its bounded capacity", true);
      const next = { ...metadata, owners: [...metadata.owners, sessionID].sort() };
      await this.writeMetadata(join(this.artifactDirectory, id, "metadata.json"), next);
      this.index.set(id, next);
    });
  }

  hasOwner(id: string, sessionID: string): boolean {
    return this.index.get(id)?.owners.includes(sessionID) === true;
  }

  async acquire(id: string, sessionID: string, requestedRange?: BlobByteRange): Promise<BlobLease> {
    this.validateID(id);
    const metadata = this.index.get(id);
    if (!metadata || !metadata.owners.includes(sessionID)) throw new GatewayError("not_found", "Display artifact is unavailable");
    if (this.activeReaders >= this.maximumReaders) {
      throw new GatewayError("busy", "Concurrent display artifact reads reached their bounded capacity", true);
    }
    const start = requestedRange?.start ?? 0;
    const end = requestedRange?.end ?? metadata.size - 1;
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || end < start || end >= metadata.size) {
      throw new GatewayError(
        "invalid_request",
        "Requested display artifact byte range is not satisfiable",
        false,
        { rangeUnsatisfiable: true, totalSize: metadata.size },
      );
    }
    const path = join(this.artifactDirectory, id, "content");
    await this.verify(metadata.digest, metadata.size, path);
    const handle = await open(path, "r");
    try {
      const info = await handle.stat();
      if (!info.isFile() || info.size !== metadata.size) throw new GatewayError("not_found", "Display artifact is unavailable");
      this.activeReaders += 1;
      this.activeReaderCounts.set(id, (this.activeReaderCounts.get(id) ?? 0) + 1);
      const stream: ReadStream = createReadStream(path, { fd: handle.fd, autoClose: false, start, end });
      let released = false;
      return {
        mimeType: metadata.mimeType,
        size: end - start + 1,
        totalSize: metadata.size,
        rangeStart: start,
        rangeEnd: end,
        stream,
        release: async () => {
          if (released) return;
          released = true;
          stream.destroy();
          await handle.close().catch(() => {});
          this.activeReaders = Math.max(0, this.activeReaders - 1);
          const count = Math.max(0, (this.activeReaderCounts.get(id) ?? 1) - 1);
          if (count === 0) this.activeReaderCounts.delete(id); else this.activeReaderCounts.set(id, count);
        },
      };
    } catch (error) {
      await handle.close().catch(() => {});
      throw error;
    }
  }

  async revoke(id: string, sessionID: string): Promise<void> {
    this.validateID(id);
    await this.serialize(() => this.revokeOwner(id, sessionID));
  }

  /** Removes only provisional/noncanonical ownership for one loaded session.
   * The caller supplies references from the complete canonical JSONL tree, not
   * merely the active branch, so branch navigation remains reversible. */
  async reconcileSession(sessionID: string, canonicalArtifactIDs: ReadonlySet<string>): Promise<void> {
    if (!validIdentity(sessionID) || canonicalArtifactIDs.size > this.maximumItems) {
      throw new GatewayError("invalid_request", "Display artifact reconciliation identity is invalid");
    }
    for (const id of canonicalArtifactIDs) {
      if (!ID_PATTERN.test(id)) {
        throw new GatewayError("invalid_request", "Display artifact reconciliation identity is invalid");
      }
    }
    await this.serialize(async () => {
      for (const [id, metadata] of [...this.index]) {
        if (metadata.owners.includes(sessionID) && !canonicalArtifactIDs.has(id)) {
          await this.revokeOwner(id, sessionID);
        }
      }
    });
  }

  private async revokeOwner(id: string, sessionID: string): Promise<void> {
    const metadata = this.index.get(id);
    if (!metadata?.owners.includes(sessionID)) return;
    const owners = metadata.owners.filter((owner) => owner !== sessionID);
    if (owners.length > 0) {
      const next = { ...metadata, owners };
      await this.writeMetadata(join(this.artifactDirectory, id, "metadata.json"), next);
      this.index.set(id, next);
      return;
    }
    if ((this.activeReaderCounts.get(id) ?? 0) > 0) return;
    await rm(join(this.artifactDirectory, id), { recursive: true, force: true });
    this.index.delete(id);
    this.logicalBytes = Math.max(0, this.logicalBytes - metadata.size);
    await this.removeObjectIfUnreferenced(metadata.digest);
  }

  async removeSession(sessionID: string): Promise<void> {
    await this.maintain(undefined, sessionID);
  }

  async maintain(liveSessionIDs?: ReadonlySet<string>, removingSessionID?: string): Promise<void> {
    await this.serialize(async () => {
      for (const [id, metadata] of [...this.index]) {
        const owners = metadata.owners.filter((owner) => owner !== removingSessionID
          && (liveSessionIDs === undefined || liveSessionIDs.has(owner)));
        if (owners.length === metadata.owners.length) continue;
        if (owners.length > 0) {
          const next = { ...metadata, owners };
          await this.writeMetadata(join(this.artifactDirectory, id, "metadata.json"), next);
          this.index.set(id, next);
          continue;
        }
        if ((this.activeReaderCounts.get(id) ?? 0) > 0) continue;
        await rm(join(this.artifactDirectory, id), { recursive: true, force: true });
        this.index.delete(id);
        this.logicalBytes = Math.max(0, this.logicalBytes - metadata.size);
        await this.removeObjectIfUnreferenced(metadata.digest);
      }
    });
  }

  private async verify(
    digest: string,
    expectedSize: number,
    path: string,
    force = false,
  ): Promise<void> {
    if (!force && this.verifiedDigests.has(digest)) return;
    const existing = this.verificationFlights.get(digest);
    if (existing) return existing;
    const operation = (async () => {
      const hash = createHash("sha256");
      let size = 0;
      for await (const value of createReadStream(path)) {
        const chunk = Buffer.isBuffer(value) ? value : Buffer.from(value);
        size += chunk.length;
        if (size > expectedSize) throw new GatewayError("conflict", "Display artifact failed integrity verification");
        hash.update(chunk);
      }
      if (size !== expectedSize || hash.digest("hex") !== digest) {
        throw new GatewayError("conflict", "Display artifact failed integrity verification");
      }
      this.verifiedDigests.add(digest);
    })();
    this.verificationFlights.set(digest, operation);
    try { await operation; }
    finally { this.verificationFlights.delete(digest); }
  }

  private async writeMetadata(path: string, metadata: DisplayArtifactMetadata): Promise<void> {
    await atomicWriteJson(path, metadata);
    const handle = await open(path, "r");
    try { await handle.sync(); }
    finally { await handle.close(); }
  }

  private async removeObjectIfUnreferenced(digest: string): Promise<void> {
    if ([...this.index.values()].some((value) => value.digest === digest)) return;
    await rm(this.objectPath(digest), { force: true });
    this.verifiedDigests.delete(digest);
  }

  private async removeOrphanObjects(): Promise<void> {
    const referenced = new Set([...this.index.values()].map((value) => value.digest));
    const shards = await readdir(this.objectDirectory, { withFileTypes: true });
    for (const shard of shards) {
      const shardPath = join(this.objectDirectory, shard.name);
      if (!shard.isDirectory() || !/^[0-9a-f]{2}$/.test(shard.name)) {
        await rm(shardPath, { recursive: true, force: true });
        continue;
      }
      for (const entry of await readdir(shardPath, { withFileTypes: true })) {
        const path = join(shardPath, entry.name);
        const digest = `${shard.name}${entry.name}`;
        if (!entry.isFile() || !DIGEST_PATTERN.test(digest) || !referenced.has(digest)) await rm(path, { recursive: true, force: true });
      }
    }
  }

  private objectPath(digest: string): string {
    if (!DIGEST_PATTERN.test(digest)) throw new GatewayError("conflict", "Display object digest is invalid");
    return join(this.objectDirectory, digest.slice(0, 2), digest.slice(2));
  }

  private async ensureDirectories(): Promise<void> {
    for (const path of [this.root, this.artifactDirectory, this.objectDirectory, this.stagingDirectory]) {
      await mkdir(path, { recursive: true, mode: 0o700 });
      const info = await lstat(path);
      const actual = await realpath(path);
      const expected = join(await realpath(dirname(path)), basename(path));
      if (!info.isDirectory() || info.isSymbolicLink() || actual !== expected) {
        throw new GatewayError("conflict", "Display artifact storage is not owned by the Gateway");
      }
    }
  }

  private validateID(id: string): void {
    if (!ID_PATTERN.test(id)) throw new GatewayError("not_found", "Display artifact is unavailable");
  }

  private assertInitialized(): void {
    if (!this.initialized) throw new GatewayError("busy", "Display artifact storage is warming", true);
  }

  private async serialize<T>(operation: () => Promise<T>): Promise<T> {
    const previous = this.mutationTail;
    let release!: () => void;
    this.mutationTail = new Promise<void>((resolvePromise) => { release = resolvePromise; });
    await previous;
    try { return await operation(); }
    finally { release(); }
  }
}
