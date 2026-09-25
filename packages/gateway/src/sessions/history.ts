import type { SessionEntry, SessionManager } from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import type { JsonValue, SessionTreeNode } from "../protocol/types.js";

const HISTORY_PAGE_SIZE = 100;
export const HISTORY_TEXT_CHARS = 24_000;
export interface HistoryCursor { ordinal: number; entryId: string; direction: "older" | "newer" }
export interface HistoryPage {
  runtimeGeneration: string;
  nodes: SessionTreeNode[];
  older?: HistoryCursor;
  newer?: HistoryCursor;
  totalEntries: number;
}

const kindNames: Record<string, string> = {
  thinking_level_change: "thinkingChange", model_change: "modelChange", branch_summary: "branchSummary",
  custom_message: "customMessage", custom: "customEntry", session_info: "sessionInfo", context_edit: "contextEdit",
};

/** Walk only the selected entry's authored content; list previews never project
 * entire transcript bodies or register media blobs. Images stay media, not base64 text. */
function* contentBlocks(content: unknown): Generator<string> {
  if (typeof content === "string") { yield content; return; }
  if (!Array.isArray(content)) return;
  for (const part of content) {
    if (!part || typeof part !== "object") continue;
    switch (part.type) {
      case "text": yield part.text ?? ""; break;
      case "thinking": yield `Thinking\n${part.thinking ?? part.text ?? ""}`; break;
      case "toolCall": yield `Tool call: ${part.name}\n${JSON.stringify(part.arguments ?? {}, null, 2)}`; break;
      case "image": yield `Image (${part.mimeType ?? "image"})`; break;
      default: yield JSON.stringify(part, null, 2);
    }
  }
}

function* entryBlocks(entry: SessionEntry): Generator<string> {
  switch (entry.type) {
    case "message": {
      const message = entry.message;
      if (message.role === "bashExecution") {
        yield message.command; yield message.output; return;
      }
      if (message.role === "system") {
        yield* contentBlocks(message.content);
        if (message.sections) yield `Sections: ${JSON.stringify(message.sections)}`;
        if (message.toolsAdded) yield `Tools added: ${JSON.stringify(message.toolsAdded)}`;
        if (message.toolsRemoved) yield `Tools removed: ${JSON.stringify(message.toolsRemoved)}`;
        return;
      }
      if ("content" in message) yield* contentBlocks(message.content);
      else if ("summary" in message) yield message.summary;
      return;
    }
    case "custom_message": yield* contentBlocks(entry.content); return;
    case "compaction": case "branch_summary": yield entry.summary; return;
    case "custom": yield JSON.stringify(entry.data ?? null, null, 2); return;
    case "model_change": yield `${entry.provider} / ${entry.modelId}`; return;
    case "thinking_level_change": yield entry.thinkingLevel; return;
    case "label": yield entry.label ?? "Bookmark removed"; return;
    case "session_info": yield entry.name ?? "Session information updated"; return;
    case "context_edit":
      yield `Target entry: ${entry.targetId}`;
      yield `Replacement: ${JSON.stringify(entry.replacement)}`;
      return;
  }
}

function entryPreview(entry: SessionEntry): string {
  // Tool arguments/extension data can be huge: previews describe their actual
  // kind without serializing them. Full values are an explicit detail read.
  if (entry.type === "message" && entry.message.role === "system") return "System context message";
  if (entry.type === "custom") return entry.customType.slice(0, 240);
  if (entry.type === "context_edit") return `Model context edit: ${entry.targetId}`;
  if (entry.type === "message" || entry.type === "custom_message") {
    const message = entry.type === "message" ? entry.message : entry;
    if ("role" in message && message.role === "bashExecution") return message.command.slice(0, 240);
    const content = "content" in message ? message.content : "summary" in message ? message.summary : undefined;
    if (typeof content === "string") return content.slice(0, 240) || "Empty text";
    if (Array.isArray(content)) {
      let preview = "";
      for (const raw of content) {
        const part = raw as unknown as Record<string, unknown>;
        const text = part.type === "thinking" ? `Thinking: ${part.thinking ?? part.text ?? ""}`
          : part.type === "toolCall" ? `Tool call: ${part.name}`
          : part.type === "image" ? "Image attachment"
          : typeof part.text === "string" ? part.text : String(part.type ?? "Structured content");
        preview += `${preview ? " · " : ""}${text.slice(0, 240 - preview.length)}`;
        if (preview.length >= 240) break;
      }
      if (preview) return preview.slice(0, 240);
    }
    return "role" in message && message.role === "toolResult" ? `Tool result: ${message.toolName}` : "Empty content";
  }
  for (const block of entryBlocks(entry)) if (block) return block.slice(0, 240);
  return entry.type;
}

