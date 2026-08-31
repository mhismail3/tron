import type { AgentMessage } from "@earendil-works/pi-agent-core";
import type { SessionEntry, SessionManager, SessionTreeNode as PiSessionTreeNode } from "@earendil-works/pi-coding-agent";

type TranscriptSessionReader = Pick<SessionManager, "getBranch"> & Partial<Pick<SessionManager, "getSessionId">>;

/**
 * Returns exact tool-call IDs whose results are already owned by the current
 * canonical branch. Runtime tool state is a disposable overlay; once Pi has
 * persisted this exact result, callers must not publish a second runtime copy,
 * even when the result is outside the bounded transcript tail.
 */
export function canonicalToolResultCallIDs(manager: TranscriptSessionReader): ReadonlySet<string> {
  const result = new Set<string>();
  for (const entry of manager.getBranch()) {
    if (entry.type === "message" && entry.message.role === "toolResult") {
      result.add(entry.message.toolCallId);
    }
  }
  return result;
}
import type { ImageContent, TextContent } from "@earendil-works/pi-ai";
import { GatewayError } from "../errors.js";
import { trustedExtensionOriginKind } from "../extensions/owner-attribution.js";
import { isGatewayTimestamp } from "../util/timestamp.js";
import type { BlobStore } from "./blob-store.js";
import { EXTENSION_ACTIVITY_RECEIPT_TYPE } from "./extension-activity-history.js";
import type { ChatOrigin, ChatSemanticMetadata, CommandInfo, ContentPart, ExtensionSurface, ExtensionToolOrigin, JsonValue, ContextDeliveryMetadata, SessionSnapshot, SessionTreeNode, TranscriptItem } from "../protocol/types.js";
import { contextDeliveryMetadataByEntry } from "./context-delivery-receipts.js";
import { INVOCATION_RECEIPT_TYPE, invocationProjection, invocationReceipts, parseInvocationReceipt, type InvocationProjection } from "./invocation-receipts.js";
import { EXTENSION_NOTIFICATION_RECEIPT_TYPE, parseExtensionNotificationReceipt } from "./extension-notification-receipts.js";
import { RESOURCE_NAME_MAX_BYTES } from "./resource-invocation.js";

const MAX_TEXT = 64_000;
const MAX_SKILL_INVOCATION_BYTES = 4 * 1_048_576;
const MAX_SKILL_NAME_BYTES = 512;
const MAX_SKILL_PATH_BYTES = 8_192;
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

function semanticForCustom(
  display: boolean,
  contextDelivery?: ContextDeliveryMetadata,
  sequence = 0,
): ChatSemanticMetadata {
  const origin: ChatOrigin = contextDelivery?.origin?.owner
    ? { kind: trustedExtensionOriginKind(contextDelivery.origin.owner), ownerId: contextDelivery.origin.owner.id, title: contextDelivery.origin.owner.title, confidence: "receipt" }
    : { kind: "unknown", confidence: "unknown" };
  return {
    version: 1,
    direction: display ? "inboundContext" : "hiddenInternal",
    contextEffect: display ? "modelInput" : contextDelivery ? "hiddenModelInput" : "none",
    delivery: contextDelivery?.delivery ?? "stored",
    visibility: display ? "visible" : "hidden",
    kind: "message",
    origin,
    sequence,
  };
}

function semanticForMessage(role: "user" | "assistant" | "toolResult", invocation?: InvocationProjection): ChatSemanticMetadata {
  const isUser = role === "user";
  const isTool = role === "toolResult";
  return {
    version: 1,
    direction: isUser ? "inboundContext" : isTool ? "agentInvocation" : "agentOutput",
    contextEffect: isTool ? "toolResult" : "modelInput",
    delivery: isTool ? "toolResult" : "stored",
    visibility: "visible",
    kind: isTool ? "tool" : "prompt",
    origin: { kind: isUser ? "user" : isTool ? "assistant" : "assistant", confidence: "boundary" },
    sequence: 0,
    ...(invocation?.resourceInvocation ? { resourceInvocation: invocation.resourceInvocation } : {}),
    ...(invocation ? { invocationId: invocation.invocationId, operationId: invocation.operationId } : {}),
  };
}

function semanticForCommand(receipt: ReturnType<typeof parseInvocationReceipt>): ChatSemanticMetadata {
  return {
    version: 1,
    direction: "ambientStatus",
    contextEffect: "none",
    delivery: "stored",
    visibility: "visible",
    kind: "command",
    origin: receipt && "origin" in receipt && receipt.origin
      ? receipt.origin : { kind: "extension", confidence: "receipt" },
    ...(receipt?.invocationId ? { invocationId: receipt.invocationId } : {}),
    ...(receipt?.operationId ? { operationId: receipt.operationId } : {}),
    ...(receipt && "lifecycle" in receipt ? { lifecycle: receipt.lifecycle } : {}),
    ...(receipt && "name" in receipt && receipt.name ? {
      resourceInvocation: {
        source: "extension",
        name: receipt.name,
        arguments: "arguments" in receipt ? receipt.arguments ?? "" : "",
      },
    } : {}),
    sequence: receipt?.sequence ?? 0,
  };
}

