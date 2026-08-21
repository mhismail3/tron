import type { AgentMessage } from "@earendil-works/pi-agent-core";
import type { SessionEntry, SessionManager, SessionTreeNode as PiSessionTreeNode } from "@earendil-works/pi-coding-agent";
import type { ImageContent, TextContent } from "@earendil-works/pi-ai";
import { GatewayError } from "../errors.js";
import { isGatewayTimestamp } from "../util/timestamp.js";
import type { BlobStore } from "./blob-store.js";
import { EXTENSION_ACTIVITY_RECEIPT_TYPE } from "./extension-activity-history.js";
import type { CommandInfo, ContentPart, ExtensionSurface, ExtensionToolOrigin, JsonValue, SessionSnapshot, SessionTreeNode, TranscriptItem } from "../protocol/types.js";

const MAX_TEXT = 64_000;
const MAX_JSON_STRING = 100_000;
const MAX_PROJECTED_JSON_BYTES = 96_000;
const MAX_CONTENT_BYTES = 320_000;
const MAX_CONTENT_PARTS = 1_000;
const COMPACT_LIVE_TOOL_JSON_BYTES = 12_000;
const MAX_LIVE_TOOL_OUTPUT_BYTES = 48_000;
export const TRANSCRIPT_PAGE_BYTES = 600_000;
export const TRANSCRIPT_PAGE_ITEMS = 512;
export const MINIMUM_TRANSCRIPT_CONTINUITY_MESSAGES = 24;
/** Leaves headroom for the response/event envelope under the 1 MiB socket cap. */
export const SESSION_SNAPSHOT_BYTES = 800_000;
/**
 * Upper bound for one live streaming progress frame. Progress events republish
 * the cumulative streaming message, so an unbounded message amplifies every
 * token into a full-payload frame and can overrun the synchronization
 * quarantine during catch-up. The settled canonical message always pages
 * through transcript projection; only the transient live tail is trimmed here.
 */
export const STREAMING_PROGRESS_BYTES = 24_000;

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
    if (Array.isArray(value)) {
      const result = value.slice(0, 1_000).map((item) => safeJson(item, depth + 1, seen));
      seen.delete(value);
      return result;
    }
    const result: Record<string, JsonValue> = {};
    for (const [key, item] of Object.entries(value).slice(0, 1_000)) {
      result[key] = safeJson(item, depth + 1, seen);
    }
    // `seen` is a recursion stack, not a global visited set. Pi reuses
    // immutable metadata objects across resource entries; repeated siblings
    // are valid JSON and must be projected again, while true back-edges still
    // resolve to the bounded circular marker above.
    seen.delete(value);
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

/** Progress payloads are current display frames, not an append-only log.
 * Install the latest nonempty frame in place; an empty advisory frame preserves
 * the last readable frame so an open detail sheet never flashes blank. */
