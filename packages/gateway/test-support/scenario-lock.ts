import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const LOCK_UPDATE_ENV = "TRON_UPDATE_LOCKS";

export function lockUpdateRequested(moduleId: string): boolean {
  const requested = (process.env[LOCK_UPDATE_ENV] ?? "").split(",").map((entry) => entry.trim()).filter(Boolean);
  return requested.includes("all") || requested.includes(moduleId);
}

export function lockPaths(testFileUrl: string, name: string): { goldenPath: string; actualPath: string; diffPath: string } {
  const testFile = fileURLToPath(testFileUrl);
  const results = resolve(process.cwd(), "test-results", "locks");
  return {
    goldenPath: join(dirname(testFile), "locks", `${name}.golden.json`),
    actualPath: join(results, `${name}.actual.json`),
    diffPath: join(results, `${name}.diff`),
  };
}

function lockName(goldenPath: string): string {
  return basename(goldenPath).replace(/\.golden\.json$/u, "");
}

const MAXIMUM_REPORTED_DIFF_LINES = 400;

export type TraceValue = null | boolean | number | string | TraceValue[] | { [key: string]: TraceValue };

export interface TraceNormalization {
  readonly roots: readonly string[];
  readonly stableIds?: readonly string[];
}

export interface ProviderRequestTrace {
  readonly repeats: number;
  readonly tools: readonly string[];
  readonly promptSections: readonly string[];
  readonly promptHash: string;
}

export interface ClientEventTrace {
  readonly topic: string;
  readonly paths: readonly string[];
}

export interface BehaviorTrace {
  readonly scenario: string;
  readonly providerRequests: readonly ProviderRequestTrace[];
  readonly classifierRequests: readonly TraceValue[];
  readonly clientEvents: readonly ClientEventTrace[];
  readonly canonicalJsonl: readonly TraceValue[];
  readonly transcript: readonly TraceValue[];
}

const IDENTITY_KEYS = new Set([
  "id", "parentId", "parentSessionId", "sessionId", "presentationId", "toolCallId", "targetId",
  "fromId", "firstKeptEntryId", "leafEntryId", "toolSegmentId", "groupId", "runtimeGeneration",
  "hostEpoch", "operationId", "invocationId", "receiptId", "requestId", "responseId",
  "canonicalEntryId", "callId", "runId", "activityId", "processId", "projectionToken", "drainId",
]);
const TIMESTAMP_KEYS = new Set([
  "timestamp", "createdAt", "updatedAt", "startedAt", "completedAt", "finishedAt",
  "lastProgressAt", "queuedAt", "settledAt", "deliveredAt",
]);
const DURATION_KEYS = new Set(["durationMs", "elapsedMs", "latencyMs", "ageMs"]);
const COUNTER_KEYS = new Set(["sequence", "eventSequence", "revision", "progressSequence", "callCount"]);
const STRUCTURE_ONLY_KEYS = new Set(["usage", "cost", "stats", "tokensBefore", "contextUsage"]);

const IDENTITY_MARKER = "<id>";
const TIMESTAMP_MARKER = "<timestamp>";
const DURATION_MARKER = "<duration>";
const COUNTER_MARKER = "<n>";
const STRUCTURE_MARKER = "<value>";

