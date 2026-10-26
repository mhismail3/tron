import { createHash, randomUUID } from "node:crypto";
import { join } from "node:path";
import type { ModelRuntime } from "../pi/coding-agent.js";
import { GatewayError } from "../../errors.js";
import { AsyncMutex } from "../../util/async-mutex.js";
import { redactProcessText } from "../projection/process-activity.js";
import { SETTINGS_OUTCOME_MESSAGE, type ApprovalActionPreview, type ChangeRequest, type SettingsSignal, type ChangeOutcome, type ChangeResult, type ChangeStatus, type GitResult, type FixedSetting, type SettingsOutcomeMessage, type SettingsOutcomeRequest, type SettingsTarget, type Direction, type LayerId, type Qualifiers, type Tier } from "./tool-contract.js";
import type { Actor, ActorKind, ChangeEntry, SettingsChangeRecord, TierBasis } from "./settings-record.js";
import type { ApprovalRequest, PendingChange, SettingsApprovals } from "./settings-approvals.js";
import { composedBelow, readBinding, resolveSettings } from "./settings-resolver.js";
import { HOME_PROFILE_SUBJECT, keyDefault, floorFor, hasSessionSettingsApplier, keyForHome, type Binding, type KeyDeclaration } from "./settings-schema.js";
import { formatStoredSetting, LAYER_LABELS, maxTier, raiseTier, type ModelRefValue, type SettingsStores, type PlannedWrite } from "./settings-types.js";
import { canonicalSettingsTarget, scopeAdmitted, storeForScope } from "./scope-resolution.js";
import { SettingsModel, declaredKey, deepEqual, setPath, unsetPath, qualifiedWrite, type SessionSettingsSource, type SettingsReadOwner } from "./settings-model.js";

export interface SessionAppliers {
  setModel(ref: ModelRefValue, fixedAt?: FixedSetting): Promise<number>;
  setThinking(level: string, fixedAt?: FixedSetting): Promise<number>;
  setContextWindow(model: ModelRefValue, value: number | null, fixedAt?: FixedSetting): Promise<number>;
  setTools(tools: string[], fixedAt?: FixedSetting): Promise<void>;
  setSetting(key: string, value: unknown, allowFixedDirection: boolean, fixedAt?: FixedSetting): Promise<number>;
  /** Tells a running Home task worker about Session-scope changes just applied to it (#1336).
   * Absent for a chat's own `settings` tool, which made the change itself. Returns
   * undefined for a chat that is not a Home task worker. */
  announce?(notice: SettingsNotice): Promise<SettingsSignal | undefined>;
}

/** The applied Session-scope changes a running worker is told about, already formatted. */
export interface SettingsNotice {
  actor: Actor;
  reason?: string;
  /** The maintainer approved this requester's pending change. */
  approved?: true;
  changes: Array<{ changeId: string; label: string; before?: string; after?: string; effect: KeyDeclaration["effect"] }>;
}

export interface ChangeContext {
  actor: Actor;
  reason?: string;
  commandId?: string;
  dryRun?: boolean;
  /** The requester asks for the maintainer's tap whatever the tier (`settings` request). */
  request?: true;
  /** Set only by the approval owner, never accepted from a request payload. */
  approved?: true;
  /** The requesting turn read web or browser content (doc 5.4 input 2). The
   * Gateway sets it from the tool calls it executed; the UI has no turn. */
  web?: boolean;
  session?: SessionSettingsSource & { appliers: SessionAppliers };
  /** The runtime owner holds its existing lane across admission, recipe
   * publication and SDK effects. Refusal arrives before any store is changed. */
  homeChapter?: SessionSettingsSource & {
    sessionId: string;
    mutate<T>(operation: (admission: { appliers: SessionAppliers } | { error: GatewayError }) => Promise<T>): Promise<T>;
  };
  undoOf?: string;
  applyAgainOf?: string;
}

/** A planned change's values as its outcome reports them. */
function outcomeValues(redacted: boolean | undefined, before: unknown, after: unknown): Pick<ChangeOutcome, "before" | "after" | "redacted"> {
  return redacted ? { redacted: true } : { before: before ?? null, after: after ?? null };
}

export interface SettingsWriters {
  /** Optional typed classifier; the gate owns disclosure, max composition and deadline. */
  assessRisk?(input: SettingsRiskInput, signal: AbortSignal): Promise<SettingsRiskAssessment>;
  /** Trust's applier: TrustService.setAndApply with the runtime reload. Returns
   * the resulting trust inspection, which the change outcome carries. */
  setTrust(project: string, decision: boolean | null): Promise<unknown>;
  /** Home owns learned-profile validation and restoration under auditSubject. */
  undoSubject?(entry: ChangeEntry, context: Omit<ChangeContext, "undoOf">): Promise<ChangeResult>;
}

/** A subject operation restores partial writes before returning failed; the domain projects its typed result. */
export interface SubjectWrite { id: string; before: unknown; after: unknown; direction: "widen" | "narrow"; undoOf?: string }
export type SubjectContext = Pick<ChangeContext, "actor" | "reason" | "web"> & { commandId: string };
export type SubjectMutation<T> = { context: SubjectContext; writes: readonly SubjectWrite[] } & (
  { status: "applied"; result: T } | { status: "failed"; error: unknown; failure: string }
);

/**
 * A maintainer-gated operation that is not a stored setting value (#1985: project
 * lifecycle). It shares the approvals store, digest, expiry, decision and
 * requester outcomes with settings changes; its owner registers it once.
 */
export interface ApprovalActionHandler {
  /** Validates now (refusal at submission) and returns the exact preview the digest
   * binds. Called again at decide: a different preview supersedes the request. */
  plan(params: unknown, context: { actor: Actor }): Promise<ApprovalActionPreview>;
  /** Runs once after the maintainer approves, under the target's stripe. A throw
   * settles the request failed with its message; it is never retried. */
  apply(params: unknown, context: { actor: Actor; requestId: string }): Promise<{ summary: string; result?: unknown }>;
}

/** Bounded serialized action parameters; the preview is display text. */
const ACTION_PARAMS_BYTES = 16 * 1024;
const ACTION_ITEMS = 16;

/** The deadline scheduler for pending approvals. The fixture's clock owns time in tests. */
export type ExpiryScheduler = (run: () => void, ms: number) => { cancel(): void };
const realScheduler: ExpiryScheduler = (run, ms) => {
  // A pending approval never keeps the process alive; startup re-arms it.
  const timer = setTimeout(run, Math.min(ms, 2_147_483_647));
  timer.unref();
  return { cancel: () => clearTimeout(timer) };
};

/** Who hears about changes once they happen. The Gateway service registers one:
 * after-apply effects and broadcasts, and the maintainer's pushes (doc 5.4, 5.5). */
export interface SettingsObserver {
  applied(target: SettingsTarget, changes: readonly ChangeOutcome[], context: { actor: Actor; tier: Tier; reason?: string; approved?: true }): void | Promise<void>;
  approvals(event: { kind: "pending" | "resolved"; request: ApprovalRequest }): void;
}

export interface SettingsChangeOwner extends SettingsReadOwner {
  projectRoot(path: string): Promise<string>;
  admitModel(runtime: ModelRuntime, ref: ModelRefValue, options?: { physical?: boolean }): Promise<void>;
  contextWindowValue(runtime: ModelRuntime, qualifier: string | undefined, value: unknown): number;
  defaultContextWindow(runtime: ModelRuntime, qualifier: string): number | undefined;
  observedWrites(planned: readonly Planned[], projectRoot: string | undefined): PlannedWrite[];
  readonly outsideChanges: { begin(writes: readonly PlannedWrite[]): Promise<void>; end(writes: readonly PlannedWrite[], landed: ReadonlyMap<string, { git?: GitResult; changeId: string }>): Promise<void> } | undefined;
  applyStore(target: SettingsTarget, stores: SettingsStores, plan: Planned, value: unknown, context: ChangeContext, writers: Pick<SettingsWriters, "setTrust">): Promise<StoreApplyResult>;
}

