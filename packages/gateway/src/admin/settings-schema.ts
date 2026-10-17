import { GatewayError } from "../errors.js";
import { COMPACTION_POLICY_INSTRUCTION_LIMIT } from "../runtime/compaction-policy.js";
import { validateMacTerminalKey } from "../security/mac-terminal.js";
import { MODEL_QUEUE_ROLES, modelQueueKey } from "../providers/model-queue.js";
import { boolean, integer, object, string, arrayOfStrings } from "../util/validation.js";
import {
  type Control, type Direction, type Effect, type LayerId, type QualifierName, type Tier, type Timing, type ValueType, type Writer,
  DEFAULT_TOOL_NAMES, modelQueueType, objectType, sameAsHomeChoice, toolSelectionType, types,
} from "./settings-types.js";

/**
 * The settings schema (docs/settings-model.md section 4, foundation F1).
 *
 * Each key is declared once. Its allowed layers, storage bindings, timing,
 * floors, writers and display metadata are data; the resolver, the change path
 * and the iOS renderer read them and hold no per-key code. Adding a key is one
 * entry here.
 */

/** A section's `description` is the one line a client shows beside its title. */
export interface SectionDeclaration { id: string; title: string; description: string; order: number; harness: boolean; note?: string }

export const SECTIONS: readonly SectionDeclaration[] = [
  { id: "model", title: "Model", description: "Models, thinking, and context window", order: 10, harness: true },
  { id: "context", title: "Context", description: "Compaction and image handling", order: 20, harness: true },
  { id: "tools", title: "Tools", description: "Available tools, code mode, and shell", order: 30, harness: true },
  { id: "permissions", title: "Permissions", description: "Project trust and agent approvals", order: 40, harness: true },
  { id: "run", title: "Run", description: "Message delivery, retries, and transport", order: 50, harness: true },
  { id: "accounts", title: "Accounts", description: "Providers, custom models, and services", order: 60, harness: false },
  { id: "sources", title: "Sources", description: "Packages and how they install", order: 70, harness: false },
  { id: "setup", title: "Setup", description: "Import, session storage, and telemetry", order: 80, harness: false },
  { id: "iphone", title: "This iPhone", description: "Appearance and sessions", order: 90, harness: false, note: "Stored on this iPhone. It never changes what the agent does." },
];

/** Where a layer stores a key (doc 3.2). Paths may hold `{model}`, which a
 * `model` qualifier fills with `provider/id`. A pi binding's `qualified` path is
 * the per-model instance of an otherwise unqualified key; it is read across
 * every layer before the unqualified path, exactly as pi resolves
 * `modelOverrides ?? ordinary` on its merged settings (doc 2.1 qualifiers). */
export type Binding =
  | { store: "pi"; path: readonly string[]; qualified?: readonly string[] }
  | { store: "pi-model-ref" }
  | { store: "chat"; field: "model" | "thinking" | "contextWindow" | "tools" }
  | { store: "chat-settings"; path: readonly string[] }
  | { store: "profile"; path: readonly string[] }
  | { store: "trust" }
  /** `~/.ssh/authorized_keys`, the Tron lines only (security/mac-terminal.ts):
   * one Mac Terminal key per paired iPhone, qualified by `device`. */
  | { store: "mac-terminal" }
  /** `<tronHome>/gateway/settings/floors.json`: the maintainer's floor
   * overrides, `{ [keyId]: { widen?, narrow? } }` (doc 5.4). */
  | { store: "floors" }
  /** `<tronHome>/gateway/settings/gateway.json`: Gateway-owned behaviour no pi
   * file holds, by path (Mac layer only; only the change path writes it). */
  | { store: "gateway"; path: readonly string[] };

export type Floor = Tier | { widen: Tier; narrow: Tier };
export type TimingDeclaration = Timing | { widen: Timing; narrow: Timing };

export interface KeyDeclaration {
  /** Stable dotted id plus any fixed qualifier, e.g. `model.ref[role=worker]`. */
  id: string;
  group: string;
  subgroup?: string;
  /** Fixed qualifier values this instance is declared for (e.g. role). */
  fixed?: Partial<Record<QualifierName, string>>;
  /** A dynamic qualifier whose instances are enumerated from the stores. */
  qualifier?: QualifierName;
  type: ValueType;
  optionsSource?: { name: string; dependsOn: readonly string[] };
  layers: Partial<Record<Exclude<LayerId, "builtin">, Binding>>;
  /** The built-in value. `undefined` means none: the key is unset. */
  builtin?: unknown;
  /** A built-in that depends on the instance (a floor's built-in is that key's code floor). */
  builtinFor?: (qualifiers: Partial<Record<QualifierName, string>>) => unknown;
  timing: TimingDeclaration;
  effect: Effect;
  floor: Floor;
  /** How a change's direction is read. Keys without one use their single floor. */
  direction?: (before: unknown, after: unknown) => Direction;
  /** Who may request a change. This list is the grant (decision 34): there is
   * no per-task or per-chat grant beside it, and a task worker may change
   * exactly the keys an ordinary chat's agent may. */
  writers: readonly Writer[];
  redacted?: boolean;
  label: string;
  help: string;
  order: number;
  importance: "essential" | "advanced";
  control: Control;
  fallback?: Control;
  confirm?: string;
  /** What to type into a text field or a list's new value (#939): the format in
   * a short sentence, and a realistic example shown as the field's placeholder.
   * Every editable text and string-list key has one. */
  entry?: EntryGuidance;
}

