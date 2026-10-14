import { GatewayError } from "../errors.js";
import { arrayOfStrings, boolean, integer, object, oneOf, string, text } from "../util/validation.js";

/** The settings model's vocabulary (docs/settings-model.md section 4).
 * Every key's behaviour is data here; nothing outside the schema names a key. */
export const LAYERS = ["chat", "profile", "project", "mac", "builtin"] as const;
export type LayerId = typeof LAYERS[number];
export const LAYER_LABELS: Record<LayerId, string> = {
  chat: "Chat", profile: "Profile: Home", project: "Project", mac: "Mac", builtin: "Built-in",
};
/** A row's provenance pill: where its value comes from, as a short phrase (#939).
 * The one source of this wording for every surface; LAYER_LABELS still names
 * the layer itself in sentences, details and the Changes feed. */
export const LAYER_SOURCE_LABELS: Record<LayerId, string> = {
  chat: "Set in this chat", profile: "Set in Home profile", project: "Set in project", mac: "Set on Mac", builtin: "Tron default",
};
/** The default a fixed chat value was taken from at start ("From Mac default at start"). */
export const LAYER_DEFAULT_LABELS: Record<Exclude<LayerId, "chat">, string> = {
  profile: "Home profile", project: "project default", mac: "Mac default", builtin: "Tron default",
};
export const TIERS = ["quiet", "notify", "approve"] as const;
export type Tier = typeof TIERS[number];
/** One step up, capped at approve (foundation F3: the web step). */
export function raiseTier(tier: Tier, steps: number): Tier {
  return TIERS[Math.min(TIERS.indexOf(tier) + steps, TIERS.length - 1)]!;
}
export function maxTier(...tiers: Tier[]): Tier {
  return TIERS[Math.max(...tiers.map(tier => TIERS.indexOf(tier)))]!;
}
export type Writer = "ui" | "home" | "worker" | "agent";
export type Direction = "widen" | "narrow";
export type Timing = "fixed" | "live";
export type Effect = "next-turn" | "next-request" | "new-chat" | "reload" | "restart" | "next-memory-pass" | "next-compaction" | "next-change" | "delegate";
export const CONTROLS = ["toggle", "choice", "number", "text", "secret", "list", "checklist", "catalog", "readOnly"] as const;
export type Control = typeof CONTROLS[number];
/** The renderer contract the Gateway speaks (doc 7.5). A client names the
 * controls it implements and its version; anything else falls back. */
export const RENDERER_CONTRACT_VERSION = 1;
export const QUALIFIER_NAMES = ["role", "model", "provider", "tool", "project", "connection", "key", "direction", "server", "note"] as const;
export type QualifierName = typeof QUALIFIER_NAMES[number];
export type Qualifiers = Partial<Record<QualifierName, string>>;

export interface ModelRefValue { provider: string; id: string }

export interface FormatContext {
  modelName(ref: ModelRefValue): string | undefined;
}

export interface ValidateContext {
  /** Admits a newly chosen model (registered, visible for the account). */
  admitModel(ref: ModelRefValue): Promise<void>;
}

/** A value type: its static validation, its display string, and, for types
 * whose stored value is relative to the layer below, how it composes. */
export interface ValueType {
  kind: string;
  validate(value: unknown, label: string, context?: ValidateContext): Promise<unknown> | unknown;
  format(value: unknown, context: FormatContext): string;
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

/** A model ref, or "same as Home" (doc 6.3). */
export function workerModelType(): ValueType {
  const ref = types.modelRef();
  return {
    kind: "workerModelRef",
    validate: async (value, label, context) => isSameAsHome(value) ? { sameAs: "home" } : ref.validate(value, label, context),
    format: (value, context) => isSameAsHome(value) ? "Same as Home" : ref.format(value, context),
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

export function isSameAsHome(value: unknown): value is { sameAs: "home" } {
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
