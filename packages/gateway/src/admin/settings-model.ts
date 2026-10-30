import { type Resolution, type SettingsTarget, TIERS, type Qualifiers, type Tier, type GitResult } from "../kernel/settings/tool-contract.js";
import type { MacTerminalService } from "../security/mac-terminal-service.js";
import { setPath, unsetPath, qualifiedWrite, fillPath, type SessionSettingsSource, type SettingsOptionsRequest, type SettingsOptionsResult } from "../kernel/settings/settings-model.js";
import type { ChangeContext, SettingsWriters, Planned } from "../kernel/settings/settings-change.js";
import { stage } from "../util/request-span.js";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { clampThinkingLevel, getSupportedThinkingLevels, type Model, type ThinkingLevel } from "../kernel/pi/ai.js";
import { SettingsManager, type ModelRuntime } from "../kernel/pi/coding-agent.js";
import { GatewayError } from "../errors.js";
import { validateProjectSettings } from "../kernel/settings/settings-sdk-manager.js";
import { contextWindowLimits, parseContextModelKey, validateContextWindow } from "../providers/context-window-policy.js";
import { assertNewModelChoice, openAIModelEligibility } from "../providers/openai-model-eligibility.js";
import { isVirtualModel } from "../providers/virtual-model.js";
import { updateJsonLocked } from "../foundation/json.js";
import { gitHeadState, projectGitState, readProjectDocument, writeProjectSettings } from "./project-settings-writer.js";
import { observedInstance, projectStores, type ObservedReaders, type OutsideChanges } from "./settings-outside.js";
import type { TrustService } from "../kernel/resources/trust-service.js";
import { targetLayers } from "../kernel/settings/settings-resolver.js";
import type { SettingsSchema } from "../kernel/settings/settings-schema.js";
import { type FormatContext, type ModelRefValue, type OptionSources, type SettingsStores, type FloorOverrides, type ResolveOptions, type ObservedStore, type PlannedWrite } from "../kernel/settings/settings-types.js";

export interface SettingsModelDependencies {
  schema: SettingsSchema;
  agentDir: string;
  tronHome: string;
  trust: Pick<TrustService, "inspect" | "canonicalDirectory">;
  modelRuntime: ModelRuntime;
  /** The tools a target's selection can name (`catalog.tools`): a chat's live
   * registry, or the built-in and opt-in extension tools of a scope. */
  toolCatalog?: (target: SettingsTarget) => Promise<readonly ToolCatalogEntry[]>;
  /** One private SSH resource owner, shared with the endpoint and CLI. */
  macTerminalKeys?: Pick<MacTerminalService, "read" | "set" | "enabled" | "setEnabled">;
}

export interface ToolCatalogEntry { name: string; description?: string; resource: Record<string, unknown> }

/**
 * The settings model's read side: loads each store a target's layers read,
 * from its owner, and resolves (docs/settings-model.md section 3).
 * Reading an untrusted project's `.pi/settings.json` is pure JSON parsing.
 */
export class SettingsStoreAdapter {
  readonly admitModelChoice = assertNewModelChoice;
  private outside: OutsideChanges | undefined;

  constructor(private readonly dependencies: SettingsModelDependencies) {}

  /** The Project root that keys a path's Project store and trust decision. */
  async projectRoot(path: string): Promise<string> {
    return (await this.dependencies.trust.inspect(path)).projectDir;
  }

  /** The outside-change owner every settings read reconciles through (doc 5.6). */
  observeOutside(outside: OutsideChanges): void {
    if (this.outside && this.outside !== outside) throw new Error("Settings already have an outside-change owner");
    this.outside = outside;
  }

  /** The readers the outside-change owner compares with: the same parse rules as resolution. */
  get outsideChanges(): OutsideChanges | undefined { return this.outside; }

  get observedReaders(): ObservedReaders {
    return {
      global: async () => this.piDocuments(this.dependencies.agentDir).global,
      project: async (root) => (await readProjectDocument(root)).document,
      floors: () => this.floorOverrides(),
    };
  }

  get schema(): SettingsSchema { return this.dependencies.schema; }

