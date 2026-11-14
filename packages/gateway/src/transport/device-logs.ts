import { createHash } from "node:crypto";
import { chmodSync, closeSync, lstatSync, mkdirSync, openSync, readSync, statSync } from "node:fs";
import { join } from "node:path";
import { GatewayError } from "../errors.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { RotatingJsonl } from "./rotating-jsonl.js";

export const DEVICE_LOG_MAX_APPEND_BYTES = 256 * 1_024;
export const DEVICE_LOG_MAX_APPEND_LINES = 256;
export const DEVICE_LOG_MAX_LINE_BYTES = 16 * 1_024;
const SEGMENT_BYTES = 5 * 1_024 * 1_024;
const SEGMENT_COUNT = 4;
const TAIL_BYTES = 2 * DEVICE_LOG_MAX_LINE_BYTES;
const BOOT_ID = /^[A-Za-z0-9._-]{8,64}$/;

export interface DeviceLogCursor {
  bootId: string | null;
  sequence: number;
}

interface DeviceLogAppend {
  bootId: string;
  firstSequence: number;
  records: Record<string, unknown>[];
}

interface Envelope {
  bootId: string;
  sequence: number;
  record: Record<string, unknown>;
}

interface Stream {
  log: RotatingJsonl;
  cursor: DeviceLogCursor;
  torn: boolean;
}

function invalid(message: string): GatewayError {
  return new GatewayError("invalid_request", message);
}

export function parseDeviceLogAppend(value: unknown): DeviceLogAppend {
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw invalid("Device log append requires an object");
  const { bootId, firstSequence, lines } = value as Record<string, unknown>;
  if (typeof bootId !== "string" || !BOOT_ID.test(bootId)) throw invalid("bootId is invalid");
  if (!Number.isSafeInteger(firstSequence) || (firstSequence as number) < 1) throw invalid("firstSequence must be a positive integer");
  if (!Array.isArray(lines) || lines.length < 1 || lines.length > DEVICE_LOG_MAX_APPEND_LINES) {
    throw invalid(`lines must hold 1 to ${DEVICE_LOG_MAX_APPEND_LINES} records`);
  }
  let bytes = 0;
  const records = lines.map((entry: unknown) => {
    if (typeof entry !== "string") throw invalid("each log record must be a string");
    const size = Buffer.byteLength(entry);
    if (size === 0 || size > DEVICE_LOG_MAX_LINE_BYTES) throw invalid("a log record is empty or exceeds 16 KiB");
    if (/[\r\n]/.test(entry)) throw invalid("a log record must be one line");
    bytes += size;
    if (bytes > DEVICE_LOG_MAX_APPEND_BYTES) throw invalid("the log batch exceeds 256 KiB");
    let parsed: unknown;
    try {
      parsed = JSON.parse(entry);
    } catch {
      throw invalid("a log record is not JSON");
    }
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) throw invalid("a log record must be a JSON object");
    return parsed as Record<string, unknown>;
  });
  return { bootId, firstSequence: firstSequence as number, records };
}

function envelopeCursor(text: string): DeviceLogCursor | undefined {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return undefined;
  }
  if (parsed === null || typeof parsed !== "object") return undefined;
  const envelope = parsed as Partial<Envelope>;
  if (typeof envelope.bootId !== "string" || !Number.isSafeInteger(envelope.sequence)) return undefined;
  return { bootId: envelope.bootId, sequence: envelope.sequence as number };
}

function assertPrivateFile(path: string): void {
  let stat;
  try {
    stat = lstatSync(path);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return;
    throw error;
  }
  if (!stat.isFile() || stat.isSymbolicLink() || stat.uid !== process.getuid?.()) {
    throw new GatewayError("conflict", "Device log storage is not private", true);
  }
}

export class DeviceLogStore {
  private readonly mutex = new AsyncMutex();
  private readonly streams = new Map<string, Stream>();

  constructor(private readonly directory: string) {}

  cursor(deviceId: string): Promise<DeviceLogCursor> {
    return this.mutex.run(() => ({ ...this.stream(deviceId).cursor }));
  }

  append(deviceId: string, input: unknown): Promise<DeviceLogCursor> {
    return this.mutex.run(() => this.appendLocked(deviceId, parseDeviceLogAppend(input)));
  }

  private appendLocked(deviceId: string, append: DeviceLogAppend): DeviceLogCursor {
    const stream = this.stream(deviceId);
    const held = stream.cursor;
    const sameBoot = held.bootId === append.bootId;
    if (sameBoot && append.firstSequence > held.sequence + 1) {
      throw new GatewayError("invalid_request", "Device log batch leaves a gap after the held cursor", false, held);
    }
    const startIndex = sameBoot ? Math.max(0, held.sequence + 1 - append.firstSequence) : 0;
    if (startIndex >= append.records.length) return { ...held };
    try {
      let sequence = append.firstSequence + startIndex;
      for (const record of append.records.slice(startIndex)) {
        const envelope: Envelope = { bootId: append.bootId, sequence, record };
        stream.log.appendChecked(envelope, stream.torn);
        stream.torn = false;
        sequence += 1;
      }
    } catch {
      this.streams.delete(deviceId);
      throw new GatewayError("conflict", "Device log could not be written", true);
    }
    stream.cursor = { bootId: append.bootId, sequence: append.firstSequence + append.records.length - 1 };
    return { ...stream.cursor };
  }

  private stream(deviceId: string): Stream {
    const existing = this.streams.get(deviceId);
    if (existing) return existing;
    this.ensureDirectory();
    const path = join(this.directory, `${createHash("sha256").update(deviceId).digest("hex").slice(0, 32)}.jsonl`);
    const log = new RotatingJsonl(path, SEGMENT_BYTES, SEGMENT_COUNT);
    const stream: Stream = { log, ...this.readTail(log) };
    this.streams.set(deviceId, stream);
    return stream;
  }

  private ensureDirectory(): void {
    mkdirSync(this.directory, { recursive: true, mode: 0o700 });
    const stat = lstatSync(this.directory);
    if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== process.getuid?.()) {
      throw new GatewayError("conflict", "Device log storage is not private", true);
    }
    chmodSync(this.directory, 0o700);
  }

  private readTail(log: RotatingJsonl): { cursor: DeviceLogCursor; torn: boolean } {
    let torn = false;
    for (let index = 0; index < SEGMENT_COUNT; index += 1) {
      const path = log.segmentPath(index);
      assertPrivateFile(path);
      let size: number;
      try {
        size = statSync(path).size;
      } catch {
        continue;
      }
      const text = readTailText(path, size);
      if (index === 0) torn = size > 0 && !text.endsWith("\n");
      const lines = text.split("\n");
      for (const entry of lines.reverse()) {
        const cursor = envelopeCursor(entry);
        if (cursor) return { cursor, torn };
      }
    }
    return { cursor: { bootId: null, sequence: 0 }, torn };
  }
}

function readTailText(path: string, size: number): string {
  const length = Math.min(size, TAIL_BYTES);
  const buffer = Buffer.alloc(length);
  const descriptor = openSync(path, "r");
  try {
    readSync(descriptor, buffer, 0, length, size - length);
  } finally {
    closeSync(descriptor);
  }
  return buffer.toString("utf8");
}
