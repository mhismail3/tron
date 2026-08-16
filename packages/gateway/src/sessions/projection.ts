import type { AgentMessage } from "@earendil-works/pi-agent-core";
import type { SessionEntry, SessionManager, SessionTreeNode as PiSessionTreeNode } from "@earendil-works/pi-coding-agent";
import type { ImageContent, TextContent } from "@earendil-works/pi-ai";
import { GatewayError } from "../errors.js";
import type { BlobStore } from "./blob-store.js";
import type { ContentPart, JsonValue, SessionSnapshot, SessionTreeNode, TranscriptItem } from "../protocol/types.js";

const MAX_TEXT = 64_000;
const MAX_JSON_STRING = 100_000;
const MAX_PROJECTED_JSON_BYTES = 96_000;
const MAX_CONTENT_BYTES = 320_000;
const MAX_CONTENT_PARTS = 1_000;
const COMPACT_LIVE_TOOL_JSON_BYTES = 12_000;
const MAX_LIVE_TOOL_OUTPUT_BYTES = 48_000;
export const TRANSCRIPT_PAGE_BYTES = 600_000;
export const TRANSCRIPT_PAGE_ITEMS = 512;
/** Leaves headroom for the response/event envelope under the 1 MiB socket cap. */
export const SESSION_SNAPSHOT_BYTES = 800_000;

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

function boundedUtf8Tail(value: string, maximumBytes: number): { value: string; truncated: boolean } {
  const encoded = Buffer.from(value);
  if (encoded.length <= maximumBytes) return { value, truncated: false };
  return {
    value: encoded.subarray(encoded.length - maximumBytes).toString("utf8").replace(/^\uFFFD/u, ""),
    truncated: true,
  };
}

function utf8Prefix(value: string, maximumBytes: number): string {
  const encoded = Buffer.from(value);
  if (encoded.length <= maximumBytes) return value;
  return encoded.subarray(0, maximumBytes).toString("utf8").replace(/\uFFFD$/u, "");
}

function utf8Suffix(value: string, maximumBytes: number): string {
  const encoded = Buffer.from(value);
  if (encoded.length <= maximumBytes) return value;
  return encoded.subarray(encoded.length - maximumBytes).toString("utf8").replace(/^\uFFFD/u, "");
}

/** Extracts only explicit display text from Pi's current AgentToolResult. Arbitrary
 * detail objects remain structured JSON and are never guessed into user-facing
 * output. The newest tail is retained because command tools stream cumulative
 * output and the current lines are the most useful audit evidence. */
export function projectToolOutput(value: unknown, maximumBytes = MAX_LIVE_TOOL_OUTPUT_BYTES): {
  output?: string;
  outputTruncated?: true;
} {
  const collect = (candidate: unknown, depth = 0): string[] => {
    if (depth > 4 || candidate === null || candidate === undefined) return [];
    if (typeof candidate === "string") return [candidate];
    if (Array.isArray(candidate)) return candidate.flatMap((item) => collect(item, depth + 1));
    if (typeof candidate !== "object") return [];
    const record = candidate as Record<string, unknown>;
    if (record.type === "text" && typeof record.text === "string") return [record.text];
    if (Array.isArray(record.content)) return collect(record.content, depth + 1);
    if (typeof record.output === "string") return [record.output];
    if (typeof record.text === "string") return [record.text];
    return [];
  };
  const output = collect(value).filter(Boolean).join("\n");
  if (!output) return {};
  if (Buffer.byteLength(output) <= maximumBytes) return { output };
  const marker = "… earlier live output truncated by gateway …\n";
  return {
    output: marker + utf8Suffix(output, Math.max(256, maximumBytes - Buffer.byteLength(marker))),
    outputTruncated: true,
  };
}

/** The JSON frame stays bounded independently from the readable live-output
 * channel. If Pi streams a huge text result, retain only a recent tail here too
 * rather than serializing the whole value before projectJson can compact it. */