function semanticForExtensionNotification(
  receipt: NonNullable<ReturnType<typeof parseExtensionNotificationReceipt>>,
): ChatSemanticMetadata {
  return {
    version: 1,
    direction: "ambientStatus",
    contextEffect: "none",
    delivery: "stored",
    visibility: "visible",
    kind: "status",
    origin: receipt.origin,
    ...(receipt.invocationId ? { invocationId: receipt.invocationId } : {}),
    ...(receipt.operationId ? { operationId: receipt.operationId } : {}),
    sequence: receipt.sequence,
  };
}

function semanticForStatus(sequence = 0): ChatSemanticMetadata {
  return {
    version: 1,
    direction: "ambientStatus",
    contextEffect: "none",
    delivery: "stored",
    visibility: "visible",
    kind: "status",
    origin: { kind: "gateway", confidence: "boundary" },
    sequence,
  };
}

function semanticForState(sequence = 0): ChatSemanticMetadata {
  return {
    version: 1,
    direction: "hiddenInternal",
    contextEffect: "none",
    delivery: "stored",
    visibility: "hidden",
    kind: "state",
    origin: { kind: "extension", confidence: "unknown" },
    sequence,
  };
}

export interface ProjectedSkillInvocation {
  resourceName: string;
  text: string;
}

/**
 * Recognizes only Pi's exact persisted skill envelope. Malformed, oversized,
 * nested, or future shapes remain untouched rather than risking content loss.
 */
export function projectSkillInvocation(value: string, expectedArguments?: string): ProjectedSkillInvocation | undefined {
  if (!value.startsWith("<skill name=\"") || Buffer.byteLength(value) > MAX_SKILL_INVOCATION_BYTES) return undefined;
  const headerEnd = value.indexOf(">\n");
  if (headerEnd < 0 || headerEnd > MAX_SKILL_NAME_BYTES + MAX_SKILL_PATH_BYTES + 64) return undefined;
  const header = value.slice(0, headerEnd + 1);
  const match = /^<skill name="([A-Za-z0-9][A-Za-z0-9._-]*)" location="([^"\r\n]+)">$/.exec(header);
  if (!match) return undefined;
  const [, resourceName, location] = match;
  if (!resourceName || !location
      || Buffer.byteLength(resourceName) > MAX_SKILL_NAME_BYTES
      || Buffer.byteLength(location) > MAX_SKILL_PATH_BYTES) return undefined;
  const bodyStart = headerEnd + 2;
  const referenceEnd = value.indexOf("\n\n", bodyStart);
  if (referenceEnd < 0) return undefined;
  const reference = value.slice(bodyStart, referenceEnd);
  const referencePrefix = "References are relative to ";
  if (!reference.startsWith(referencePrefix) || !reference.endsWith(".")) return undefined;
  const baseDir = reference.slice(referencePrefix.length, -1);
  if (!baseDir || /[\r\n]/u.test(baseDir) || Buffer.byteLength(baseDir) > MAX_SKILL_PATH_BYTES) return undefined;
  const closing = "\n</skill>";
  // Delimiter-like text can occur in skill Markdown or user arguments. Exact
  // receipt arguments disambiguate it; without them, multiple candidates fail
  // closed rather than dropping user text or exposing private skill content.
  let closingIndex = value.lastIndexOf(closing);
  if (expectedArguments !== undefined) {
    let matched = false;
    let candidate = value.indexOf(closing, referenceEnd + 2);
    while (candidate >= 0) {
      const candidateTail = value.slice(candidate + closing.length);
      if ((candidateTail === "" && expectedArguments === "")
        || (candidateTail.startsWith("\n\n") && candidateTail.slice(2) === expectedArguments)) {
        closingIndex = candidate;
        matched = true;
        break;
      }
      candidate = value.indexOf(closing, candidate + closing.length);
    }
    if (!matched) return undefined;
  } else {
    const firstClosingIndex = value.indexOf(closing, referenceEnd + 2);
    if (firstClosingIndex !== closingIndex) return undefined;
  }
  if (closingIndex < referenceEnd + 2) return undefined;
  const tail = value.slice(closingIndex + closing.length);
  if (tail !== "" && !tail.startsWith("\n\n")) return undefined;
  return { resourceName, text: tail === "" ? "" : tail.slice(2) };
}

function projectedSkillText(value: string): string {
  const invocation = projectSkillInvocation(value);
  if (invocation) return invocation.text;
  return value.startsWith("<skill name=\"")
    ? "Skill invocation omitted from this bounded mobile projection"
    : value;
}

