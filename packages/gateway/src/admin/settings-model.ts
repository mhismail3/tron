import { createHash, randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { clampThinkingLevel, getSupportedThinkingLevels, type Model, type ThinkingLevel } from "@earendil-works/pi-ai";
import { SettingsManager, type ModelRuntime } from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import { contextWindowLimits, parseContextModelKey, validateContextWindow } from "../providers/context-window-policy.js";
import { assertNewModelChoice } from "../providers/openai-model-eligibility.js";
import { isVirtualModel } from "../providers/virtual-model.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { updateJsonLocked } from "../util/json.js";
import { writeProjectSettings } from "./project-settings-writer.js";
import type { TrustService } from "./trust-service.js";
import type { Actor, ChangeEntry, ChangeStatus, GitResult, SettingsChangeRecord, TierBasis } from "./settings-record.js";
import { readBinding, resolveSettings, targetLayers, type ChatStore, type OptionSources, type Resolution, type SettingsStores, type SettingsTarget } from "./settings-resolver.js";
import { floorFor, schemaKey, type Binding, type KeyDeclaration } from "./settings-schema.js";
import { LAYER_LABELS, type FormatContext, type LayerId, type ModelRefValue, type Qualifiers, type Tier } from "./settings-types.js";

/** What a session target contributes: its Chat layer and whether it is Home's chat. */
export interface SessionSettingsSource {
  cwd: string;
  home: boolean;
  chat: ChatStore;
  modelRuntime: ModelRuntime;
}

export interface SettingsModelDependencies {
  agentDir: string;
  tronHome: string;
  trust: Pick<TrustService, "inspect" | "canonicalDirectory">;
  modelRuntime: ModelRuntime;
  /** The Home record's memory model; Home owns it (doc 6.1). */
  homeMemoryModel?: () => Promise<{ provider: string; id: string } | undefined>;
}

/**
 * The settings model's read side: loads each store a target's layers read,
 * from its owner, and resolves (docs/settings-model.md section 3).
 * Reading an untrusted project's `.pi/settings.json` is pure JSON parsing.
 */
export class SettingsModel {
  constructor(private readonly dependencies: SettingsModelDependencies) {}

  get modelRuntime(): ModelRuntime { return this.dependencies.modelRuntime; }

  get profilePath(): string {
    return join(this.dependencies.tronHome, "gateway", "home", "profile.json");
  }

  async resolve(target: SettingsTarget, session?: SessionSettingsSource, keys?: readonly string[]): Promise<Resolution> {
    const stores = await this.stores(target, session);
    const runtime = session?.modelRuntime ?? this.dependencies.modelRuntime;
    return resolveSettings(target, stores, { format: formatContext(runtime), options: optionSources(runtime), ...(keys ? { keys } : {}) });
  }

  async stores(target: SettingsTarget, session?: SessionSettingsSource): Promise<SettingsStores> {
    if (target.kind === "session" && !session) throw new GatewayError("invalid_request", "A session target needs its session");
    const mac = this.piDocuments(this.dependencies.agentDir).global;
    const trust = await this.trustDecisions();
    let project: SettingsStores["project"];
    const cwd = target.kind === "project" ? target.cwd : target.kind === "session" && !session!.home ? session!.cwd : undefined;
    if (cwd !== undefined) {
      // The Project store is `.pi/` at the cwd Tron gives pi, which is where pi
      // reads it (pi settings-manager has no upward search).
      const inspection = await this.dependencies.trust.inspect(cwd);
      const documents = this.piDocuments(inspection.cwd);
      project = {
        root: inspection.cwd,
        document: documents.project,
        ...(documents.projectUnreadable ? { unreadable: true as const } : {}),
        applied: inspection.effectiveDecision === true,
        ...(inspection.effectiveDecision === true ? {} : { reason: "untrusted" as const }),
      };
    }
    const home = target.kind === "home" || (target.kind === "session" && session!.home);
    const layers = targetLayers(target, { home, project: project !== undefined });
    return {
      layers,
      mac,
      trust,
      ...(project ? { project } : {}),
      ...(session ? { chat: session.chat } : {}),
      ...(home ? { profile: await readJsonObject(this.profilePath) } : {}),
      ...(home && this.dependencies.homeMemoryModel ? await this.homeMemory() : {}),
    };
  }

  private async homeMemory(): Promise<{ homeMemory?: { provider: string; id: string } }> {
    const model = await this.dependencies.homeMemoryModel!();
    return model ? { homeMemory: model } : {};
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

  private async trustDecisions(): Promise<Record<string, boolean>> {
    const document = await readJsonObject(join(this.dependencies.agentDir, "trust.json"));
    const result: Record<string, boolean> = {};
    for (const [path, decision] of Object.entries(document)) {
      if (typeof decision === "boolean") result[path] = decision;
    }
    return result;
  }
}

async function readJsonObject(path: string): Promise<Record<string, unknown>> {
  let raw: string;
  try {
    raw = await readFile(path, "utf8");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return {};
    throw error;
  }
  try {
    const value = JSON.parse(raw.replace(/^\uFEFF/u, "")) as unknown;
    return typeof value === "object" && value !== null && !Array.isArray(value) ? value as Record<string, unknown> : {};
  } catch {
    throw new GatewayError("conflict", "A settings store could not be parsed");
  }
}

export function formatContext(runtime: ModelRuntime): FormatContext {
  return { modelName: (ref) => runtime.getModel(ref.provider, ref.id)?.name };
}

/** Named option sources (doc 4.1 `optionsSource`). Capability clamping uses
 * pi's own `clampThinkingLevel`, so this names existing behaviour (doc 3.6). */
export function optionSources(runtime: ModelRuntime): OptionSources {
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

// ---------------------------------------------------------------------------
// The one change path (docs/settings-model.md 5.1-5.3, foundation F2/F3).
// ---------------------------------------------------------------------------

export type WritableLayer = Exclude<LayerId, "builtin">;

export interface ChangeRequest {
  key: string;
  qualifiers?: Qualifiers;
  layer: WritableLayer;
  op: "set" | "unset";
  value?: unknown;
  /** The value the actor read at this layer; `null` means unset. Omitted skips the check. */
  expected?: unknown;
}

/** The Chat layer's appliers: the session's slot-lane setters, whose lane
 * guards (idle configuration, chapter writability, runtime fence) stay. */
export interface ChatAppliers {
  setModel(ref: ModelRefValue): Promise<number>;
  setThinking(level: string): Promise<number>;
  setContextWindow(model: ModelRefValue, value: number | null): Promise<number>;
  setTools(tools: string[]): Promise<void>;
}

export interface ChangeContext {
  actor: Actor;
  reason?: string;
  commandId?: string;
  dryRun?: boolean;
  session?: SessionSettingsSource & { appliers: ChatAppliers };
  undoOf?: string;
  applyAgainOf?: string;
}

export interface ChangeOutcome {
  changeId: string;
  key: string;
  qualifiers?: Qualifiers;
  layer: WritableLayer;
  status: ChangeStatus;
  tier: Tier;
  revision?: number;
  git?: GitResult;
  /** The store's resulting state when its applier reports one (trust's inspection). */
  result?: unknown;
  error?: { code: string; message: string };
}

export interface SettingsWriters {
  /** Trust's applier: TrustService.setAndApply with the runtime reload. Returns
   * the resulting trust inspection, which the change outcome carries. */
  setTrust(project: string, decision: boolean | null): Promise<unknown>;
  /** Home memory's applier: HomeOwner (doc 6.1). */
  configureHomeMemory?(model: ModelRefValue): Promise<void>;
}

interface Planned {
  request: ChangeRequest;
  key: KeyDeclaration;
  binding: Binding;
  qualifiers: Qualifiers;
  before: unknown;
  after: unknown;
  tier: Tier;
  basis: TierBasis;
  changeId: string;
}

const deepEqual = (left: unknown, right: unknown) => JSON.stringify(left ?? null) === JSON.stringify(right ?? null);

/** Applier order across stores (doc 5.2): fixed, so rollback is the reverse. */
const STORE_ORDER: Record<Binding["store"], number> = {
  "pi": 0, "pi-model-ref": 0, "trust": 1, "home-memory": 2, "profile": 3, "floors": 4, "chat": 5, "chat-settings": 5,
};

export class SettingsChangePath {
  /** Changes serialize per target (in a bounded set of stripes), so distinct
   * sessions change concurrently; each store's applier holds its own lock too. */
  private readonly stripes = Array.from({ length: 32 }, () => new AsyncMutex());

  private mutexFor(target: SettingsTarget): AsyncMutex {
    const id = target.kind === "session" ? `session:${target.sessionId}` : target.kind === "project" ? `project:${target.cwd}` : target.kind;
    const hash = createHash("sha256").update(id).digest().readUInt32BE(0);
    return this.stripes[hash % this.stripes.length]!;
  }

  constructor(
    private readonly model: SettingsModel,
    readonly record: SettingsChangeRecord,
    private readonly writers: SettingsWriters,
    private readonly agentDir: string,
    private readonly now: () => Date = () => new Date(),
  ) {}

  async change(target: SettingsTarget, requests: readonly ChangeRequest[], context: ChangeContext): Promise<{ dryRun?: true; status: ChangeStatus; changes: ChangeOutcome[] }> {
    if (requests.length === 0 || requests.length > 50) throw new GatewayError("invalid_request", "A settings change holds 1 to 50 changes");
    if (context.actor.kind !== "ui" && !context.reason?.trim()) throw new GatewayError("invalid_request", "A reason is required for a change not made from the iPhone");
    return this.mutexFor(target).run(async () => {
      const stores = await this.model.stores(target, context.session);
      const runtime = context.session?.modelRuntime ?? this.model.modelRuntime;
      const planned: Planned[] = [];
      const errors = new Map<number, GatewayError>();
      for (const [index, request] of requests.entries()) {
        try {
          planned.push(await this.plan(target, stores, request, context, runtime));
        } catch (error) {
          if (!context.dryRun) throw error;
          errors.set(index, error instanceof GatewayError ? error : new GatewayError("invalid_request", String(error)));
        }
      }
      if (context.dryRun) {
        let next = 0;
        return {
          dryRun: true as const, status: "applied" as const,
          changes: requests.map((request, index) => {
            const error = errors.get(index);
            if (error) return { changeId: "", key: request.key, layer: request.layer, status: "failed" as const, tier: "quiet" as const, error: { code: error.code, message: error.message } };
            const plan = planned[next++]!;
            return { changeId: "", key: plan.key.id, ...(Object.keys(plan.qualifiers).length ? { qualifiers: plan.qualifiers } : {}), layer: request.layer, status: "applied" as const, tier: plan.tier };
          }),
        };
      }
      const ordered = [...planned].sort((a, b) => STORE_ORDER[a.binding.store] - STORE_ORDER[b.binding.store]);
      const applied: Array<{ plan: Planned; revision?: number; git?: GitResult; result?: unknown }> = [];
      let failure: { plan: Planned; error: GatewayError } | undefined;
      for (const plan of ordered) {
        try {
          const result = await this.apply(target, stores, plan, plan.after, context);
          applied.push({ plan, ...result });
        } catch (error) {
          failure = { plan, error: error instanceof GatewayError ? error : new GatewayError("internal", error instanceof Error ? error.message : String(error)) };
          break;
        }
      }
      if (failure) {
        // Roll back the stores already changed, newest first (doc 5.2).
        for (const done of [...applied].reverse()) {
          await this.apply(target, stores, done.plan, done.plan.before, context).catch(() => undefined);
        }
        await this.record.append(ordered.map(plan => this.entry(target, plan, context, "failed",
          plan === failure!.plan ? failure!.error.message : "Rolled back: another change in the same request failed")));
        throw failure.error;
      }
      await this.record.append(applied.map(done => this.entry(target, done.plan, context, "applied", undefined, done.git)));
      return {
        status: "applied" as const,
        changes: applied.map(({ plan, revision, git, result }) => ({
          changeId: plan.changeId, key: plan.key.id, ...(Object.keys(plan.qualifiers).length ? { qualifiers: plan.qualifiers } : {}),
          layer: plan.request.layer, status: "applied" as const, tier: plan.tier,
          ...(revision === undefined ? {} : { revision }), ...(git ? { git } : {}),
          ...(result === undefined ? {} : { result }),
        })),
      };
    });
  }

  /** Undo writes `before` back; refused when the store no longer holds `after` (doc 5.3). */
  async undo(changeId: string, context: Omit<ChangeContext, "undoOf">, session?: ChangeContext["session"]) {
    const found = await this.record.entry(changeId);
    if (!found) throw new GatewayError("not_found", "No such settings change");
    const { entry } = found;
    if (entry.redacted) throw new GatewayError("conflict", "This change is not undoable: its previous value was never recorded");
    if (entry.status !== "applied" && entry.status !== "approved") throw new GatewayError("conflict", "Only an applied change can be undone");
    const key = schemaKey(entry.key);
    const stores = await this.model.stores(entry.target, session);
    const binding = key.layers[entry.layer]!;
    const current = readBinding(stores, entry.layer, binding, entry.qualifiers ?? {}, qualifiedWrite(binding, entry.qualifiers ?? {}));
    if (!deepEqual(current, entry.after)) {
      throw new GatewayError("conflict", "The setting changed since; undo would overwrite a newer value", false,
        { current: (current ?? null) as never, after: (entry.after ?? null) as never });
    }
    return this.change(entry.target, [{
      key: entry.key, ...(entry.qualifiers ? { qualifiers: entry.qualifiers } : {}), layer: entry.layer,
      op: entry.before === undefined ? "unset" : "set", ...(entry.before === undefined ? {} : { value: entry.before }),
    }], { ...context, undoOf: changeId, ...(session ? { session } : {}) });
  }

  history(input: { cursor?: string; limit?: number; key?: string; status?: string }) {
    return this.record.page({
      ...(input.cursor ? { cursor: input.cursor } : {}), ...(input.limit ? { limit: input.limit } : {}),
      filter: entry => (!input.key || entry.key === input.key) && (!input.status || entry.status === input.status),
    });
  }

  private async plan(target: SettingsTarget, stores: SettingsStores, request: ChangeRequest, context: ChangeContext, runtime: ModelRuntime): Promise<Planned> {
    const key = schemaKey(request.key);
    const binding = key.layers[request.layer];
    if (!binding) throw new GatewayError("invalid_request", `${key.label} cannot be set at the ${LAYER_LABELS[request.layer]} layer`);
    if (!stores.layers.includes(request.layer)) throw new GatewayError("invalid_request", `This target has no ${LAYER_LABELS[request.layer]} layer`);
    const writer = context.actor.kind === "outside" ? undefined : context.actor.kind;
    if (!writer || !key.writers.includes(writer)) throw new GatewayError("invalid_request", `${key.label} cannot be changed by ${context.actor.kind}`);
    if (request.layer === "project" && stores.project && !stores.project.applied) {
      throw new GatewayError("trust_required", "Trust this project before changing its project settings");
    }
    const qualifiers: Qualifiers = { ...(key.fixed ?? {}), ...(request.qualifiers ?? {}) };
    // A project or chat target names its own project; only the Mac target
    // takes a project qualifier from the request (its canonical path).
    if (key.qualifier === "project" && target.kind !== "mac" && stores.project) {
      if (request.qualifiers?.project !== undefined && request.qualifiers.project !== stores.project.root) {
        throw new GatewayError("invalid_request", `${key.label} for another project belongs to that project's target`);
      }
      qualifiers.project = stores.project.root;
    }
    if (key.qualifier === "project" && !qualifiers.project) throw new GatewayError("invalid_request", `${key.label} needs a project`);
    if (bindingNeedsModel(binding) && !qualifiers.model) {
      const chatModel = stores.chat?.model;
      if (request.layer === "chat" && chatModel) qualifiers.model = `${chatModel.provider}/${chatModel.id}`;
      else throw new GatewayError("invalid_request", `${key.label} needs a model qualifier`);
    }
    if (binding.store === "chat-settings" || binding.store === "profile" || binding.store === "floors") {
      throw new GatewayError("unsupported", `${key.label} has no writable ${LAYER_LABELS[request.layer]} store yet`);
    }
    let after: unknown;
    if (request.op === "set") {
      after = await key.type.validate(request.value, key.id, { admitModel: (ref) => this.admitModel(runtime, ref) });
      if (key.optionsSource?.name === "catalog.contextWindow") after = contextWindowValue(runtime, qualifiers.model, after);
    } else if (request.op !== "unset") {
      throw new GatewayError("invalid_request", "op must be set or unset");
    }
    if (request.op === "unset" && binding.store === "chat" && binding.field !== "contextWindow") {
      throw new GatewayError("invalid_request", `${key.label} always has a Chat value; set another value instead`);
    }
    const before = readBinding(stores, request.layer, binding, qualifiers, qualifiedWrite(binding, qualifiers));
    if (request.expected !== undefined && binding.store !== "chat" && !deepEqual(request.expected, before)) {
      throw new GatewayError("conflict", `${key.label} changed since it was read; refresh and try again`, false, { current: (before ?? null) as never });
    }
    const direction = key.direction ? key.direction(before ?? key.builtin, after ?? key.builtin) : "widen";
    const floor = floorFor(key, direction);
    return {
      request, key, binding, qualifiers, before, after,
      tier: floor, basis: { direction, floor, floorSource: "code", web: false, risk: null },
      changeId: randomUUID(),
    };
  }

  private async admitModel(runtime: ModelRuntime, ref: ModelRefValue): Promise<void> {
    if (!runtime.getModel(ref.provider, ref.id)) throw new GatewayError("not_found", "Model is not registered in Tron");
    await assertNewModelChoice(runtime, ref.provider, ref.id);
  }

  private async apply(target: SettingsTarget, stores: SettingsStores, plan: Planned, value: unknown, context: ChangeContext): Promise<{ revision?: number; git?: GitResult; result?: unknown }> {
    const { binding, qualifiers } = plan;
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
        await updateJsonLocked<Record<string, unknown>>(join(this.agentDir, "settings.json"), {}, write);
        return {};
      }
      case "trust":
        return { result: await this.writers.setTrust(qualifiers.project!, unset ? null : value as boolean) };
      case "home-memory":
        if (!this.writers.configureHomeMemory) throw new GatewayError("unsupported", "Home is not available");
        if (unset) throw new GatewayError("invalid_request", "The memory model cannot be unset");
        {
          // Home's memory runs one fixed physical model (home.md).
          const ref = value as ModelRefValue;
          const registered = (context.session?.modelRuntime ?? this.model.modelRuntime).getModel(ref.provider, ref.id);
          if (registered && isVirtualModel(registered)) {
            throw new GatewayError("invalid_request", "Tron Home requires a fixed physical model; virtual models are not supported");
          }
          await this.writers.configureHomeMemory(ref);
        }
        return {};
      case "chat": {
        const appliers = context.session?.appliers;
        if (!appliers || target.kind !== "session") throw new GatewayError("invalid_request", "A Chat-layer change needs its open session");
        if (binding.field === "model") return { revision: await appliers.setModel(value as ModelRefValue) };
        if (binding.field === "thinking") return { revision: await appliers.setThinking(value as string) };
        if (binding.field === "tools") { await appliers.setTools(value as string[]); return {}; }
        const [provider, ...id] = qualifiers.model!.split("/");
        return { revision: await appliers.setContextWindow({ provider: provider!, id: id.join("/") }, unset ? null : value as number) };
      }
      default:
        throw new GatewayError("unsupported", "This store has no applier yet");
    }
  }

  private entry(target: SettingsTarget, plan: Planned, context: ChangeContext, status: ChangeStatus, failure?: string, git?: GitResult): ChangeEntry {
    const redacted = plan.key.redacted === true;
    return {
      changeId: plan.changeId, at: this.now().toISOString(),
      ...(context.commandId ? { commandId: context.commandId } : {}),
      actor: context.actor, target, layer: plan.request.layer, key: plan.key.id,
      ...(Object.keys(plan.qualifiers).length ? { qualifiers: plan.qualifiers } : {}),
      op: plan.request.op,
      ...(redacted ? { changed: true as const, redacted: true as const } : {
        ...(plan.before === undefined ? {} : { before: plan.before }),
        ...(plan.after === undefined ? {} : { after: plan.after }),
      }),
      ...(context.reason ? { reason: context.reason } : {}),
      tier: plan.tier, tierBasis: plan.basis, status,
      ...(failure ? { failure } : {}), ...(git ? { git } : {}),
      ...(context.undoOf ? { undoOf: context.undoOf } : {}),
      ...(context.applyAgainOf ? { applyAgainOf: context.applyAgainOf } : {}),
    };
  }
}

function bindingNeedsModel(binding: Binding): boolean {
  return (binding.store === "pi" && binding.path.includes("{model}")) || (binding.store === "chat" && binding.field === "contextWindow");
}

/** A change qualified by model writes the binding's per-model path when it has one. */
function qualifiedWrite(binding: Binding, qualifiers: Qualifiers): boolean {
  return binding.store === "pi" && binding.qualified !== undefined && qualifiers.model !== undefined;
}

function fillPath(path: readonly string[], qualifiers: Qualifiers): string[] {
  return path.map(segment => segment === "{model}" ? qualifiers.model! : segment);
}

function setPath(document: Record<string, unknown>, path: readonly string[], value: unknown): void {
  let current = document;
  for (const segment of path.slice(0, -1)) {
    const child = current[segment];
    current = current[segment] = child && typeof child === "object" && !Array.isArray(child) ? child as Record<string, unknown> : {};
  }
  current[path[path.length - 1]!] = value;
}

/** Unset a value and drop parents it leaves empty. */
function unsetPath(document: Record<string, unknown>, path: readonly string[]): void {
  const parents: Array<Record<string, unknown>> = [];
  let current: unknown = document;
  for (const segment of path.slice(0, -1)) {
    if (!current || typeof current !== "object") return;
    parents.push(current as Record<string, unknown>);
    current = (current as Record<string, unknown>)[segment];
  }
  if (!current || typeof current !== "object") return;
  delete (current as Record<string, unknown>)[path[path.length - 1]!];
  for (let index = parents.length - 1; index >= 0; index -= 1) {
    const child = parents[index]![path[index]!];
    if (child && typeof child === "object" && Object.keys(child).length === 0) delete parents[index]![path[index]!];
  }
}

function contextWindowValue(runtime: ModelRuntime, qualifier: string | undefined, value: unknown): number {
  const ref = qualifier ? parseContextModelKey(qualifier) : undefined;
  const model = ref && runtime.getModel(ref.provider, ref.id);
  if (!model) throw new GatewayError("not_found", "Context window model is not registered in Tron");
  return validateContextWindow(value, contextWindowLimits(model));
}
