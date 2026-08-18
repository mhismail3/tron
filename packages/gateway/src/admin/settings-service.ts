import { join } from "node:path";
import { SettingsManager, type ModelRuntime } from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { updateJsonLocked } from "../util/json.js";
import { arrayOfStrings, boolean, integer, object, oneOf, string } from "../util/validation.js";

interface SettingsDocument extends Record<string, unknown> {}
type SettingsScope = "global" | "project";

const thinkingLevels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"] as const;
const SETTINGS_DOCUMENT_BYTES = 256 * 1_024;
const SETTINGS_DOCUMENT_NODES = 15_000;
const SETTINGS_DOCUMENT_OBJECT_DEPTH = 11;
export const SETTINGS_PROJECTION_BYTES = 800 * 1_024;
const SETTINGS_MAX_NODES = 32_768;
const SETTINGS_MAX_COLLECTION_MEMBERS = 1_000;
const SETTINGS_MAX_STRING_CHARACTERS = 100_000;
const SETTINGS_MAX_OBJECT_DEPTH = 12;

function assertUntruncatedSettingsJson(
  value: unknown,
  label: string,
  maximumBytes: number,
  maximumNodes = SETTINGS_MAX_NODES,
  maximumObjectDepth = SETTINGS_MAX_OBJECT_DEPTH,
): void {
  const pending: Array<{ value: unknown; depth: number }> = [{ value, depth: 0 }];
  const seen = new WeakSet<object>();
  let nodes = 0;
  while (pending.length > 0) {
    const current = pending.pop()!;
    nodes += 1;
    if (nodes > maximumNodes) throw new GatewayError("conflict", `${label} exceeds its node limit`);
    if (current.value === null || current.value === undefined || typeof current.value === "boolean") continue;
    if (typeof current.value === "string") {
      if (current.value.length > SETTINGS_MAX_STRING_CHARACTERS) {
        throw new GatewayError("conflict", `${label} exceeds its string limit`);
      }
      continue;
    }
    if (typeof current.value === "number") {
      if (!Number.isFinite(current.value)) throw new GatewayError("conflict", `${label} contains a non-finite number`);
      continue;
    }
    if (typeof current.value !== "object") throw new GatewayError("conflict", `${label} contains non-JSON data`);
    if (current.depth >= maximumObjectDepth) throw new GatewayError("conflict", `${label} exceeds its depth limit`);
    if (seen.has(current.value)) throw new GatewayError("conflict", `${label} contains repeated object ownership`);
    seen.add(current.value);
    const values = Array.isArray(current.value) ? current.value : Object.values(current.value);
    if (values.length > SETTINGS_MAX_COLLECTION_MEMBERS) {
      throw new GatewayError("conflict", `${label} exceeds its collection limit`);
    }
    for (const child of values) pending.push({ value: child, depth: current.depth + 1 });
  }
  const encoded = JSON.stringify(value, (_key, item) => item === undefined ? null : item);
  if (encoded === undefined || Buffer.byteLength(encoded) > maximumBytes) {
    throw new GatewayError("conflict", `${label} exceeds its encoded byte limit`);
  }
}

function merge(base: Record<string, unknown>, override: Record<string, unknown>): Record<string, unknown> {
  const result = structuredClone(base);
  for (const [key, value] of Object.entries(override)) {
    if (value && typeof value === "object" && !Array.isArray(value) && result[key] && typeof result[key] === "object" && !Array.isArray(result[key])) {
      result[key] = merge(result[key] as Record<string, unknown>, value as Record<string, unknown>);
    } else {
      result[key] = structuredClone(value);
    }
  }
  return result;
}

function nullableString(value: unknown, name: string, maximum: number): string | null {
  return value === null ? null : string(value, name, { max: maximum });
}

function rawString(value: unknown, name: string, maximum: number): string {
  if (typeof value !== "string" || value.length > maximum) {
    throw new GatewayError("invalid_request", `${name} must be a string no longer than ${maximum} characters`);
  }
  return value;
}

function redactSettingsDocument(document: Record<string, unknown>): Record<string, unknown> {
  const redacted = structuredClone(document);
  delete redacted.httpProxy;
  return redacted;
}

function setNullable(target: SettingsDocument, key: string, value: unknown): void {
  if (value === null || value === undefined) delete target[key];
  else target[key] = value;
}

function validatePackageSource(value: unknown, name: string): unknown {
  if (typeof value === "string") return string(value, name, { max: 2_000 });
  const packageValue = object(value, name);
  const result: Record<string, unknown> = { source: string(packageValue.source, `${name}.source`, { max: 2_000 }) };
  if (packageValue.autoload !== undefined) result.autoload = boolean(packageValue.autoload, `${name}.autoload`);
  for (const key of ["extensions", "skills", "prompts", "themes"] as const) {
    if (packageValue[key] !== undefined) result[key] = arrayOfStrings(packageValue[key], `${name}.${key}`, 500);
  }
  return result;
}

