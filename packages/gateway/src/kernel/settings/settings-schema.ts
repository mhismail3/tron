import { GatewayError } from "../../errors.js";
import { boolean, integer, object, string, arrayOfStrings } from "../../util/validation.js";
import { type Control, type Effect, type Timing, type ValueType, type Writer, DEFAULT_TOOL_NAMES, modelQueueType, objectType, sameAsHomeChoice, toolSelectionType, types } from "./settings-types.js";
import { MODEL_QUEUE_ROLES, modelQueueKey, type QualifierName, type Direction } from "./tool-contract.js";
import type { StoreLayer } from "./settings-types.js";

interface SectionDeclaration { id: string; title: string; description: string; order: number; harness: boolean; note?: string; chatInline?: boolean }

export const SECTIONS: readonly SectionDeclaration[] = [
  { id: "model", title: "Model", description: "Model and thinking", order: 10, harness: true, chatInline: true },
  { id: "workers", title: "Workers & delegation", description: "Task budget and retained overrides", order: 15, harness: true, chatInline: true },
  { id: "context", title: "Compaction", description: "Automatic summaries and retained context", order: 20, harness: true },
  { id: "tools", title: "Tools", description: "Available tools, code mode, and shell", order: 30, harness: true },
  { id: "run", title: "Connection", description: "Proxy and retained overrides", order: 50, harness: true },
  { id: "trust", title: "Trusted Projects", description: "Project trust decisions and default policy", order: 55, harness: true },
  { id: "notifications", title: "Notifications", description: "Push alerts for agent events; the agent can change them", order: 57, harness: true },
  { id: "connections", title: "Mac Terminal", description: "This iPhone's key on the connected Mac", order: 58, harness: false },
  { id: "accounts", title: "Accounts", description: "Providers, custom models, and services", order: 60, harness: false },
  { id: "sources", title: "Sources", description: "Packages and how they install", order: 70, harness: false },
  { id: "setup", title: "Storage", description: "Import, session storage, and telemetry", order: 80, harness: false },
  { id: "iphone", title: "This iPhone", description: "Appearance and sessions", order: 90, harness: false, note: "Stored on this iPhone. It never changes what the agent does." },
];

export type Binding =
  | { store: "pi"; path: readonly string[]; qualified?: readonly string[] }
  | { store: "pi-model-ref" }
  | { store: "session"; field: "model" | "thinking" | "contextWindow" | "tools" }
  | { store: "session-settings"; path: readonly string[] }
  | { store: "session-launch" }
  | { store: "home"; path: readonly string[] }
  | { store: "trust" }
  | { store: "mac-terminal" }
  | { store: "mac-terminal-service" }
  | { store: "gateway"; path: readonly string[] };

export type TimingDeclaration = Timing | { widen: Timing; narrow: Timing };

export interface KeyDeclaration {
  id: string;
  group: string;
  subgroup?: string;
  fixed?: Partial<Record<QualifierName, string>>;
  qualifier?: QualifierName;
  type: ValueType;
  optionsSource?: { name: string; dependsOn: readonly string[] };
  sessionOverridable: boolean;
  projectSettable: boolean;
  layers: Partial<Record<Exclude<StoreLayer, "default">, Binding>>;
  home?: { layers: readonly Exclude<StoreLayer, "default">[]; defaultValue?: unknown };
  defaultValue?: unknown;
  defaultValueFor?: (qualifiers: Partial<Record<QualifierName, string>>) => unknown;
  timing: TimingDeclaration;
  effect: Effect;
  tap?: "trust" | "privacy" | "spend" | "install" | "irreversible";
  direction?: (before: unknown, after: unknown) => Direction;
  writers: readonly Writer[];
  label: string;
  help: string;
  order: number;
  importance: "essential" | "advanced";
  control?: Control;
  fallback?: Control;
  confirm?: string;
  entry?: EntryGuidance;
}

export interface EntryGuidance { hint: string; example: string }

const ANY_ACTOR: readonly Writer[] = ["ui", "home", "agent", "worker"];

const THINKING = [
  { value: "off", label: "Off", detail: "No reasoning before answering" },
  { value: "minimal", label: "Minimal", detail: "The least reasoning the model supports" },
  { value: "low", label: "Low", detail: "Brief reasoning; faster and cheaper" },
  { value: "medium", label: "Medium", detail: "Balanced reasoning for most work" },
  { value: "high", label: "High", detail: "Thorough reasoning for hard problems" },
  { value: "xhigh", label: "Extra high", detail: "More thorough than High, and slower" },
  { value: "max", label: "Max", detail: "The most reasoning the model allows" },
] as const;
const MODEL_QUEUE_LABELS = {
  worker: { label: "Worker models", help: "The models Home's task workers run, in order. Empty uses Home's own model." },
  subagent: { label: "Subagent models", help: "The models subagents fall back through, in order. Empty keeps each agent's own model." },
  background: { label: "Background models", help: "The models for memory and Knowledge calls, in order. Empty uses the subagent models." },
} as const;
const QUEUE = [
  { value: "all", label: "All at once", detail: "Every waiting message is delivered together" },
  { value: "one-at-a-time", label: "One at a time", detail: "Waiting messages are delivered one per turn" },
] as const;

