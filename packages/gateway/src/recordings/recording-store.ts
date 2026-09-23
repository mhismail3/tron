import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { chmod, lstat, mkdir, open, readdir, realpath, rename, statfs, type FileHandle } from "node:fs/promises";
import { dirname, join } from "node:path";
import { GatewayError } from "../errors.js";
import { durableAtomicWriteJson } from "../util/durable-json.js";
import type { TronWorkspace } from "../workspace/tron-workspace.js";

export const RECORDING_CAPABILITY = "recordings.v1";
export const MAX_RECORDING_SEGMENT_BYTES = 64 * 1024 * 1024;
export const MAX_RECORDING_SEGMENTS = 512;
export const RECORDING_PAGE_LIMIT = 100;
const MINIMUM_FREE_BYTES = 1_024 * 1_048_576;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const SHA256 = /^[0-9a-f]{64}$/;

export interface RecordingCaptureMetadata {
  schemaVersion: 1;
  source: { appVersion: string; platform: "watchOS"; platformVersion: string };
  startedAt: string;
  stoppedAt: string;
  clockOffsetMilliseconds: number;
  stopReason: "user" | "recovered-partial";
  recoveryStatus: "complete" | "interrupted";
  timeline: Array<{ segment: number; startMonotonicMilliseconds: number; durationMilliseconds: number; pauseBeforeMilliseconds: number; frameCount: number; codec: string; format: string }>;
}
export interface SegmentReceipt { schemaVersion: 1; recordingId: string; segment: number; size: number; sha256: string; acceptedAt: string }
export interface RecordingReceipt {
  schemaVersion: 1; recordingId: string; destinationId: string; sourceDeviceId: string;
  finalizedAt: string; contentSha256: string; totalBytes: number; segmentCount: number;
  capture: RecordingCaptureMetadata;
}
interface RecordingManifest { schemaVersion: 1; recordingId: string; sourceDeviceId: string; destinationId: string; createdAt: string }

function validDate(value: unknown): value is string { return typeof value === "string" && Number.isFinite(Date.parse(value)) && new Date(value).toISOString() === value; }
function validateCapture(value: unknown): RecordingCaptureMetadata {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new GatewayError("invalid_request", "Capture metadata must be an object");
  const item = value as RecordingCaptureMetadata;
  if (Object.keys(value).sort().join(",") !== "clockOffsetMilliseconds,recoveryStatus,schemaVersion,source,startedAt,stopReason,stoppedAt,timeline"
    || !item.source || Object.keys(item.source).sort().join(",") !== "appVersion,platform,platformVersion"
    || item.schemaVersion !== 1 || !item.source || item.source.platform !== "watchOS"
    || !boundedText(item.source.appVersion, 64) || !boundedText(item.source.platformVersion, 64)
    || !validDate(item.startedAt) || !validDate(item.stoppedAt) || Date.parse(item.stoppedAt) < Date.parse(item.startedAt)
    || !Number.isSafeInteger(item.clockOffsetMilliseconds) || Math.abs(item.clockOffsetMilliseconds) > 86_400_000
    || !["user", "recovered-partial"].includes(item.stopReason)
    || !["complete", "interrupted"].includes(item.recoveryStatus)
    || !Array.isArray(item.timeline) || item.timeline.length < 1 || item.timeline.length > MAX_RECORDING_SEGMENTS) {
    throw new GatewayError("invalid_request", "Capture metadata is invalid");
  }
  for (const [index, point] of item.timeline.entries()) {
    if (!point || Object.keys(point).sort().join(",") !== "codec,durationMilliseconds,format,frameCount,pauseBeforeMilliseconds,segment,startMonotonicMilliseconds" || !boundedText(point.codec, 64) || !boundedText(point.format, 64) || !Number.isSafeInteger(point.frameCount) || point.frameCount < 0 || point.segment !== index + 1 || !Number.isSafeInteger(point.startMonotonicMilliseconds)
      || point.startMonotonicMilliseconds < 0 || !Number.isSafeInteger(point.durationMilliseconds)
      || point.durationMilliseconds < 0 || !Number.isSafeInteger(point.pauseBeforeMilliseconds) || point.pauseBeforeMilliseconds < 0) {
      throw new GatewayError("invalid_request", "Capture timeline is invalid");
    }
  }
  if ((item.stopReason === "user") !== (item.recoveryStatus === "complete")) throw new GatewayError("invalid_request", "Stop reason and recovery status disagree");
  return item;
}
function boundedText(value: unknown, maximum: number): value is string { return typeof value === "string" && value.length > 0 && value.length <= maximum && !/[\u0000-\u001f\u007f]/.test(value); }
function isSegmentReceipt(value: unknown, id: string, number: number): value is SegmentReceipt {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const receipt = value as Record<string, unknown>;
  return Object.keys(receipt).sort().join(",") === "acceptedAt,recordingId,schemaVersion,segment,sha256,size"
    && receipt.schemaVersion === 1 && receipt.recordingId === id && receipt.segment === number
    && Number.isSafeInteger(receipt.size) && (receipt.size as number) > 0 && (receipt.size as number) <= MAX_RECORDING_SEGMENT_BYTES
    && typeof receipt.sha256 === "string" && SHA256.test(receipt.sha256) && validDate(receipt.acceptedAt);
}
function validateId(id: string): void { if (!UUID.test(id)) throw new GatewayError("invalid_request", "Recording ID must be a lowercase UUID"); }

