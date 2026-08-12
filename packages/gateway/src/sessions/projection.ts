import type { AgentMessage } from "@earendil-works/pi-agent-core";
import type { SessionEntry, SessionManager, SessionTreeNode as PiSessionTreeNode } from "@earendil-works/pi-coding-agent";
import type { ImageContent, TextContent } from "@earendil-works/pi-ai";
import type { BlobStore } from "./blob-store.js";
import type { ContentPart, JsonValue, SessionTreeNode, TranscriptItem } from "../protocol/types.js";

const MAX_TEXT = 64_000;
const MAX_JSON_STRING = 100_000;
const MAX_PROJECTED_JSON_BYTES = 96_000;
const MAX_CONTENT_BYTES = 320_000;
export const TRANSCRIPT_PAGE_BYTES = 600_000;

function boundedText(value: string): string {
  return value.length <= MAX_TEXT ? value : `${value.slice(0, MAX_TEXT)}\n… output truncated by gateway`;
}

export function safeJson(value: unknown, depth = 0, seen = new WeakSet<object>()): JsonValue {
  if (value === null || typeof value === "boolean") return value;
  if (typeof value === "string") return value.length <= MAX_JSON_STRING ? value : `${value.slice(0, MAX_JSON_STRING)}…`;
  if (typeof value === "number") return Number.isFinite(value) ? value : String(value);
  if (typeof value === "bigint") return value.toString();
  if (value === undefined || typeof value === "function" || typeof value === "symbol") return null;
  if (depth >= 12) return "[maximum depth]";
  if (typeof value === "object") {
    if (seen.has(value)) return "[circular]";
    seen.add(value);
    if (Array.isArray(value)) return value.slice(0, 1_000).map((item) => safeJson(item, depth + 1, seen));
    const result: Record<string, JsonValue> = {};
    for (const [key, item] of Object.entries(value).slice(0, 1_000)) {
      result[key] = safeJson(item, depth + 1, seen);
    }
    return result;
  }
  return null;
}

function boundedJson(value: unknown): JsonValue {
  const projected = safeJson(value);
  const encoded = JSON.stringify(projected);
  if (Buffer.byteLength(encoded) <= MAX_PROJECTED_JSON_BYTES) return projected;
  return {
    truncated: true,
    preview: `${encoded.slice(0, 24_000)}…`,
  };
}

type ProjectableContent = string | Array<
  | TextContent
  | ImageContent
  | { type: "thinking"; thinking: string; redacted?: boolean }
  | { type: "toolCall"; id: string; name: string; arguments: unknown }
>;

function projectContent(content: ProjectableContent, blobs: BlobStore, ownerId: string): ContentPart[] {
  if (typeof content === "string") return [{ id: `${ownerId}:0`, type: "text", text: boundedText(content) }];
  const projected: ContentPart[] = [];
  let bytes = 2;
  for (const [index, part] of content.entries()) {
    const id = `${ownerId}:${index}`;
    let candidate: ContentPart | undefined;
    switch (part.type) {
      case "text":
        candidate = { id, type: "text", text: boundedText(part.text) };
        break;
      case "image":
        candidate = { id, type: "image", mimeType: part.mimeType, blobId: blobs.register(part.data, part.mimeType) };
        break;
      case "thinking":
        candidate = { id, type: "thinking", text: boundedText(part.thinking), ...(part.redacted ? { redacted: true } : {}) };
        break;
      case "toolCall":
        candidate = { id, type: "toolCall", toolCallId: part.id, name: part.name, arguments: boundedJson(part.arguments) };
        break;
    }
    if (!candidate) continue;
    const candidateBytes = Buffer.byteLength(JSON.stringify(candidate)) + 1;
    if (bytes + candidateBytes > MAX_CONTENT_BYTES) {
      projected.push({ id: `${ownerId}:truncated`, type: "text", text: "… additional content omitted from this mobile projection" });
      break;
    }
    projected.push(candidate);
    bytes += candidateBytes;
  }
  return projected;
}