const larger = (before: unknown, after: unknown): Direction =>
  typeof before === "number" && typeof after === "number" && after < before ? "narrow" : "widen";
const turnsOn = (_before: unknown, after: unknown): Direction => after === true ? "narrow" : "widen";
const grants = (_before: unknown, after: unknown): Direction => after === true ? "widen" : "narrow";
const toolsDirection = (before: unknown, after: unknown): Direction => {
  const was = new Set(Array.isArray(before) ? before as string[] : []);
  return Array.isArray(after) && (after as string[]).some(name => !was.has(name)) ? "widen" : "narrow";
};

function thinkingBudgetsType(): ValueType {
  const levels = ["minimal", "low", "medium", "high"] as const;
  const max = 10_000_000;
  return {
    ...objectType("numberMap", (value, label) => {
      const budgets = object(value, label);
      if (Object.keys(budgets).some(key => !levels.some(level => level === key))) {
        throw new GatewayError("invalid_request", `${label} contains an unsupported thinking level`);
      }
      const result: Record<string, number> = {};
      for (const key of levels) {
        if (budgets[key] !== undefined) result[key] = integer(budgets[key], `${label}.${key}`, 0, max);
      }
      return result;
    }, value => Object.entries(value as Record<string, number>).map(([k, v]) => `${k} ${v}`).join(", ") || "Default"),
    options: levels.map(value => ({ value, label: value[0]!.toUpperCase() + value.slice(1) })),
    range: { min: 0, max, step: 1, unit: "tokens" },
  };
}

const TASK_BUDGET_FIELDS = ["inputTokens", "outputTokens"] as const;
function taskBudgetType(): ValueType {
  const max = 10_000_000_000;
  return {
    ...objectType("numberMap", (value, label) => {
      const budget = object(value, label);
      if (Object.keys(budget).some(key => !TASK_BUDGET_FIELDS.some(field => field === key))) {
        throw new GatewayError("invalid_request", `${label} names a field other than inputTokens or outputTokens`);
      }
      const result: Record<string, number> = {};
      for (const field of TASK_BUDGET_FIELDS) {
        if (budget[field] !== undefined) result[field] = integer(budget[field], `${label}.${field}`, 1, max);
      }
      return result;
    }, value => Object.entries(value as Record<string, number>)
      .map(([field, tokens]) => `${field === "inputTokens" ? "input" : "output"} ${tokens}`).join(", ") || "No limit"),
    options: [{ value: "inputTokens", label: "Input tokens" }, { value: "outputTokens", label: "Output tokens" }],
    range: { min: 1, max, step: 1, unit: "tokens" },
  };
}

const raisesBudget = (before: unknown, after: unknown): Direction => {
  const was = (before ?? {}) as Record<string, number>, next = (after ?? {}) as Record<string, number>;
  return TASK_BUDGET_FIELDS.some(field => was[field] !== undefined && (next[field] === undefined || next[field]! > was[field]!)) ? "widen" : "narrow";
};

function packagesType(): ValueType {
  return objectType("packages", (value, label) => {
    if (!Array.isArray(value) || value.length > 500) throw new GatewayError("invalid_request", `${label} must be an array with at most 500 entries`);
    return value.map((entry, index) => {
      const name = `${label}[${index}]`;
      if (typeof entry === "string") return string(entry, name, { max: 2_000 });
      const item = object(entry, name);
      const result: Record<string, unknown> = { source: string(item.source, `${name}.source`, { max: 2_000 }) };
      if (item.autoload !== undefined) result.autoload = boolean(item.autoload, `${name}.autoload`);
      for (const key of ["extensions", "skills", "prompts", "themes"] as const) {
        if (item[key] !== undefined) result[key] = arrayOfStrings(item[key], `${name}.${key}`, 500);
      }
      return result;
    });
  }, (value) => {
    const list = value as unknown[];
    return list.length === 0 ? "None" : list.length === 1 ? "1 package" : `${list.length} packages`;
  });
}

const pi = (...path: string[]): Binding => ({ store: "pi", path });

const both = (binding: Binding) => ({ project: binding, global: binding });
const sessionPi = (...path: string[]) => ({ session: { store: "session-settings", path } as Binding, ...both(pi(...path)) });

const thinkingType = types.choice(THINKING, true);

