import { episodicDigest as digest, type EpisodicCanonicalEntry } from "../kernel/session/canonical-reader.js";
import { asRecord } from "../util/json.js";
import { redactCredentials } from "../util/credential-redaction.js";
import { EPISODIC_CAP_CHARS, EPISODIC_CAP_TAIL_CHARS, EPISODIC_OMITTED_TEXT, type EpisodicLimits, type EpisodicMessageKind, type EpisodicSourceCursor } from "./episodic-contract.js";
import { capText } from "./episodic-tree.js";

/** One chapter-ordered delta of Home's canonical source, already projected: the
 * memory never receives raw JSONL. A full branch refresh of one physical chapter
 * sets `scopeSessionId`, so only that chapter's entries can be marked off-branch. */
export interface EpisodicSourceDelta {
  sessionId: string;
  projected: EpisodicProjectedMessage[];
  /** The cursor after this delta; its `completeBytes` and `leafEntryId` are the
   * position the memory has read through. */
  cursor: EpisodicSourceCursor;
  /** True when this delta continued from the previous cursor. */
  incremental: boolean;
  scopeSessionId?: string;
}

export interface EpisodicProjectedMessage {
  entryId: string;
  /** The physical chapter the entry was read from. */
  sourceSessionId: string;
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

/** Redact while the full credential shape still exists, before any cap can
 * split its prefix from its tail. All projections keep the one shared rule set. */
function redactedContent(text: string, omissions: string[]): string {
  const redacted = redactCredentials(text);
  if (redacted !== text) omissions.push("credentials");
  return redacted;
}

/** Assistant content: text and tool calls; thinking is excluded and recorded
 * (gist §2 logs no thoughts, and the compactor refused them). */
function projectAssistantContent(content: unknown, omissions: string[]): string {
  const lines: string[] = [];
  for (const part of parts(content)) {
    if (part.type === "text" && typeof part.text === "string") lines.push(part.text);
    else if (part.type === "thinking") omissions.push("thinking");
    else if (part.type === "toolCall" && typeof part.name === "string") {
      const args = redactedContent(JSON.stringify(part.arguments ?? {}), omissions);
      const capped = capText(args, EPISODIC_CAP_CHARS, EPISODIC_CAP_TAIL_CHARS);
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

function projectEntry(entry: EpisodicCanonicalEntry, edit: Record<string, unknown> | undefined): ProjectedContent | undefined {
  if (entry.type === "message") {
    const message = asRecord(entry.raw.message);
    if (!message) return undefined;
    const role = message.role;
    const content = edit === undefined ? message.content : asRecord(edit.replacement)?.content;
    const omissions: string[] = [];
    if (role === "user") return { kind: "user", text: projectContent(content, omissions), omissions };
    if (role === "assistant") return { kind: "talk", text: projectAssistantContent(content, omissions), omissions };
    if (role === "toolResult") {
      const name = typeof message.toolName === "string" ? message.toolName : "unknown";
      const capped = capText(redactedContent(projectContent(content, omissions), omissions), EPISODIC_CAP_CHARS, EPISODIC_CAP_TAIL_CHARS);
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
 * message each, stamped with the physical chapter they were read from. Context
 * edits replace their target's content without renumbering anything; a null
 * replacement makes the message `[omitted]`.
 *
 * Credentials are the one shared credential-only rule set
 * (`redactCredentials`), never the process preview's rule set: the memory must
 * keep file paths and ordinary identifiers readable.
 */
export function projectBranch(branch: readonly EpisodicCanonicalEntry[], limits: EpisodicLimits, sourceSessionId: string): EpisodicProjectedMessage[] {
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
      const base = projectEntry(entry, undefined);
      if (!base) continue;
      kind = base.kind;
      text = EPISODIC_OMITTED_TEXT;
      omissions.push("context-edit");
      omitted = true;
    } else {
      const content = projectEntry(entry, edit);
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
    text = redactedContent(text, omissions);
    if (!omitted) {
      // The recipe sends user and assistant text whole; a memory record must
      // still fit its store's line, so an oversized paste is capped head+tail.
      const capped = capText(text, limits.recordCapChars, EPISODIC_CAP_TAIL_CHARS);
      if (capped.capped) omissions.push("capped");
      text = capped.text;
    }
    projected.push({
      entryId: entry.id,
      sourceSessionId,
      kind,
      text,
      timestamp: entry.timestamp,
      sourceDigest: digest(entry.line),
      projectedDigest: digest(text),
      omissions: [...new Set(omissions)],
      omitted,
    });
  }
  return projected;
}