export interface EntryGuidance { hint: string; example: string }

/** Search-path entries, as pi resolves them (pi docs/settings.md "Resources"). */
const SEARCH_PATH_ENTRY: Record<"extensions" | "skills" | "prompts" | "themes", EntryGuidance> = {
  extensions: { hint: "An extension file or folder on the Mac. Start with ~ or /.", example: "~/Code/pi-extensions" },
  skills: { hint: "A skill file or folder on the Mac. Start with ~ or /.", example: "~/Code/skills" },
  prompts: { hint: "A prompt-template file or folder on the Mac. Start with ~ or /.", example: "~/Code/prompts" },
  themes: { hint: "A theme file or folder on the Mac. Start with ~ or /.", example: "~/Code/themes/dusk.json" },
};

/** The maintainer, Home, an ordinary chat's agent and a task worker. A key an
 * agent may change, a task worker may change too (decision 34). */
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
const turnsOn = (before: unknown, after: unknown): Direction => after === true && before !== true ? "narrow" : "widen";
/** Trust: granting widens, revoking or clearing narrows. */
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

/** A Home task's token budget (doc 6.1): the task record's own spend counters,
 * the only spend Tron measures (home.md Spend). An absent field is no limit. */
export const TASK_BUDGET_FIELDS = ["inputTokens", "outputTokens"] as const;
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

/** A budget widens when any limited field rises or is removed (no limit). */
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

export const TERMINAL_IDLE_DEFAULT_MINUTES = 60;
const TERMINAL_IDLE_CHOICES = [0, 15, 30, 60, 120, 240, 480, 1_440] as const;
/** Minutes, with 0 as Off: a bounded choice, so every client offers the same periods. */
function terminalIdleType(): ValueType {
  const label = (minutes: number) => minutes === 0 ? "Off" : minutes < 60 ? `${minutes} minutes`
    : minutes === 60 ? "1 hour" : `${minutes / 60} hours`;
  return {
    kind: "choice",
    validate: (value, name) => {
      const minutes = integer(value, name, 0, 1_440);
      if (!(TERMINAL_IDLE_CHOICES as readonly number[]).includes(minutes)) throw new GatewayError("invalid_request", `${name} must be one of the offered periods`);
      return minutes;
    },
    format: value => label(value as number),
    options: TERMINAL_IDLE_CHOICES.map(minutes => ({
      value: minutes, label: label(minutes),
      ...(minutes === 0 ? { detail: "Idle terminals stay open and can block a restart" } : {}),
    })),
  };
}
const both = (binding: Binding) => ({ project: binding, mac: binding });
const chatPi = (...path: string[]) => ({ chat: { store: "chat-settings", path } as Binding, ...both(pi(...path)) });

const thinkingType = types.choice(THINKING, true);

const TIER_LABELS = [
  { value: "quiet", label: "Quiet", detail: "The change applies without telling you" },
  { value: "notify", label: "Notify", detail: "The change applies, and you are told" },
  { value: "approve", label: "Approve", detail: "The change waits for your approval" },
] as const;
function tierType(): ValueType { return types.choice(TIER_LABELS, true); }
const TIER_ORDER = ["quiet", "notify", "approve"];
/** A floor change lowers (widens) when the new tier is below the one it replaces. */
const lowers = (before: unknown, after: unknown): Direction =>
  TIER_ORDER.indexOf(String(after)) < TIER_ORDER.indexOf(String(before)) ? "widen" : "narrow";

