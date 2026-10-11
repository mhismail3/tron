import { SettingsManager } from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import { contextWindowMinimum, contextWindowPreferences, MAX_CONTEXT_PREFERENCES } from "../providers/context-window-policy.js";
import { resolveCompactionPolicy } from "../runtime/compaction-policy.js";

interface SettingsDocument extends Record<string, unknown> {}
type SettingsScope = "global" | "project";

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

function redactSettingsDocument(document: Record<string, unknown>): Record<string, unknown> {
  const redacted = structuredClone(document);
  delete redacted.httpProxy;
  delete redacted.deviceId;
  return redacted;
}

/** The pi settings projection `settings.get` serves until its last client moves
 * to `settings.resolve` (docs/settings-model.md 8). Writes go through the one
 * change path (`SettingsChangePath`), never here. */
export class SettingsService {
  constructor(private readonly agentDir: string) {}

  get(cwd: string, projectTrusted = false): Record<string, unknown> {
    // SettingsManager keeps its initially merged snapshot even when the trust
    // flag is false. Use an agent-dir-bound manager for a truly global-only
    // projection and a cwd-bound manager only after project trust resolves.
    const manager = SettingsManager.create(projectTrusted ? cwd : this.agentDir, this.agentDir, { projectTrusted });
    if (manager.drainErrors().length) throw new GatewayError("conflict", "Canonical settings could not be loaded");
    const global = manager.getGlobalSettings() as Record<string, unknown>;
    const project = projectTrusted ? manager.getProjectSettings() as Record<string, unknown> : {};
    const effective = merge(global, project);
    const defaultProvider = manager.getDefaultProvider();
    const defaultModel = manager.getDefaultModel();
    const rawRetry = manager.getRetrySettings();
    const compactionPolicy = resolveCompactionPolicy(global, project, projectTrusted);
    const result = {
      scope: { cwd, projectTrusted },
      documents: {
        global: redactSettingsDocument(global),
        project: projectTrusted ? redactSettingsDocument(project) : null,
      },
      effective: {
        defaultModel: defaultProvider && defaultModel ? { provider: defaultProvider, id: defaultModel } : null,
        defaultThinkingLevel: manager.getDefaultThinkingLevel() ?? null,
        defaultTools: manager.getDefaultTools() ?? null,
        codemode: effective.codemode ?? null,
        modelContextWindows: contextWindowPreferences(effective, MAX_CONTEXT_PREFERENCES * 2),
        contextWindowMinimum: contextWindowMinimum(manager.getCompactionSettings()),
        thinkingBudgets: manager.getThinkingBudgets() ?? null,
        transport: manager.getTransport(),
        compaction: { ...manager.getCompactionSettings(), ...compactionPolicy },
        branchSummary: { reserveTokens: manager.getBranchSummarySettings().reserveTokens },
        retry: { ...rawRetry, provider: manager.getProviderRetrySettings() },
        httpIdleTimeoutMs: manager.getHttpIdleTimeoutMs(),
        websocketConnectTimeoutMs: manager.getWebSocketConnectTimeoutMs() ?? null,
        steeringMode: manager.getSteeringMode(),
        followUpMode: manager.getFollowUpMode(),
        defaultProjectTrust: manager.getDefaultProjectTrust(),
        images: { autoResize: manager.getImageAutoResize(), blockImages: manager.getBlockImages() },
        enabledModels: manager.getEnabledModels() ?? null,
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
        // Tron's SDK host reads install telemetry only as provider attribution
        // headers. Terminal-only presentation, warning and analytics settings are
        // deliberately not editable here because no Tron surface consumes them.
        telemetry: { install: manager.getEnableInstallTelemetry() },
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
}
