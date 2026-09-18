import { clampThinkingLevel, type AssistantMessage, type Context } from "@earendil-works/pi-ai";
import type { StreamFn } from "@earendil-works/pi-agent-core";
import { SettingsManager, type AgentSession, type ExtensionFactory, type SessionBeforeCompactEvent } from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import type { CompactionConfiguration, CompactionPolicyProjection, ResolvedCompactionConfiguration } from "../protocol/types.js";

export const COMPACTION_POLICY_INSTRUCTION_LIMIT = 4_000;
export const COMPACTION_THINKING_LEVELS = ["inherit", "off", "minimal", "low", "medium", "high", "xhigh", "max"] as const;
export type CompactionThinkingLevel = typeof COMPACTION_THINKING_LEVELS[number];
const DEFAULTS = { enabled: true, reserveTokens: 16_384, keepRecentTokens: 20_000, thinkingLevel: "inherit", instructions: "" } as const;

function document(value: unknown): Record<string, unknown> {
  if (value === undefined) return {};
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new GatewayError("conflict", "Canonical compaction settings must be an object");
  return value as Record<string, unknown>;
}

/** Missing project fields inherit. Explicit inherit/empty restore standard
 * generation even when the global scope has a custom policy. */
export function resolveCompactionPolicy(global: Record<string, unknown>, project: Record<string, unknown> = {}, trusted = false): CompactionConfiguration {
  const scopes = { global: document(global.compaction), project: trusted ? document(project.compaction) : {} };
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

export function settingsCompactionPolicy(settings: SettingsManager): CompactionConfiguration {
  return resolveCompactionPolicy(settings.getGlobalSettings() as Record<string, unknown>, settings.getProjectSettings() as Record<string, unknown>, settings.isProjectTrusted());
}

/** One disposable operation projection per SDK session, not a second settings
 * store. Canonical reads are limited to settings/operation boundaries. Only the
 * three SDK compaction controls are applied, never a broad resource/settings reload. */
export class CompactionOperationPolicy {
  private next: CompactionConfiguration;
  private budgetSources: Pick<CompactionConfiguration["source"], "enabled" | "reserveTokens" | "keepRecentTokens">;
  private active: { signal: AbortSignal; configuration: ResolvedCompactionConfiguration; reason: SessionBeforeCompactEvent["reason"] } | undefined;
  private warning: string | undefined;

  constructor(private readonly session: AgentSession, private readonly agentDir: string) {
    this.next = settingsCompactionPolicy(session.settingsManager);
    this.budgetSources = { enabled: this.next.source.enabled, reserveTokens: this.next.source.reserveTokens, keepRecentTokens: this.next.source.keepRecentTokens };
    this.refresh();
    // Installed before RuntimeSlot's subscriber: an end snapshot cannot retain
    // policy authority from the completed operation, including failed attempts.
    session.subscribe(event => { if (event.type === "compaction_end") this.active = undefined; });
  }

  restore(): void {
    try {
      const source = settingsCompactionPolicy(this.session.settingsManager).source;
      this.budgetSources = { enabled: source.enabled, reserveTokens: source.reserveTokens, keepRecentTokens: source.keepRecentTokens };
      this.refresh();
    } catch {
      this.warning ??= "Canonical compaction settings are invalid. The last valid configuration remains in use.";
    }
  }

  refresh(): void {
    const settings = SettingsManager.create(this.session.sessionManager.getCwd(), this.agentDir, { projectTrusted: this.session.settingsManager.isProjectTrusted() });
    if (settings.drainErrors().length) {
      this.warning = "Canonical compaction settings could not be loaded. The last valid configuration remains in use.";
      throw new GatewayError("conflict", this.warning);
    }
    try {
      this.next = settingsCompactionPolicy(settings);
      this.warning = undefined;
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
    this.session.settingsManager.applyOverrides({ compaction: { enabled, reserveTokens, keepRecentTokens } });
    this.budgetSources = { enabled: this.next.source.enabled, reserveTokens: this.next.source.reserveTokens, keepRecentTokens: this.next.source.keepRecentTokens };
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
    const model = this.session.model;
    const requestedThinkingLevel = configuration.thinkingLevel === "inherit" ? this.session.thinkingLevel : configuration.thinkingLevel;
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
      const requestContext: Context = captured.instructions ? {
        ...context,
        systemPrompt: `${context.systemPrompt ?? ""}\n\nUser-configured summary focus:\n${captured.instructions}`,
      } : context;
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