export const KEYS: readonly KeyDeclaration[] = [
  // Model ---------------------------------------------------------------
  {
    id: "model.ref[role=chat]", group: "model", fixed: { role: "chat" }, type: types.modelRef(),
    optionsSource: { name: "catalog.models", dependsOn: [] },
    layers: { chat: { store: "chat", field: "model" }, profile: { store: "profile", path: ["model", "chat"] }, ...both({ store: "pi-model-ref" }) },
    timing: "fixed", effect: "next-turn", floor: "quiet", writers: ANY_ACTOR,
    label: "Model", help: "The model this chat runs.", order: 10, importance: "essential", control: "catalog", fallback: "readOnly",
  },
  {
    id: "model.thinking[role=chat]", group: "model", fixed: { role: "chat" }, qualifier: "model", type: thinkingType,
    builtin: "medium", // Pinned SDK DEFAULT_THINKING_LEVEL; capability clamping is resolver-owned.
    optionsSource: { name: "catalog.thinkingLevels", dependsOn: ["model.ref[role=chat]"] },
    layers: {
      chat: { store: "chat", field: "thinking" }, profile: { store: "profile", path: ["thinking", "chat"] },
      ...both({ store: "pi", path: ["defaultThinkingLevel"], qualified: ["modelThinkingLevels", "{model}"] }),
    },
    timing: "fixed", effect: "next-turn", floor: "quiet", writers: ANY_ACTOR,
    label: "Thinking", help: "How much the model reasons before it answers.",
    order: 20, importance: "essential", control: "choice",
  },
  {
    id: "model.contextWindow", group: "model", qualifier: "model", type: types.integer(1_024, 100_000_000, "tokens"),
    optionsSource: { name: "catalog.contextWindow", dependsOn: ["model.ref[role=chat]"] },
    layers: { chat: { store: "chat", field: "contextWindow" }, ...both(pi("modelContextWindows", "{model}")) },
    timing: "fixed", effect: "next-turn", floor: "quiet", writers: ANY_ACTOR,
    label: "Context window", help: "Tokens of conversation the model is given.",
    order: 30, importance: "essential", control: "number",
  },
  {
    id: "model.thinkingBudgets", group: "model", subgroup: "Thinking budgets", type: thinkingBudgetsType(),
    layers: both(pi("thinkingBudgets")), timing: "fixed", effect: "new-chat", floor: "quiet", writers: ANY_ACTOR,
    label: "Thinking budgets", help: "Token budget per thinking level, for models that take one.", order: 60, importance: "advanced",
    control: "list",
  },
  {
    id: "model.offered", group: "model", type: types.stringList(500),
    layers: both(pi("enabledModels")), timing: "live", effect: "next-turn", floor: "quiet", writers: ["ui", "home"],
    label: "Offered models", help: "Models offered in the picker. Empty offers every model.", order: 70,
    importance: "advanced", control: "list",
    // pi matches each pattern against `provider/id` and the bare id (pi model-resolver).
    entry: { hint: "A provider/model ID, or a pattern where * matches any text.", example: "anthropic/claude-sonnet-*" },
  },
  {
    id: "model.thinking[role=summarizer]", group: "model", fixed: { role: "summarizer" }, subgroup: "Compaction",
    type: types.choice([{ value: "inherit", label: "Same as chat", detail: "Uses the chat's own thinking level" }, ...THINKING], true),
    layers: both(pi("compaction", "thinkingLevel")), builtin: "inherit", timing: "live", effect: "next-compaction", floor: "quiet",
    writers: ANY_ACTOR, label: "Summary thinking", help: "Thinking level for compaction summaries.", order: 80,
    importance: "advanced", control: "choice",
  },
  ...MODEL_QUEUE_ROLES.map((role, index): KeyDeclaration => ({
    // An ordered fallback queue (settings-model.md 6.3): the first available
    // model runs; a usage-limit error or a provider at 95% usage moves to the next.
    id: modelQueueKey(role), group: "model", fixed: { role }, subgroup: "Model queues", type: modelQueueType(role),
    optionsSource: { name: "catalog.models", dependsOn: [] }, builtin: [],
    layers: { profile: { store: "profile", path: ["modelQueue", role] }, mac: { store: "gateway", path: ["modelQueues", role] } },
    timing: "live", effect: role === "worker" ? "delegate" : role === "subagent" ? "next-request" : "next-memory-pass",
    floor: "notify", writers: ["ui", "home"], label: MODEL_QUEUE_LABELS[role].label, help: MODEL_QUEUE_LABELS[role].help,
    order: 40 + index, importance: "essential", control: "list", fallback: "readOnly",
    entry: { hint: "A provider/model ID. Tron uses the first available model in this order.", example: "anthropic/claude-haiku-5-5" },
  })),
  {
    id: "model.thinking[role=worker]", group: "model", fixed: { role: "worker" }, subgroup: "Workers", type: sameAsHomeChoice(thinkingType),
    layers: { profile: { store: "profile", path: ["thinking", "worker"] } }, builtin: { sameAs: "home" },
    timing: "fixed", effect: "delegate", floor: "notify", writers: ["ui", "home"],
    label: "Worker thinking", help: "The thinking level Home's task workers start with.", order: 45, importance: "advanced", control: "choice",
  },
  // Context -------------------------------------------------------------
  {
    id: "context.compaction.enabled", group: "context", subgroup: "Compaction", type: types.boolean(),
    // The Chat layer is applied by the session's CompactionOperationPolicy, which
    // overlays this chat's `tron.settings.v1` values on Project and Mac (decision 9).
    layers: chatPi("compaction", "enabled"), builtin: true, timing: "live", effect: "next-compaction", floor: "quiet",
    writers: ANY_ACTOR, label: "Automatic compaction", help: "Summarize older conversation when the context fills.",
    order: 10, importance: "essential", control: "toggle",
  },
  {
    id: "context.compaction.reserveTokens", group: "context", subgroup: "Compaction", qualifier: "model", type: types.integer(1_024, 1_000_000, "tokens"),
    layers: { chat: { store: "chat-settings", path: ["compaction", "reserveTokens"] }, ...both({ store: "pi", path: ["compaction", "reserveTokens"], qualified: ["compaction", "modelOverrides", "{model}", "reserveTokens"] }) },
    builtin: 16_384, timing: "live", effect: "next-compaction", floor: "quiet", writers: ANY_ACTOR,
    label: "Reserve", help: "Tokens kept free for the response before compaction starts.", order: 20, importance: "advanced", control: "number",
  },
  {
    id: "context.compaction.keepRecentTokens", group: "context", subgroup: "Compaction", qualifier: "model", type: types.integer(0, 1_000_000, "tokens"),
    layers: { chat: { store: "chat-settings", path: ["compaction", "keepRecentTokens"] }, ...both({ store: "pi", path: ["compaction", "keepRecentTokens"], qualified: ["compaction", "modelOverrides", "{model}", "keepRecentTokens"] }) },
    builtin: 20_000, timing: "live", effect: "next-compaction", floor: "quiet", writers: ANY_ACTOR,
    label: "Keep recent", help: "Recent tokens kept verbatim after compaction.", order: 30, importance: "advanced", control: "number",
  },
  {
    id: "context.compaction.instructions", group: "context", subgroup: "Compaction", type: types.text(COMPACTION_POLICY_INSTRUCTION_LIMIT, { raw: true }),
    layers: chatPi("compaction", "instructions"), timing: "live", effect: "next-compaction", floor: "notify", writers: ["ui", "home"],
    label: "Summary instructions", help: "Extra instructions for compaction summaries.", order: 40, importance: "advanced", control: "text",
    entry: { hint: "Plain sentences added to the summary prompt.", example: "Keep file paths and open decisions." },
  },
  {
    id: "context.branchSummary.reserveTokens", group: "context", subgroup: "Compaction", type: types.integer(1_024, 1_000_000, "tokens"),
    layers: both(pi("branchSummary", "reserveTokens")), builtin: 16_384, timing: "live", effect: "next-compaction", floor: "quiet",
    writers: ANY_ACTOR, label: "Branch summary reserve", help: "Tokens reserved when summarizing an abandoned branch.",
    order: 50, importance: "advanced", control: "number",
  },
  {
    id: "context.images.autoResize", group: "context", subgroup: "Images", type: types.boolean(),
    layers: chatPi("images", "autoResize"), builtin: true, timing: "fixed", effect: "new-chat", floor: "quiet", writers: ANY_ACTOR,
    label: "Resize images", help: "Shrink large images before they are sent.", order: 60, importance: "advanced", control: "toggle",
  },
  {
    id: "context.images.block", group: "context", subgroup: "Images", type: types.boolean(["Blocked", "Allowed"]),
    layers: chatPi("images", "blockImages"), builtin: false, timing: { narrow: "live", widen: "fixed" }, effect: "next-request",
    floor: { widen: "approve", narrow: "quiet" }, direction: turnsOn, writers: ANY_ACTOR,
    label: "Block images", help: "Replace images with a placeholder for the model.", order: 70, importance: "advanced", control: "toggle",
    confirm: "Allowing images again lets the model see image content.",
  },
  // Tools ---------------------------------------------------------------
  {
    id: "tools.active", group: "tools", type: toolSelectionType(),
    optionsSource: { name: "catalog.tools", dependsOn: [] },
    layers: { chat: { store: "chat", field: "tools" }, profile: { store: "profile", path: ["tools"] }, ...both(pi("defaultTools")) },
    builtin: DEFAULT_TOOL_NAMES, timing: "fixed", effect: "next-turn", floor: { widen: "notify", narrow: "quiet" },
    direction: toolsDirection, writers: ANY_ACTOR,
    label: "Tools", help: "The tools the model may call.", order: 10, importance: "essential", control: "checklist",
  },
  {
    id: "tools.codemode.mode", group: "tools", subgroup: "Code mode", type: types.choice([
      { value: "on", label: "On", detail: "The model calls tools directly or from a script" },
      { value: "only", label: "Only code mode", detail: "The model calls tools only from scripts" },
    ]),
    layers: both(pi("codemode", "mode")), timing: "fixed", effect: "new-chat", floor: { widen: "notify", narrow: "quiet" },
    writers: ["ui", "home"], label: "Code mode", help: "Let the model call tools from a script.", order: 20, importance: "advanced", control: "choice",
  },
  {
    id: "tools.codemode.inlineBudget", group: "tools", subgroup: "Code mode", type: types.integer(0, 1_000_000, "bytes"),
    layers: both(pi("codemode", "inlineBudget")), timing: "fixed", effect: "new-chat", floor: "quiet", writers: ["ui", "home"],
    label: "Inline budget", help: "Bytes of script output returned inline.", order: 30, importance: "advanced", control: "number",
  },
  {
    id: "tools.shell.path", group: "tools", subgroup: "Shell", type: types.text(4_096),
    layers: both(pi("shellPath")), timing: "fixed", effect: "new-chat", floor: "notify", writers: ["ui", "home"],
    label: "Shell", help: "The shell the bash tool runs.", order: 40, importance: "advanced", control: "text",
    entry: { hint: "The path to a Bash executable on the Mac. ~ is allowed.", example: "/opt/homebrew/bin/bash" },
  },
  {
    id: "tools.shell.commandPrefix", group: "tools", subgroup: "Shell", type: types.text(4_096),
    layers: both(pi("shellCommandPrefix")), timing: "fixed", effect: "new-chat", floor: "notify", writers: ["ui", "home"],
    label: "Command prefix", help: "Text run before every shell command.", order: 50, importance: "advanced", control: "text",
    entry: { hint: "Shell code run before each command, on one line.", example: "shopt -s expand_aliases" },
  },
  // Permissions ---------------------------------------------------------
  {
    id: "permissions.projectTrust", group: "permissions", qualifier: "project", type: types.boolean(["Trusted", "Not trusted"]),
    layers: { mac: { store: "trust" } }, timing: "live", effect: "reload", floor: { widen: "approve", narrow: "notify" }, direction: grants,
    writers: ["ui", "home"], label: "Trust for this project", help: "Lets this project's extensions, hooks and settings load.",
    order: 10, importance: "essential", control: "toggle", confirm: "Trusting a project runs its extensions and hooks.",
  },
  {
    // A paired iPhone's Mac Terminal key: its line in ~/.ssh/authorized_keys.
    // Adding one lets that iPhone's Secure Enclave key log in over Tailscale,
    // so it is a credential addition (approve); removing it is a revocation.
    id: "permissions.macTerminalKey", group: "permissions", subgroup: "Mac Terminal", qualifier: "device",
    type: {
      kind: "text",
      validate: (value: unknown, label: string) => validateMacTerminalKey(value, label),
      format: (value: unknown) => {
        const blob = String(value).split(" ")[1] ?? "";
        return `ECDSA P-256 key …${blob.slice(-12)}`;
      },
    },
    layers: { mac: { store: "mac-terminal" } }, timing: "live", effect: "next-change",
    floor: { widen: "approve", narrow: "notify" }, direction: (_before, after) => after === undefined ? "narrow" : "widen",
    writers: ANY_ACTOR, label: "Mac Terminal key",
    help: "Lets this paired iPhone open a shell on the Mac over Tailscale through Remote Login, even when the Gateway is not running.",
    order: 15, importance: "advanced", control: "readOnly",
    confirm: "This iPhone's key will be added to ~/.ssh/authorized_keys and can log in to your Mac account over Tailscale.",
  },
  {
    id: "permissions.defaultProjectTrust", group: "permissions",
    type: types.choice([
      { value: "ask", label: "Ask", detail: "Asks you the first time a project opens" },
      { value: "always", label: "Always trust", detail: "Loads every project's extensions and hooks" },
      { value: "never", label: "Never trust", detail: "Never loads a project's extensions or hooks" },
    ]),
    layers: { mac: pi("defaultProjectTrust") }, builtin: "ask", timing: "live", effect: "next-change",
    floor: { widen: "approve", narrow: "notify" }, direction: (_b, a) => a === "always" ? "widen" : "narrow", writers: ["ui"],
    label: "Default trust policy", help: "What happens with a project that has no trust decision.", order: 20, importance: "advanced",
    control: "choice", confirm: "Always trust loads every new project's extensions and hooks without asking.",
  },
  {
    // Lowering a floor widens what agents may do, so it is this key's widen
    // direction and its floor is approve; only the maintainer's tap writes it,
    // and that tap is the approval (doc 4.2, F3). Nothing else is special.
    id: "permissions.floor", group: "permissions", subgroup: "Floors", qualifier: "key", type: tierType(),
    layers: { mac: { store: "floors" } }, builtinFor: (qualifiers) => codeFloor(qualifiers),
    timing: "live", effect: "next-change", floor: { widen: "approve", narrow: "quiet" }, direction: lowers, writers: ["ui"],
    label: "Agent approvals", help: "How much of your attention an agent's change to each setting gets: Quiet applies it, Notify also tells you, Approve waits for you.",
    order: 90, importance: "advanced", control: "choice",
    confirm: "Lowering a floor lets agents make this change with less of your attention.",
  },
  {
    // Profile only (doc 6.2): Home's tasks read it at dispatch. A raise never
    // reaches a running task (widen is fixed at its start); a lower applies at
    // its next turn boundary (narrow live). Unset is no limit, today's behaviour.
    id: "permissions.budget.task", group: "permissions", subgroup: "Home tasks", type: taskBudgetType(),
    layers: { profile: { store: "profile", path: ["budget", "task"] } }, timing: { narrow: "live", widen: "fixed" }, effect: "delegate",
    floor: { widen: "approve", narrow: "quiet" }, direction: raisesBudget, writers: ["ui", "home"],
    label: "Task budget", help: "Tokens one Home task may use, cached included. Empty is no limit.",
    order: 30, importance: "advanced", control: "list", confirm: "Raising a task budget lets Home's tasks spend more.",
  },
  // Run -----------------------------------------------------------------
  {
    id: "run.queue.steeringMode", group: "run", subgroup: "Queue", type: types.choice(QUEUE),
    layers: chatPi("steeringMode"), builtin: "one-at-a-time", timing: "live", effect: "next-turn", floor: "quiet", writers: ANY_ACTOR,
    label: "Steering delivery", help: "How queued steering messages reach a running turn.", order: 10, importance: "advanced", control: "choice",
  },
  {
    id: "run.queue.followUpMode", group: "run", subgroup: "Queue", type: types.choice(QUEUE),
    layers: chatPi("followUpMode"), builtin: "one-at-a-time", timing: "live", effect: "next-turn", floor: "quiet", writers: ANY_ACTOR,
    label: "Follow-up delivery", help: "How queued follow-up messages are delivered after a turn.", order: 20, importance: "advanced", control: "choice",
  },
  {
    id: "run.retry.enabled", group: "run", subgroup: "Retry", type: types.boolean(),
    layers: chatPi("retry", "enabled"), builtin: true, timing: "live", effect: "next-request", floor: "quiet", writers: ANY_ACTOR,
    label: "Retry", help: "Retry a failed model request.", order: 30, importance: "advanced", control: "toggle",
  },
  {
    id: "run.retry.maxRetries", group: "run", subgroup: "Retry", type: types.integer(0, 20, "retries"),
    layers: chatPi("retry", "maxRetries"), builtin: 3, timing: "live", effect: "next-request", floor: "quiet", writers: ANY_ACTOR,
    label: "Retries", help: "How many times a failed request is retried.", order: 40, importance: "essential", control: "number",
  },
  {
    id: "run.retry.baseDelayMs", group: "run", subgroup: "Retry", type: types.integer(0, 300_000, "ms"),
    layers: chatPi("retry", "baseDelayMs"), builtin: 2_000, timing: "live", effect: "next-request", floor: "quiet", writers: ANY_ACTOR,
    label: "Retry delay", help: "The first delay between retries; later delays grow.", order: 50, importance: "advanced", control: "number",
  },
  {
    id: "run.retry.provider.timeoutMs", group: "run", subgroup: "Retry", type: types.integer(1_000, 3_600_000, "ms"),
    layers: chatPi("retry", "provider", "timeoutMs"), timing: "live", effect: "next-request", floor: "quiet", writers: ANY_ACTOR,
    label: "Provider timeout", help: "The provider client's request timeout.", order: 60, importance: "advanced", control: "number",
  },
  {
    id: "run.retry.provider.maxRetries", group: "run", subgroup: "Retry", type: types.integer(0, 20, "retries"),
    layers: chatPi("retry", "provider", "maxRetries"), timing: "live", effect: "next-request", floor: "quiet", writers: ANY_ACTOR,
    label: "Provider retries", help: "Retries inside the provider client.", order: 70, importance: "advanced", control: "number",
  },
  {
    id: "run.retry.provider.maxRetryDelayMs", group: "run", subgroup: "Retry", type: types.integer(0, 300_000, "ms"),
    layers: chatPi("retry", "provider", "maxRetryDelayMs"), builtin: 60_000, timing: "live", effect: "next-request", floor: "quiet",
    writers: ANY_ACTOR, label: "Provider retry delay cap", help: "The longest delay the provider client waits.",
    order: 80, importance: "advanced", control: "number",
  },
  {
    id: "run.transport", group: "run", subgroup: "Connection",
    type: types.choice([
      { value: "auto", label: "Automatic", detail: "The provider's best available transport" },
      { value: "sse", label: "SSE", detail: "Server-sent events over HTTP" },
      { value: "websocket", label: "WebSocket", detail: "A WebSocket for each request" },
      { value: "websocket-cached", label: "WebSocket (cached)", detail: "One WebSocket reused between requests" },
    ]),
    layers: chatPi("transport"), builtin: "auto", timing: "live", effect: "next-request", floor: "quiet", writers: ANY_ACTOR,
    label: "Transport", help: "How requests reach the provider.", order: 90, importance: "advanced", control: "choice",
  },
  {
    id: "run.httpIdleTimeoutMs", group: "run", subgroup: "Connection", type: types.integer(1_000, 3_600_000, "ms"),
    layers: chatPi("httpIdleTimeoutMs"), builtin: 300_000, timing: "live", effect: "next-request", floor: "quiet", writers: ANY_ACTOR,
    label: "Idle timeout", help: "How long a silent HTTP stream may idle.", order: 100, importance: "advanced", control: "number",
  },
  {
    id: "run.websocketConnectTimeoutMs", group: "run", subgroup: "Connection", type: types.integer(1_000, 300_000, "ms"),
    layers: chatPi("websocketConnectTimeoutMs"), timing: "live", effect: "next-request", floor: "quiet", writers: ANY_ACTOR,
    label: "WebSocket connect timeout", help: "How long a WebSocket connection may take to open.", order: 110, importance: "advanced", control: "number",
  },
  {
    id: "run.httpProxy", group: "run", subgroup: "Connection", type: types.text(4_096), redacted: true,
    layers: { mac: pi("httpProxy") }, timing: "live", effect: "restart", floor: "notify", writers: ["ui"],
    label: "HTTP proxy", help: "Proxy for model requests. Applies after a restart.", order: 120, importance: "advanced", control: "secret",
  },
  {
    id: "run.cacheWarming", group: "run", subgroup: "Connection",
    type: types.choice([
      { value: "off", label: "Off", detail: "Prompt caches are never kept warm" },
      { value: "streaming", label: "While running", detail: "Caches stay warm while a turn runs" },
      { value: "idle", label: "Also between runs", detail: "Also kept warm between turns; costs more" },
    ]),
    layers: { mac: pi("cacheWarming") }, builtin: "streaming", timing: "live", effect: "next-turn", floor: { widen: "notify", narrow: "quiet" },
    direction: (_b, a) => a === "idle" ? "widen" : "narrow", writers: ["ui", "home"],
    label: "Cache warming", help: "Keep prompt caches warm between runs. Costs money.", order: 130, importance: "advanced", control: "choice",
  },
  // Sources -------------------------------------------------------------
  ...(["extensions", "skills", "prompts", "themes"] as const).map((name, index): KeyDeclaration => ({
    id: `sources.${name}`, group: "sources", subgroup: "Search paths", type: types.stringList(500),
    layers: both(pi(name)), timing: "fixed", effect: "reload", floor: { widen: "notify", narrow: "quiet" }, direction: toolsDirection,
    writers: ["ui", "home"], label: name[0]!.toUpperCase() + name.slice(1), help: `Paths searched for ${name}.`,
    order: 10 + index * 10, importance: "advanced", control: "list", entry: SEARCH_PATH_ENTRY[name],
  })),
  {
    id: "sources.packages", group: "sources", type: packagesType(), layers: both(pi("packages")), timing: "fixed", effect: "reload",
    floor: { widen: "notify", narrow: "quiet" }, direction: (b, a) => larger(Array.isArray(b) ? b.length : 0, Array.isArray(a) ? a.length : 0),
    writers: ["ui", "home"], label: "Packages", help: "Installed pi packages.", order: 50, importance: "essential", control: "readOnly",
  },
  {
    id: "sources.npmCommand", group: "sources", type: types.stringList(20), layers: { mac: pi("npmCommand") }, timing: "live", effect: "next-change",
    floor: "notify", writers: ["ui"], label: "npm command", help: "The command used to install packages.", order: 60, importance: "advanced", control: "list",
    // pi runs the first value as the program and passes the rest before its own npm arguments.
    entry: { hint: "One word per value: the program first (npm, pnpm or bun), then any arguments.", example: "pnpm" },
  },
  // Setup ---------------------------------------------------------------
  {
    // No writer: the runtime snapshots its session folder under the ownership
    // lock at start, so it changes only while the Gateway is stopped.
    id: "setup.sessionDir", group: "setup", type: types.text(4_096), layers: { mac: pi("sessionDir") }, timing: "live", effect: "restart",
    floor: "notify", writers: [], label: "Session folder", help: "Where chats are stored. Applies after a restart.",
    order: 10, importance: "advanced", control: "text",
    entry: { hint: "A folder path on the Mac. Start with ~ or /.", example: "~/Documents/Tron Sessions" },
  },
  {
    id: "setup.installTelemetry", group: "setup", type: types.boolean(), layers: { mac: pi("enableInstallTelemetry") }, builtin: true,
    timing: "live", effect: "next-request", floor: "quiet", writers: ["ui"], label: "Install telemetry",
    help: "Send pi's anonymous install attribution header.", order: 20, importance: "advanced", control: "toggle",
  },
  {
    // #479: an app terminal left detached at an empty shell prompt is closed
    // after this period, so it stops blocking Gateway restarts. Busy terminals
    // (open on a device, running a program, holding typed input) never close.
    // TerminalService reads it at every idle pass, so a change applies live;
    // Mac Terminal's shell host reads the same store (machine/mac-terminal-host.ts).
    id: "setup.terminalIdleMinutes", group: "setup", type: terminalIdleType(),
    layers: { mac: { store: "gateway", path: ["terminal", "idleMinutes"] } }, builtin: TERMINAL_IDLE_DEFAULT_MINUTES,
    timing: "live", effect: "next-change", floor: "notify", writers: ANY_ACTOR,
    label: "Close idle terminals",
    help: "Closes an app terminal or Mac Terminal shell no device has open, sitting at an empty prompt with nothing typed, after this long.",
    order: 30, importance: "advanced", control: "choice",
  },
];

