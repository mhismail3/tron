import { join } from "node:path";
import { SettingsManager, type ModelRuntime } from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import { KEYS } from "./settings-schema.js";
import { assertNewModelChoice } from "../providers/openai-model-eligibility.js";
import { contextWindowLimits, contextWindowMinimum, contextWindowPreferences, MAX_CONTEXT_PREFERENCES, parseContextModelKey, validateContextWindow } from "../providers/context-window-policy.js";
import { resolveCompactionPolicy } from "../runtime/compaction-policy.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { updateJsonLocked } from "../util/json.js";
import { object, string } from "../util/validation.js";

interface SettingsDocument extends Record<string, unknown> {}
type SettingsScope = "global" | "project";

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

function redactSettingsDocument(document: Record<string, unknown>): Record<string, unknown> {
  const redacted = structuredClone(document);
  delete redacted.httpProxy;
  delete redacted.deviceId;
  return redacted;
}

function patchValue(patch: Record<string, unknown>, path: readonly string[]): { present: boolean; value?: unknown } {
  let current: unknown = patch;
  for (const segment of path) {
    if (typeof current !== "object" || current === null || Array.isArray(current) || !(segment in current)) return { present: false };
    current = (current as Record<string, unknown>)[segment];
  }
  return { present: true, value: current };
}

function setPath(document: SettingsDocument, path: readonly string[], value: unknown): void {
  let current: Record<string, unknown> = document;
  for (const segment of path.slice(0, -1)) {
    const child = current[segment];
    current = current[segment] = child && typeof child === "object" && !Array.isArray(child) ? child as Record<string, unknown> : {};
  }
  current[path[path.length - 1]!] = value;
}

function unsetPath(document: SettingsDocument, path: readonly string[]): void {
  let current: unknown = document;
  for (const segment of path.slice(0, -1)) {
    if (!current || typeof current !== "object") return;
    current = (current as Record<string, unknown>)[segment];
  }
  if (current && typeof current === "object") delete (current as Record<string, unknown>)[path[path.length - 1]!];
}


/** Canonical Pi settings projection with explicit global/project ownership. */
export class SettingsService {
  private readonly mutation = new AsyncMutex();

  constructor(
    private readonly agentDir: string,
    private readonly modelRuntime: ModelRuntime,
    private readonly allowSessionDirectoryChange = true,
  ) {}

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

  async update(raw: unknown, options: { cwd: string; scope: SettingsScope; projectTrusted: boolean; modelRuntime?: ModelRuntime }): Promise<Record<string, unknown>> {
    return this.mutation.run(() => this.updateLocked(raw, options));
  }

  private async updateLocked(raw: unknown, options: { cwd: string; scope: SettingsScope; projectTrusted: boolean; modelRuntime?: ModelRuntime }): Promise<Record<string, unknown>> {
    if (options.scope === "project" && !options.projectTrusted) {
      throw new GatewayError("trust_required", "Trust this project before changing its project settings");
    }
    const patch = object(raw, "settings patch");
    if (patch.defaultModel !== undefined && patch.defaultModel !== null) {
      const selected = object(patch.defaultModel, "defaultModel");
      await assertNewModelChoice(
        options.modelRuntime ?? this.modelRuntime,
        string(selected.provider, "defaultModel.provider", { max: 120 }),
        string(selected.id, "defaultModel.id", { max: 300 }),
      );
    }
    const path = options.scope === "global"
      ? join(this.agentDir, "settings.json")
      : join(options.cwd, ".pi", "settings.json");
    const inherited = options.scope === "project"
      ? SettingsManager.create(options.cwd, this.agentDir, { projectTrusted: true })
      : undefined;
    if (inherited?.drainErrors().length) throw new GatewayError("conflict", "Canonical settings could not be loaded");
    const global = inherited?.getGlobalSettings() as Record<string, unknown> | undefined;
    await updateJsonLocked<SettingsDocument>(path, {}, (current) => {
      const next = this.applyPatch(current, patch, options.scope);
      if ("modelContextWindows" in patch) {
        const delta = object(patch.modelContextWindows, "modelContextWindows");
        if (Object.keys(delta).length > MAX_CONTEXT_PREFERENCES) throw new GatewayError("invalid_request", "Too many context window preferences");
        const values = contextWindowPreferences(current);
        const effective = merge(global ?? {}, next);
        const compaction = object(effective.compaction ?? {}, "compaction");
        const budget = {
          reserveTokens: typeof compaction.reserveTokens === "number" ? compaction.reserveTokens : 16_384,
          keepRecentTokens: typeof compaction.keepRecentTokens === "number" ? compaction.keepRecentTokens : 20_000,
        };
        const catalog = (options.modelRuntime ?? this.modelRuntime).getModels();
        for (const [key, value] of Object.entries(delta)) {
          const identity = parseContextModelKey(key);
          if (value === null) { delete values[key]; continue; }
          const model = catalog.find(model => model.provider === identity.provider && model.id === identity.id);
          if (!model) throw new GatewayError("not_found", "Context window model is not registered in this settings scope");
          values[key] = validateContextWindow(value, contextWindowLimits(model, budget));
        }
        if (Object.keys(values).length > MAX_CONTEXT_PREFERENCES) throw new GatewayError("invalid_request", "Too many context window preferences");
        if (Object.keys(values).length) next.modelContextWindows = values;
        else delete next.modelContextWindows;
      }
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
      // `updateJsonLocked` commits the callback result before the response is
      // projected by get(). Validate the complete effective policy here so a
      // stale hand-edited compaction value cannot turn a durable unrelated
      // update into a failed RPC.
      if (global === undefined) resolveCompactionPolicy(next, {}, false);
      else resolveCompactionPolicy(global, next, true);
      return next;
    });
    return this.get(options.cwd, options.scope === "project" && options.projectTrusted);
  }

  /** Applies a pi-document-shaped patch. Each value is validated by its
   * settings-schema entry, at the layer the scope writes; a key the layer does
   * not allow is refused (settings-model.md F1). `null` unsets a value. */
  private applyPatch(current: SettingsDocument, patch: Record<string, unknown>, scope: SettingsScope): SettingsDocument {
    const next: SettingsDocument = structuredClone(current);
    const layer = scope === "global" ? "mac" : "project";
    for (const key of KEYS) {
      const binding = key.layers.mac?.store === "pi" ? key.layers.mac : key.layers.project?.store === "pi" ? key.layers.project : undefined;
      if (!binding || binding.store !== "pi" || binding.path.includes("{model}")) continue;
      const found = patchValue(patch, binding.path);
      if (!found.present) continue;
      if (!key.layers[layer]) {
        throw new GatewayError("invalid_request", `${key.label} cannot be set at the ${layer === "mac" ? "Mac" : "Project"} layer`);
      }
      if (key.id === "setup.sessionDir" && !this.allowSessionDirectoryChange) {
        throw new GatewayError(
          "conflict",
          "Change sessionDir only while the Gateway is stopped; restart is required before a new canonical session directory can be used.",
          false,
        );
      }
      if (found.value === null) unsetPath(next, binding.path);
      else setPath(next, binding.path, key.type.validate(found.value, binding.path.join(".")));
    }
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
    return next;
  }

}
