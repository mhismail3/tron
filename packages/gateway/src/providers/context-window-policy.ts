import { existsSync } from "node:fs";
import type { Model } from "@earendil-works/pi-ai";
import { estimateTokens, type AgentSession, type ExtensionFactory, type ModelRuntime } from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import type { ContextWindowLimits, ContextWindowPolicy, ModelRef } from "../protocol/types.js";

export const CONTEXT_WINDOW_ENTRY = "tron.context-window.v1";
export const MAX_CONTEXT_PREFERENCES = 500;
const MAX_CONTEXT_TOKENS = 100_000_000;
const DEFAULT_COMPACTION = { reserveTokens: 16_384, keepRecentTokens: 20_000 };
type CompactionBudget = typeof DEFAULT_COMPACTION;
type RuntimeModel = Model<any>;

export function contextModelKey(model: ModelRef): string {
  return `${model.provider}/${model.id}`;
}

export function parseContextModelKey(key: string): ModelRef {
  const separator = key.indexOf("/");
  const provider = key.slice(0, separator);
  const id = key.slice(separator + 1);
  if (separator < 1 || provider.length > 120 || !id || id.length > 300 || /[\u0000-\u001f\u007f]/u.test(key)) {
    throw new GatewayError("invalid_request", "Context window preferences require provider/modelId keys");
  }
  return { provider, id };
}

/** Catalog metadata is a configured default, not necessarily the service ceiling.
 * This exact, endpoint-qualified correction is required until the pinned catalog
 * represents both. No family-name inference, remote scraping, or provider aliases.
 * Verified 2026-09-04 against OpenAI's individual model documentation:
 * https://developers.openai.com/api/docs/models/gpt-6-astra
 * https://developers.openai.com/api/docs/models/gpt-5.6-sol
 * https://developers.openai.com/api/docs/models/gpt-5.6-terra
 * https://developers.openai.com/api/docs/models/gpt-5.6-luna
 * Codex uses the same models but account/endpoint acceptance remains provider-owned.
 */