function projectableUserContent(content: ProjectableContent, expectedSkillArguments?: string): ProjectableContent {
  if (typeof content === "string") return expectedSkillArguments === undefined
    ? projectedSkillText(content)
    : projectSkillInvocation(content, expectedSkillArguments)?.text ?? projectedSkillText(content);
  const first = content[0];
  if (first?.type !== "text") return content;
  const text = expectedSkillArguments === undefined
    ? projectedSkillText(first.text)
    : projectSkillInvocation(first.text, expectedSkillArguments)?.text ?? projectedSkillText(first.text);
  if (text === first.text) return content;
  return [{ ...first, text }, ...content.slice(1)];
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

  // Process output is a bounded convenience projection. Canonical command
  // results and child transcripts remain available independently, so shed the
  // duplicated tails before sacrificing transcript continuity or authority.
  if (projected.processActivities?.length) {
    projected = {
      ...projected,
      processActivities: projected.processActivities.map((activity) => {
        const { outputTail: _outputTail, ...metadata } = activity;
        return _outputTail === undefined ? activity : { ...metadata, outputTruncated: true };
      }),
    };
  }
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
        // Status attribution is structurally owned by the corresponding
        // status key. Clear both halves atomically under wire pressure;
        // retaining an orphan owner makes the authoritative snapshot invalid
        // to native admission and can strand an otherwise healthy session.
        statusOwners: {},
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

export function toolSegmentId(ownerId: string): string {
  return `tool-segment:${JSON.stringify(ownerId)}`;
}

function decorateToolGroups(
  parts: ContentPart[],
  presentationId: string,
  finalized: boolean,
  segmentId?: string,
): ContentPart[] {
  if (!finalized) {
    return parts.map((part) => part.type === "toolCall"
      ? { ...part, ...(segmentId ? { toolSegmentId: segmentId } : {}), groupFinalized: false }
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
        parts[start + offset] = {
          ...part,
          ...(segmentId ? { toolSegmentId: segmentId } : {}),
          groupId,
          groupIndex: offset,
          groupCount: count,
          groupFinalized: true,
        };
      }
    }
  }
  return parts;
}

function projectContent(
  content: ProjectableContent,
  blobs: BlobStore,
  ownerId: string,
  extractAttachments = false,
  finalizedToolGroups = false,
  toolLabels?: ReadonlyMap<string, string>,
  segmentId?: string,
): ContentPart[] {
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
        const label = toolLabels?.get(part.name);
        candidates = [{
          id: `${ownerId}:${ordinal}`,
          ordinal,
          type: "toolCall",
          toolCallId: part.id,
          name: part.name,
          ...(label ? { label } : {}),
          arguments: projectJson(part.arguments),
        }];
        break;
      }
    }
    for (const candidate of candidates) {
      if (projected.length >= MAX_CONTENT_PARTS - 1) {
        const ordinal = nextIndex();
        projected.push({ id: `${ownerId}:truncated:${ordinal}`, ordinal, type: "text", text: "… additional content omitted from this mobile projection" });
        return decorateToolGroups(projected, ownerId, finalizedToolGroups, segmentId);
      }
      const candidateBytes = Buffer.byteLength(JSON.stringify(candidate)) + 1;
      if (bytes + candidateBytes > MAX_CONTENT_BYTES) {
        const ordinal = nextIndex();
        projected.push({ id: `${ownerId}:truncated:${ordinal}`, ordinal, type: "text", text: "… additional content omitted from this mobile projection" });
        return decorateToolGroups(projected, ownerId, finalizedToolGroups, segmentId);
      }
      projected.push(candidate);
      bytes += candidateBytes;
    }
  }
  return decorateToolGroups(projected, ownerId, finalizedToolGroups, segmentId);
}