/** Canonical Pi settings projection with explicit global/project ownership. */
export class SettingsService {
  private readonly mutation = new AsyncMutex();

  constructor(
    private readonly agentDir: string,
    private readonly modelRuntime: ModelRuntime,
  ) {}

  get(cwd: string, projectTrusted = false): Record<string, unknown> {
    // SettingsManager keeps its initially merged snapshot even when the trust
    // flag is false. Use an agent-dir-bound manager for a truly global-only
    // projection and a cwd-bound manager only after project trust resolves.
    const manager = SettingsManager.create(projectTrusted ? cwd : this.agentDir, this.agentDir, { projectTrusted });
    const global = manager.getGlobalSettings() as Record<string, unknown>;
    const project = projectTrusted ? manager.getProjectSettings() as Record<string, unknown> : {};
    const effective = merge(global, project);
    const defaultProvider = manager.getDefaultProvider();
    const defaultModel = manager.getDefaultModel();
    const rawRetry = manager.getRetrySettings();
    const result = {
      scope: { cwd, projectTrusted },
      documents: {
        global: redactSettingsDocument(global),
        project: projectTrusted ? redactSettingsDocument(project) : null,
      },
      effective: {
        defaultModel: defaultProvider && defaultModel ? { provider: defaultProvider, id: defaultModel } : null,
        defaultThinkingLevel: manager.getDefaultThinkingLevel() ?? null,
        thinkingBudgets: manager.getThinkingBudgets() ?? null,
        transport: manager.getTransport(),
        compaction: manager.getCompactionSettings(),
        branchSummary: manager.getBranchSummarySettings(),
        retry: { ...rawRetry, provider: manager.getProviderRetrySettings() },
        httpIdleTimeoutMs: manager.getHttpIdleTimeoutMs(),
        websocketConnectTimeoutMs: manager.getWebSocketConnectTimeoutMs() ?? null,
        steeringMode: manager.getSteeringMode(),
        followUpMode: manager.getFollowUpMode(),
        hideThinkingBlock: manager.getHideThinkingBlock(),
        showCacheMissNotices: manager.getShowCacheMissNotices(),
        defaultProjectTrust: manager.getDefaultProjectTrust(),
        images: { autoResize: manager.getImageAutoResize(), blockImages: manager.getBlockImages() },
        enabledModels: manager.getEnabledModels() ?? null,
        enableSkillCommands: manager.getEnableSkillCommands(),
        shellPath: manager.getShellPath() ?? null,
        shellCommandPrefix: manager.getShellCommandPrefix() ?? null,
        npmCommand: manager.getNpmCommand() ?? null,
        sessionDir: manager.getSessionDir() ?? null,
        resources: {
          extensions: manager.getExtensionPaths(),
          skills: manager.getSkillPaths(),
          prompts: manager.getPromptTemplatePaths(),
          themes: manager.getThemePaths(),
          packages: manager.getPackages(),
        },
        markdown: {
          codeBlockIndent: manager.getCodeBlockIndent(),
          mermaid: manager.getMermaidRenderingMode(),
        },
        warnings: manager.getWarnings(),
        telemetry: {
          install: manager.getEnableInstallTelemetry(),
          analytics: manager.getEnableAnalytics(),
        },
        httpProxyConfigured: typeof effective.httpProxy === "string" && effective.httpProxy.length > 0,
        terminalOnly: {
          theme: manager.getThemeSetting() ?? null,
          tuiMode: manager.getTuiMode(),
          fullscreenScrollbar: manager.getFullscreenScrollbar(),
          externalEditor: manager.getExternalEditorCommand(),
          showImages: manager.getShowImages(),
          imageWidthCells: manager.getImageWidthCells(),
          clearOnShrink: manager.getClearOnShrink(),
          showTerminalProgress: manager.getShowTerminalProgress(),
          showHardwareCursor: manager.getShowHardwareCursor(),
          editorPaddingX: manager.getEditorPaddingX(),
          outputPad: manager.getOutputPad(),
          autocompleteMaxVisible: manager.getAutocompleteMaxVisible(),
          doubleEscapeAction: manager.getDoubleEscapeAction(),
          treeFilterMode: manager.getTreeFilterMode(),
        },
      },
    };
    assertUntruncatedSettingsJson(result, "Settings projection", SETTINGS_PROJECTION_BYTES);
    return result;
  }

