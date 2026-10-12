import { createHash, randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { clampThinkingLevel, getSupportedThinkingLevels, type Model, type ThinkingLevel } from "@earendil-works/pi-ai";
import { SettingsManager, type ModelRuntime } from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import { contextWindowLimits, parseContextModelKey, validateContextWindow } from "../providers/context-window-policy.js";
import { assertNewModelChoice, openAIModelEligibility } from "../providers/openai-model-eligibility.js";
import { isVirtualModel } from "../providers/virtual-model.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { updateJsonLocked } from "../util/json.js";
import { writeProjectSettings } from "./project-settings-writer.js";
import type { TrustService } from "./trust-service.js";
import type { Actor, ChangeEntry, ChangeStatus, GitResult, SettingsChangeRecord, TierBasis } from "./settings-record.js";
import type { ApprovalRequest, PendingChange, SettingsApprovals } from "./settings-approvals.js";
import { readBinding, resolveSettings, targetLayers, type ChatStore, type FixedSetting, type OptionSources, type Resolution, type SettingsStores, type SettingsTarget } from "./settings-resolver.js";
import { KEYS, builtinValue, floorFor, floorInstances, hasRuntimeRequestApplier, schemaKey, timingFor, type Binding, type FloorOverrides, type KeyDeclaration } from "./settings-schema.js";
import { LAYER_LABELS, TIERS, maxTier, raiseTier, type FormatContext, type LayerId, type ModelRefValue, type Qualifiers, type Tier } from "./settings-types.js";

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

  /** The maintainer's floor overrides (doc 5.4); only the change path writes it. */
  get floorsPath(): string {
    return join(this.dependencies.tronHome, "gateway", "settings", "floors.json");
  }

  async resolve(target: SettingsTarget, session?: SessionSettingsSource, keys?: readonly string[]): Promise<Resolution> {
    const stores = await this.stores(target, session);
    const runtime = session?.modelRuntime ?? this.dependencies.modelRuntime;
    return resolveSettings(target, stores, { format: formatContext(runtime), options: optionSources(runtime), ...(keys ? { keys } : {}) });
  }

  /** Resolve operational defaults at a request boundary, never by reloading the
   * whole SDK manager (which would also change fixed resource/shell settings).
   * Absence is meaningful for optional provider fields: the request boundary
   * replaces them after the SDK has composed its initial defaults. */
  async requestSettings(sessionId: string, session: SessionSettingsSource, previousPins: Record<string, FixedSetting>): Promise<{
    settings: ReturnType<SettingsManager["getSettings"]>; requestPins: Record<string, FixedSetting>;
  }> {
    const keys = KEYS.filter(hasRuntimeRequestApplier);
    const resolved = await this.resolve({ kind: "session", sessionId }, session, keys.map(key => key.id));
    const settings: Record<string, unknown> = {};
    const requestPins = structuredClone(previousPins);
    for (const row of resolved.keys) {
      const key = schemaKey(row.key);
      const binding = key.layers.chat;
      if (binding?.store !== "chat-settings") continue;
      let value = row.value;
      if (typeof key.timing !== "string") {
        const previous = previousPins[key.id];
        if (previous && key.direction && timingFor(key, key.direction(previous.value, value)) === "fixed") value = previous.value;
        if (!previous || !deepEqual(previous.value, value)) requestPins[key.id] = {
          value, from: row.layer, at: new Date().toISOString(), ref: randomUUID(), ...(row.qualifiers ? { qualifiers: row.qualifiers } : {}),
        };
      }
      if (value !== undefined) setPath(settings, binding.path, await key.type.validate(value, key.id));
    }
    return { settings, requestPins };
  }

  /** `settings.options` (docs/settings-model.md 7.5): the choices a key's control offers. */
  async options(target: SettingsTarget, session: SessionSettingsSource | undefined, request: SettingsOptionsRequest): Promise<SettingsOptionsResult> {
    const key = KEYS.find(candidate => candidate.id === request.key);
    if (!key) throw new GatewayError("invalid_request", `Unknown setting ${request.key}`);
    if (!key.optionsSource) {
      if (!key.type.options) throw new GatewayError("invalid_request", `${key.label} has no options to choose from`);
      return { key: key.id, source: "static", dependsOn: [], options: key.type.options.map(option => ({ value: option.value, label: option.label })) };
    }
    const { name, dependsOn } = key.optionsSource;
    const runtime = session?.modelRuntime ?? this.dependencies.modelRuntime;
    const base = { key: key.id, source: name, dependsOn: [...dependsOn] };
    switch (name) {
      case "catalog.models":
        return { ...base, ...await this.catalogModelOptions(runtime, request) };
      case "catalog.thinkingLevels": {
        const model = await this.followedModel(target, session, runtime, request.qualifiers);
        const supported = model ? getSupportedThinkingLevels(model) : [];
        // pi reports only "off" for a model without reasoning: there is no level to offer.
        const levels = supported.length === 1 && supported[0] === "off" ? [] : supported;
        const labels = new Map(schemaKey("model.thinking[role=chat]").type.options!.map(option => [option.value, option.label]));
        return { ...base, options: levels.map(level => ({ value: level, label: labels.get(level) ?? level })) };
      }
      case "catalog.contextWindow": {
        // The bounds `settings.change` validates the value against (contextWindowValue).
        const model = await this.followedModel(target, session, runtime, request.qualifiers);
        const limits = model && contextWindowLimits(model);
        return { ...base, options: [], ...(limits ? { range: { min: limits.minimum, max: limits.maximum, unit: "tokens" as const } } : {}) };
      }
      default:
        throw new GatewayError("unsupported", `${name} is not a settings option source`);
    }
  }

  /** The registered model a model-qualified option list follows: its `model`
   * qualifier, else the target's resolved chat model (doc 7.5). */
  private async followedModel(target: SettingsTarget, session: SessionSettingsSource | undefined, runtime: ModelRuntime, qualifiers: Qualifiers | undefined): Promise<Model<any> | undefined> {
    if (qualifiers?.model !== undefined) {
      const ref = parseContextModelKey(qualifiers.model);
      return runtime.getModel(ref.provider, ref.id);
    }
    const resolution = await this.resolve(target, session, ["model.ref[role=chat]"]);
    const chat = resolution.keys.find(key => key.key === "model.ref[role=chat]")?.value as ModelRefValue | undefined;
    return chat ? runtime.getModel(chat.provider, chat.id) : undefined;
  }

  private async catalogModelOptions(runtime: ModelRuntime, request: SettingsOptionsRequest): Promise<Pick<SettingsOptionsResult, "options" | "nextCursor">> {
    const models = await catalogModelEntries(runtime);
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
      floors: await this.floorOverrides(),
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

export interface SettingsOptionsRequest {
  key: string;
  qualifiers?: Qualifiers;
  query?: string;
  cursor?: string;
  limit?: number;
}

export interface SettingsOption { value: unknown; label: string; detail?: string; disabledReason?: string }

export interface SettingsOptionsResult {
  key: string;
  /** The key's option source, or `static` for its declared choices. */
  source: string;
  dependsOn: string[];
  options: SettingsOption[];
  range?: { min: number; max: number; unit: "tokens" };
  /** An opaque cursor for the next page of a catalog. */
  nextCursor?: string;
}

/** The registered models as the model picker lists them: the display name, and
 * whether this account can use each one (the same test `model.list` applies). */
async function catalogModelEntries(runtime: ModelRuntime): Promise<Array<{ provider: string; id: string; name: string; available: boolean }>> {
  const eligibility = openAIModelEligibility(runtime);
  await eligibility?.refresh();
  const providerIds = new Set(runtime.getModels().map(model => model.provider));
  const available = new Set((await Promise.all([...providerIds].map(async providerId => {
    try { return await runtime.getAvailable(providerId); }
    catch { return []; }
  }))).flat().map(model => `${model.provider}\0${model.id}`));
  const projected = runtime.getModels().map(model => ({
    provider: model.provider, id: model.id,
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
  setModel(ref: ModelRefValue, fixedAt?: FixedSetting): Promise<number>;
  setThinking(level: string, fixedAt?: FixedSetting): Promise<number>;
  setContextWindow(model: ModelRefValue, value: number | null, fixedAt?: FixedSetting): Promise<number>;
  setTools(tools: string[], fixedAt?: FixedSetting): Promise<void>;
  setSetting(key: string, value: unknown, allowFixedDirection: boolean, fixedAt?: FixedSetting): Promise<number>;
}

export interface ChangeContext {
  actor: Actor;
  reason?: string;
  commandId?: string;
  dryRun?: boolean;
  /** Set only by the approval owner, never accepted from a request payload. */
  approved?: true;
  /** The requesting turn read web or browser content (doc 5.4 input 2). The
   * Gateway sets it from the tool calls it executed; the UI has no turn. */
  web?: boolean;
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
  /** A dry run's: the key's `confirm` text when this change's tier is approve,
   * for the maintainer's row to show before he makes it. */
  confirm?: string;
  /** The store's resulting state when its applier reports one (trust's inspection). */
  result?: unknown;
  error?: { code: string; message: string };
}

export interface ChangeResult {
  dryRun?: true;
  status: ChangeStatus;
  /** The request's tier: the highest of its changes (doc 5.4). */
  tier: Tier;
  changes: ChangeOutcome[];
  /** A pending request: what the maintainer decides and the exact diff it binds to. */
  approval?: { requestId: string; digest: string; expiresAt: string };
}

export interface SettingsWriters {
  /** Trust's applier: TrustService.setAndApply with the runtime reload. Returns
   * the resulting trust inspection, which the change outcome carries. */
  setTrust(project: string, decision: boolean | null): Promise<unknown>;
  /** Home memory's applier: HomeOwner (doc 6.1). */
  configureHomeMemory?(model: ModelRefValue): Promise<void>;
}

/** Who hears about changes once they happen. The Gateway service registers one:
 * after-apply effects and broadcasts, and the maintainer's pushes (doc 5.4, 5.5). */
export interface SettingsObserver {
  applied(target: SettingsTarget, changes: readonly ChangeOutcome[], context: { actor: Actor; tier: Tier; reason?: string; approved?: true }): void | Promise<void>;
  approvals(event: { kind: "pending" | "resolved"; request: ApprovalRequest }): void;
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
  fixedAt?: FixedSetting;
}

const deepEqual = (left: unknown, right: unknown) => JSON.stringify(left ?? null) === JSON.stringify(right ?? null);

/** Applier order across stores (doc 5.2): fixed, so rollback is the reverse. */
const STORE_ORDER: Record<Binding["store"], number> = {
  "pi": 0, "pi-model-ref": 0, "trust": 1, "home-memory": 2, "profile": 3, "floors": 4, "chat": 5, "chat-settings": 5,
};

const DECIDED = new Set<ChangeStatus>(["approved", "declined", "expired", "superseded", "failed"]);

export class SettingsChangePath {
  /** Changes serialize per target (in a bounded set of stripes), so distinct
   * sessions change concurrently; each store's applier holds its own lock too. */
  private readonly stripes = Array.from({ length: 32 }, () => new AsyncMutex());
  private observer: SettingsObserver | undefined;

  private mutexFor(target: SettingsTarget): AsyncMutex {
    const id = target.kind === "session" ? `session:${target.sessionId}` : target.kind === "project" ? `project:${target.cwd}` : target.kind;
    const hash = createHash("sha256").update(id).digest().readUInt32BE(0);
    return this.stripes[hash % this.stripes.length]!;
  }

  constructor(
    private readonly model: SettingsModel,
    readonly record: SettingsChangeRecord,
    readonly approvals: SettingsApprovals,
    private readonly writers: SettingsWriters,
    private readonly agentDir: string,
    private readonly now: () => Date = () => new Date(),
  ) {}

  observe(observer: SettingsObserver): void {
    if (this.observer && this.observer !== observer) throw new Error("Settings changes already have an observer");
    this.observer = observer;
  }

  async change(target: SettingsTarget, requests: readonly ChangeRequest[], context: ChangeContext): Promise<ChangeResult> {
    if (requests.length === 0 || requests.length > 50) throw new GatewayError("invalid_request", "A settings change holds 1 to 50 changes");
    if (context.actor.kind !== "ui" && !context.reason?.trim()) throw new GatewayError("invalid_request", "A reason is required for a change not made from the iPhone");
    await this.expireDue();
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
      const tier = planned.length ? maxTier(...planned.map(plan => plan.tier)) : "quiet";
      // Only the maintainer's own tap applies an approve-tier request at once;
      // that tap is the approval (F3). Everyone else waits for it.
      const held = tier === "approve" && context.actor.kind !== "ui";
      if (context.dryRun) {
        let next = 0;
        return {
          dryRun: true as const, status: held ? "pending" as const : "applied" as const, tier,
          changes: requests.map((request, index) => {
            const error = errors.get(index);
            if (error) return { changeId: "", key: request.key, layer: request.layer, status: "failed" as const, tier: "quiet" as const, error: { code: error.code, message: error.message } };
            const plan = planned[next++]!;
            return { changeId: "", key: plan.key.id, ...(Object.keys(plan.qualifiers).length ? { qualifiers: plan.qualifiers } : {}), layer: request.layer, status: held ? "pending" as const : "applied" as const, tier: plan.tier,
              // The maintainer's row shows this before an approve-tier change of his own (doc 5.4, item 4).
              ...(plan.tier === "approve" && plan.key.confirm ? { confirm: plan.key.confirm } : {}) };
          }),
        };
      }
      if (held) return this.hold(target, planned, context, tier);
      const applied = await this.applyAll(target, stores, planned, context, entry => entry);
      const changes = this.outcomes(applied, "applied");
      await this.observer?.applied(target, changes, { actor: context.actor, tier, ...(context.reason ? { reason: context.reason } : {}) });
      return { status: "applied" as const, tier, changes };
    });
  }

  /** Undo writes `before` back; refused when the store no longer holds `after` (doc 5.3). */
  async undo(changeId: string, context: Omit<ChangeContext, "undoOf">, session?: ChangeContext["session"]) {
    const found = await this.record.entry(changeId);
    if (!found) throw new GatewayError("not_found", "No such settings change");
    const { entry } = found;
    if (entry.redacted) throw new GatewayError("conflict", "This change is not undoable: its previous value was never recorded");
    // A pending entry's outcome is its latest decision fact.
    const status = entry.status === "pending" ? [...found.facts].reverse().find(fact => DECIDED.has(fact.status))?.status ?? "pending" : entry.status;
    if (status !== "applied" && status !== "approved") throw new GatewayError("conflict", "Only an applied change can be undone");
    const key = schemaKey(entry.key);
    const stores = await this.model.stores(entry.target, session);
    const binding = key.layers[entry.layer]!;
    const current = readBinding(stores, entry.layer, binding, entry.qualifiers ?? {}, qualifiedWrite(binding, entry.qualifiers ?? {}), entry.key);
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

  /** Requests waiting for the maintainer, after expiring those past 24 hours. */
  async pendingApprovals(): Promise<ApprovalRequest[]> {
    await this.expireDue();
    return this.approvals.pending();
  }

  /**
   * The maintainer's decision on one pending request, bound to the exact diff
   * he saw (`digest`). Approval re-checks every store against the diff's
   * `before`: a store that moved since supersedes the request, so an approval
   * can never apply a different change than the one shown (doc 5.5).
   */
  async decide(requestId: string, input: { digest: string; approved: boolean; decidedBy: Actor; commandId?: string; session?: ChangeContext["session"] }): Promise<ChangeResult> {
    await this.expireDue();
    const found = await this.approvals.get(requestId);
    if (!found) throw new GatewayError("not_found", "No such settings approval");
    return this.mutexFor(found.target).run(async () => {
      const request = await this.approvals.get(requestId);
      if (!request || request.status !== "pending") throw new GatewayError("conflict", `This change is no longer waiting for approval (${request?.status ?? "gone"})`);
      if (input.digest !== request.digest) throw new GatewayError("conflict", "This approval is for a different change than the one waiting");
      const context: ChangeContext = {
        actor: request.actor, ...(input.approved ? { approved: true as const } : {}), ...(request.reason ? { reason: request.reason } : {}),
        ...(input.commandId ? { commandId: input.commandId } : {}), ...(input.session ? { session: input.session } : {}),
      };
      const fact = (status: ChangeStatus, failure?: string) => request.changes.map((change): ChangeEntry => ({
        ...this.pendingEntry(request, change, context), changeId: randomUUID(), at: this.now().toISOString(), status,
        refersTo: change.changeId, decidedBy: input.decidedBy, ...(failure ? { failure } : {}),
      }));
      if (!input.approved) {
        const settled = await this.approvals.settle(requestId, "declined", this.now());
        await this.record.append(fact("declined"));
        this.observer?.approvals({ kind: "resolved", request: settled });
        return { status: "declined" as const, tier: "approve" as const, changes: request.changes.map(change => this.pendingOutcome(change, "declined")) };
      }
      const stores = await this.model.stores(request.target, input.session);
      const runtime = input.session?.modelRuntime ?? this.model.modelRuntime;
      const planned: Planned[] = [];
      try {
        for (const change of request.changes) {
          const plan = await this.plan(request.target, stores, {
            key: change.key, ...(change.qualifiers ? { qualifiers: change.qualifiers } : {}), layer: change.layer, op: change.op,
            ...(change.op === "set" ? { value: change.after } : {}),
            // A redacted diff has no `before` to compare; the digest still binds its key.
            ...(change.redacted ? {} : { expected: change.before === undefined ? null : change.before }),
          }, context, runtime);
          planned.push({ ...plan, ...(change.fixedAt ? { fixedAt: change.fixedAt } : {}), changeId: change.changeId, tier: change.tier, basis: change.tierBasis });
        }
      } catch (error) {
        const message = error instanceof GatewayError && error.code === "conflict"
          ? "The setting changed since this was requested" : error instanceof Error ? error.message : String(error);
        const settled = await this.approvals.settle(requestId, "superseded", this.now(), message);
        await this.record.append(fact("superseded", message));
        this.observer?.approvals({ kind: "resolved", request: settled });
        throw new GatewayError("conflict", `This change was superseded: ${message}`);
      }
      let applied: Awaited<ReturnType<SettingsChangePath["applyAll"]>>;
      try {
        applied = await this.applyAll(request.target, stores, planned, context, entry => ({
          ...entry, changeId: randomUUID(), status: entry.status === "failed" ? "failed" : "approved", refersTo: entry.changeId, requestId, decidedBy: input.decidedBy,
        }));
      } catch (error) {
        const settled = await this.approvals.settle(requestId, "failed", this.now(), error instanceof Error ? error.message : String(error));
        this.observer?.approvals({ kind: "resolved", request: settled });
        throw error;
      }
      const settled = await this.approvals.settle(requestId, "approved", this.now());
      const changes = this.outcomes(applied, "approved");
      await this.observer?.applied(request.target, changes, { actor: request.actor, tier: "approve", ...(request.reason ? { reason: request.reason } : {}), approved: true });
      this.observer?.approvals({ kind: "resolved", request: settled });
      return { status: "approved" as const, tier: "approve" as const, changes };
    });
  }

  /**
   * What the requester hears on its next turn (Q22): one line per change it
   * asked for that was declined, expired or superseded since it last heard.
   */
  async takeOutcomes(sessionId: string): Promise<string[]> {
    await this.expireDue();
    const taken = await this.approvals.takeOutcomes(sessionId);
    return taken.flatMap(request => request.changes.map(change => {
      const what = `${schemaKey(change.key).label} (${change.key}) at the ${LAYER_LABELS[change.layer]} layer`;
      const outcome = request.status === "declined" ? "was declined by the maintainer"
        : request.status === "expired" ? "expired after 24 hours without a decision"
          : request.status === "superseded" ? `was superseded${request.failure ? ` (${request.failure})` : " by a newer request"}`
            : `failed${request.failure ? ` (${request.failure})` : ""}`;
      return `Settings change ${change.changeId}: ${what} ${outcome}; it was not applied.`;
    }));
  }

  /** Pending requests past their 24 hours become expired, never applied (decision 8). */
  private async expireDue(): Promise<void> {
    const expired = await this.approvals.expire(this.now());
    for (const request of expired) {
      await this.record.append(request.changes.map((change): ChangeEntry => ({
        ...this.pendingEntry(request, change, { actor: request.actor }), changeId: randomUUID(), at: this.now().toISOString(),
        status: "expired", refersTo: change.changeId,
      })));
      this.observer?.approvals({ kind: "resolved", request });
    }
  }

  /** Holds an approve-tier request for the maintainer's tap (doc 5.5). */
  private async hold(target: SettingsTarget, planned: readonly Planned[], context: ChangeContext, tier: Tier): Promise<ChangeResult> {
    const changes = planned.map((plan): PendingChange => ({
      changeId: plan.changeId, key: plan.key.id, ...(Object.keys(plan.qualifiers).length ? { qualifiers: plan.qualifiers } : {}),
      layer: plan.request.layer, op: plan.request.op, ...(plan.fixedAt ? { fixedAt: plan.fixedAt } : {}),
      ...(plan.key.redacted ? { redacted: true as const } : {
        ...(plan.before === undefined ? {} : { before: plan.before }), ...(plan.after === undefined ? {} : { after: plan.after }),
      }),
      tier: plan.tier, tierBasis: plan.basis,
    }));
    const { request, superseded } = await this.approvals.create({
      target, actor: context.actor, ...(context.reason ? { reason: context.reason } : {}), changes,
    }, this.now());
    for (const previous of superseded) {
      await this.record.append(previous.changes.map((change): ChangeEntry => ({
        ...this.pendingEntry(previous, change, { actor: previous.actor }), changeId: randomUUID(), at: request.createdAt,
        status: "superseded", refersTo: change.changeId, failure: `Superseded by request ${request.requestId}`,
      })));
      this.observer?.approvals({ kind: "resolved", request: previous });
    }
    await this.record.append(changes.map(change => this.pendingEntry(request, change, context)));
    this.observer?.approvals({ kind: "pending", request });
    return {
      status: "pending", tier, approval: { requestId: request.requestId, digest: request.digest, expiresAt: request.expiresAt },
      changes: changes.map(change => this.pendingOutcome(change, "pending")),
    };
  }

  private pendingOutcome(change: PendingChange, status: ChangeStatus): ChangeOutcome {
    return { changeId: change.changeId, key: change.key, ...(change.qualifiers ? { qualifiers: change.qualifiers } : {}), layer: change.layer, status, tier: change.tier };
  }

  private pendingEntry(request: ApprovalRequest, change: PendingChange, context: Pick<ChangeContext, "actor" | "commandId" | "reason">): ChangeEntry {
    return {
      changeId: change.changeId, at: request.createdAt, ...(context.commandId ? { commandId: context.commandId } : {}),
      actor: request.actor, target: request.target, layer: change.layer, key: change.key,
      ...(change.qualifiers ? { qualifiers: change.qualifiers } : {}), op: change.op, ...(change.fixedAt ? { fixedAt: change.fixedAt } : {}),
      ...(change.redacted ? { changed: true as const, redacted: true as const } : {
        ...(change.before === undefined ? {} : { before: change.before }), ...(change.after === undefined ? {} : { after: change.after }),
      }),
      ...(request.reason ? { reason: request.reason } : {}),
      tier: change.tier, tierBasis: change.tierBasis, status: "pending", requestId: request.requestId,
    };
  }

  /** Applies every plan in store order, rolls back on a failure (doc 5.2), and
   * records one entry per change, shaped by `shape` (an approval's facts). */
  private async applyAll(target: SettingsTarget, stores: SettingsStores, planned: readonly Planned[], context: ChangeContext, shape: (entry: ChangeEntry) => ChangeEntry) {
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
      await this.record.append(ordered.map(plan => shape(this.entry(target, plan, context, "failed",
        plan === failure!.plan ? failure!.error.message : "Rolled back: another change in the same request failed"))));
      throw failure.error;
    }
    const entries = applied.map(done => shape(this.entry(target, done.plan, context, "applied", undefined, done.git)));
    await this.record.append(entries);
    return applied.map((done, index) => ({ ...done, changeId: entries[index]!.changeId }));
  }

  private outcomes(applied: ReadonlyArray<{ plan: Planned; changeId: string; revision?: number; git?: GitResult; result?: unknown }>, status: ChangeStatus): ChangeOutcome[] {
    return applied.map(({ plan, changeId, revision, git, result }) => ({
      changeId, key: plan.key.id, ...(Object.keys(plan.qualifiers).length ? { qualifiers: plan.qualifiers } : {}),
      layer: plan.request.layer, status, tier: plan.tier,
      ...(revision === undefined ? {} : { revision }), ...(git ? { git } : {}),
      ...(result === undefined ? {} : { result }),
    }));
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
    if (key.qualifier === "key" && !floorInstances().some(instance => instance.key === qualifiers.key && instance.direction === qualifiers.direction)) {
      throw new GatewayError("invalid_request", `${key.label} names a setting and, when its floor differs by direction, that direction`);
    }
    if (bindingNeedsModel(binding) && !qualifiers.model) {
      const chatModel = stores.chat?.model;
      if (request.layer === "chat" && chatModel) qualifiers.model = `${chatModel.provider}/${chatModel.id}`;
      else throw new GatewayError("invalid_request", `${key.label} needs a model qualifier`);
    }
    if (binding.store === "profile" || (binding.store === "chat-settings" && !hasRuntimeRequestApplier(key))) {
      throw new GatewayError("unsupported", `${key.label} has no writable ${LAYER_LABELS[request.layer]} store yet`);
    }
    let after: unknown;
    if (request.op === "set") {
      after = await key.type.validate(request.value, key.id, { admitModel: (ref) => this.admitModel(runtime, ref) });
      if (key.optionsSource?.name === "catalog.contextWindow") after = contextWindowValue(runtime, qualifiers.model, after);
    } else if (request.op !== "unset") {
      throw new GatewayError("invalid_request", "op must be set or unset");
    }
    let fixedAt: FixedSetting | undefined;
    if (request.op === "unset" && (binding.store === "chat" || binding.store === "chat-settings") && key.timing === "fixed") {
      // A fixed key never starts following a moving default: reset resolves
      // below its Chat value now and records another explicit start snapshot.
      const chat = structuredClone(stores.chat!);
      if (binding.store === "chat") delete chat[binding.field];
      else unsetPath(chat.settings, binding.path);
      if (chat.fixed) delete chat.fixed[key.id];
      const resolution = resolveSettings(target, { ...stores, chat }, { format: formatContext(runtime), options: optionSources(runtime), keys: [key.id] });
      const row = resolution.keys.find(row => row.key === key.id);
      after = row?.value;
      if (after === undefined && binding.store === "chat" && binding.field === "contextWindow" && qualifiers.model) {
        const ref = parseContextModelKey(qualifiers.model);
        const model = runtime.getPhysicalModel(ref.provider, ref.id);
        after = model && contextWindowLimits(model)?.default;
      }
      if (after === undefined) throw new GatewayError("conflict", `No current default is available for ${key.label}`);
      after = await key.type.validate(after, key.id, { admitModel: ref => this.admitModel(runtime, ref) });
      fixedAt = { value: after, from: row?.layer ?? "builtin", at: this.now().toISOString(), ref: randomUUID(), ...(row?.qualifiers ? { qualifiers: row.qualifiers } : {}) };
      request = { ...request, op: "set", value: after };
    }
    const before = readBinding(stores, request.layer, binding, qualifiers, qualifiedWrite(binding, qualifiers), key.id);
    if (request.expected !== undefined && binding.store !== "chat" && !deepEqual(request.expected, before)) {
      throw new GatewayError("conflict", `${key.label} changed since it was read; refresh and try again`, false, { current: (before ?? null) as never });
    }
    const builtin = builtinValue(key, qualifiers);
    const direction = key.direction ? key.direction(before ?? builtin, after ?? builtin) : "widen";
    // F3: tier = max(floor + web, riskModel), capped at approve. No risk model
    // exists yet (slice 13), so it never raises.
    const { floor, source } = floorFor(key, direction, stores.floors);
    const web = context.web === true;
    return {
      request, key, binding, qualifiers, before, after,
      tier: raiseTier(floor, web ? 1 : 0), basis: { direction, floor, floorSource: source, web, risk: null },
      changeId: randomUUID(), ...(fixedAt ? { fixedAt } : {}),
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
      case "floors":
        await updateJsonLocked<Record<string, Record<string, Tier>>>(this.model.floorsPath, {}, document => {
          const entry = { ...(document[qualifiers.key!] ?? {}) };
          // A key with one floor keeps both directions equal.
          for (const direction of qualifiers.direction ? [qualifiers.direction] : ["widen", "narrow"]) {
            if (unset) delete entry[direction]; else entry[direction] = value as Tier;
          }
          if (Object.keys(entry).length === 0) delete document[qualifiers.key!]; else document[qualifiers.key!] = entry;
          return document;
        });
        return {};
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
      case "chat-settings": {
        if (!context.session || target.kind !== "session") throw new GatewayError("invalid_request", "A Chat-layer change needs its open session");
        return { revision: await context.session.appliers.setSetting(plan.key.id, value, context.actor.kind === "ui" || context.approved === true, plan.fixedAt) };
      }
      case "chat": {
        const appliers = context.session?.appliers;
        if (!appliers || target.kind !== "session") throw new GatewayError("invalid_request", "A Chat-layer change needs its open session");
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

  private entry(target: SettingsTarget, plan: Planned, context: ChangeContext, status: ChangeStatus, failure?: string, git?: GitResult): ChangeEntry {
    const redacted = plan.key.redacted === true;
    return {
      changeId: plan.changeId, at: this.now().toISOString(),
      ...(context.commandId ? { commandId: context.commandId } : {}),
      actor: context.actor, target, layer: plan.request.layer, key: plan.key.id,
      ...(Object.keys(plan.qualifiers).length ? { qualifiers: plan.qualifiers } : {}),
      op: plan.request.op, ...(plan.fixedAt ? { fixedAt: plan.fixedAt } : {}),
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
