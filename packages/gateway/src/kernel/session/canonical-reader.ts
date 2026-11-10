import { createHash } from "node:crypto";
import { constants, type Stats } from "node:fs";
import { lstat, open } from "node:fs/promises";
import { dirname } from "node:path";
import { syncDurably } from "../../foundation/durable-json.js";
import { EpisodicMemoryError } from "../../errors.js";
import { asRecord } from "../../foundation/json.js";
import { CANONICAL_SOURCE_MAX_LINE_BYTES } from "../resources/prompt-bounds.js";

const SUPPORTED_SESSION_VERSION = 3;
const PREFIX_WINDOW_BYTES = 8 * 1_024;
export const COMPLETE_PREFIX_SEED = createHash("sha256").update("tron-episodic-prefix-v1").digest("hex");

export class EpisodicSourceChangedError extends Error {
  constructor() {
    super("Canonical session changed while it was being read");
    this.name = "EpisodicSourceChangedError";
  }
}

export function sameSnapshot(start: Stats, end: Stats): boolean {
  return start.dev === end.dev && start.ino === end.ino && start.size === end.size
    && start.mtimeMs === end.mtimeMs && start.ctimeMs === end.ctimeMs;
}

export interface EpisodicCanonicalEntry {
  id: string;
  parentId: string | null;
  timestamp: string;
  type: string;
  raw: Record<string, unknown>;
  line: string;
}

interface EpisodicCanonicalBranch {
  branch: EpisodicCanonicalEntry[];
  tornBytes: number;
}

interface LineBatch {
  lines: string[];
  tornBytes: number;
}

async function readLines(handle: { read(buffer: Buffer, offset: number, length: number, position: number): Promise<{ bytesRead: number }> }, maxLineBytes: number, endExclusive?: number): Promise<LineBatch> {
  const lines: string[] = [];
  const buffer = Buffer.alloc(1_024 * 1_024);
  let pieces: Buffer[] = [];
  let pendingBytes = 0;
  let offset = 0;
  for (;;) {
    if (endExclusive !== undefined && offset >= endExclusive) break;
    const length = endExclusive === undefined ? buffer.length : Math.min(buffer.length, endExclusive - offset);
    const read = await handle.read(buffer, 0, length, offset);
    if (read.bytesRead === 0) break;
    offset += read.bytesRead;
    const chunk = buffer.subarray(0, read.bytesRead);
    let from = 0;
    let newline = chunk.indexOf(0x0a);
    while (newline >= 0) {
      if (pendingBytes + newline - from > maxLineBytes) throw new EpisodicMemoryError("source", `Canonical session line exceeds ${maxLineBytes} bytes`);
      lines.push(Buffer.concat([...pieces, chunk.subarray(from, newline)]).toString("utf8"));
      pieces = []; pendingBytes = 0;
      from = newline + 1;
      newline = chunk.indexOf(0x0a, from);
    }
    if (pendingBytes + chunk.length - from > maxLineBytes) throw new EpisodicMemoryError("source", `Canonical session line exceeds ${maxLineBytes} bytes`);
    if (from < chunk.length) {
      pieces.push(Buffer.from(chunk.subarray(from)));
      pendingBytes += chunk.length - from;
    }
  }
  return { lines, tornBytes: pendingBytes };
}

export function extendPrefixDigest(prefix: string, lineBytes: Buffer): string {
  return createHash("sha256").update(prefix).update("\\0").update(lineBytes).update("\\n").digest("hex");
}

export function parseEntry(line: string): EpisodicCanonicalEntry {
  let raw: Record<string, unknown>;
  try {
    raw = asRecord(JSON.parse(line)) ?? {};
  } catch {
    throw new EpisodicMemoryError("source", "Canonical session holds a line that is not JSON");
  }
  const id = raw.id;
  const parentId = raw.parentId;
  const timestamp = raw.timestamp;
  if (typeof id !== "string" || (typeof parentId !== "string" && parentId !== null) || typeof timestamp !== "string" || typeof raw.type !== "string") {
    throw new EpisodicMemoryError("source", "Canonical session holds a line that is not a session entry");
  }
  return { id, parentId, timestamp, type: raw.type, raw, line };
}