/** Canonical append order is the ordering authority, including clock-skewed
 * timestamps. Cursors anchor both ordinal and identity, never a mutable offset alone. */
export function historyPage(manager: SessionManager, runtimeGeneration: string, cursor?: HistoryCursor): HistoryPage {
  const entries = manager.getEntries();
  if (cursor && (!Number.isSafeInteger(cursor.ordinal) || cursor.ordinal < 0
      || entries[cursor.ordinal]?.id !== cursor.entryId)) {
    throw new GatewayError("conflict", "History position changed. Reload history.", true);
  }
  let end = cursor ? cursor.direction === "older" ? cursor.ordinal : Math.min(entries.length, cursor.ordinal + 1 + HISTORY_PAGE_SIZE) : entries.length;
  const start = cursor?.direction === "newer" ? cursor.ordinal + 1 : Math.max(0, end - HISTORY_PAGE_SIZE);
  end = Math.max(start, end);
  const selected = entries.slice(start, end);
  const wanted = new Set(selected.map(e => e.id));
  const childCounts = new Map<string, number>();
  // Metadata only: no getTree() recursion, body flattening or durable index.
  for (const entry of entries) if (entry.parentId && wanted.has(entry.parentId)) childCounts.set(entry.parentId, (childCounts.get(entry.parentId) ?? 0) + 1);
  const path = new Set(manager.getBranch().filter(e => wanted.has(e.id)).map(e => e.id));
  const nodes = selected.reverse().map((entry): SessionTreeNode => {
    const role = entry.type === "message" && ["user", "assistant", "toolResult"].includes(entry.message.role)
      ? entry.message.role as "user" | "assistant" | "toolResult" : undefined;
    const bookmarkTargetId = entry.type === "label" && manager.getEntry(entry.targetId) ? entry.targetId : undefined;
    const label = manager.getLabel(bookmarkTargetId ?? entry.id);
    // A pathological canonical identifier/label must fail explicitly rather
    // than exceed the mobile frame budget or acquire an ambiguous truncated ID.
    for (const value of [entry.id, entry.parentId, label, bookmarkTargetId]) {
      if (value !== undefined && value !== null && Buffer.byteLength(value) > 1_024) {
        throw new GatewayError("conflict", "History entry metadata exceeds the supported bound. Use JSONL Export to inspect it.");
      }
    }
    return { id: entry.id, parentId: entry.parentId, timestamp: entry.timestamp,
      kind: entry.type === "message" && entry.message.role === "bashExecution" ? "bash"
        : entry.type === "message" && entry.message.role === "system" ? "systemMessage"
        : (kindNames[entry.type] ?? entry.type) as SessionTreeNode["kind"],
      ...(role ? { role } : {}), ...(label ? { label } : {}),
      ...(bookmarkTargetId ? { bookmarkTargetId } : {}), preview: entryPreview(entry),
      depth: 0, childCount: childCounts.get(entry.id) ?? 0, isCurrentPath: path.has(entry.id) };
  });
  if (Buffer.byteLength(JSON.stringify(nodes)) > 600_000) {
    throw new GatewayError("conflict", "History metadata exceeds the page budget. Use JSONL Export to inspect it.");
  }
  return { runtimeGeneration, nodes, totalEntries: entries.length,
    ...(start > 0 && entries[start] ? { older: { ordinal: start, entryId: entries[start]!.id, direction: "older" as const } } : {}),
    ...(end < entries.length && entries[end - 1] ? { newer: { ordinal: end - 1, entryId: entries[end - 1]!.id, direction: "newer" as const } } : {}) };
}

