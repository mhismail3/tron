import { type SettingsTarget, type ChangeResult, type ConfirmChange } from "../kernel/settings/tool-contract.js";
import type { MacTerminalService } from "../security/mac-terminal-service.js";
import { setPath, unsetPath, qualifiedWrite, fillPath, type SessionSettingsSource } from "../kernel/settings/settings-model.js";
import type { ChangeContext, SettingsWriters, Planned } from "../kernel/settings/settings-change.js";
import { stage } from "../util/request-span.js";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { clampThinkingLevel, getSupportedThinkingLevels, type Model, type ThinkingLevel } from "../kernel/pi/ai.js";
import { SettingsManager, type ModelRuntime } from "../kernel/pi/coding-agent.js";
import { asUncertainOutcome, GatewayError } from "../errors.js";
import { validateProjectSettings } from "../kernel/settings/settings-sdk-manager.js";
import { contextWindowLimits, parseContextModelKey, validateContextWindow } from "../providers/context-window-policy.js";
import { assertNewModelChoice } from "../providers/openai-model-eligibility.js";
import { isVirtualModel } from "../providers/virtual-model.js";
import { updateJsonLocked } from "../foundation/json.js";
import { gitHeadState, projectGitState, readProjectDocument } from "./project-settings-writer.js";
import { observedInstance, projectStores, type ObservedReaders, type OutsideChanges } from "./settings-outside.js";
import type { McpAdminService } from "./mcp-admin-service.js";
import type { McpServerValue } from "../kernel/settings/mcp-server-value.js";
import type { LessonMoveValue } from "../kernel/settings/lesson-move-value.js";
import type { ModelProviderValue } from "../kernel/settings/model-provider-value.js";
import type { ModelConfigService } from "./model-config-service.js";
import { agentDefinition, setAgentDefinition } from "./agent-definitions.js";
import type { TrustService } from "../kernel/resources/trust-service.js";
import { targetLayers } from "../kernel/settings/settings-resolver.js";
import type { SettingsSchema } from "../kernel/settings/settings-schema.js";
import { type DevicePreferencePort, type DevicePreferenceRead, type DevicePreferenceSnapshot, type FormatContext, type ModelRefValue, type OptionSources, type SettingsStores, type ResolveOptions, type ObservedStore, type PlannedWrite } from "../kernel/settings/settings-types.js";
import { tronHomePath } from "../foundation/tron-home-layout.js";
import type { PackageUpdateRequest } from "./package-service.js";
import type { Actor } from "../kernel/settings/settings-record.js";

interface SettingsModelDependencies {
  schema: SettingsSchema;
  agentDir: string;
  tronHome: string;
  trust: Pick<TrustService, "inspect" | "canonicalDirectory">;
  modelRuntime: ModelRuntime;
  toolCatalog?: (target: SettingsTarget) => Promise<readonly ToolCatalogEntry[]>;
  updatePackage?: (request: PackageUpdateRequest, requester: Actor, confirm?: ConfirmChange) => Promise<ChangeResult>;
  macTerminalKeys?: Pick<MacTerminalService, "read" | "set" | "enabled" | "setEnabled">;
  mcpAdmin?: McpAdminService;
  modelConfig?: ModelConfigService;
  lessonMoves?: LessonMoveStore;
  devicePreferences?: DevicePreferencePort;
}

export interface LessonMoveStore {
  value(lesson: string): Promise<LessonMoveValue | undefined>;
  set(lesson: string, value: LessonMoveValue | undefined, commandId: string): Promise<void>;
}

export interface ToolCatalogEntry { name: string; description?: string; resource: Record<string, unknown> }

export class SettingsStoreAdapter {
  readonly admitModelChoice = assertNewModelChoice;
  private outside: OutsideChanges | undefined;

  constructor(private readonly dependencies: SettingsModelDependencies) {}

  private mcp(): McpAdminService {
    if (!this.dependencies.mcpAdmin) throw new GatewayError("unsupported", "This Gateway has no MCP configuration owner");
    return this.dependencies.mcpAdmin;
  }

  private lessonMoves(): LessonMoveStore {
    if (!this.dependencies.lessonMoves) throw new GatewayError("unsupported", "This Gateway has no lesson move owner");
    return this.dependencies.lessonMoves;
  }

  private modelConfig(): ModelConfigService {
    if (!this.dependencies.modelConfig) throw new GatewayError("unsupported", "This Gateway has no custom model configuration owner");
    return this.dependencies.modelConfig;
  }

