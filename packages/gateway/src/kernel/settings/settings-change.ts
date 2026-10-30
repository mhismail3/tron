import { createHash, randomUUID } from "node:crypto";
import { join } from "node:path";
import type { ModelRuntime } from "../pi/coding-agent.js";
import { asUncertainOutcome, GatewayError } from "../../errors.js";
import { AsyncMutex } from "../../util/async-mutex.js";
import { type ConfirmChange, type ChangeRequest, type SettingsSignal, type ChangeOutcome, type ChangeResult, type ChangeStatus, type GitResult, type FixedSetting, type SettingsTarget, type Direction, type LayerId, type Qualifiers } from "./tool-contract.js";
import type { Actor, ActorKind, ChangeEntry, SettingsChangeRecord } from "./settings-record.js";
import { composedBelow, readBinding, resolveSettings } from "./settings-resolver.js";
import { HOME_PROFILE_SUBJECT, keyDefault, hasSessionSettingsApplier, keyForHome, type Binding, type KeyDeclaration } from "./settings-schema.js";
import { changeReview, formatStoredSetting, LAYER_LABELS, type ModelRefValue, type SettingsStores, type PlannedWrite } from "./settings-types.js";
import { canonicalSettingsTarget, scopeAdmitted, storeForScope } from "./scope-resolution.js";
import { SettingsModel, declaredKey, deepEqual, setPath, unsetPath, qualifiedWrite, type SessionSettingsSource, type SettingsReadOwner } from "./settings-model.js";

export interface SessionAppliers {
  /** Runtime-owned admission, checked before holding a diff and by dry run too. */
  admit?(key: KeyDeclaration, layer: LayerId): void;
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
  changes: Array<{ changeId: string; label: string; before?: string; after?: string; effect: KeyDeclaration["effect"] }>;
}

export interface ChangeContext {
  actor: Actor;
  reason?: string;
  commandId?: string;
  dryRun?: boolean;
  /** Only the paired-native route can supply a reviewed digest. */
  confirmationDigest?: string;
  confirm?: ConfirmChange;
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
  /** Trust's applier: TrustService.setAndApply with the runtime reload. Returns
   * the resulting trust inspection, which the change outcome carries. */
  setTrust(project: string, decision: boolean | null): Promise<unknown>;
  /** Home owns learned-profile validation and restoration under auditSubject. */
  undoSubject?(entry: ChangeEntry, context: Omit<ChangeContext, "undoOf">): Promise<ChangeResult>;
}

/** A subject operation restores partial writes before returning failed; the domain projects its typed result. */
export interface SubjectWrite { id: string; before: unknown; after: unknown; direction: "widen" | "narrow"; undoOf?: string }
export type SubjectContext = Pick<ChangeContext, "actor" | "reason"> & { commandId: string };
export type SubjectMutation<T> = { context: SubjectContext; writes: readonly SubjectWrite[] } & (
  { status: "applied"; result: T } | { status: "failed"; error: unknown; failure: string }
);

export interface SettingsObserver {
  applied(target: SettingsTarget, changes: readonly ChangeOutcome[], context: { actor: Actor; reason?: string }): void | Promise<void>;
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

export interface Planned {
  request: ChangeRequest;
  key: KeyDeclaration;
  binding: Binding;
  qualifiers: Qualifiers;
  before: unknown;
  after: unknown;
  direction: Direction;
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
  "pi": 0, "pi-model-ref": 0, "trust": 1, "mac-terminal": 1, "mac-terminal-service": 1, "home": 3, "gateway": 4, "session": 5, "session-settings": 5, "session-launch": 5,
};

export type StoreApplyResult = { revision?: number; git?: GitResult; result?: unknown };

export class SettingsChangePath {
  private readonly stripes = Array.from({ length: 32 }, () => new AsyncMutex());
  private observer: SettingsObserver | undefined;
  private disposed = false;
  private startup: Promise<void> | undefined;

  constructor(private readonly model: SettingsModel<SettingsChangeOwner>, readonly record: SettingsChangeRecord,
    private readonly writers: SettingsWriters, private readonly now: () => Date = () => new Date()) {}

