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
 * Departure 2 of the brief: the memory reads the canonical session JSONL
 * itself, with a bounded reader that can never repair, migrate or rewrite it.
 * The branch is followed from the last complete entry to the root through
 * parentId. `SessionManager.open` is deliberately not used: it migrates.
 *
 * A read that starts from the previous read's cursor continues at the offset
 * when the file only grew; it falls back to a whole-file read when the identity
 * changed, the file shrank, the line before the offset no longer matches, or the
 * new entries do not chain onto the branch it remembers.
 */

/** The pinned SDK's current session file version. A newer file is refused
 * rather than guessed at. */
const SUPPORTED_SESSION_VERSION = 3;
/** How many bytes before the cursor the incremental reader re-reads to prove the
 * prefix is the one it read last time. */
const PREFIX_WINDOW_BYTES = 8 * 1_024;

export interface EpisodicCanonicalEntry {
  id: string;
  parentId: string | null;
  timestamp: string;
  type: string;
  raw: Record<string, unknown>;
  /** The exact JSON text of the entry's line, without its newline. */
  line: string;
}

export interface EpisodicCanonicalCut {
  sessionId: string;
  /** The current branch, root first. */
  branch: EpisodicCanonicalEntry[];
  /** Bytes of complete lines; a trailing partial line is not counted. */
  completeBytes: number;
  /** Bytes of a trailing partial line that were ignored. */
  tornBytes: number;
  leafEntryId: string | null;
  cursor: EpisodicSourceCursor;
  /** True when this read continued from the previous cursor. */
  incremental: boolean;
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : undefined;
}

interface LineBatch {
  lines: string[];
  completeBytes: number;
  tornBytes: number;
}

/** Read complete lines from `start` to the end of the file, bounded per line. */
async function readLines(handle: { read(buffer: Buffer, offset: number, length: number, position: number): Promise<{ bytesRead: number }> }, start: number, maxLineBytes: number): Promise<LineBatch> {
  const lines: string[] = [];
  const buffer = Buffer.alloc(1_024 * 1_024);
  let pending = Buffer.alloc(0);
  let offset = start;
  let completeBytes = start;
  for (;;) {
    const read = await handle.read(buffer, 0, buffer.length, offset);
    if (read.bytesRead === 0) break;
    offset += read.bytesRead;
    let chunk = Buffer.concat([pending, buffer.subarray(0, read.bytesRead)]);
    let newline = chunk.indexOf(0x0a);
    while (newline >= 0) {
      if (newline > maxLineBytes) throw new EpisodicMemoryError("source", `Canonical session line exceeds ${maxLineBytes} bytes`);
      lines.push(chunk.subarray(0, newline).toString("utf8"));
      completeBytes += newline + 1;
      chunk = chunk.subarray(newline + 1);
      newline = chunk.indexOf(0x0a);
    }
    if (chunk.length > maxLineBytes) throw new EpisodicMemoryError("source", `Canonical session line exceeds ${maxLineBytes} bytes`);
    pending = chunk;
  }
  return { lines, completeBytes, tornBytes: pending.length };
}

function parseEntry(line: string): EpisodicCanonicalEntry {
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

/** The last complete line that is not blank, as read from the file. */
function lastLine(lines: readonly string[]): { line: string; entry: EpisodicCanonicalEntry } | undefined {
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    const line = lines[index]!;
    if (line.trim() === "") continue;
    return { line, entry: parseEntry(line) };
  }
  return undefined;
}

/** Extend the remembered branch with entries read after the cursor. `undefined`
 * means the new entries do not chain onto it and the caller must read the whole
 * file. */
function extendBranch(branch: readonly EpisodicCanonicalEntry[], entries: readonly EpisodicCanonicalEntry[]): EpisodicCanonicalEntry[] | undefined {
  const extended = [...branch];
  const indexById = new Map(extended.map((entry, position) => [entry.id, position]));
  for (const entry of entries) {
    if (indexById.has(entry.id)) return undefined;
    if (entry.parentId === null) {
      extended.length = 0;
      indexById.clear();
    } else {
      const parent = indexById.get(entry.parentId);
      if (parent === undefined) return undefined;
      for (const dropped of extended.splice(parent + 1)) indexById.delete(dropped.id);
    }
    indexById.set(entry.id, extended.length);
    extended.push(entry);
  }
  return extended;
}

/** The digest of the last complete non-blank line before `offset`, read from a
 * small window. `undefined` when the window cannot prove it. */
