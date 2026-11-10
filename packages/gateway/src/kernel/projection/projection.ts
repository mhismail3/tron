import { isAbsolute } from "node:path";
import { redactedUpstreamError, upstreamErrorInfo } from "../../util/upstream-error.js";
import type { AgentMessage } from "../pi/agent-core.js";
import type { SessionEntry, SessionManager, SessionTreeNode as PiSessionTreeNode } from "../pi/coding-agent.js";

type TranscriptSessionReader = Pick<SessionManager, "getBranch"> & Partial<Pick<SessionManager, "getSessionId">>;

export function canonicalToolResultCallIDsFromBranch(branch: readonly SessionEntry[]): ReadonlySet<string> {
  const result = new Set<string>();
  for (const entry of branch) {
    if (entry.type === "message" && entry.message.role === "toolResult") {
      result.add(entry.message.toolCallId);
    }
  }
  return result;
}

export function canonicalToolResultCallIDs(manager: TranscriptSessionReader): ReadonlySet<string> {
  return canonicalToolResultCallIDsFromBranch(manager.getBranch());
}
import { GatewayError } from "../../errors.js";
import { jsonNodeCount } from "../../protocol/json-budget.js";
import type { ToolDisplayProjection } from "./tool-result.js";
import { trustedExtensionOriginKind } from "./extension-origin.js";
import { isGatewayTimestamp } from "../../util/timestamp.js";
import { boundedUtf8Prefix, boundedUtf8Suffix, TRUNCATION_MARKER } from "../../util/bounded-text.js";
import type { BlobStore } from "../../sessions/blob-store.js";
import { projectForkBoundary, type ForkBoundaryAnchor } from "../../sessions/fork-boundary.js";
import type { ChatOrigin, ChatSemanticMetadata, InvocationLifecycle, CommandInfo, ContentPart, ExtensionToolOrigin, JsonValue, NestedToolCallsProjection, ContextDeliveryMetadata, SessionSnapshot, SessionTreeNode, TranscriptForkBoundary, TranscriptItem } from "../../protocol/types.js";
import { contextDeliveryMetadataByEntry } from "../receipts/context-delivery-receipts.js";
import { INVOCATION_RECEIPT_TYPE, invocationProjection, invocationReceipts, parseInvocationReceipt, type InvocationProjection } from "../receipts/invocation-receipts.js";
import { EXTENSION_NOTIFICATION_RECEIPT_TYPE, parseExtensionNotificationReceipt } from "../receipts/extension-notification-receipts.js";
import { projectSkillInvocation, RESOURCE_NAME_MAX_BYTES } from "../resources/resource-invocation.js";

const MAX_TEXT = 64_000;
const MAX_JSON_STRING = 100_000;
const MAX_PROJECTED_JSON_BYTES = 96_000;
const MAX_CONTENT_BYTES = 320_000;
const MAX_CONTENT_PARTS = 1_000;
const COMPACT_LIVE_TOOL_JSON_BYTES = 12_000;
const MAX_LIVE_TOOL_OUTPUT_BYTES = 48_000;
const TRANSCRIPT_PAGE_BYTES = 600_000;
const TRANSCRIPT_PAGE_ITEMS = 512;
const TRANSCRIPT_PAGE_NODES = 24_000;
const SESSION_SNAPSHOT_NODES = 30_000;
const MINIMUM_TRANSCRIPT_CONTINUITY_MESSAGES = 24;
const SESSION_SNAPSHOT_BYTES = 800_000;
const STREAMING_PROGRESS_BYTES = 24_000;

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
    ...(invocation?.resourceInvocations ? { resourceInvocations: invocation.resourceInvocations } : {}),
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
      resourceInvocations: [{
        source: "extension",
        name: receipt.name,
        arguments: "arguments" in receipt ? receipt.arguments ?? "" : "",
      }],
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

function projectedSkillText(value: string): string {
  const invocation = projectSkillInvocation(value);
  if (invocation) return invocation.text;
  return value.startsWith("<skill name=\"")
    ? "Skill invocation omitted from this bounded mobile projection"
    : value;
}

function invokedResourceText(invocation: InvocationProjection | undefined): string | undefined {
  if (!invocation?.resourceInvocations?.some(resource => resource.source !== "extension")) return undefined;
  return invocation.submittedText ?? invocation.arguments ?? "";
}

function projectableUserContent(content: ProjectableContent, resourceText?: string): ProjectableContent {
  if (typeof content === "string") return resourceText ?? projectedSkillText(content);
  const first = content[0];
  if (first?.type !== "text") return content;
  const text = resourceText ?? projectedSkillText(first.text);
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
      const result: JsonValue[] = [];
      const length = Math.min(value.length, 1_000);
      for (let index = 0; index < length; index += 1) {
        result.push(safeJson(value[index], depth + 1, seen));
      }
      seen.delete(value);
      return result;
    }
    const result: Record<string, JsonValue> = {};
    const usedKeys = new Set<string>();
    let entries = 0;
    for (const key in value) {
      if (!Object.prototype.hasOwnProperty.call(value, key)) continue;
      if (entries >= 1_000) break;
      const keyLimit = MAX_JSON_STRING;
      const keyMarker = TRUNCATION_MARKER;
      const baseKey = Buffer.byteLength(key) <= keyLimit
        ? key
        : `${boundedUtf8Prefix(key, keyLimit - Buffer.byteLength(keyMarker))}${keyMarker}`;
      let boundedKey = baseKey;
      let collision = 2;
      while (usedKeys.has(boundedKey)) {
        const suffix = `${keyMarker}${collision}`;
        boundedKey = `${boundedUtf8Prefix(baseKey, keyLimit - Buffer.byteLength(suffix))}${suffix}`;
        collision += 1;
      }
      usedKeys.add(boundedKey);
      Object.defineProperty(result, boundedKey, { value: safeJson((value as Record<string, unknown>)[key], depth + 1, seen),
        enumerable: true, configurable: true, writable: true });
      entries += 1;
    }
    seen.delete(value);
    return result;
  }
  return null;
}

function boundedUtf8Tail(value: string, maximumBytes: number): { value: string; truncated: boolean } {
  const bounded = boundedUtf8Suffix(value, maximumBytes);
  return { value: bounded, truncated: bounded.length !== value.length };
}