export async function prefixLineDigest(handle: { read(buffer: Buffer, offset: number, length: number, position: number): Promise<{ bytesRead: number }> }, offset: number, maxLineBytes: number): Promise<string | undefined> {
  if (offset <= 1) return undefined;
  for (let span = Math.min(PREFIX_WINDOW_BYTES, offset); ; span = Math.min(span * 2, offset, maxLineBytes + 2)) {
    const start = offset - span;
    const buffer = Buffer.alloc(span);
    let filled = 0;
    while (filled < span) {
      const read = await handle.read(buffer, filled, span - filled, start + filled);
      if (read.bytesRead === 0) break;
      filled += read.bytesRead;
    }
    const lines = buffer.subarray(0, filled).toString("utf8").split("\n");
    for (let index = lines.length - 2; index >= (start === 0 ? 0 : 1); index -= 1) {
      const line = lines[index]!;
      if (line.trim() !== "") return digest(line);
    }
    if (start === 0 || span >= maxLineBytes + 2) return undefined;
  }
}

export async function readCanonicalSession(options: {
  path: string;
  sessionId: string;
}): Promise<EpisodicCanonicalBranch> {
  const handle = await open(options.path, constants.O_RDONLY).catch((error: NodeJS.ErrnoException) => {
    throw new EpisodicMemoryError("source", `Canonical session ${options.path} cannot be read: ${error.code ?? error.message}`);
  });
  let start: Stats | undefined;
  try {
    const info = start = await handle.stat();
    if (!info.isFile()) throw new EpisodicMemoryError("source", "Canonical session is not a regular file");
    const { batch, entries, byId } = await readWholeFile(handle, options);
    const leaf = entries.at(-1);
    const branch: EpisodicCanonicalEntry[] = [];
    const seen = new Set<string>();
    for (let entry = leaf; entry; entry = entry.parentId === null ? undefined : byId.get(entry.parentId)) {
      if (seen.has(entry.id)) throw new EpisodicMemoryError("source", "Canonical session parent chain is cyclic");
      seen.add(entry.id);
      branch.push(entry);
    }
    return { branch: branch.reverse(), tornBytes: batch.tornBytes };
  } catch (error) {
    if (start && error instanceof EpisodicMemoryError && error.kind === "source") {
      const end = await handle.stat().catch(() => undefined);
      if (!end || !sameSnapshot(start, end)) throw new EpisodicSourceChangedError();
    }
    throw error;
  } finally {
    await handle.close();
  }
}

