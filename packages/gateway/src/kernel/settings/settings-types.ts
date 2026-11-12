import { redactCredentials } from "../../util/credential-redaction.js";
import { createHash } from "node:crypto";
import type { ChangeReview } from "../../protocol/types.js";
import { splitModelRef, type LayerId, type FixedSetting } from "./tool-contract.js";
import { GatewayError } from "../../errors.js";
import { core as toolSelection, type BelowList, type Entry } from "../../core/settings/tool-selection/facade.js";
import { arrayOfStrings, boolean, integer, object, oneOf, string, text } from "../../util/validation.js";



export type ObservedStore = { kind: "global" } | { kind: "trust" } | { kind: "mcp" } | { kind: "models" }
  | { kind: "project"; root: string } | { kind: "project-mcp"; root: string };

export interface PlannedWrite { store: ObservedStore; instance: string; changeId: string; value: unknown }

export type StoreLayer = "session" | "home" | "project" | "global" | "default";


export type ProjectGitState =
  | { kind: "local"; reason: "not in a git repository" | ".pi is ignored by git" }
  | { kind: "repo"; head?: Record<string, unknown>; index?: Record<string, unknown> };

export interface SessionStore {
  model?: { provider: string; id: string };
  thinking?: string;
  contextWindow?: { model: string; value: number };
  tools?: string[];
  settings: Record<string, unknown>;
  requestPins?: Record<string, FixedSetting>;
  fixed?: Record<string, FixedSetting>;
}

export interface ProjectStore {
  root: string;
  document: Record<string, unknown>;
  unreadable?: true;
  applied: boolean;
  reason?: "untrusted";
  git?: ProjectGitState;
}

export interface OutsideMark { changeId: string; applyAgain: boolean; before: string; after: string }

export interface SettingsStores {
  layers: readonly StoreLayer[];
  session?: SessionStore;
  home?: Record<string, unknown>;
  project?: ProjectStore;
  global: Record<string, unknown>;
  trust: Record<string, boolean>;
  macTerminal: Record<string, string>;
  macTerminalServerEnabled?: boolean;
  gateway: Record<string, unknown>;
  outside?: Partial<Record<"global" | "project", Record<string, OutsideMark>>>;
}

export interface OptionSources {
  clamp(source: string, dependency: unknown, value: unknown): unknown;
}

export interface ResolveOptions {
  format: FormatContext;
  options: OptionSources;
  keys?: readonly string[];
}

export const LAYER_LABELS: Record<LayerId, string> = {
  project: "Project", session: "Session", global: "Global",
};


function disclosed(text: string): string {
  return redactCredentials(text).replace(/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}\p{Default_Ignorable_Code_Point}]/gu,
    character => character === "\n" ? character : character.split("").map(unit => "\\u" + unit.charCodeAt(0).toString(16).padStart(4, "0")).join(""));
}

export function changeReview(identity: unknown, input: Omit<ChangeReview, "digest">): ChangeReview {
  const review = { title: disclosed(input.title), requiresTap: input.requiresTap,
    ...(input.reason === undefined ? {} : { reason: disclosed(input.reason) }),
    items: input.items.map(item => Object.freeze({ label: disclosed(item.label), before: disclosed(item.before), after: disclosed(item.after),
      ...(item.detail === undefined ? {} : { detail: disclosed(item.detail) }), ...(item.exact === undefined ? {} : { exact: disclosed(item.exact) }) })) };
  const result = { ...review, digest: createHash("sha256").update(JSON.stringify({ identity, review })).digest("hex") };
  Object.freeze(result.items);
  return Object.freeze(result);
}

export type Writer = "ui" | "home" | "worker" | "agent";
export type Timing = "fixed" | "live";
export type Effect = "next-turn" | "next-request" | "new-chat" | "reload" | "restart" | "next-memory-pass" | "next-compaction" | "next-change" | "delegate";
export const CONTROLS = ["toggle", "choice", "text", "list", "checklist", "catalog", "readOnly"] as const;
export type Control = typeof CONTROLS[number];
export const RENDERER_CONTRACT_VERSION = 1;




export interface ModelRefValue { provider: string; id: string }

export interface FormatContext {
  modelName(ref: ModelRefValue): string | undefined;
}

export interface ValidateContext {
  admitModel(ref: ModelRefValue, options?: { physical?: boolean }): Promise<void>;
}