export function projectMessage(
  id: string,
  parentId: string | null,
  timestamp: string,
  message: AgentMessage,
  blobs: BlobStore,
): TranscriptItem | undefined {
  switch (message.role) {
    case "user":
      return { id, parentId, timestamp, kind: "message", role: "user", content: projectContent(message.content, blobs, id) };
    case "assistant":
      return {
        id,
        parentId,
        timestamp,
        kind: "message",
        role: "assistant",
        content: projectContent(message.content, blobs, id),
        provider: message.provider,
        modelId: message.model,
        stopReason: message.stopReason,
        ...(message.errorMessage ? { errorMessage: boundedText(message.errorMessage) } : {}),
        usage: boundedJson(message.usage),
      };
    case "toolResult":
      return {
        id,
        parentId,
        timestamp,
        kind: "message",
        role: "toolResult",
        content: projectContent(message.content, blobs, id),
        toolCallId: message.toolCallId,
        toolName: message.toolName,
        isError: message.isError,
        ...(message.details === undefined ? {} : { details: boundedJson(message.details) }),
        ...(message.usage === undefined ? {} : { usage: boundedJson(message.usage) }),
      };
    case "bashExecution":
      return {
        id,
        parentId,
        timestamp,
        kind: "bash",
        command: message.command,
        output: boundedText(message.output),
        ...(message.exitCode === undefined ? {} : { exitCode: message.exitCode }),
        cancelled: message.cancelled,
        truncated: message.truncated,
        ...(message.fullOutputPath ? { fullOutputPath: message.fullOutputPath } : {}),
        ...(message.excludeFromContext === undefined ? {} : { excludeFromContext: message.excludeFromContext }),
      };
    case "custom":
      if (!message.display) return undefined;
      return {
        id,
        parentId,
        timestamp,
        kind: "customMessage",
        customType: message.customType,
        content: projectContent(message.content, blobs, id),
        ...(message.details === undefined ? {} : { details: boundedJson(message.details) }),
      };
    case "branchSummary":
      return { id, parentId, timestamp, kind: "branchSummary", summary: boundedText(message.summary) };
    case "compactionSummary":
      return {
        id,
        parentId,
        timestamp,
        kind: "compaction",
        summary: boundedText(message.summary),
        tokensBefore: message.tokensBefore,
      };
    default:
      return undefined;
  }
}

export function projectEntry(entry: SessionEntry, blobs: BlobStore): TranscriptItem | undefined {
  switch (entry.type) {
    case "message":
      return projectMessage(entry.id, entry.parentId, entry.timestamp, entry.message, blobs);
    case "custom_message":
      if (!entry.display) return undefined;
      return {
        id: entry.id,
        parentId: entry.parentId,
        timestamp: entry.timestamp,
        kind: "customMessage",
        customType: entry.customType,
        content: projectContent(entry.content, blobs, entry.id),
        ...(entry.details === undefined ? {} : { details: boundedJson(entry.details) }),
      };
    case "custom":
      return {
        id: entry.id,
        parentId: entry.parentId,
        timestamp: entry.timestamp,
        kind: "customEntry",
        customType: entry.customType,
        ...(entry.data === undefined ? {} : { data: boundedJson(entry.data) }),
      };
    case "compaction":
      return {
        id: entry.id,
        parentId: entry.parentId,
        timestamp: entry.timestamp,
        kind: "compaction",
        summary: boundedText(entry.summary),
        tokensBefore: entry.tokensBefore,
        ...(entry.details === undefined ? {} : { details: boundedJson(entry.details) }),
        ...(entry.usage === undefined ? {} : { usage: boundedJson(entry.usage) }),
        ...(entry.fromHook === undefined ? {} : { fromHook: entry.fromHook }),
      };
    case "branch_summary":
      return {
        id: entry.id,
        parentId: entry.parentId,
        timestamp: entry.timestamp,
        kind: "branchSummary",
        summary: boundedText(entry.summary),
        ...(entry.details === undefined ? {} : { details: boundedJson(entry.details) }),
        ...(entry.usage === undefined ? {} : { usage: boundedJson(entry.usage) }),
        ...(entry.fromHook === undefined ? {} : { fromHook: entry.fromHook }),
      };
    case "model_change":
      return {
        id: entry.id,
        parentId: entry.parentId,
        timestamp: entry.timestamp,
        kind: "modelChange",
        modelRef: { provider: entry.provider, id: entry.modelId },
      };
    case "thinking_level_change":
      return { id: entry.id, parentId: entry.parentId, timestamp: entry.timestamp, kind: "thinkingChange", level: entry.thinkingLevel };
    case "label":
      return {
        id: entry.id,
        parentId: entry.parentId,
        timestamp: entry.timestamp,
        kind: "label",
        targetId: entry.targetId,
        ...(entry.label ? { label: entry.label } : {}),
      };
    case "session_info":
      return undefined;
  }
}