export interface ToolProjectionMetadata {
  toolSegmentId?: string;
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
  toolLabel?: string;
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
  toolLabels?: ReadonlyMap<string, string>,
  contextDelivery?: ContextDeliveryMetadata,
  segmentId?: string,
  expectedSkillArguments?: string,
): TranscriptItem | undefined {
  switch (message.role) {
    case "user":
      return {
        id, parentId, timestamp, kind: "message", role: "user", presentationId,
        content: projectContent(projectableUserContent(message.content, expectedSkillArguments), blobs, presentationId, true),
        semantic: semanticForMessage("user"),
      };
    case "assistant":
      return {
        id,
        parentId,
        timestamp,
        kind: "message",
        role: "assistant",
        presentationId,
        content: projectContent(
          message.content,
          blobs,
          presentationId,
          false,
          finalizedToolGroups,
          toolLabels,
          segmentId,
        ),
        provider: message.provider,
        modelId: message.model,
        stopReason: message.stopReason,
        ...(message.errorMessage ? { errorMessage: boundedText(message.errorMessage) } : {}),
        usage: projectJson(message.usage),
        semantic: semanticForMessage("assistant"),
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
        ...(toolLabels?.get(message.toolName) ? { toolLabel: toolLabels.get(message.toolName)! } : {}),
        isError: message.isError,
        ...(message.details === undefined ? {} : { details: projectJson(message.details) }),
        ...(message.usage === undefined ? {} : { usage: projectJson(message.usage) }),
        semantic: semanticForMessage("toolResult"),
        ...(toolMetadata ? {
          startedAt: toolMetadata.startedAt,
          ...(toolMetadata.completedAt ? { completedAt: toolMetadata.completedAt } : {}),
          ...(toolMetadata.durationMs === undefined ? {} : { durationMs: toolMetadata.durationMs }),
          lastProgressAt: toolMetadata.lastProgressAt,
          progressSequence: toolMetadata.progressSequence,
          ...(toolMetadata.extensionOrigin ? { extensionOrigin: toolMetadata.extensionOrigin } : {}),
          ...(toolMetadata.toolLabel ? { toolLabel: toolMetadata.toolLabel } : {}),
          ...(toolMetadata.toolSegmentId ? { toolSegmentId: toolMetadata.toolSegmentId } : {}),
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
        ...(toolMetadata ? {
          startedAt: toolMetadata.startedAt,
          ...(toolMetadata.completedAt ? { completedAt: toolMetadata.completedAt } : {}),
          ...(toolMetadata.durationMs === undefined ? {} : { durationMs: toolMetadata.durationMs }),
        } : {}),
        semantic: {
          version: 1,
          direction: "agentInvocation",
          contextEffect: message.excludeFromContext ? "none" : "toolResult",
          delivery: "toolResult",
          visibility: "visible",
          kind: "tool",
          origin: { kind: "assistant", confidence: "boundary" },
          sequence: 0,
        },
      };
    case "custom":
      // Producer-hidden custom messages remain context-only. They are
      // intentionally excluded from the ordinary chat projection; canonical
      // JSONL and typed receipts retain them for audit/reconciliation.
      if (!message.display) return undefined;
      return {
        id,
        parentId,
        timestamp,
        kind: "customMessage",
        customType: message.customType,
        content: projectContent(message.content, blobs, id),
        ...(message.details === undefined ? {} : { details: projectJson(message.details) }),
        semantic: semanticForCustom(message.display === true, contextDelivery),
      };
    case "branchSummary":
      return { id, parentId, timestamp, kind: "branchSummary", summary: boundedText(message.summary), semantic: semanticForStatus() };
    case "compactionSummary":
      return {
        id,
        parentId,
        timestamp,
        kind: "compaction",
        summary: boundedText(message.summary),
        tokensBefore: message.tokensBefore,
        semantic: semanticForStatus(),
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
  toolLabels?: ReadonlyMap<string, string>,
  contextDelivery?: ContextDeliveryMetadata,
  segmentId?: string,
  expectedSkillArguments?: string,
  bashMetadata?: ReadonlyMap<string, ToolProjectionMetadata>,
): TranscriptItem | undefined {
  switch (entry.type) {
    case "message":
      return projectMessage(
        entry.id,
        entry.parentId,
        entry.timestamp,
        entry.message,
        blobs,
        entry.message.role === "toolResult"
          ? toolMetadata?.get(entry.message.toolCallId)
          : entry.message.role === "bashExecution"
            ? bashMetadata?.get(entry.id)
            : undefined,
        presentationIDs?.get(entry.id) ?? entry.id,
        entry.message.role === "assistant",
        toolLabels,
        contextDelivery,
        segmentId,
        expectedSkillArguments,
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
        semantic: semanticForCustom(entry.display === true, contextDelivery),
      };
    case "custom": {
      // Arbitrary extension state stays canonical in Pi JSONL but never
      // consumes a chat row. Only Gateway-authored, strictly validated command
      // and notification receipts receive typed transcript presentation.
      if (entry.customType === EXTENSION_NOTIFICATION_RECEIPT_TYPE) {
        const notification = parseExtensionNotificationReceipt(entry.data);
        if (!notification) return undefined;
        return {
          id: entry.id,
          parentId: entry.parentId,
          timestamp: entry.timestamp,
          kind: "customEntry",
          customType: entry.customType,
          data: projectJson(notification),
          semantic: semanticForExtensionNotification(notification),
        };
      }
      if (entry.customType !== INVOCATION_RECEIPT_TYPE) return undefined;
      const invocation = parseInvocationReceipt(entry.data);
      if (!invocation || invocation.receiptKind !== "start" || invocation.source !== "extension") return undefined;
      return {
        id: entry.id,
        parentId: entry.parentId,
        timestamp: entry.timestamp,
        kind: "customEntry",
        customType: entry.customType,
        semantic: semanticForCommand(invocation),
      };
    }
    case "compaction": {
      const presentationId = presentationIDs?.get(entry.id);
      return {
        id: entry.id,
        parentId: entry.parentId,
        timestamp: entry.timestamp,
        kind: "compaction",
        ...(presentationId === undefined ? {} : { presentationId }),
        summary: boundedText(entry.summary),
        tokensBefore: entry.tokensBefore,
        ...(entry.details === undefined ? {} : { details: projectJson(entry.details) }),
        ...(entry.usage === undefined ? {} : { usage: projectJson(entry.usage) }),
        ...(entry.fromHook === undefined ? {} : { fromHook: entry.fromHook }),
        semantic: semanticForStatus(),
      };
    }
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
        semantic: semanticForStatus(),
      };
    case "model_change":
      return {
        id: entry.id,
        parentId: entry.parentId,
        timestamp: entry.timestamp,
        kind: "modelChange",
        modelRef: { provider: entry.provider, id: entry.modelId },
        semantic: semanticForStatus(),
      };
    case "thinking_level_change":
      return { id: entry.id, parentId: entry.parentId, timestamp: entry.timestamp, kind: "thinkingChange", level: entry.thinkingLevel, semantic: semanticForStatus() };
    case "label":
      return {
        id: entry.id,
        parentId: entry.parentId,
        timestamp: entry.timestamp,
        kind: "label",
        targetId: entry.targetId,
        ...(entry.label ? { label: entry.label } : {}),
        semantic: semanticForStatus(),
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
export const COMMAND_DETAIL_CONTENT_BYTES = 96 * 1_024;

export interface BoundedCommandContent {
  content: string;
  contentBytes: number;
  contentTruncated: boolean;
}

/** Keeps selected resource content bounded without making the complete command
 * catalog carry every source document. UTF-8 decoding drops only a split final
 * code point when truncation lands inside a multibyte scalar. */
export function boundCommandContent(content: string): BoundedCommandContent {
  const encoded = Buffer.from(content, "utf8");
  if (encoded.byteLength <= COMMAND_DETAIL_CONTENT_BYTES) {
    return { content, contentBytes: encoded.byteLength, contentTruncated: false };
  }
  let end = COMMAND_DETAIL_CONTENT_BYTES;
  while (end > 0 && (encoded[end]! & 0xC0) === 0x80) end -= 1;
  return {
    content: encoded.subarray(0, end).toString("utf8"),
    contentBytes: encoded.byteLength,
    contentTruncated: true,
  };
}

/** Validates the complete runtime-owned command catalog before generic JSON
 * projection can silently trim it. Ordering and object identity are preserved. */
export function admitCommandCatalog(commands: CommandInfo[]): CommandInfo[] {
  if (commands.length > COMMAND_CATALOG_ITEMS) {
    throw new GatewayError("conflict", "Command catalog exceeds its item limit");
  }
  const identities = new Set<string>();
  for (const command of commands) {
    const fields = [
      command.name,
      command.description,
      command.argumentHint,
      command.sourcePath,
      command.resourceSource,
    ];
    const identity = `${command.source}:${command.name}`;
    if (typeof command.name !== "string" || command.name.length === 0
      || Buffer.byteLength(command.name) > RESOURCE_NAME_MAX_BYTES || /\s/u.test(command.name)
      || !["extension", "skill", "prompt"].includes(command.source)
      || command.resourceScope !== undefined
        && !["user", "project", "temporary"].includes(command.resourceScope)
      || command.resourceOrigin !== undefined
        && !["package", "top-level"].includes(command.resourceOrigin)
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

function validTreeString(value: unknown, optional = false): boolean {
  return optional && value === undefined
    || typeof value === "string" && value.length > 0 && Buffer.byteLength(value) <= TREE_PROJECTION_STRING_BYTES;
}

function validContentPart(value: unknown): boolean {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const part = value as Record<string, unknown>;
  switch (part.type) {
    case "text": return typeof part.text === "string";
    case "thinking": return typeof part.thinking === "string";
    case "image": return typeof part.mimeType === "string" && typeof part.data === "string";
    case "toolCall": return typeof part.id === "string" && typeof part.name === "string"
      && Object.prototype.hasOwnProperty.call(part, "arguments");
    default: return false;
  }
}

function validMessage(value: unknown): boolean {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const message = value as Record<string, unknown>;
  if (typeof message.role !== "string" || !Number.isFinite(message.timestamp as number)) return false;
  switch (message.role) {
    case "user":
      return (typeof message.content === "string"
        || Array.isArray(message.content) && message.content.every(validContentPart));
    case "assistant":
      return Array.isArray(message.content) && message.content.every(validContentPart)
        && typeof message.api === "string" && typeof message.provider === "string"
        && typeof message.model === "string" && !!message.usage && typeof message.usage === "object"
        && typeof message.stopReason === "string";
    case "toolResult":
      return Array.isArray(message.content) && message.content.every(validContentPart)
        && typeof message.toolCallId === "string" && typeof message.toolName === "string"
        && typeof message.isError === "boolean";
    case "bashExecution":
      return typeof message.command === "string" && typeof message.output === "string"
        && (message.exitCode === undefined || Number.isSafeInteger(message.exitCode))
        && typeof message.cancelled === "boolean" && typeof message.truncated === "boolean";
    case "custom":
      return typeof message.customType === "string"
        && (typeof message.content === "string"
          || Array.isArray(message.content) && message.content.every(validContentPart))
        && typeof message.display === "boolean";
    case "branchSummary":
      return typeof message.fromId === "string" && typeof message.summary === "string";
    case "compactionSummary":
      return typeof message.summary === "string" && Number.isSafeInteger(message.tokensBefore);
    default:
      return false;
  }
}

/** Validate canonical shape without calling projectEntry/projectContent. This
 * keeps omitted history fail-closed while reserving blob registration for an
 * already admitted tree candidate. */
function validateCanonicalEntry(value: unknown): void {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new GatewayError("conflict", "Session tree contains a malformed canonical entry");
  }
  const entry = value as Record<string, unknown>;
  if (!validTreeString(entry.id) || (entry.parentId !== null && !validTreeString(entry.parentId))
    || typeof entry.type !== "string") {
    throw new GatewayError("conflict", "Session tree contains an invalid canonical entry");
  }
  if (typeof entry.timestamp !== "string" || !isGatewayTimestamp(entry.timestamp)) {
    throw new GatewayError("conflict", "Session tree contains an invalid or oversized string");
  }
  let valid = false;
  if (typeof entry.customType === "string" && Buffer.byteLength(entry.customType) > TREE_PROJECTION_STRING_BYTES) {
    throw new GatewayError("conflict", "Session tree contains an invalid or oversized string");
  }
  switch (entry.type) {
    case "message": valid = validMessage(entry.message); break;
    case "thinking_level_change": valid = validTreeString(entry.thinkingLevel); break;
    case "model_change": valid = validTreeString(entry.provider) && validTreeString(entry.modelId); break;
    case "compaction":
      valid = validTreeString(entry.summary) && validTreeString(entry.firstKeptEntryId)
        && Number.isSafeInteger(entry.tokensBefore); break;
    case "branch_summary":
      valid = validTreeString(entry.fromId) && validTreeString(entry.summary); break;
    case "custom": valid = validTreeString(entry.customType); break;
    case "custom_message":
      valid = validTreeString(entry.customType)
        && (typeof entry.content === "string"
          || Array.isArray(entry.content) && entry.content.every(validContentPart))
        && typeof entry.display === "boolean"; break;
    case "label": valid = validTreeString(entry.targetId) && (entry.label === undefined || validTreeString(entry.label)); break;
    case "session_info": valid = entry.name === undefined || validTreeString(entry.name); break;
    default: valid = false;
  }
  if (!valid) throw new GatewayError("conflict", "Session tree contains an invalid canonical entry payload");
}

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
  contextDelivery?: ContextDeliveryMetadata,
): SessionTreeNode {
  const item = projectEntry(node.entry, blobs, undefined, undefined, undefined, contextDelivery);
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

interface TreeProjectionRef {
  source: PiSessionTreeNode;
  depth: number;
}

// A dry projector preserves the exact projected shape without registering image
// bytes. Real BlobStore registration occurs only after a candidate is admitted.
const treeProjectionProbe = { register: () => "x".repeat(43) } as unknown as BlobStore;

function validateSourceTreeNode(source: PiSessionTreeNode, expectedParentId: string | null, depth: number): void {
  if (!source || typeof source !== "object") throw new GatewayError("conflict", "Session tree contains a malformed node");
  const raw = source as unknown as Record<string, unknown>;
  const entry = raw.entry as Record<string, unknown> | undefined;
  const children = raw.children;
  if (!entry || typeof entry !== "object" || !Array.isArray(children)
    || entry.parentId !== expectedParentId
    || children.length > MAX_TREE_NODES * 2 || depth > MAX_TREE_NODES * 32) {
    throw new GatewayError("conflict", "Session tree contains a malformed node");
  }
  validateCanonicalEntry(entry);
  if (raw.label !== undefined && !validTreeString(raw.label)) {
    throw new GatewayError("conflict", "Session tree contains an invalid or oversized string");
  }
}

export function projectTree(manager: SessionManager, blobs: BlobStore): SessionTreeNode[] {
  const canonicalRoots = manager.getTree();
  const currentPath = new Set(manager.getBranch().map((entry) => entry.id));
  const contextDelivery = contextDeliveryMetadataByEntry(manager.getEntries());
  const byId = new Map<string, TreeProjectionRef>();
  const seenSourceIDs = new Set<string>();
  const work: Array<{ source: PiSessionTreeNode; depth: number; parentId: string | null }> = [];
  for (let index = canonicalRoots.length - 1; index >= 0; index -= 1) {
    work.push({ source: canonicalRoots[index]!, depth: 0, parentId: null });
  }
  while (work.length > 0) {
    const { source, depth, parentId } = work.pop()!;
    validateSourceTreeNode(source, parentId, depth);
    if (source.entry.type === "custom" && source.entry.customType === INVOCATION_RECEIPT_TYPE
        && parseInvocationReceipt(source.entry.data) === undefined) {
      throw new GatewayError("conflict", "Session contains a malformed Gateway invocation receipt");
    }
    const id = source.entry.id;
    if (seenSourceIDs.has(id)) throw new GatewayError("conflict", "Session tree contains a duplicate canonical entry ID");
    seenSourceIDs.add(id);
    const treeInvocation = source.entry.type === "custom"
      && source.entry.customType === INVOCATION_RECEIPT_TYPE
      ? parseInvocationReceipt(source.entry.data)
      : undefined;
    const isHiddenCanonical = source.entry.type === "custom" && (
      treeInvocation?.receiptKind !== "start" || treeInvocation.source !== "extension"
    );
    if (!isHiddenCanonical) byId.set(id, { source, depth });
    const childDepth = isHiddenCanonical ? depth : depth + 1;
    // Preserve descendants while omitting reserved audit nodes themselves.
    for (let index = source.children.length - 1; index >= 0; index -= 1) {
      work.push({ source: source.children[index]!, depth: childDepth, parentId: id });
    }
  }

  const entries = manager.getEntries();
  const canonicalEntryIDs = new Set<string>();
  for (const entry of entries) {
    validateCanonicalEntry(entry);
    if (canonicalEntryIDs.has(entry.id)) throw new GatewayError("conflict", "Session tree contains a duplicate canonical entry ID");
    canonicalEntryIDs.add(entry.id);
    const entryInvocation = entry.type === "custom" && entry.customType === INVOCATION_RECEIPT_TYPE
      ? parseInvocationReceipt(entry.data)
      : undefined;
    const omittedReceipt = entry.type === "custom" && (
      entryInvocation?.receiptKind !== "start" || entryInvocation.source !== "extension"
    );
    if (!omittedReceipt && !byId.has(entry.id)) {
      throw new GatewayError("conflict", "Session tree omits a canonical entry");
    }
  }

  // Admit the newest canonical entries first, then restore chronological order.
  // Dry projection is intentionally side-effect free so omitted images never
  // consume BlobStore capacity.
  const selected: SessionTreeNode[] = [];
  let bytes = 2;
  for (let index = entries.length - 1; index >= 0 && selected.length < MAX_TREE_NODES; index -= 1) {
    const ref = byId.get(entries[index]!.id);
    if (!ref) continue;
    const candidate = projectedTreeNode(
      ref.source, treeProjectionProbe, ref.depth, currentPath, contextDelivery.get(ref.source.entry.id),
    );
    validateProjectedTreeNode(candidate);
    const nodeBytes = Buffer.byteLength(JSON.stringify(candidate)) + 1;
    if (bytes + nodeBytes > TREE_PROJECTION_BYTES) break;
    const admitted = projectedTreeNode(
      ref.source, blobs, ref.depth, currentPath, contextDelivery.get(ref.source.entry.id),
    );
    validateProjectedTreeNode(admitted);
    bytes += Buffer.byteLength(JSON.stringify(admitted)) + 1;
    selected.push(admitted);
  }
  return selected.reverse();
}

/** Filter the canonical branch and derive tool segments in the same pass. The
 * identity begins at exact conversation input, survives tool-only assistant and
 * result entries, and retires at visible or non-conversation barriers. This
 * keeps cold reopen and live delivery equivalent without adding another O(N)
 * transcript walk or persisting presentation metadata to Pi JSONL. */
function projectableTranscriptEntries(
  manager: TranscriptSessionReader,
  presentationIDs?: ReadonlyMap<string, string>,
): {
  entries: SessionEntry[];
  contextDelivery: ReadonlyMap<string, ContextDeliveryMetadata>;
  toolSegmentIDs: ReadonlyMap<string, string>;
} {
  const branch = manager.getBranch();
  const contextDelivery = contextDeliveryMetadataByEntry(branch);
  const entries: SessionEntry[] = [];
  const toolSegmentIDs = new Map<string, string>();
  let ownerId: string | undefined;
  for (const entry of branch) {
    if (entry.type === "custom" && entry.customType === INVOCATION_RECEIPT_TYPE
        && parseInvocationReceipt(entry.data) === undefined) {
      throw new GatewayError("conflict", "Session contains a malformed Gateway invocation receipt");
    }
    if (entry.type === "custom" && entry.customType === EXTENSION_NOTIFICATION_RECEIPT_TYPE
        && parseExtensionNotificationReceipt(entry.data) === undefined) {
      throw new GatewayError("conflict", "Session contains a malformed Gateway extension notification receipt");
    }
    const invocation = entry.type === "custom" && entry.customType === INVOCATION_RECEIPT_TYPE
      ? parseInvocationReceipt(entry.data)
      : undefined;
    const notification = entry.type === "custom" && entry.customType === EXTENSION_NOTIFICATION_RECEIPT_TYPE
      ? parseExtensionNotificationReceipt(entry.data)
      : undefined;
    const projectableCustom = entry.type !== "custom"
      || invocation?.receiptKind === "start" && invocation.source === "extension"
      || notification !== undefined;
    const projectable = entry.type !== "session_info"
      && projectableCustom
      && !(entry.type === "custom_message" && !entry.display)
      && !(entry.type === "message" && entry.message.role === "custom"
        && !entry.message.display);
    if (!projectable) continue;
    entries.push(entry);

    const presentationId = presentationIDs?.get(entry.id) ?? entry.id;
    if (contextDelivery.has(entry.id)) {
      ownerId = presentationId;
      continue;
    }
    if (entry.type !== "message") {
      ownerId = undefined;
      continue;
    }
    if (entry.message.role === "user") {
      ownerId = presentationId;
      continue;
    }
    if (entry.message.role === "toolResult") continue;
    if (entry.message.role !== "assistant") {
      ownerId = undefined;
      continue;
    }
    const content = typeof entry.message.content === "string"
      ? [{ type: "text" as const, text: entry.message.content }]
      : entry.message.content;
    const lastToolIndex = content.findLastIndex((part) => part.type === "toolCall");
    if (lastToolIndex >= 0) {
      ownerId ??= presentationId;
      toolSegmentIDs.set(entry.id, toolSegmentId(ownerId));
    }
    // A barrier after the final declaration retires the segment. Content before
    // a declaration starts that displayed run and must not split later tool-only
    // continuations from the same producer turn on cold reconstruction.
    const lastBarrierIndex = content.findLastIndex((part) => part.type !== "toolCall");
    if (lastToolIndex < 0 || lastBarrierIndex > lastToolIndex) ownerId = undefined;
  }
  return { entries, contextDelivery, toolSegmentIDs };
}

function durableInvocationLifecycle(lifecycle: InvocationProjection["lifecycle"]): InvocationProjection["lifecycle"] {
  return ["completed", "failed", "interrupted", "outcomeUnknown"].includes(lifecycle)
    ? lifecycle
    : "outcomeUnknown";
}

export function projectTranscript(
  manager: TranscriptSessionReader,
  blobs: BlobStore,
  toolMetadata?: ReadonlyMap<string, ToolProjectionMetadata>,
  toolLabels?: ReadonlyMap<string, string>,
  bashMetadata?: ReadonlyMap<string, ToolProjectionMetadata>,
): TranscriptItem[] {
  const { entries, contextDelivery, toolSegmentIDs } = projectableTranscriptEntries(manager);
  const invocationValues = invocationProjection(invocationReceipts(
    manager.getBranch(),
    manager.getSessionId?.(),
  ));
  const invocationStates = new Map(invocationValues.map((value) => [value.invocationId, value.lifecycle]));
  const invocationByCanonicalEntry = new Map(invocationValues
    .filter(value => value.canonicalEntryId !== undefined)
    .map(value => [value.canonicalEntryId!, value]));
  return entries.map((entry) => {
    const boundInvocation = invocationByCanonicalEntry.get(entry.id);
    const expectedSkillArguments = boundInvocation?.resourceInvocation?.source === "skill"
      ? boundInvocation.resourceInvocation.arguments : undefined;
    const projected = projectEntry(
      entry,
      blobs,
      toolMetadata,
      undefined,
      toolLabels,
      contextDelivery.get(entry.id),
      toolSegmentIDs.get(entry.id),
      expectedSkillArguments,
      bashMetadata,
    );
    if (!projected) throw new Error("projectable transcript entry produced no item");
    if (boundInvocation && projected.semantic) {
      return { ...projected, semantic: {
        ...projected.semantic,
        invocationId: boundInvocation.invocationId,
        operationId: boundInvocation.operationId,
        kind: "resourcePrompt",
        ...(boundInvocation.resourceInvocation ? { resourceInvocation: boundInvocation.resourceInvocation } : {}),
        lifecycle: boundInvocation.lifecycle,
      } };
    }
    if (projected.semantic?.invocationId && invocationStates.has(projected.semantic.invocationId)) {
      const lifecycle = invocationStates.get(projected.semantic.invocationId)!;
      return { ...projected, semantic: {
        ...projected.semantic,
        lifecycle: projected.semantic.kind === "command"
          ? durableInvocationLifecycle(lifecycle)
          : lifecycle,
      } };
    }
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
  manager: TranscriptSessionReader,
  blobs: BlobStore,
  before?: number,
  byteBudget = TRANSCRIPT_PAGE_BYTES,
  expectedNextEntryId?: string,
  toolMetadata?: ReadonlyMap<string, ToolProjectionMetadata>,
  presentationIDs?: ReadonlyMap<string, string>,
  toolLabels?: ReadonlyMap<string, string>,
  bashMetadata?: ReadonlyMap<string, ToolProjectionMetadata>,
): TranscriptPage {
  const { entries, contextDelivery, toolSegmentIDs } = projectableTranscriptEntries(
    manager,
    presentationIDs,
  );
  const invocationValues = invocationProjection(invocationReceipts(
    manager.getBranch(),
    manager.getSessionId?.(),
  ));
  const invocationStates = new Map(invocationValues.map((value) => [value.invocationId, value.lifecycle]));
  const invocationByCanonicalEntry = new Map(invocationValues
    .filter(value => value.canonicalEntryId !== undefined)
    .map(value => [value.canonicalEntryId!, value]));
  const end = Math.max(0, Math.min(before ?? entries.length, entries.length));
  if (expectedNextEntryId !== undefined && entries[end]?.id !== expectedNextEntryId) {
    throw new Error("session transcript anchor changed");
  }
  let start = end;
  let bytes = 2;
  const selected: TranscriptItem[] = [];
  while (start > 0 && selected.length < TRANSCRIPT_PAGE_ITEMS) {
    const entry = entries[start - 1]!;
    const boundInvocation = invocationByCanonicalEntry.get(entry.id);
    const expectedSkillArguments = boundInvocation?.resourceInvocation?.source === "skill"
      ? boundInvocation.resourceInvocation.arguments : undefined;
    const item = projectEntry(
      entry,
      blobs,
      toolMetadata,
      presentationIDs,
      toolLabels,
      contextDelivery.get(entry.id),
      toolSegmentIDs.get(entry.id),
      expectedSkillArguments,
      bashMetadata,
    );
    if (!item) throw new Error("projectable transcript entry produced no item");
    const enriched = boundInvocation && item.semantic
      ? { ...item, semantic: {
          ...item.semantic,
          invocationId: boundInvocation.invocationId,
          operationId: boundInvocation.operationId,
          kind: "resourcePrompt" as const,
          ...(boundInvocation.resourceInvocation ? { resourceInvocation: boundInvocation.resourceInvocation } : {}),
          lifecycle: boundInvocation.lifecycle,
        } }
      : item.semantic?.invocationId && invocationStates.has(item.semantic.invocationId)
        ? { ...item, semantic: {
            ...item.semantic,
            lifecycle: item.semantic.kind === "command"
              ? durableInvocationLifecycle(invocationStates.get(item.semantic.invocationId)!)
              : invocationStates.get(item.semantic.invocationId)!,
          } }
        : item;
    const itemBytes = Buffer.byteLength(JSON.stringify(enriched)) + 1;
    if (bytes + itemBytes > byteBudget && selected.length > 0) break;
    if (itemBytes > byteBudget) {
      // session.transcript responses are not passed through the snapshot fitter.
      // Compact an unexpectedly oversized legal item before returning it so the
      // page both advances and stays inside its production wire budget.
      selected.unshift(compactTranscriptPageItem(enriched, Math.max(256, byteBudget - 3)));
      start -= 1;
      break;
    }
    selected.unshift(enriched);
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
    const notification = item.semantic?.kind === "status" ? item.data as Record<string, JsonValue> | undefined : undefined;
    compacted = notification && typeof notification.message === "string"
      ? {
          ...item,
          data: {
            message: utf8Prefix(notification.message, Math.max(64, byteBudget - 2_048)),
            tone: typeof notification.tone === "string" ? notification.tone : "info",
            truncated: true,
          },
        }
      : { ...item, data: { truncated: true, preview: "Oversized custom entry omitted from mobile page." } };
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