  recordValue(subject: string, instance: string): Promise<unknown> {
    switch (subject) {
      case "tools.mcp.server": return this.mcp().server(instance);
      case "accounts.models.provider": return this.modelConfig().provider(instance);
      case "context.lesson": return this.lessonMoves().value(instance);
      case "subagents.agent": return agentDefinition(this.dependencies.agentDir, instance);
      default: throw new GatewayError("unsupported", `${subject} has no record owner`);
    }
  }

  updatePackage(request: PackageUpdateRequest, requester: Actor, confirm?: ConfirmChange): Promise<ChangeResult> {
    if (!this.dependencies.updatePackage) throw new GatewayError("unsupported", "Package updates are not available");
    return this.dependencies.updatePackage(request, requester, confirm);
  }

  async projectRoot(path: string): Promise<string> {
    return (await this.dependencies.trust.inspect(path)).projectDir;
  }

  observeOutside(outside: OutsideChanges): void {
    if (this.outside && this.outside !== outside) throw new Error("Settings already have an outside-change owner");
    this.outside = outside;
  }

  get outsideChanges(): OutsideChanges | undefined { return this.outside; }

  get observedReaders(): ObservedReaders {
    return {
      global: async () => this.piDocuments(this.dependencies.agentDir).global,
      project: async (root) => (await readProjectDocument(root)).document,
    };
  }

  get schema(): SettingsSchema { return this.dependencies.schema; }

  get modelRuntime(): ModelRuntime { return this.dependencies.modelRuntime; }

  get macTerminalKeys(): SettingsModelDependencies["macTerminalKeys"] { return this.dependencies.macTerminalKeys; }

  get profilePath(): string {
    return tronHomePath(this.dependencies.tronHome, "state/home/profile.json");
  }


  get gatewaySettingsPath(): string {
    return tronHomePath(this.dependencies.tronHome, "state/settings/gateway.json");
  }

  resolveOptions(runtime: ModelRuntime): Pick<ResolveOptions, "format" | "options"> {
    return { format: formatContext(runtime), options: optionSources(runtime) };
  }

  private async devicePreferenceSnapshot(target: SettingsTarget, keys: readonly string[] | undefined): Promise<DevicePreferenceSnapshot | undefined> {
    const requested = this.dependencies.schema.KEYS.filter(key => key.layers.global?.store === "device-preference" && (!keys || keys.includes(key.id)));
    if (!requested.length || (target.kind !== "global" && target.kind !== "home")) return undefined;
    const port = this.dependencies.devicePreferences;
    if (!port) return { devices: [], reads: {} };
    const devices = await port.devices().catch(() => []);
    const reads = Object.fromEntries(await Promise.all(devices.map(async device => [device, Object.fromEntries(await Promise.all(requested.map(async key =>
      [key.id, await port.read(device, key.id).catch((): DevicePreferenceRead => ({ status: "unavailable" }))] as const)))] as const)));
    return { devices, reads };
  }