  async update(raw: unknown, options: { cwd: string; scope: SettingsScope; projectTrusted: boolean }): Promise<Record<string, unknown>> {
    return this.mutation.run(() => this.updateLocked(raw, options));
  }

  private async updateLocked(raw: unknown, options: { cwd: string; scope: SettingsScope; projectTrusted: boolean }): Promise<Record<string, unknown>> {
    if (options.scope === "project" && !options.projectTrusted) {
      throw new GatewayError("trust_required", "Trust this project before changing its project settings");
    }
    const patch = object(raw, "settings patch");
    const path = options.scope === "global"
      ? join(this.agentDir, "settings.json")
      : join(options.cwd, ".pi", "settings.json");
    const global = options.scope === "project"
      ? SettingsManager.create(options.cwd, this.agentDir, { projectTrusted: true }).getGlobalSettings() as Record<string, unknown>
      : undefined;
    await updateJsonLocked<SettingsDocument>(path, {}, (current) => {
      const next = this.applyPatch(current, patch);
      // The response retains these documents once and derives at most another
      // document's worth of effective values. This conservative admission leaves
      // response byte/node/depth headroom before the canonical write commits.
      assertUntruncatedSettingsJson(
        global === undefined ? { global: next } : { global, project: next },
        "Settings documents",
        SETTINGS_DOCUMENT_BYTES,
        SETTINGS_DOCUMENT_NODES,
        SETTINGS_DOCUMENT_OBJECT_DEPTH,
      );
      return next;
    });
    return this.get(options.cwd, options.scope === "project" && options.projectTrusted);
  }