async function prefixLineDigest(handle: { read(buffer: Buffer, offset: number, length: number, position: number): Promise<{ bytesRead: number }> }, offset: number): Promise<string | undefined> {
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
  /** The previous read's cursor and branch, when this owner has one. */
  previous?: { cursor: EpisodicSourceCursor; branch: readonly EpisodicCanonicalEntry[] };
}): Promise<EpisodicCanonicalCut> {
  const handle = await open(options.path, constants.O_RDONLY).catch((error: NodeJS.ErrnoException) => {
    throw new EpisodicMemoryError("source", `Canonical session ${options.path} cannot be read: ${error.code ?? error.message}`);
  });
  try {
    const info = await handle.stat();
    if (!info.isFile()) throw new EpisodicMemoryError("source", "Canonical session is not a regular file");

    const previous = options.previous;
    if (previous && previous.cursor.dev === info.dev && previous.cursor.ino === info.ino
      && info.size >= previous.cursor.size && info.size >= previous.cursor.completeBytes) {
      const digest = await prefixLineDigest(handle, previous.cursor.completeBytes);
      if (digest !== undefined && digest === previous.cursor.leafLineDigest) {
        const batch = await readLines(handle, previous.cursor.completeBytes, options.maxLineBytes);
        const entries: EpisodicCanonicalEntry[] = [];
        for (const line of batch.lines) {
          if (line.trim() === "") continue;
          entries.push(parseEntry(line));
        }
        const extended = extendBranch(previous.branch, entries);
        if (extended) {
          const end = await handle.stat();
          const tail = lastLine(batch.lines);
          const branchLeaf = extended.at(-1) ?? null;
          return {
            sessionId: options.sessionId,
            branch: extended,
            completeBytes: batch.completeBytes,
            tornBytes: batch.tornBytes,
            leafEntryId: branchLeaf?.id ?? null,
            incremental: true,
            cursor: {
              dev: end.dev, ino: end.ino, size: end.size,
              completeBytes: batch.completeBytes,
              leafEntryId: tail?.entry.id ?? previous.cursor.leafEntryId,
              leafLineDigest: tail ? digestOf(tail.line) : previous.cursor.leafLineDigest,
            },
          };
        }
      }
    }

    const { batch, entries, byId } = await readWholeFile(handle, options);
    const leaf = entries.at(-1);
    const branch: EpisodicCanonicalEntry[] = [];
    const seen = new Set<string>();
    for (let entry = leaf; entry; entry = entry.parentId === null ? undefined : byId.get(entry.parentId)) {
      if (seen.has(entry.id)) throw new EpisodicMemoryError("source", "Canonical session parent chain is cyclic");
      seen.add(entry.id);
      branch.push(entry);
    }
    branch.reverse();
    const end = await handle.stat();
    const tail = lastLine(batch.lines);
    return {
      sessionId: options.sessionId,
      branch,
      completeBytes: batch.completeBytes,
      tornBytes: batch.tornBytes,
      leafEntryId: leaf?.id ?? null,
      incremental: false,
      cursor: {
        dev: end.dev, ino: end.ino, size: end.size,
        completeBytes: batch.completeBytes,
        leafEntryId: tail?.entry.id ?? null,
        leafLineDigest: tail ? digestOf(tail.line) : null,
      },
    };
  } finally {
    await handle.close();
  }
}

interface WholeFile {
  batch: LineBatch;
  /** Every complete entry, in file order. */
  entries: EpisodicCanonicalEntry[];
  byId: Map<string, EpisodicCanonicalEntry>;
}

/**
 * Read every complete entry of one canonical file, after checking the header this
 * reader supports. Both the branch walk and the by-id instant read prove the file
 * the same way, so neither can accept a file the other would refuse.
 */
async function readWholeFile(
  handle: { read(buffer: Buffer, offset: number, length: number, position: number): Promise<{ bytesRead: number }> },
  options: { path: string; sessionId: string; maxLineBytes: number },
): Promise<WholeFile> {
  const batch = await readLines(handle, 0, options.maxLineBytes);
  if (batch.lines.length === 0) throw new EpisodicMemoryError("source", "Canonical session file is empty");
  let header: Record<string, unknown>;
  try {
    header = asRecord(JSON.parse(batch.lines[0]!)) ?? {};
  } catch {
    throw new EpisodicMemoryError("source", "Canonical session header is not JSON");
  }
  if (header.type !== "session") throw new EpisodicMemoryError("source", "Canonical session header is not a session header");
  if (header.id !== options.sessionId) throw new EpisodicMemoryError("source", "Canonical session header names a different session");
  if (typeof header.version === "number" && header.version > SUPPORTED_SESSION_VERSION) {
    throw new EpisodicMemoryError("source", `Canonical session version ${header.version} is newer than this Gateway supports`);
  }
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

/**
 * The instant of every entry the file holds, keyed by entry id: every parsed entry,
 * not only the branch the last entry follows, because an entry that has left the
 * branch is still an entry the source can date. Bounded per line, one read, and it
 * never repairs or migrates the file.
 */
export async function readCanonicalEntryInstants(options: {
  path: string;
  sessionId: string;
  maxLineBytes: number;
}): Promise<Map<string, string>> {
  const handle = await open(options.path, constants.O_RDONLY).catch((error: NodeJS.ErrnoException) => {
    throw new EpisodicMemoryError("source", `Canonical session ${options.path} cannot be read: ${error.code ?? error.message}`);
  });
  try {
    const info = await handle.stat();
    if (!info.isFile()) throw new EpisodicMemoryError("source", "Canonical session is not a regular file");
    const { entries } = await readWholeFile(handle, options);
    return new Map(entries.map(entry => [entry.id, entry.timestamp]));
  } finally {
    await handle.close();
  }
}

export interface EpisodicProjectedMessage {
  entryId: string;
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

function digestOf(line: string): string {
  return digest(line);
}

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
export function projectBranch(cut: EpisodicCanonicalCut, limits: EpisodicLimits): EpisodicProjectedMessage[] {
  const edits = new Map<string, Record<string, unknown>>();
  for (const entry of cut.branch) {
    if (entry.type !== "context_edit" || typeof entry.raw.targetId !== "string") continue;
    edits.set(entry.raw.targetId, entry.raw);
  }
  const projected: EpisodicProjectedMessage[] = [];
  for (const entry of cut.branch) {
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
