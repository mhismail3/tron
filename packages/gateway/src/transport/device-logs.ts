import { createHash } from "node:crypto";
import { chmodSync, closeSync, existsSync, lstatSync, mkdirSync, openSync, readFileSync, readSync, statSync } from "node:fs";
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

export const DEVICE_LOG_GAP_REASON = "local-rotation";

export interface DeviceLogGap {
  fromSequence: number;
  reason: typeof DEVICE_LOG_GAP_REASON;
}

interface DeviceLogAppend {
  bootId: string;
  firstSequence: number;
  records: Record<string, unknown>[];
  gap?: DeviceLogGap;
}

interface Envelope {
  bootId: string;
  sequence: number;
  record: Record<string, unknown>;
  gap?: DeviceLogGap;
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
  const { bootId, firstSequence, lines, gapFrom, reason } = value as Record<string, unknown>;
  if (typeof bootId !== "string" || !BOOT_ID.test(bootId)) throw invalid("bootId is invalid");
  if (!Number.isSafeInteger(firstSequence) || (firstSequence as number) < 1) throw invalid("firstSequence must be a positive integer");
  const gap = gapFrom === undefined && reason === undefined ? undefined : parseGap(gapFrom, reason);
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
  return { bootId, firstSequence: firstSequence as number, records, ...(gap ? { gap } : {}) };
}

function parseGap(gapFrom: unknown, reason: unknown): DeviceLogGap {
  if (!Number.isSafeInteger(gapFrom) || (gapFrom as number) < 1) throw invalid("gapFrom must be the held sequence");
  if (reason !== DEVICE_LOG_GAP_REASON) throw invalid("gap reason is not supported");
  return { fromSequence: gapFrom as number, reason: DEVICE_LOG_GAP_REASON };
}

function parseEnvelope(text: string): Envelope | undefined {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return undefined;
  }
  if (parsed === null || typeof parsed !== "object") return undefined;
  const envelope = parsed as Partial<Envelope>;
  if (typeof envelope.bootId !== "string" || !Number.isSafeInteger(envelope.sequence)) return undefined;
  return envelope as Envelope;
}

function sameGap(left: DeviceLogGap | undefined, right: DeviceLogGap | undefined): boolean {
  if (left === undefined || right === undefined) return left === right;
  return left.fromSequence === right.fromSequence && left.reason === right.reason;
}

function envelopeCursor(text: string): DeviceLogCursor | undefined {
  const envelope = parseEnvelope(text);
  return envelope === undefined ? undefined : { bootId: envelope.bootId, sequence: envelope.sequence };
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
  private readonly owners = new Map<string, number>();

  constructor(private readonly directory: string) {}

  cursor(deviceId: string): Promise<DeviceLogCursor> {
    return this.mutex.run(() => ({ ...this.stream(deviceId).cursor }));
  }

  append(deviceId: string, admission: number, input: unknown): Promise<DeviceLogCursor> {
    return this.mutex.run(() => this.appendLocked(deviceId, admission, parseDeviceLogAppend(input)));
  }

  private appendLocked(deviceId: string, admission: number, append: DeviceLogAppend): DeviceLogCursor {
    const stream = this.stream(deviceId);
    const held = stream.cursor;
    const sameBoot = held.bootId === append.bootId;
    const owner = this.owners.get(deviceId) ?? Number.NEGATIVE_INFINITY;
    if (!sameBoot && held.bootId !== null && admission < owner) {
      throw new GatewayError("conflict", "Device log batch came from an older connection; the cursor is unchanged", false, held);
    }
    if (sameBoot && append.firstSequence === 1) {
      const first = firstEnvelopeOf(stream.log, append.bootId);
      if (first === undefined) {
        throw new GatewayError("conflict", "Device log gap metadata for this epoch is no longer retained; the batch is refused", false, held);
      }
      if (!sameGap(first.gap, append.gap)) {
        throw new GatewayError("conflict", "Device log replay does not match the durable gap of its epoch", false, held);
      }
    }
    if (append.gap) {
      if (sameBoot) {
        if (append.firstSequence !== 1) throw invalid("A gap belongs to the first batch of a new epoch");
      } else if (held.bootId === null || append.gap.fromSequence !== held.sequence) {
        throw new GatewayError("conflict", "Device log gap does not match the held cursor", false, held);
      }
    }
    if (!sameBoot && append.firstSequence !== 1) {
      throw new GatewayError("invalid_request", "A new epoch starts at sequence 1", false, held);
    }
    if (sameBoot && append.firstSequence > held.sequence + 1) {
      throw new GatewayError("invalid_request", "Device log batch leaves a gap after the held cursor", false, held);
    }
    this.owners.set(deviceId, Math.max(owner, admission));
    const startIndex = sameBoot ? Math.max(0, held.sequence + 1 - append.firstSequence) : 0;
    if (startIndex >= append.records.length) return { ...held };
    try {
      let sequence = append.firstSequence + startIndex;
      for (const record of append.records.slice(startIndex)) {
        const envelope: Envelope = { bootId: append.bootId, sequence, record, ...(append.gap && sequence === 1 ? { gap: append.gap } : {}) };
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

function firstEnvelopeOf(log: RotatingJsonl, bootId: string): { gap?: DeviceLogGap } | undefined {
  for (let index = 0; index < SEGMENT_COUNT; index += 1) {
    const path = log.segmentPath(index);
    if (!existsSync(path)) continue;
    assertPrivateFile(path);
    const lines = readFileSync(path, "utf8").split("\n");
    for (const entry of lines.reverse()) {
      const envelope = parseEnvelope(entry);
      if (envelope === undefined) continue;
      if (envelope.bootId !== bootId) return undefined;
      if (envelope.sequence === 1) return envelope.gap === undefined ? {} : { gap: envelope.gap };
    }
  }
  return undefined;
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
