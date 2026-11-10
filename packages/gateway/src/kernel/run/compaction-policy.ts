import type { CompactionPolicyLifecycle, ModuleDescriptor } from "../host/module-host.js";
import { clampThinkingLevel, normalizeContext, type AssistantMessage } from "../pi/ai.js";
import type { StreamFn } from "../pi/agent-core.js";
import { SettingsManager, type AgentSession, type ExtensionFactory, type SessionBeforeCompactEvent } from "../pi/coding-agent.js";
import { GatewayError } from "../../errors.js";
import type { CompactionConfiguration, CompactionPolicyProjection, ResolvedCompactionConfiguration } from "../../protocol/types.js";

export const COMPACTION_POLICY_INSTRUCTION_LIMIT = 4_000;
export class CompactionOperationPolicy {
  private next: CompactionConfiguration;
  private budgetSources: Pick<CompactionConfiguration["source"], "enabled" | "reserveTokens" | "keepRecentTokens">;
  private active: { signal: AbortSignal; configuration: ResolvedCompactionConfiguration; reason: SessionBeforeCompactEvent["reason"] } | undefined;
  private warning: string | undefined;
  private readonly disabled: boolean;
  private readonly explicitSettings: (() => Record<string, unknown>) | undefined;

  constructor(
    private readonly session: AgentSession,
    private readonly agentDir: string,
    private readonly resolvePolicy: (settings: SettingsManager, session: Record<string, unknown>, model?: string) => CompactionConfiguration,
    options: { disabled?: boolean; session?: () => Record<string, unknown> } = {},
  ) {
    this.disabled = options.disabled === true;
    this.explicitSettings = options.session;
    this.next = this.resolvePolicy(session.settingsManager, this.guardedChatSettings(), this.modelKey());
    this.budgetSources = { enabled: this.next.source.enabled, reserveTokens: this.next.source.reserveTokens, keepRecentTokens: this.next.source.keepRecentTokens };
    this.refresh();
    if (this.disabled) this.applyBudgets();
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

  private chatSettings(): Record<string, unknown> {
    return this.explicitSettings?.() ?? {};
  }

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

  applyBudgets(): void {
    this.refresh();
    const { enabled, reserveTokens, keepRecentTokens } = this.next;
    const model = this.modelKey();
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
    try { this.refresh(); } catch { }
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
      extensionMayOverride: this.session.resourceLoader.getExtensions().extensions.some(extension =>
        extension.path !== "<inline:tron-compaction-policy>" && (extension.handlers.get("session_before_compact")?.length ?? 0) > 0),
      ...(this.warning ? { warning: this.warning } : {}),
    };
  }

  wrap(stream: StreamFn): StreamFn {
    return (model, context, options) => {
      const captured = this.active?.signal === options?.signal ? this.active?.configuration : undefined;
      if (!captured) return stream(model, context, options);
      if (model.id !== captured.model?.id || model.provider !== captured.model.provider) return stream(model, context, options);
      let requestOptions = options;
      if (captured.thinkingLevel !== "inherit") {
        requestOptions = { ...options };
        const level = clampThinkingLevel(model, captured.requestedThinkingLevel);
        if (level === "off") delete requestOptions.reasoning;
        else requestOptions.reasoning = level;
      }
      if (!captured.instructions) return stream(model, context, requestOptions);
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

function oversizedRequestOverflow(message: AssistantMessage): AssistantMessage | undefined {
  if (message.stopReason !== "error") return undefined;
  const errorMessage = message.errorMessage ?? "";
  if (!OVERSIZED_REQUEST.test(errorMessage) || CONTEXT_OVERFLOW_PHRASE.test(errorMessage)) return undefined;
  return { ...message, errorMessage: `context_length_exceeded: ${errorMessage}` };
}

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