  private mutexFor(target: SettingsTarget): AsyncMutex {
    const id = target.kind === "session" ? `session:${target.sessionId}` : target.kind === "project" ? `project:${target.cwd}` : target.kind;
    return this.stripes[createHash("sha256").update(id).digest().readUInt32BE(0) % this.stripes.length]!;
  }

  async start(): Promise<void> {
    if (this.disposed) throw new GatewayError("conflict", "Settings changes are disposed");
    // A corrupt audit refuses writes/history, not unrelated Gateway startup or reads.
    await (this.startup ??= this.record.recover().catch(() => process.emitWarning(
      "Settings history recovery refused; inspect its bounded record before further writes", { code: "TRON_SETTINGS_HISTORY_UNAVAILABLE" })));
  }

  async dispose(): Promise<void> { this.disposed = true; await this.startup; }

  /** Typed domains share the real target stripe, not a second action queue. */
  withTarget<T>(target: SettingsTarget, operation: () => Promise<T>): Promise<T> {
    if (this.disposed) throw new GatewayError("conflict", "Settings changes are disposed");
    return this.mutexFor(target).run(operation);
  }

  observe(observer: SettingsObserver): void {
    if (this.observer && this.observer !== observer) throw new Error("Settings changes already have an observer");
    this.observer = observer;
  }

  async change(target: SettingsTarget, requests: readonly ChangeRequest[], context: ChangeContext): Promise<ChangeResult> {
    target = canonicalSettingsTarget(target, context.session?.home === true);
    if (!requests.length || requests.length > 50) throw new GatewayError("invalid_request", "A settings change holds 1 to 50 changes");
    if (context.actor.kind !== "ui" && !context.reason?.trim()) throw new GatewayError("invalid_request", "A reason is required for an agent change");
    if (context.confirmationDigest && context.actor.kind !== "ui") throw new GatewayError("invalid_request", "Only a paired native answer confirms a reviewed change");
    const result = await this.withTarget(target, () => this.changeInStripe(target, requests, context));
    if (result.status !== "review" || !context.confirm || context.dryRun) return result;
    const review = result.review!;
    const exact = structuredClone(requests);
    return await context.confirm(review, acceptance => this.withTarget(target, () => {
      // Resolve runtime-owned getters only after reacquiring the actual stripe.
      // A snapshot captured before the human wait must not authorize an effect.
      const { confirm: _confirm, ...current } = context;
      return this.changeInStripe(target, exact, { ...current, actor: { kind: "ui", id: acceptance.deviceId },
        commandId: acceptance.commandId, confirmationDigest: review.digest });
    })) ?? { status: "declined", changes: [] };
  }

