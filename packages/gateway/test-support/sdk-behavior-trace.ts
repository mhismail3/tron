import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { promisify } from "node:util";

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
 *
 * The comparison's diff is produced by `git diff --no-index`, not by a
 * hand-written algorithm: the same tool a reviewer would run, with real hunk
 * boundaries on a golden whose blocks repeat.
 */

/** Set to `1` to rewrite the committed golden from a real run instead of comparing. */
export const BEHAVIOR_TRACE_UPDATE_ENV = "TRON_UPDATE_SDK_BEHAVIOR_TRACE";

/** A mismatch prints at most this many diff lines; the whole diff is in the artifact. */
const MAXIMUM_REPORTED_DIFF_LINES = 400;

export type TraceValue = null | boolean | number | string | TraceValue[] | { [key: string]: TraceValue };

/** Per-run facts the trace must not carry: the disposable roots it ran in. */
export interface TraceNormalization {
  /** Absolute directories (and their realpaths) that become `<tmp>`. */
  readonly roots: readonly string[];
  /**
   * Identity values that are the scenario's own, not the SDK's: a fixed
   * tool-call ID the script names. Anything else under an identity key is
   * generated per run and becomes `<id>`.
   */
  readonly stableIds?: readonly string[];
}

/** One distinct provider request, with how many consecutive requests it covers. */
export interface ProviderRequestTrace {
  /** Consecutive identical requests this record stands for; `1` for a one-off. */
  readonly repeats: number;
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
  /** The non-chat provider boundary the scenario exercises: TypeSafe classify. */
  readonly classifierRequests: readonly TraceValue[];
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
/**
 * Values whose exact numbers are host- and checkout-derived; only their
 * structure is compared. `tokensBefore` is one of them: Pi estimates the
 * pre-compaction context from the last assistant usage plus a chars/4 estimate
 * of the serialized context, and that context contains absolute package and
 * temp paths, so the same scenario on a checkout of a different path length
 * produces a different number. The prompt-size signal stays visible through the
 * prompt sections, the per-request prompt hash and the section text.
 */
const STRUCTURE_ONLY_KEYS = new Set(["usage", "cost", "stats", "tokensBefore"]);

const IDENTITY_MARKER = "<id>";
const TIMESTAMP_MARKER = "<timestamp>";
const DURATION_MARKER = "<duration>";
const COUNTER_MARKER = "<n>";
const STRUCTURE_MARKER = "<value>";

/**
 * Absolute package paths differ per checkout and machine; only the package
 * identity matters. Deliberately a single bounded quantifier: a star over a
 * group that itself repeats is exponential on a long slash-heavy token.
 */
const PACKAGE_PATH = /(?:[^\s"'`()[\]]*[/\\])?node_modules[/\\]((?:@[^/\\]+[/\\])?[^/\\]+)/g;
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
function normalizeTraceString(value: string, normalization: TraceNormalization): string {
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
  if (typeof value === "string") {
    return (normalization.stableIds ?? []).includes(value) ? value : normalizeTraceString(value, normalization);
  }
  if (Array.isArray(value)) return value.map((item) => normalizeTraceValue(item, normalization));
  if (typeof value === "object") {
    const out: Record<string, TraceValue> = {};
    for (const key of Object.keys(value as Record<string, unknown>).sort()) {
      const child = (value as Record<string, unknown>)[key];
      if (child === undefined) continue;
      if (STRUCTURE_ONLY_KEYS.has(key)) { out[key] = blindStructure(child); continue; }
      if (key === "systemMessage") { out[key] = summarizeSystemPromptState(child); continue; }
      if (IDENTITY_KEYS.has(key)) {
        out[key] = typeof child === "string" && (normalization.stableIds ?? []).includes(child)
          ? child
          : IDENTITY_MARKER;
        continue;
      }
      if (TIMESTAMP_KEYS.has(key)) { out[key] = TIMESTAMP_MARKER; continue; }
      if (DURATION_KEYS.has(key)) { out[key] = DURATION_MARKER; continue; }
      if (COUNTER_KEYS.has(key)) { out[key] = COUNTER_MARKER; continue; }
      out[key] = normalizeTraceValue(child, normalization);
    }
    return out;
  }
  return `<${typeof value}>`;
}

/**
 * A compaction entry repeats the whole system prompt it was cut at, which is
 * already recorded by the live system message and by every request's section
 * headings and prompt hash. Keep which sections and tools the boundary carried,
 * drop the duplicated text.
 */
function summarizeSystemPromptState(value: unknown): TraceValue {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return normalizeShapeOnly(value);
  const state = value as { content?: unknown; sections?: unknown; toolsAdded?: unknown };
  const sections = state.sections !== null && typeof state.sections === "object" && !Array.isArray(state.sections)
    ? Object.keys(state.sections as Record<string, unknown>).sort()
    : [];
  const tools = Array.isArray(state.toolsAdded)
    ? state.toolsAdded.flatMap((tool) => tool !== null && typeof tool === "object" && typeof (tool as { name?: unknown }).name === "string"
      ? [(tool as { name: string }).name]
      : [])
    : [];
  return {
    contentChars: typeof state.content === "string" ? state.content.length : 0,
    sectionNames: sections,
    toolsAdded: tools,
  };
}

function normalizeShapeOnly(value: unknown): TraceValue {
  if (value === null) return "<null>";
  if (Array.isArray(value)) return value.map(normalizeShapeOnly);
  if (typeof value === "object") {
    const out: Record<string, TraceValue> = {};
    for (const key of Object.keys(value as Record<string, unknown>).sort()) {
      out[key] = normalizeShapeOnly((value as Record<string, unknown>)[key]);
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
function shapePaths(value: unknown, options: { readonly skip?: ReadonlySet<string> } = {}): string[] {
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

/**
 * Collapse each run of identical consecutive provider requests into one record
 * carrying its `repeats`. A turn makes several requests with the same prompt and
 * tool set; recording them once keeps the trace's *sequence* and count while
 * sparing the reviewer eight identical blocks, and any request that differs
 * splits the run and stays visible.
 */
export function collapseRepeatedRequests(requests: readonly Omit<ProviderRequestTrace, "repeats">[]): ProviderRequestTrace[] {
  const collapsed: ProviderRequestTrace[] = [];
  for (const request of requests) {
    const previous = collapsed[collapsed.length - 1];
    if (previous !== undefined
      && previous.promptHash === request.promptHash
      && previous.promptSections.join("\n") === request.promptSections.join("\n")
      && previous.tools.join("\n") === request.tools.join("\n")) {
      collapsed[collapsed.length - 1] = { ...previous, repeats: previous.repeats + 1 };
      continue;
    }
    collapsed.push({ repeats: 1, tools: request.tools, promptSections: request.promptSections, promptHash: request.promptHash });
  }
  return collapsed;
}

/** The canonical rendering both the golden and the retained artifact use. */
function renderTrace(trace: BehaviorTrace): string {
  return `${JSON.stringify(trace, null, 2)}\n`;
}

export interface GoldenComparison {
  readonly goldenPath: string;
  /** Where the exact trace that produced the diff is retained. */
  readonly actualPath: string;
  /** Where the full unified diff is retained for review. */
  readonly diffPath: string;
  readonly trace: BehaviorTrace;
  /**
   * Rewrite the golden from this trace. Only the idle case passes `true` (and
   * only under {@link BEHAVIOR_TRACE_UPDATE_ENV}), so the load case still has to
   * agree with the golden this run just wrote.
   */
  readonly update: boolean;
  /**
   * Assert the scenario itself ran. Called once the trace is known to *match*
   * the golden — and, in update mode, before the golden is written — so a golden
   * can never be accepted from a run whose own steps stopped exercising a seam,
   * while a real SDK delta is still reported as a diff.
   */
  readonly validate: (trace: BehaviorTrace) => void;
}

/**
 * Compare one scenario's trace with the committed golden, or rewrite it.
 *
 * A mismatch throws a unified diff produced by `git diff --no-index` — the same
 * command a reviewer runs — and retains the full diff and the exact trace at
 * stable paths so the whole comparison can be inspected without re-running
 * anything.
 */
export async function compareWithGolden(comparison: GoldenComparison): Promise<{ updated: boolean; hunks: number }> {
  const rendered = renderTrace(comparison.trace);
  await mkdir(dirname(comparison.actualPath), { recursive: true });
  await writeFile(comparison.actualPath, rendered);
  const golden = await readFile(comparison.goldenPath, "utf8").catch(() => undefined);
  if (golden === undefined) {
    if (!comparison.update) throw new Error(`The SDK boundary behavior trace has no golden at ${comparison.goldenPath}.`);
    comparison.validate(comparison.trace);
    await writeGolden(comparison.goldenPath, rendered);
    return { updated: true, hunks: 0 };
  }
  if (golden === rendered) {
    comparison.validate(comparison.trace);
    return { updated: false, hunks: 0 };
  }
  const diff = await unifiedDiff(comparison.goldenPath, comparison.actualPath);
  await mkdir(dirname(comparison.diffPath), { recursive: true });
  await writeFile(comparison.diffPath, diff);
  const hunks = diff.split("\n").filter((line) => line.startsWith("@@")).length;
  if (comparison.update) {
    comparison.validate(comparison.trace);
    await writeGolden(comparison.goldenPath, rendered);
    return { updated: true, hunks };
  }
  const lines = diff.split("\n");
  const shown = lines.slice(0, MAXIMUM_REPORTED_DIFF_LINES);
  throw new Error([
    `The SDK boundary behavior trace differs from ${comparison.goldenPath} (${hunks} hunks).`,
    `Retained actual trace: ${comparison.actualPath}`,
    `Retained unified diff: ${comparison.diffPath}`,
    `Reproduce it with: git diff --no-index --no-color --unified=3 ${comparison.goldenPath} ${comparison.actualPath}`,
    "Review every hunk: an intended change updates the golden with",
    `\`${BEHAVIOR_TRACE_UPDATE_ENV}=1 npm run update:sdk-behavior-trace\`, and the pull request lists each hunk.`,
    "",
    ...shown,
    ...(lines.length > shown.length ? [`… ${lines.length - shown.length} more diff lines in ${comparison.diffPath}`] : []),
  ].join("\n"));
}

async function writeGolden(goldenPath: string, rendered: string): Promise<void> {
  await mkdir(dirname(goldenPath), { recursive: true });
  await writeFile(goldenPath, rendered);
}

/** The reviewable unified diff between two trace files, from git itself. */
async function unifiedDiff(beforePath: string, afterPath: string): Promise<string> {
  const run = promisify(execFile);
  try {
    const { stdout } = await run("git", ["diff", "--no-index", "--no-color", "--unified=3", beforePath, afterPath], {
      maxBuffer: 64 * 1024 * 1024,
    });
    return stdout;
  } catch (error) {
    // `git diff --no-index` exits 1 for "differences found", which is the
    // expected case; anything else is reported with the two files so the
    // comparison is still reproducible by hand.
    const stdout = (error as { stdout?: unknown }).stdout;
    if (typeof stdout === "string" && stdout.length > 0) return stdout;
    throw new Error(`Could not diff the behavior trace (${String(error)}); compare ${beforePath} with ${afterPath} by hand.`);
  }
}