export function projectToolResult(value: unknown, maximumBytes = 24_000): JsonValue {
  if (!value || typeof value !== "object" || Array.isArray(value)) return projectJson(value, maximumBytes);
  const record = value as Record<string, unknown>;
  if (!Array.isArray(record.content)) return projectJson(value, maximumBytes);
  let truncated = false;
  const content = record.content.slice(-128).map((part) => {
    if (!part || typeof part !== "object" || Array.isArray(part)) return part;
    const projected = { ...part as Record<string, unknown> };
    if (typeof projected.text === "string") {
      const bounded = boundedUtf8Tail(projected.text, Math.max(1_024, maximumBytes - 1_024));
      projected.text = bounded.value;
      truncated ||= bounded.truncated;
    }
    return projected;
  });
  const bounded = projectJson({ ...record, content }, maximumBytes);
  if (!truncated || typeof bounded !== "object" || bounded === null || Array.isArray(bounded)) return bounded;
  return { ...bounded, truncated: true };
}

export function projectJson(value: unknown, maximumBytes = MAX_PROJECTED_JSON_BYTES): JsonValue {
  const projected = safeJson(value);
  const encoded = JSON.stringify(projected);
  if (Buffer.byteLength(encoded) <= maximumBytes) return projected;
  const previewBytes = Math.max(256, Math.min(24_000, maximumBytes - 128));
  return {
    truncated: true,
    preview: `${utf8Prefix(encoded, previewBytes)}…`,
  };
}

function frameBytes(value: unknown): number {
  return Buffer.byteLength(JSON.stringify(value));
}

/**
 * Fits every live session snapshot to a strict wire budget without touching Pi's
 * canonical state. Large tool payloads become readable previews first. While an
 * operation is active, transcript rows inside the fixed item cap are not removed:
 * doing so would make a subscribed chat replace already-visible history with a
 * shorter tail. Status, operation, ordering, and canonical transcript cursors
 * always survive.
 */
export function fitSessionSnapshot(
  snapshot: SessionSnapshot,
  maximumBytes = SESSION_SNAPSHOT_BYTES,
): SessionSnapshot {
  const transcriptOverflow = Math.max(0, snapshot.transcript.length - TRANSCRIPT_PAGE_ITEMS);
  const countBounded = transcriptOverflow === 0
    ? snapshot
    : {
      ...snapshot,
      transcript: snapshot.transcript.slice(transcriptOverflow),
      transcriptStart: snapshot.transcriptStart + transcriptOverflow,
    };
  if (frameBytes(countBounded) <= maximumBytes) return countBounded;

  let projected: SessionSnapshot = {
    ...countBounded,
    toolExecutions: snapshot.toolExecutions.map((tool) => ({
      ...tool,
      arguments: projectJson(tool.arguments, COMPACT_LIVE_TOOL_JSON_BYTES),
      ...(tool.partialResult === undefined
        ? {}
        : { partialResult: projectJson(tool.partialResult, COMPACT_LIVE_TOOL_JSON_BYTES) }),
      ...(tool.result === undefined
        ? {}
        : { result: projectJson(tool.result, COMPACT_LIVE_TOOL_JSON_BYTES) }),
    })),
    diagnostics: [
      ...countBounded.diagnostics,
      { type: "projection", message: "Large live details were compacted for this mobile snapshot." },
    ],
  };
  if (frameBytes(projected) <= maximumBytes) return projected;

  // Completed output is canonical in the transcript. Do not duplicate partial
  // output in the live overlay when the frame is under pressure.
  projected = {
    ...projected,
    toolExecutions: projected.toolExecutions.map((tool) => {
      if (tool.status === "running") return tool;
      const { partialResult: _partialResult, ...withoutPartialResult } = tool;
      return withoutPartialResult;
    }),
  };

  // A resumed idle session may use a smaller fitted tail. An active session must
  // keep its baseline page stable for the lifetime of the open subscription;
  // mobile merges later snapshots with any history it has explicitly prepended.
  if (projected.phase === "idle" || projected.phase === "interrupted") {
    let removed = 0;
    const transcript = [...projected.transcript];
    while (transcript.length > 0 && frameBytes({ ...projected, transcript }) > maximumBytes) {
      transcript.shift();
      removed += 1;
    }
    projected = {
      ...projected,
      transcript,
      transcriptStart: projected.transcriptStart + removed,
    };
    if (frameBytes(projected) <= maximumBytes) return projected;
  }

  projected = {
    ...projected,
    extensionUI: {
      ...projected.extensionUI,
      statuses: {},
      widgets: [],
      editorText: "",
    },
  };
  if (frameBytes(projected) <= maximumBytes) return projected;

  // A single streaming message can itself be large. It remains canonical and
  // will return through paged transcript projection once settled.
  const { streaming: _streaming, ...withoutStreaming } = projected;
  projected = withoutStreaming;
  if (frameBytes(projected) <= maximumBytes) return projected;

  const tools = projected.toolExecutions.slice(-256).map((tool) => {
    const { partialResult: _partialResult, result: _result, ...metadata } = tool;
    return { ...metadata, arguments: { truncated: true } };
  });
  projected = {
    ...projected,
    ...(projected.phase === "idle" || projected.phase === "interrupted"
      ? { transcript: [], transcriptStart: projected.transcriptTotal }
      : {}),
    toolExecutions: tools,
    diagnostics: [{ type: "projection", message: "Large live detail is available from canonical paged history after the run settles." }],
  };
  if (frameBytes(projected) <= maximumBytes) return projected;

  if (projected.phase !== "idle" && projected.phase !== "interrupted") {
    // Preserve the active canonical baseline before sacrificing live detail.
    // Tool identities/order remain in the streaming/canonical call projection
    // and return through events or the next fitted snapshot.
    projected = { ...projected, toolExecutions: [] };
    if (frameBytes(projected) <= maximumBytes) return projected;
  }

  return projected;
}

