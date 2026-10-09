import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { open } from "node:fs/promises";
import { redactCredentials } from "../util/credential-redaction.js";
import {
  EpisodicMemoryError, EPISODIC_OMITTED_TEXT,
  type EpisodicLimits, type EpisodicMessageKind, type EpisodicSourceCursor,
} from "./episodic-contract.js";
import { capText } from "./episodic-tree.js";

/*
 * Canonical session JSONL is read by a bounded reader that can never repair,
 * migrate or rewrite it. `readCanonicalSession` reads one whole file and follows
 * the branch from the last complete entry to the root through parentId. Home's
 * source (`home-source.ts`) owns the cursor-proven incremental reads. The
 * SDK's `SessionManager.open` is deliberately not used: it migrates.
 */

/** The pinned SDK's current session file version. A newer file is refused
 * rather than guessed at. */
const SUPPORTED_SESSION_VERSION = 3;
/** How many bytes before a cursor's offset Home's source re-reads to prove the
 * prefix is the one it read last time. */
const PREFIX_WINDOW_BYTES = 8 * 1_024;
export const COMPLETE_PREFIX_SEED = createHash("sha256").update("tron-episodic-prefix-v1").digest("hex");

/** A failed parse of a source whose snapshot could not be proven stable. */
export class EpisodicSourceChangedError extends Error {
  constructor() {
    super("Canonical session changed while it was being read");
    this.name = "EpisodicSourceChangedError";
  }
}

function sameSnapshot(start: Awaited<ReturnType<import("node:fs/promises").FileHandle["stat"]>>, end: Awaited<ReturnType<import("node:fs/promises").FileHandle["stat"]>>): boolean {
  return start.dev === end.dev && start.ino === end.ino && start.size === end.size
    && start.mtimeMs === end.mtimeMs && start.ctimeMs === end.ctimeMs;
}

export interface EpisodicCanonicalEntry {
  id: string;
  parentId: string | null;
  timestamp: string;
  type: string;
  raw: Record<string, unknown>;
  /** Physical provenance when a stable Home source spans chapters. */
  sourceSessionId?: string;
  /** The exact JSON text of the entry's line, without its newline. */
  line: string;
}

/** One read of a canonical session file: its current branch, root first. */
export interface EpisodicCanonicalBranch {
  branch: EpisodicCanonicalEntry[];
  /** Bytes of a trailing partial line that were ignored. */
  tornBytes: number;
}

/** One chapter-ordered delta of Home's canonical source, already projected: the
 * memory never receives raw JSONL. A full branch refresh of one physical chapter
 * sets `scopeSessionId`, so only that chapter's entries can be marked off-branch. */
export interface EpisodicSourceDelta {
  sessionId: string;
  projected: EpisodicProjectedMessage[];
  /** Bytes of complete lines; a trailing partial line is not counted. */
  completeBytes: number;
  leafEntryId: string | null;
  cursor: EpisodicSourceCursor;
  /** True when this delta continued from the previous cursor. */
  incremental: boolean;
  scopeSessionId?: string;
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : undefined;
}

interface LineBatch {
  lines: string[];
  tornBytes: number;
}

/** Read complete lines from the start of the file, bounded per line. A line's reads
 * are kept as pieces and joined once, as in the Home source's reader, because a
 * canonical line can be tens of megabytes. */
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

/** The digest of the last complete non-blank line before `offset`, read from a
 * small window. `undefined` when the window cannot prove it. */
export async function prefixLineDigest(handle: { read(buffer: Buffer, offset: number, length: number, position: number): Promise<{ bytesRead: number }> }, offset: number): Promise<string | undefined> {
  if (offset <= 1) return undefined;
  const start = Math.max(0, offset - PREFIX_WINDOW_BYTES);
  const buffer = Buffer.alloc(offset - start);
  let filled = 0;
  while (filled < buffer.length) {
    const read = await handle.read(buffer, filled, buffer.length - filled, start + filled);
    if (read.bytesRead === 0) break;
    filled += read.bytesRead;
  }
  const text = buffer.subarray(0, filled).toString("utf8");
  const lines = text.split("\n");
  // The window ends at a line boundary, so its last element is the empty tail.
  for (let index = lines.length - 2; index >= 0; index -= 1) {
    const line = lines[index]!;
    if (line.trim() === "") continue;
    return digest(line);
  }
  return undefined;
}

/**
 * Read one canonical session file with bounded lines. A trailing partial line
 * (a crash mid-write, or a live writer) is ignored and reported, never parsed;
 * a complete line that is not a well-formed entry refuses the read.
 */
