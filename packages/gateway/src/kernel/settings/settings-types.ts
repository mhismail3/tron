import { createHash } from "node:crypto";
import type { ChangeReview } from "../../protocol/types.js";
import { splitModelRef, type LayerId, type FixedSetting } from "./tool-contract.js";
import { GatewayError } from "../../errors.js";
import { arrayOfStrings, boolean, integer, object, oneOf, string, text } from "../../util/validation.js";



export type ObservedStore = { kind: "global" } | { kind: "trust" } | { kind: "mcp" } | { kind: "models" }
  | { kind: "project"; root: string } | { kind: "project-mcp"; root: string };

/** One planned write the change path brackets: its observed store and instance. */
export interface PlannedWrite { store: ObservedStore; instance: string; changeId: string; value: unknown }

/** Private persistence metadata, never an outward settings scope or grant. */
export type StoreLayer = "session" | "home" | "project" | "global" | "default";


export type ProjectGitState =
  | { kind: "local"; reason: "not in a git repository" | ".pi is ignored by git" }
  | { kind: "repo"; head?: Record<string, unknown>; index?: Record<string, unknown> };

/** The Session scope as the session record holds it (doc 3.2). */
export interface SessionStore {
  model?: { provider: string; id: string };
  thinking?: string;
  /** `tron.context-window.v1`: the chat's explicit window for its model. */
  contextWindow?: { model: string; value: number };
  tools?: string[];
  /** `tron.settings.v1`: explicit Session-scope values for the other keys. */
  settings: Record<string, unknown>;
  /** Effective directional request values retained at this branch's boundary. */
  requestPins?: Record<string, FixedSetting>;
  fixed?: Record<string, FixedSetting>;
}

export interface ProjectStore {
  root: string;
  document: Record<string, unknown>;
  /** The file exists but cannot be parsed; its values are unknown. */
  unreadable?: true;
  applied: boolean;
  reason?: "untrusted";
  /** The store's git state, which badges each Project value (doc 5.7). */
  git?: ProjectGitState;
}

/** The latest outside change of a key instance since Tron last wrote it (doc 5.6). */
export interface OutsideMark { changeId: string; applyAgain: boolean; before: string; after: string }

/** Every store the target's layers read, loaded by their owners (doc 3.2). */
export interface SettingsStores {
  /** The layers this target has (doc 3.3). Built-in is always last. */
  layers: readonly StoreLayer[];
  session?: SessionStore;
  home?: Record<string, unknown>;
  project?: ProjectStore;
  global: Record<string, unknown>;
  /** Saved trust decisions by canonical project path. */
  trust: Record<string, boolean>;
  /** Private Mac Terminal authorizations, by paired device id. */
  macTerminal: Record<string, string>;
  macTerminalServerEnabled?: boolean;
  /** The Gateway-owned settings document (`gateway/settings/gateway.json`). */
  gateway: Record<string, unknown>;
  /** Outside-change marks by layer and key instance (doc 5.6). */
  outside?: Partial<Record<"global" | "project", Record<string, OutsideMark>>>;
}

/** Capability-constrained option sources (doc 3.6, 7.5). */
export interface OptionSources {
  /** The closest supported value, or the value itself when supported. */
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


/** Invisible controls are disclosed, not silently stripped from an exact review. */
export function disclosed(text: string): string {
  return text.replace(/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}\p{Default_Ignorable_Code_Point}]/gu,
    character => character === "\n" ? character : character.split("").map(unit => "\\u" + unit.charCodeAt(0).toString(16).padStart(4, "0")).join(""));
}

/** One immutable before/after projection; the digest binds identity AND everything shown. */
export function changeReview(identity: unknown, input: Omit<ChangeReview, "digest">): ChangeReview {
  const review = { title: disclosed(input.title), requiresTap: input.requiresTap,
    items: input.items.map(item => Object.freeze({ label: disclosed(item.label), before: disclosed(item.before), after: disclosed(item.after),
      ...(item.detail === undefined ? {} : { detail: disclosed(item.detail) }), ...(item.exact === undefined ? {} : { exact: disclosed(item.exact) }) })) };
  const result = { ...review, digest: createHash("sha256").update(JSON.stringify({ identity, review })).digest("hex") };
  Object.freeze(result.items);
  return Object.freeze(result);
}

export type Writer = "ui" | "home" | "worker" | "agent";
export type Timing = "fixed" | "live";
export type Effect = "next-turn" | "next-request" | "new-chat" | "reload" | "restart" | "next-memory-pass" | "next-compaction" | "next-change" | "delegate";
export const CONTROLS = ["toggle", "choice", "text", "secret", "list", "checklist", "catalog", "readOnly"] as const;
export type Control = typeof CONTROLS[number];
/** The renderer contract the Gateway speaks (doc 7.5). A client names the
 * controls it implements and its version; anything else falls back. */