type ProjectableContent = string | Array<
  | TextContent
  | ImageContent
  | { type: "thinking"; thinking: string; redacted?: boolean }
  | { type: "toolCall"; id: string; name: string; arguments: unknown }
>;

const ATTACHMENT_TAG = /<attachment\b([^<>]*?)\s*\/>/g;
const ATTACHMENT_ATTRIBUTE = /([a-z-]+)="([^"]*)"/g;
const ATTACHMENT_LIKE_TAG = /<attachment\b[^>]*>/gi;
const ATTACHMENT_PATH_ATTRIBUTE = /\s+path\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]*)/gi;

function safeAttachmentFallback(value: string): string {
  return value.replace(ATTACHMENT_LIKE_TAG, (tag) => tag.replace(ATTACHMENT_PATH_ATTRIBUTE, ""));
}

function unescapeXML(value: string): string {
  return value
    .replaceAll("&quot;", '"')
    .replaceAll("&gt;", ">")
    .replaceAll("&lt;", "<")
    .replaceAll("&amp;", "&");
}

function projectUserText(text: string, ownerId: string, nextIndex: () => number): ContentPart[] {
  const projected: ContentPart[] = [];
  let cursor = 0;
  let match: RegExpExecArray | null;
  ATTACHMENT_TAG.lastIndex = 0;
  while ((match = ATTACHMENT_TAG.exec(text)) !== null) {
    const attributes = new Map<string, string>();
    ATTACHMENT_ATTRIBUTE.lastIndex = 0;
    for (let attribute = ATTACHMENT_ATTRIBUTE.exec(match[1] ?? ""); attribute; attribute = ATTACHMENT_ATTRIBUTE.exec(match[1] ?? "")) {
      attributes.set(attribute[1]!, unescapeXML(attribute[2]!));
    }
    const name = attributes.get("name");
    const mimeType = attributes.get("mime-type");
    const size = Number(attributes.get("size"));
    const path = attributes.get("path");
    if (!name || !mimeType || !path || !Number.isSafeInteger(size) || size < 0) continue;

    const leading = safeAttachmentFallback(text.slice(cursor, match.index)).replace(/\s+$/, "");
    if (leading) projected.push({ id: `${ownerId}:${nextIndex()}`, type: "text", text: boundedText(leading) });
    projected.push({
      id: `${ownerId}:${nextIndex()}`,
      type: "text",
      text: name,
      attachment: { name, mimeType, size },
    });
    cursor = match.index + match[0].length;
  }
  if (projected.length === 0) {
    return [{ id: `${ownerId}:${nextIndex()}`, type: "text", text: boundedText(safeAttachmentFallback(text)) }];
  }
  const trailing = safeAttachmentFallback(text.slice(cursor)).replace(/^\s+/, "");
  if (trailing) projected.push({ id: `${ownerId}:${nextIndex()}`, type: "text", text: boundedText(trailing) });
  return projected;
}