export interface ValueType {
  kind: string;
  validate(value: unknown, label: string, context?: ValidateContext): Promise<unknown> | unknown;
  format(value: unknown, context: FormatContext): string;
  summary?(value: unknown): string;
  compose?(below: unknown, value: unknown): unknown;
  encode?(value: unknown, below: unknown, current: unknown): unknown;
  options?: readonly { value: unknown; label: string; detail?: string }[];
  range?: { min: number; max: number; step?: number; unit?: string };
}

export function formatStoredSetting(type: ValueType | undefined, value: unknown): string {
  if (value === undefined) return "Not set";
  return type ? type.format(value, { modelName: () => undefined }) : JSON.stringify(value);
}

const tokenUnit = (value: number) => value >= 1_000_000 && value % 100_000 === 0 ? `${value / 1_000_000}M`
  : value >= 1_000 && value % 1_000 === 0 ? `${value / 1_000}K` : String(value);

export const types = {
  boolean(labels: [string, string] = ["On", "Off"]): ValueType {
    return {
      kind: "boolean",
      validate: (value, label) => boolean(value, label),
      format: (value) => value ? labels[0] : labels[1],
    };
  },
  integer(min: number, max: number, unit: "tokens" | "ms" | "retries" | "bytes" | "count" = "count", step?: number): ValueType {
    return {
      kind: "integer",
      validate: (value, label) => integer(value, label, min, max),
      format: (value) => {
        const n = value as number;
        if (unit === "tokens") return `${tokenUnit(n)} tokens`;
        if (unit === "ms") return n % 1_000 === 0 ? `${n / 1_000} s` : `${n} ms`;
        if (unit === "retries") return n === 1 ? "1 retry" : `${n} retries`;
        return String(n);
      },
      range: { min, max, ...(step ? { step } : {}), unit },
    };
  },
  choice(values: readonly { value: string; label: string; detail?: string }[], ordered = false): ValueType {
    const allowed = values.map(option => option.value);
    return {
      kind: ordered ? "orderedChoice" : "choice",
      validate: (value, label) => oneOf(value, label, allowed),
      format: (value) => values.find(option => option.value === value)?.label ?? String(value),
      options: values,
    };
  },
  text(max: number, options: { raw?: boolean } = {}): ValueType {
    return {
      kind: "text",
      validate: (value, label) => options.raw ? text(value, label, max) : string(value, label, { max }),
      format: (value) => {
        const s = String(value);
        return s.length > 80 ? `${s.slice(0, 77)}…` : s;
      },
    };
  },
  stringList(maxItems: number, pattern?: RegExp, patternMessage?: string): ValueType {
    return {
      kind: "stringList",
      summary: value => `${(value as string[]).length} item${(value as string[]).length === 1 ? "" : "s"}`,
      validate: (value, label) => {
        const list = arrayOfStrings(value, label, maxItems);
        if (pattern && list.some(item => !pattern.test(item))) throw new GatewayError("invalid_request", patternMessage ?? `${label} has an invalid entry`);
        return list;
      },
      format: (value) => {
        const list = value as string[];
        if (list.length === 0) return "None";
        return list.length <= 3 ? list.join(", ") : `${list.slice(0, 3).join(", ")} +${list.length - 3}`;
      },
    };
  },
  modelRef(): ValueType {
    return {
      kind: "modelRef",
      validate: async (value, label, context) => {
        const ref = object(value, label);
        if (Object.keys(ref).some(name => name !== "provider" && name !== "id")) throw new GatewayError("invalid_request", `${label} accepts only provider and id`);
        const result = { provider: string(ref.provider, `${label}.provider`, { max: 120 }), id: string(ref.id, `${label}.id`, { max: 300 }) };
        await context?.admitModel(result);
        return result;
      },
      format: (value, context) => {
        const ref = value as ModelRefValue;
        return context.modelName(ref) ?? `${ref.provider}/${ref.id}`;
      },
    };
  },
};

export function modelQueueType(role: "worker" | "subagent" | "background"): ValueType {
  const empty = role === "worker" ? "Same as Home" : role === "subagent" ? "Each agent's own model" : "Subagent queue";
  return {
    kind: "stringList",
    summary: value => (value as string[]).length === 0 ? empty : `${(value as string[]).length} model${(value as string[]).length === 1 ? "" : "s"}`,
    validate: async (value, label, context) => {
      const list = arrayOfStrings(value, label, 8);
      if (new Set(list).size !== list.length) throw new GatewayError("invalid_request", `${label} lists a model twice`);
      for (const entry of list) {
        const ref = splitModelRef(entry);
        if (!ref || entry.length > 421) throw new GatewayError("invalid_request", `${label} entries must be provider/model IDs`);
        await context?.admitModel(ref, { physical: true });
      }
      return list;
    },
    format: (value, context) => {
      const list = value as string[];
      return list.length === 0 ? empty : list.map(entry => context.modelName(splitModelRef(entry)!) ?? entry).join(" → ");
    },
  };
}