function preview(item: TranscriptItem | undefined, entry: SessionEntry): string {
  if (!item) return entry.type === "session_info" ? entry.name ?? "Session renamed" : entry.type;
  switch (item.kind) {
    case "message":
      return item.content.flatMap((part) => part.type === "text" || part.type === "thinking" ? [part.text] : []).join(" ").slice(0, 240);
    case "bash": return item.command.slice(0, 240);
    case "customMessage": return item.content.flatMap((part) => part.type === "text" ? [part.text] : []).join(" ").slice(0, 240) || item.customType;
    case "customEntry": return item.customType;
    case "compaction":
    case "branchSummary": return item.summary.slice(0, 240);
    case "modelChange": return `${item.modelRef.provider} / ${item.modelRef.id}`;
    case "thinkingChange": return item.level;
    case "label": return item.label ?? "Label cleared";
  }
}

const MAX_TREE_NODES = 4_000;

function projectedTreeNode(node: PiSessionTreeNode, blobs: BlobStore): SessionTreeNode {
  const item = projectEntry(node.entry, blobs);
  return {
    id: node.entry.id,
    parentId: node.entry.parentId,
    timestamp: node.entry.timestamp,
    kind: item?.kind ?? "sessionInfo",
    ...(node.label ? { label: node.label } : {}),
    preview: preview(item, node.entry),
    ...(item ? { item } : {}),
    children: [],
  };
}

export function projectTree(manager: SessionManager, blobs: BlobStore): SessionTreeNode[] {
  const canonicalRoots = manager.getTree();
  const projectedRoots: SessionTreeNode[] = [];
  const work: Array<{ source: PiSessionTreeNode; target: SessionTreeNode[] }> = [];
  for (let index = canonicalRoots.length - 1; index >= 0; index -= 1) {
    work.push({ source: canonicalRoots[index]!, target: projectedRoots });
  }
  let admitted = 0;
  while (work.length > 0 && admitted < MAX_TREE_NODES) {
    const { source, target } = work.pop()!;
    const projected = projectedTreeNode(source, blobs);
    target.push(projected);
    admitted += 1;
    for (let index = source.children.length - 1; index >= 0; index -= 1) {
      work.push({ source: source.children[index]!, target: projected.children });
    }
  }
  return projectedRoots;
}

export function projectTranscript(manager: SessionManager, blobs: BlobStore): TranscriptItem[] {
  return manager.getBranch().flatMap((entry) => {
    const projected = projectEntry(entry, blobs);
    return projected ? [projected] : [];
  });
}

export interface TranscriptPage {
  items: TranscriptItem[];
  start: number;
  total: number;
}

export function projectTranscriptPage(
  manager: SessionManager,
  blobs: BlobStore,
  before?: number,
  byteBudget = TRANSCRIPT_PAGE_BYTES,
): TranscriptPage {
  const transcript = projectTranscript(manager, blobs);
  const end = Math.max(0, Math.min(before ?? transcript.length, transcript.length));
  let start = end;
  let bytes = 2;
  while (start > 0) {
    const itemBytes = Buffer.byteLength(JSON.stringify(transcript[start - 1])) + 1;
    if (bytes + itemBytes > byteBudget && start < end) break;
    // Projection limits guarantee ordinary items remain below the page budget.
    // Never return an empty, non-advancing page for an unknown oversized shape.
    if (itemBytes > byteBudget) break;
    bytes += itemBytes;
    start -= 1;
  }
  return { items: transcript.slice(start, end), start, total: transcript.length };
}