  private async changeInStripe(target: SettingsTarget, requests: readonly ChangeRequest[], context: ChangeContext): Promise<ChangeResult> {
    await this.record.recover();
    const stores = await this.model.owner.stores(target, context.session);
    const runtime = context.session?.modelRuntime ?? this.model.owner.modelRuntime;
    const planned: Planned[] = [];
    const errors = new Map<number, GatewayError>();
    for (const [index, request] of requests.entries()) {
      try { planned.push(await this.plan(target, stores, request, context, runtime)); }
      catch (error) {
        if (!context.dryRun) throw error;
        errors.set(index, error instanceof GatewayError ? error : new GatewayError("invalid_request", String(error)));
      }
    }
    const requiresTap = planned.some(plan => plan.key.tap && (plan.key.tap !== "spend" || plan.direction === "widen"));
    const review = changeReview({ target, undoOf: context.undoOf, applyAgainOf: context.applyAgainOf, planned: planned.map(plan => ({
      key: plan.key.id, layer: plan.request.layer, qualifiers: plan.qualifiers, op: plan.request.op, before: plan.before ?? null, after: plan.after ?? null })) },
      { title: planned.map(plan => plan.key.label).join(", "), requiresTap, ...(context.reason ? { reason: context.reason } : {}),
        items: planned.map(plan => ({ label: plan.key.label, before: plan.key.redacted ? "Hidden" : formatStoredSetting(plan.key.type, plan.before),
          after: plan.key.redacted ? "Hidden" : formatStoredSetting(plan.key.type, plan.after),
          detail: [LAYER_LABELS[plan.request.layer] + " stored value", target.kind === "session" ? target.sessionId : target.kind === "project" ? target.cwd : target.kind, plan.key.confirm].filter(Boolean).join("\n"),
          ...(plan.key.redacted ? {} : { exact: JSON.stringify({ target, key: plan.key.id, layer: plan.request.layer, qualifiers: plan.qualifiers, op: plan.request.op, before: plan.before ?? null, after: plan.after ?? null }) }) })) });
    if (context.confirmationDigest && context.confirmationDigest !== review.digest) throw new GatewayError("conflict", "The reviewed change is stale; nothing was applied");
    if (context.dryRun) {
      let next = 0;
      return { dryRun: true, status: errors.size ? "failed" : requiresTap ? "review" : "applied", review,
        changes: requests.map((request, index) => {
          const error = errors.get(index);
          if (error) return { changeId: "", key: request.key, layer: request.layer, status: "failed", error: { code: error.code, message: error.message } };
          const plan = planned[next++]!;
          return { changeId: "", key: plan.key.id, ...(Object.keys(plan.qualifiers).length ? { qualifiers: plan.qualifiers } : {}), layer: request.layer,
            status: "applied", ...outcomeValues(plan.key.redacted, plan.before, plan.after) };
        }) };
    }
    if (requiresTap && !context.confirmationDigest) return { status: "review", review, changes: [] };
    const applied = await this.applyAll(target, stores, planned, context, entry => entry);
    const changes = this.outcomes(applied.filter(done => !done.plan.target), "applied");
    const adopted = this.outcomes(applied.filter(done => done.plan.target), "applied");
    await this.observer?.applied(target, changes, { actor: context.actor, ...(context.reason ? { reason: context.reason } : {}) });
    if (adopted.length) await this.observer?.applied(applied.find(done => done.plan.target)!.plan.target!, adopted, { actor: context.actor, ...(context.reason ? { reason: context.reason } : {}) });
    const signal = await this.announce(changes, context);
    return { status: "applied", changes, review, ...(signal ? { signal } : {}) };
  }

  /** Home's learned subject shares the settings stripe, audit and observer cut.
   * The domain projects its typed result after the observer, still under the stripe. */
  async auditSubject<T, R>(operation: () => Promise<SubjectMutation<T>>, project: (result: T, audit: ChangeResult) => Promise<R>): Promise<R> {
    return this.mutexFor({ kind: "home" }).run(() => this.auditSubjectInStripe(operation, project));
  }

  /** The Home domain supplies effects and rollback; failed diffs remain ungrouped. */
  private async auditSubjectInStripe<T, R>(operation: () => Promise<SubjectMutation<T>>, project: (result: T, audit: ChangeResult) => Promise<R>): Promise<R> {
      await this.record.recover();
      const mutation = await operation();
      if (mutation.status === "failed") {
        if (mutation.writes.length) await this.record.append(mutation.writes.map(write => this.subjectEntry(write, mutation.context, "failed", mutation.failure)));
        throw mutation.error;
      }
      const group = { id: randomUUID(), size: mutation.writes.length };
      const entries = mutation.writes.map(write => ({ ...this.subjectEntry(write, mutation.context, "applied"), group,
        ...(write.undoOf ? { undoOf: write.undoOf } : {}) }));
      await this.record.append(entries).catch(error => { throw asUncertainOutcome(error, "Profile applied but history publication failed"); });
      const changes: ChangeOutcome[] = entries.map(entry => ({
        changeId: entry.changeId, key: entry.key, qualifiers: entry.qualifiers!, layer: "session", status: "applied",
        before: entry.before ?? null, after: entry.after ?? null,
      }));
      const context = mutation.context;
      await this.observer?.applied({ kind: "home" }, changes, { actor: context.actor, ...(context.reason ? { reason: context.reason } : {}) });
      return project(mutation.result, { status: "applied", changes });
  }