const OPENAI_LONG_CONTEXT_MODELS = new Set(["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]);
function documentedMaximum(model: RuntimeModel): number | undefined {
  if (!OPENAI_LONG_CONTEXT_MODELS.has(model.id)) return undefined;
  if (model.provider === "openai" && model.api === "openai-responses"
    && model.baseUrl.replace(/\/+$/u, "") === "https://api.openai.com/v1") return 1_050_000;
  if (model.provider === "openai-codex" && model.api === "openai-codex-responses"
    && model.baseUrl.replace(/\/+$/u, "") === "https://chatgpt.com/backend-api") return 1_050_000;
  return undefined;
}

export function contextWindowMinimum(compaction: CompactionBudget = DEFAULT_COMPACTION): number {
  if (![compaction.reserveTokens, compaction.keepRecentTokens].every(value => Number.isSafeInteger(value) && value >= 0 && value <= MAX_CONTEXT_TOKENS)) {
    throw new GatewayError("conflict", "Compaction settings do not declare valid context headroom");
  }
  return Math.max(1_024, compaction.reserveTokens + compaction.keepRecentTokens + 1_024);
}

export function contextWindowLimits(model: RuntimeModel, compaction: CompactionBudget = DEFAULT_COMPACTION): ContextWindowLimits | undefined {
  if (!Number.isSafeInteger(model.contextWindow) || model.contextWindow <= 0 || model.contextWindow > MAX_CONTEXT_TOKENS) return undefined;
  const maximum = documentedMaximum(model) ?? model.contextWindow;
  // Keep room for both the retained tail and a response. Existing tiny custom
  // models remain usable at their declared window rather than inventing capacity.
  const minimum = Math.min(maximum, contextWindowMinimum(compaction));
  const threshold = model.cost.tiers?.map(tier => tier.inputTokensAbove)
    .filter(value => Number.isSafeInteger(value) && value > 0 && value < maximum).sort((a, b) => a - b)[0];
  return {
    minimum, maximum, default: Math.max(minimum, Math.min(model.contextWindow, maximum)),
    ...(threshold === undefined ? {} : { longContextThreshold: threshold }),
  };
}

/** This first-party preference lives in canonical SDK settings, not a second store.
 * Return a fresh bounded projection; never mutate the SDK's settings snapshot. */
export function contextWindowPreferences(document: object, maximumEntries = MAX_CONTEXT_PREFERENCES): Record<string, number> {
  const raw = (document as Record<string, unknown>).modelContextWindows;
  if (raw === undefined) return {};
  if (!raw || typeof raw !== "object" || Array.isArray(raw) || Object.keys(raw).length > maximumEntries) {
    throw new GatewayError("conflict", "Canonical model context preferences must be a bounded object");
  }
  const result: Record<string, number> = {};
  for (const [key, value] of Object.entries(raw)) {
    parseContextModelKey(key);
    if (!Number.isSafeInteger(value) || typeof value !== "number" || value <= 0 || value > MAX_CONTEXT_TOKENS) {
      throw new GatewayError("conflict", "Canonical model context preferences contain an invalid token count");
    }
    result[key] = value;
  }
  return result;
}

export function validateContextWindow(value: unknown, limits: ContextWindowLimits | undefined): number {
  if (!limits) throw new GatewayError("conflict", "This model does not declare a configurable context window");
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < limits.minimum || value > limits.maximum) {
    throw new GatewayError("invalid_request", `Context window must be a whole number between ${limits.minimum} and ${limits.maximum} tokens`);
  }
  return value;
}

interface ContextEntry { version: 1; provider: string; modelId: string; contextWindow: number | null }

/** One policy per live SDK session. The catalog stays unchanged; only the selected
 * model copy carries the effective budget. Session overrides are branch-local
 * custom entries and never become messages or independent Gateway session state. */
export class SessionContextWindowPolicy {
  private readonly lookup: ModelRuntime["getModel"];
  private readonly overrides = new Map<string, number>();
  private global: Record<string, number> = {};
  private project: Record<string, number> = {};

  constructor(private readonly session: AgentSession) {
    this.lookup = session.modelRuntime.getModel.bind(session.modelRuntime);
    // Provider registration refreshes the selected model from this public lookup
    // without emitting model_select. Keep that SDK path subject to the same policy.
    session.modelRuntime.getModel = ((provider: string, id: string) => {
      const model = this.lookup(provider, id);
      return model ? this.modelWithBudget(model) : model;
    }) as ModelRuntime["getModel"];
    this.restore();
  }

  restore(): void {
    const settings = this.session.settingsManager;
    const global = contextWindowPreferences(settings.getGlobalSettings());
    const project = settings.isProjectTrusted() ? contextWindowPreferences(settings.getProjectSettings()) : {};
    const overrides = new Map<string, number>();
    for (const entry of this.session.sessionManager.getBranch()) {
      if (entry.type !== "custom" || entry.customType !== CONTEXT_WINDOW_ENTRY) continue;
      const value = entry.data as Partial<ContextEntry> | null;
      if (!value || value.version !== 1 || typeof value.provider !== "string" || typeof value.modelId !== "string"
        || (value.contextWindow !== null && (typeof value.contextWindow !== "number"
          || !Number.isSafeInteger(value.contextWindow) || value.contextWindow <= 0 || value.contextWindow > MAX_CONTEXT_TOKENS))) {
        throw new GatewayError("conflict", "Canonical session context preference is invalid");
      }
      const key = contextModelKey({ provider: value.provider, id: value.modelId });
      const identity = parseContextModelKey(key);
      if (identity.provider !== value.provider || identity.id !== value.modelId) throw new GatewayError("conflict", "Canonical session context model identity is ambiguous");
      if (value.contextWindow === null) overrides.delete(key);
      else overrides.set(key, value.contextWindow);
      if (overrides.size > MAX_CONTEXT_PREFERENCES) throw new GatewayError("conflict", "Too many session context preferences");
    }
    this.global = global;
    this.project = project;
    this.overrides.clear();
    for (const [key, value] of overrides) this.overrides.set(key, value);
    this.apply();
  }

  private resolve(model: RuntimeModel, override = this.overrides.get(contextModelKey(model)) ?? null): ContextWindowPolicy | undefined {
    const limits = contextWindowLimits(model, this.session.settingsManager.getCompactionSettings());
    if (!limits) return undefined;
    const key = contextModelKey(model);
    const global = this.global[key];
    const project = this.project[key];
    const configured = project ?? global ?? model.contextWindow;
    const defaultWindow = Math.max(limits.minimum, Math.min(limits.maximum, configured));
    const requested = override ?? configured;
    const effective = Math.max(limits.minimum, Math.min(limits.maximum, requested));
    const warnings: string[] = [];
    if (effective !== requested || defaultWindow !== configured) warnings.push("Saved context preference was bounded to the model's current capacity and compaction headroom.");
    if (limits.longContextThreshold !== undefined && effective > limits.longContextThreshold) {
      warnings.push("Long-context requests may use higher pricing or subscription allowances; endpoint availability is provider-controlled.");
    }
    return {
      model: { provider: model.provider, id: model.id }, minimum: limits.minimum, maximum: limits.maximum,
      default: defaultWindow, effective, override,
      source: override !== null ? "session" : project !== undefined ? "project" : global !== undefined ? "global" : "model",
      ...(warnings.length ? { warning: warnings.join(" ") } : {}),
    };
  }

  private modelWithBudget(model: RuntimeModel): RuntimeModel {
    const state = this.resolve(model);
    return state && state.effective !== model.contextWindow ? { ...model, contextWindow: state.effective } : model;
  }

  apply(): void {
    const selected = this.session.model;
    if (!selected) return;
    const model = this.lookup(selected.provider, selected.id);
    if (model) this.session.agent.state.model = this.modelWithBudget(model);
  }

  snapshot(): ContextWindowPolicy | undefined {
    const selected = this.session.model;
    const model = selected && this.lookup(selected.provider, selected.id);
    const state = model && this.resolve(model);
    // Projection must never claim a changed catalog budget is already applied.
    if (!state || !selected) return undefined;
    const warnings = [state.warning];
    const file = this.session.sessionManager.getSessionFile();
    if (state.override !== null && file && !existsSync(file)) {
      warnings.push("This new session and its context override are not yet saved to disk; they persist after the first assistant response.");
    }
    if (state.effective !== selected.contextWindow) {
      warnings.push("Model metadata changed; the current bounds will apply on the next turn.");
    }
    return { ...state, effective: selected.contextWindow,
      ...(warnings.some(Boolean) ? { warning: warnings.filter(Boolean).join(" ") } : {}) };
  }

  set(model: ModelRef, raw: unknown): void {
    const selected = this.session.model;
    if (!selected || selected.provider !== model.provider || selected.id !== model.id) {
      throw new GatewayError("conflict", "Session model changed; refresh before changing its context window");
    }
    const base = this.lookup(model.provider, model.id);
    if (!base) throw new GatewayError("not_found", "Model is no longer registered in Tron");
    const value = raw === null ? null : validateContextWindow(raw, contextWindowLimits(base, this.session.settingsManager.getCompactionSettings()));
    const next = this.resolve(base, value);
    if (!next) throw new GatewayError("conflict", "This model does not declare a configurable context window");
    const used = this.session.getContextUsage()?.tokens ?? this.session.messages.reduce((sum, message) => sum + estimateTokens(message), 0);
    const reserve = this.session.settingsManager.getCompactionSettings().reserveTokens;
    if (next.effective < selected.contextWindow && used + reserve >= next.effective) {
      throw new GatewayError("conflict", "Compact the session before reducing its context window below current usage plus response headroom");
    }
    const key = contextModelKey(model);
    // Every new command records its desired value, including an apparent no-op:
    // an earlier failed SDK append may have staged that value only in memory.
    if (value !== null && !this.overrides.has(key) && this.overrides.size >= MAX_CONTEXT_PREFERENCES) throw new GatewayError("conflict", "Too many session context preferences");
    const entry: ContextEntry = { version: 1, provider: model.provider, modelId: model.id, contextWindow: value };
    // The SDK stages an entry in memory before its synchronous disk append.
    // Brand-new sessions retain its documented first-assistant persistence.
    const previousLeaf = this.session.sessionManager.getLeafId();
    try {
      this.session.sessionManager.appendCustomEntry(CONTEXT_WINDOW_ENTRY, entry);
    } catch (error) {
      const staged = this.session.sessionManager.getLeafEntry();
      if (staged?.id !== previousLeaf && staged?.type === "custom" && staged.customType === CONTEXT_WINDOW_ENTRY
        && JSON.stringify(staged.data) === JSON.stringify(entry)) {
        // Do not invent a rollback of Pi's canonical in-memory branch. Report
        // uncertain durability so the command receipt prevents blind replay.
        this.restore();
        throw new GatewayError("conflict", "Context preference entered the runtime but could not be persisted; refresh session state before retrying", false, { outcomeUnknown: true });
      }
      throw error;
    }
    if (value === null) this.overrides.delete(key);
    else this.overrides.set(key, value);
    this.apply();
  }
}

/** Hook the owner, not SDK private lifecycle fields. Factories survive resource
 * reload; each replacement session receives a distinct policy closure. */
export function contextWindowExtension(policy: () => SessionContextWindowPolicy | undefined): ExtensionFactory {
  return pi => {
    pi.on("session_start", () => { policy()?.restore(); });
    pi.on("session_tree", () => { policy()?.restore(); });
    pi.on("model_select", () => { policy()?.apply(); });
    pi.on("before_agent_start", () => { policy()?.apply(); });
    pi.on("turn_start", () => { policy()?.apply(); });
  };
}