const byId = new Map(KEYS.map(key => [key.id, key]));

/** The configured idle period for app terminals in ms, or null when off
 * (#479). The Gateway store is the Mac layer's truth; the built-in applies when
 * it is unset. */
export async function terminalIdleLimitMs(model: {
  resolve(target: { kind: "mac" }, session?: undefined, keys?: readonly string[], options?: { storeState?: boolean }): Promise<{ keys: readonly { key: string; value?: unknown }[] }>;
}): Promise<number | null> {
  const resolution = await model.resolve({ kind: "mac" }, undefined, ["setup.terminalIdleMinutes"], { storeState: false });
  const value = resolution.keys.find(row => row.key === "setup.terminalIdleMinutes")?.value ?? TERMINAL_IDLE_DEFAULT_MINUTES;
  return typeof value === "number" && value > 0 ? value * 60_000 : null;
}

export function schemaKey(id: string): KeyDeclaration {
  const key = byId.get(id);
  if (!key) throw new GatewayError("not_found", `Unknown setting ${id}`);
  return key;
}

/** The maintainer's floor overrides as `floors.json` holds them. */
export type FloorOverrides = Record<string, { widen?: Tier; narrow?: Tier }>;

/** A key's floor for a direction: the maintainer's override, else the code floor (doc 5.4). */
export function floorFor(key: KeyDeclaration, direction: Direction, overrides?: FloorOverrides): { floor: Tier; source: "code" | "override" } {
  const override = overrides?.[key.id]?.[direction];
  if (override) return { floor: override, source: "override" };
  return { floor: typeof key.floor === "string" ? key.floor : key.floor[direction], source: "code" };
}