const PACKAGE_PATH = /(?:[^\s"'`()[\]]*[/\\])?node_modules[/\\]((?:@[^/\\]+[/\\])?[^/\\]+)/g;
const TEMP_PATH = /(?:[/\\]private)?[/\\](?:var[/\\]folders|tmp|private[/\\]tmp)[^\s"',;)]*/g;
const SESSION_FOLDER = /([/\\]sessions[/\\])--[^/\\\s"']+--/g;
const ISO_TIMESTAMP = /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?/g;
const FILE_TIMESTAMP = /\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}Z/g;
const DIGEST_SEGMENT = /([/\\])[0-9a-f]{64}(?=[/\\])/g;
const SHORT_DIGEST = /^sha256:[0-9a-f]{16}$/;
const EXTENSION_OWNER = /^extension:[A-Za-z0-9_-]{43}$/;
const UUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi;
const DATA_URL = /data:([a-z0-9.+-]+\/[a-z0-9.+-]+);base64,[A-Za-z0-9+/=]+/gi;
const EPOCH_NUMBER = /(?<![.\d])\b\d{13,}\b/g;
const WALL_TIME_TEXT = /\bWall time \d+(?:\.\d+)? seconds?\b/g;
const FAUX_API = /^faux:\d+:[a-z0-9]+$/;
const BASE64_PAYLOAD = /^[A-Za-z0-9+/]{64,}={0,2}$/;

const SNAPSHOT_TRANSIENTS = ["streaming", "toolExecutions", "partialResult", "nestedCalls", "pendingPrompt",
  "queuedItems", "activeToolSegmentId", "contextWindowPolicy.warning"];
const TRANSIENT_EVENT_PATHS: ReadonlyMap<string, ReadonlySet<string>> = new Map([
  ["session.snapshot", new Set(SNAPSHOT_TRANSIENTS)],
  ["session.rebaseline", new Set(SNAPSHOT_TRANSIENTS)],
  ["session.configuration", new Set(SNAPSHOT_TRANSIENTS)],
  ["session.progress", new Set(["message"])],
  ["session.toolProgress", new Set(["data"])],
]);
const NO_TRANSIENT_PATHS: ReadonlySet<string> = new Set<string>();

function normalizeTraceString(value: string, normalization: TraceNormalization): string {
  if (FAUX_API.test(value)) return "<api>";
  if (BASE64_PAYLOAD.test(value)) return `<base64:${value.length}>`;
  if (SHORT_DIGEST.test(value)) return "sha256:<digest>";
  if (EXTENSION_OWNER.test(value)) return "extension:<digest>";
  let text = value;
  for (const root of [...normalization.roots].sort((left, right) => right.length - left.length)) {
    if (root.length > 1) text = text.split(root).join("<tmp>");
  }
  text = text.replace(PACKAGE_PATH, "<pkg:$1>");
  text = text.replace(TEMP_PATH, "<tmp>/<path>");
  text = text.replace(SESSION_FOLDER, "$1<session-cwd>");
  text = text.replace(ISO_TIMESTAMP, TIMESTAMP_MARKER);
  text = text.replace(FILE_TIMESTAMP, TIMESTAMP_MARKER);
  text = text.replace(DIGEST_SEGMENT, "$1<digest>");
  text = text.replace(UUID, IDENTITY_MARKER);
  text = text.replace(DATA_URL, (_match, mime: string) => `data:${mime};base64,<base64>`);
  text = text.replace(EPOCH_NUMBER, "<epoch>");
  text = text.replace(WALL_TIME_TEXT, "Wall time <duration>");
  return text;
}

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

export function hashPromptText(prompt: string, normalization: TraceNormalization): string {
  const normalized = normalizeTraceString(prompt, normalization);
  return `sha256:${createHash("sha256").update(normalized, "utf8").digest("hex")}`;
}

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
      const path = prefix === "" ? key : `${prefix}.${key}`;
      if (skip.has(key) || [...skip].some((entry) => entry.includes(".") && (path === entry || path.endsWith(`.${entry}`)))) continue;
      collectShapePaths(child, path, found, skip);
    }
    return;
  }
  found.add(`${prefix}:${value === null ? "null" : typeof value}`);
}

export function eventShapePaths(topic: string, payload: unknown): string[] {
  return shapePaths(payload, { skip: TRANSIENT_EVENT_PATHS.get(topic) ?? NO_TRANSIENT_PATHS });
}

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