export function sameAsHomeChoice(inner: ValueType): ValueType {
  return {
    ...inner,
    kind: `${inner.kind}OrSameAsHome`,
    validate: (value, label, context) => isSameAsHome(value) ? { sameAs: "home" } : inner.validate(value, label, context),
    format: (value, context) => isSameAsHome(value) ? "Same as Home" : inner.format(value, context),
    ...(inner.options ? { options: [{ value: { sameAs: "home" }, label: "Same as Home", detail: "Uses Home's own choice" }, ...inner.options] } : {}),
  };
}

function isSameAsHome(value: unknown): value is { sameAs: "home" } {
  return typeof value === "object" && value !== null && (value as Record<string, unknown>).sameAs === "home";
}

const TOOL_ENTRY = /^[+-]?[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$/;
export const DEFAULT_TOOL_NAMES = ["read", "bash", "edit", "write"];
export const PI_BUILTIN_TOOL_NAMES = ["read", "bash", "powershell", "edit", "write", "grep", "find", "ls"];

function isToolModifier(entry: string) {
  return entry.startsWith("+") || entry.startsWith("-");
}

export function toolSelectionType(): ValueType {
  return {
    kind: "toolSelection",
    summary: value => `${(value as string[]).length} tool${(value as string[]).length === 1 ? "" : "s"}`,
    validate: (value, label) => {
      const tools = arrayOfStrings(value, label, 500);
      if (tools.some(name => !TOOL_ENTRY.test(name))) {
        throw new GatewayError("invalid_request", `${label} entries must be tool names or +name/-name modifiers`);
      }
      return tools;
    },
    format: (value) => {
      const list = value as string[];
      if (list.length === 0) return "No tools";
      return list.length <= 4 ? list.join(", ") : `${list.slice(0, 4).join(", ")} +${list.length - 4}`;
    },
    compose: composeToolSelection,
    encode: encodeToolSelection,
  };
}

function toolTokens() {
  const names: unknown[] = [""];
  const tokens = new Map<unknown, number>([["", 0]]);
  const token = (name: unknown): number => {
    let found = tokens.get(name);
    if (found === undefined) {
      tokens.set(name, found = names.length);
      names.push(name);
    }
    return found;
  };
  return {
    token,
    name: (found: number) => names[found] as string,
    entry: (text: string): Entry => isToolModifier(text)
      ? { $: text.startsWith("+") ? "Plus" : "Minus", n: token(text.slice(1)) } : { $: "Plain", n: token(text) },
    text: (entry: Entry) => entry.$ === "Plain" ? names[entry.n] as string : `${entry.$ === "Plus" ? "+" : "-"}${names[entry.n] as string}`,
    below: (below: unknown): BelowList => Array.isArray(below) ? { $: "NamesList", names: below.map(name => token(name)) } : { $: "NoBelowList" },
    defaults: () => DEFAULT_TOOL_NAMES.map(name => token(name)),
  };
}

function composeToolSelection(below: unknown, value: unknown): string[] {
  const names = toolTokens();
  const entries = (value as string[]).map(text => names.entry(text));
  return toolSelection.ComposeList(names.below(below), entries, names.defaults()).map(names.name);
}

function encodeToolSelection(value: unknown, below: unknown, current: unknown): string[] | undefined {
  const names = toolTokens();
  const chosen = (value as string[]).map(text => names.entry(text));
  const held: Entry[] = [];
  if (Array.isArray(current) && chosen.every(entry => entry.$ === "Plain")) {
    for (const text of current as string[]) {
      const entry = names.entry(text);
      held.push(entry);
      if (entry.$ === "Plain") break;
    }
  }
  const stored = toolSelection.EncodeList(chosen, names.below(below), held, names.defaults());
  return stored.$ === "NothingList" ? undefined : stored.entries.map(names.text);
}

export function objectType(kind: string, validate: (value: unknown, label: string) => unknown, format: (value: unknown) => string): ValueType {
  return { kind, validate, format };
}