  get modelRuntime(): ModelRuntime { return this.dependencies.modelRuntime; }

  get macTerminalKeys(): SettingsModelDependencies["macTerminalKeys"] { return this.dependencies.macTerminalKeys; }

  get profilePath(): string {
    return join(this.dependencies.tronHome, "gateway", "home", "profile.json");
  }

  /** The maintainer's floor overrides (doc 5.4); only the change path writes it. */
  get floorsPath(): string {
    return join(this.dependencies.tronHome, "gateway", "settings", "floors.json");
  }

  /** Gateway-owned keys no pi file holds (Binding `gateway`); only the change path writes it. */
  get gatewaySettingsPath(): string {
    return join(this.dependencies.tronHome, "gateway", "settings", "gateway.json");
  }

  resolveOptions(runtime: ModelRuntime): Pick<ResolveOptions, "format" | "options"> {
    return { format: formatContext(runtime), options: optionSources(runtime) };
  }

  /** `settings.options` (docs/settings-model.md 7.5): the choices a key's control offers. */
  async options(target: SettingsTarget, session: SessionSettingsSource | undefined, request: SettingsOptionsRequest, resolve: (keys: readonly string[]) => Promise<Resolution>): Promise<SettingsOptionsResult> {
    const key = this.schema.KEYS.find(candidate => candidate.id === request.key);
    if (!key) throw new GatewayError("invalid_request", `Unknown setting ${request.key}`);
    if (!key.control) throw new GatewayError("invalid_request", `${key.label} has no editor options`);
    if (!key.optionsSource) {
      if (!key.type.options) throw new GatewayError("invalid_request", `${key.label} has no options to choose from`);
      return { key: key.id, source: "static", dependsOn: [], options: key.type.options.map(option => ({
        value: option.value, label: option.label, ...(option.detail ? { detail: option.detail } : {}) })) };
    }
    const { name, dependsOn } = key.optionsSource;
    const runtime = session?.modelRuntime ?? this.dependencies.modelRuntime;
    const base = { key: key.id, source: name, dependsOn: [...dependsOn] };
    switch (name) {
      case "catalog.models":
        return { ...base, ...await this.catalogModelOptions(runtime, request, key.type.kind === "stringList" || target.kind === "home" || session?.home === true) };
      case "catalog.thinkingLevels": {
        const model = await this.followedModel(runtime, request.qualifiers, resolve);
        const supported = model ? getSupportedThinkingLevels(model) : [];
        // pi reports only "off" for a model without reasoning: there is no level to offer.
        const levels = supported.length === 1 && supported[0] === "off" ? [] : supported;
        const declared = new Map(this.schema.schemaKey("model.thinking[role=chat]").type.options!.map(option => [option.value, option]));
        return { ...base, options: levels.map(level => ({ value: level, label: declared.get(level)?.label ?? level,
          ...(declared.get(level)?.detail ? { detail: declared.get(level)!.detail } : {}) })) };
      }
      case "catalog.tools": {
        if (!this.dependencies.toolCatalog) throw new GatewayError("unsupported", "This Gateway has no tool catalog");
        const catalog = await this.dependencies.toolCatalog(target);
        // A chosen name the catalog no longer offers stays listed, so it can be cleared.
        const chosen = (await resolve([key.id])).keys[0]?.value;
        const names = new Set(catalog.map(tool => tool.name));
        const missing = (Array.isArray(chosen) ? chosen as string[] : []).filter(name => !names.has(name));
        return { ...base, options: [
          ...catalog.map(tool => ({ value: tool.name, label: tool.name, ...(tool.description ? { detail: firstSentence(tool.description) } : {}), resource: tool.resource })),
          ...missing.map(name => ({ value: name, label: name, disabledReason: "Not available here" })),
        ] };
      }
      default:
        throw new GatewayError("unsupported", `${name} is not a settings option source`);
    }
  }