  /** Home freezes these original inputs in its existing backup before domain effects. */
  validateSubjectAudit(writes: readonly SubjectWrite[], context: SubjectContext, replayAt: string): void {
    this.record.validateAppendOnce(this.subjectPublication(writes, context, replayAt));
  }

  /** Publishes only facts for proven committed effects; it never replays the domain. */
  async publishSubjectAudit(writes: readonly SubjectWrite[], context: SubjectContext, replayAt: string): Promise<ChangeResult> {
    if (this.disposed) throw new GatewayError("conflict", "Settings changes are disposed");
    return this.mutexFor({ kind: "home" }).run(() => this.publishSubjectAuditInStripe(writes, context, replayAt));
  }

  private async publishSubjectAuditInStripe(writes: readonly SubjectWrite[], context: SubjectContext, replayAt: string): Promise<ChangeResult> {
    const entries = this.subjectPublication(writes, context, replayAt);
      await this.record.appendOnce(entries);
      const changes: ChangeOutcome[] = entries.map(entry => ({ changeId: entry.changeId, key: entry.key, qualifiers: entry.qualifiers!,
        layer: "session", status: "applied", before: entry.before ?? null, after: entry.after ?? null }));
      if (entries.length) await this.observer?.applied({ kind: "home" }, changes, { actor: context.actor, ...(context.reason ? { reason: context.reason } : {}) });
      return { status: "applied", changes };
  }

  private subjectPublication(writes: readonly SubjectWrite[], context: SubjectContext, replayAt: string): ChangeEntry[] {
    if (!context.commandId?.trim() || !Number.isFinite(Date.parse(replayAt)) || new Set(writes.map(write => write.id)).size !== writes.length
      || writes.some(write => !write.id || !["widen", "narrow"].includes(write.direction))) {
      throw new GatewayError("invalid_request", "Home audit requires its original command, timestamp and unique ordered writes");
    }
    const digest = (value: unknown) => createHash("sha256").update(JSON.stringify(value)).digest("hex");
    const group = { id: `home-profile:${digest(context.commandId)}`, size: writes.length };
    return writes.map(write => ({ ...this.subjectEntry(write, context, "applied", undefined,
      { at: replayAt, changeId: `home-profile-entry:${digest([context.commandId, write.id])}` }), group,
      ...(write.undoOf ? { undoOf: write.undoOf } : {}) }));
  }

  private subjectEntry(write: SubjectWrite, context: SubjectContext, status: ChangeStatus, failure?: string,
    identity: { changeId: string; at: string } = { changeId: randomUUID(), at: this.now().toISOString() }): ChangeEntry {
    return {
      ...identity, commandId: context.commandId, actor: context.actor, target: { kind: "home" },
      layer: "session", key: HOME_PROFILE_SUBJECT.id, qualifiers: { note: write.id }, op: "set",
      ...(write.before === null ? {} : { before: write.before }), ...(write.after === null ? {} : { after: write.after }),
      ...(context.reason ? { reason: context.reason } : {}),
      status, ...(failure ? { failure } : {}),
    };
  }