/** The instances of the floor key: one per key, or one per direction for a
 * key whose floor differs by direction. */
export function floorInstances(): Array<{ key: string; direction?: Direction }> {
  return KEYS.flatMap(key => typeof key.floor === "string" ? [{ key: key.id }] : [{ key: key.id, direction: "widen" as const }, { key: key.id, direction: "narrow" as const }]);
}

function codeFloor(qualifiers: Partial<Record<QualifierName, string>>): Tier | undefined {
  const key = qualifiers.key === undefined ? undefined : byId.get(qualifiers.key);
  if (!key) return undefined;
  return typeof key.floor === "string" ? key.floor : key.floor[qualifiers.direction === "narrow" ? "narrow" : "widen"];
}

export function builtinValue(key: KeyDeclaration, qualifiers: Partial<Record<QualifierName, string>>): unknown {
  return key.builtinFor ? key.builtinFor(qualifiers) : key.builtin;
}

/** Run policy and directional request settings reach the SDK at admission.
 * Optional provider fields are replaced at the final provider boundary; fixed
 * directions are retained in the canonical Chat request snapshot. */
export function hasRuntimeRequestApplier(key: KeyDeclaration): boolean {
  return key.layers.chat?.store === "chat-settings" && (key.timing === "fixed" || (key.group === "run" && key.timing === "live")
    || (key.effect === "next-request" && typeof key.timing !== "string"));
}