  /** The registered model a model-qualified option list follows: its `model`
   * qualifier, else the target's resolved chat model (doc 7.5). */
  private async followedModel(runtime: ModelRuntime, qualifiers: Qualifiers | undefined, resolve: (keys: readonly string[]) => Promise<Resolution>): Promise<Model<any> | undefined> {
    if (qualifiers?.model !== undefined) {
      const ref = parseContextModelKey(qualifiers.model);
      return runtime.getModel(ref.provider, ref.id);
    }
    const resolution = await resolve(["model.ref[role=chat]"]);
    const chat = resolution.keys.find(key => key.key === "model.ref[role=chat]")?.value as ModelRefValue | undefined;
    return chat ? runtime.getModel(chat.provider, chat.id) : undefined;
  }

  private async catalogModelOptions(runtime: ModelRuntime, request: SettingsOptionsRequest, physicalOnly: boolean): Promise<Pick<SettingsOptionsResult, "options" | "nextCursor">> {
    const models = (await catalogModelEntries(runtime)).filter(model => !physicalOnly || !model.virtual);
    const query = request.query?.toLowerCase();
    const matching = query ? models.filter(model => [model.name, model.id, model.provider].some(field => field.toLowerCase().includes(query))) : models;
    const offset = request.cursor === undefined ? 0 : catalogCursorOffset(request.cursor);
    const limit = request.limit ?? 50;
    return {
      options: matching.slice(offset, offset + limit).map(model => ({
        value: { provider: model.provider, id: model.id }, label: model.name, detail: model.provider,
        ...(model.available ? {} : { disabledReason: "Not available for this account" }),
      })),
      ...(offset + limit < matching.length ? { nextCursor: String(offset + limit) } : {}),
    };
  }