export function mergeLiveToolOutput(
  previous: { output?: string; outputTruncated?: boolean } | undefined,
  incoming: { output?: string; outputTruncated?: true },
  maximumBytes = MAX_LIVE_TOOL_OUTPUT_BYTES,
): { output?: string; outputTruncated?: true } {
  if (incoming.output) {
    if (Buffer.byteLength(incoming.output) > maximumBytes) {
      const marker = "… earlier live output truncated by gateway …\n";
      return {
        output: marker + utf8Suffix(incoming.output, Math.max(0, maximumBytes - Buffer.byteLength(marker))),
        outputTruncated: true,
      };
    }
    return {
      output: incoming.output,
      ...(incoming.outputTruncated ? { outputTruncated: true } : {}),
    };
  }
  return previous?.output === undefined ? {} : {
    output: previous.output,
    ...(previous.outputTruncated ? { outputTruncated: true } : {}),
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

/**
 * Bounds one live streaming progress item for the wire without touching Pi's
 * canonical state. Trailing parts survive whole; only the oldest kept text or
 * thinking part is tail-trimmed with an explicit ellipsis marker. Clients
 * replace their transient streaming bubble with each event, so a bounded tail
 * is always superseded by the canonical settled message.
 */
export function boundStreamingProgressItem(
  item: TranscriptItem,
  maximumBytes = STREAMING_PROGRESS_BYTES,
): TranscriptItem {
  if (definitelyFitsStreamingFrame(item, maximumBytes)) return item;
  if (frameBytes(item) <= maximumBytes) return item;
  if (item.kind !== "message") return item;
  const envelopeBytes = frameBytes({ ...item, content: [] });
  const kept: ContentPart[] = [];
  let bytes = envelopeBytes;
  for (let index = item.content.length - 1; index >= 0; index -= 1) {
    const part = item.content[index]!;
    const partBytes = frameBytes(part) + 1;
    if (bytes + partBytes <= maximumBytes) {
      kept.unshift(part);
      bytes += partBytes;
      continue;
    }
    if (part.type === "text" || part.type === "thinking") {
      const marker = "…";
      let lower = 0;
      let upper = Math.max(0, Math.min(Buffer.byteLength(part.text), maximumBytes - bytes));
      let best: ContentPart | undefined;
      while (lower <= upper) {
        const candidateBytes = Math.floor((lower + upper) / 2);
        const candidate = { ...part, text: `${marker}${utf8Suffix(part.text, candidateBytes)}` };
        const projected = { ...item, content: [candidate, ...kept] };
        if (frameBytes(projected) <= maximumBytes) {
          best = candidate;
          lower = candidateBytes + 1;
        } else {
          upper = candidateBytes - 1;
        }
      }
      if (best) kept.unshift(best);
    }
    break;
  }
  // A bounded live frame may omit a leading portion of a finalized group.
  // Never publish a partial declaration with a complete group count: either
  // the whole group survives or the subsequent group-aware tool progress owns
  // its aggregate placeholder until canonical projection arrives.
  const retainedCounts = new Map<string, number>();
  for (const part of kept) {
    if (part.type === "toolCall" && part.groupFinalized && part.groupId) {
      retainedCounts.set(part.groupId, (retainedCounts.get(part.groupId) ?? 0) + 1);
    }
  }
  const completeGroupIDs = new Set([...retainedCounts].flatMap(([groupId, count]) => {
    const member = kept.find((part) => part.type === "toolCall" && part.groupId === groupId);
    return member?.type === "toolCall" && member.groupCount === count ? [groupId] : [];
  }));
  for (let index = kept.length - 1; index >= 0; index -= 1) {
    const part = kept[index]!;
    if (part.type === "toolCall" && part.groupId && !completeGroupIDs.has(part.groupId)) kept.splice(index, 1);
  }

  const fallbackOrdinal = item.content.reduce(
    (maximum, part) => Math.max(maximum, part.ordinal), -1,
  ) + 1;
  if (kept.length === 0) {
    kept.push({ id: `${item.id}:truncated:${fallbackOrdinal}`, ordinal: fallbackOrdinal, type: "text", text: "…" });
  }
  const bounded = { ...item, content: kept };
  if (frameBytes(bounded) <= maximumBytes) return bounded;

  // Optional assistant metadata can itself exceed the live-frame budget. Keep
  // only the stable handoff envelope and an explicit marker; canonical history
  // remains complete and is published immediately after persistence.
  const minimal: TranscriptItem = {
    id: item.id,
    parentId: item.parentId,
    timestamp: item.timestamp,
    kind: "message",
    role: item.role,
    presentationId: item.presentationId,
    content: [{
      id: `${item.id}:truncated:${fallbackOrdinal}`,
      ordinal: fallbackOrdinal,
      type: "text",
      text: "…",
    }],
  };
  return minimal;
}

function frameBytes(value: unknown): number {
  return Buffer.byteLength(JSON.stringify(value));
}

function transcriptContinuityMessages(items: TranscriptItem[]): number {
  return items.reduce((count, item) =>
    count + (item.kind === "message" && item.role === "toolResult" ? 0 : 1), 0);
}

function definitelyFitsStreamingFrame(item: TranscriptItem, maximumBytes: number): boolean {
  if (item.kind !== "message") return false;
  // JSON control characters can expand to six bytes. This deliberately loose
  // upper bound avoids allocating/stringifying the cumulative content only
  // when the result is provably below the wire limit; exact sizing remains the
  // authority for every near-limit or structured part.
  let maximum = frameBytes({ ...item, content: [] }) + 2;
  const escapedUpperBound = (value: string): number => 2 + (6 * Buffer.byteLength(value));
  for (const part of item.content) {
    maximum += 128 + escapedUpperBound(part.id);
    switch (part.type) {
      case "text":
        if (part.attachment) return false;
        maximum += escapedUpperBound(part.text);
        break;
      case "thinking":
        maximum += escapedUpperBound(part.text);
        break;
      case "image":
        maximum += escapedUpperBound(part.mimeType) + escapedUpperBound(part.blobId);
        break;
      case "toolCall":
        return false;
    }
    if (maximum > maximumBytes) return false;
  }
  return maximum <= maximumBytes;
}

/**
 * Fits every live session snapshot to a strict wire budget without touching Pi's
 * canonical state. Large tool payloads become readable previews first. While an
 * operation is active, the newest transcript continuity floor survives pressure;
 * iOS retains any larger compatible prefix already on screen. Status, operation,
 * ordering, and canonical transcript cursors always survive.
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

  // Completed output is canonical in the transcript. Do not duplicate terminal
  // payloads in the live overlay when the frame is under pressure. Running
  // output remains available for the exact current call.
  projected = {
    ...projected,
    toolExecutions: projected.toolExecutions.map((tool) => {
      if (tool.status === "running") return tool;
      const {
        partialResult: _partialResult,
        result: _result,
        output: _output,
        outputTruncated: _outputTruncated,
        ...metadata
      } = tool;
      return metadata;
    }),
  };
  if (frameBytes(projected) <= maximumBytes) return projected;

  // Retain a stable recent continuity floor even under active snapshot pressure.
  // iOS may keep a larger exact loaded prefix, but it must never receive a new
  // authoritative tail containing only the Load earlier control and one row.
  let removed = 0;
  const fittedTranscript = [...projected.transcript];
  let fittedContinuityMessages = transcriptContinuityMessages(fittedTranscript);
  while (
    fittedContinuityMessages > MINIMUM_TRANSCRIPT_CONTINUITY_MESSAGES
      && frameBytes({ ...projected, transcript: fittedTranscript }) > maximumBytes
  ) {
    const shifted = fittedTranscript.shift();
    if (shifted && !(shifted.kind === "message" && shifted.role === "toolResult")) {
      fittedContinuityMessages -= 1;
    }
    removed += 1;
  }
  projected = {
    ...projected,
    transcript: fittedTranscript,
    transcriptStart: projected.transcriptStart + removed,
  };
  if (frameBytes(projected) <= maximumBytes) return projected;

  // Retain actionable frames first. Omitted identities/revisions remain a
  // bounded delta baseline, so an exact-next full-frame upsert can converge.
  const surfacePriority = (surface: ExtensionSurface): number => {
    const leased = projected.extensionPresentation.inputLease?.surfaceId === surface.id;
    if (leased || surface.lifecycle === "blocking") return 100;
    if (surface.focused) return 90;
    if (surface.kind === "overlay" || surface.kind === "editor" || surface.inputMode !== "none") return 80;
    if (surface.lifecycle === "transient") return 40;
    return 0;
  };
  const completeSurfaces = [...projected.extensionPresentation.surfaces];
  const removalOrder = [...completeSurfaces].sort((left, right) => surfacePriority(left) - surfacePriority(right));
  const omittedSurfaceRevisions: Array<{ id: string; revision: number }> = [];
  for (const removed of removalOrder) {
    omittedSurfaceRevisions.push({ id: removed.id, revision: removed.revision });
    const retained = completeSurfaces.filter((surface) => !omittedSurfaceRevisions.some((item) => item.id === surface.id));
    projected = {
      ...projected,
      extensionPresentation: {
        ...projected.extensionPresentation,
        surfaces: retained,
        diagnostics: [
          ...projected.extensionPresentation.diagnostics.filter((item) => item.code !== "projection.surfaces-omitted").slice(0, 63),
          { code: "projection.surfaces-omitted", message: "Decorative extension surfaces were omitted from this bounded snapshot." },
        ],
        projection: { complete: false, omitted: ["surfaces"], omittedSurfaces: [...omittedSurfaceRevisions] },
      },
    };
    if (frameBytes(projected) <= maximumBytes) return projected;
  }

  // Statuses and widgets are disposable chrome. The revisioned editor baseline
  // is not: retaining editorRevision while clearing editorText would make a
  // later paste delta impossible for the client to validate or converge.
  projected = {
    ...projected,
    extensionPresentation: {
      ...projected.extensionPresentation,
      semanticState: {
        ...projected.extensionPresentation.semanticState,
        statuses: {},
        widgets: [],
      },
      diagnostics: [
        ...projected.extensionPresentation.diagnostics.filter((item) => item.code !== "projection.surfaces-omitted").slice(0, 63),
        { code: "projection.presentation-omitted", message: "Decorative extension presentation was omitted from this bounded snapshot." },
      ],
      projection: {
        complete: false,
        omitted: ["surfaces", "statuses", "widgets"],
        ...(projected.extensionPresentation.projection?.omittedSurfaces
          ? { omittedSurfaces: projected.extensionPresentation.projection.omittedSurfaces }
          : {}),
      },
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
    const liveOutput = tool.output === undefined
      ? {}
      : {
          output: utf8Suffix(tool.output, 8 * 1_024),
          ...(Buffer.byteLength(tool.output) > 8 * 1_024 || tool.outputTruncated ? { outputTruncated: true } : {}),
        };
    return { ...metadata, ...liveOutput, arguments: { truncated: true } };
  });
  projected = {
    ...projected,
    toolExecutions: tools,
    diagnostics: [{ type: "projection", message: "Large live detail is available from canonical paged history after the run settles." }],
  };
  if (frameBytes(projected) <= maximumBytes) return projected;

  // Output tails are the last disposable component. Preserve every bounded call
  // identity and the transcript continuity floor before dropping live text.
  projected = {
    ...projected,
    toolExecutions: tools.map((tool) => {
      const { output: _output, outputTruncated: _outputTruncated, ...metadata } = tool;
      return metadata;
    }),
  };
  if (frameBytes(projected) <= maximumBytes) return projected;

  // All high-cardinality fields above are bounded. Reaching this point means a
  // legal transcript item itself exhausted the remaining envelope. Shrink only
  // rows above the continuity floor; projectTranscriptPage already compacts an
  // individually oversized item before it can enter this frame.
  const strictTranscript = [...projected.transcript];
  let strictContinuityMessages = transcriptContinuityMessages(strictTranscript);
  let strictRemoved = 0;
  while (strictContinuityMessages > MINIMUM_TRANSCRIPT_CONTINUITY_MESSAGES
    && frameBytes({ ...projected, transcript: strictTranscript }) > maximumBytes) {
    const shifted = strictTranscript.shift();
    if (shifted && !(shifted.kind === "message" && shifted.role === "toolResult")) {
      strictContinuityMessages -= 1;
    }
    strictRemoved += 1;
  }
  projected = {
    ...projected,
    transcript: strictTranscript,
    transcriptStart: projected.transcriptStart + strictRemoved,
  };
  if (frameBytes(projected) <= maximumBytes) return projected;

  const envelopeBytes = frameBytes({ ...projected, transcript: [] });
  const perItemBudget = Math.max(
    256,
    Math.floor(Math.max(0, maximumBytes - envelopeBytes - 2) / Math.max(1, projected.transcript.length)) - 1,
  );
  projected = {
    ...projected,
    transcript: projected.transcript.map((item) => compactTranscriptPageItem(item, perItemBudget)),
  };
  if (frameBytes(projected) <= maximumBytes) return projected;

  // The caller may provide a test-only envelope smaller than the legal metadata
  // floor. Preserve strict transport safety and the newest canonical rows when
  // even compacted continuity cannot fit.
  const unavoidableTrim = [...projected.transcript];
  let unavoidableRemoved = 0;
  while (unavoidableTrim.length > 0
    && frameBytes({ ...projected, transcript: unavoidableTrim }) > maximumBytes) {
    unavoidableTrim.shift();
    unavoidableRemoved += 1;
  }
  return {
    ...projected,
    transcript: unavoidableTrim,
    transcriptStart: projected.transcriptStart + unavoidableRemoved,
  };
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
const ATTACHMENT_PRIVATE_ATTRIBUTE = /\s+(?:path|upload-id)\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]*)/gi;

function safeAttachmentFallback(value: string): string {
  return value.replace(ATTACHMENT_LIKE_TAG, (tag) => tag.replace(ATTACHMENT_PRIVATE_ATTRIBUTE, ""));
}

function unescapeXML(value: string): string {
  return value
    .replaceAll("&quot;", '"')
    .replaceAll("&gt;", ">")
    .replaceAll("&lt;", "<")
    .replaceAll("&amp;", "&");
}

const OWNED_UPLOAD_PATH = /\/([0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})\/[^/]+$/i;

function uploadIdentity(path: string): string | undefined {
  return OWNED_UPLOAD_PATH.exec(path)?.[1];
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
    const uploadId = attributes.get("upload-id") ?? (path ? uploadIdentity(path) : undefined);
    if (!name || !mimeType || !path || !Number.isSafeInteger(size) || size < 0) continue;

    const leading = safeAttachmentFallback(text.slice(cursor, match.index)).replace(/\s+$/, "");
    if (leading) {
      const ordinal = nextIndex();
      projected.push({ id: `${ownerId}:${ordinal}`, ordinal, type: "text", text: boundedText(leading) });
    }
    const ordinal = nextIndex();
    projected.push({
      id: `${ownerId}:${ordinal}`,
      ordinal,
      type: "text",
      text: name,
      attachment: { name, mimeType, size },
      ...(uploadId ? { blobId: `upload:${uploadId}` } : {}),
    });
    cursor = match.index + match[0].length;
  }
  if (projected.length === 0) {
    const ordinal = nextIndex();
    return [{ id: `${ownerId}:${ordinal}`, ordinal, type: "text", text: boundedText(safeAttachmentFallback(text)) }];
  }
  const trailing = safeAttachmentFallback(text.slice(cursor)).replace(/^\s+/, "");
  if (trailing) {
    const ordinal = nextIndex();
    projected.push({ id: `${ownerId}:${ordinal}`, ordinal, type: "text", text: boundedText(trailing) });
  }
  return projected;
}

export function toolGroupId(presentationId: string, firstOrdinal: number): string {
  return `tool-group:${JSON.stringify([presentationId, firstOrdinal])}`;
}

function decorateToolGroups(parts: ContentPart[], presentationId: string, finalized: boolean): ContentPart[] {
  if (!finalized) {
    return parts.map((part) => part.type === "toolCall"
      ? { ...part, groupFinalized: false }
      : part);
  }
  let index = 0;
  while (index < parts.length) {
    if (parts[index]?.type !== "toolCall") { index += 1; continue; }
    const start = index;
    while (index < parts.length && parts[index]?.type === "toolCall") index += 1;
    const count = index - start;
    const first = parts[start]!;
    if (first.type !== "toolCall") continue;
    const groupId = toolGroupId(presentationId, first.ordinal);
    for (let offset = 0; offset < count; offset += 1) {
      const part = parts[start + offset]!;
      if (part.type === "toolCall") {
        parts[start + offset] = { ...part, groupId, groupIndex: offset, groupCount: count, groupFinalized: true };
      }
    }
  }
  return parts;
}

function projectContent(content: ProjectableContent, blobs: BlobStore, ownerId: string, extractAttachments = false, finalizedToolGroups = false): ContentPart[] {
  const source = typeof content === "string" ? [{ type: "text" as const, text: content }] : content;
  const projected: ContentPart[] = [];
  let bytes = 2;
  let outputIndex = 0;
  let activeThinkingRunOrdinal: number | undefined;
  const nextIndex = () => outputIndex++;
  for (const part of source) {
    let candidates: ContentPart[] = [];
    if (part.type !== "thinking") activeThinkingRunOrdinal = undefined;
    switch (part.type) {
      case "text":
        candidates = extractAttachments
          ? projectUserText(part.text, ownerId, nextIndex)
          : (() => {
            const ordinal = nextIndex();
            return [{ id: `${ownerId}:${ordinal}`, ordinal, type: "text", text: boundedText(part.text) }];
          })();
        break;
      case "image": {
        const ordinal = nextIndex();
        const id = `${ownerId}:${ordinal}`;
        try {
          candidates = [{ id, ordinal, type: "image", mimeType: part.mimeType, blobId: blobs.register(part.data, part.mimeType) }];
        } catch (error) {
          if (!(error instanceof GatewayError) || (error.code !== "conflict" && error.code !== "busy")) throw error;
          candidates = [{ id, ordinal, type: "text", text: "Image omitted from this bounded mobile projection" }];
        }
        break;
      }
      case "thinking": {
        const ordinal = nextIndex();
        activeThinkingRunOrdinal ??= ordinal;
        candidates = [{
          id: `${ownerId}:${ordinal}`,
          ordinal,
          thinkingRunOrdinal: activeThinkingRunOrdinal,
          type: "thinking",
          text: boundedText(part.thinking),
          ...(part.redacted ? { redacted: true } : {}),
        }];
        break;
      }
      case "toolCall": {
        const ordinal = nextIndex();
        candidates = [{ id: `${ownerId}:${ordinal}`, ordinal, type: "toolCall", toolCallId: part.id, name: part.name, arguments: projectJson(part.arguments) }];
        break;
      }
    }
    for (const candidate of candidates) {
      if (projected.length >= MAX_CONTENT_PARTS - 1) {
        const ordinal = nextIndex();
        projected.push({ id: `${ownerId}:truncated:${ordinal}`, ordinal, type: "text", text: "… additional content omitted from this mobile projection" });
        return decorateToolGroups(projected, ownerId, finalizedToolGroups);
      }
      const candidateBytes = Buffer.byteLength(JSON.stringify(candidate)) + 1;
      if (bytes + candidateBytes > MAX_CONTENT_BYTES) {
        const ordinal = nextIndex();
        projected.push({ id: `${ownerId}:truncated:${ordinal}`, ordinal, type: "text", text: "… additional content omitted from this mobile projection" });
        return decorateToolGroups(projected, ownerId, finalizedToolGroups);
      }
      projected.push(candidate);
      bytes += candidateBytes;
    }
  }
  return decorateToolGroups(projected, ownerId, finalizedToolGroups);
}

export interface ToolProjectionMetadata {
  groupId?: string;
  groupIndex?: number;
  groupCount?: number;
  groupFinalized?: boolean;
  startedAt: string;
  completedAt?: string;
  durationMs?: number;
  lastProgressAt: string;
  progressSequence: number;
  extensionOrigin?: ExtensionToolOrigin;
}

export function projectMessage(
  id: string,
  parentId: string | null,
  timestamp: string,
  message: AgentMessage,
  blobs: BlobStore,
  toolMetadata?: ToolProjectionMetadata,
  presentationId = id,
  finalizedToolGroups = true,
): TranscriptItem | undefined {
  switch (message.role) {
    case "user":
      return {
        id, parentId, timestamp, kind: "message", role: "user", presentationId,
        content: projectContent(message.content, blobs, presentationId, true),
      };
    case "assistant":
      return {
        id,
        parentId,
        timestamp,
        kind: "message",
        role: "assistant",
        presentationId,
        content: projectContent(message.content, blobs, presentationId, false, finalizedToolGroups),
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
        presentationId,
        content: projectContent(message.content, blobs, presentationId),
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
          ...(toolMetadata.extensionOrigin ? { extensionOrigin: toolMetadata.extensionOrigin } : {}),
          ...(toolMetadata.groupId ? { groupId: toolMetadata.groupId } : {}),
          ...(toolMetadata.groupIndex === undefined ? {} : { groupIndex: toolMetadata.groupIndex }),
          ...(toolMetadata.groupCount === undefined ? {} : { groupCount: toolMetadata.groupCount }),
          ...(toolMetadata.groupFinalized === undefined ? {} : { groupFinalized: toolMetadata.groupFinalized }),
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
  presentationIDs?: ReadonlyMap<string, string>,
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
        entry.message.role === "assistant" ? (presentationIDs?.get(entry.id) ?? entry.id) : entry.id,
        entry.message.role === "assistant",
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
      // Canonical lifecycle receipts are session audit facts, not transcript,
      // tree, or model-visible conversation entries.
      if (entry.customType === EXTENSION_ACTIVITY_RECEIPT_TYPE) return undefined;
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

export const COMMAND_CATALOG_ITEMS = 1_000;
export const COMMAND_CATALOG_STRING_BYTES = 8_192;
export const COMMAND_CATALOG_BYTES = 700_000;

/** Validates the complete runtime-owned command catalog before generic JSON
 * projection can silently trim it. Ordering and object identity are preserved. */
export function admitCommandCatalog(commands: CommandInfo[]): CommandInfo[] {
  if (commands.length > COMMAND_CATALOG_ITEMS) {
    throw new GatewayError("conflict", "Command catalog exceeds its item limit");
  }
  const identities = new Set<string>();
  for (const command of commands) {
    const fields = [command.name, command.description, command.argumentHint, command.sourcePath];
    const identity = `${command.source}:${command.name}`;
    if (typeof command.name !== "string" || command.name.length === 0
      || !["extension", "skill", "prompt"].includes(command.source)
      || fields.some((field) => field !== undefined
        && (typeof field !== "string" || Buffer.byteLength(field) > COMMAND_CATALOG_STRING_BYTES))
      || identities.has(identity)) {
      throw new GatewayError("conflict", "Command catalog contains an invalid or duplicate command");
    }
    identities.add(identity);
  }
  if (Buffer.byteLength(JSON.stringify(commands)) > COMMAND_CATALOG_BYTES) {
    throw new GatewayError("conflict", "Command catalog exceeds its encoded byte limit");
  }
  return commands;
}

// safeJson intentionally bounds arrays to 1,000 values. Keep the tree page
// within that generic transport bound so selected nodes are never discarded
// after projectTree has chosen the newest useful history.
export const MAX_TREE_NODES = 1_000;
export const TREE_PROJECTION_BYTES = 700_000;
export const TREE_PROJECTION_STRING_BYTES = 8_192;

function validateProjectedTreeNode(node: SessionTreeNode): void {
  const required = [node.id, node.kind];
  const optionalNonempty = [node.parentId ?? undefined, node.label, node.role];
  if (!isGatewayTimestamp(node.timestamp)
    || required.some((field) => typeof field !== "string" || field.length === 0
      || Buffer.byteLength(field) > TREE_PROJECTION_STRING_BYTES)
    || optionalNonempty.some((field) => field !== undefined
      && (typeof field !== "string" || field.length === 0
        || Buffer.byteLength(field) > TREE_PROJECTION_STRING_BYTES))
    || typeof node.preview !== "string" || Buffer.byteLength(node.preview) > TREE_PROJECTION_STRING_BYTES) {
    throw new GatewayError("conflict", "Session tree contains an invalid or oversized string");
  }
}

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
    if (source.entry.type === "custom" && source.entry.customType === EXTENSION_ACTIVITY_RECEIPT_TYPE) {
      // Preserve descendants while omitting the reserved audit node itself.
      for (let index = source.children.length - 1; index >= 0; index -= 1) {
        work.push({ source: source.children[index]!, depth });
      }
      continue;
    }
    if (byId.has(source.entry.id)) {
      throw new GatewayError("conflict", "Session tree contains a duplicate canonical entry ID");
    }
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
  const canonicalEntryIDs = new Set<string>();
  for (const entry of entries) {
    if (canonicalEntryIDs.has(entry.id)) {
      throw new GatewayError("conflict", "Session tree contains a duplicate canonical entry ID");
    }
    canonicalEntryIDs.add(entry.id);
  }
  for (let index = entries.length - 1; index >= 0 && selected.length < MAX_TREE_NODES; index -= 1) {
    const node = byId.get(entries[index]!.id);
    if (!node) continue;
    validateProjectedTreeNode(node);
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
      && !(entry.type === "custom" && entry.customType === EXTENSION_ACTIVITY_RECEIPT_TYPE)
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
  /** Exact next projected entry at `end`, echoed so clients can validate the
   * page boundary without treating raw parent links as display adjacency. */
  nextEntryId?: string;
  runtimeGeneration?: string;
  leafEntryId?: string;
}

export function projectTranscriptPage(
  manager: SessionManager,
  blobs: BlobStore,
  before?: number,
  byteBudget = TRANSCRIPT_PAGE_BYTES,
  expectedNextEntryId?: string,
  toolMetadata?: ReadonlyMap<string, ToolProjectionMetadata>,
  presentationIDs?: ReadonlyMap<string, string>,
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
    const item = projectEntry(entries[start - 1]!, blobs, toolMetadata, presentationIDs);
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
  return {
    items: selected,
    start,
    end,
    total: entries.length,
    ...(entries[end]?.id ? { nextEntryId: entries[end].id } : {}),
  };
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
    presentationId: item.kind === "message" ? item.presentationId : item.id,
    content: [{ id: `${item.id}:truncated:0`, ordinal: 0, type: "text", text: "… transcript item omitted from this mobile page" }],
  };
}