export interface HistoryEntryPage {
  runtimeGeneration: string; entryId: string; text: string; offset: number; nextOffset?: number; previousOffset?: number;
  totalCharacters: number; metadata: Record<string, JsonValue>;
}

export function historyEntry(manager: SessionManager, runtimeGeneration: string, entryId: string, offset: number): HistoryEntryPage {
  const entry = manager.getEntry(entryId);
  if (!entry) throw new GatewayError("not_found", "History entry no longer exists");
  if (!Number.isSafeInteger(offset) || offset < 0) throw new GatewayError("invalid_request", "Invalid entry content position");
  let total = 0;
  let text = "";
  let previous = Math.max(0, offset - HISTORY_TEXT_CHARS);
  let previousCharacter = "";
  function take(fragment: string) {
    if (previous >= total && previous < total + fragment.length) previousCharacter = fragment[previous - total]!;
    const start = Math.max(0, offset - total);
    const stop = Math.min(fragment.length, offset + HISTORY_TEXT_CHARS + 1 - total);
    if (start < stop) text += fragment.slice(start, stop);
    total += fragment.length;
  }
  let first = true;
  for (const block of entryBlocks(entry)) {
    if (!first) take("\n\n");
    first = false;
    take(block);
  }
  // Keep at most one native-reader page, not another full joined message.
  if (offset > total || offset > 0 && /[\uDC00-\uDFFF]/.test(text[0] ?? "")) {
    throw new GatewayError("invalid_request", "Invalid entry content position");
  }
  const length = /[\uDC00-\uDFFF]/.test(text[HISTORY_TEXT_CHARS] ?? "") ? HISTORY_TEXT_CHARS - 1 : HISTORY_TEXT_CHARS;
  text = text.slice(0, length);
  const end = offset + text.length;
  if (/[\uDC00-\uDFFF]/.test(previousCharacter)) previous += 1;
  const metadata: Record<string, JsonValue> = { type: entry.type, timestamp: entry.timestamp,
    entryId: entry.id, parentId: entry.parentId };
  if (entry.type === "message") {
    const message = entry.message;
    metadata.role = message.role;
    if (message.role === "assistant") {
      metadata.provider = message.provider; metadata.model = message.model;
      metadata.stopReason = message.stopReason;
      const usage: Record<string, JsonValue> = {};
      for (const key of ["input", "output", "cacheRead", "cacheWrite", "totalTokens"] as const) {
        const value = message.usage?.[key];
        if (typeof value === "number" && Number.isFinite(value)) usage[key] = value;
      }
      metadata.usage = usage;
      if (message.errorMessage) metadata.error = message.errorMessage;
    }
    if (message.role === "toolResult") { metadata.tool = message.toolName; metadata.toolCallId = message.toolCallId; metadata.isError = message.isError; }
    if (message.role === "bashExecution") { metadata.exitCode = message.exitCode ?? null; metadata.cancelled = message.cancelled; metadata.truncated = message.truncated; }
  }
  if (entry.type === "branch_summary") metadata.fromEntryId = entry.fromId;
  if (entry.type === "compaction") { metadata.tokensBefore = entry.tokensBefore; metadata.firstKeptEntryId = entry.firstKeptEntryId; }
  if (entry.type === "label") metadata.targetEntryId = entry.targetId;
  if (entry.type === "custom" || entry.type === "custom_message") metadata.customType = entry.customType;
  // Scalar metadata is deliberately separate from content and remains bounded
  // even for malformed/custom producers. Do not send tool arguments, image
  // bytes or arbitrary extension details through this side channel.
  for (const [key, value] of Object.entries(metadata)) {
    if (typeof value === "string" && value.length > 1_024) {
      metadata[key] = value.slice(0, 1_024);
      metadata[`${key}Truncated`] = true;
    }
  }
  return { runtimeGeneration, entryId, text, offset,
    ...(end < total ? { nextOffset: end } : {}),
    ...(offset > 0 ? { previousOffset: previous } : {}), totalCharacters: total, metadata };
}