  async stores(target: SettingsTarget, session?: SessionSettingsSource, options: { storeState?: boolean; keys?: readonly string[] } = {}): Promise<SettingsStores> {
    const storeState = options.storeState !== false;
    if (target.kind === "session" && !session) throw new GatewayError("invalid_request", "A session target needs its session");
    const cwd = target.kind === "project" ? target.cwd : target.kind === "session" && !session!.home ? session!.cwd : undefined;
    const inspection = cwd === undefined ? undefined : await stage("settings.store.trust-inspection", () => this.dependencies.trust.inspect(cwd));
    const observed: ObservedStore[] = [{ kind: "global" }, { kind: "trust" }, { kind: "mcp" }, { kind: "models" }, { kind: "agents" },
      ...(inspection ? projectStores(inspection.projectDir) : [])];
    const head = storeState && inspection
      ? await stage("settings.store.project-git-head", () => gitHeadState(inspection.projectDir))
      : undefined;
    if (storeState && this.outside) {
      await stage("settings.store.outside-reconcile", () => this.outside!.reconcile(
        observed, inspection ? new Map([[inspection.projectDir, head]]) : undefined,
      ));
    }
    const global = stage("settings.store.global-document", () => this.piDocuments(this.dependencies.agentDir).global);
    const trust = await stage("settings.store.trust-decisions", () => this.trustDecisions());
    let project: SettingsStores["project"];
    if (inspection) {
      const documents = stage("settings.store.project-document", () => this.piDocuments(inspection.projectDir));
      project = {
        root: inspection.projectDir,
        document: documents.project,
        ...(documents.projectUnreadable ? { unreadable: true as const } : {}),
        applied: inspection.effectiveDecision === true,
        ...(inspection.effectiveDecision === true ? {} : { reason: "untrusted" as const }),
        ...(storeState ? { git: await stage("settings.store.project-git-state", () => projectGitState(inspection.projectDir, head ?? null)) } : {}),
      };
    }
    if (project?.applied) await validateProjectSettings(this.schema, project.document);
    const outside = this.outside && storeState ? {
      global: {
        ...await stage("settings.store.global-outside-marks", () => this.outside!.marks({ kind: "global" })),
        ...await stage("settings.store.trust-outside-marks", () => this.outside!.marks({ kind: "trust" })),
      },
      ...(inspection ? {
        project: await stage("settings.store.project-outside-marks", () => this.outside!.marks({ kind: "project", root: inspection.projectDir })),
      } : {}),
    } : undefined;
    const home = target.kind === "home" || (target.kind === "session" && session!.home);
    const layers = targetLayers(target, { home, project: project !== undefined });
    const devicePreferences = await stage("settings.store.device-preferences", () => this.devicePreferenceSnapshot(target, options.keys));
    const macTerminal = this.dependencies.macTerminalKeys
      ? await stage("settings.store.mac-terminal-keys", () => this.dependencies.macTerminalKeys!.read())
      : {};
    return {
      layers,
      global,
      trust,
      macTerminal,
      macTerminalServerEnabled: await this.macTerminalKeys?.enabled() ?? false,
      ...(devicePreferences ? { devicePreferences } : {}),
      gateway: await stage("settings.store.gateway-settings", () => this.gatewaySettings()),
      ...(outside ? { outside } : {}),
      ...(project ? { project } : {}),
      ...(session ? { session: session.session } : {}),
      ...(home ? { home: await stage("settings.store.home-profile", () => this.homeProfile()) } : {}),
    };
  }

  observedWrites(planned: readonly Planned[], projectRoot: string | undefined): PlannedWrite[] {
    return planned.flatMap(plan => {
      const observed = observedInstance(plan.key, plan.request.layer, plan.binding, plan.qualifiers, projectRoot);
      return observed ? [{ ...observed, changeId: plan.changeId, value: plan.after }] : [];
    });
  }

  contextWindowValue(runtime: ModelRuntime, qualifier: string | undefined, value: unknown): number {
    return contextWindowValue(runtime, qualifier, value);
  }

  defaultContextWindow(runtime: ModelRuntime, qualifier: string): number | undefined {
    const ref = parseContextModelKey(qualifier);
    const model = runtime.getPhysicalModel(ref.provider, ref.id);
    return model && contextWindowLimits(model)?.default;
  }

  async admitModel(runtime: ModelRuntime, ref: ModelRefValue, options: { physical?: boolean } = {}): Promise<void> {
    const model = runtime.getModel(ref.provider, ref.id);
    if (!model) throw new GatewayError("not_found", "Model is not registered in Tron");
    if (options.physical && isVirtualModel(model)) throw new GatewayError("invalid_request", "A model queue lists physical models; virtual models are not supported");
    await assertNewModelChoice(runtime, ref.provider, ref.id);
  }