export function createSettingsSchema(homeToolNames: readonly string[], compactionInstructionLimit: number, validateTerminalKey: (value: unknown, label: string) => string) {
  const KEYS: readonly KeyDeclaration[] = ([
    {
      id: "model.ref[role=chat]", sessionOverridable: true, projectSettable: true, group: "model", fixed: { role: "chat" }, type: types.modelRef(),
      optionsSource: { name: "catalog.models", dependsOn: [] },
      layers: { session: { store: "session", field: "model" }, home: { store: "home", path: ["model", "chat"] }, ...both({ store: "pi-model-ref" }) },
      timing: "fixed", effect: "next-turn", writers: ANY_ACTOR,
      label: "Model", help: "The model this chat runs.", order: 10, importance: "essential", control: "catalog", fallback: "readOnly",
    },
    {
      id: "model.thinking[role=chat]", sessionOverridable: true, projectSettable: true, group: "model", fixed: { role: "chat" }, qualifier: "model", type: thinkingType,
      defaultValue: "medium",
      optionsSource: { name: "catalog.thinkingLevels", dependsOn: ["model.ref[role=chat]"] },
      layers: {
        session: { store: "session", field: "thinking" }, home: { store: "home", path: ["thinking", "chat"] },
        ...both({ store: "pi", path: ["defaultThinkingLevel"], qualified: ["modelThinkingLevels", "{model}"] }),
      },
      timing: "fixed", effect: "next-turn", writers: ANY_ACTOR,
      label: "Thinking", help: "How much the model reasons before it answers.",
      order: 20, importance: "essential", control: "choice",
    },
    {
      id: "model.contextWindow", sessionOverridable: true, projectSettable: true, group: "model", qualifier: "model", type: types.integer(1_024, 100_000_000, "tokens"),
      optionsSource: { name: "catalog.contextWindow", dependsOn: ["model.ref[role=chat]"] },
      layers: { session: { store: "session", field: "contextWindow" }, ...both(pi("modelContextWindows", "{model}")) },
      timing: "fixed", effect: "next-turn", writers: ANY_ACTOR,
      label: "Context window", help: "Tokens of conversation the model is given.",
      order: 30, importance: "essential",
    },
    {
      id: "model.thinkingBudgets", sessionOverridable: false, projectSettable: false, group: "workers", type: thinkingBudgetsType(),
      layers: both(pi("thinkingBudgets")), timing: "fixed", effect: "new-chat", writers: ANY_ACTOR,
      label: "Thinking budgets", help: "Token budget per thinking level, for models that take one.", order: 60, importance: "advanced",
    },
    {
      id: "model.thinking[role=summarizer]", sessionOverridable: false, projectSettable: true, home: { layers: [] }, group: "context", fixed: { role: "summarizer" },
      type: types.choice([{ value: "inherit", label: "Same as chat", detail: "Uses the chat's own thinking level" }, ...THINKING], true),
      layers: both(pi("compaction", "thinkingLevel")), defaultValue: "inherit", timing: "live", effect: "next-compaction",
      writers: ANY_ACTOR, label: "Summary thinking", help: "Thinking level for compaction summaries.", order: 80,
      importance: "advanced",
    },
    ...MODEL_QUEUE_ROLES.map((role, index): KeyDeclaration => ({
      id: modelQueueKey(role), sessionOverridable: true, projectSettable: false, group: "workers", fixed: { role }, type: modelQueueType(role),
      defaultValue: [],
      layers: { ...(role === "background" ? {} : { session: { store: "session-launch" as const } }),
        home: { store: "home", path: ["modelQueue", role] }, global: { store: "gateway", path: ["modelQueues", role] } },
      timing: "live", effect: role === "worker" ? "delegate" : role === "subagent" ? "next-request" : "next-memory-pass",
      writers: ["ui", "home"], label: MODEL_QUEUE_LABELS[role].label, help: MODEL_QUEUE_LABELS[role].help,
      order: 40 + index * 2, importance: "essential", control: "list", fallback: "readOnly",
      optionsSource: { name: "catalog.models", dependsOn: [] },
    })),
    {
      id: "model.thinking[role=worker]", sessionOverridable: true, projectSettable: false, group: "workers", fixed: { role: "worker" }, type: sameAsHomeChoice(thinkingType),
      layers: { home: { store: "home", path: ["thinking", "worker"] }, global: { store: "gateway", path: ["workerThinking"] } }, defaultValue: { sameAs: "home" },
      timing: "fixed", effect: "delegate", writers: ["ui", "home"],
      label: "Worker thinking", help: "The thinking level Home's task workers start with.", order: 41, importance: "essential",
    },
    {
      id: "context.compaction.enabled", sessionOverridable: true, projectSettable: true, home: { layers: [] }, group: "context", subgroup: "Compaction", type: types.boolean(),
      layers: sessionPi("compaction", "enabled"), defaultValue: true, timing: "live", effect: "next-compaction",
      writers: ANY_ACTOR, label: "Automatic compaction", help: "Summarize older conversation when the context fills.",
      order: 10, importance: "essential",
    },
    {
      id: "context.compaction.reserveTokens", sessionOverridable: true, projectSettable: true, home: { layers: [] }, group: "context", subgroup: "Compaction", qualifier: "model", type: types.integer(1_024, 1_000_000, "tokens"),
      layers: { session: { store: "session-settings", path: ["compaction", "reserveTokens"] }, ...both({ store: "pi", path: ["compaction", "reserveTokens"], qualified: ["compaction", "modelOverrides", "{model}", "reserveTokens"] }) },
      defaultValue: 16_384, timing: "live", effect: "next-compaction", writers: ANY_ACTOR,
      label: "Response reserve", help: "Tokens kept free for the reply. Compaction starts once the conversation fills the context window minus this.", order: 20, importance: "advanced",
    },
    {
      id: "context.compaction.keepRecentTokens", sessionOverridable: true, projectSettable: true, home: { layers: [] }, group: "context", subgroup: "Compaction", qualifier: "model", type: types.integer(0, 1_000_000, "tokens"),
      layers: { session: { store: "session-settings", path: ["compaction", "keepRecentTokens"] }, ...both({ store: "pi", path: ["compaction", "keepRecentTokens"], qualified: ["compaction", "modelOverrides", "{model}", "keepRecentTokens"] }) },
      defaultValue: 20_000, timing: "live", effect: "next-compaction", writers: ANY_ACTOR,
      label: "Kept after compaction", help: "The latest tokens of conversation kept word for word; older turns become a summary.", order: 30, importance: "advanced",
    },
    {
      id: "context.compaction.instructions", sessionOverridable: true, projectSettable: true, home: { layers: [] }, group: "context", subgroup: "Compaction", type: types.text(compactionInstructionLimit, { raw: true }),
      layers: sessionPi("compaction", "instructions"), defaultValue: "", timing: "live", effect: "next-compaction", writers: ["ui", "home"],
      label: "Summary instructions", help: "Extra instructions for compaction summaries.", order: 40, importance: "advanced",
    },
    {
      id: "context.branchSummary.reserveTokens", sessionOverridable: false, projectSettable: true, home: { layers: [] }, group: "context", subgroup: "Compaction", type: types.integer(1_024, 1_000_000, "tokens"),
      layers: both(pi("branchSummary", "reserveTokens")), defaultValue: 16_384, timing: "live", effect: "next-compaction",
      writers: ANY_ACTOR, label: "Branch summary reserve", help: "Tokens reserved when summarizing an abandoned branch.",
      order: 50, importance: "advanced",
    },
    {
      id: "context.images.autoResize", sessionOverridable: true, projectSettable: true, group: "tools", subgroup: "Images", type: types.boolean(),
      layers: sessionPi("images", "autoResize"), defaultValue: true, timing: "fixed", effect: "reload", writers: ANY_ACTOR,
      label: "Resize images", help: "Shrink large images before they are sent.", order: 60, importance: "advanced",
    },
    {
      tap: "privacy", id: "context.images.block", sessionOverridable: true, projectSettable: false, group: "tools", subgroup: "Images", type: types.boolean(["Blocked", "Allowed"]),
      layers: sessionPi("images", "blockImages"), defaultValue: false, timing: { narrow: "live", widen: "fixed" }, effect: "next-request",
      direction: turnsOn, writers: ANY_ACTOR,
      label: "Block images", help: "Replace images with a placeholder for the model.", order: 70, importance: "advanced", control: "toggle",
      confirm: "Allowing images again lets the model see image content.",
    },
    {
      id: "tools.active", sessionOverridable: true, projectSettable: false, group: "tools", type: toolSelectionType(),
      optionsSource: { name: "catalog.tools", dependsOn: [] },
      layers: { session: { store: "session", field: "tools" }, home: { store: "home", path: ["tools"] }, ...both(pi("defaultTools")) },
      home: { layers: ["session", "home"], defaultValue: homeToolNames },
      defaultValue: DEFAULT_TOOL_NAMES, timing: "fixed", effect: "next-turn",
      direction: toolsDirection, writers: ANY_ACTOR,
      label: "Tools", help: "The tools the model may call.", order: 10, importance: "essential", control: "checklist",
    },
    {
      id: "tools.codemode.mode", sessionOverridable: false, projectSettable: false, home: { layers: [] }, group: "tools", type: types.choice([
        { value: "on", label: "On", detail: "The model calls tools directly or from a script" },
        { value: "only", label: "Only code mode", detail: "The model calls tools only from scripts" },
      ]),
      layers: both(pi("codemode", "mode")), timing: "fixed", effect: "reload",
      writers: ["ui", "home"], label: "Code mode", help: "Let the model call tools from a script.", order: 20, importance: "advanced", control: "choice",
    },
    {
      id: "tools.codemode.inlineBudget", sessionOverridable: false, projectSettable: false, home: { layers: [] }, group: "tools", type: types.integer(0, 1_000_000, "tokens"),
      layers: both(pi("codemode", "inlineBudget")), timing: "fixed", effect: "reload", writers: ["ui", "home"],
      label: "Inline budget", help: "Estimated tokens available for inline codemode tool declarations.", order: 30, importance: "advanced",
    },
    {
      tap: "trust", id: "tools.shell.path", sessionOverridable: false, projectSettable: true, home: { layers: [] }, group: "tools", type: types.text(4_096),
      layers: both(pi("shellPath")), timing: "fixed", effect: "reload", writers: ["ui", "home"],
      label: "Shell", help: "The shell the bash tool runs.", order: 40, importance: "advanced", control: "text",
      entry: { hint: "The path to a Bash executable on the Mac. ~ is allowed.", example: "/opt/homebrew/bin/bash" },
    },
    {
      tap: "trust", id: "tools.shell.commandPrefix", sessionOverridable: false, projectSettable: true, home: { layers: [] }, group: "tools", type: types.text(4_096),
      layers: both(pi("shellCommandPrefix")), timing: "fixed", effect: "reload", writers: ["ui", "home"],
      label: "Command prefix", help: "Text run before every shell command.", order: 50, importance: "advanced", control: "text",
      entry: { hint: "Shell code run before each command, on one line.", example: "shopt -s expand_aliases" },
    },
    {
      tap: "trust", id: "permissions.projectTrust", sessionOverridable: false, projectSettable: false, group: "trust", qualifier: "project", type: types.boolean(["Trusted", "Not trusted"]),
      layers: { global: { store: "trust" } }, timing: "live", effect: "reload", direction: grants,
      writers: ["ui", "home"], label: "Trust for this project", help: "Lets this project's extensions, hooks and settings load.",
      order: 10, importance: "essential", control: "toggle", confirm: "Trusting a project runs its extensions and hooks.",
    },
    {
      tap: "trust", id: "permissions.macTerminalKey", sessionOverridable: false, projectSettable: false, group: "connections", subgroup: "Mac Terminal", qualifier: "device",
      type: {
        kind: "text",
        validate: (value: unknown, label: string) => validateTerminalKey(value, label),
        format: (value: unknown) => {
          const blob = String(value).split(" ")[1] ?? "";
          return `ECDSA P-256 key …${blob.slice(-12)}`;
        },
      },
      layers: { global: { store: "mac-terminal" } }, timing: "live", effect: "next-change",
      direction: (_before, after) => after === undefined ? "narrow" : "widen",
      writers: ANY_ACTOR, label: "Mac Terminal key",
      help: "Lets this paired iPhone open a shell through Tron’s private Tailscale-only SSH service, even without the Gateway.",
      order: 15, importance: "advanced", control: "readOnly",
      confirm: "This iPhone’s key will authorize your Mac account through the private Tron SSH service, after you trust its host fingerprint.",
    },
    {
      tap: "trust", id: "permissions.macTerminalServer", sessionOverridable: false, projectSettable: false,
      group: "connections", subgroup: "Mac Terminal", type: types.boolean(["Enabled", "Stopped"]),
      layers: { global: { store: "mac-terminal-service" } }, defaultValue: false,
      timing: "live", effect: "next-change", direction: grants,
      writers: ANY_ACTOR, label: "Private Mac SSH service", order: 16, importance: "advanced", control: "toggle",
      help: "A user-level native SSH server bound only to this Mac’s Tailscale IPv4. Stock Remote Login is unchanged.",
      confirm: "Start Tron’s private user SSH server and create or reuse its host identity. No iPhone key is added until you explicitly trust the fingerprint.",
    },
    {
      tap: "trust", id: "permissions.defaultProjectTrust", sessionOverridable: false, projectSettable: false, group: "trust",
      type: types.choice([
        { value: "ask", label: "Ask", detail: "Asks you the first time a project opens" },
        { value: "always", label: "Always trust", detail: "Loads every project's extensions and hooks" },
        { value: "never", label: "Never trust", detail: "Never loads a project's extensions or hooks" },
      ]),
      layers: { global: pi("defaultProjectTrust") }, defaultValue: "ask", timing: "live", effect: "next-change",
      direction: (_b, a) => a === "always" ? "widen" : "narrow", writers: ["ui"],
      label: "Default trust policy", help: "What happens with a project that has no trust decision.", order: 20, importance: "advanced",
      control: "choice", confirm: "Always trust loads every new project's extensions and hooks without asking.",
    },
    {
      tap: "spend", id: "run.workers.maxConcurrent", sessionOverridable: false, projectSettable: false,
      group: "workers", type: types.integer(1, 64, "count"),
      layers: { global: { store: "gateway", path: ["homeWorkerLimit"] } }, defaultValue: 4,
      timing: "live", effect: "delegate", direction: (before, after) => Number(after) > Number(before) ? "widen" : "narrow",
      writers: ["ui", "home"], label: "Home worker limit", order: 45, importance: "essential",
      help: "Maximum concurrent Home tasks. Lowering the limit does not stop existing tasks.",
      confirm: "Raising the worker limit lets Home run more tasks concurrently.",
    },
    {
      tap: "spend", id: "permissions.budget.task", sessionOverridable: true, projectSettable: false, group: "workers", type: taskBudgetType(),
      layers: { home: { store: "home", path: ["budget", "task"] }, global: { store: "gateway", path: ["taskBudget"] } }, timing: { narrow: "live", widen: "fixed" }, effect: "delegate",
      direction: raisesBudget, writers: ["ui", "home"],
      label: "Task budget", help: "Tokens one Home task may use, cached included. Empty is no limit.",
      order: 50, importance: "essential", control: "list", confirm: "Raising a task budget lets Home's tasks spend more.",
    },
    {
      id: "run.queue.steeringMode", sessionOverridable: true, projectSettable: true, group: "run", subgroup: "Queue", type: types.choice(QUEUE),
      layers: sessionPi("steeringMode"), defaultValue: "one-at-a-time", timing: "live", effect: "next-turn", writers: ANY_ACTOR,
      label: "Steering delivery", help: "How queued steering messages reach a running turn.", order: 10, importance: "advanced",
    },
    {
      id: "run.queue.followUpMode", sessionOverridable: true, projectSettable: true, group: "run", subgroup: "Queue", type: types.choice(QUEUE),
      layers: sessionPi("followUpMode"), defaultValue: "one-at-a-time", timing: "live", effect: "next-turn", writers: ANY_ACTOR,
      label: "Follow-up delivery", help: "How queued follow-up messages are delivered after a turn.", order: 20, importance: "advanced",
    },
    {
      id: "run.retry.enabled", sessionOverridable: true, projectSettable: true, group: "run", subgroup: "Retry", type: types.boolean(),
      layers: sessionPi("retry", "enabled"), defaultValue: true, timing: "live", effect: "next-request", writers: ANY_ACTOR,
      label: "Retry", help: "Retry a failed model request.", order: 30, importance: "advanced",
    },
    {
      id: "run.retry.maxRetries", sessionOverridable: true, projectSettable: true, group: "run", subgroup: "Retry", type: types.integer(0, 20, "retries"),
      layers: sessionPi("retry", "maxRetries"), defaultValue: 3, timing: "live", effect: "next-request", writers: ANY_ACTOR,
      label: "Retries", help: "How many times a failed request is retried.", order: 40, importance: "essential",
    },
    {
      id: "run.retry.baseDelayMs", sessionOverridable: true, projectSettable: true, group: "run", subgroup: "Retry", type: types.integer(0, 300_000, "ms"),
      layers: sessionPi("retry", "baseDelayMs"), defaultValue: 2_000, timing: "live", effect: "next-request", writers: ANY_ACTOR,
      label: "Retry delay", help: "The first delay between retries; later delays grow.", order: 50, importance: "advanced",
    },
    {
      id: "run.retry.provider.timeoutMs", sessionOverridable: true, projectSettable: true, group: "run", subgroup: "Retry", type: types.integer(1_000, 3_600_000, "ms"),
      layers: sessionPi("retry", "provider", "timeoutMs"), timing: "live", effect: "next-request", writers: ANY_ACTOR,
      label: "Provider timeout", help: "The provider client's request timeout.", order: 60, importance: "advanced",
    },
    {
      id: "run.retry.provider.maxRetries", sessionOverridable: true, projectSettable: true, group: "run", subgroup: "Retry", type: types.integer(0, 20, "retries"),
      layers: sessionPi("retry", "provider", "maxRetries"), timing: "live", effect: "next-request", writers: ANY_ACTOR,
      label: "Provider retries", help: "Retries inside the provider client.", order: 70, importance: "advanced",
    },
    {
      id: "run.retry.provider.maxRetryDelayMs", sessionOverridable: true, projectSettable: true, group: "run", subgroup: "Retry", type: types.integer(0, 300_000, "ms"),
      layers: sessionPi("retry", "provider", "maxRetryDelayMs"), defaultValue: 60_000, timing: "live", effect: "next-request",
      writers: ANY_ACTOR, label: "Provider retry delay cap", help: "The longest delay the provider client waits.",
      order: 80, importance: "advanced",
    },
    {
      id: "run.transport", sessionOverridable: true, projectSettable: true, group: "run", subgroup: "Connection",
      type: types.choice([
        { value: "auto", label: "Automatic", detail: "The provider's best available transport" },
        { value: "sse", label: "SSE", detail: "Server-sent events over HTTP" },
        { value: "websocket", label: "WebSocket", detail: "A WebSocket for each request" },
        { value: "websocket-cached", label: "WebSocket (cached)", detail: "One WebSocket reused between requests" },
      ]),
      layers: sessionPi("transport"), defaultValue: "auto", timing: "live", effect: "next-request", writers: ANY_ACTOR,
      label: "Transport", help: "How requests reach the provider.", order: 90, importance: "essential",
    },
    {
      id: "run.httpIdleTimeoutMs", sessionOverridable: true, projectSettable: true, group: "run", subgroup: "Connection", type: types.integer(1_000, 3_600_000, "ms"),
      layers: sessionPi("httpIdleTimeoutMs"), defaultValue: 300_000, timing: "live", effect: "next-request", writers: ANY_ACTOR,
      label: "Idle timeout", help: "How long a silent HTTP stream may idle.", order: 100, importance: "advanced",
    },
    {
      id: "run.websocketConnectTimeoutMs", sessionOverridable: true, projectSettable: true, group: "run", subgroup: "Connection", type: types.integer(1_000, 300_000, "ms"),
      layers: sessionPi("websocketConnectTimeoutMs"), timing: "live", effect: "next-request", writers: ANY_ACTOR,
      label: "WebSocket connect timeout", help: "How long a WebSocket connection may take to open.", order: 110, importance: "advanced",
    },
    {
      tap: "spend", id: "run.cacheWarming", sessionOverridable: false, projectSettable: false, home: { layers: [] }, group: "run", subgroup: "Connection",
      type: types.choice([
        { value: "off", label: "Off", detail: "Prompt caches are never kept warm" },
        { value: "streaming", label: "While running", detail: "Caches stay warm while a turn runs" },
        { value: "idle", label: "Also between runs", detail: "Also kept warm between turns; costs more" },
      ]),
      layers: { global: pi("cacheWarming") }, defaultValue: "off", timing: "fixed", effect: "reload",
      direction: (_b, a) => a === "idle" ? "widen" : "narrow", writers: ["ui", "home"],
      label: "Cache warming", help: "Keep prompt caches warm between runs. Costs money.", order: 130, importance: "advanced",
    },
    ...(["extensions", "skills", "prompts", "themes"] as const).map((name, index): KeyDeclaration => ({
      ...(name === "extensions" || name === "skills" ? { tap: "trust" as const } : {}), id: `sources.${name}`, sessionOverridable: false, projectSettable: true, home: { layers: [] }, group: "sources", subgroup: "Search paths", type: types.stringList(500),
      layers: both(pi(name)), timing: "fixed", effect: "reload", direction: toolsDirection,
      writers: ["ui", "home"], label: name[0]!.toUpperCase() + name.slice(1), help: `Paths searched for ${name}.`,
      order: 10 + index * 10, importance: "advanced",
      ...(name === "extensions" ? {
        control: "list" as const,
        entry: { hint: "An extension file or folder on the Mac. Start with ~ or /.", example: "~/Code/pi-extensions" },
      } : {}),
    })),
    {
      tap: "install", id: "sources.packages", sessionOverridable: false, projectSettable: true, home: { layers: [] }, group: "sources", type: packagesType(), layers: both(pi("packages")), timing: "fixed", effect: "reload",
      direction: (b, a) => larger(Array.isArray(b) ? b.length : 0, Array.isArray(a) ? a.length : 0),
      writers: ["ui", "home"], label: "Packages", help: "Installed pi packages.", order: 50, importance: "essential", control: "readOnly",
    },
    {
      tap: "trust", id: "sources.npmCommand", sessionOverridable: false, projectSettable: false, home: { layers: [] }, group: "sources", type: types.stringList(20), layers: { global: pi("npmCommand") }, timing: "live", effect: "next-change",
      writers: ["ui", "home"], label: "npm command", help: "The command used to install packages.", order: 60, importance: "advanced", control: "list",
      entry: { hint: "One word per value: the program first (npm, pnpm or bun), then any arguments.", example: "pnpm" },
    },
    {
      tap: "privacy", id: "notifications.push.inputNeeded", sessionOverridable: false, projectSettable: false, home: { layers: [] }, group: "notifications", type: types.boolean(),
      layers: { global: { store: "gateway", path: ["notifications", "push", "inputNeeded"] } }, defaultValue: true, timing: "live", effect: "next-request", direction: grants,
      writers: ANY_ACTOR, label: "Input needed", help: "Send a push when Tron needs an answer or approval.", order: 10, importance: "essential",
    },
    {
      tap: "privacy", id: "notifications.push.finished", sessionOverridable: false, projectSettable: false, home: { layers: [] }, group: "notifications", type: types.boolean(),
      layers: { global: { store: "gateway", path: ["notifications", "push", "finished"] } }, defaultValue: true, timing: "live", effect: "next-request", direction: grants,
      writers: ANY_ACTOR, label: "Finished", help: "Send a push when a chat finishes its work.", order: 20, importance: "essential",
    },
    {
      tap: "privacy", id: "notifications.push.waiting", sessionOverridable: false, projectSettable: false, home: { layers: [] }, group: "notifications", type: types.boolean(),
      layers: { global: { store: "gateway", path: ["notifications", "push", "waiting"] } }, defaultValue: true, timing: "live", effect: "next-request", direction: grants,
      writers: ANY_ACTOR, label: "Waiting", help: "Send a push when work is waiting on background tasks.", order: 30, importance: "essential",
    },
    {
      tap: "irreversible", id: "setup.installTelemetry", sessionOverridable: false, projectSettable: false, group: "setup", type: types.boolean(), layers: { global: pi("enableInstallTelemetry") }, defaultValue: true,
      timing: "live", effect: "next-request", writers: ["ui"], label: "Install telemetry",
      help: "Send pi's anonymous install attribution header.", order: 20, importance: "advanced", control: "toggle",
    },
  ] satisfies readonly KeyDeclaration[]);

  const byId = new Map(KEYS.map(key => [key.id, key]));

  function schemaKey(id: string): KeyDeclaration {
    const key = byId.get(id);
    if (!key) throw new GatewayError("not_found", `Unknown setting ${id}`);
    return key;
  }

  function auditSubject(id: string): { label: string; group: string } | undefined {
    if (id === HOME_PROFILE_SUBJECT.id) return HOME_PROFILE_SUBJECT;
    return KEYS.find(key => key.id === id) ?? recordSubject(id);
  }

  return { KEYS, RECORD_SUBJECTS, schemaKey, auditSubject } as const;
}

