import { clampThinkingLevel, normalizeContext, type AssistantMessage } from "@earendil-works/pi-ai";
import type { StreamFn } from "@earendil-works/pi-agent-core";
import { SettingsManager, type AgentSession, type ExtensionFactory, type SessionBeforeCompactEvent } from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import type { CompactionConfiguration, CompactionPolicyProjection, ResolvedCompactionConfiguration } from "../protocol/types.js";

export const COMPACTION_POLICY_INSTRUCTION_LIMIT = 4_000;
export const COMPACTION_THINKING_LEVELS = ["inherit", "off", "minimal", "low", "medium", "high", "xhigh", "max"] as const;
type CompactionThinkingLevel = typeof COMPACTION_THINKING_LEVELS[number];
const DEFAULTS = { enabled: true, reserveTokens: 16_384, keepRecentTokens: 20_000, thinkingLevel: "inherit", instructions: "" } as const;

function document(value: unknown): Record<string, unknown> {
  if (value === undefined) return {};
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new GatewayError("conflict", "Canonical compaction settings must be an object");
  return value as Record<string, unknown>;
}

/** Missing project fields inherit. Explicit inherit/empty restore standard
 * generation even when the global scope has a custom policy. */
function resolveCompactionPolicy(global: Record<string, unknown>, project: Record<string, unknown> = {}, trusted = false, model?: string): CompactionConfiguration {
  const scope = (settings: Record<string, unknown>) => {
    const plain = document(settings.compaction);
    const qualified = model ? document(document(plain.modelOverrides)[model]) : {};
    // Only these two budgets have declared model-qualified bindings.
    return { ...plain, ...Object.fromEntries(["reserveTokens", "keepRecentTokens"].flatMap(key => qualified[key] === undefined ? [] : [[key, qualified[key]]])) };
  };
  const scopes = { global: scope(global), project: trusted ? scope(project) : {} };
  const source = {} as CompactionConfiguration["source"];
  const result: Record<string, unknown> = {};
  for (const key of Object.keys(DEFAULTS) as Array<keyof typeof DEFAULTS>) {
    source[key] = scopes.project[key] !== undefined ? "project" : scopes.global[key] !== undefined ? "global" : "default";
    result[key] = scopes.project[key] ?? scopes.global[key] ?? DEFAULTS[key];
  }
  if (typeof result.enabled !== "boolean"
    || !Number.isSafeInteger(result.reserveTokens) || (result.reserveTokens as number) < 1_024 || (result.reserveTokens as number) > 1_000_000
    || !Number.isSafeInteger(result.keepRecentTokens) || (result.keepRecentTokens as number) < 0 || (result.keepRecentTokens as number) > 1_000_000
    || !COMPACTION_THINKING_LEVELS.includes(result.thinkingLevel as CompactionThinkingLevel)
    || typeof result.instructions !== "string" || result.instructions.length > COMPACTION_POLICY_INSTRUCTION_LIMIT) {
    throw new GatewayError("conflict", "Canonical compaction settings contain an invalid value");
  }
  // Null is a patch deletion, never a canonical policy value.
  if (Object.values(scopes).some(scope => Object.keys(DEFAULTS).some(key => scope[key] === null))) {
    throw new GatewayError("conflict", "Canonical compaction settings contain an invalid null");
  }
  return { ...result, source } as unknown as CompactionConfiguration;
}

/** The Chat-layer compaction values this policy honours (decision 9). The
 * summarizer's thinking level stays Project/Mac (`model.thinking[role=summarizer]`). */
const CHAT_FIELDS = ["enabled", "reserveTokens", "keepRecentTokens", "instructions"] as const;

function settingsCompactionPolicy(settings: SettingsManager, chat: Record<string, unknown> = {}, model?: string): CompactionConfiguration {
  const resolved = resolveCompactionPolicy(settings.getGlobalSettings() as Record<string, unknown>, settings.getProjectSettings() as Record<string, unknown>, settings.isProjectTrusted(), model);
  const values = document(chat.compaction);
  const result: CompactionConfiguration = { ...resolved, source: { ...resolved.source } };
  // Chat values were validated by the schema when written; the shared
  // validation below refuses a canonical entry edited out of range.
  for (const field of CHAT_FIELDS) {
    if (values[field] === undefined) continue;
    (result as unknown as Record<string, unknown>)[field] = values[field];
    result.source[field] = "chat";
  }
  if (typeof result.enabled !== "boolean"
    || !Number.isSafeInteger(result.reserveTokens) || result.reserveTokens < 1_024 || result.reserveTokens > 1_000_000
    || !Number.isSafeInteger(result.keepRecentTokens) || result.keepRecentTokens < 0 || result.keepRecentTokens > 1_000_000
    || typeof result.instructions !== "string" || result.instructions.length > COMPACTION_POLICY_INSTRUCTION_LIMIT) {
    throw new GatewayError("conflict", "Canonical Chat compaction settings contain an invalid value");
  }
  return result;
}

/** One disposable operation projection per SDK session, not a second settings
 * store. Canonical reads are limited to settings/operation boundaries. Only the
 * three SDK compaction controls are applied, never a broad resource/settings reload. */