  async applyStore(bundleTarget: SettingsTarget, stores: SettingsStores, plan: Planned, value: unknown, bundleContext: ChangeContext, writers: Pick<SettingsWriters, "setTrust">, current: unknown): Promise<{ revision?: number; result?: unknown }> {
    const { binding, qualifiers } = plan;
    const target = plan.target ?? bundleTarget;
    const context = plan.session ? { ...bundleContext, session: plan.session } : bundleContext;
    const unset = value === undefined;
    switch (binding.store) {
      case "pi":
      case "pi-model-ref": {
        const write = (document: Record<string, unknown>) => {
          if (binding.store === "pi-model-ref") {
            if (unset) { delete document.defaultProvider; delete document.defaultModel; }
            else { const ref = value as ModelRefValue; document.defaultProvider = ref.provider; document.defaultModel = ref.id; }
          } else {
            const path = fillPath(qualifiedWrite(binding, qualifiers) ? binding.qualified! : binding.path, qualifiers);
            if (unset) unsetPath(document, path); else setPath(document, path, value);
          }
          return document;
        };
        await updateJsonLocked<Record<string, unknown>>(join(this.dependencies.agentDir, "settings.json"), {}, write);
        return {};
      }
      case "mac-terminal-service": {
        if (!this.macTerminalKeys) throw new GatewayError("unsupported", "This Gateway has no private SSH service");
        await this.macTerminalKeys.setEnabled(!unset && value === true);
        return {};
      }
      case "mac-terminal": {
        const keys = this.macTerminalKeys;
        if (!keys) throw new GatewayError("unsupported", "This Gateway has no Mac Terminal key store");
        await keys.set(qualifiers.device!, unset ? null : value as string);
        return {};
      }
      case "mcp":
        await this.mcp().setServer(qualifiers.server!, unset ? undefined : value as McpServerValue);
        return {};
      case "models":
        await this.modelConfig().setProvider(qualifiers.provider!, unset ? undefined : value as ModelProviderValue,
          value !== plan.after || context.undoOf || context.applyAgainOf ? null : context.secret);
        return {};
      case "agents":
        await setAgentDefinition(this.dependencies.agentDir, qualifiers.agent!, unset ? undefined : value as string);
        return {};
      case "lesson":
        await this.lessonMoves().set(qualifiers.lesson!, unset ? undefined : value as LessonMoveValue, plan.changeId);
        return {};
      case "device-preference": {
        if (unset) throw new GatewayError("invalid_request", `${plan.key.label} cannot be unset on an iPhone`);
        const port = this.dependencies.devicePreferences;
        if (!port) throw new GatewayError("busy", "This iPhone is not connected; nothing was changed", true);
        const outcome = await port.compareAndSet(qualifiers.device!, plan.key.id, current, value);
        if (outcome.status === "applied") return {};
        if (outcome.status === "conflict") throw new GatewayError("conflict", `${plan.key.label} changed on this iPhone since it was read; refresh and try again`, false, { current: outcome.current as never });
        if (outcome.status === "unavailable") throw new GatewayError("busy", "This iPhone is not connected; nothing was changed", true);
        const message = `${plan.key.label}: the write to this iPhone has an unknown outcome; inspect it before changing it again`;
        throw asUncertainOutcome(new GatewayError("conflict", message), message);
      }
      case "trust":
        return { result: await writers.setTrust(qualifiers.project!, unset ? null : value as boolean) };
      case "gateway":
        await updateJsonLocked<Record<string, unknown>>(this.gatewaySettingsPath, {}, document => {
          if (unset) unsetPath(document, binding.path); else setPath(document, binding.path, value);
          return document;
        });
        return {};
      case "home":
        await updateJsonLocked<Record<string, unknown>>(this.profilePath, {}, document => {
          if (unset) unsetPath(document, binding.path); else setPath(document, binding.path, value);
          return document;
        });
        return {};
      case "session-settings": {
        if (!context.session || target.kind !== "session") throw new GatewayError("invalid_request", "A Session-scope change needs its open session");
        return { revision: await context.session.appliers.setSetting(plan.key.id, value, context.actor.kind === "ui", plan.fixedAt) };
      }
      case "session": {
        const appliers = context.session?.appliers;
        if (!appliers || target.kind !== "session") throw new GatewayError("invalid_request", "A Session-scope change needs its open session");
        if (binding.field === "model") return { revision: await appliers.setModel(value as ModelRefValue, plan.fixedAt) };
        if (binding.field === "thinking") return { revision: await appliers.setThinking(value as string, plan.fixedAt) };
        if (binding.field === "tools") { await appliers.setTools(value as string[], plan.fixedAt); return {}; }
        const [provider, ...id] = qualifiers.model!.split("/");
        return { revision: await appliers.setContextWindow({ provider: provider!, id: id.join("/") }, unset ? null : value as number, plan.fixedAt) };
      }
      default:
        throw new GatewayError("unsupported", "This store has no applier yet");
    }
  }

  private async homeProfile(): Promise<Record<string, unknown>> {
    return this.validatedStore(await readBoundedJsonObject(this.profilePath, 256 * 1024, "Home profile"), "home", "Home profile");
  }

  private async validatedStore(document: Record<string, unknown>, layer: "home" | "global", label: string): Promise<Record<string, unknown>> {
    for (const key of this.schema.KEYS) {
      const binding = key.layers[layer];
      if (binding?.store !== (layer === "home" ? "home" : "gateway") || !("path" in binding)) continue;
      const value = readPath(document, binding.path);
      if (value === undefined) continue;
      try {
        setPath(document, binding.path, await key.type.validate(value, key.id));
      } catch {
        throw new GatewayError("conflict", `The ${label} value for ${key.id} is invalid`);
      }
    }
    return document;
  }