function projectContent(content: ProjectableContent, blobs: BlobStore, ownerId: string, extractAttachments = false): ContentPart[] {
  const source = typeof content === "string" ? [{ type: "text" as const, text: content }] : content;
  const projected: ContentPart[] = [];
  let bytes = 2;
  let outputIndex = 0;
  const nextIndex = () => outputIndex++;
  for (const part of source) {
    let candidates: ContentPart[] = [];
    switch (part.type) {
      case "text":
        candidates = extractAttachments
          ? projectUserText(part.text, ownerId, nextIndex)
          : [{ id: `${ownerId}:${nextIndex()}`, type: "text", text: boundedText(part.text) }];
        break;
      case "image": {
        const id = `${ownerId}:${nextIndex()}`;
        try {
          candidates = [{ id, type: "image", mimeType: part.mimeType, blobId: blobs.register(part.data, part.mimeType) }];
        } catch (error) {
          if (!(error instanceof GatewayError) || (error.code !== "conflict" && error.code !== "busy")) throw error;
          candidates = [{ id, type: "text", text: "Image omitted from this bounded mobile projection" }];
        }
        break;
      }
      case "thinking":
        candidates = [{ id: `${ownerId}:${nextIndex()}`, type: "thinking", text: boundedText(part.thinking), ...(part.redacted ? { redacted: true } : {}) }];
        break;
      case "toolCall":
        candidates = [{ id: `${ownerId}:${nextIndex()}`, type: "toolCall", toolCallId: part.id, name: part.name, arguments: projectJson(part.arguments) }];
        break;
    }
    for (const candidate of candidates) {
      if (projected.length >= MAX_CONTENT_PARTS - 1) {
        projected.push({ id: `${ownerId}:truncated`, type: "text", text: "… additional content omitted from this mobile projection" });
        return projected;
      }
      const candidateBytes = Buffer.byteLength(JSON.stringify(candidate)) + 1;
      if (bytes + candidateBytes > MAX_CONTENT_BYTES) {
        projected.push({ id: `${ownerId}:truncated`, type: "text", text: "… additional content omitted from this mobile projection" });
        return projected;
      }
      projected.push(candidate);
      bytes += candidateBytes;
    }
  }
  return projected;
}

export interface ToolProjectionMetadata {
  startedAt: string;
  completedAt?: string;
  durationMs?: number;
  lastProgressAt: string;
  progressSequence: number;
}