export type SettingsSchema = ReturnType<typeof createSettingsSchema>;




export function keyForHome(key: KeyDeclaration, home: boolean): KeyDeclaration {
  if (!home) return key;
  const layers = key.home ? Object.fromEntries(Object.entries(key.layers).filter(([layer]) => key.home!.layers.includes(layer as Exclude<StoreLayer, "default">))) : { ...key.layers };
  if (key.sessionOverridable && layers.session?.store === "session-settings" && !layers.home) {
    layers.home = { store: "home", path: ["settings", ...layers.session.path] };
  }
  const type = key.id === "tools.active" ? { ...key.type, summary: (value: unknown) =>
    `${key.type.summary!(value)}; Home wake turns refuse write, edit, bash and computer` } : key.type;
  return { ...key, type, layers, ...(key.home && Object.hasOwn(key.home, "defaultValue") ? { defaultValue: key.home.defaultValue } : {}) };
}

export function keyDefault(key: KeyDeclaration, qualifiers: Partial<Record<QualifierName, string>>): unknown {
  return key.defaultValueFor ? key.defaultValueFor(qualifiers) : key.defaultValue;
}

export function hasRuntimeRequestApplier(key: KeyDeclaration): boolean {
  return key.layers.session?.store === "session-settings" && (key.timing === "fixed" || (key.timing === "live" && ["next-turn", "next-request"].includes(key.effect))
    || (key.effect === "next-request" && typeof key.timing !== "string"));
}

export function hasCompactionApplier(key: KeyDeclaration): boolean {
  return key.layers.session?.store === "session-settings" && key.effect === "next-compaction";
}

export function hasSessionSettingsApplier(key: KeyDeclaration): boolean {
  return hasRuntimeRequestApplier(key) || hasCompactionApplier(key);
}

export interface RecordSubject {
  id: string;
  label: string;
  group: string;
  container: string;
  qualifier: QualifierName;
}

export const RECORD_SUBJECTS: readonly RecordSubject[] = [
  { id: "tools.mcp.server", label: "MCP server", group: "tools", container: "mcpServers", qualifier: "server", },
  { id: "accounts.models.provider", label: "Custom model provider", group: "accounts", container: "providers", qualifier: "provider", },
];

export function recordSubject(id: string): RecordSubject | undefined {
  return RECORD_SUBJECTS.find(subject => subject.id === id);
}

export const HOME_PROFILE_SUBJECT = { id: "home.profile.item", label: "Profile item", group: "context", qualifier: "note" as const, };


export function timingFor(key: KeyDeclaration, direction: Direction): Timing {
  return typeof key.timing === "string" ? key.timing : key.timing[direction];
}