export const RENDERER_CONTRACT_VERSION = 1;




export interface ModelRefValue { provider: string; id: string }

export interface FormatContext {
  modelName(ref: ModelRefValue): string | undefined;
}

export interface ValidateContext {
  /** Admits a newly chosen model (registered, visible for the account; `physical`
   * also refuses a virtual model). */
  admitModel(ref: ModelRefValue, options?: { physical?: boolean }): Promise<void>;
}

/** A value type: its static validation, its display string, and, for types
 * whose stored value is relative to the layer below, how it composes. */
export interface ValueType {
  kind: string;
  validate(value: unknown, label: string, context?: ValidateContext): Promise<unknown> | unknown;
  format(value: unknown, context: FormatContext): string;
  /** Compact row value; history and editors retain the full value. */
  summary?(value: unknown): string;
  /** A layer value that modifies the value below it rather than replacing it.
   * pi's `defaultTools` `+name`/`-name` lists are the one such type today. */
  compose?(below: unknown, value: unknown): unknown;
  /** For a composing type: how a layer stores a chosen value, given the value
   * composed below it and what the layer holds now. Undefined: hold nothing. */
  encode?(value: unknown, below: unknown, current: unknown): unknown;
  /** Static options for `choice` controls. */
  /** A choice's `detail` is one line on what choosing it changes. */
  options?: readonly { value: unknown; label: string; detail?: string }[];
  range?: { min: number; max: number; step?: number; unit?: string };
}

/** Audit/conflict display uses the declared formatter, never a client key table. */
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

/** An ordered model fallback queue (doc 6.3): `provider/id` strings, first
 * choice first. Its list kind keeps the generic list editor; its
 * `catalog.models` options source lets that editor pick models. */
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
        // A queue names physical models; the virtual subagent model routes over one.
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
/** pi's built-in tools (`allToolNames` in pi's core/tools, which pi does not
 * export). The tool catalog's integration test holds this to a live session. */
export const PI_BUILTIN_TOOL_NAMES = ["read", "bash", "powershell", "edit", "write", "grep", "find", "ls"];

function isToolModifier(entry: string) {
  return entry.startsWith("+") || entry.startsWith("-");
}

/** pi's `defaultTools`: plain names replace the selection below; a list of only
 * `+name`/`-name` entries modifies it (pi `settings-manager.js` mergeDefaultTools
 * and resolveDefaultTools). The resolver composes; it never re-implements merge. */
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
    compose: (below, value) => {
      const entries = value as string[];
      const base = Array.isArray(below) ? below as string[] : undefined;
      if (base && entries.length > 0 && entries.every(isToolModifier)) return applyToolModifiers([...base], entries);
      return applyToolModifiers(entries.filter(entry => !isToolModifier(entry)).length > 0 || entries.length === 0
        ? entries.filter(entry => !isToolModifier(entry)) : [...DEFAULT_TOOL_NAMES], entries);
    },
    // A chosen selection keeps the layer's form: a layer of `+name`/`-name`
    // entries (or one holding nothing) stays relative to the layers below it, so
    // a later Mac change still flows through; a plain list stays a plain list.
    encode: (value, below, current) => {
      const chosen = value as string[];
      if (chosen.some(isToolModifier)) return chosen;
      const stored = Array.isArray(current) ? current as string[] : [];
      if (stored.length > 0 && !stored.every(isToolModifier)) return chosen;
      const base = Array.isArray(below) ? below as string[] : DEFAULT_TOOL_NAMES;
      const entries = [...chosen.filter(name => !base.includes(name)).map(name => `+${name}`),
        ...base.filter(name => !chosen.includes(name)).map(name => `-${name}`)];
      return entries.length > 0 ? entries : undefined;
    },
  };
}

function applyToolModifiers(tools: string[], entries: string[]): string[] {
  for (const entry of entries) {
    if (!isToolModifier(entry)) continue;
    const name = entry.slice(1);
    const index = tools.indexOf(name);
    if (entry.startsWith("+") && index === -1 && name) tools.push(name);
    else if (entry.startsWith("-") && index !== -1) tools.splice(index, 1);
  }
  return tools;
}

/** A free-form, statically validated object (thinking budgets, packages). */
export function objectType(kind: string, validate: (value: unknown, label: string) => unknown, format: (value: unknown) => string): ValueType {
  return { kind, validate, format };
}