export function projectToolOutput(value: unknown, maximumBytes = MAX_LIVE_TOOL_OUTPUT_BYTES, toolName?: string): {
  output?: string;
  outputTruncated?: true;
} {
  const retainedNewestFirst: string[] = [];
  let retainedBytes = 0;
  let truncated = false;
  const addNewest = (text: string): boolean => {
    if (!text) return false;
    const textBytes = Buffer.byteLength(text);
    if (retainedNewestFirst.length === 0) {
      const kept = textBytes <= maximumBytes ? text : boundedUtf8Suffix(text, maximumBytes);
      retainedNewestFirst.unshift(kept);
      retainedBytes = Buffer.byteLength(kept);
      if (textBytes > maximumBytes) truncated = true;
      return truncated;
    }
    const capacity = maximumBytes - retainedBytes - 1;
    if (capacity <= 0) {
      truncated = true;
      return true;
    }
    if (textBytes > capacity) {
      retainedNewestFirst.unshift(boundedUtf8Suffix(text, capacity));
      retainedBytes = maximumBytes;
      truncated = true;
      return true;
    }
    retainedNewestFirst.unshift(text);
    retainedBytes += textBytes + 1;
    return false;
  };
  const visitReverse = (candidate: unknown, depth = 0, filterCodemodeImageLabels = false): boolean => {
    if (depth > 4 || candidate === null || candidate === undefined) return false;
    if (typeof candidate === "string") return addNewest(candidate);
    if (Array.isArray(candidate)) {
      for (let index = candidate.length - 1; index >= 0; index -= 1) {
        if (filterCodemodeImageLabels && index > 0) {
          const visiblePair = visibleToolResultContent("codemode", [candidate[index - 1], candidate[index]]);
          if (visiblePair.length === 1) {
            if (visitReverse(visiblePair[0], depth + 1)) return true;
            index -= 1;
            continue;
          }
        }
        if (visitReverse(candidate[index], depth + 1)) return true;
      }
      return false;
    }
    if (typeof candidate !== "object") return false;
    const record = candidate as Record<string, unknown>;
    if (record.type === "text" && typeof record.text === "string") return addNewest(record.text);
    if (Array.isArray(record.content)) return visitReverse(record.content, depth + 1);
    if (typeof record.output === "string") return addNewest(record.output);
    if (typeof record.text === "string") return addNewest(record.text);
    return false;
  };
  if (value && typeof value === "object" && !Array.isArray(value)) {
    const record = value as Record<string, unknown>;
    if (Array.isArray(record.content)) {
      visitReverse(record.content, 1, toolName === "codemode");
    } else {
      visitReverse(value);
    }
  } else {
    visitReverse(value);
  }
  if (retainedNewestFirst.length === 0) return {};
  const output = retainedNewestFirst.join("\n");
  if (!truncated) return { output };
  const marker = "… earlier live output truncated by gateway …\n";
  const markerBytes = Buffer.byteLength(marker);
  if (maximumBytes <= markerBytes) {
    return { output: boundedUtf8Suffix(output, maximumBytes), outputTruncated: true };
  }
  return {
    output: marker + boundedUtf8Suffix(output, maximumBytes - markerBytes),
    outputTruncated: true,
  };
}