const SHARED_TOOL_SCHEMAS = new Set([
  "ask_user", "display", "notify", "zoom", "date", "memory_search", "delegate", "task", "profile",
  "web_search", "session_search", "session_read", "settings", "projects",
  "read", "bash", "edit", "write", "jev", "swift_app", "computer", "checkin", "report",
]);
const TOOL_SCHEMA_PATH = /(?:^|\.)(?:toolsAdded|availableTools)\[\]\.(?:parameters(?=[:.\[])|description:)/u;

export function withoutSharedToolSchemas(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(withoutSharedToolSchemas);
  if (value === null || typeof value !== "object") return value;
  return Object.fromEntries(Object.entries(value).map(([key, child]) => {
    if (key === "toolsAdded" && Array.isArray(child)) {
      return [key, child.map(tool => {
        if (tool === null || typeof tool !== "object" || !SHARED_TOOL_SCHEMAS.has(tool.name)) return tool;
        const { description: _description, parameters: _parameters, ...identity } = tool;
        return identity;
      })];
    }
    if ((key === "paths" || key === "response") && Array.isArray(child)) {
      return [key, child.filter(path => typeof path !== "string" || !TOOL_SCHEMA_PATH.test(path))
        .map(withoutSharedToolSchemas)];
    }
    return [key, withoutSharedToolSchemas(child)];
  }));
}

function renderTrace(trace: unknown): string {
  return `${JSON.stringify(trace, null, 2)}\n`;
}

export interface GoldenComparison<Trace = BehaviorTrace> {
  readonly module: string;
  readonly goldenPath: string;
  readonly actualPath: string;
  readonly diffPath: string;
  readonly trace: Trace;
  readonly inlineTrace?: TraceValue;
  readonly update: boolean;
  readonly validate: (trace: Trace) => void;
}

export async function compareWithGolden<Trace>(comparison: GoldenComparison<Trace>): Promise<{ updated: boolean; hunks: number }> {
  const lock = lockName(comparison.goldenPath);
  const goldenTrace = comparison.inlineTrace === undefined
    ? comparison.trace
    : { ...(comparison.trace as Record<string, unknown>), inlineTrace: comparison.inlineTrace };
  const rendered = renderTrace(lock === "home-activation-wake" ? goldenTrace : withoutSharedToolSchemas(goldenTrace));
  await mkdir(dirname(comparison.actualPath), { recursive: true });
  await writeFile(comparison.actualPath, rendered);
  const golden = await readFile(comparison.goldenPath, "utf8").catch(() => undefined);
  if (golden === undefined) {
    if (!comparison.update) {
      throw new Error(`Lock ${lockName(comparison.goldenPath)} has no golden at ${comparison.goldenPath}; `
        + `record it with ${LOCK_UPDATE_ENV}=${comparison.module}.`);
    }
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
    `Lock ${lockName(comparison.goldenPath)} (${comparison.module}) differs from ${comparison.goldenPath} (${hunks} hunks).`,
    `Retained actual trace: ${comparison.actualPath}`,
    `Retained unified diff: ${comparison.diffPath}`,
    `Reproduce it with: git diff --no-index --no-color --unified=3 ${comparison.goldenPath} ${comparison.actualPath}`,
    "Review every hunk: a refactor never changes a golden. An intended, approved change updates it with",
    `\`${LOCK_UPDATE_ENV}=${comparison.module}\` on the same run, and the change lists each hunk.`,
    "",
    ...shown,
    ...(lines.length > shown.length ? [`… ${lines.length - shown.length} more diff lines in ${comparison.diffPath}`] : []),
  ].join("\n"));
}

async function writeGolden(goldenPath: string, rendered: string): Promise<void> {
  await mkdir(dirname(goldenPath), { recursive: true });
  await writeFile(goldenPath, rendered);
}

async function unifiedDiff(beforePath: string, afterPath: string): Promise<string> {
  const run = promisify(execFile);
  try {
    const { stdout } = await run("git", ["diff", "--no-index", "--no-color", "--unified=3", beforePath, afterPath], {
      maxBuffer: 64 * 1024 * 1024,
    });
    return stdout;
  } catch (error) {
    const stdout = (error as { stdout?: unknown }).stdout;
    if (typeof stdout === "string" && stdout.length > 0) return stdout;
    throw new Error(`Could not diff the lock trace (${String(error)}); compare ${beforePath} with ${afterPath} by hand.`);
  }
}