export async function readCanonicalSession(options: {
  path: string;
  sessionId: string;
  maxLineBytes: number;
}): Promise<EpisodicCanonicalBranch> {
  const handle = await open(options.path, constants.O_RDONLY).catch((error: NodeJS.ErrnoException) => {
    throw new EpisodicMemoryError("source", `Canonical session ${options.path} cannot be read: ${error.code ?? error.message}`);
  });
  let start: Awaited<ReturnType<typeof handle.stat>> | undefined;
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

/**
 * Visit every complete entry of one canonical file in file order, one line at a
 * time, so the visitor decides what survives: nothing is batched. Refuses what the
 * whole-file reader refuses (header, torn tail, over-long line), and a file that
 * shrinks while it is read. Reads only the bytes present when it began.
 */
export async function visitCanonicalSessionEntries(options: {
  path: string;
  sessionId: string;
  maxLineBytes: number;
  visit: (entry: EpisodicCanonicalEntry) => void;
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
        if (newline > options.maxLineBytes) throw new EpisodicMemoryError("source", `Canonical session line exceeds ${options.maxLineBytes} bytes`);
        accept(chunk.subarray(0, newline));
        chunk = chunk.subarray(newline + 1);
      }
      if (chunk.length > options.maxLineBytes) throw new EpisodicMemoryError("source", `Canonical session line exceeds ${options.maxLineBytes} bytes`);
      pending = Buffer.from(chunk);
    }
    if (pending.length > 0) throw new EpisodicMemoryError("source", "Canonical session has an incomplete tail");
    if (!headerSeen) throw new EpisodicMemoryError("source", "Canonical session file is empty");
  } finally { await handle.close(); }
}