/** Compaction keys reach a chat through its CompactionOperationPolicy at the
 * next compaction boundary, not through the request settings. */
export function hasCompactionApplier(key: KeyDeclaration): boolean {
  return key.layers.chat?.store === "chat-settings" && key.effect === "next-compaction";
}

/** Home keeps its own history with SDK compaction off, so the Home chat has no
 * Chat layer for compaction keys: it is neither served nor writable there. */
export function chatLayerApplies(key: KeyDeclaration, home: boolean): boolean {
  return !(home && hasCompactionApplier(key));
}

/** Whether a Chat-layer value of this key has a runtime owner that honours it. */
export function hasChatSettingsApplier(key: KeyDeclaration): boolean {
  return hasRuntimeRequestApplier(key) || hasCompactionApplier(key);
}

/**
 * Record subjects: configuration that has its own owner and editor rather than a
 * schema key (doc 7.6 hand-built screens), compared with what Tron last observed
 * so an outside edit is recorded, shown in Changes and pushed by its floor (doc
 * 5.6). One subject instance per entry of `container`; values are compared by
 * digest only. They never resolve as settings.
 */
export interface RecordSubject {
  id: string;
  label: string;
  group: string;
  container: string;
  qualifier: QualifierName;
  /** Fixed in code; decision 13: Tools and credential-bearing changes push. */
  floor: Tier;
}