export async function visitCanonicalSessionEntries(options: {
  path: string;
  sessionId: string;
  visit: (entry: EpisodicCanonicalEntry) => void;
  durable?: true;
}): Promise<void> {
  const handle = await open(options.path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const start = await handle.stat();
    if (!start.isFile()) throw new EpisodicMemoryError("source", "Canonical session is not a regular file");
    const buffer = Buffer.alloc(1_024 * 1_024);
    let pending = Buffer.alloc(0);
    let position = 0;
    let headerSeen = false;
    const accept = (bytes: Buffer): void => {
      const line = bytes.toString("utf8");
      if (!headerSeen) {
        checkSessionHeader(line, options.sessionId);
        headerSeen = true;
      } else if (line.trim() !== "") {
        options.visit(parseEntry(line));
      }
    };
    while (position < start.size) {
      const { bytesRead } = await handle.read(buffer, 0, Math.min(buffer.length, start.size - position), position);
      if (bytesRead === 0) throw new EpisodicSourceChangedError();
      position += bytesRead;
      let chunk = Buffer.concat([pending, buffer.subarray(0, bytesRead)]);
      for (let newline = chunk.indexOf(0x0a); newline >= 0; newline = chunk.indexOf(0x0a)) {
        if (newline > CANONICAL_SOURCE_MAX_LINE_BYTES) throw new EpisodicMemoryError("source", `Canonical session line exceeds ${CANONICAL_SOURCE_MAX_LINE_BYTES} bytes`);
        accept(chunk.subarray(0, newline));
        chunk = chunk.subarray(newline + 1);
      }
      if (chunk.length > CANONICAL_SOURCE_MAX_LINE_BYTES) throw new EpisodicMemoryError("source", `Canonical session line exceeds ${CANONICAL_SOURCE_MAX_LINE_BYTES} bytes`);
      pending = Buffer.from(chunk);
    }
    if (pending.length > 0) throw new EpisodicMemoryError("source", "Canonical session has an incomplete tail");
    if (!headerSeen) throw new EpisodicMemoryError("source", "Canonical session file is empty");
    if (options.durable) {
      await syncDurably(handle);
      const directory = await open(dirname(options.path), constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
      try { await syncDurably(directory); } finally { await directory.close(); }
      const [end, current] = await Promise.all([handle.stat(), lstat(options.path)]);
      if (!sameSnapshot(start, end) || !sameSnapshot(end, current)) throw new EpisodicSourceChangedError();
    }
  } finally { await handle.close(); }
}

interface WholeFile {
  batch: LineBatch;
  entries: EpisodicCanonicalEntry[];
  byId: Map<string, EpisodicCanonicalEntry>;
}

function checkSessionHeader(line: string, sessionId: string): void {
  let header: Record<string, unknown>;
  try {
    header = asRecord(JSON.parse(line)) ?? {};
  } catch {
    throw new EpisodicMemoryError("source", "Canonical session header is not JSON");
  }
  if (header.type !== "session") throw new EpisodicMemoryError("source", "Canonical session header is not a session header");
  if (header.id !== sessionId) throw new EpisodicMemoryError("source", "Canonical session header names a different session");
  if (typeof header.version === "number" && header.version > SUPPORTED_SESSION_VERSION) {
    throw new EpisodicMemoryError("source", `Canonical session version ${header.version} is newer than this Gateway supports`);
  }
}

async function readWholeFile(
  handle: { read(buffer: Buffer, offset: number, length: number, position: number): Promise<{ bytesRead: number }> },
  options: { path: string; sessionId: string; endBytes?: number },
): Promise<WholeFile> {
  const batch = await readLines(handle, CANONICAL_SOURCE_MAX_LINE_BYTES, options.endBytes);
  if (batch.lines.length === 0) throw new EpisodicMemoryError("source", "Canonical session file is empty");
  checkSessionHeader(batch.lines[0]!, options.sessionId);
  const entries: EpisodicCanonicalEntry[] = [];
  const byId = new Map<string, EpisodicCanonicalEntry>();
  for (let index = 1; index < batch.lines.length; index += 1) {
    const line = batch.lines[index]!;
    if (line.trim() === "") continue;
    const entry = parseEntry(line);
    if (byId.has(entry.id)) throw new EpisodicMemoryError("source", `Canonical session repeats entry id ${entry.id}`);
    entries.push(entry);
    byId.set(entry.id, entry);
  }
  return { batch, entries, byId };
}

export async function readCanonicalSessionFile(options: {
  path: string; sessionId: string;
  appendStable?: boolean;
}): Promise<EpisodicCanonicalEntry[]> {
  const handle = await open(options.path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const start = await handle.stat();
    if (!start.isFile()) throw new EpisodicMemoryError("source", "Canonical session is not a regular file");
    const { batch, entries } = await readWholeFile(handle, { ...options, endBytes: start.size });
    if (JSON.parse(batch.lines[0]!).version !== SUPPORTED_SESSION_VERSION) throw new EpisodicMemoryError("source", "Canonical task evidence requires the current session format");
    if (batch.tornBytes) throw new EpisodicMemoryError("source", "Canonical session evidence has an incomplete tail");
    const parents = new Set<string>();
    for (const entry of entries) {
      if (entry.parentId !== null && !parents.has(entry.parentId)) throw new EpisodicMemoryError("source", "Canonical session evidence has a missing parent");
      parents.add(entry.id);
    }
    const end = await handle.stat();
    if (!sameSnapshot(start, end)) {
      if (!options.appendStable || end.dev !== start.dev || end.ino !== start.ino || end.size < start.size) throw new EpisodicSourceChangedError();
      const again = await readWholeFile(handle, { ...options, endBytes: start.size }).catch((error: unknown) => {
        if (error instanceof EpisodicMemoryError && error.kind === "source") throw new EpisodicSourceChangedError();
        throw error;
      });
      if (again.batch.lines.length !== batch.lines.length || again.batch.lines.some((line, index) => line !== batch.lines[index])) {
        throw new EpisodicSourceChangedError();
      }
    }
    return entries;
  } finally { await handle.close(); }
}

function digest(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

export const episodicDigest = digest;