/** Canonical originals live in workspace files; accepted segments are immutable until explicit user deletion exists. */
export class RecordingStore {
  private readonly locks = new Map<string, Promise<void>>();
  private activeBodies = 0;
  private reservedBytes = 0;
  constructor(private readonly workspace: TronWorkspace, private readonly destinationId: string, private readonly options: { minimumFreeBytes?: number; availableDiskBytes?: (path: string) => Promise<number> } = {}) {}

  private async recordingsRoot(create: boolean): Promise<string> {
    const files = await this.workspace.filesRoot();
    const path = join(files, "recordings");
    if (create) {
      try { await mkdir(path, { mode: 0o700 }); await this.syncDirectory(files); }
      catch (error) { if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error; }
    }
    const info = await lstat(path);
    const actual = await realpath(path);
    if (!info.isDirectory() || info.isSymbolicLink() || actual !== path || info.uid !== process.getuid?.() || (info.mode & 0o022) !== 0) throw new GatewayError("conflict", "Recording workspace directory is not safely owned");
    return actual;
  }
  private async folder(id: string, create = false): Promise<string> {
    validateId(id);
    const root = await this.recordingsRoot(create);
    const path = join(root, id);
    if (create) { try { await mkdir(path, { mode: 0o700 }); await this.syncDirectory(root); } catch (error) { if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error; } }
    const info = await lstat(path).catch(() => undefined);
    if (!info) throw new GatewayError("not_found", "Recording was not found");
    const actual = await realpath(path);
    if (!info.isDirectory() || info.isSymbolicLink() || dirname(actual) !== root || info.uid !== process.getuid?.() || (info.mode & 0o022) !== 0) throw new GatewayError("conflict", "Recording path escaped its owned directory");
    return actual;
  }
  private async syncDirectory(path: string): Promise<void> {
    const handle = await open(path, "r");
    try { await handle.sync(); } finally { await handle.close(); }
  }
  private async segmentsDirectory(folder: string, create: boolean): Promise<string> {
    const path = join(folder, "segments");
    if (create) {
      try { await mkdir(path, { mode: 0o700 }); await this.syncDirectory(folder); }
      catch (error) { if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error; }
    }
    const info = await lstat(path);
    const actual = await realpath(path);
    if (!info.isDirectory() || info.isSymbolicLink() || actual !== path || info.uid !== process.getuid?.() || (info.mode & 0o022) !== 0) throw new GatewayError("conflict", "Recording segments directory is not safely owned");
    return actual;
  }
  private async openOwnedFile(parent: string, name: string, maximumBytes: number): Promise<FileHandle> {
    const path = join(parent, name);
    const handle = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
    try {
      const info = await handle.stat();
      if (!info.isFile() || info.uid !== process.getuid?.() || (info.mode & 0o022) !== 0 || info.size > maximumBytes) throw new GatewayError("conflict", "Recording file is not safely owned or exceeds its bound");
      return handle;
    } catch (error) { await handle.close(); throw error; }
  }
  private async readOwnedJson<T>(parent: string, name: string, maximumBytes: number): Promise<T> {
    const handle = await this.openOwnedFile(parent, name, maximumBytes);
    try { return JSON.parse(await handle.readFile("utf8")) as T; }
    finally { await handle.close(); }
  }
  private async readOptionalOwnedJson<T>(parent: string, name: string, maximumBytes: number): Promise<T | undefined> {
    try { return await this.readOwnedJson<T>(parent, name, maximumBytes); }
    catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined; throw error; }
  }
  private async hashOwnedAudio(segments: string, name: string): Promise<{ size: number; sha256: string }> {
    const handle = await this.openOwnedFile(segments, name, MAX_RECORDING_SEGMENT_BYTES);
    const hash = createHash("sha256"); let size = 0;
    try {
      for await (const chunk of handle.createReadStream({ autoClose: false })) { size += chunk.length; hash.update(chunk); }
      return { size, sha256: hash.digest("hex") };
    } finally { await handle.close(); }
  }
  private async serialize<T>(id: string, operation: () => Promise<T>): Promise<T> {
    const prior = this.locks.get(id) ?? Promise.resolve();
    let release!: () => void;
    const current = new Promise<void>(resolve => { release = resolve; });
    const tail = prior.then(() => current);
    this.locks.set(id, tail);
    await prior;
    try { return await operation(); } finally { release(); if (this.locks.get(id) === tail) this.locks.delete(id); }
  }
  private async manifest(folder: string, expectedId: string): Promise<RecordingManifest> {
    try { const value = await this.readOwnedJson<RecordingManifest>(folder, "recording.json", 4_096);
      if (Object.keys(value).sort().join(",") !== "createdAt,destinationId,recordingId,schemaVersion,sourceDeviceId" || value.schemaVersion !== 1 || value.recordingId !== expectedId || !boundedText(value.sourceDeviceId, 128) || value.destinationId !== this.destinationId || !validDate(value.createdAt)) throw new Error("invalid");
      return value;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") throw new GatewayError("not_found", "Recording was not found");
      if (error instanceof SyntaxError || error instanceof Error && error.message === "invalid") throw new GatewayError("conflict", "Recording manifest is invalid");
      throw error;
    }
  }
  private async ensureManifest(folder: string, id: string, deviceId: string): Promise<RecordingManifest> {
    const path = join(folder, "recording.json");
    try {
      const existing = await this.manifest(folder, id);
      if (existing.sourceDeviceId !== deviceId) throw new GatewayError("conflict", "Recording belongs to another paired device");
      return existing;
    } catch (error) {
      if (!(error instanceof GatewayError && error.code === "not_found")) throw error;
      try { await lstat(path); throw error; } catch (missing) { if ((missing as NodeJS.ErrnoException).code !== "ENOENT") throw missing; }
    }
    const manifest = { schemaVersion: 1 as const, recordingId: id, sourceDeviceId: deviceId, destinationId: this.destinationId, createdAt: new Date().toISOString() };
    await durableAtomicWriteJson(path, manifest);
    return manifest;
  }
  async acceptSegment(id: string, number: number, size: number, sha256: string, deviceId: string, body: AsyncIterable<Uint8Array>): Promise<SegmentReceipt> {
    validateId(id);
    if (!Number.isSafeInteger(number) || number < 1 || number > MAX_RECORDING_SEGMENTS || !Number.isSafeInteger(size) || size < 1 || size > MAX_RECORDING_SEGMENT_BYTES || !SHA256.test(sha256)) throw new GatewayError("invalid_request", "Segment identity, size, or SHA-256 is invalid");
    return this.serialize(id, async () => {
      if (this.activeBodies >= 4) throw new GatewayError("busy", "Recording upload capacity is full", true);
      this.activeBodies++;
      this.reservedBytes += size;
      try {
      const folder = await this.folder(id, true);
      await this.ensureManifest(folder, id, deviceId);
      const segments = await this.segmentsDirectory(folder, true);
      const metadataPath = join(segments, `${String(number).padStart(6, "0")}.json`);
      try {
        const prior = await this.readOwnedJson<SegmentReceipt>(segments, `${String(number).padStart(6, "0")}.json`, 2_048);
        if (!isSegmentReceipt(prior, id, number)) throw new GatewayError("conflict", "Stored segment receipt is invalid");
        if (prior.size !== size || prior.sha256 !== sha256) throw new GatewayError("conflict", "Segment identity was already admitted with different content");
        const replayHash = createHash("sha256"); let replayBytes = 0;
        for await (const chunk of body) { const bytes = Buffer.from(chunk); replayBytes += bytes.length; if (replayBytes > size) throw new GatewayError("invalid_request", "Segment exceeded its declared size"); replayHash.update(bytes); }
        if (replayBytes !== size || replayHash.digest("hex") !== sha256) throw new GatewayError("conflict", "Segment replay did not match its declared length and SHA-256");
        const stored = await this.hashOwnedAudio(segments, `${String(number).padStart(6, "0")}.audio`);
        if (stored.size !== size || stored.sha256 !== sha256) throw new GatewayError("conflict", "Previously accepted segment failed durable integrity verification");
        return prior;
      } catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
      try { await lstat(join(folder, "commit.json")); throw new GatewayError("conflict", "Recording is already finalized"); }
      catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
      const root = await this.recordingsRoot(true);
      const available = await (this.options.availableDiskBytes ?? (async (path: string) => { const value = await statfs(path); return value.bavail * value.bsize; }))(root);
      if (available - this.reservedBytes < (this.options.minimumFreeBytes ?? MINIMUM_FREE_BYTES)) throw new GatewayError("busy", "Recording storage is preserving the Mac free-space floor", true, { reason: "disk", availableBytes: available });

      // A process crash may leave only an unacknowledged `.part` request body;
      // under this recording's lock it is safe to reclaim before retrying.
      for (const entry of await readdir(segments)) if (entry.endsWith(".part")) await import("node:fs/promises").then(({ rm }) => rm(join(segments, entry), { force: true }));
      const finalPath = join(segments, `${String(number).padStart(6, "0")}.audio`);
      const tempPath = `${finalPath}.${process.pid}.part`;
      const handle = await open(tempPath, "wx", 0o600);
      const hash = createHash("sha256"); let received = 0;
      try {
        for await (const chunk of body) {
          const bytes = Buffer.from(chunk); received += bytes.length;
          if (received > size || received > MAX_RECORDING_SEGMENT_BYTES) throw new GatewayError("invalid_request", "Segment exceeded its declared size");
          hash.update(bytes); let offset = 0;
          while (offset < bytes.length) { const result = await handle.write(bytes, offset); if (!result.bytesWritten) throw new Error("short recording write"); offset += result.bytesWritten; }
        }
        if (received !== size || hash.digest("hex") !== sha256) throw new GatewayError("conflict", "Segment length or SHA-256 did not match the request");
        await handle.sync();
      } catch (error) { await handle.close(); await import("node:fs/promises").then(({ rm }) => rm(tempPath, { force: true })); throw error; }
      await handle.close(); await chmod(tempPath, 0o400); await rename(tempPath, finalPath);
      const segmentReceipt: SegmentReceipt = { schemaVersion: 1, recordingId: id, segment: number, size, sha256, acceptedAt: new Date().toISOString() };
      await durableAtomicWriteJson(metadataPath, segmentReceipt);
      const dirHandle = await open(segments, "r"); try { await dirHandle.sync(); } finally { await dirHandle.close(); }
      const parent = await open(folder, "r"); try { await parent.sync(); } finally { await parent.close(); }
      return segmentReceipt;
      } finally { this.activeBodies--; this.reservedBytes -= size; }
    });
  }
  async finalize(id: string, deviceId: string, requested: { segmentCount: number; capture: RecordingCaptureMetadata }): Promise<RecordingReceipt> {
    validateId(id);
    if (!Number.isSafeInteger(requested.segmentCount) || requested.segmentCount < 1 || requested.segmentCount > MAX_RECORDING_SEGMENTS) throw new GatewayError("invalid_request", "Final segment count is invalid");
    const capture = validateCapture(requested.capture);
    if (capture.timeline.length !== requested.segmentCount) throw new GatewayError("invalid_request", "Timeline must describe every ordered segment");
    return this.serialize(id, async () => {
      const folder = await this.folder(id);
      const manifest = await this.manifest(folder, id);
      if (manifest.sourceDeviceId !== deviceId) throw new GatewayError("conflict", "Recording belongs to another paired device");
      const commitPath = join(folder, "commit.json");
      const existing = await this.readOptionalOwnedJson<RecordingReceipt>(folder, "commit.json", 128 * 1_024);
      const aggregate = createHash("sha256"); let totalBytes = 0;
      const segments = await this.segmentsDirectory(folder, false);
      const sidecars = (await readdir(segments)).filter(file => /^\d{6}\.json$/.test(file));
      if (sidecars.length !== requested.segmentCount) throw new GatewayError("conflict", "Final segment count does not match the complete admitted set");
      for (let number = 1; number <= requested.segmentCount; number++) {
        const stem = String(number).padStart(6, "0");
        let segment: SegmentReceipt;
        try { segment = await this.readOwnedJson<SegmentReceipt>(segments, `${stem}.json`, 2_048); }
        catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT" || error instanceof SyntaxError) throw new GatewayError("conflict", `Recording segment ${number} is missing or invalid`); throw error; }
        if (!isSegmentReceipt(segment, id, number)) throw new GatewayError("conflict", "Recording segment receipt is invalid");
        const actual = await this.hashOwnedAudio(segments, `${stem}.audio`);
        if (actual.size !== segment.size || actual.sha256 !== segment.sha256) throw new GatewayError("conflict", `Recording segment ${number} failed integrity verification`);
        aggregate.update(Buffer.from(`${number}:${segment.sha256}:${segment.size}\n`)); totalBytes += segment.size;
      }
      const receipt: RecordingReceipt = { schemaVersion: 1, recordingId: id, destinationId: this.destinationId, sourceDeviceId: deviceId, finalizedAt: new Date().toISOString(), contentSha256: aggregate.digest("hex"), totalBytes, segmentCount: requested.segmentCount, capture };
      if (existing) {
        const prior = existing;
        if (prior.contentSha256 !== receipt.contentSha256 || prior.segmentCount !== receipt.segmentCount || JSON.stringify(prior.capture) !== JSON.stringify(capture)) throw new GatewayError("conflict", "Recording has already been finalized with different content or metadata");
        return prior;
      }
      await durableAtomicWriteJson(commitPath, receipt);
      const directory = await open(folder, "r"); try { await directory.sync(); } finally { await directory.close(); }
      return receipt;
    });
  }
  async status(id: string, deviceId: string, offset: number, limit: number): Promise<{ recordingId: string; finalized: boolean; receipt?: RecordingReceipt; segments: SegmentReceipt[]; nextOffset: number | null }> {
    validateId(id);
    if (!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(limit) || limit < 1 || limit > RECORDING_PAGE_LIMIT) throw new GatewayError("invalid_request", "Recording page bounds are invalid");
    return this.serialize(id, async () => {
      const folder = await this.folder(id); const manifest = await this.manifest(folder, id);
      if (manifest.sourceDeviceId !== deviceId) throw new GatewayError("not_found", "Recording was not found");
      const root = await this.segmentsDirectory(folder, false).catch(error => { if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined; throw error; });
      const files = root ? await readdir(root) : [];
      const numbers = files.filter(file => /^\d{6}\.json$/.test(file)).map(file => Number(file.slice(0, 6))).sort((a, b) => a - b);
      const selected = numbers.slice(offset, offset + limit); const segments: SegmentReceipt[] = [];
      for (const number of selected) {
        const item = await this.readOwnedJson<unknown>(root!, `${String(number).padStart(6, "0")}.json`, 2_048);
        if (!isSegmentReceipt(item, id, number)) throw new GatewayError("conflict", "Stored recording segment receipt is invalid");
        segments.push(item);
      }
      const receipt = await this.readOptionalOwnedJson<RecordingReceipt>(folder, "commit.json", 128 * 1_024);
      return { recordingId: id, finalized: !!receipt, ...(receipt ? { receipt } : {}), segments, nextOffset: offset + selected.length < numbers.length ? offset + selected.length : null };
    });
  }
}