export const RECORD_SUBJECTS: readonly RecordSubject[] = [
  { id: "tools.mcp.server", label: "MCP server", group: "tools", container: "mcpServers", qualifier: "server", floor: "notify" },
  { id: "accounts.models.provider", label: "Custom model provider", group: "accounts", container: "providers", qualifier: "provider", floor: "notify" },
];

export function recordSubject(id: string): RecordSubject | undefined {
  return RECORD_SUBJECTS.find(subject => subject.id === id);
}

/**
 * Home's learned profile items (doc 6.4): Knowledge notes, changed by Home's `profile`
 * tool and the maintainer's `home.profileChange` through the change path, which records
 * one instance per note (qualifier `note`). Not a key: an item never resolves as a
 * setting, and Knowledge stays its store.
 */
export const HOME_PROFILE_SUBJECT = { id: "home.profile.item", label: "Profile item", group: "context", qualifier: "note" as const, floor: "quiet" as Tier };

/** The section group and label of a recorded key or subject, or undefined for one this
 * Gateway no longer declares. */
export function auditSubject(id: string): { label: string; group: string } | undefined {
  if (id === HOME_PROFILE_SUBJECT.id) return HOME_PROFILE_SUBJECT;
  return KEYS.find(key => key.id === id) ?? recordSubject(id);
}

export function timingFor(key: KeyDeclaration, direction: Direction): Timing {
  return typeof key.timing === "string" ? key.timing : key.timing[direction];
}