export function mergeLiveToolOutput(
  previous: { output?: string; outputTruncated?: boolean } | undefined,
  incoming: { output?: string; outputTruncated?: true },
  maximumBytes = MAX_LIVE_TOOL_OUTPUT_BYTES,
): { output?: string; outputTruncated?: true } {
  if (incoming.output) {
    if (Buffer.byteLength(incoming.output) > maximumBytes) return projectToolOutput(incoming.output, maximumBytes);
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

export function projectToolResult(value: unknown, maximumBytes = 24_000, toolName?: string): JsonValue {
  if (!value || typeof value !== "object" || Array.isArray(value)) return projectJson(value, maximumBytes);
  const record = value as Record<string, unknown>;
  if (!Array.isArray(record.content)) {
    if (!Object.hasOwn(record, "structuredContent")) return projectJson(record, maximumBytes);
    const minimal: Record<string, unknown> = {};
    let fields = 0;
    for (const key in record) {
      if (!Object.prototype.hasOwnProperty.call(record, key) || key === "structuredContent") continue;
      if (fields++ >= 1_000) break;
      minimal[key] = record[key];
    }
    return projectJson(minimal, maximumBytes);
  }
  let truncated = false;
  const content = visibleToolResultContent(toolName ?? "", record.content.slice(-128)).map((part) => {
    if (!part || typeof part !== "object" || Array.isArray(part)) return part;
    const source = part as Record<string, unknown>;
    const result: Record<string, unknown> = {};
    let fields = 0;
    for (const key in source) {
      if (!Object.prototype.hasOwnProperty.call(source, key)) continue;
      if (fields >= 1_000) break;
      const field = source[key];
      if (key === "text" && typeof field === "string") {
        const bounded = boundedUtf8Tail(field, Math.max(0, maximumBytes - 1_024));
        result[key] = bounded.value;
        truncated ||= bounded.truncated;
      } else {
        result[key] = field;
      }
      fields += 1;
    }
    return result;
  });
  const projectedRecord: Record<string, unknown> = { content };
  let properties = 1;
  for (const key in record) {
    if (!Object.prototype.hasOwnProperty.call(record, key) || key === "content" || key === "structuredContent") continue;
    if (properties >= 1_000) break;
    projectedRecord[key] = record[key];
    properties += 1;
  }
  const bounded = projectJson(projectedRecord, maximumBytes);
  if (!truncated || typeof bounded !== "object" || bounded === null || Array.isArray(bounded)) return bounded;
  return { ...bounded, truncated: true };
}

export const NESTED_CALL_LIMIT = 256;
export const NESTED_ARGUMENT_CALL_BYTES = 1_024;
export const NESTED_ARGUMENT_TOTAL_BYTES = 32 * 1_024;

function projectNestedCalls(value: unknown): NestedToolCallsProjection {
  const record = value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown> : {};
  const sourceCalls = Array.isArray(record.calls) ? record.calls : [];
  let complete = record.complete === true;
  let argumentBudget = NESTED_ARGUMENT_TOTAL_BYTES;
  const calls = sourceCalls.slice(0, NESTED_CALL_LIMIT).map((candidate) => {
    const item = candidate && typeof candidate === "object" && !Array.isArray(candidate)
      ? candidate as Record<string, unknown> : {};
    const id = typeof item.id === "string" ? item.id.slice(0, 512) : "";
    const toolName = typeof item.name === "string" ? item.name.slice(0, 256) : "unknown";
    const status: NestedToolCallsProjection["calls"][number]["status"] = item.status === "ok" ? "completed"
      : item.status === "error" ? "failed" : item.status === "unfinished" ? "unfinished" : "running";
    if (status === "unfinished") complete = false;
    const error = typeof item.error === "string" ? boundedUtf8Prefix(item.error, 512) : undefined;
    let args: JsonValue | undefined;
    let argumentsBytes = typeof item.argumentsBytes === "number" && Number.isSafeInteger(item.argumentsBytes)
      ? Math.max(0, item.argumentsBytes) : undefined;
    if (item.arguments !== undefined) {
      let bytes = 0;
      try { bytes = Buffer.byteLength(JSON.stringify(item.arguments)); } catch { bytes = Number.MAX_SAFE_INTEGER; }
      if (bytes <= NESTED_ARGUMENT_CALL_BYTES && bytes <= argumentBudget) {
        args = projectJson(item.arguments, NESTED_ARGUMENT_CALL_BYTES);
        argumentBudget -= bytes;
      } else { argumentsBytes = bytes; complete = false; }
    }
    if (!id) complete = false;
    const durationMs = typeof item.durationMs === "number" && Number.isFinite(item.durationMs)
      ? Math.max(0, Math.round(item.durationMs)) : undefined;
    return {
      id, parentToolCallId: id.includes("/") ? id.slice(0, id.lastIndexOf("/")) : "",
      toolName, status,
      ...(error === undefined ? {} : { error }),
      ...(args === undefined ? {} : { arguments: args }),
      ...(argumentsBytes === undefined ? {} : { argumentsBytes }),
      ...(durationMs === undefined ? {} : { durationMs }),
    };
  }).filter((call) => call.id);
  if (sourceCalls.length > calls.length) complete = false;
  return { calls, complete };
}

interface BudgetedJsonNode {
  value: JsonValue;
  bytes: number;
  truncated: boolean;
}

function jsonBytes(value: JsonValue): number {
  return Buffer.byteLength(JSON.stringify(value));
}

function boundedJsonNode(
  value: unknown,
  maximumBytes: number,
  depth = 0,
  seen = new WeakSet<object>(),
): BudgetedJsonNode {
  if (maximumBytes <= 0) return { value: null, bytes: 4, truncated: true };
  if (value === null || typeof value === "boolean") {
    const projected = value;
    return { value: projected, bytes: jsonBytes(projected), truncated: false };
  }
  if (typeof value === "string") {
    const clipped = value.length <= MAX_JSON_STRING ? value : `${boundedUtf8Prefix(value, MAX_JSON_STRING - Buffer.byteLength(TRUNCATION_MARKER))}${TRUNCATION_MARKER}`;
    const clippedBytes = jsonBytes(clipped);
    if (clippedBytes <= maximumBytes) {
      return { value: clipped, bytes: clippedBytes, truncated: clipped !== value };
    }
    const prefix = boundedUtf8Prefix(clipped, Math.max(0, maximumBytes - 2));
    const projected = prefix;
    return { value: projected, bytes: jsonBytes(projected), truncated: true };
  }
  if (typeof value === "number") {
    const projected = Number.isFinite(value) ? value : String(value);
    const bytes = jsonBytes(projected);
    return { value: projected, bytes, truncated: bytes > maximumBytes };
  }
  if (typeof value === "bigint") {
    const projected = value.toString();
    return { value: projected, bytes: jsonBytes(projected), truncated: projected.length > maximumBytes };
  }
  if (value === undefined || typeof value === "function" || typeof value === "symbol") {
    return { value: null, bytes: 4, truncated: false };
  }
  if (depth >= 12) return { value: "[maximum depth]", bytes: jsonBytes("[maximum depth]"), truncated: false };
  if (seen.has(value)) return { value: "[circular]", bytes: jsonBytes("[circular]"), truncated: false };

  seen.add(value);
  let result: JsonValue;
  let bytes: number;
  let truncated = false;
  if (Array.isArray(value)) {
    const items: JsonValue[] = [];
    bytes = 2;
    const length = Math.min(value.length, 1_000);
    for (let index = 0; index < length; index += 1) {
      const separator = items.length === 0 ? 0 : 1;
      const remaining = maximumBytes - bytes - separator;
      if (remaining < 1) { truncated = true; break; }
      const child = boundedJsonNode(value[index], remaining, depth + 1, seen);
      if (bytes + separator + child.bytes > maximumBytes) { truncated = true; break; }
      items.push(child.value);
      bytes += separator + child.bytes;
      truncated ||= child.truncated;
    }
    if (items.length < length) truncated = true;
    result = items;
  } else {
    const object = value as Record<string, unknown>;
    const output: Record<string, JsonValue> = {};
    const usedKeys = new Set<string>();
    bytes = 2;
    let entries = 0;
    for (const key in object) {
      if (!Object.prototype.hasOwnProperty.call(object, key)) continue;
      if (entries >= 1_000) { truncated = true; break; }
      const boundedKeyBase = Buffer.byteLength(key) <= MAX_JSON_STRING
        ? key
        : `${boundedUtf8Prefix(key, MAX_JSON_STRING - Buffer.byteLength(TRUNCATION_MARKER))}${TRUNCATION_MARKER}`;
      let boundedKey = boundedKeyBase;
      let collision = 2;
      while (usedKeys.has(boundedKey)) {
        const suffix = `…${collision}`;
        boundedKey = `${boundedUtf8Prefix(boundedKeyBase, MAX_JSON_STRING - Buffer.byteLength(suffix))}${suffix}`;
        collision += 1;
      }
      usedKeys.add(boundedKey);
      const keyBytes = jsonBytes(boundedKey);
      const separator = entries === 0 ? 0 : 1;
      const remaining = maximumBytes - bytes - separator - keyBytes - 1;
      if (remaining < 1) { truncated = true; break; }
      const child = boundedJsonNode(object[key], remaining, depth + 1, seen);
      if (bytes + separator + keyBytes + 1 + child.bytes > maximumBytes) {
        truncated = true;
        break;
      }
      Object.defineProperty(output, boundedKey, { value: child.value, enumerable: true, configurable: true, writable: true });
      bytes += separator + keyBytes + 1 + child.bytes;
      entries += 1;
      truncated ||= child.truncated;
    }
    result = output;
  }
  seen.delete(value);
  return { value: result, bytes, truncated };
}

function boundedProjectionEnvelope(preview: string, maximumBytes: number): JsonValue {
  const marker = TRUNCATION_MARKER;
  const envelopeBytes = (candidate: string): number => jsonBytes({ truncated: true, preview: candidate });
  if (envelopeBytes("") <= maximumBytes) {
    let lower = 0;
    let upper = preview.length;
    let best = "";
    while (lower <= upper) {
      const middle = Math.floor((lower + upper) / 2);
      let candidate = preview.slice(0, middle);
      if (candidate.length > 0 && /[\uD800-\uDBFF]$/u.test(candidate)) candidate = candidate.slice(0, -1);
      if (envelopeBytes(candidate + marker) <= maximumBytes) {
        best = candidate;
        lower = middle + 1;
      } else {
        upper = middle - 1;
      }
    }
    const candidate = `${best}${marker}`;
    if (envelopeBytes(candidate) <= maximumBytes) return { truncated: true, preview: candidate };
  }
  if (maximumBytes >= 4) return null;
  if (maximumBytes >= 2) return "";
  return 0;
}

export function projectJson(value: unknown, maximumBytes = MAX_PROJECTED_JSON_BYTES): JsonValue {
  if (!Number.isSafeInteger(maximumBytes) || maximumBytes < 1) throw new RangeError("JSON projection requires a positive byte budget");
  const bounded = boundedJsonNode(value, maximumBytes);
  if (!bounded.truncated && bounded.bytes <= maximumBytes) return bounded.value;
  const preview = boundedUtf8Prefix(JSON.stringify(bounded.value), 24_000);
  return boundedProjectionEnvelope(preview, maximumBytes);
}

export function boundStreamingProgressItem(
  item: TranscriptItem,
  maximumBytes = STREAMING_PROGRESS_BYTES,
): TranscriptItem {
  if (definitelyFitsStreamingFrame(item, maximumBytes)) return item;
  if (frameBytes(item) <= maximumBytes) return item;
  if (item.kind !== "message") return item;
  const toolCount = item.content.filter(part => part.type === "toolCall").length;
  if (toolCount > 0) {
    const omitted = { truncated: true };
    const structure = {
      ...item,
      content: item.content.map(part => part.type === "toolCall" ? { ...part, arguments: omitted } : part),
    };
    const argumentBudget = frameBytes(omitted)
      + Math.floor(Math.max(0, maximumBytes - frameBytes(structure)) / toolCount);
    item = {
      ...item,
      content: item.content.map(part => {
        if (part.type !== "toolCall") return part;
        const encoded = JSON.stringify(part.arguments);
        if (Buffer.byteLength(encoded) <= argumentBudget) return part;
        const prefixBytes = Math.floor((argumentBudget - frameBytes({ truncated: true, preview: TRUNCATION_MARKER })) / 6);
        const argumentsPreview = prefixBytes > 0
          ? { truncated: true, preview: `${boundedUtf8Prefix(encoded, prefixBytes)}${TRUNCATION_MARKER}` }
          : omitted;
        return { ...part, arguments: argumentsPreview };
      }),
    };
    if (frameBytes(item) <= maximumBytes) return item;
  }
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
      const marker = TRUNCATION_MARKER;
      let lower = 0;
      let upper = Math.max(0, Math.min(Buffer.byteLength(part.text), maximumBytes - bytes));
      let best: ContentPart | undefined;
      while (lower <= upper) {
        const candidateBytes = Math.floor((lower + upper) / 2);
        const candidate = { ...part, text: `${marker}${boundedUtf8Suffix(part.text, candidateBytes)}` };
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

function fitsSnapshot(value: unknown, maximumBytes: number): boolean {
  return jsonNodeCount(value, SESSION_SNAPSHOT_NODES, true) <= SESSION_SNAPSHOT_NODES
    && frameBytes(value) <= maximumBytes;
}

function fitTranscriptStructure(items: TranscriptItem[]): TranscriptItem[] {
  if (jsonNodeCount(items, TRANSCRIPT_PAGE_NODES, true) <= TRANSCRIPT_PAGE_NODES) return items;
  const perItemNodes = Math.floor((TRANSCRIPT_PAGE_NODES - 1) / items.length);
  return items.map(item => compactTranscriptPageItem(item, TRANSCRIPT_PAGE_BYTES, perItemNodes));
}

function transcriptContinuityMessages(items: TranscriptItem[]): number {
  return items.reduce((count, item) =>
    count + (item.kind === "message" && item.role === "toolResult" ? 0 : 1), 0);
}

function definitelyFitsStreamingFrame(item: TranscriptItem, maximumBytes: number): boolean {
  if (item.kind !== "message") return false;
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

export function fitSessionSnapshot(snapshot: SessionSnapshot): SessionSnapshot {
  const streaming = snapshot.streaming && boundStreamingProgressItem(snapshot.streaming);
  if (streaming && streaming !== snapshot.streaming) snapshot = { ...snapshot, streaming };
  const transcriptOverflow = Math.max(0, snapshot.transcript.length - TRANSCRIPT_PAGE_ITEMS);
  const transcript = fitTranscriptStructure(transcriptOverflow === 0
    ? snapshot.transcript : snapshot.transcript.slice(transcriptOverflow));
  const countBounded = transcript === snapshot.transcript
    ? snapshot
    : { ...snapshot, transcript, transcriptStart: snapshot.transcriptStart + transcriptOverflow };
  if (fitsSnapshot(countBounded, SESSION_SNAPSHOT_BYTES)) return countBounded;

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
  if (fitsSnapshot(projected, SESSION_SNAPSHOT_BYTES)) return projected;

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
  if (fitsSnapshot(projected, SESSION_SNAPSHOT_BYTES)) return projected;

  if (projected.processActivities?.length) {
    projected = {
      ...projected,
      processActivities: projected.processActivities.map((activity) => {
        const { outputTail: _outputTail, ...metadata } = activity;
        return _outputTail === undefined ? activity : { ...metadata, outputTruncated: true };
      }),
    };
  }
  if (fitsSnapshot(projected, SESSION_SNAPSHOT_BYTES)) return projected;

  let removed = 0;
  const fittedTranscript = [...projected.transcript];
  let fittedContinuityMessages = transcriptContinuityMessages(fittedTranscript);
  while (
    fittedContinuityMessages > MINIMUM_TRANSCRIPT_CONTINUITY_MESSAGES
      && !fitsSnapshot({ ...projected, transcript: fittedTranscript }, SESSION_SNAPSHOT_BYTES)
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
  if (fitsSnapshot(projected, SESSION_SNAPSHOT_BYTES)) return projected;

  const completeSurfaces = [...projected.extensionPresentation.surfaces];
  const omittedSurfaceRevisions: Array<{ id: string; revision: number }> = [];
  for (const removed of completeSurfaces) {
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
    if (fitsSnapshot(projected, SESSION_SNAPSHOT_BYTES)) return projected;
  }

  projected = {
    ...projected,
    extensionPresentation: {
      ...projected.extensionPresentation,
      semanticState: {
        ...projected.extensionPresentation.semanticState,
        statuses: {},
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
  if (fitsSnapshot(projected, SESSION_SNAPSHOT_BYTES)) return projected;

  const { streaming: _streaming, ...withoutStreaming } = projected;
  projected = withoutStreaming;
  if (fitsSnapshot(projected, SESSION_SNAPSHOT_BYTES)) return projected;

  const tools = projected.toolExecutions.slice(-256).map((tool) => {
    const { partialResult: _partialResult, result: _result, ...metadata } = tool;
    const liveOutput = tool.output === undefined
      ? {}
      : {
          output: boundedUtf8Suffix(tool.output, 8 * 1_024),
          ...(Buffer.byteLength(tool.output) > 8 * 1_024 || tool.outputTruncated ? { outputTruncated: true } : {}),
        };
    return { ...metadata, ...liveOutput, arguments: { truncated: true } };
  });
  projected = {
    ...projected,
    toolExecutions: tools,
    diagnostics: [{ type: "projection", message: "Large live detail is available from canonical paged history after the run settles." }],
  };
  if (fitsSnapshot(projected, SESSION_SNAPSHOT_BYTES)) return projected;

  projected = {
    ...projected,
    toolExecutions: tools.map((tool) => {
      const { output: _output, outputTruncated: _outputTruncated, ...metadata } = tool;
      return metadata;
    }),
  };
  if (fitsSnapshot(projected, SESSION_SNAPSHOT_BYTES)) return projected;

  const strictTranscript = [...projected.transcript];
  let strictContinuityMessages = transcriptContinuityMessages(strictTranscript);
  let strictRemoved = 0;
  while (strictContinuityMessages > MINIMUM_TRANSCRIPT_CONTINUITY_MESSAGES
    && !fitsSnapshot({ ...projected, transcript: strictTranscript }, SESSION_SNAPSHOT_BYTES)) {
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
  if (fitsSnapshot(projected, SESSION_SNAPSHOT_BYTES)) return projected;

  const envelopeBytes = frameBytes({ ...projected, transcript: [] });
  const perItemBudget = Math.max(
    256,
    Math.floor(Math.max(0, SESSION_SNAPSHOT_BYTES - envelopeBytes - 2) / Math.max(1, projected.transcript.length)) - 1,
  );
  projected = {
    ...projected,
    transcript: projected.transcript.map((item) => compactTranscriptPageItem(item, perItemBudget)),
  };
  if (fitsSnapshot(projected, SESSION_SNAPSHOT_BYTES)) return projected;

  const unavoidableTrim = [...projected.transcript];
  let unavoidableRemoved = 0;
  while (unavoidableTrim.length > 0
    && !fitsSnapshot({ ...projected, transcript: unavoidableTrim }, SESSION_SNAPSHOT_BYTES)) {
    unavoidableTrim.shift();
    unavoidableRemoved += 1;
  }
  return {
    ...projected,
    transcript: unavoidableTrim,
    transcriptStart: projected.transcriptStart + unavoidableRemoved,
  };
}

type MessageContentBlock<M> = M extends { content: infer C } ? C extends readonly unknown[] ? C[number] : never : never;
export type PiMessageContentBlock = MessageContentBlock<AgentMessage>;

type ProjectableContent = string | readonly PiMessageContentBlock[];

const PI_CODEMODE_IMAGE_SAVED_TEXT = /^\[Image saved to ([^\r\n]+) \((image\/(?:png|jpeg|gif|webp)), (?:\d+B|\d+\.\d(?:KB|MB))\)\]$/;
const PI_CODEMODE_IMAGE_PATH = /(?:^|[\\/])pi-codemode-[a-f0-9]{16}\.(png|jpg|gif|webp)$/;
const PI_CODEMODE_IMAGE_MIME_BY_EXTENSION = {
  png: "image/png",
  jpg: "image/jpeg",
  gif: "image/gif",
  webp: "image/webp",
} as const;

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

function toolGroupId(presentationId: string, firstOrdinal: number): string {
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
      default: {
        part satisfies never;
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

function isPiCodemodeImageSavedText(text: string, followingImageMimeType: string): boolean {
  const saved = PI_CODEMODE_IMAGE_SAVED_TEXT.exec(text);
  if (!saved || saved[2] !== followingImageMimeType || !isAbsolute(saved[1]!)) return false;
  const file = PI_CODEMODE_IMAGE_PATH.exec(saved[1]!);
  return file !== null && PI_CODEMODE_IMAGE_MIME_BY_EXTENSION[file[1] as keyof typeof PI_CODEMODE_IMAGE_MIME_BY_EXTENSION] === saved[2];
}

function visibleToolResultContent<T>(toolName: string, content: readonly T[]): readonly T[] {
  if (toolName !== "codemode") return content;
  let visible: T[] | undefined;
  for (let index = 0; index < content.length; index += 1) {
    const part = content[index] as unknown;
    const following = content[index + 1] as unknown;
    const isText = part !== null && typeof part === "object"
      && (part as Record<string, unknown>).type === "text"
      && typeof (part as Record<string, unknown>).text === "string";
    const isImage = following !== null && typeof following === "object"
      && (following as Record<string, unknown>).type === "image"
      && typeof (following as Record<string, unknown>).mimeType === "string";
    if (isText && isImage && isPiCodemodeImageSavedText(
      (part as { text: string }).text,
      (following as { mimeType: string }).mimeType,
    )) {
      visible ??= content.slice(0, index);
      continue;
    }
    visible?.push(content[index]!);
  }
  return visible ?? content;
}

function projectToolResultContent(content: ProjectableContent, toolName: string, blobs: BlobStore, ownerId: string): ContentPart[] {
  return projectContent(visibleToolResultContent(toolName, typeof content === "string" ? [
    { type: "text", text: content } as PiMessageContentBlock,
  ] : content), blobs, ownerId);
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

export function projectMessage(displayProjection: ToolDisplayProjection,
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
  resourceText?: string,
  ownerSessionId?: string,
): TranscriptItem | undefined {
  switch (message.role) {
    case "user":
      return {
        id, parentId, timestamp, kind: "message", role: "user", presentationId,
        content: projectContent(projectableUserContent(message.content, resourceText), blobs, presentationId, true),
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
        ...(message.thinkingLevel ? { thinkingLevel: message.thinkingLevel } : {}),
        stopReason: message.stopReason,
        ...(message.errorMessage ? {
          errorMessage: boundedText(redactedUpstreamError(message.errorMessage)),
          errorInfo: upstreamErrorInfo(message.errorMessage, message.provider),
        } : {}),
        usage: projectJson(message.usage),
        semantic: semanticForMessage("assistant"),
      };
    case "toolResult": {
      const display = displayProjection(message.toolName, message.details, message.toolCallId, ownerSessionId);
      return {
        id,
        parentId,
        timestamp,
        kind: "message",
        role: "toolResult",
        presentationId,
        content: projectToolResultContent(message.content, message.toolName, blobs, presentationId),
        toolCallId: message.toolCallId,
        toolName: message.toolName,
        ...(toolLabels?.get(message.toolName) ? { toolLabel: toolLabels.get(message.toolName)! } : {}),
        isError: message.isError,
        ...(message.details === undefined ? {} : { details: projectJson(message.details) }),
        ...(display ? { display } : {}),
        ...(message.usage === undefined ? {} : { usage: projectJson(message.usage) }),
        ...(message.nestedCalls === undefined ? {} : { nestedCalls: projectNestedCalls(message.nestedCalls) }),
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
          completedAt: timestamp,
        }),
      };
    }
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
    case "system":
      return undefined;
    default: {
      message satisfies never;
      return undefined;
    }
  }
}

function projectEntry(displayProjection: ToolDisplayProjection,
  entry: SessionEntry,
  blobs: BlobStore,
  toolMetadata?: ReadonlyMap<string, ToolProjectionMetadata>,
  presentationIDs?: ReadonlyMap<string, string>,
  toolLabels?: ReadonlyMap<string, string>,
  contextDelivery?: ContextDeliveryMetadata,
  segmentId?: string,
  resourceText?: string,
  bashMetadata?: ReadonlyMap<string, ToolProjectionMetadata>,
  ownerSessionId?: string,
): TranscriptItem | undefined {
  switch (entry.type) {
    case "message":
      return projectMessage(displayProjection,
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
        resourceText,
        ownerSessionId,
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
    case "usage":
      return undefined;
    case "context_edit":
      return undefined;
    default: {
      entry satisfies never;
      return undefined;
    }
  }
}

function preview(item: TranscriptItem | undefined, entry: SessionEntry): string {
  if (!item) {
    if (entry.type === "session_info") return entry.name ?? "Session renamed";
    if (entry.type === "context_edit") return `Model context edit: ${entry.targetId}`;
    return entry.type;
  }
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

const COMMAND_CATALOG_ITEMS = 1_000;
const COMMAND_CATALOG_STRING_BYTES = 8_192;
const COMMAND_CATALOG_BYTES = 700_000;
const COMMAND_DETAIL_CONTENT_BYTES = 96 * 1_024;

interface BoundedCommandContent {
  content: string;
  contentBytes: number;
  contentTruncated: boolean;
}

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

export function admitCommandCatalog(commands: CommandInfo[]): CommandInfo[] {
  if (commands.length > COMMAND_CATALOG_ITEMS) {
    throw new GatewayError("conflict", "Command catalog exceeds its item limit");
  }
  const identities = new Set<string>();
  for (const command of commands) {
    const fields = [
      command.name, command.title,
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

const MAX_TREE_NODES = 1_000;
const TREE_PROJECTION_BYTES = 700_000;
const TREE_PROJECTION_STRING_BYTES = 8_192;

function validTreeString(value: unknown, optional = false): boolean {
  return optional && value === undefined
    || typeof value === "string" && value.length > 0 && Buffer.byteLength(value) <= TREE_PROJECTION_STRING_BYTES;
}

function validCanonicalSummary(value: unknown): value is string {
  return typeof value === "string" && value.length > 0;
}

function validContentPart(value: unknown): boolean {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const part = value as Record<string, unknown>;
  const type = part.type as PiMessageContentBlock["type"];
  switch (type) {
    case "text": return typeof part.text === "string";
    case "thinking": return typeof part.thinking === "string";
    case "image": return typeof part.mimeType === "string" && typeof part.data === "string";
    case "toolCall": return typeof part.id === "string" && typeof part.name === "string"
      && Object.prototype.hasOwnProperty.call(part, "arguments");
    default: {
      void (type satisfies never);
      return false;
    }
  }
}

function validContextEditableContent(value: unknown): boolean {
  return typeof value === "string" || Array.isArray(value) && value.every(validContentPart);
}

function validMessage(value: unknown): boolean {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const message = value as Record<string, unknown>;
  if (typeof message.role !== "string" || !Number.isFinite(message.timestamp as number)) return false;
  const role = message.role as AgentMessage["role"];
  switch (role) {
    case "system": {
      const sections = message.sections;
      return (typeof message.content === "string" || Array.isArray(message.content) && message.content.every(validContentPart))
        && (sections === undefined || !!sections && typeof sections === "object" && !Array.isArray(sections)
          && Object.entries(sections).every(([key, value]) => validTreeString(key) && (value === null || typeof value === "string")));
    }
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
    default: {
      role satisfies never;
      return false;
    }
  }
}

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
  const type = entry.type as SessionEntry["type"];
  switch (type) {
    case "message": valid = validMessage(entry.message); break;
    case "thinking_level_change": valid = validTreeString(entry.thinkingLevel); break;
    case "model_change": valid = validTreeString(entry.provider) && validTreeString(entry.modelId); break;
    case "compaction":
      valid = validCanonicalSummary(entry.summary) && validTreeString(entry.firstKeptEntryId)
        && Number.isSafeInteger(entry.tokensBefore); break;
    case "branch_summary":
      valid = validTreeString(entry.fromId) && validCanonicalSummary(entry.summary); break;
    case "custom": valid = validTreeString(entry.customType); break;
    case "custom_message":
      valid = validTreeString(entry.customType)
        && (typeof entry.content === "string"
          || Array.isArray(entry.content) && entry.content.every(validContentPart))
        && typeof entry.display === "boolean"; break;
    case "label": valid = validTreeString(entry.targetId) && (entry.label === undefined || validTreeString(entry.label)); break;
    case "session_info": valid = entry.name === undefined || validTreeString(entry.name); break;
    case "usage":
      valid = validTreeString(entry.kind) && validTreeString(entry.provider) && validTreeString(entry.model)
        && !!entry.usage && typeof entry.usage === "object" && !Array.isArray(entry.usage)
        && (entry.note === undefined || validTreeString(entry.note)); break;
    case "context_edit": {
      const replacement = entry.replacement;
      valid = validTreeString(entry.targetId) && (replacement === null
        || !!replacement && typeof replacement === "object" && !Array.isArray(replacement)
          && validContextEditableContent((replacement as Record<string, unknown>).content));
      break;
    }
    default: {
      void (type satisfies never);
      valid = false;
    }
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

function outlineNodeKind(entry: SessionEntry, item: TranscriptItem | undefined): SessionTreeNode["kind"] {
  switch (entry.type) {
    case "context_edit": return "contextEdit";
    case "session_info": return "sessionInfo";
    case "usage": return "usage";
    case "message":
      if (entry.message.role === "system") return "systemMessage";
      return entry.message.role === "custom" && !entry.message.display ? "sessionInfo" : rowKind(item);
    case "custom_message":
      return entry.display ? rowKind(item) : "sessionInfo";
    case "custom": case "compaction": case "branch_summary": case "model_change":
    case "thinking_level_change": case "label":
      return rowKind(item);
    default: {
      entry satisfies never;
      return "sessionInfo";
    }
  }
}

function rowKind(item: TranscriptItem | undefined): SessionTreeNode["kind"] {
  return item?.kind ?? "sessionInfo";
}

function projectedTreeNode(displayProjection: ToolDisplayProjection,
  node: PiSessionTreeNode,
  blobs: BlobStore,
  depth: number,
  currentPath: Set<string>,
  contextDelivery?: ContextDeliveryMetadata,
): SessionTreeNode {
  const item = projectEntry(displayProjection, node.entry, blobs, undefined, undefined, undefined, contextDelivery);
  return {
    id: node.entry.id,
    parentId: node.entry.parentId,
    timestamp: node.entry.timestamp,
    kind: outlineNodeKind(node.entry, item),
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

function omittedFromTreeOutline(
  entry: SessionEntry,
  invocation: ReturnType<typeof parseInvocationReceipt>,
): boolean {
  switch (entry.type) {
    case "usage": return true;
    case "custom": return invocation?.receiptKind !== "start" || invocation.source !== "extension";
    case "message": case "custom_message": case "thinking_level_change": case "model_change":
    case "compaction": case "branch_summary": case "context_edit": case "label": case "session_info":
      return false;
    default: {
      entry satisfies never;
      return false;
    }
  }
}

export function projectTree(displayProjection: ToolDisplayProjection, manager: SessionManager, blobs: BlobStore): SessionTreeNode[] {
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
    const isHiddenCanonical = omittedFromTreeOutline(source.entry, treeInvocation);
    if (!isHiddenCanonical) byId.set(id, { source, depth });
    const childDepth = isHiddenCanonical ? depth : depth + 1;
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
    const omitted = omittedFromTreeOutline(entry, entryInvocation);
    if (!omitted && !byId.has(entry.id)) {
      throw new GatewayError("conflict", "Session tree omits a canonical entry");
    }
  }

  const selected: SessionTreeNode[] = [];
  let bytes = 2;
  for (let index = entries.length - 1; index >= 0 && selected.length < MAX_TREE_NODES; index -= 1) {
    const ref = byId.get(entries[index]!.id);
    if (!ref) continue;
    const candidate = projectedTreeNode(displayProjection,
      ref.source, treeProjectionProbe, ref.depth, currentPath, contextDelivery.get(ref.source.entry.id),
    );
    validateProjectedTreeNode(candidate);
    const nodeBytes = Buffer.byteLength(JSON.stringify(candidate)) + 1;
    if (bytes + nodeBytes > TREE_PROJECTION_BYTES) break;
    const admitted = projectedTreeNode(displayProjection,
      ref.source, blobs, ref.depth, currentPath, contextDelivery.get(ref.source.entry.id),
    );
    validateProjectedTreeNode(admitted);
    bytes += Buffer.byteLength(JSON.stringify(admitted)) + 1;
    selected.push(admitted);
  }
  return selected.reverse();
}

function projectableMessageRole(message: AgentMessage): boolean {
  switch (message.role) {
    case "custom": return message.display;
    case "user": case "assistant": case "toolResult": case "bashExecution":
    case "branchSummary": case "compactionSummary":
      return true;
    case "system":
      return false;
    default: {
      message satisfies never;
      return false;
    }
  }
}

function transcriptRowFor(
  entry: SessionEntry,
  invocation: ReturnType<typeof parseInvocationReceipt>,
  notification: ReturnType<typeof parseExtensionNotificationReceipt>,
): boolean {
  switch (entry.type) {
    case "message": return projectableMessageRole(entry.message);
    case "custom_message": return entry.display;
    case "custom": return invocation?.receiptKind === "start" && invocation.source === "extension"
      || notification !== undefined;
    case "thinking_level_change": case "model_change": case "compaction":
    case "branch_summary": case "label":
      return true;
    case "session_info": case "context_edit": case "usage":
      return false;
    default: {
      entry satisfies never;
      return false;
    }
  }
}

function projectableTranscriptEntries(
  manager: TranscriptSessionReader,
  presentationIDs?: ReadonlyMap<string, string>,
  branchCut?: SessionEntry[],
): {
  branch: SessionEntry[];
  entries: SessionEntry[];
  contextDelivery: ReadonlyMap<string, ContextDeliveryMetadata>;
  toolSegmentIDs: ReadonlyMap<string, string>;
} {
  const branch = branchCut ?? manager.getBranch();
  const contextDelivery = contextDeliveryMetadataByEntry(branch);
  const entries: SessionEntry[] = [];
  const toolSegmentIDs = new Map<string, string>();
  let ownerId: string | undefined;
  for (const entry of branch) {
    const invocation = entry.type === "custom" && entry.customType === INVOCATION_RECEIPT_TYPE
      ? parseInvocationReceipt(entry.data)
      : undefined;
    if (entry.type === "custom" && entry.customType === INVOCATION_RECEIPT_TYPE && invocation === undefined) {
      throw new GatewayError("conflict", "Session contains a malformed Gateway invocation receipt");
    }
    if (entry.type === "custom" && entry.customType === EXTENSION_NOTIFICATION_RECEIPT_TYPE
        && parseExtensionNotificationReceipt(entry.data) === undefined) {
      throw new GatewayError("conflict", "Session contains a malformed Gateway extension notification receipt");
    }
    const notification = entry.type === "custom" && entry.customType === EXTENSION_NOTIFICATION_RECEIPT_TYPE
      ? parseExtensionNotificationReceipt(entry.data)
      : undefined;
    if (!transcriptRowFor(entry, invocation, notification)) continue;
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
    const lastBarrierIndex = content.findLastIndex((part) => part.type !== "toolCall");
    if (lastToolIndex < 0 || lastBarrierIndex > lastToolIndex) ownerId = undefined;
  }
  return { branch, entries, contextDelivery, toolSegmentIDs };
}

function durableInvocationLifecycle(lifecycle: InvocationProjection["lifecycle"]): InvocationProjection["lifecycle"] {
  return ["completed", "failed", "interrupted", "outcomeUnknown"].includes(lifecycle)
    ? lifecycle
    : "outcomeUnknown";
}

function inheritedCommandSettlements(
  branch: readonly SessionEntry[],
  sessionId: string | undefined,
): ReadonlyMap<string, InvocationLifecycle> {
  if (sessionId === undefined) return new Map();
  const receipts = branch.flatMap((entry) => {
    if (entry.type !== "custom" || entry.customType !== INVOCATION_RECEIPT_TYPE) return [];
    const receipt = parseInvocationReceipt(entry.data);
    return receipt ? [receipt] : [];
  });
  const terminals = new Map(receipts
    .filter((receipt) => receipt.receiptKind === "terminal")
    .map((receipt) => [receipt.invocationId, receipt.lifecycle] as const));
  const settlements = new Map<string, InvocationLifecycle>();
  for (const receipt of receipts) {
    if (receipt.receiptKind !== "start" || receipt.source !== "extension" || receipt.sessionId === sessionId) continue;
    settlements.set(receipt.invocationId, terminals.get(receipt.invocationId) ?? "completed");
  }
  return settlements;
}

function withInvocationSemantics(
  item: TranscriptItem,
  boundInvocation: InvocationProjection | undefined,
  invocationStates: ReadonlyMap<string, InvocationProjection["lifecycle"]>,
  inheritedCommands: ReadonlyMap<string, InvocationLifecycle>,
): TranscriptItem {
  if (boundInvocation && item.semantic && boundInvocation.source !== "homeWake") {
    return { ...item, semantic: {
      ...item.semantic,
      origin: boundInvocation.origin,
      invocationId: boundInvocation.invocationId,
      operationId: boundInvocation.operationId,
      kind: boundInvocation.source === "subagentWake" ? "prompt" : "resourcePrompt",
      ...(boundInvocation.source === "subagentWake" ? { direction: "hiddenInternal" as const, visibility: "hidden" as const } : {}),
      ...(boundInvocation.resourceInvocations ? { resourceInvocations: boundInvocation.resourceInvocations } : {}),
      ...(boundInvocation.submittedText === undefined ? {} : { submittedText: boundInvocation.submittedText }),
      lifecycle: boundInvocation.lifecycle,
    } };
  }
  const inheritedLifecycle = item.semantic?.kind === "command" && item.semantic.invocationId
    ? inheritedCommands.get(item.semantic.invocationId)
    : undefined;
  if (item.semantic && inheritedLifecycle) {
    return { ...item, semantic: { ...item.semantic, lifecycle: inheritedLifecycle, settledInOriginSession: true } };
  }
  if (item.semantic?.invocationId && invocationStates.has(item.semantic.invocationId)) {
    const lifecycle = invocationStates.get(item.semantic.invocationId)!;
    return { ...item, semantic: {
      ...item.semantic,
      lifecycle: item.semantic.kind === "command"
        ? durableInvocationLifecycle(lifecycle)
        : lifecycle,
    } };
  }
  return item;
}

export interface TranscriptPage {
  items: TranscriptItem[];
  start: number;
  end: number;
  total: number;
  nextEntryId?: string;
  previousEntryId?: string;
  runtimeGeneration?: string;
  leafEntryId?: string;
  forkBoundary?: TranscriptForkBoundary;
}

export function projectTranscriptPage(displayProjection: ToolDisplayProjection,
  manager: TranscriptSessionReader,
  blobs: BlobStore,
  before?: number,
  byteBudget = TRANSCRIPT_PAGE_BYTES,
  expectedNextEntryId?: string,
  toolMetadata?: ReadonlyMap<string, ToolProjectionMetadata>,
  presentationIDs?: ReadonlyMap<string, string>,
  toolLabels?: ReadonlyMap<string, string>,
  bashMetadata?: ReadonlyMap<string, ToolProjectionMetadata>,
  forkAnchor?: ForkBoundaryAnchor,
  branchCut?: SessionEntry[],
): TranscriptPage {
  const { branch, entries, contextDelivery, toolSegmentIDs } = projectableTranscriptEntries(
    manager,
    presentationIDs,
    branchCut,
  );
  const invocationValues = invocationProjection(invocationReceipts(
    branch,
    manager.getSessionId?.(),
  ));
  const invocationStates = new Map(invocationValues.map((value) => [value.invocationId, value.lifecycle]));
  const invocationByCanonicalEntry = new Map(invocationValues
    .filter(value => value.canonicalEntryId !== undefined)
    .map(value => [value.canonicalEntryId!, value]));
  const inheritedCommands = inheritedCommandSettlements(branch, manager.getSessionId?.());
  const forkBoundary = projectForkBoundary(branch, entries, forkAnchor);
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
    const resourceText = invokedResourceText(boundInvocation);
    const item = projectEntry(displayProjection,
      entry,
      blobs,
      toolMetadata,
      presentationIDs,
      toolLabels,
      contextDelivery.get(entry.id),
      toolSegmentIDs.get(entry.id),
      resourceText,
      bashMetadata,
      manager.getSessionId?.(),
    );
    if (!item) throw new Error(`projectable transcript entry produced no item: ${entry.type}${entry.type === "message" ? `/${entry.message.role}` : ""}`);
    const enriched = withInvocationSemantics(item, boundInvocation, invocationStates, inheritedCommands);
    const itemBytes = Buffer.byteLength(JSON.stringify(enriched)) + 1;
    if (bytes + itemBytes > byteBudget && selected.length > 0) break;
    if (itemBytes > byteBudget) {
      selected.unshift(compactTranscriptPageItem(enriched, Math.max(256, byteBudget - 3)));
      start -= 1;
      break;
    }
    selected.unshift(enriched);
    bytes += itemBytes;
    start -= 1;
  }
  return {
    items: fitTranscriptStructure(selected),
    start,
    end,
    total: entries.length,
    ...(entries[end]?.id ? { nextEntryId: entries[end].id } : {}),
    ...(forkBoundary ? { forkBoundary } : {}),
  };
}

export function projectTranscriptPageAfter(displayProjection: ToolDisplayProjection,
  manager: TranscriptSessionReader,
  blobs: BlobStore,
  after: number,
  byteBudget = TRANSCRIPT_PAGE_BYTES,
  expectedPreviousEntryId?: string,
  toolMetadata?: ReadonlyMap<string, ToolProjectionMetadata>,
  presentationIDs?: ReadonlyMap<string, string>,
  toolLabels?: ReadonlyMap<string, string>,
  bashMetadata?: ReadonlyMap<string, ToolProjectionMetadata>,
  forkAnchor?: ForkBoundaryAnchor,
  branchCut?: SessionEntry[],
): TranscriptPage {
  const { branch, entries, contextDelivery, toolSegmentIDs } = projectableTranscriptEntries(manager, presentationIDs, branchCut);
  const invocationValues = invocationProjection(invocationReceipts(branch, manager.getSessionId?.()));
  const invocationStates = new Map(invocationValues.map((value) => [value.invocationId, value.lifecycle]));
  const invocationByCanonicalEntry = new Map(invocationValues
    .filter(value => value.canonicalEntryId !== undefined)
    .map(value => [value.canonicalEntryId!, value]));
  const inheritedCommands = inheritedCommandSettlements(branch, manager.getSessionId?.());
  const forkBoundary = projectForkBoundary(branch, entries, forkAnchor);
  const start = Math.max(0, Math.min(after, entries.length));
  if (expectedPreviousEntryId !== undefined && entries[start - 1]?.id !== expectedPreviousEntryId) {
    throw new Error("session transcript anchor changed");
  }
  let end = start;
  let bytes = 2;
  const selected: TranscriptItem[] = [];
  while (end < entries.length && selected.length < TRANSCRIPT_PAGE_ITEMS) {
    const entry = entries[end]!;
    const boundInvocation = invocationByCanonicalEntry.get(entry.id);
    const resourceText = invokedResourceText(boundInvocation);
    const item = projectEntry(displayProjection, entry, blobs, toolMetadata, presentationIDs, toolLabels,
      contextDelivery.get(entry.id), toolSegmentIDs.get(entry.id), resourceText,
      bashMetadata, manager.getSessionId?.());
    if (!item) throw new Error(`projectable transcript entry produced no item: ${entry.type}${entry.type === "message" ? `/${entry.message.role}` : ""}`);
    const enriched = withInvocationSemantics(item, boundInvocation, invocationStates, inheritedCommands);
    const itemBytes = Buffer.byteLength(JSON.stringify(enriched)) + 1;
    if (bytes + itemBytes > byteBudget && selected.length > 0) break;
    if (itemBytes > byteBudget) {
      selected.push(compactTranscriptPageItem(enriched, Math.max(256, byteBudget - 3)));
      end += 1;
      break;
    }
    selected.push(enriched);
    bytes += itemBytes;
    end += 1;
  }
  const nextEntryId = entries[end]?.id;
  const previousEntryId = entries[start - 1]?.id;
  return {
    items: fitTranscriptStructure(selected), start, end, total: entries.length,
    ...(nextEntryId ? { nextEntryId } : {}),
    ...(previousEntryId ? { previousEntryId } : {}),
    ...(forkBoundary ? { forkBoundary } : {}),
  };
}

function compactTranscriptPageItem(item: TranscriptItem, byteBudget: number, nodeBudget = TRANSCRIPT_PAGE_NODES): TranscriptItem {
  let compacted = item;
  if (item.kind === "message") {
    const { details: _details, usage: _usage, ...base } = item;
    compacted = {
      ...base,
      content: item.content.map((part) => {
        if (part.type !== "text" && part.type !== "thinking") return part;
        return { ...part, text: boundedUtf8Prefix(part.text, Math.max(64, Math.floor(byteBudget / 3))) };
      }),
      ...(item.details === undefined ? {} : { details: { truncated: true, preview: "Oversized detail omitted from mobile page." } }),
      ...(item.usage === undefined ? {} : { usage: projectJson(item.usage, 256) }),
    };
  } else if (item.kind === "bash") {
    compacted = { ...item, command: boundedUtf8Prefix(item.command, 256), output: boundedUtf8Suffix(item.output, Math.max(64, byteBudget - 1_024)), truncated: true };
  } else if (item.kind === "customMessage") {
    compacted = { ...item, content: [], details: { truncated: true, preview: "Oversized custom message omitted from mobile page." } };
  } else if (item.kind === "customEntry") {
    const notification = item.semantic?.kind === "status" ? item.data as Record<string, JsonValue> | undefined : undefined;
    compacted = notification && typeof notification.message === "string"
      ? {
          ...item,
          data: {
            message: boundedUtf8Prefix(notification.message, Math.max(64, byteBudget - 2_048)),
            tone: typeof notification.tone === "string" ? notification.tone : "info",
            truncated: true,
          },
        }
      : { ...item, data: { truncated: true, preview: "Oversized custom entry omitted from mobile page." } };
  } else if (item.kind === "compaction" || item.kind === "branchSummary") {
    const { details: _details, usage: _usage, ...base } = item;
    compacted = { ...base, summary: boundedUtf8Prefix(item.summary, Math.max(64, byteBudget - 1_024)) };
  }
  if (jsonNodeCount(compacted, nodeBudget, true) <= nodeBudget
    && Buffer.byteLength(JSON.stringify(compacted)) <= byteBudget) return compacted;
  return {
    id: item.id,
    parentId: item.parentId,
    timestamp: item.timestamp,
    kind: "message",
    role: item.kind === "message" ? item.role : "assistant",
    ...(item.kind === "message" && item.toolCallId ? { toolCallId: item.toolCallId } : {}),
    ...(item.kind === "message" && item.toolName ? { toolName: item.toolName } : {}),
    presentationId: item.kind === "message" ? item.presentationId : item.id,
    content: [{ id: `${item.id}:truncated:0`, ordinal: 0, type: "text", text: "… transcript item omitted from this mobile page" }],
  };
}
