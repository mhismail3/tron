import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

/**
 * Shared machinery for the SDK-boundary behavior trace (epic #468, layer L2).
 *
 * The trace is a *normalized* recording of what one deterministic scenario makes
 * the pinned Pi SDK emit, persist and send. Two runs of the same scenario must
 * produce byte-identical traces, so every per-run identity (ids, timestamps,
 * durations, counters, the disposable temp root) is replaced by a stable
 * placeholder, and the golden comparison is exact.
 *
 * What must never be normalized away is the *shape and wording* the SDK
 * produces: a tool name, a prompt section heading, a tool-result text. Those are
 * the deltas an SDK upgrade has to justify hunk by hunk.
 */

/** Set to `1` to rewrite the committed golden from a real run instead of comparing. */
export const BEHAVIOR_TRACE_UPDATE_ENV = "TRON_UPDATE_SDK_BEHAVIOR_TRACE";

export type TraceValue = null | boolean | number | string | TraceValue[] | { [key: string]: TraceValue };

/** Per-run facts the trace must not carry: the disposable roots it ran in. */
export interface TraceNormalization {
  /** Absolute directories (and their realpaths) that become `<tmp>`. */
  readonly roots: readonly string[];
}

/** One provider request as the SDK handed it to the model API. */
export interface ProviderRequestTrace {
  /** Declared tool names, in declaration order. */
  readonly tools: readonly string[];
  /** System-prompt section headings, in the order they appear in the prompt. */
  readonly promptSections: readonly string[];
  /** `sha256:<hex>` over the normalized prompt text. */
  readonly promptHash: string;
}

/** One client-facing topic, with the union of the payload structures it carried. */
export interface ClientEventTrace {
  readonly topic: string;
  readonly paths: readonly string[];
}

export interface BehaviorTrace {
  readonly scenario: string;
  readonly providerRequests: readonly ProviderRequestTrace[];
  readonly clientEvents: readonly ClientEventTrace[];
  /** Canonical session JSONL entries, in file order, normalized. */
  readonly canonicalJsonl: readonly TraceValue[];
  /** The slot's transcript projection, normalized. */
  readonly transcript: readonly TraceValue[];
}

/** Values that differ per run but whose structure is worth keeping. */
const IDENTITY_KEYS = new Set([
  "id", "parentId", "parentSessionId", "sessionId", "presentationId", "toolCallId", "targetId",
  "fromId", "firstKeptEntryId", "leafEntryId", "toolSegmentId", "groupId", "runtimeGeneration",
  "hostEpoch", "operationId", "invocationId", "receiptId", "requestId", "responseId",
  "canonicalEntryId", "callId", "runId",
]);
const TIMESTAMP_KEYS = new Set([
  "timestamp", "createdAt", "updatedAt", "startedAt", "completedAt", "finishedAt",
  "lastProgressAt", "queuedAt", "settledAt", "deliveredAt",
]);
const DURATION_KEYS = new Set(["durationMs", "elapsedMs", "latencyMs"]);
const COUNTER_KEYS = new Set(["sequence", "eventSequence", "revision", "progressSequence", "callCount"]);
/** Values whose exact numbers are host- and timing-derived; only their structure is compared. */
const STRUCTURE_ONLY_KEYS = new Set(["usage", "cost", "stats"]);

const IDENTITY_MARKER = "<id>";
const TIMESTAMP_MARKER = "<timestamp>";
const DURATION_MARKER = "<duration>";
const COUNTER_MARKER = "<n>";
const STRUCTURE_MARKER = "<value>";