export function projectMessage(
  id: string,
  parentId: string | null,
  timestamp: string,
  message: AgentMessage,
  blobs: BlobStore,
  toolMetadata?: ToolProjectionMetadata,
): TranscriptItem | undefined {
  switch (message.role) {
    case "user":
      return { id, parentId, timestamp, kind: "message", role: "user", content: projectContent(message.content, blobs, id, true) };
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
        usage: projectJson(message.usage),
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
        ...(message.details === undefined ? {} : { details: projectJson(message.details) }),
        ...(message.usage === undefined ? {} : { usage: projectJson(message.usage) }),
        ...(toolMetadata ? {
          startedAt: toolMetadata.startedAt,
          ...(toolMetadata.completedAt ? { completedAt: toolMetadata.completedAt } : {}),
          ...(toolMetadata.durationMs === undefined ? {} : { durationMs: toolMetadata.durationMs }),
          lastProgressAt: toolMetadata.lastProgressAt,
          progressSequence: toolMetadata.progressSequence,
        } : {
          // Pi JSONL does not currently persist tool execution start/end metadata.
          // The result timestamp is an observed completion anchor; clients pair it
          // with the canonical call timestamp as a conservative history fallback.
          completedAt: timestamp,
        }),
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
        ...(message.details === undefined ? {} : { details: projectJson(message.details) }),
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

export function projectEntry(
  entry: SessionEntry,
  blobs: BlobStore,
  toolMetadata?: ReadonlyMap<string, ToolProjectionMetadata>,
): TranscriptItem | undefined {
  switch (entry.type) {
    case "message":
      return projectMessage(
        entry.id,
        entry.parentId,
        entry.timestamp,
        entry.message,
        blobs,
        entry.message.role === "toolResult" ? toolMetadata?.get(entry.message.toolCallId) : undefined,
      );
    case "custom_message":
      if (!entry.display) return undefined;
      return {
        id: entry.id,
        parentId: entry.parentId,
        timestamp: entry.timestamp,
        kind: "customMessage",
        customType: entry.customType,
        content: projectContent(entry.content, blobs, entry.id),
        ...(entry.details === undefined ? {} : { details: projectJson(entry.details) }),
      };
    case "custom":
      return {
        id: entry.id,
        parentId: entry.parentId,
        timestamp: entry.timestamp,
        kind: "customEntry",
        customType: entry.customType,
        ...(entry.data === undefined ? {} : { data: projectJson(entry.data) }),
      };
    case "compaction":
      return {
        id: entry.id,
        parentId: entry.parentId,
        timestamp: entry.timestamp,
        kind: "compaction",
        summary: boundedText(entry.summary),
        tokensBefore: entry.tokensBefore,
        ...(entry.details === undefined ? {} : { details: projectJson(entry.details) }),
        ...(entry.usage === undefined ? {} : { usage: projectJson(entry.usage) }),
        ...(entry.fromHook === undefined ? {} : { fromHook: entry.fromHook }),
      };
    case "branch_summary":
      return {
        id: entry.id,
        parentId: entry.parentId,
        timestamp: entry.timestamp,
        kind: "branchSummary",
        summary: boundedText(entry.summary),
        ...(entry.details === undefined ? {} : { details: projectJson(entry.details) }),
        ...(entry.usage === undefined ? {} : { usage: projectJson(entry.usage) }),
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

// safeJson intentionally bounds arrays to 1,000 values. Keep the tree page
// within that generic transport bound so selected nodes are never discarded
// after projectTree has chosen the newest useful history.
const MAX_TREE_NODES = 1_000;
export const TREE_PROJECTION_BYTES = 700_000;

function projectedTreeNode(
  node: PiSessionTreeNode,
  blobs: BlobStore,
  depth: number,
  currentPath: Set<string>,
): SessionTreeNode {
  const item = projectEntry(node.entry, blobs);
  return {
    id: node.entry.id,
    parentId: node.entry.parentId,
    timestamp: node.entry.timestamp,
    kind: item?.kind ?? "sessionInfo",
    ...(node.label ? { label: node.label } : {}),
    preview: preview(item, node.entry),
    ...(item?.kind === "message" ? { role: item.role } : {}),
    depth,
    childCount: node.children.length,
    isCurrentPath: currentPath.has(node.entry.id),
  };
}

export function projectTree(manager: SessionManager, blobs: BlobStore): SessionTreeNode[] {
  const canonicalRoots = manager.getTree();
  const currentPath = new Set(manager.getBranch().map((entry) => entry.id));
  const byId = new Map<string, SessionTreeNode>();
  const work: Array<{ source: PiSessionTreeNode; depth: number }> = [];
  for (let index = canonicalRoots.length - 1; index >= 0; index -= 1) {
    work.push({ source: canonicalRoots[index]!, depth: 0 });
  }
  while (work.length > 0) {
    const { source, depth } = work.pop()!;
    byId.set(source.entry.id, projectedTreeNode(source, blobs, depth, currentPath));
    for (let index = source.children.length - 1; index >= 0; index -= 1) {
      work.push({ source: source.children[index]!, depth: depth + 1 });
    }
  }

  // Admit the newest canonical entries first, then restore chronological order.
  // This keeps the current fork/navigation points useful when a large session
  // exceeds the bounded mobile projection.
  const selected: SessionTreeNode[] = [];
  let bytes = 2;
  const entries = manager.getEntries();
  for (let index = entries.length - 1; index >= 0 && selected.length < MAX_TREE_NODES; index -= 1) {
    const node = byId.get(entries[index]!.id);
    if (!node) continue;
    const nodeBytes = Buffer.byteLength(JSON.stringify(node)) + 1;
    if (bytes + nodeBytes > TREE_PROJECTION_BYTES) break;
    bytes += nodeBytes;
    selected.push(node);
  }
  return selected.reverse();
}

function projectableTranscriptEntries(manager: SessionManager): SessionEntry[] {
  return manager.getBranch().filter((entry) =>
    entry.type !== "session_info"
      && !(entry.type === "custom_message" && !entry.display)
      && !(entry.type === "message" && entry.message.role === "custom" && !entry.message.display));
}

export function projectTranscript(
  manager: SessionManager,
  blobs: BlobStore,
  toolMetadata?: ReadonlyMap<string, ToolProjectionMetadata>,
): TranscriptItem[] {
  return projectableTranscriptEntries(manager).map((entry) => {
    const projected = projectEntry(entry, blobs, toolMetadata);
    if (!projected) throw new Error("projectable transcript entry produced no item");
    return projected;
  });
}

export interface TranscriptPage {
  items: TranscriptItem[];
  start: number;
  end: number;
  total: number;
}

export function projectTranscriptPage(
  manager: SessionManager,
  blobs: BlobStore,
  before?: number,
  byteBudget = TRANSCRIPT_PAGE_BYTES,
  expectedNextEntryId?: string,
  toolMetadata?: ReadonlyMap<string, ToolProjectionMetadata>,
): TranscriptPage {
  const entries = projectableTranscriptEntries(manager);
  const end = Math.max(0, Math.min(before ?? entries.length, entries.length));
  if (expectedNextEntryId !== undefined && entries[end]?.id !== expectedNextEntryId) {
    throw new Error("session transcript anchor changed");
  }
  let start = end;
  let bytes = 2;
  const selected: TranscriptItem[] = [];
  while (start > 0 && selected.length < TRANSCRIPT_PAGE_ITEMS) {
    const item = projectEntry(entries[start - 1]!, blobs, toolMetadata);
    if (!item) throw new Error("projectable transcript entry produced no item");
    const itemBytes = Buffer.byteLength(JSON.stringify(item)) + 1;
    if (bytes + itemBytes > byteBudget && selected.length > 0) break;
    if (itemBytes > byteBudget) {
      // session.transcript responses are not passed through the snapshot fitter.
      // Compact an unexpectedly oversized legal item before returning it so the
      // page both advances and stays inside its production wire budget.
      const compacted = compactTranscriptPageItem(item, Math.max(256, byteBudget - 3));
      selected.unshift(compacted);
      start -= 1;
      break;
    }
    selected.unshift(item);
    bytes += itemBytes;
    start -= 1;
  }
  return { items: selected, start, end, total: entries.length };
}

function compactTranscriptPageItem(item: TranscriptItem, byteBudget: number): TranscriptItem {
  let compacted = item;
  if (item.kind === "message") {
    const { details: _details, usage: _usage, ...base } = item;
    compacted = {
      ...base,
      content: item.content.map((part) => {
        if (part.type !== "text" && part.type !== "thinking") return part;
        return { ...part, text: utf8Prefix(part.text, Math.max(64, Math.floor(byteBudget / 3))) };
      }),
      ...(item.details === undefined ? {} : { details: { truncated: true, preview: "Oversized detail omitted from mobile page." } }),
      ...(item.usage === undefined ? {} : { usage: projectJson(item.usage, 256) }),
    };
  } else if (item.kind === "bash") {
    compacted = { ...item, command: utf8Prefix(item.command, 256), output: utf8Suffix(item.output, Math.max(64, byteBudget - 1_024)), truncated: true };
  } else if (item.kind === "customMessage") {
    compacted = { ...item, content: [], details: { truncated: true, preview: "Oversized custom message omitted from mobile page." } };
  } else if (item.kind === "customEntry") {
    compacted = { ...item, data: { truncated: true, preview: "Oversized custom entry omitted from mobile page." } };
  } else if (item.kind === "compaction" || item.kind === "branchSummary") {
    const { details: _details, usage: _usage, ...base } = item;
    compacted = { ...base, summary: utf8Prefix(item.summary, Math.max(64, byteBudget - 1_024)) };
  }
  if (Buffer.byteLength(JSON.stringify(compacted)) <= byteBudget) return compacted;
  // Metadata alone is small; this final message-shaped marker retains canonical
  // identity/order while guaranteeing a bounded response for future item shapes.
  return {
    id: item.id,
    parentId: item.parentId,
    timestamp: item.timestamp,
    kind: "message",
    role: "assistant",
    content: [{ id: `${item.id}:truncated`, type: "text", text: "… transcript item omitted from this mobile page" }],
  };
}