  async stores(target: SettingsTarget, session?: SessionSettingsSource, options: { storeState?: boolean } = {}): Promise<SettingsStores> {
    const storeState = options.storeState !== false;
    if (target.kind === "session" && !session) throw new GatewayError("invalid_request", "A session target needs its session");
    const cwd = target.kind === "project" ? target.cwd : target.kind === "session" && !session!.home ? session!.cwd : undefined;
    // The Project store is `.pi/` at the chat's Project root (decision 31), the
    // `projectDir` Tron gives pi; trust names that root for every chat in it.
    const inspection = cwd === undefined ? undefined : await stage("settings.store.trust-inspection", () => this.dependencies.trust.inspect(cwd));
    const observed: ObservedStore[] = [{ kind: "global" }, { kind: "trust" }, { kind: "mcp" }, { kind: "models" },
      ...(inspection ? projectStores(inspection.projectDir) : [])];
    // Every read compares the stores with what Tron last observed first (F2):
    // file events are only prompts, so a dropped event cannot hide a change.
    // One repository read serves both the comparison and the git-state badges.
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
    const macTerminal = this.dependencies.macTerminalKeys
      ? await stage("settings.store.mac-terminal-keys", () => this.dependencies.macTerminalKeys!.read())
      : {};
    return {
      layers,
      global,
      trust,
      macTerminal,
      macTerminalServerEnabled: await this.macTerminalKeys?.enabled() ?? false,
      floors: await stage("settings.store.floors", () => this.floorOverrides()),
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

  async applyStore(bundleTarget: SettingsTarget, stores: SettingsStores, plan: Planned, value: unknown, bundleContext: ChangeContext, writers: Pick<SettingsWriters, "setTrust">): Promise<{ revision?: number; git?: GitResult; result?: unknown }> {
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
        if (plan.request.layer === "project") {
          const { git } = await writeProjectSettings(stores.project!.root, write);
          return { git };
        }
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
      case "trust":
        return { result: await writers.setTrust(qualifiers.project!, unset ? null : value as boolean) };
      case "floors":
        await updateJsonLocked<Record<string, Record<string, Tier>>>(this.floorsPath, {}, document => {
          const entry = { ...(document[qualifiers.key!] ?? {}) };
          // A key with one floor keeps both directions equal.
          for (const direction of qualifiers.direction ? [qualifiers.direction] : ["widen", "narrow"]) {
            if (unset) delete entry[direction]; else entry[direction] = value as Tier;
          }
          if (Object.keys(entry).length === 0) delete document[qualifiers.key!]; else document[qualifiers.key!] = entry;
          return document;
        });
        return {};
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
        return { revision: await context.session.appliers.setSetting(plan.key.id, value, context.actor.kind === "ui" || context.approved === true, plan.fixedAt) };
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

  /** A Tron-owned store's declared fields, each admitted by its key's type. */
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

  /** pi's own reader, so migrations and parse rules match the runtime exactly. */
  private piDocuments(cwd: string): { global: Record<string, unknown>; project: Record<string, unknown>; projectUnreadable?: true } {
    const manager = SettingsManager.create(cwd, this.dependencies.agentDir, { projectTrusted: true });
    const errors = manager.drainErrors();
    if (errors.some(error => error.scope === "global")) throw new GatewayError("conflict", "Canonical settings could not be loaded");
    // An unparseable project file (unresolved merge markers) is an empty, unreadable
    // layer: it is reported, and a write to it fails without touching it (doc 5.7).
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

  private async floorOverrides(): Promise<FloorOverrides> {
    const document = await readJsonObject(this.floorsPath);
    const result: FloorOverrides = {};
    for (const [key, value] of Object.entries(document)) {
      if (!value || typeof value !== "object" || Array.isArray(value)) continue;
      const entry: { widen?: Tier; narrow?: Tier } = {};
      for (const direction of ["widen", "narrow"] as const) {
        const tier = (value as Record<string, unknown>)[direction];
        if (typeof tier === "string" && (TIERS as readonly string[]).includes(tier)) entry[direction] = tier as Tier;
      }
      result[key] = entry;
    }
    return result;
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

/** A JSON store's text, or undefined when the store does not exist yet. */
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

/** A tool's description as one option line. */
function firstSentence(text: string): string {
  const line = text.trim().split("\n")[0]!;
  const end = line.search(/[.!?](\s|$)/);
  return end === -1 ? line : line.slice(0, end + 1);
}

/** The registered models as the model picker lists them: the display name, and
 * whether this account can use each one (the same test `model.list` applies). */
async function catalogModelEntries(runtime: ModelRuntime): Promise<Array<{ provider: string; id: string; name: string; available: boolean; virtual: boolean }>> {
  const eligibility = openAIModelEligibility(runtime);
  await eligibility?.refresh();
  const providerIds = new Set(runtime.getModels().map(model => model.provider));
  const available = new Set((await Promise.all([...providerIds].map(async providerId => {
    try { return await runtime.getAvailable(providerId); }
    catch { return []; }
  }))).flat().map(model => `${model.provider}\0${model.id}`));
  const projected = runtime.getModels().map(model => ({
    provider: model.provider, id: model.id, virtual: isVirtualModel(model),
    name: eligibility?.displayName(model.provider, model.id) ?? model.name,
    available: available.has(`${model.provider}\0${model.id}`) && (eligibility?.isEligibleInRuntime(runtime, model.provider, model.id) ?? true),
  }));
  return eligibility?.orderAccountModels(projected) ?? projected;
}

/** The catalog cursor is the offset of the next page, as a decimal string. */
function catalogCursorOffset(cursor: string): number {
  if (!/^(0|[1-9][0-9]{0,8})$/u.test(cursor)) throw new GatewayError("invalid_request", "Invalid settings options cursor");
  return Number(cursor);
}

/** Named option sources (doc 4.1 `optionsSource`). Capability clamping uses
 * pi's own `clampThinkingLevel`, so this names existing behaviour (doc 3.6). */
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

/** The model a context window's bounds come from: the registered model, never a
 * session's budgeted copy (SessionContextWindowPolicy wraps a session runtime's
 * `getModel` with the chat's current window, which would shrink the maximum to it). */
function limitsModel(runtime: ModelRuntime, ref: { provider: string; id: string }): Model<any> | undefined {
  return runtime.getPhysicalModel(ref.provider, ref.id) ?? runtime.getModel(ref.provider, ref.id);
}

function contextWindowValue(runtime: ModelRuntime, qualifier: string | undefined, value: unknown): number {
  const ref = qualifier ? parseContextModelKey(qualifier) : undefined;
  const model = ref && limitsModel(runtime, ref);
  if (!model) throw new GatewayError("not_found", "Context window model is not registered in Tron");
  return validateContextWindow(value, contextWindowLimits(model));
}