  private piDocuments(cwd: string): { global: Record<string, unknown>; project: Record<string, unknown>; projectUnreadable?: true } {
    const manager = SettingsManager.create(cwd, this.dependencies.agentDir, { projectTrusted: true });
    const errors = manager.drainErrors();
    if (errors.some(error => error.scope === "global")) throw new GatewayError("conflict", "Canonical settings could not be loaded");
    const projectUnreadable = errors.some(error => error.scope === "project");
    return {
      global: manager.getGlobalSettings() as Record<string, unknown>,
      project: cwd === this.dependencies.agentDir || projectUnreadable ? {} : manager.getProjectSettings() as Record<string, unknown>,
      ...(projectUnreadable ? { projectUnreadable: true as const } : {}),
    };
  }

  private async gatewaySettings(): Promise<Record<string, unknown>> {
    return this.validatedStore(await readJsonObject(this.gatewaySettingsPath), "global", "Gateway settings");
  }

  private async trustDecisions(): Promise<Record<string, boolean>> {
    const document = await readJsonObject(join(this.dependencies.agentDir, "trust.json"));
    const result: Record<string, boolean> = {};
    for (const [path, decision] of Object.entries(document)) {
      if (typeof decision === "boolean") result[path] = decision;
    }
    return result;
  }
}

function readPath(document: Record<string, unknown>, path: readonly string[]): unknown {
  let value: unknown = document;
  for (const [index, segment] of path.entries()) {
    if (value === undefined) return undefined;
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      throw new GatewayError("conflict", "The Home profile has an invalid field structure");
    }
    value = (value as Record<string, unknown>)[segment];
    if (value === undefined && index < path.length - 1) return undefined;
  }
  return value;
}

async function readStore(path: string): Promise<string | undefined> {
  try { return await readFile(path, "utf8"); }
  catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined; throw error; }
}

async function readBoundedJsonObject(path: string, maxBytes: number, label: string): Promise<Record<string, unknown>> {
  const raw = await readStore(path);
  if (raw === undefined) return {};
  if (Buffer.byteLength(raw, "utf8") > maxBytes) throw new GatewayError("conflict", `${label} exceeds its ${maxBytes}-byte limit`);
  try {
    const value = JSON.parse(raw.replace(/^\uFEFF/u, "")) as unknown;
    if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error("not object");
    return value as Record<string, unknown>;
  } catch {
    throw new GatewayError("conflict", `${label} could not be parsed`);
  }
}

async function readJsonObject(path: string): Promise<Record<string, unknown>> {
  const raw = await readStore(path);
  if (raw === undefined) return {};
  try {
    const value = JSON.parse(raw.replace(/^\uFEFF/u, "")) as unknown;
    return typeof value === "object" && value !== null && !Array.isArray(value) ? value as Record<string, unknown> : {};
  } catch {
    throw new GatewayError("conflict", "A settings store could not be parsed");
  }
}

function formatContext(runtime: ModelRuntime): FormatContext {
  return { modelName: (ref) => runtime.getModel(ref.provider, ref.id)?.name };
}

function optionSources(runtime: ModelRuntime): OptionSources {
  return {
    clamp(source, dependency, value) {
      if (source !== "catalog.thinkingLevels") return value;
      const ref = dependency as { provider: string; id: string } | undefined;
      const model = ref && runtime.getModel(ref.provider, ref.id) as Model<any> | undefined;
      if (!model || typeof value !== "string") return value;
      return getSupportedThinkingLevels(model).includes(value as ThinkingLevel) ? value : clampThinkingLevel(model, value as ThinkingLevel);
    },
  };
}

function limitsModel(runtime: ModelRuntime, ref: { provider: string; id: string }): Model<any> | undefined {
  return runtime.getPhysicalModel(ref.provider, ref.id) ?? runtime.getModel(ref.provider, ref.id);
}

function contextWindowValue(runtime: ModelRuntime, qualifier: string | undefined, value: unknown): number {
  const ref = qualifier ? parseContextModelKey(qualifier) : undefined;
  const model = ref && limitsModel(runtime, ref);
  if (!model) throw new GatewayError("not_found", "Context window model is not registered in Tron");
  return validateContextWindow(value, contextWindowLimits(model));
}
