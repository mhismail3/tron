import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { open } from "node:fs/promises";
import { redact } from "../transport/logger.js";
import { EpisodicMemoryError, EPISODIC_OMITTED_TEXT, type EpisodicLimits, type EpisodicMessageKind } from "./episodic-contract.js";
import { capText } from "./episodic-tree.js";

/*
 * Departure 2 of the brief: the memory reads the canonical session JSONL
 * itself, with a bounded reader that can never repair, migrate or rewrite it.
 * The branch is followed from the last complete entry to the root through
 * parentId. `SessionManager.open` is deliberately not used: it migrates.
 */

/** The pinned SDK's current session file version. A newer file is refused
 * rather than guessed at. */
const SUPPORTED_SESSION_VERSION = 3;

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
  /** Every complete entry in file order. */
  entries: EpisodicCanonicalEntry[];
  /** The current branch, root first. */
  branch: EpisodicCanonicalEntry[];
  /** Bytes of complete lines; a trailing partial line is not counted. */
  completeBytes: number;
  /** Bytes of a trailing partial line that were ignored. */
  tornBytes: number;
  leafEntryId: string | null;
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : undefined;
}

/**
 * Read one canonical session file with bounded lines. A trailing partial line
 * (a crash mid-write, or a live writer) is ignored and reported, never parsed;
 * a complete line that is not a well-formed entry refuses the read.
 */
export async function readCanonicalSession(options: { path: string; sessionId: string; maxLineBytes: number }): Promise<EpisodicCanonicalCut> {
  const handle = await open(options.path, constants.O_RDONLY).catch((error: NodeJS.ErrnoException) => {
    throw new EpisodicMemoryError("source", `Canonical session ${options.path} cannot be read: ${error.code ?? error.message}`);
  });
  const lines: string[] = [];
  let tornBytes = 0;
  let completeBytes = 0;
  try {
    const info = await handle.stat();
    if (!info.isFile()) throw new EpisodicMemoryError("source", "Canonical session is not a regular file");
    const buffer = Buffer.alloc(1_024 * 1_024);
    let pending = Buffer.alloc(0);
    let offset = 0;
    for (;;) {
      const read = await handle.read(buffer, 0, buffer.length, offset);
      if (read.bytesRead === 0) break;
      offset += read.bytesRead;
      let chunk = Buffer.concat([pending, buffer.subarray(0, read.bytesRead)]);
      let newline = chunk.indexOf(0x0a);
      while (newline >= 0) {
        if (newline > options.maxLineBytes) throw new EpisodicMemoryError("source", `Canonical session line exceeds ${options.maxLineBytes} bytes`);
        const line = chunk.subarray(0, newline).toString("utf8");
        lines.push(line);
        completeBytes += newline + 1;
        chunk = chunk.subarray(newline + 1);
        newline = chunk.indexOf(0x0a);
      }
      if (chunk.length > options.maxLineBytes) throw new EpisodicMemoryError("source", `Canonical session line exceeds ${options.maxLineBytes} bytes`);
      pending = chunk;
    }
    tornBytes = pending.length;
  } finally {
    await handle.close();
  }

  if (lines.length === 0) throw new EpisodicMemoryError("source", "Canonical session file is empty");
  let header: Record<string, unknown>;
  try {
    header = asRecord(JSON.parse(lines[0]!)) ?? {};
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
  for (let index = 1; index < lines.length; index += 1) {
    const line = lines[index]!;
    if (line.trim() === "") continue;
    let raw: Record<string, unknown>;
    try {
      raw = asRecord(JSON.parse(line)) ?? {};
    } catch {
      throw new EpisodicMemoryError("source", `Canonical session line ${index + 1} is not JSON`);
    }
    const id = raw.id;
    const parentId = raw.parentId;
    const timestamp = raw.timestamp;
    if (typeof id !== "string" || (typeof parentId !== "string" && parentId !== null) || typeof timestamp !== "string" || typeof raw.type !== "string") {
      throw new EpisodicMemoryError("source", `Canonical session line ${index + 1} is not a session entry`);
    }
    if (byId.has(id)) throw new EpisodicMemoryError("source", `Canonical session repeats entry id ${id}`);
    const entry: EpisodicCanonicalEntry = { id, parentId, timestamp, type: raw.type, raw, line };
    entries.push(entry);
    byId.set(id, entry);
  }

  const leaf = entries.at(-1);
  const branch: EpisodicCanonicalEntry[] = [];
  const seen = new Set<string>();
  for (let entry = leaf; entry; entry = entry.parentId === null ? undefined : byId.get(entry.parentId)) {
    if (seen.has(entry.id)) throw new EpisodicMemoryError("source", "Canonical session parent chain is cyclic");
    seen.add(entry.id);
    branch.push(entry);
  }
  branch.reverse();
  return { sessionId: options.sessionId, entries, branch, completeBytes, tornBytes, leafEntryId: leaf?.id ?? null };
}

export interface EpisodicProjectedMessage {
  entryId: string;
  kind: EpisodicMessageKind;
  text: string;
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
 * Redaction is the Gateway's one rule set (transport/logger's `redact`), the
 * same one the diagnostic bundle applies before writing text out.
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
      text = EPISODIC_OMITTED_TEXT;
      omissions.push("context-edit");
      omitted = true;
      const base = projectEntry(entry, undefined, limits);
      if (base) kind = base.kind;
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
    const redacted = redact(text);
    if (redacted !== text) omissions.push("redacted");
    const finalText = redacted;
    projected.push({
      entryId: entry.id,
      kind,
      text: finalText,
      sourceDigest: digest(entry.line),
      projectedDigest: digest(finalText),
      omissions: [...new Set(omissions)],
      omitted,
    });
  }
  return projected;
}
