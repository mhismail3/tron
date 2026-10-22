import type { CompactionPolicyLifecycle, ModuleDescriptor } from "../host/module-host.js";
import { clampThinkingLevel, normalizeContext, type AssistantMessage } from "../pi/ai.js";
import type { StreamFn } from "../pi/agent-core.js";
import { SettingsManager, type AgentSession, type ExtensionFactory, type SessionBeforeCompactEvent } from "../pi/coding-agent.js";
import { GatewayError } from "../../errors.js";
import type { CompactionConfiguration, CompactionPolicyProjection, ResolvedCompactionConfiguration } from "../../protocol/types.js";

export const COMPACTION_POLICY_INSTRUCTION_LIMIT = 4_000;
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
  private readonly explicitSettings: (() => Record<string, unknown>) | undefined;

  constructor(
    private readonly session: AgentSession,
    private readonly agentDir: string,
    private readonly resolvePolicy: (settings: SettingsManager, session: Record<string, unknown>, model?: string) => CompactionConfiguration,
    /** Tron Home keeps its own history: SDK compaction is disabled for this
     * session only, through the same per-session overlay `applyBudgets`
     * reapplies from canonical settings at every idle admission. */
    options: { disabled?: boolean; session?: () => Record<string, unknown> } = {},
  ) {
    this.disabled = options.disabled === true;
    this.explicitSettings = options.session;
    this.next = this.resolvePolicy(session.settingsManager, this.guardedChatSettings(), this.modelKey());
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
      const source = this.resolvePolicy(this.session.settingsManager, this.guardedChatSettings(), this.modelKey()).source;
      this.budgetSources = { enabled: source.enabled, reserveTokens: source.reserveTokens, keepRecentTokens: source.keepRecentTokens };
      this.refresh();
    } catch {
      this.warning ??= "Canonical compaction settings are invalid. The last valid configuration remains in use.";
    }
  }

  /** This chat's explicit Session scope (`tron.settings.v1`), supplied by its
   * RuntimeSlot: branch-local like every Session value, so fork and resume follow
   * Pi's canonical branch. */
  private chatSettings(): Record<string, unknown> {
    return this.explicitSettings?.() ?? {};
  }

  /** A damaged Chat entry never fails construction or a refresh: the Project and
   * Global policy applies and the published warning says so until a valid read. */
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
      this.next = this.resolvePolicy(settings, this.guardedChatSettings(), this.modelKey());
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
function oversizedRequestOverflow(message: AssistantMessage): AssistantMessage | undefined {
  if (message.stopReason !== "error") return undefined;
  const errorMessage = message.errorMessage ?? "";
  if (!OVERSIZED_REQUEST.test(errorMessage) || CONTEXT_OVERFLOW_PHRASE.test(errorMessage)) return undefined;
  return { ...message, errorMessage: `context_length_exceeded: ${errorMessage}` };
}

// Pi surfaces provider failures as `${status}: ${body}` (pi-ai's
// formatProviderError); some transports keep the RFC reason phrase instead.
const OVERSIZED_REQUEST = /^413(?::| (?:Request Entity Too Large|Content Too Large)\b)/u;
const CONTEXT_OVERFLOW_PHRASE = /context[_ ]length[_ ]exceeded/iu;

export const compactionPolicyModule: ModuleDescriptor = {
  name: "tron-compaction-policy",
  purpose: "Applies Tron's compaction policy and cancels the compaction a stop aborted.",
  tools: [],
  commands: [],
  start: () => ({ extension: (session) => compactionPolicyExtension(
    () => session.compaction.policy(),
    (event) => session.compaction.stopped(event),
    () => session.compaction.changed(),
  ) }),
};

export function compactionPolicyExtension(policy: () => CompactionPolicyLifecycle | undefined, stopped: (event: SessionBeforeCompactEvent) => boolean, changed: () => void): ExtensionFactory {
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