export class CompactionOperationPolicy {
  private next: CompactionConfiguration;
  private budgetSources: Pick<CompactionConfiguration["source"], "enabled" | "reserveTokens" | "keepRecentTokens">;
  private active: { signal: AbortSignal; configuration: ResolvedCompactionConfiguration; reason: SessionBeforeCompactEvent["reason"] } | undefined;
  private warning: string | undefined;
  /** True only for a Home session. Never read from global settings. */
  private readonly disabled: boolean;
  private readonly chat: (() => Record<string, unknown>) | undefined;

  constructor(
    private readonly session: AgentSession,
    private readonly agentDir: string,
    /** Tron Home keeps its own history: SDK compaction is disabled for this
     * session only, through the same per-session overlay `applyBudgets`
     * reapplies from canonical settings at every idle admission. */
    options: { disabled?: boolean; chat?: () => Record<string, unknown> } = {},
  ) {
    this.disabled = options.disabled === true;
    this.chat = options.chat;
    this.next = settingsCompactionPolicy(session.settingsManager, this.guardedChatSettings(), this.modelKey());
    this.budgetSources = { enabled: this.next.source.enabled, reserveTokens: this.next.source.reserveTokens, keepRecentTokens: this.next.source.keepRecentTokens };
    this.refresh();
    // The override must exist from the session's first admission, not only after
    // the first idle prompt: `applyBudgets` is the only writer of this session's
    // compaction budget, and the SDK's own threshold check reads it directly.
    if (this.disabled) this.applyBudgets();
    // Installed before RuntimeSlot's subscriber: an end snapshot cannot retain
    // policy authority from the completed operation, including failed attempts.
    session.subscribe(event => { if (event.type === "compaction_end") this.active = undefined; });
  }

  restore(): void {
    try {
      const source = settingsCompactionPolicy(this.session.settingsManager, this.guardedChatSettings(), this.modelKey()).source;
      this.budgetSources = { enabled: source.enabled, reserveTokens: source.reserveTokens, keepRecentTokens: source.keepRecentTokens };
      this.refresh();
    } catch {
      this.warning ??= "Canonical compaction settings are invalid. The last valid configuration remains in use.";
    }
  }

  /** This chat's explicit Chat layer (`tron.settings.v1`), supplied by its
   * RuntimeSlot: branch-local like every Chat value, so fork and resume follow
   * Pi's canonical branch. */
  private chatSettings(): Record<string, unknown> {
    return this.chat?.() ?? {};
  }

  /** A damaged Chat entry never fails construction or a refresh: the Project and
   * Mac policy applies and the published warning says so until a valid read. */
  private guardedChatSettings(): Record<string, unknown> {
    try { return this.chatSettings(); } catch {
      this.warning = "Canonical Chat compaction settings are invalid. Project and Mac compaction settings apply.";
      return {};
    }
  }

  refresh(): void {
    const settings = SettingsManager.create(this.session.projectDir, this.agentDir, { projectTrusted: this.session.settingsManager.isProjectTrusted() });
    if (settings.drainErrors().length) {
      this.warning = "Canonical compaction settings could not be loaded. The last valid configuration remains in use.";
      throw new GatewayError("conflict", this.warning);
    }
    try {
      this.warning = undefined;
      this.next = settingsCompactionPolicy(settings, this.guardedChatSettings(), this.modelKey());
    } catch (error) {
      this.warning = "Canonical compaction settings are invalid. The last valid configuration remains in use.";
      throw error;
    }
  }

  /** Called only by idle prompt/manual-compaction admission. A saved budget
   * never changes a prepared split operation or an active agent run. SDK saves
   * may remerge its settings, so reapply from canonical at every such boundary. */
  applyBudgets(): void {
    this.refresh();
    const { enabled, reserveTokens, keepRecentTokens } = this.next;
    const model = this.modelKey();
    // The SDK reads modelOverrides before plain budgets. Pin this operation's
    // already scope-resolved budgets there too, or a lower-scope SDK value could
    // silently override the Session policy at the real threshold/preparation cut.
    this.session.settingsManager.applyOverrides({ compaction: { enabled: this.disabled ? false : enabled, reserveTokens, keepRecentTokens,
      ...(model ? { modelOverrides: { [model]: { reserveTokens, keepRecentTokens } } } : {}),
    } });
    this.budgetSources = { enabled: this.next.source.enabled, reserveTokens: this.next.source.reserveTokens, keepRecentTokens: this.next.source.keepRecentTokens };
  }

  private modelKey(): string | undefined {
    const model = this.session.model;
    return model ? `${model.provider}/${model.id}` : undefined;
  }

  capture(event: SessionBeforeCompactEvent): void {
    // A file edit during a run is not permission to discard the last valid
    // policy. Report the failed refresh in the projection, without throwing
    // into ExtensionRunner's catch-and-fall-through boundary.
    try { this.refresh(); } catch { /* Warning remains visible until a valid read. */ }
    const configuration = this.resolve(this.next);
    this.active = { signal: event.signal, configuration: { ...configuration, ...event.preparation.settings, source: { ...configuration.source, ...this.budgetSources } }, reason: event.reason };
  }