/** The gate supplies metadata and a deliberately lossy diff, never stores,
 * credentials, target paths, transcripts or executable instructions. */
export interface SettingsRiskInput {
  key: string;
  layer: string;
  actor: ActorKind;
  reason: string;
  before: unknown;
  after: unknown;
  redacted: boolean;
  direction: Direction;
  floor: Tier;
  web: boolean;
}
export interface SettingsRiskAssessment { tier: Tier; rationale: string }

/** Free-form values are not needed to classify a schema key's change. Keep
 * booleans/numbers and array cardinality; never send arbitrary value text. */
function riskValue(value: unknown): unknown {
  if (value == null || typeof value === "boolean" || typeof value === "number") return value ?? null;
  if (Array.isArray(value)) return { kind: "array", count: value.length };
  return { kind: typeof value, withheld: true };
}

function riskReason(reason: string | undefined): string {
  // Use the existing broad untrusted-text redactor, not a second secret regex.
  return redactProcessText(reason ?? "").slice(0, 1_024);
}

const DECIDED = new Set<ChangeStatus>(["approved", "declined", "expired", "superseded", "failed"]);

export interface Planned {
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
  /** A companion write to another target in the same atomic bundle (the Home chapter). */
  target?: SettingsTarget;
  session?: ChangeContext["session"];
}

const adoptsHomeRuntime = (plan: Planned) => plan.request.layer === "session" && plan.binding.store === "home"
  && (plan.key.layers.session?.store === "session" || plan.key.layers.session?.store === "session-settings");

/** Applier order across stores (doc 5.2): fixed, so rollback is the reverse. */
const STORE_ORDER: Record<Binding["store"], number> = {
  "pi": 0, "pi-model-ref": 0, "trust": 1, "mac-terminal": 1, "home": 3, "floors": 4, "gateway": 4, "session": 5, "session-settings": 5, "session-launch": 5,
};

export type StoreApplyResult = { revision?: number; git?: GitResult; result?: unknown };

export class SettingsChangePath {
  /** Changes serialize per target (in a bounded set of stripes), so distinct
   * sessions change concurrently; each store's applier holds its own lock too. */
  private readonly stripes = Array.from({ length: 32 }, () => new AsyncMutex());
  private observer: SettingsObserver | undefined;
  private readonly actions = new Map<string, ApprovalActionHandler>();
  /** Requesters to nudge when an outcome they have not heard settles (Home's wake). */
  private readonly outcomeListeners = new Set<(sessionId: string) => void>();
  private expiry: ReturnType<ExpiryScheduler> | undefined;
  private disposed = false;
  private started = false;
  private armWork: Promise<void> = Promise.resolve();
  private readonly expiryWork = new Map<string, Promise<void>>();

  private mutexFor(target: SettingsTarget): AsyncMutex {
    const id = target.kind === "session" ? `session:${target.sessionId}` : target.kind === "project" ? `project:${target.cwd}` : target.kind;
    const hash = createHash("sha256").update(id).digest().readUInt32BE(0);
    return this.stripes[hash % this.stripes.length]!;
  }

  constructor(
    private readonly model: SettingsModel<SettingsChangeOwner>,
    readonly record: SettingsChangeRecord,
    readonly approvals: SettingsApprovals,
    private readonly writers: SettingsWriters,
    private readonly now: () => Date = () => new Date(),
    private readonly schedule: ExpiryScheduler = realScheduler,
  ) {}

  /** Composition activates background work once the actual owner is installed.
   * Merely opening settings for inspection must never expire or rewrite stores. */
  async start(): Promise<void> {
    if (this.disposed) throw new GatewayError("conflict", "Settings approvals are disposed");
    if (this.started) return this.armWork;
    this.started = true;
    // The existing joined arm owner also owns the one activation recovery.
    // Concurrent start/dispose must not escape an accepted recovery read.
    await this.armExpiry(true);
  }