interface WholeFile {
  batch: LineBatch;
  /** Every complete entry, in file order. */
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

/**
 * Read every complete entry of one canonical file, after checking the header this
 * reader supports. Both the branch walk and the by-id instant read prove the file
 * the same way, so neither can accept a file the other would refuse.
 */
async function readWholeFile(
  handle: { read(buffer: Buffer, offset: number, length: number, position: number): Promise<{ bytesRead: number }> },
  options: { path: string; sessionId: string; maxLineBytes: number; endBytes?: number },
): Promise<WholeFile> {
  const batch = await readLines(handle, options.maxLineBytes, options.endBytes);
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

/** Exact file-wide evidence for cold owners. Unlike a model branch, immutable
 * report addresses survive navigation. Refuse torn/changed graphs; never open
 * the SDK's repairing/migrating SessionManager just to inspect evidence. */
export async function readCanonicalSessionFile(options: {
  path: string; sessionId: string; maxLineBytes: number;
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
    if (!sameSnapshot(start, await handle.stat())) throw new EpisodicSourceChangedError();
    return entries;
  } finally { await handle.close(); }
}

export interface EpisodicProjectedMessage {
  entryId: string;
  sourceSessionId?: string;
  kind: EpisodicMessageKind;
  text: string;
  /** The canonical entry's instant, carried so the catalog can answer a
   * message's date without reading the source again. */
  timestamp: string;
  sourceDigest: string;
  projectedDigest: string;
  omissions: string[];
  omitted: boolean;
}

function digest(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

/** One digest rule for every persisted record. */
export const episodicDigest = digest;

function parts(content: unknown): Array<Record<string, unknown>> {
  if (typeof content === "string") return [{ type: "text", text: content }];
  if (!Array.isArray(content)) return [];
  return content.flatMap(part => {
    const record = asRecord(part);
    return record ? [record] : [];
  });
}

/** Text and image parts; anything else is named, never forwarded. */
function projectContent(content: unknown, omissions: string[]): string {
  const lines: string[] = [];
  for (const part of parts(content)) {
    if (part.type === "text" && typeof part.text === "string") lines.push(part.text);
    else if (part.type === "image") {
      omissions.push("attachment");
      lines.push(`[image: ${typeof part.mimeType === "string" ? part.mimeType : "unknown"}]`);
    } else if (part.type !== "text") omissions.push("unsupported-part");
  }
  return lines.join("\n");
}

/** Assistant content: text and tool calls; thinking is excluded and recorded
 * (gist §2 logs no thoughts, and the compactor refused them). */
function projectAssistantContent(content: unknown, omissions: string[], limits: EpisodicLimits): string {
  const lines: string[] = [];
  for (const part of parts(content)) {
    if (part.type === "text" && typeof part.text === "string") lines.push(part.text);
    else if (part.type === "thinking") omissions.push("thinking");
    else if (part.type === "toolCall" && typeof part.name === "string") {
      const args = JSON.stringify(part.arguments ?? {});
      const capped = capText(args, limits.capChars, limits.capTailChars);
      if (capped.capped) omissions.push("capped");
      lines.push(`[call ${part.name} ${capped.text}]`);
    } else if (part.type === "image") {
      omissions.push("attachment");
      lines.push(`[image: ${typeof part.mimeType === "string" ? part.mimeType : "unknown"}]`);
    } else omissions.push("unsupported-part");
  }
  return lines.join("\n");
}

interface ProjectedContent {
  kind: EpisodicMessageKind;
  text: string;
  omissions: string[];
}

function projectEntry(entry: EpisodicCanonicalEntry, edit: Record<string, unknown> | undefined, limits: EpisodicLimits): ProjectedContent | undefined {
  if (entry.type === "message") {
    const message = asRecord(entry.raw.message);
    if (!message) return undefined;
    const role = message.role;
    const content = edit === undefined ? message.content : asRecord(edit.replacement)?.content;
    const omissions: string[] = [];
    if (role === "user") return { kind: "user", text: projectContent(content, omissions), omissions };
    if (role === "assistant") return { kind: "talk", text: projectAssistantContent(content, omissions, limits), omissions };
    if (role === "toolResult") {
      const name = typeof message.toolName === "string" ? message.toolName : "unknown";
      const capped = capText(projectContent(content, omissions), limits.capChars, limits.capTailChars);
      if (capped.capped) omissions.push("capped");
      return { kind: "echo", text: `tool ${name}: ${capped.text}`, omissions };
    }
    return undefined;
  }
  if (entry.type === "custom_message") {
    if (entry.raw.display !== true) return undefined;
    const content = edit === undefined ? entry.raw.content : asRecord(edit.replacement)?.content;
    const omissions: string[] = [];
    return { kind: "event", text: projectContent(content, omissions), omissions };
  }
  return undefined;
}

/**
 * Project every projectable entry of the branch, in branch order, at most one
 * message each. Context edits replace their target's content without
 * renumbering anything; a null replacement makes the message `[omitted]`.
 *
 * Credentials are the one shared credential-only rule set
 * (`redactCredentials`), never the process preview's rule set: the memory must
 * keep file paths and ordinary identifiers readable.
 */
export function projectBranch(branch: readonly EpisodicCanonicalEntry[], limits: EpisodicLimits): EpisodicProjectedMessage[] {
  const edits = new Map<string, Record<string, unknown>>();
  for (const entry of branch) {
    if (entry.type !== "context_edit" || typeof entry.raw.targetId !== "string") continue;
    edits.set(entry.raw.targetId, entry.raw);
  }
  const projected: EpisodicProjectedMessage[] = [];
  for (const entry of branch) {
    if (entry.type === "context_edit") continue;
    const edit = edits.get(entry.id);
    const replacement = edit === undefined ? undefined : asRecord(edit.replacement);
    const omissions: string[] = [];
    let text: string;
    let kind: EpisodicMessageKind = "user";
    let omitted = false;
    if (edit !== undefined && (edit.replacement === null || replacement === undefined)) {
      // A null edit only omits an entry that is a message in its own right: a
      // hidden custom message or a state entry never held a slot to begin with.
      const base = projectEntry(entry, undefined, limits);
      if (!base) continue;
      kind = base.kind;
      text = EPISODIC_OMITTED_TEXT;
      omissions.push("context-edit");
      omitted = true;
    } else {
      const content = projectEntry(entry, edit, limits);
      if (!content) continue;
      kind = content.kind;
      omissions.push(...content.omissions);
      if (edit !== undefined) omissions.push("context-edit");
      text = content.text;
    }
    // A projectable entry always holds a message slot, even when its own text
    // is empty (an all-thinking reply, an empty paste): dropping the slot would
    // renumber every later message, and indices are permanent. It becomes the
    // same `[omitted]` free node a null context edit produces.
    if (text === "") {
      text = EPISODIC_OMITTED_TEXT;
      omissions.push("empty");
      omitted = true;
    }
    if (!omitted) {
      // The recipe sends user and assistant text whole; a memory record must
      // still fit its store's line, so an oversized paste is capped head+tail.
      const capped = capText(text, limits.recordCapChars, limits.capTailChars);
      if (capped.capped) omissions.push("capped");
      text = capped.text;
    }
    const credentials = redactCredentials(text);
    if (credentials !== text) omissions.push("credentials");
    projected.push({
      entryId: entry.id,
      ...(entry.sourceSessionId === undefined ? {} : { sourceSessionId: entry.sourceSessionId }),
      kind,
      text: credentials,
      timestamp: entry.timestamp,
      sourceDigest: digest(entry.line),
      projectedDigest: digest(credentials),
      omissions: [...new Set(omissions)],
      omitted,
    });
  }
  return projected;
}