  private applyPatch(current: SettingsDocument, patch: Record<string, unknown>): SettingsDocument {
    const next: SettingsDocument = structuredClone(current);
    if ("defaultModel" in patch) {
      if (patch.defaultModel === null) {
        delete next.defaultProvider;
        delete next.defaultModel;
      } else {
        const model = object(patch.defaultModel, "defaultModel");
        const provider = string(model.provider, "defaultModel.provider", { max: 120 });
        const id = string(model.id, "defaultModel.id", { max: 300 });
        if (!this.modelRuntime.getModel(provider, id)) throw new GatewayError("not_found", "Default model is not registered in Tron");
        next.defaultProvider = provider;
        next.defaultModel = id;
      }
    }
    if ("defaultThinkingLevel" in patch) {
      if (patch.defaultThinkingLevel === null) delete next.defaultThinkingLevel;
      else next.defaultThinkingLevel = oneOf(patch.defaultThinkingLevel, "defaultThinkingLevel", thinkingLevels);
    }
    if ("thinkingBudgets" in patch) {
      if (patch.thinkingBudgets === null) delete next.thinkingBudgets;
      else {
        const budgets = object(patch.thinkingBudgets, "thinkingBudgets");
        const value: Record<string, number> = {};
        for (const key of ["minimal", "low", "medium", "high"] as const) {
          if (budgets[key] !== undefined) value[key] = integer(budgets[key], `thinkingBudgets.${key}`, 0, 10_000_000);
        }
        next.thinkingBudgets = value;
      }
    }
    if ("transport" in patch) next.transport = oneOf(patch.transport, "transport", ["sse", "websocket", "websocket-cached", "auto"] as const);
    if ("compaction" in patch) next.compaction = this.nested(next.compaction, patch.compaction, "compaction", {
      enabled: (value) => boolean(value, "compaction.enabled"),
      reserveTokens: (value) => integer(value, "compaction.reserveTokens", 1_024, 1_000_000),
      keepRecentTokens: (value) => integer(value, "compaction.keepRecentTokens", 0, 1_000_000),
    });
    if ("branchSummary" in patch) next.branchSummary = this.nested(next.branchSummary, patch.branchSummary, "branchSummary", {
      reserveTokens: (value) => integer(value, "branchSummary.reserveTokens", 1_024, 1_000_000),
      skipPrompt: (value) => boolean(value, "branchSummary.skipPrompt"),
    });
    if ("retry" in patch) {
      const retry = object(patch.retry, "retry");
      const existing = object(next.retry ?? {}, "existing retry");
      const validated: Record<string, unknown> = { ...existing };
      if (retry.enabled !== undefined) validated.enabled = boolean(retry.enabled, "retry.enabled");
      if (retry.maxRetries !== undefined) validated.maxRetries = integer(retry.maxRetries, "retry.maxRetries", 0, 20);
      if (retry.baseDelayMs !== undefined) validated.baseDelayMs = integer(retry.baseDelayMs, "retry.baseDelayMs", 0, 300_000);
      if (retry.provider !== undefined) validated.provider = this.nested(existing.provider, retry.provider, "retry.provider", {
        timeoutMs: (value) => integer(value, "retry.provider.timeoutMs", 1_000, 3_600_000),
        maxRetries: (value) => integer(value, "retry.provider.maxRetries", 0, 20),
        maxRetryDelayMs: (value) => integer(value, "retry.provider.maxRetryDelayMs", 0, 300_000),
      });
      next.retry = validated;
    }
    if ("httpIdleTimeoutMs" in patch) next.httpIdleTimeoutMs = integer(patch.httpIdleTimeoutMs, "httpIdleTimeoutMs", 1_000, 3_600_000);
    if ("websocketConnectTimeoutMs" in patch) setNullable(next, "websocketConnectTimeoutMs", patch.websocketConnectTimeoutMs === null ? null : integer(patch.websocketConnectTimeoutMs, "websocketConnectTimeoutMs", 1_000, 300_000));
    if ("steeringMode" in patch) next.steeringMode = oneOf(patch.steeringMode, "steeringMode", ["all", "one-at-a-time"] as const);
    if ("followUpMode" in patch) next.followUpMode = oneOf(patch.followUpMode, "followUpMode", ["all", "one-at-a-time"] as const);
    if ("hideThinkingBlock" in patch) next.hideThinkingBlock = boolean(patch.hideThinkingBlock, "hideThinkingBlock");
    if ("showCacheMissNotices" in patch) next.showCacheMissNotices = boolean(patch.showCacheMissNotices, "showCacheMissNotices");
    if ("defaultProjectTrust" in patch) next.defaultProjectTrust = oneOf(patch.defaultProjectTrust, "defaultProjectTrust", ["ask", "always", "never"] as const);
    if ("images" in patch) next.images = this.nested(next.images, patch.images, "images", {
      autoResize: (value) => boolean(value, "images.autoResize"),
      blockImages: (value) => boolean(value, "images.blockImages"),
    });
    if ("enabledModels" in patch) setNullable(next, "enabledModels", patch.enabledModels === null ? null : arrayOfStrings(patch.enabledModels, "enabledModels", 500));
    if ("enableSkillCommands" in patch) next.enableSkillCommands = boolean(patch.enableSkillCommands, "enableSkillCommands");
    if ("shellPath" in patch) setNullable(next, "shellPath", nullableString(patch.shellPath, "shellPath", 4_096));
    if ("shellCommandPrefix" in patch) setNullable(next, "shellCommandPrefix", nullableString(patch.shellCommandPrefix, "shellCommandPrefix", 4_096));
    if ("npmCommand" in patch) setNullable(next, "npmCommand", patch.npmCommand === null ? null : arrayOfStrings(patch.npmCommand, "npmCommand", 20));
    if ("sessionDir" in patch) setNullable(next, "sessionDir", nullableString(patch.sessionDir, "sessionDir", 4_096));
    for (const key of ["extensions", "skills", "prompts", "themes"] as const) {
      if (key in patch) next[key] = arrayOfStrings(patch[key], key, 500);
    }
    if ("packages" in patch) {
      if (!Array.isArray(patch.packages) || patch.packages.length > 500) throw new GatewayError("invalid_request", "packages must be an array with at most 500 entries");
      next.packages = patch.packages.map((value, index) => validatePackageSource(value, `packages[${index}]`));
    }
    if ("markdown" in patch) next.markdown = this.nested(next.markdown, patch.markdown, "markdown", {
      codeBlockIndent: (value) => rawString(value, "markdown.codeBlockIndent", 32),
      mermaid: (value) => oneOf(value, "markdown.mermaid", ["off", "final", "streaming"] as const),
    });
    if ("warnings" in patch) next.warnings = this.nested(next.warnings, patch.warnings, "warnings", {
      anthropicExtraUsage: (value) => boolean(value, "warnings.anthropicExtraUsage"),
    });
    if ("httpProxy" in patch) setNullable(next, "httpProxy", nullableString(patch.httpProxy, "httpProxy", 4_096));
    if ("enableInstallTelemetry" in patch) next.enableInstallTelemetry = boolean(patch.enableInstallTelemetry, "enableInstallTelemetry");
    if ("enableAnalytics" in patch) next.enableAnalytics = boolean(patch.enableAnalytics, "enableAnalytics");
    return next;
  }

  private nested(
    existing: unknown,
    raw: unknown,
    name: string,
    validators: Record<string, (value: unknown) => unknown>,
  ): Record<string, unknown> {
    const patch = object(raw, name);
    const value: Record<string, unknown> = { ...object(existing ?? {}, `existing ${name}`) };
    for (const [key, validate] of Object.entries(validators)) {
      if (patch[key] !== undefined) value[key] = validate(patch[key]);
    }
    return value;
  }
}