  private resolve(configuration: CompactionConfiguration): ResolvedCompactionConfiguration {
    const selected = this.session.model;
    const model = selected?.api === "pi-virtual" ? this.session.routedModel?.model ?? selected : selected;
    const requestedThinkingLevel = configuration.thinkingLevel === "inherit"
      ? (selected?.api === "pi-virtual" ? this.session.routedModel?.thinkingLevel ?? this.session.thinkingLevel : this.session.thinkingLevel)
      : configuration.thinkingLevel;
    return {
      ...configuration,
      ...(model ? { model: { provider: model.provider, id: model.id } } : {}),
      requestedThinkingLevel,
      effectiveThinkingLevel: model ? clampThinkingLevel(model, requestedThinkingLevel) : null,
    };
  }

  snapshot(): CompactionPolicyProjection {
    const currentBudgets = this.session.settingsManager.getCompactionSettings();
    return {
      next: this.resolve(this.next),
      currentBudgets: { enabled: currentBudgets.enabled, reserveTokens: currentBudgets.reserveTokens, keepRecentTokens: currentBudgets.keepRecentTokens },
      ...(this.active ? { active: { ...this.active.configuration, reason: this.active.reason } } : {}),
      // An observer is not necessarily a generator (subagents observes this
      // event). Never reject loading a project merely for registering a hook.
      extensionMayOverride: this.session.resourceLoader.getExtensions().extensions.some(extension =>
        extension.path !== "<inline:tron-compaction-policy>" && (extension.handlers.get("session_before_compact")?.length ?? 0) > 0),
      ...(this.warning ? { warning: this.warning } : {}),
    };
  }

  wrap(stream: StreamFn): StreamFn {
    return (model, context, options) => {
      const captured = this.active?.signal === options?.signal ? this.active?.configuration : undefined;
      if (!captured) return stream(model, context, options);
      // Signal identity fences the operation. Model identity prevents a custom
      // extension's separate-model request from being relabelled as our policy.
      if (model.id !== captured.model?.id || model.provider !== captured.model.provider) return stream(model, context, options);
      let requestOptions = options;
      if (captured.thinkingLevel !== "inherit") {
        requestOptions = { ...options };
        const level = clampThinkingLevel(model, captured.requestedThinkingLevel);
        if (level === "off") delete requestOptions.reasoning;
        else requestOptions.reasoning = level;
      }
      if (!captured.instructions) return stream(model, context, requestOptions);
      // Preserve transcript system/tool deltas in order; append the compaction-only
      // instruction as a request-local system change rather than flattening history.
      const requestContext = normalizeContext({ messages: [...context.messages] });
      requestContext.messages.push({
        role: "system",
        content: `User-configured summary focus:\n${captured.instructions}`,
        timestamp: Date.now(),
      });
      return stream(model, requestContext, requestOptions);
    };
  }
}

/**
 * Report a provider request-size rejection as the generic overflow Pi already
 * recovers from. A provider that enforces a request-body limit answers with
 * HTTP 413 and an opaque body (for example opencode-go: "server_error",
 * "Upstream response was not valid JSON"), which matches none of pi-ai's
 * overflow patterns. Pi then retries the identical oversized request until it
 * fails permanently, leaving the session unable to continue until it is
 * compacted. Compaction is the correct recovery for a request the provider
 * refuses to accept, so select it with the phrase `isContextOverflow` matches.
 * Provider text is preserved verbatim and the rewrite is idempotent.
 */
export function oversizedRequestOverflow(message: AssistantMessage): AssistantMessage | undefined {
  if (message.stopReason !== "error") return undefined;
  const errorMessage = message.errorMessage ?? "";
  if (!OVERSIZED_REQUEST.test(errorMessage) || CONTEXT_OVERFLOW_PHRASE.test(errorMessage)) return undefined;
  return { ...message, errorMessage: `context_length_exceeded: ${errorMessage}` };
}

// Pi surfaces provider failures as `${status}: ${body}` (pi-ai's
// formatProviderError); some transports keep the RFC reason phrase instead.
const OVERSIZED_REQUEST = /^413(?::| (?:Request Entity Too Large|Content Too Large)\b)/u;
const CONTEXT_OVERFLOW_PHRASE = /context[_ ]length[_ ]exceeded/iu;

export function compactionPolicyExtension(policy: () => CompactionOperationPolicy | undefined, stopped: (event: SessionBeforeCompactEvent) => boolean, changed: () => void): ExtensionFactory {
  return pi => {
    pi.on("message_end", (event) => {
      if (event.message.role !== "assistant") return;
      const recovered = oversizedRequestOverflow(event.message);
      return recovered ? { message: recovered } : undefined;
    });
    pi.on("session_start", () => { policy()?.restore(); });
    pi.on("session_before_compact", (event) => {
      if (stopped(event)) return { cancel: true };
      policy()?.capture(event);
      changed();
    });
  };
}