  /** Undo checks the original identity and its expected after value in the actual target stripe. */
  async undo(changeId: string, context: Omit<ChangeContext, "undoOf">, session?: ChangeContext["session"]): Promise<ChangeResult> {
    const found = await this.record.entry(changeId);
    if (!found) throw new GatewayError("not_found", "No such settings change");
    if (found.entry.key === HOME_PROFILE_SUBJECT.id) {
      if (!this.writers.undoSubject) throw new GatewayError("unsupported", "Knowledge is not available on this Gateway");
      return this.writers.undoSubject(found.entry, context);
    }
    const result = await this.withTarget(found.entry.target, async () => {
      const current = await this.record.entry(changeId);
      if (!current || current.undone) throw new GatewayError("conflict", "This change has already been undone");
      const { entry } = current;
      if (entry.action || entry.redacted) throw new GatewayError("conflict", "This change has no supported inverse; inspect it with its owner");
      if (entry.status !== "applied") throw new GatewayError("conflict", "Only an applied change can be undone");
      return this.changeInStripe(entry.target, [{
        key: entry.key, ...(entry.qualifiers ? { qualifiers: entry.qualifiers } : {}), layer: entry.layer,
        op: entry.before === undefined ? "unset" : "set", ...(entry.before === undefined ? {} : { value: entry.before }),
        expected: entry.after ?? null,
      }], { ...context, undoOf: changeId, ...(session ? { session } : {}) });
    });
    return result;
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

  private async announce(changes: readonly ChangeOutcome[], context: ChangeContext): Promise<SettingsSignal | undefined> {
    const announce = context.session?.appliers.announce;
    const chat = changes.filter(change => change.layer === "session");
    if (!announce || chat.length === 0) return undefined;
    return announce({
      actor: context.actor, ...(context.reason ? { reason: context.reason } : {}),
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
  /** Applies every plan in store order, rolls back on a failure (doc 5.2), and
   * records one entry per change, with the canonical before/after facts. */
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
    await this.record.append(entries).catch(error => {
      // Store effects already landed: retain the canonical receipt's replay fence.
      throw asUncertainOutcome(error, "Settings applied but history publication failed");
    });
    return applied.map(done => ({ ...done, changeId: entries.find(entry => entry.changeId === done.plan.changeId || entry.refersTo === done.plan.changeId)!.changeId }));
  }

  private outcomes(applied: ReadonlyArray<{ plan: Planned; changeId: string; revision?: number; git?: GitResult; result?: unknown }>, status: ChangeStatus): ChangeOutcome[] {
    return applied.map(({ plan, changeId, revision, git, result }) => ({
      changeId, key: plan.key.id, ...(Object.keys(plan.qualifiers).length ? { qualifiers: plan.qualifiers } : {}),
      layer: plan.request.layer, status, ...outcomeValues(plan.key.redacted, plan.before, plan.after),
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
    if (request.expected !== undefined && !deepEqual(request.expected, before ?? null)) {
      throw new GatewayError("conflict", `${key.label} changed since it was read; refresh and try again`, false, { current: (before ?? null) as never });
    }
    const defaultValue = keyDefault(key, qualifiers);
    // A composing layer's entries are relative: compare what each value selects.
    const below = key.type.compose ? composedBelow(stores, key, qualifiers, store) : defaultValue;
    const selects = (value: unknown) => value === undefined ? below : key.type.compose ? key.type.compose(below, value) : value;
    const direction = key.direction ? key.direction(selects(before), selects(after)) : "widen";
    context.session?.appliers.admit?.(key, request.layer);
    return {
      request, key, binding, qualifiers, before, after,
      direction,
      changeId: randomUUID(), ...(fixedAt ? { fixedAt } : {}),
    };
  }

  private entry(target: SettingsTarget, plan: Planned, context: ChangeContext, status: ChangeStatus, failure?: string, git?: GitResult): ChangeEntry {
    return { changeId: plan.changeId, at: this.now().toISOString(), actor: context.actor, target,
      ...(context.commandId ? { commandId: context.commandId } : {}), key: plan.key.id, layer: plan.request.layer, op: plan.request.op,
      ...(Object.keys(plan.qualifiers).length ? { qualifiers: plan.qualifiers } : {}),
      ...(plan.fixedAt ? { fixedAt: plan.fixedAt } : {}),
      ...(plan.key.redacted ? { changed: true as const, redacted: true as const } : {
        ...(plan.before === undefined ? {} : { before: plan.before }), ...(plan.after === undefined ? {} : { after: plan.after }) }),
      ...(context.reason ? { reason: context.reason } : {}), status,
      ...(failure ? { failure } : {}), ...(git ? { git } : {}),
      ...(context.undoOf ? { undoOf: context.undoOf } : {}), ...(context.applyAgainOf ? { applyAgainOf: context.applyAgainOf } : {}) };
  }
}

function bindingNeedsModel(binding: Binding): boolean {
  return (binding.store === "pi" && binding.path.includes("{model}")) || (binding.store === "session" && binding.field === "contextWindow");
}