  registerAction(subject: string, handler: ApprovalActionHandler): void {
    if (!/^[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+$/.test(subject) || subject.length > 80) throw new Error(`Invalid approval action subject ${subject}`);
    if (this.actions.has(subject) || this.model.schema.auditSubject(subject)) throw new Error(`Approval action ${subject} is already declared`);
    this.actions.set(subject, handler);
  }

  /** Nudged with the requester's session when one of its outcomes settles. The
   * outcome itself stays in the approvals store until the requester hears it. */
  onOutcome(listener: (sessionId: string) => void): () => void {
    this.outcomeListeners.add(listener);
    return () => { this.outcomeListeners.delete(listener); };
  }

  private settledOutcome(request: ApprovalRequest): void {
    this.observer?.approvals({ kind: "resolved", request });
    if (request.status !== "pending" && !request.told && request.actor.sessionId) {
      for (const listener of this.outcomeListeners) listener(request.actor.sessionId);
    }
    void this.armExpiry().catch(() => undefined);
  }

  /** One timer for the earliest pending deadline; serialize reads so an older
   * asynchronous arm cannot replace a newer deadline or survive disposal. */
  private armExpiry(recoverInterruptedActions?: true): Promise<void> {
    this.armWork = this.armWork.catch(() => undefined).then(async () => {
      if (this.disposed || !this.started) return;
      if (recoverInterruptedActions) await this.expireDue({ interruptedActions: true });
      if (this.disposed) return;
      const pending = await this.approvals.pending();
      if (this.disposed) return;
      this.scheduleExpiry(pending.filter(request => !request.executionStartedAt).map(request => Date.parse(request.expiresAt)));
    });
    return this.armWork;
  }

  /** Deadline hints only wake the owner: every effect re-reads the approvals store.
   * Keep the later known deadline before I/O, so a failed pass cannot disarm it.
   * Do not retry the failed deadline immediately against a persistently bad store. */
  private scheduleExpiry(deadlines: readonly number[]): void {
    this.expiry?.cancel();
    this.expiry = undefined;
    const at = Math.min(...deadlines);
    if (this.disposed || !Number.isFinite(at)) return;
    const timer = this.schedule(() => {
      if (this.disposed || this.expiry !== timer) return;
      this.scheduleExpiry(deadlines.filter(deadline => deadline > this.now().getTime()));
      void this.expireDue().then(() => this.armExpiry()).catch(() => {
        if (!this.disposed) process.emitWarning("Settings approval expiry failed; retained requests retry at the next deadline or admission", { code: "TRON_SETTINGS_EXPIRY_FAILED" });
      });
    }, Math.max(0, at - this.now().getTime()));
    this.expiry = timer;
  }

  /** Composition stops the timer before releasing its stores; accepted expiry
   * work is joined, not abandoned against the next installation's owner. */
  async dispose(): Promise<void> {
    this.disposed = true;
    this.expiry?.cancel();
    this.expiry = undefined;
    this.outcomeListeners.clear();
    await Promise.all(this.expiryWork.values());
    await this.armWork;
  }

  /** Asks the maintainer to approve one registered action (#1985). */
  async requestAction(subject: string, params: unknown, context: Pick<ChangeContext, "actor" | "reason" | "commandId">): Promise<ChangeResult> {
    const handler = this.actions.get(subject);
    if (!handler) throw new GatewayError("invalid_request", `No approval action ${subject}`);
    if (context.actor.kind === "ui") throw new GatewayError("invalid_request", "The maintainer runs his own actions directly");
    if (!context.reason?.trim()) throw new GatewayError("invalid_request", "A reason is required for an approval request");
    if (Buffer.byteLength(JSON.stringify(params ?? null)) > ACTION_PARAMS_BYTES) throw new GatewayError("invalid_request", "Action parameters exceed 16 KiB");
    const preview = actionPreview(await handler.plan(params, { actor: context.actor }));
    await this.expireDue({ target: preview.target });
    return this.mutexFor(preview.target).run(async () => {
      const { request } = await this.approvals.create({ target: preview.target, actor: context.actor, reason: context.reason!, changes: [],
        action: { subject, params: params ?? null, preview } }, this.now());
      // The pending entry is keyed by the request, so every later fact refers to it.
      await this.record.append([{ ...this.actionEntry(request, context.commandId), changeId: request.requestId, status: "pending" }]);
      this.observer?.approvals({ kind: "pending", request });
      void this.armExpiry().catch(() => undefined);
      return { status: "pending", tier: "approve", changes: [], action: preview,
        approval: { requestId: request.requestId, digest: request.digest, expiresAt: request.expiresAt } };
    });
  }

  private actionEntry(request: ApprovalRequest, commandId?: string): ChangeEntry {
    return {
      changeId: randomUUID(), at: this.now().toISOString(), ...(commandId ? { commandId } : {}), actor: request.actor, target: request.target,
      layer: "global", key: request.action!.subject, op: "set", after: request.action!.preview, ...(request.reason ? { reason: request.reason } : {}),
      tier: "approve", tierBasis: { direction: "widen", floor: "approve", floorSource: "code", web: false, risk: null },
      status: "pending", requestId: request.requestId, action: true,
    };
  }

  observe(observer: SettingsObserver): void {
    if (this.observer && this.observer !== observer) throw new Error("Settings changes already have an observer");
    this.observer = observer;
  }

  async change(target: SettingsTarget, requests: readonly ChangeRequest[], context: ChangeContext): Promise<ChangeResult> {
    target = canonicalSettingsTarget(target, context.session?.home === true);
    if (requests.length === 0 || requests.length > 50) throw new GatewayError("invalid_request", "A settings change holds 1 to 50 changes");
    if (context.actor.kind !== "ui" && !context.reason?.trim()) throw new GatewayError("invalid_request", "A reason is required for a change not made from the iPhone");
    if (context.request && context.actor.kind === "ui") throw new GatewayError("invalid_request", "The maintainer applies his own changes directly");
    await this.expireDue({ target });
    return this.mutexFor(target).run(async () => {
      const stores = await this.model.owner.stores(target, context.session);
      const runtime = context.session?.modelRuntime ?? this.model.owner.modelRuntime;
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
      // Validate the entire bundle before disclosing anything or spending on it.
      await this.assessRisk(planned, context);
      const tier = planned.length ? maxTier(...planned.map(plan => plan.tier)) : "quiet";
      // Only the maintainer's own tap applies an approve-tier request at once;
      // that tap is the approval (F3). Everyone else waits for it.
      const held = (tier === "approve" || context.request === true) && context.actor.kind !== "ui";
      // A request waits for the tap whatever its tier; tiers only rise (F3).
      if (context.request) for (const plan of planned) if (plan.tier !== "approve") { plan.tier = "approve"; plan.basis = { ...plan.basis, requested: true }; }
      if (context.dryRun) {
        let next = 0;
        return {
          dryRun: true as const, status: held ? "pending" as const : "applied" as const, tier: held ? "approve" as const : tier,
          changes: requests.map((request, index) => {
            const error = errors.get(index);
            if (error) return { changeId: "", key: request.key, layer: request.layer, status: "failed" as const, tier: "quiet" as const, error: { code: error.code, message: error.message } };
            const plan = planned[next++]!;
            return { changeId: "", key: plan.key.id, ...(Object.keys(plan.qualifiers).length ? { qualifiers: plan.qualifiers } : {}), layer: request.layer, status: held ? "pending" as const : "applied" as const, tier: plan.tier,
              ...outcomeValues(plan.key.redacted, plan.before, plan.after),
              // The maintainer's row shows this before an approve-tier change of his own (doc 5.4, item 4).
              ...(plan.tier === "approve" && plan.key.confirm ? { confirm: plan.key.confirm } : {}) };
          }),
        };
      }
      if (held) return this.hold(target, planned, context, "approve");
      const applied = await this.applyAll(target, stores, planned, context, entry => entry);
      const changes = this.outcomes(applied.filter(done => !done.plan.target), "applied");
      const adopted = this.outcomes(applied.filter(done => done.plan.target), "applied");
      await this.observer?.applied(target, changes, { actor: context.actor, tier, ...(context.reason ? { reason: context.reason } : {}) });
      if (adopted.length) await this.observer?.applied(applied.find(done => done.plan.target)!.plan.target!, adopted, { actor: context.actor, tier, ...(context.reason ? { reason: context.reason } : {}) });
      const signal = await this.announce(changes, context);
      return { status: "applied" as const, tier, changes, ...(signal ? { signal } : {}) };
    });
  }

  /** Home's learned subject shares the settings stripe, audit and observer cut.
   * The domain projects its typed result after the observer, still under the stripe. */
  async auditSubject<T, R>(operation: () => Promise<SubjectMutation<T>>, project: (result: T, audit: ChangeResult) => Promise<R>): Promise<R> {
    return this.mutexFor({ kind: "home" }).run(async () => {
      const mutation = await operation();
      if (mutation.status === "failed") {
        if (mutation.writes.length) await this.record.append(mutation.writes.map(write => this.subjectEntry(write, mutation.context, "failed", mutation.failure)));
        throw mutation.error;
      }
      const group = { id: randomUUID(), size: mutation.writes.length };
      const entries = mutation.writes.map(write => ({ ...this.subjectEntry(write, mutation.context, "applied"), group,
        ...(write.undoOf ? { undoOf: write.undoOf } : {}) }));
      await this.record.append(entries);
      const changes: ChangeOutcome[] = entries.map(entry => ({
        changeId: entry.changeId, key: entry.key, qualifiers: entry.qualifiers!, layer: "session", status: "applied", tier: entry.tier,
        before: entry.before ?? null, after: entry.after ?? null,
      }));
      const tier = maxTier(...entries.map(entry => entry.tier));
      const context = mutation.context;
      await this.observer?.applied({ kind: "home" }, changes, { actor: context.actor, tier, ...(context.reason ? { reason: context.reason } : {}) });
      return project(mutation.result, { status: "applied", tier, changes });
    });
  }

  private subjectEntry(write: SubjectWrite, context: SubjectContext, status: ChangeStatus, failure?: string): ChangeEntry {
    const web = context.web === true;
    return {
      changeId: randomUUID(), at: this.now().toISOString(), commandId: context.commandId, actor: context.actor, target: { kind: "home" },
      layer: "session", key: HOME_PROFILE_SUBJECT.id, qualifiers: { note: write.id }, op: "set",
      ...(write.before === null ? {} : { before: write.before }), ...(write.after === null ? {} : { after: write.after }),
      ...(context.reason ? { reason: context.reason } : {}),
      tier: raiseTier(HOME_PROFILE_SUBJECT.floor, web ? 1 : 0),
      tierBasis: { direction: write.direction, floor: HOME_PROFILE_SUBJECT.floor, floorSource: "code", web, risk: null },
      status, ...(failure ? { failure } : {}),
    };
  }

  /** Undo writes `before` back; refused when the store no longer holds `after` (doc 5.3). */
  async undo(changeId: string, context: Omit<ChangeContext, "undoOf">, session?: ChangeContext["session"]) {
    const found = await this.record.entry(changeId);
    if (!found) throw new GatewayError("not_found", "No such settings change");
    const { entry } = found;
    if (entry.action) throw new GatewayError("conflict", "An approved action is not undoable here; ask its owner to reverse it");
    if (entry.key === HOME_PROFILE_SUBJECT.id) {
      if (!this.writers.undoSubject) throw new GatewayError("unsupported", "Knowledge is not available on this Gateway");
      return this.writers.undoSubject(entry, context);
    }
    if (entry.redacted) throw new GatewayError("conflict", "This change is not undoable: its previous value was never recorded");
    // A pending entry's outcome is its latest decision fact.
    const status = entry.status === "pending" ? [...found.facts].reverse().find(fact => DECIDED.has(fact.status))?.status ?? "pending" : entry.status;
    if (status !== "applied" && status !== "approved") throw new GatewayError("conflict", "Only an applied change can be undone");
    const key = this.model.schema.schemaKey(entry.key);
    const stores = await this.model.owner.stores(entry.target, session);
    const store = storeForScope(entry.layer, stores.layers);
    const binding = key.layers[store];
    if (!binding) throw new GatewayError("conflict", "The historical setting has no surviving store");
    const current = readBinding(stores, store, binding, entry.qualifiers ?? {}, qualifiedWrite(binding, entry.qualifiers ?? {}), entry.key);
    if (!deepEqual(current, entry.after)) {
      throw new GatewayError("conflict", "The setting changed since; undo would overwrite a newer value", false,
        { current: (current ?? null) as never, after: (entry.after ?? null) as never,
          display: { current: formatStoredSetting(key.type, current), after: formatStoredSetting(key.type, entry.after) } });
    }
    return this.change(entry.target, [{
      key: entry.key, ...(entry.qualifiers ? { qualifiers: entry.qualifiers } : {}), layer: entry.layer,
      op: entry.before === undefined ? "unset" : "set", ...(entry.before === undefined ? {} : { value: entry.before }),
    }], { ...context, undoOf: changeId, ...(session ? { session } : {}) });
  }

  /**
   * Apply again (doc 5.3, 5.6): writes back the value Tron had written before an
   * outside change replaced or removed it. An ordinary change through the same
   * path and gate, never automatic; refused when the store moved on since.
   */
  async applyAgain(changeId: string, context: Omit<ChangeContext, "applyAgainOf" | "undoOf">, session?: ChangeContext["session"]) {
    const entry = await this.record.find(changeId);
    if (!entry || entry.status !== "outside") throw new GatewayError("not_found", "No such outside change");
    if (entry.redacted) throw new GatewayError("conflict", "A hidden value cannot be applied again: it was never recorded");
    const replaced = entry.refersTo ? await this.record.entry(entry.refersTo) : undefined;
    if (!replaced || replaced.entry.redacted) throw new GatewayError("conflict", "This outside change did not replace a value Tron wrote");
    const value = replaced.entry.after;
    return this.change(entry.target, [{
      key: entry.key, ...(entry.qualifiers ? { qualifiers: entry.qualifiers } : {}), layer: entry.layer,
      op: value === undefined ? "unset" : "set", ...(value === undefined ? {} : { value }),
      // The outside value is what the maintainer saw; a newer change refuses.
      expected: entry.after === undefined ? null : entry.after,
    }], { ...context, applyAgainOf: changeId, ...(session ? { session } : {}) });
  }

  history(input: { cursor?: string; limit?: number; key?: string; status?: string; actor?: ActorKind | "agents"; layer?: LayerId; section?: string }) {
    return this.record.page({
      ...(input.cursor ? { cursor: input.cursor } : {}), ...(input.limit ? { limit: input.limit } : {}),
      filter: entry => (!input.key || entry.key === input.key) && (!input.status || entry.status === input.status)
        && (!input.actor || (input.actor === "agents" ? entry.actor.kind !== "ui" : entry.actor.kind === input.actor))
        && (!input.layer || entry.layer === input.layer)
        // The permanent record may name a key this Gateway no longer declares.
        // It stays in Everything/key history, but has no current section.
        && (!input.section || this.model.schema.auditSubject(entry.key)?.group === input.section),
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
  async decide(requestId: string, input: { digest: string; approved: boolean; decidedBy: Actor; commandId?: string; session?: ChangeContext["session"]; homeChapter?: ChangeContext["homeChapter"] }): Promise<ChangeResult> {
    // Only the maintainer's own client decides; no requester can approve itself (F3).
    if (input.decidedBy.kind !== "ui") throw new GatewayError("invalid_request", "Only the maintainer decides a settings approval");
    const found = await this.approvals.get(requestId);
    if (!found) throw new GatewayError("not_found", "No such settings approval");
    await this.expireDue({ target: found.target });
    return this.mutexFor(found.target).run(async () => {
      const request = await this.approvals.get(requestId);
      if (!request || request.status !== "pending") throw new GatewayError("conflict", `This change is no longer waiting for approval (${request?.status ?? "gone"})`);
      // This is the serialized decision cut: a request can pass its deadline while
      // waiting for this stripe, but never expire after its effects are admitted.
      if (Date.parse(request.expiresAt) <= this.now().getTime()) {
        await this.expireRequest(request.requestId);
        throw new GatewayError("conflict", "This change is no longer waiting for approval (expired)");
      }
      if (input.digest !== request.digest) throw new GatewayError("conflict", "This approval is for a different change than the one waiting");
      if (request.action) return this.decideAction(request, input);
      const context: ChangeContext = {
        actor: request.actor, ...(input.approved ? { approved: true as const } : {}), ...(request.reason ? { reason: request.reason } : {}),
        ...(input.commandId ? { commandId: input.commandId } : {}), ...(input.session ? { session: input.session } : {}),
        ...(input.homeChapter ? { homeChapter: input.homeChapter } : {}),
      };
      const fact = (status: ChangeStatus, failure?: string) => request.changes.map((change): ChangeEntry => ({
        ...this.pendingEntry(request, change, context), changeId: randomUUID(), at: this.now().toISOString(), status,
        refersTo: change.changeId, decidedBy: input.decidedBy, ...(failure ? { failure } : {}),
      }));
      if (!input.approved) {
        const settled = await this.approvals.settle(requestId, "declined", this.now());
        await this.record.append(fact("declined"));
        this.settledOutcome(settled);
        return { status: "declined" as const, tier: "approve" as const, changes: request.changes.map(change => this.pendingOutcome(change, "declined")) };
      }
      const stores = await this.model.owner.stores(request.target, input.session);
      const runtime = input.session?.modelRuntime ?? this.model.owner.modelRuntime;
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
        this.settledOutcome(settled);
        throw new GatewayError("conflict", `This change was superseded: ${message}`);
      }
      let applied: Awaited<ReturnType<SettingsChangePath["applyAll"]>>;
      try {
        applied = await this.applyAll(request.target, stores, planned, context, entry => ({
          ...entry, changeId: randomUUID(), status: entry.status === "failed" ? "failed" : "approved", refersTo: entry.changeId, requestId, decidedBy: input.decidedBy,
        }));
      } catch (error) {
        const settled = await this.approvals.settle(requestId, "failed", this.now(), error instanceof Error ? error.message : String(error));
        this.settledOutcome(settled);
        throw error;
      }
      const settled = await this.approvals.settle(requestId, "approved", this.now());
      const changes = this.outcomes(applied.filter(done => !done.plan.target), "approved");
      const adopted = this.outcomes(applied.filter(done => done.plan.target), "approved");
      const observerContext = { actor: request.actor, tier: "approve" as const, ...(request.reason ? { reason: request.reason } : {}), approved: true as const };
      await this.observer?.applied(request.target, changes, observerContext);
      if (adopted.length) await this.observer?.applied(applied.find(done => done.plan.target)!.plan.target!, adopted, observerContext);
      const signal = await this.announce(changes, context);
      this.settledOutcome(settled);
      return { status: "approved" as const, tier: "approve" as const, changes, ...(signal ? { signal } : {}) };
    });
  }

  /** An action request's decision: re-plan (a moved state supersedes), then apply once. */
  private async decideAction(request: ApprovalRequest, input: { approved: boolean; decidedBy: Actor; commandId?: string }): Promise<ChangeResult> {
    const action = request.action!;
    const settle = async (status: Exclude<ApprovalRequest["status"], "pending">, failure?: string, summary?: string) => {
      const settled = await this.approvals.settle(request.requestId, status, this.now(), failure, summary);
      await this.record.append([{ ...this.actionEntry(request, input.commandId), status, refersTo: request.requestId, decidedBy: input.decidedBy,
        ...(failure ? { failure } : {}) }]);
      this.settledOutcome(settled);
    };
    if (!input.approved) { await settle("declined"); return { status: "declined", tier: "approve", changes: [], action: action.preview }; }
    const handler = this.actions.get(action.subject);
    let preview: ApprovalActionPreview | undefined;
    try { preview = handler ? actionPreview(await handler.plan(action.params, { actor: request.actor })) : undefined; }
    catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      await settle("superseded", message);
      throw new GatewayError("conflict", `This action was superseded: ${message}`);
    }
    if (!preview || !deepEqual(preview, action.preview)) {
      const message = preview ? "The state changed since this was requested" : `No approval action ${action.subject} on this Gateway`;
      await settle("superseded", message);
      throw new GatewayError("conflict", `This action was superseded: ${message}`);
    }
    await this.approvals.beginAction(request.requestId, this.now());
    let summary: string;
    try { ({ summary } = await handler!.apply(action.params, { actor: request.actor, requestId: request.requestId })); }
    catch (error) {
      await settle("failed", error instanceof Error ? error.message : String(error));
      throw error;
    }
    await settle("approved", undefined, summary);
    return { status: "approved", tier: "approve", changes: [], action: preview };
  }

  /** The target chat's own signal for its applied Session-scope changes (#1336). The
   * changes are stored before this runs, so a refused signal never undoes them. */
  private async announce(changes: readonly ChangeOutcome[], context: ChangeContext): Promise<SettingsSignal | undefined> {
    const announce = context.session?.appliers.announce;
    const chat = changes.filter(change => change.layer === "session");
    if (!announce || chat.length === 0) return undefined;
    return announce({
      actor: context.actor, ...(context.reason ? { reason: context.reason } : {}), ...(context.approved ? { approved: true as const } : {}),
      changes: chat.map(change => {
        const key = this.model.schema.schemaKey(change.key);
        const shown = (value: unknown) => value === null || value === undefined ? "the default" : formatStoredSetting(key.type, value);
        return { changeId: change.changeId, label: key.label, effect: key.effect,
          ...(change.redacted ? {} : { before: shown(change.before), after: shown(change.after) }) };
      }),
    });
  }

  /**
   * Every settled request this requester has not heard, as one canonical message
   * (decision 4e6e8f54): approved and applied, declined, failed, superseded or expired.
   * The text is for the model; `details` carries the same facts for the chat's chip.
   */
  async takeOutcomes(requesterSessionIds: readonly string[], deliveredRequestIds: readonly string[] = [], accepts?: (message: SettingsOutcomeMessage) => boolean): Promise<SettingsOutcomeMessage | undefined> {
    await this.expireDue({ requesterSessionIds });
    await this.approvals.acknowledge(requesterSessionIds, deliveredRequestIds);
    const requests = (await this.approvals.takeOutcomes(requesterSessionIds)).map(request => this.outcomeRequest(request));
    if (!requests.length) return undefined;
    if (!accepts) return this.outcomeMessage(requests);
    const selected: SettingsOutcomeRequest[] = [];
    let message: SettingsOutcomeMessage | undefined;
    for (const request of requests) {
      const candidate = this.outcomeMessage([...selected, request]);
      if (!accepts(candidate)) break;
      selected.push(request); message = candidate;
    }
    return message;
  }

  private outcomeMessage(requests: readonly SettingsOutcomeRequest[]): SettingsOutcomeMessage {
    const lines = requests.map(request => {
      const what = request.action ? request.action.title
        : request.items.map(item => `${item.label} (${item.key}) at the ${LAYER_LABELS[item.layer]} layer${item.before !== undefined ? `: ${item.before} → ${item.after}` : ""}`).join("; ");
      const outcome = request.status === "approved" ? `was approved by the maintainer and applied${request.action?.summary ? ` (${request.action.summary})` : ""}`
        : request.status === "declined" ? "was declined by the maintainer; it was not applied"
          : request.status === "expired" ? "expired after 24 hours without a decision; it was not applied"
            : request.status === "superseded" ? `was superseded${request.failure ? ` (${request.failure})` : " by a newer request"}; it was not applied`
              : `failed${request.failure ? ` (${request.failure})` : ""}; ${request.action ? "inspect the operation's state before retrying" : "it was not applied"}`;
      return `Settings request ${request.requestId}: ${what} ${outcome}.`;
    });
    const eventId = `settings-outcome:${createHash("sha256").update(requests.map(request => request.requestId).join(",")).digest("hex").slice(0, 32)}`;
    return { customType: SETTINGS_OUTCOME_MESSAGE, content: lines.join("\n"), display: true,
      details: { version: 1, eventId, taskId: `settings:${requests[0]!.requestId}`, requests: [...requests] } };
  }

  private outcomeRequest(request: ApprovalRequest): SettingsOutcomeRequest {
    const items = request.changes.map(change => {
      const key = this.model.schema.KEYS.find(candidate => candidate.id === change.key);
      // Unset at this layer means the key's default applies there.
      const fallback = key ? keyDefault(key, change.qualifiers ?? {}) : undefined;
      const shown = (value: unknown): string => value === undefined || value === null
        ? (fallback === undefined || fallback === null ? "Not set" : `Default (${shown(fallback)})`)
        : key ? formatStoredSetting(key.type, value) : JSON.stringify(value);
      return { key: change.key, label: key?.label ?? change.key, ...(change.qualifiers ? { qualifiers: change.qualifiers } : {}), layer: change.layer,
        ...(change.redacted ? { redacted: true as const } : { before: shown(change.before), after: shown(change.after) }) };
    });
    return {
      requestId: request.requestId, status: request.status as SettingsOutcomeRequest["status"],
      requester: { kind: request.actor.kind, ...(request.actor.taskId ? { taskId: request.actor.taskId } : {}) },
      target: request.target, createdAt: request.createdAt, ...(request.decidedAt ? { decidedAt: request.decidedAt } : {}),
      ...(request.reason ? { reason: request.reason } : {}),
      ...(request.failure ? { failure: request.failure } : {}),
      items,
      ...(request.action ? { action: { subject: request.action.subject, title: request.action.preview.title,
        ...(request.summary ? { summary: request.summary } : {}) } } : {}),
    };
  }

  /** Expiry uses the same target stripe as decision admission and effects. A
   * timer may become due during apply, but cannot contradict an admitted decision. */
  private async expireDue(filter: { target?: SettingsTarget; requesterSessionIds?: readonly string[]; interruptedActions?: true } = {}): Promise<void> {
    if (this.disposed) throw new GatewayError("conflict", "Settings approvals are disposed");
    const work: Promise<void>[] = [];
    for (const request of await this.approvals.pending()) {
      if (this.disposed) return;
      if (filter.target && !deepEqual(request.target, filter.target)) continue;
      if (filter.requesterSessionIds && (!request.actor.sessionId || !filter.requesterSessionIds.includes(request.actor.sessionId))) continue;
      if (filter.interruptedActions ? !request.executionStartedAt : request.executionStartedAt || Date.parse(request.expiresAt) > this.now().getTime()) continue;
      let pending = this.expiryWork.get(request.requestId);
      if (!pending) {
        pending = this.mutexFor(request.target).run(async () => {
          if (!this.disposed) await this.expireRequest(request.requestId);
        }).finally(() => { this.expiryWork.delete(request.requestId); });
        this.expiryWork.set(request.requestId, pending);
      }
      work.push(pending);
    }
    // Independent targets remain concurrent; public admission joins only its
    // own target/requester, never a timer waiting behind another target's apply.
    await Promise.all(work);
  }

  /** Caller owns the target stripe. */
  private async expireRequest(requestId: string): Promise<void> {
    const current = await this.approvals.get(requestId);
    if (current?.status === "pending" && current.action && current.executionStartedAt) {
      // No live apply can be here: the caller owns its stripe. An earlier process
      // stopped after its durable execution claim; effects are unknown, never replayed.
      const failure = "Action execution was interrupted; its effects may have completed";
      const request = await this.approvals.settle(requestId, "failed", this.now(), failure);
      await this.record.append([{ ...this.actionEntry(request), status: "failed", refersTo: requestId, failure }]);
      this.settledOutcome(request);
      return;
    }
    for (const request of await this.approvals.expire(this.now(), requestId)) {
      await this.record.append(request.action ? [{ ...this.actionEntry(request), status: "expired", refersTo: request.requestId }]
        : request.changes.map((change): ChangeEntry => ({
          ...this.pendingEntry(request, change, { actor: request.actor }), changeId: randomUUID(), at: this.now().toISOString(),
          status: "expired", refersTo: change.changeId,
        })));
      this.settledOutcome(request);
    }
  }

  /** Holds an approve-tier request for the maintainer's tap (doc 5.5). */
  private async hold(target: SettingsTarget, planned: readonly Planned[], context: ChangeContext, tier: Tier): Promise<ChangeResult> {
    const changes = planned.map(plan => this.plannedChange(plan));
    const { request, superseded } = await this.approvals.create({
      target, actor: context.actor, ...(context.reason ? { reason: context.reason } : {}), changes,
    }, this.now());
    for (const previous of superseded) {
      await this.record.append(previous.changes.map((change): ChangeEntry => ({
        ...this.pendingEntry(previous, change, { actor: previous.actor }), changeId: randomUUID(), at: request.createdAt,
        status: "superseded", refersTo: change.changeId, failure: `Superseded by request ${request.requestId}`,
      })));
      this.settledOutcome(previous);
    }
    await this.record.append(changes.map(change => this.pendingEntry(request, change, context)));
    this.observer?.approvals({ kind: "pending", request });
    void this.armExpiry().catch(() => undefined);
    return {
      status: "pending", tier, approval: { requestId: request.requestId, digest: request.digest, expiresAt: request.expiresAt },
      changes: changes.map(change => this.pendingOutcome(change, "pending")),
    };
  }

  private pendingOutcome(change: PendingChange, status: ChangeStatus): ChangeOutcome {
    return { changeId: change.changeId, key: change.key, ...(change.qualifiers ? { qualifiers: change.qualifiers } : {}), layer: change.layer, status, tier: change.tier,
      ...outcomeValues(change.redacted, change.before, change.after) };
  }

  private plannedChange(plan: Planned): PendingChange {
    return {
      changeId: plan.changeId, key: plan.key.id, ...(Object.keys(plan.qualifiers).length ? { qualifiers: plan.qualifiers } : {}),
      layer: plan.request.layer, op: plan.request.op, ...(plan.fixedAt ? { fixedAt: plan.fixedAt } : {}),
      ...(plan.key.redacted ? { redacted: true as const } : {
        ...(plan.before === undefined ? {} : { before: plan.before }), ...(plan.after === undefined ? {} : { after: plan.after }),
      }),
      tier: plan.tier, tierBasis: plan.basis,
    };
  }

  private fact(target: SettingsTarget, change: PendingChange, context: Pick<ChangeContext, "actor" | "commandId" | "reason">, at: string, status: ChangeStatus): ChangeEntry {
    return {
      changeId: change.changeId, at, ...(context.commandId ? { commandId: context.commandId } : {}),
      actor: context.actor, target, layer: change.layer, key: change.key,
      ...(change.qualifiers ? { qualifiers: change.qualifiers } : {}), op: change.op, ...(change.fixedAt ? { fixedAt: change.fixedAt } : {}),
      ...(change.redacted ? { changed: true as const, redacted: true as const } : {
        ...(change.before === undefined ? {} : { before: change.before }), ...(change.after === undefined ? {} : { after: change.after }),
      }),
      ...(context.reason ? { reason: context.reason } : {}),
      tier: change.tier, tierBasis: change.tierBasis, status,
    };
  }

  private pendingEntry(request: ApprovalRequest, change: PendingChange, context: Pick<ChangeContext, "actor" | "commandId" | "reason">): ChangeEntry {
    const source = { actor: request.actor, ...(context.commandId ? { commandId: context.commandId } : {}), ...(request.reason ? { reason: request.reason } : {}) };
    return { ...this.fact(request.target, change, source, request.createdAt, "pending"), requestId: request.requestId };
  }

  /** Applies every plan in store order, rolls back on a failure (doc 5.2), and
   * records one entry per change, shaped by `shape` (an approval's facts). */
  private async applyAll(target: SettingsTarget, stores: SettingsStores, planned: readonly Planned[], context: ChangeContext, shape: (entry: ChangeEntry) => ChangeEntry) {
    const apply = async (appliers?: SessionAppliers) => {
      const adoptions = await this.homeChapterAdoptions(stores, planned, context, context.session?.modelRuntime ?? this.model.owner.modelRuntime, appliers);
      const ordered = [...planned, ...adoptions].sort((a, b) => STORE_ORDER[a.binding.store] - STORE_ORDER[b.binding.store]);
      // SDK adoption is an effect of the recipe, not another observed choice.
      const outside = this.model.owner.outsideChanges;
      const writes = this.model.owner.observedWrites(planned, stores.project?.root);
      const landed = new Map<string, { git?: GitResult; changeId: string }>();
      await outside?.begin(writes);
      try {
        const result = await this.applyBracketed(target, stores, ordered, context, shape);
        for (const done of result.filter(done => !done.plan.target)) landed.set(done.plan.changeId, { ...(done.git ? { git: done.git } : {}), changeId: done.plan.changeId });
        return result;
      } finally {
        await outside?.end(writes, landed);
      }
    };
    if (target.kind !== "home" || !context.homeChapter || !planned.some(adoptsHomeRuntime)) return apply();
    // Admission, publication and SDK adoption share the Home runtime's existing lane.
    return context.homeChapter.mutate(async admission => {
      if ("error" in admission) {
        await this.record.append(planned.map(plan => shape(this.entry(target, plan, context, "failed", admission.error.message))));
        throw admission.error;
      }
      return apply(admission.appliers);
    });
  }

  /** Home's durable recipe owns the choice. The runtime adopts its admitted
   * value under its lane; that SDK effect is not a second Session edit. */
  private async homeChapterAdoptions(stores: SettingsStores, planned: readonly Planned[], context: ChangeContext, runtime: ModelRuntime, appliers?: SessionAppliers): Promise<Planned[]> {
    const chapter = context.homeChapter;
    if (!appliers || !chapter) return [];
    const relevant = planned.filter(adoptsHomeRuntime);
    const sessionTarget: SettingsTarget = { kind: "session", sessionId: chapter.sessionId };
    const { sessionId: _sessionId, mutate: _mutate, ...source } = chapter;
    const session = { ...source, appliers };
    const sessionStores = await this.model.owner.stores(sessionTarget, session, { storeState: false });
    // Home's view after this bundle: Home resolves its saved settings, never its chapter.
    const profile = structuredClone(stores.home ?? {});
    for (const plan of relevant) {
      const path = (plan.binding as Extract<Binding, { store: "home" }>).path;
      if (plan.after === undefined) unsetPath(profile, path); else setPath(profile, path, plan.after);
    }
    const resolution = resolveSettings(this.model.schema, sessionTarget, { ...sessionStores, home: profile },
      { ...this.model.owner.resolveOptions(runtime), keys: relevant.map(plan => plan.key.id) });
    const adoptions: Planned[] = [];
    // Model first: a model change can clamp thinking, which is then adopted.
    for (const plan of [...relevant].sort((left, right) => left.key.order - right.key.order)) {
      const row = resolution.keys.find(candidate => candidate.key === plan.key.id);
      if (row?.value === undefined) continue;
      // The saved change owns the choice: this is its SDK effect, not a second edit.
      const binding = plan.key.layers.session!;
      const adoption: Planned = { ...plan, binding,
        request: { key: plan.key.id, layer: "session", op: "set", value: row.value },
        before: readBinding(sessionStores, "session", binding, plan.qualifiers, false, plan.key.id), after: row.value };
      const current = sessionStores.session?.fixed?.[plan.key.id];
      if (deepEqual(adoption.before, adoption.after) && current?.from === row.layer) continue;
      adoptions.push({ ...adoption, target: sessionTarget, session, fixedAt: {
        value: adoption.after, from: row.layer, at: this.now().toISOString(), ref: randomUUID(), ...(row.qualifiers ? { qualifiers: row.qualifiers } : {}),
      } });
    }
    return adoptions;
  }

  private async applyBracketed(target: SettingsTarget, stores: SettingsStores, ordered: readonly Planned[], context: ChangeContext, shape: (entry: ChangeEntry) => ChangeEntry) {
    const applied: Array<{ plan: Planned; revision?: number; git?: GitResult; result?: unknown }> = [];
    let failure: { plan: Planned; error: GatewayError } | undefined;
    for (const plan of ordered) {
      try {
        const result = await this.model.owner.applyStore(target, stores, plan, plan.after, context, this.writers);
        applied.push({ plan, ...result });
      } catch (error) {
        failure = { plan, error: error instanceof GatewayError ? error : new GatewayError("internal", error instanceof Error ? error.message : String(error)) };
        break;
      }
    }
    if (failure) {
      // Roll back the stores already changed, newest first (doc 5.2).
      for (const done of [...applied].reverse()) {
        await this.model.owner.applyStore(target, stores, done.plan, done.plan.before, context, this.writers).catch(() => undefined);
      }
      await this.record.append(ordered.filter(plan => !plan.target).map(plan => shape(this.entry(target, plan, context, "failed",
        plan.changeId === failure!.plan.changeId ? failure!.error.message : "Rolled back: another change in the same request failed"))));
      throw failure.error;
    }
    const entries = applied.filter(done => !done.plan.target).map(done => shape(this.entry(target, done.plan, context, "applied", undefined, done.git)));
    await this.record.append(entries);
    return applied.map(done => ({ ...done, changeId: entries.find(entry => entry.changeId === done.plan.changeId || entry.refersTo === done.plan.changeId)!.changeId }));
  }

  private outcomes(applied: ReadonlyArray<{ plan: Planned; changeId: string; revision?: number; git?: GitResult; result?: unknown }>, status: ChangeStatus): ChangeOutcome[] {
    return applied.map(({ plan, changeId, revision, git, result }) => ({
      changeId, key: plan.key.id, ...(Object.keys(plan.qualifiers).length ? { qualifiers: plan.qualifiers } : {}),
      layer: plan.request.layer, status, tier: plan.tier, ...outcomeValues(plan.key.redacted, plan.before, plan.after),
      ...(revision === undefined ? {} : { revision }), ...(git ? { git } : {}),
      ...(result === undefined ? {} : { result }),
    }));
  }

  private async plan(target: SettingsTarget, stores: SettingsStores, request: ChangeRequest, context: ChangeContext, runtime: ModelRuntime): Promise<Planned> {
    const key = keyForHome(declaredKey(this.model.schema, request.key), stores.layers.includes("home"));
    // The retained repository applier is reachable only through verified Undo,
    // never through a new agent/UI request or Apply again.
    if (request.layer === "project" && !context.undoOf) {
      throw new GatewayError("invalid_request", "Project settings are read-only; edit the repository");
    }
    const store = storeForScope(request.layer, stores.layers);
    const binding = scopeAdmitted(key, store) || (request.layer === "project" && context.undoOf) ? key.layers[store] : undefined;
    if (!binding) throw new GatewayError("invalid_request", `${key.label} cannot be set at the ${LAYER_LABELS[request.layer]} layer`);
    if (!stores.layers.includes(store)) throw new GatewayError("invalid_request", `This target has no ${LAYER_LABELS[request.layer]} layer`);
    const writer = context.actor.kind === "outside" ? undefined : context.actor.kind;
    if (!writer || !key.writers.includes(writer)) throw new GatewayError("invalid_request", `${key.label} cannot be changed by ${context.actor.kind}`);
    if (request.layer === "project" && stores.project && !stores.project.applied) {
      throw new GatewayError("trust_required", "Trust this project before changing its project settings");
    }
    for (const [name, value] of Object.entries(key.fixed ?? {})) {
      const named = request.qualifiers?.[name as keyof Qualifiers];
      if (named !== undefined && named !== value) throw new GatewayError("invalid_request", `${key.id} is the ${name}=${value} instance; ${name}=${named} is a different setting`);
    }
    const qualifiers: Qualifiers = { ...(request.qualifiers ?? {}), ...(key.fixed ?? {}) };
    // A project or chat target names its own project; only the Mac target
    // takes a project qualifier from the request (its canonical path).
    if (key.qualifier === "project" && target.kind !== "global" && stores.project) {
      if (request.qualifiers?.project !== undefined && request.qualifiers.project !== stores.project.root) {
        throw new GatewayError("invalid_request", `${key.label} for another project belongs to that project's target`);
      }
      qualifiers.project = stores.project.root;
    }
    if (key.qualifier === "project" && !qualifiers.project) throw new GatewayError("invalid_request", `${key.label} needs a project`);
    // Trust is keyed by the Project root (TrustInspection.projectDir), so a path a
    // Mac or Home request names reads, plans and writes its root's decision. A
    // path that does not exist yet keeps its name; applying it fails as before.
    if (key.qualifier === "project" && qualifiers.project !== stores.project?.root) {
      qualifiers.project = await this.model.owner.projectRoot(qualifiers.project!).catch(() => qualifiers.project!);
    }
    if (key.qualifier === "key" && !this.model.schema.floorInstances().some(instance => instance.key === qualifiers.key && instance.direction === qualifiers.direction)) {
      throw new GatewayError("invalid_request", `${key.label} names a setting and, when its floor differs by direction, that direction`);
    }
    if (bindingNeedsModel(binding) && !qualifiers.model) {
      const chatModel = stores.session?.model;
      if (request.layer === "session" && chatModel) qualifiers.model = `${chatModel.provider}/${chatModel.id}`;
      else throw new GatewayError("invalid_request", `${key.label} needs a model qualifier`);
    }
    const projectBinding = key.layers.project;
    if (request.layer === "session" && key.projectSettable && projectBinding && stores.project?.applied) {
      const value = readBinding(stores, "project", projectBinding, qualifiers, true, key.id)
        ?? readBinding(stores, "project", projectBinding, qualifiers, false, key.id);
      if (value !== undefined) throw new GatewayError("conflict", `${key.label} is set by ${join(stores.project.root, ".pi", "settings.json")}; edit its Project key instead. The Session override is retained inactive.`);
    }
    if (binding.store === "session-launch") throw new GatewayError("invalid_request", "Delegation launch inputs are read-only");
    if (binding.store === "session-settings" && !hasSessionSettingsApplier(key)) {
      throw new GatewayError("unsupported", `${key.label} has no writable ${LAYER_LABELS[request.layer]} store yet`);
    }
    let after: unknown;
    if (request.op === "set") {
      after = await key.type.validate(request.value, key.id, { admitModel: (ref, options) => this.model.owner.admitModel(runtime, ref,
        { ...options, physical: options?.physical || stores.layers.includes("home") }) });
      if (store === "home" && key.optionsSource?.name === "catalog.tools") {
        const names = key.home?.defaultValue;
        if (!Array.isArray(names) || !Array.isArray(after) || after.some(name => typeof name !== "string" || !names.includes(name))) {
          throw new GatewayError("invalid_request", "Home tools must stay within its curated executable ceiling");
        }
      }
      if (key.optionsSource?.name === "catalog.contextWindow") after = this.model.owner.contextWindowValue(runtime, qualifiers.model, after);
      if (key.type.encode && binding.store === "pi") {
        // A chosen selection is stored in the layer's own form (relative or plain).
        after = key.type.encode(after, composedBelow(stores, key, qualifiers, store),
          readBinding(stores, store, binding, qualifiers, false, key.id));
        if (after === undefined) {
          const { value: _chosen, ...rest } = request;
          request = { ...rest, op: "unset" };
        } else request = { ...request, value: after };
      }
    } else if (request.op !== "unset") {
      throw new GatewayError("invalid_request", "op must be set or unset");
    }
    let fixedAt: FixedSetting | undefined;
    if (request.op === "unset" && (binding.store === "session" || binding.store === "session-settings") && key.timing === "fixed") {
      // A fixed key never starts following a moving default: reset resolves
      // below its Session value now and records another explicit start snapshot.
      const chat = structuredClone(stores.session!);
      if (binding.store === "session") delete chat[binding.field];
      else unsetPath(chat.settings, binding.path);
      if (chat.fixed) delete chat.fixed[key.id];
      const resolution = resolveSettings(this.model.schema, target, { ...stores, session: chat }, { ...this.model.owner.resolveOptions(runtime), keys: [key.id] });
      const row = resolution.keys.find(row => row.key === key.id);
      after = row?.value;
      if (after === undefined && binding.store === "session" && binding.field === "contextWindow" && qualifiers.model) {
        after = this.model.owner.defaultContextWindow(runtime, qualifiers.model);
      }
      if (after === undefined) throw new GatewayError("conflict", `No current default is available for ${key.label}`);
      after = await key.type.validate(after, key.id, { admitModel: (ref, options) => this.model.owner.admitModel(runtime, ref, options) });
      fixedAt = { value: after, from: row?.layer ?? "global", at: this.now().toISOString(), ref: randomUUID(), ...(row?.qualifiers ? { qualifiers: row.qualifiers } : {}) };
      request = { ...request, op: "set", value: after };
    }
    // A trust write records this project's own decision: its `before` is that
    // exact entry (absent when only a parent's decision covered it), so undo
    // restores "no decision of its own" rather than copying the parent's.
    const before = binding.store === "trust" ? stores.trust[qualifiers.project!]
      : readBinding(stores, store, binding, qualifiers, qualifiedWrite(binding, qualifiers), key.id);
    if (request.expected !== undefined && binding.store !== "session" && !deepEqual(request.expected, before)) {
      throw new GatewayError("conflict", `${key.label} changed since it was read; refresh and try again`, false, { current: (before ?? null) as never });
    }
    const defaultValue = keyDefault(key, qualifiers);
    // A composing layer's entries are relative: compare what each value selects.
    const below = key.type.compose ? composedBelow(stores, key, qualifiers, store) : defaultValue;
    const selects = (value: unknown) => value === undefined ? below : key.type.compose ? key.type.compose(below, value) : value;
    const direction = key.direction ? key.direction(selects(before), selects(after)) : "widen";
    const { floor, source } = floorFor(key, direction, stores.floors);
    const web = context.web === true;
    const basis: TierBasis = { direction, floor, floorSource: source, web, risk: null };
    return {
      request, key, binding, qualifiers, before, after,
      tier: raiseTier(floor, web ? 1 : 0), basis,
      changeId: randomUUID(), ...(fixedAt ? { fixedAt } : {}),
    };
  }

  private async assessRisk(plans: Planned[], context: ChangeContext): Promise<void> {
    if (!this.writers.assessRisk || context.actor.kind === "ui" || context.dryRun) return;
    // One deadline for the whole bounded request, not 1.5 seconds per key.
    const signal = AbortSignal.timeout(1_500);
    for (const plan of plans) {
      const { key, basis } = plan;
      try {
        signal.throwIfAborted();
        const assessment = await this.writers.assessRisk({
          key: key.id, layer: plan.request.layer, actor: context.actor.kind, reason: riskReason(context.reason),
          before: key.redacted ? null : riskValue(plan.before), after: key.redacted ? null : riskValue(plan.after),
          redacted: key.redacted === true, direction: basis.direction, floor: basis.floor, web: basis.web,
        }, signal);
        signal.throwIfAborted();
        basis.risk = assessment.tier;
        basis.riskEvaluation = { status: "assessed", rationale: assessment.rationale };
        plan.tier = maxTier(plan.tier, assessment.tier);
      } catch {
        // No provider failure text enters permanent audit: it may echo input.
        basis.riskEvaluation = { status: signal.aborted ? "timeout" : "failed",
          rationale: "Risk evaluation did not complete; the deterministic tier stands." };
      }
    }
  }

  private entry(target: SettingsTarget, plan: Planned, context: ChangeContext, status: ChangeStatus, failure?: string, git?: GitResult): ChangeEntry {
    return {
      ...this.fact(target, this.plannedChange(plan), context, this.now().toISOString(), status),
      ...(failure ? { failure } : {}), ...(git ? { git } : {}),
      ...(context.undoOf ? { undoOf: context.undoOf } : {}),
      ...(context.applyAgainOf ? { applyAgainOf: context.applyAgainOf } : {}),
    };
  }
}

function bindingNeedsModel(binding: Binding): boolean {
  return (binding.store === "pi" && binding.path.includes("{model}")) || (binding.store === "session" && binding.field === "contextWindow");
}

/** A handler's preview, bounded and canonical, so the digest binds exactly what is shown. */
function actionPreview(preview: ApprovalActionPreview): ApprovalActionPreview {
  const text = (value: unknown, max: number, name: string) => {
    if (typeof value !== "string" || !value.trim() || value.length > max) throw new GatewayError("invalid_request", `Approval action ${name} must be 1 to ${max} characters`);
    return value;
  };
  if (!Array.isArray(preview.items) || preview.items.length > ACTION_ITEMS) throw new GatewayError("invalid_request", `An approval action shows at most ${ACTION_ITEMS} items`);
  return {
    title: text(preview.title, 200, "title"), target: preview.target,
    items: preview.items.map(item => ({ label: text(item.label, 80, "item label"), value: text(item.value, 1_000, "item value"),
      ...(item.detail === undefined ? {} : { detail: text(item.detail, 1_000, "item detail") }) })),
  };
}
