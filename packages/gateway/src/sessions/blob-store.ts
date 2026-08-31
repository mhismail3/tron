import { createHash, randomUUID } from "node:crypto";
import { createReadStream, createWriteStream } from "node:fs";
import { lstat, mkdir, open, realpath, rename, rm, stat, statfs } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { Readable, Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import { GatewayError } from "../errors.js";

interface BlobValueBase {
  mimeType: string;
  size: number;
  touchedAt: number;
  activeReaders: number;
  retired: boolean;
  cleanup?: Promise<void>;
}

interface MemoryBlobValue extends BlobValueBase {
  kind: "memory";
  data: Buffer;
}

interface FileBlobValue extends BlobValueBase {
  kind: "file";
  path: string;
}

type BlobValue = MemoryBlobValue | FileBlobValue;

export interface BlobLease {
  mimeType: string;
  /** Bytes exposed by this lease (the full item when rangeStart is zero). */
  size: number;
  totalSize: number;
  rangeStart: number;
  rangeEnd: number;
  stream: Readable;
  release(): Promise<void>;
}

export interface BlobByteRange {
  start: number;
  end?: number;
}

export const BLOB_MAX_ITEM_BYTES = 25 * 1_048_576;
export const BLOB_MAX_ITEMS = 128;
export const BLOB_MAX_TOTAL_BYTES = 200 * 1_048_576;
export const BLOB_MAX_MIME_TYPE_BYTES = 1_024;

export interface BlobStoreLimits {
  maximumItemBytes: number;
  maximumItems: number;
  maximumTotalBytes: number;
  maximumReaders?: number;
  maximumFileProductions?: number;
  minimumFreeBytes?: number;
}

function isConfirmedMissingBlob(error: unknown): boolean {
  if (error instanceof GatewayError) return error.code === "not_found";
  const code = (error as NodeJS.ErrnoException)?.code;
  return code === "ENOENT" || code === "ENOTDIR" || code === "ELOOP";
}

const defaultLimits: BlobStoreLimits = {
  maximumItemBytes: BLOB_MAX_ITEM_BYTES,
  maximumItems: BLOB_MAX_ITEMS,
  maximumTotalBytes: BLOB_MAX_TOTAL_BYTES,
};

export class BlobStore {
  private readonly blobs = new Map<string, BlobValue>();
  private totalBytes = 0;
  private pendingFileItems = 0;
  private pendingFileBytes = 0;
  private activeReaders = 0;
  private activeFileProductions = 0;
  private readonly maximumReaders: number;
  private readonly maximumFileProductions: number;
  private readonly fileRegistrations = new Set<Promise<string>>();
  private readonly fileProductions = new Set<Promise<unknown>>();
  private mutationTail = Promise.resolve();
  private initialization?: Promise<void>;
  private initialized = false;
  private disposed = false;
  private disposeTask?: Promise<void>;

  constructor(
    private readonly limits: BlobStoreLimits = defaultLimits,
    private readonly now: () => number = Date.now,
    private readonly directory?: string,
  ) {
    const ratio = Math.max(1, Math.floor(limits.maximumTotalBytes / Math.max(1, limits.maximumItemBytes)));
    this.maximumReaders = limits.maximumReaders ?? Math.max(4, Math.floor(limits.maximumItems / 4));
    this.maximumFileProductions = limits.maximumFileProductions ?? Math.max(1, Math.floor(ratio / 2));
    if (limits.maximumItemBytes < 0 || limits.maximumItems < 1
      || limits.maximumTotalBytes < limits.maximumItemBytes
      || !Number.isSafeInteger(this.maximumReaders) || this.maximumReaders < 1
      || !Number.isSafeInteger(this.maximumFileProductions) || this.maximumFileProductions < 1
      || !Number.isSafeInteger(limits.minimumFreeBytes ?? 0) || (limits.minimumFreeBytes ?? 0) < 0) {
      throw new Error("Invalid blob store limits");
    }
  }

  async initialize(): Promise<void> {
    if (this.disposed) throw new GatewayError("internal", "Blob storage is not available");
    if (!this.directory || this.initialized) return;
    if (this.initialization) return this.initialization;
    const operation = (async () => {
      await rm(this.directory!, { recursive: true, force: true });
      if (this.disposed) throw new GatewayError("internal", "Blob storage is not available");
      await this.ensureDirectory();
      if (this.disposed) throw new GatewayError("internal", "Blob storage is not available");
      this.initialized = true;
    })();
    this.initialization = operation;
    try {
      await operation;
    } finally {
      if (this.initialization === operation) delete this.initialization;
    }
  }

  register(base64: string, mimeType: string): string {
    const maximumBase64Characters = Math.ceil(this.limits.maximumItemBytes / 3) * 4;
    if (base64.length > maximumBase64Characters) {
      throw new GatewayError("conflict", "Blob exceeds the 25 MiB item limit");
    }
    return this.registerData(Buffer.from(base64, "base64"), mimeType);
  }

  registerData(data: Buffer, mimeType: string): string {
    if (this.disposed) throw new GatewayError("internal", "Blob storage is not available");
    this.validateMimeType(mimeType);
    if (data.length > this.limits.maximumItemBytes) {
      throw new GatewayError("conflict", "Blob exceeds the 25 MiB item limit");
    }
    const id = this.idFor(mimeType, data);
    const existing = this.blobs.get(id);
    if (existing) {
      if (existing.cleanup) throw new GatewayError("busy", "Blob storage is retiring matching content", true);
      this.revive(existing);
      return id;
    }
    this.prune();
    this.admit(data.length);
    this.blobs.set(id, {
      kind: "memory",
      data,
      size: data.length,
      mimeType,
      touchedAt: this.now(),
      activeReaders: 0,
      retired: false,
    });
    this.totalBytes += data.length;
    return id;
  }

  async withFileProductionAdmission<T>(operation: () => Promise<T>): Promise<T> {
    if (this.disposed) throw new GatewayError("internal", "Blob storage is not available");
    if (this.activeFileProductions >= this.maximumFileProductions) {
      throw new GatewayError("busy", "Concurrent export generation reached its bounded capacity", true);
    }
    this.activeFileProductions += 1;
    let production: Promise<T>;
    try {
      production = operation();
    } catch (error) {
      this.activeFileProductions = Math.max(0, this.activeFileProductions - 1);
      throw error;
    }
    this.fileProductions.add(production);
    try {
      return await production;
    } finally {
      this.fileProductions.delete(production);
      this.activeFileProductions = Math.max(0, this.activeFileProductions - 1);
    }
  }

  registerFile(source: string, mimeType: string): Promise<string> {
    const operation = this.registerFileOperation(source, mimeType);
    this.fileRegistrations.add(operation);
    void operation.then(
      () => { this.fileRegistrations.delete(operation); },
      () => { this.fileRegistrations.delete(operation); },
    );
    return operation;
  }

  private async registerFileOperation(source: string, mimeType: string): Promise<string> {
    this.validateMimeType(mimeType);
    this.assertFileStorageAvailable();
    const before = await stat(source);
    if (!before.isFile() || before.size > this.limits.maximumItemBytes) {
      throw new GatewayError("conflict", "Blob exceeds the 25 MiB item limit");
    }
    let reserved = false;
    await this.serialize(async () => {
      this.assertFileStorageAvailable();
      this.prune();
      this.admit(before.size);
      this.pendingFileItems += 1;
      this.pendingFileBytes += before.size;
      reserved = true;
    });

    let staging: string | undefined;
    try {
      this.assertFileStorageAvailable();
      const directory = await this.ensureDirectory();
      const minimumFreeBytes = this.limits.minimumFreeBytes ?? 0;
      if (minimumFreeBytes > 0) {
        const filesystem = await statfs(directory);
        const available = filesystem.bavail * filesystem.bsize;
        if (!Number.isSafeInteger(available) || available < before.size + minimumFreeBytes) {
          throw new GatewayError("busy", "Blob file storage does not have enough free space", true);
        }
      }
      const stagingPath = join(directory, `staging-${randomUUID()}`);
      staging = stagingPath;
      const hash = createHash("sha256").update(mimeType).update("\0");
      let copiedSize = 0;
      const meter = new Transform({
        transform: (chunk: Buffer, _encoding, callback) => {
          copiedSize += chunk.length;
          if (copiedSize > before.size) {
            callback(new GatewayError("conflict", "Blob source changed while it was being registered"));
            return;
          }
          hash.update(chunk);
          callback(null, chunk);
        },
      });
      await pipeline(
        createReadStream(source),
        meter,
        createWriteStream(stagingPath, { flags: "wx", mode: 0o600 }),
      );
      const afterCopy = await stat(source);
      const staged = await stat(stagingPath);
      if (!afterCopy.isFile() || afterCopy.size !== before.size || afterCopy.mtimeMs !== before.mtimeMs
        || copiedSize !== before.size || !staged.isFile() || staged.size !== copiedSize) {
        throw new GatewayError("conflict", "Blob source changed while it was being registered");
      }
      const id = hash.digest("base64url");
      return await this.serialize(async () => {
        this.assertFileStorageAvailable();
        let existing = this.blobs.get(id);
        if (existing?.cleanup) {
          await existing.cleanup;
          this.assertFileStorageAvailable();
          existing = this.blobs.get(id);
        }
        if (existing) {
          this.revive(existing);
          this.releaseFileReservation(before.size);
          reserved = false;
          return id;
        }
        const path = join(directory, `blob-${randomUUID()}`);
        try {
          await rename(stagingPath, path);
          const actual = await realpath(path);
          const info = await stat(actual);
          if (!actual.startsWith(`${directory}/`) || !info.isFile() || info.size !== before.size) {
            throw new GatewayError("conflict", "Blob storage ownership changed during registration");
          }
          this.assertFileStorageAvailable();
          this.releaseFileReservation(before.size);
          reserved = false;
          this.admit(before.size);
          this.blobs.set(id, {
            kind: "file",
            path: actual,
            size: before.size,
            mimeType,
            touchedAt: this.now(),
            activeReaders: 0,
            retired: false,
          });
          this.totalBytes += before.size;
          return id;
        } catch (error) {
          await rm(path, { force: true });
          throw error;
        }
      });
    } finally {
      if (staging) await rm(staging, { force: true });
      if (reserved) {
        await this.serialize(async () => {
          this.releaseFileReservation(before.size);
          reserved = false;
        });
      }
    }
  }

  /** Compatibility accessor for synchronous projected-image tests and callers. */
  get(id: string): { data: Buffer; mimeType: string } {
    const value = this.available(id);
    if (value.kind !== "memory") throw new GatewayError("conflict", "File-backed blobs require a reader lease");
    this.touch(value);
    return { data: value.data, mimeType: value.mimeType };
  }

  async acquire(id: string, requestedRange?: BlobByteRange): Promise<BlobLease> {
    if (this.disposed) throw new GatewayError("not_found", "Blob is not available; refresh the session snapshot");
    const value = this.available(id);
    const rangeStart = requestedRange?.start ?? 0;
    const rangeEnd = requestedRange?.end ?? value.size - 1;
    if ((value.size === 0 && requestedRange)
      || !Number.isSafeInteger(rangeStart) || !Number.isSafeInteger(rangeEnd)
      || rangeStart < 0
      || (value.size > 0 && (rangeEnd < rangeStart || rangeEnd >= value.size))
      || (value.size === 0 && (rangeStart !== 0 || rangeEnd !== -1))) {
      throw new GatewayError("invalid_request", "Requested blob byte range is not satisfiable");
    }
    const rangeSize = value.size === 0 ? 0 : rangeEnd - rangeStart + 1;
    if (this.activeReaders >= this.maximumReaders) {
      throw new GatewayError("busy", "Concurrent blob downloads reached their bounded capacity", true);
    }
    this.touch(value);
    value.activeReaders += 1;
    this.activeReaders += 1;
    let handle: Awaited<ReturnType<typeof open>> | undefined;
    let stream: Readable;
    try {
      if (value.kind === "memory") stream = Readable.from([value.data.subarray(rangeStart, rangeEnd + 1)]);
      else {
        handle = await open(value.path, "r");
        const info = await handle.stat();
        if (!info.isFile() || info.size !== value.size) {
          throw new GatewayError("not_found", "Blob is not available; refresh the session snapshot");
        }
        stream = value.size === 0
          ? Readable.from([])
          : handle.createReadStream({ start: rangeStart, end: rangeEnd, autoClose: false });
      }
    } catch (error) {
      value.activeReaders -= 1;
      this.activeReaders = Math.max(0, this.activeReaders - 1);
      await handle?.close().catch(() => {});
      if (isConfirmedMissingBlob(error)) {
        this.retire(id, value);
        throw new GatewayError("not_found", "Blob is not available; refresh the session snapshot");
      }
      throw error;
    }

    let released = false;
    return {
      mimeType: value.mimeType,
      size: rangeSize,
      totalSize: value.size,
      rangeStart,
      rangeEnd,
      stream,
      release: async () => {
        if (released) return;
        released = true;
        stream.destroy();
        await handle?.close().catch(() => {});
        value.activeReaders = Math.max(0, value.activeReaders - 1);
        this.activeReaders = Math.max(0, this.activeReaders - 1);
        if (value.retired && value.activeReaders === 0) await this.cleanup(id, value);
        else if (!value.retired) this.touch(value);
      },
    };
  }

  prune(maxAgeMs = 30 * 60_000): void {
    const cutoff = this.now() - maxAgeMs;
    for (const [id, value] of this.blobs) {
      if (value.touchedAt < cutoff) this.retire(id, value);
    }
  }

  dispose(): Promise<void> {
    if (this.disposeTask) return this.disposeTask;
    this.disposed = true;
    const task = this.finishDispose();
    this.disposeTask = task;
    return task;
  }

  private async finishDispose(): Promise<void> {
    if (this.initialization) await this.initialization.catch(() => {});
    await Promise.allSettled([...this.fileProductions]);
    await Promise.allSettled([...this.fileRegistrations]);
    await this.serialize(async () => {});
    await Promise.all([...this.blobs].map(async ([id, value]) => {
      value.retired = true;
      if (value.activeReaders === 0) await this.cleanup(id, value);
    }));
    if (this.directory && [...this.blobs.values()].every((value) => value.activeReaders === 0)) {
      await rm(this.directory, { recursive: true, force: true });
    }
  }

  private available(id: string): BlobValue {
    const value = this.blobs.get(id);
    if (!value || value.retired) {
      throw new GatewayError("not_found", "Blob is not available; refresh the session snapshot");
    }
    return value;
  }

  private assertFileStorageAvailable(): void {
    if (!this.directory || !this.initialized || this.disposed) {
      throw new GatewayError("internal", "Blob file storage is not available");
    }
  }

  private validateMimeType(mimeType: string): void {
    if (Buffer.byteLength(mimeType) > BLOB_MAX_MIME_TYPE_BYTES
      || /[\u0000-\u001f\u007f]/.test(mimeType)) {
      throw new GatewayError("conflict", "Blob MIME type exceeds the metadata limit or contains control characters");
    }
  }

  private idFor(mimeType: string, data: Buffer): string {
    return createHash("sha256").update(mimeType).update("\0").update(data).digest("base64url");
  }

  private admit(size: number): void {
    if (this.blobs.size + this.pendingFileItems >= this.limits.maximumItems
      || size > this.limits.maximumTotalBytes - this.totalBytes - this.pendingFileBytes) {
      throw new GatewayError("busy", "Blob storage is temporarily full", true);
    }
  }

  private releaseFileReservation(size: number): void {
    this.pendingFileItems = Math.max(0, this.pendingFileItems - 1);
    this.pendingFileBytes = Math.max(0, this.pendingFileBytes - size);
  }

  private revive(value: BlobValue): void {
    value.retired = false;
    this.touch(value);
  }

  private touch(value: BlobValue): void {
    value.touchedAt = this.now();
  }

  private retire(id: string, value: BlobValue): void {
    value.retired = true;
    if (value.activeReaders === 0) void this.cleanup(id, value);
  }

  private cleanup(id: string, value: BlobValue): Promise<void> {
    if (value.activeReaders > 0) return Promise.resolve();
    if (value.cleanup) return value.cleanup;
    value.cleanup = (async () => {
      if (value.kind === "file") {
        try {
          await rm(value.path, { force: true });
        } catch {
          // Retain the retired entry and its physical capacity accounting so
          // cleanup failure cannot admit more disk usage or break a completed download.
          return;
        }
      }
      if (this.blobs.get(id) === value) {
        this.blobs.delete(id);
        this.totalBytes -= value.size;
      }
      if (this.disposed && this.directory && this.blobs.size === 0) {
        await rm(this.directory, { recursive: true, force: true });
      }
    })().finally(() => { delete value.cleanup; });
    return value.cleanup;
  }

  private async ensureDirectory(): Promise<string> {
    if (!this.directory) throw new GatewayError("internal", "Blob file storage is not configured");
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    const info = await lstat(this.directory);
    const actual = await realpath(this.directory);
    const expected = join(await realpath(dirname(this.directory)), basename(this.directory));
    if (!info.isDirectory() || info.isSymbolicLink() || actual !== expected) {
      throw new GatewayError("conflict", "Blob directory is not owned by the Gateway");
    }
    return actual;
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