/** Absolute package paths differ per checkout and machine; only the package identity matters. */
const PACKAGE_PATH = /(?:[A-Za-z]:)?(?:[/\\][^\s"']*?)*[/\\]node_modules[/\\]((?:@[^/\\]+[/\\])?[^/\\]+)/g;
const TEMP_PATH = /(?:[/\\]private)?[/\\](?:var[/\\]folders|tmp|private[/\\]tmp)[^\s"',;)]*/g;
const ISO_TIMESTAMP = /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?/g;
const UUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi;
const DATA_URL = /data:([a-z0-9.+-]+\/[a-z0-9.+-]+);base64,[A-Za-z0-9+/=]+/gi;
const EPOCH_NUMBER = /(?<![.\d])\b\d{13,}\b/g;
/** The codemode tool result reports its own wall time, which host load moves. */
const WALL_TIME_TEXT = /\bWall time \d+(?:\.\d+)? seconds?\b/g;
const FAUX_API = /^faux:\d+:[a-z0-9]+$/;
const BASE64_PAYLOAD = /^[A-Za-z0-9+/]{64,}={0,2}$/;

/**
 * Live-progress subtrees a payload carries only while work is in flight, so
 * whether a run observed them depends on host timing rather than on the SDK's
 * behavior: the growing streamed message, the live tool-execution list, a tool
 * result before it settles, and nested-call progress inside a live execution.
 * Their settled forms are recorded by the transcript projection, so pruning them
 * from an *event shape* costs no signal and removes a false delta.
 */
const TRANSIENT_EVENT_PATHS: ReadonlyMap<string, ReadonlySet<string>> = new Map([
  ["session.snapshot", new Set(["streaming", "toolExecutions", "partialResult", "nestedCalls"])],
  ["session.progress", new Set(["message"])],
  ["session.toolProgress", new Set(["data"])],
]);
const NO_TRANSIENT_PATHS: ReadonlySet<string> = new Set<string>();

/** Replace per-run values in one string, keeping every stable structural cue. */
export function normalizeTraceString(value: string, normalization: TraceNormalization): string {
  // Whole-value identities first: the generic replacements below would hide the
  // pattern that identifies them.
  if (FAUX_API.test(value)) return "<api>";
  if (BASE64_PAYLOAD.test(value)) return `<base64:${value.length}>`;
  let text = value;
  // Longest first: a realpath (`/private/var/…`) contains the raw temp root
  // (`/var/…`), and replacing the shorter one first would leave `/private<tmp>`.
  for (const root of [...normalization.roots].sort((left, right) => right.length - left.length)) {
    if (root.length > 1) text = text.split(root).join("<tmp>");
  }
  text = text.replace(PACKAGE_PATH, "<pkg:$1>");
  text = text.replace(TEMP_PATH, "<tmp>/<path>");
  text = text.replace(ISO_TIMESTAMP, TIMESTAMP_MARKER);
  text = text.replace(UUID, IDENTITY_MARKER);
  text = text.replace(DATA_URL, (_match, mime: string) => `data:${mime};base64,<base64>`);
  text = text.replace(EPOCH_NUMBER, "<epoch>");
  text = text.replace(WALL_TIME_TEXT, "Wall time <duration>");
  return text;
}

/** The normalized trace value of one JSON-shaped SDK value. */
export function normalizeTraceValue(value: unknown, normalization: TraceNormalization): TraceValue {
  if (value === null || typeof value === "boolean") return value;
  if (typeof value === "number") return Number.isFinite(value) ? value : "<nonfinite>";
  if (typeof value === "string") return normalizeTraceString(value, normalization);
  if (Array.isArray(value)) return value.map((item) => normalizeTraceValue(item, normalization));
  if (typeof value === "object") {
    const out: Record<string, TraceValue> = {};
    for (const key of Object.keys(value as Record<string, unknown>).sort()) {
      const child = (value as Record<string, unknown>)[key];
      if (child === undefined) continue;
      if (STRUCTURE_ONLY_KEYS.has(key)) { out[key] = blindStructure(child); continue; }
      if (IDENTITY_KEYS.has(key)) { out[key] = IDENTITY_MARKER; continue; }
      if (TIMESTAMP_KEYS.has(key)) { out[key] = TIMESTAMP_MARKER; continue; }
      if (DURATION_KEYS.has(key)) { out[key] = DURATION_MARKER; continue; }
      if (COUNTER_KEYS.has(key)) { out[key] = COUNTER_MARKER; continue; }
      out[key] = normalizeTraceValue(child, normalization);
    }
    return out;
  }
  return `<${typeof value}>`;
}

/** Keep a value's structure while discarding its numbers. */
function blindStructure(value: unknown): TraceValue {
  if (value === null) return "<null>";
  if (Array.isArray(value)) return value.map(blindStructure);
  if (typeof value === "object") {
    const out: Record<string, TraceValue> = {};
    for (const key of Object.keys(value as Record<string, unknown>).sort()) {
      out[key] = blindStructure((value as Record<string, unknown>)[key]);
    }
    return out;
  }
  return STRUCTURE_MARKER;
}

/** `sha256:<hex>` over a normalized prompt text. */
export function hashPromptText(prompt: string, normalization: TraceNormalization): string {
  const normalized = normalizeTraceString(prompt, normalization);
  return `sha256:${createHash("sha256").update(normalized, "utf8").digest("hex")}`;
}

/**
 * The system prompt's section headings, in prompt order.
 *
 * The Gateway's own `before_agent_start` hook flattens the structured prompt
 * into one `content` string, so the request carries no `sections` object: the
 * headings are the rendered `<name>…</name>` blocks. A heading only counts when
 * its closing tag exists, so prose that mentions a `<placeholder>` does not
 * become a section.
 */
export function promptSectionHeadings(prompt: string): string[] {
  const headings: string[] = [];
  for (const match of prompt.matchAll(/(?:^|\n)<([a-z][a-z0-9_]*)>\n/g)) {
    const name = match[1];
    if (name === undefined) continue;
    if (!prompt.includes(`</${name}>`)) continue;
    if (!headings.includes(name)) headings.push(name);
  }
  return headings;
}

/**
 * Every dotted path (with a type tag at each leaf) reachable in one JSON-shaped
 * value. Paths are deduplicated and sorted, so a payload's structure is compared
 * without its per-run ordering or repetition. `skip` prunes whole subtrees.
 */
export function shapePaths(value: unknown, options: { readonly skip?: ReadonlySet<string> } = {}): string[] {
  const found = new Set<string>();
  collectShapePaths(value, "", found, options.skip ?? NO_TRANSIENT_PATHS);
  return [...found].sort();
}

function collectShapePaths(value: unknown, prefix: string, found: Set<string>, skip: ReadonlySet<string>): void {
  if (Array.isArray(value)) {
    found.add(`${prefix}:array`);
    for (const item of value) collectShapePaths(item, `${prefix}[]`, found, skip);
    return;
  }
  if (value !== null && typeof value === "object") {
    found.add(`${prefix}:object`);
    for (const [key, child] of Object.entries(value as Record<string, unknown>)) {
      if (skip.has(key)) continue;
      collectShapePaths(child, prefix === "" ? key : `${prefix}.${key}`, found, skip);
    }
    return;
  }
  found.add(`${prefix}:${value === null ? "null" : typeof value}`);
}

/** The shape of one client-event payload, with its in-flight sub-states pruned. */
export function eventShapePaths(topic: string, payload: unknown): string[] {
  return shapePaths(payload, { skip: TRANSIENT_EVENT_PATHS.get(topic) ?? NO_TRANSIENT_PATHS });
}

/** Collapse a run's broadcasts into one row per topic, in first-appearance order. */
export function clientEventTrace(events: Iterable<{ topic: string; paths: readonly string[] }>): ClientEventTrace[] {
  const order: string[] = [];
  const byTopic = new Map<string, Set<string>>();
  for (const event of events) {
    let paths = byTopic.get(event.topic);
    if (paths === undefined) { paths = new Set<string>(); byTopic.set(event.topic, paths); order.push(event.topic); }
    for (const path of event.paths) paths.add(path);
  }
  return order.map((topic) => ({ topic, paths: [...(byTopic.get(topic) ?? [])].sort() }));
}

/** The canonical rendering both the golden and the retained artifact use. */
export function renderTrace(trace: BehaviorTrace): string {
  return `${JSON.stringify(trace, null, 2)}\n`;
}

type Edit = { readonly op: "keep" | "delete" | "insert"; readonly text: string };

/**
 * Patience diff over lines.
 *
 * A golden comparison reports a change in *wording*, not in line numbers, so the
 * diff has to stay readable when many lines shift at once (a renamed tool
 * changes every request and every transcript row). Anchoring on lines that are
 * unique on both sides keeps unrelated shifts out of the hunks, and a region
 * with no unique line is reported as its own replacement instead of a
 * line-by-line cascade.
 */
export function diffLines(before: string, after: string): Edit[] {
  const a = before.split("\n");
  const b = after.split("\n");
  const out: Edit[] = [];
  diffRange(a, 0, a.length, b, 0, b.length, out);
  return out;
}

function diffRange(a: string[], a0: number, a1: number, b: string[], b0: number, b1: number, out: Edit[]): void {
  while (a0 < a1 && b0 < b1 && a[a0] === b[b0]) { out.push({ op: "keep", text: a[a0] ?? "" }); a0 += 1; b0 += 1; }
  const suffix: Edit[] = [];
  while (a1 > a0 && b1 > b0 && a[a1 - 1] === b[b1 - 1]) { suffix.push({ op: "keep", text: a[a1 - 1] ?? "" }); a1 -= 1; b1 -= 1; }
  if (a0 === a1) {
    for (let index = b0; index < b1; index += 1) out.push({ op: "insert", text: b[index] ?? "" });
  } else if (b0 === b1) {
    for (let index = a0; index < a1; index += 1) out.push({ op: "delete", text: a[index] ?? "" });
  } else {
    const countA = new Map<string, number>();
    const countB = new Map<string, number>();
    for (let index = a0; index < a1; index += 1) countA.set(a[index] ?? "", (countA.get(a[index] ?? "") ?? 0) + 1);
    for (let index = b0; index < b1; index += 1) countB.set(b[index] ?? "", (countB.get(b[index] ?? "") ?? 0) + 1);
    const uniqueInB = new Map<string, number>();
    for (let index = b0; index < b1; index += 1) {
      const line = b[index] ?? "";
      if (countB.get(line) === 1 && countA.get(line) === 1) uniqueInB.set(line, index);
    }
    const candidates: Array<{ a: number; b: number }> = [];
    for (let index = a0; index < a1; index += 1) {
      const position = uniqueInB.get(a[index] ?? "");
      if (position !== undefined) candidates.push({ a: index, b: position });
    }
    const anchors = longestIncreasing(candidates);
    if (anchors.length === 0) {
      for (let index = a0; index < a1; index += 1) out.push({ op: "delete", text: a[index] ?? "" });
      for (let index = b0; index < b1; index += 1) out.push({ op: "insert", text: b[index] ?? "" });
    } else {
      let previousA = a0;
      let previousB = b0;
      for (const anchor of anchors) {
        diffRange(a, previousA, anchor.a, b, previousB, anchor.b, out);
        out.push({ op: "keep", text: a[anchor.a] ?? "" });
        previousA = anchor.a + 1;
        previousB = anchor.b + 1;
      }
      diffRange(a, previousA, a1, b, previousB, b1, out);
    }
  }
  for (const edit of suffix.reverse()) out.push(edit);
}

/** Longest strictly increasing subsequence of `candidates[].b`, keeping `a` order. */
function longestIncreasing(candidates: Array<{ a: number; b: number }>): Array<{ a: number; b: number }> {
  const tails: number[] = [];
  const tailIndex: number[] = [];
  const previous: number[] = new Array<number>(candidates.length).fill(-1);
  for (let index = 0; index < candidates.length; index += 1) {
    const candidate = candidates[index];
    if (candidate === undefined) continue;
    let low = 0;
    let high = tails.length;
    while (low < high) {
      const middle = (low + high) >> 1;
      if ((tails[middle] ?? Number.NEGATIVE_INFINITY) < candidate.b) low = middle + 1;
      else high = middle;
    }
    tails[low] = candidate.b;
    tailIndex[low] = index;
    previous[index] = low > 0 ? (tailIndex[low - 1] ?? -1) : -1;
  }
  const result: Array<{ a: number; b: number }> = [];
  let cursor = tails.length > 0 ? (tailIndex[tails.length - 1] ?? -1) : -1;
  while (cursor >= 0) {
    const candidate = candidates[cursor];
    if (candidate !== undefined) result.push(candidate);
    cursor = previous[cursor] ?? -1;
  }
  return result.reverse();
}

/** A unified diff (3 lines of context) between two golden renderings; `""` when equal. */
export function renderUnifiedDiff(before: string, after: string, contextLines = 3): string {
  const edits = diffLines(before, after);
  // The A/B line each edit starts at (1-based), so hunk headers never depend on
  // how the hunk boundaries were chosen.
  const aAt: number[] = [];
  const bAt: number[] = [];
  let aLine = 1;
  let bLine = 1;
  for (const edit of edits) {
    aAt.push(aLine);
    bAt.push(bLine);
    if (edit.op !== "insert") aLine += 1;
    if (edit.op !== "delete") bLine += 1;
  }
  const changes: number[] = [];
  for (let index = 0; index < edits.length; index += 1) if (edits[index]?.op !== "keep") changes.push(index);
  if (changes.length === 0) return "";
  const hunks: Array<{ start: number; end: number }> = [];
  for (const change of changes) {
    const last = hunks[hunks.length - 1];
    if (last !== undefined && change - last.end <= contextLines * 2 + 1) { last.end = change; continue; }
    hunks.push({ start: change, end: change });
  }
  const lines: string[] = [];
  let previousEnd = 0;
  for (const hunk of hunks) {
    const start = Math.max(previousEnd, hunk.start - contextLines);
    const end = Math.min(edits.length, hunk.end + contextLines + 1);
    let removed = 0;
    let added = 0;
    for (let cursor = start; cursor < end; cursor += 1) {
      if (edits[cursor]?.op !== "insert") removed += 1;
      if (edits[cursor]?.op !== "delete") added += 1;
    }
    const aStart = removed === 0 ? (aAt[start] ?? 1) - 1 : (aAt[start] ?? 1);
    const bStart = added === 0 ? (bAt[start] ?? 1) - 1 : (bAt[start] ?? 1);
    lines.push(`@@ -${aStart},${removed} +${bStart},${added} @@`);
    for (let cursor = start; cursor < end; cursor += 1) {
      const edit = edits[cursor];
      if (edit === undefined) continue;
      lines.push(`${edit.op === "keep" ? " " : edit.op === "delete" ? "-" : "+"}${edit.text}`);
    }
    previousEnd = end;
  }
  return lines.join("\n");
}

export interface GoldenComparison {
  readonly goldenPath: string;
  readonly actualPath: string;
  readonly trace: BehaviorTrace;
}

/**
 * Compare one scenario's trace with the committed golden, or rewrite it.
 *
 * A mismatch throws a unified diff; the exact rendering that produced it is also
 * written to `actualPath` (a retained, gitignored artifact) so a reviewer can
 * regenerate and inspect the whole trace without re-running anything.
 */
export async function compareWithGolden(comparison: GoldenComparison): Promise<{ updated: boolean }> {
  const rendered = renderTrace(comparison.trace);
  await mkdir(dirname(comparison.actualPath), { recursive: true });
  await writeFile(comparison.actualPath, rendered);
  if (process.env[BEHAVIOR_TRACE_UPDATE_ENV] === "1") {
    await mkdir(dirname(comparison.goldenPath), { recursive: true });
    await writeFile(comparison.goldenPath, rendered);
    return { updated: true };
  }
  const golden = await readFile(comparison.goldenPath, "utf8");
  if (golden === rendered) return { updated: false };
  const diff = renderUnifiedDiff(golden, rendered);
  const lines = diff.split("\n");
  const shown = lines.slice(0, MAXIMUM_REPORTED_DIFF_LINES);
  throw new Error([
    `The SDK boundary behavior trace differs from ${comparison.goldenPath}.`,
    `Retained actual trace: ${comparison.actualPath}`,
    "Review every hunk: an intended change updates the golden with",
    `\`${BEHAVIOR_TRACE_UPDATE_ENV}=1 npm run update:sdk-behavior-trace\`, and the pull request lists each hunk.`,
    "",
    ...shown,
    ...(lines.length > shown.length ? [`… ${lines.length - shown.length} more diff lines in ${comparison.actualPath}`] : []),
  ].join("\n"));
}

const MAXIMUM_REPORTED_DIFF_LINES = 600;
