import { createHash, randomUUID } from "node:crypto";
import { watch, type FSWatcher } from "node:fs";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { GatewayError } from "../errors.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { durableAtomicWriteJson } from "../util/durable-json.js";
import { readJsonDocument } from "../util/json.js";
import { gitHeadState, projectSettingsPath, stagedBlob, type GitHeadState } from "./project-settings-writer.js";
import type { ChangeEntry, GitResult, SettingsChangeRecord } from "./settings-record.js";
import type { OutsideMark } from "./settings-resolver.js";
import { KEYS, builtinValue, floorFor, recordSubject, schemaKey, type Binding, type FloorOverrides, type KeyDeclaration } from "./settings-schema.js";
import { formatStoredSetting, type Qualifiers, type Tier } from "./settings-types.js";

/**
 * Outside changes (docs/settings-model.md 5.6, foundation F2).
 *
 * The stores Tron does not own exclusively are compared with what Tron last
 * observed in them: the Mac `settings.json`, `trust.json`, `mcp.json` and
 * `models.json`, and each known project's `.pi/settings.json` and `.pi/mcp.json`.
 * A per-key difference Tron did not write is one `outside` record entry, whatever
 * caused it (a hand edit, a pull, a revert, a stash, a branch switch, the pi CLI):
 * there are no per-git-case rules. `mcp.json` and `models.json` are compared per
 * record subject (one MCP server, one custom model provider; see
 * `RECORD_SUBJECTS`), by digest only: their definitions can carry credentials.
 *
 * Comparison is by content digest on every settings read and on a file event,
 * so dropped or coalesced events and rename-replace writes cannot hide a change.
 * Tron's own writes bracket the store (`begin`/`end`): a scan never runs while
 * Tron is writing, and `end` adopts Tron's values as observed with the change id
 * that wrote them, which is what later offers Apply again.
 *
 * This owner keeps only the last observed values and their provenance in
 * `<tronHome>/gateway/settings/observed.json`; values are always read from the
 * stores (F2), and the record stays audit only.
 */

export type ObservedStore = { kind: "mac" } | { kind: "trust" } | { kind: "mcp" } | { kind: "models" }
  | { kind: "project"; root: string } | { kind: "project-mcp"; root: string };
type ProjectObservedStore = Extract<ObservedStore, { root: string }>;
const isProjectStore = (store: ObservedStore): store is ProjectObservedStore => store.kind === "project" || store.kind === "project-mcp";

/** The bound on known projects, least recently read first out. */
export const OBSERVED_PROJECT_LIMIT = 64;
const AGENT_FILES = new Set(["settings.json", "trust.json", "mcp.json", "models.json"]);
const PROJECT_FILES = new Set(["settings.json", "mcp.json"]);
const STAGED_LIMIT = 20;

interface ObservedValue { key: string; qualifiers?: Qualifiers; value?: unknown; hash?: string }

interface StoreState {
  digest: string;
  values: Record<string, ObservedValue>;
  /** The Tron change that wrote each instance's current value. */
  tron: Record<string, string>;
  /** The latest outside change of each instance since Tron last wrote it. */
  outside: Record<string, OutsideMark>;
  /** Project stores: Tron's staged writes not yet seen in `HEAD`. */
  staged?: Array<{ changeId: string; path: string; blob: string }>;
  head?: string | null;
  seen: string;
}

interface ObservedDocument { version: 1; stores: Record<string, StoreState> }

export interface OutsideObserver {
  outside(entries: readonly ChangeEntry[]): void | Promise<void>;
}

export interface ObservedReaders {
  /** pi's own reader for the Mac `settings.json`, so parse rules match the runtime. */
  mac(): Promise<Record<string, unknown>>;
  project(root: string): Promise<Record<string, unknown> | undefined>;
  floors(): Promise<FloorOverrides>;
}

/** One planned write the change path brackets: its observed store and instance. */
export interface PlannedWrite { store: ObservedStore; instance: string; changeId: string; value: unknown }

export function storeId(store: ObservedStore): string {
  return isProjectStore(store) ? `${store.kind}:${store.root}` : store.kind;
}

/** The project's `.pi/` stores this owner compares; both follow the Project root. */
export function projectStores(root: string): ObservedStore[] {
  return [{ kind: "project", root }, { kind: "project-mcp", root }];
}

/** The observed file of a store. */
export function observedFile(store: ObservedStore, agentDir: string): string {
  switch (store.kind) {
    case "mac": return join(agentDir, "settings.json");
    case "trust": return join(agentDir, "trust.json");
    case "mcp": return join(agentDir, "mcp.json");
    case "models": return join(agentDir, "models.json");
    case "project": return projectSettingsPath(store.root);
    case "project-mcp": return join(store.root, ".pi", "mcp.json");
  }
}

export function instanceId(key: string, qualifiers: Qualifiers | undefined): string {
  const sorted = Object.fromEntries(Object.entries(qualifiers ?? {}).sort(([left], [right]) => left.localeCompare(right)));
  return `${key}\u0000${JSON.stringify(sorted)}`;
}

/** The observed store and instance a change to `binding` at `layer` writes, or
 * undefined for stores Tron owns exclusively (Chat, Profile, floors, Home memory). */
export function observedInstance(key: KeyDeclaration, layer: string, binding: Binding, qualifiers: Qualifiers, projectRoot: string | undefined): { store: ObservedStore; instance: string } | undefined {
  const fixed = key.fixed ?? {};
  if (binding.store === "trust") {
    return qualifiers.project === undefined ? undefined : { store: { kind: "trust" }, instance: instanceId(key.id, { ...fixed, project: qualifiers.project }) };
  }
  if (binding.store !== "pi" && binding.store !== "pi-model-ref") return undefined;
  const store: ObservedStore | undefined = layer === "mac" ? { kind: "mac" } : layer === "project" && projectRoot ? { kind: "project", root: projectRoot } : undefined;
  if (!store) return undefined;
  const modelQualified = binding.store === "pi" && qualifiers.model !== undefined
    && (binding.qualified !== undefined || binding.path.includes("{model}"));
  return { store, instance: instanceId(key.id, modelQualified ? { ...fixed, model: qualifiers.model! } : fixed) };
}

function readPath(document: unknown, path: readonly string[]): unknown {
  let current = document;
  for (const segment of path) {
    if (typeof current !== "object" || current === null || Array.isArray(current)) return undefined;
    if (!Object.prototype.hasOwnProperty.call(current, segment)) return undefined;
    current = (current as Record<string, unknown>)[segment];
  }
  return current;
}

function modelsAt(document: Record<string, unknown>, path: readonly string[]): string[] {
  const container = readPath(document, path.slice(0, path.indexOf("{model}")));
  return container && typeof container === "object" && !Array.isArray(container) ? Object.keys(container) : [];
}

/** Every key instance a pi settings document holds at a layer, from the schema. */
export function piInstances(document: Record<string, unknown>, layer: "mac" | "project"): Map<string, ObservedValue> {
  const values = new Map<string, ObservedValue>();
  const add = (key: KeyDeclaration, qualifiers: Qualifiers, value: unknown) => {
    if (value === undefined) return;
    values.set(instanceId(key.id, qualifiers), { key: key.id, ...(Object.keys(qualifiers).length ? { qualifiers } : {}), value });
  };
  for (const key of KEYS) {
    const binding = key.layers[layer];
    const fixed = (key.fixed ?? {}) as Qualifiers;
    if (binding?.store === "pi-model-ref") {
      const provider = document.defaultProvider, id = document.defaultModel;
      if (typeof provider === "string" && typeof id === "string") add(key, fixed, { provider, id });
    }
    if (binding?.store !== "pi") continue;
    for (const path of [binding.path, ...(binding.qualified ? [binding.qualified] : [])]) {
      if (!path.includes("{model}")) { add(key, fixed, readPath(document, path)); continue; }
      for (const model of modelsAt(document, path)) {
        add(key, { ...fixed, model }, readPath(document, path.map(segment => segment === "{model}" ? model : segment)));
      }
    }
  }
  return values;
}

/** One instance per entry of a subject's container (`mcpServers`, `providers`),
 * hashed: a server or provider definition may carry headers, keys or commands. */
function subjectInstances(document: unknown, subjectId: string): Map<string, ObservedValue> | undefined {
  if (!document || typeof document !== "object" || Array.isArray(document)) return undefined;
  const subject = recordSubject(subjectId)!;
  const container = (document as Record<string, unknown>)[subject.container];
  if (container !== undefined && (!container || typeof container !== "object" || Array.isArray(container))) return undefined;
  const values = new Map<string, ObservedValue>();
  for (const [name, definition] of Object.entries((container ?? {}) as Record<string, unknown>)) {
    const qualifiers = { [subject.qualifier]: name } as Qualifiers;
    values.set(instanceId(subject.id, qualifiers), { key: subject.id, qualifiers, hash: createHash("sha256").update(JSON.stringify(definition)).digest("hex") });
  }
  return values;
}

function trustInstances(document: Record<string, unknown>): Map<string, ObservedValue> {
  const key = schemaKey("permissions.projectTrust");
  const values = new Map<string, ObservedValue>();
  for (const [project, decision] of Object.entries(document)) {
    if (typeof decision !== "boolean") continue;
    const qualifiers = { ...(key.fixed ?? {}), project };
    values.set(instanceId(key.id, qualifiers), { key: key.id, qualifiers, value: decision });
  }
  return values;
}

const digestOf = (text: string | undefined) => text === undefined ? "" : createHash("sha256").update(text).digest("hex");

/** Redacted keys are compared by digest; their values never enter observed state or audit. */
function observed(value: ObservedValue): ObservedValue {
  if (!schemaKeyOrUndefined(value.key)?.redacted || value.value === undefined) return value;
  const { value: secret, ...rest } = value;
  return { ...rest, hash: createHash("sha256").update(JSON.stringify(secret)).digest("hex") };
}
const fingerprint = (value: ObservedValue | undefined) => value === undefined ? null : value.hash ?? JSON.stringify(value.value ?? null);
const subjectOf = (store: ObservedStore) => store.kind === "mcp" || store.kind === "project-mcp" ? "tools.mcp.server" : store.kind === "models" ? "accounts.models.provider" : undefined;
function schemaKeyOrUndefined(id: string): KeyDeclaration | undefined { return KEYS.find(key => key.id === id); }

export class OutsideChanges {
  private readonly mutex = new AsyncMutex();
  private readonly writing = new Map<string, number>();
  private document: ObservedDocument | undefined;
  private observer: OutsideObserver | undefined;
  private readonly watchers = new Map<string, FSWatcher>();
  private readonly timers = new Map<string, NodeJS.Timeout>();
  private watching = false;
  private readonly reconciliations = new Set<Promise<void>>();
  private disposal: Promise<void> | undefined;
  private retired = false;
  private failed: ((error: unknown) => void) | undefined;

  constructor(
    private readonly tronHome: string,
    private readonly agentDir: string,
    private readonly record: SettingsChangeRecord,
    private readonly readers: ObservedReaders,
    private readonly now: () => Date = () => new Date(),
  ) {}

  get path(): string { return join(this.tronHome, "gateway", "settings", "observed.json"); }

  observe(observer: OutsideObserver): void {
    if (this.observer && this.observer !== observer) throw new Error("Outside changes already have an observer");
    this.observer = observer;
  }

  /** Compare each store with what Tron last observed; record what changed outside. */
  /** `heads` carries a repository state the caller already read for a project root. */
  reconcile(stores: readonly ObservedStore[], heads?: ReadonlyMap<string, GitHeadState | undefined>): Promise<void> {
    if (this.retired) return Promise.reject(new Error("Outside settings comparison is disposed"));
    const work = this.compareStores(stores, heads);
    this.reconciliations.add(work);
    // Retain the whole comparison, including the observer outside the mutex.
    // The caller still receives its original result/error, never this cleanup.
    void work.then(() => this.reconciliations.delete(work), () => this.reconciliations.delete(work));
    return work;
  }

  private async compareStores(stores: readonly ObservedStore[], heads?: ReadonlyMap<string, GitHeadState | undefined>): Promise<void> {
    const entries: ChangeEntry[] = [];
    await this.mutex.run(async () => {
      const document = await this.load();
      for (const store of stores) {
        if (isProjectStore(store)) this.watchProject(store.root);
        if ((this.writing.get(storeId(store)) ?? 0) > 0) continue;
        entries.push(...await this.compare(document, store, undefined, undefined, isProjectStore(store) ? heads?.get(store.root) : undefined, isProjectStore(store) && heads?.has(store.root)));
      }
      if (entries.length) await this.record.append(entries);
      await this.save(document);
    });
    if (entries.length) await this.observer?.outside(entries);
  }

  /**
   * File events prompt a rescan so an outside change pushes without waiting for
   * a read. Events are lossy (rename-replace, coalescing), so they carry no
   * content: the rescan compares digests. Directories are watched, never files.
   */
  startWatching(failed: (error: unknown) => void): void {
    if (this.disposal) throw new Error("Outside settings comparison is disposed");
    this.watching = true;
    this.failed = failed;
    this.watchDirectory("agent", this.agentDir, name => AGENT_FILES.has(name), [{ kind: "mac" }, { kind: "trust" }, { kind: "mcp" }, { kind: "models" }]);
  }

  dispose(): Promise<void> {
    if (this.disposal) return this.disposal;
    this.watching = false;
    for (const watcher of this.watchers.values()) watcher.close();
    for (const timer of this.timers.values()) clearTimeout(timer);
    this.watchers.clear();
    this.timers.clear();
    this.disposal = (async () => {
      const errors: unknown[] = [];
      // An accepted observer can resolve settings again. Drain that work too;
      // closing file-event admission must not revoke its after-apply effects.
      while (this.reconciliations.size) {
        const results = await Promise.allSettled([...this.reconciliations]);
        errors.push(...results.flatMap(result => result.status === "rejected" ? [result.reason] : []));
      }
      this.retired = true;
      if (errors.length) throw new AggregateError(errors, "Outside settings reconciliation failed during disposal");
    })();
    return this.disposal;
  }

  private watchProject(root: string): void {
    if (!this.watching || this.watchers.has(`project:${root}`)) return;
    // `.pi/` may not exist yet: its parent's events include its creation, and the
    // rescan that event prompts replaces the parent watch with the `.pi/` one.
    if (this.watchDirectory(`project:${root}`, join(root, ".pi"), name => PROJECT_FILES.has(name), projectStores(root))) {
      this.watchers.get(`project-parent:${root}`)?.close();
      this.watchers.delete(`project-parent:${root}`);
      return;
    }
    if (this.watchers.has(`project-parent:${root}`) || this.watchers.size > OBSERVED_PROJECT_LIMIT) return;
    this.watchDirectory(`project-parent:${root}`, root, name => name === ".pi", projectStores(root));
  }

  private watchDirectory(id: string, directory: string, relevant: (name: string) => boolean, stores: ObservedStore[]): boolean {
    try {
      const watcher = watch(directory, { persistent: false }, (_event, name) => {
        if (!this.watching || (name !== null && !relevant(String(name)))) return;
        clearTimeout(this.timers.get(id));
        this.timers.set(id, setTimeout(() => {
          this.timers.delete(id);
          if (!this.watching) return;
          void this.reconcile(stores).catch(error => this.failed?.(error));
        }, 250));
      });
      watcher.on("error", () => { watcher.close(); this.watchers.delete(id); });
      this.watchers.set(id, watcher);
      return true;
    } catch {
      return false;
    }
  }

  /** Marks of the latest outside change per instance for a store, for its rows. */
  async marks(store: ObservedStore): Promise<Record<string, OutsideMark>> {
    const document = await this.mutex.run(() => this.load());
    return { ...(document.stores[storeId(store)]?.outside ?? {}) };
  }

  /** Tron starts writing these stores: no scan may read them until `end`. */
  async begin(writes: readonly PlannedWrite[]): Promise<void> {
    // Under the mutex: a comparison already reading these stores finishes first,
    // so it can never see a half-written Tron change as an outside one.
    await this.mutex.run(async () => {
      for (const id of new Set(writes.map(write => storeId(write.store)))) this.writing.set(id, (this.writing.get(id) ?? 0) + 1);
    });
  }

  /**
   * Tron finished writing. Instances that now hold the value Tron wrote are
   * Tron's (with their change id and staged blob); a planned write that did not
   * land (rolled back) is adopted silently; any other difference happened
   * outside meanwhile and is recorded.
   */
  async end(writes: readonly PlannedWrite[], applied: ReadonlyMap<string, { git?: GitResult; changeId: string }>): Promise<void> {
    const entries: ChangeEntry[] = [];
    await this.mutex.run(async () => {
      const byStore = new Map<string, { store: ObservedStore; writes: PlannedWrite[] }>();
      for (const write of writes) {
        const id = storeId(write.store);
        byStore.set(id, { store: write.store, writes: [...(byStore.get(id)?.writes ?? []), write] });
      }
      try {
        const document = await this.load();
        for (const { store, writes: storeWrites } of byStore.values()) {
          const planned = new Map(storeWrites.map(write => [write.instance, write]));
          entries.push(...await this.compare(document, store, planned, applied));
        }
        if (entries.length) await this.record.append(entries);
        await this.save(document);
      } finally {
        for (const id of byStore.keys()) {
          const count = (this.writing.get(id) ?? 1) - 1;
          if (count > 0) this.writing.set(id, count); else this.writing.delete(id);
        }
      }
    });
    if (entries.length) await this.observer?.outside(entries);
  }

  /**
   * Tron's own writers outside the change path (the MCP and custom-model owners)
   * write a store as Tron: no scan reads it meanwhile, and whatever it then holds
   * is adopted as observed, so Tron's write is never an outside change.
   */
  async adopt<T>(stores: readonly ObservedStore[], write: () => Promise<T>): Promise<T> {
    // First record what already changed outside, so Tron's write cannot absorb it;
    // then hold the stores as Tron's. An outside edit made while the owner's own
    // write runs is indistinguishable from it and is adopted with it.
    const entries: ChangeEntry[] = [];
    await this.mutex.run(async () => {
      const document = await this.load();
      for (const store of stores) {
        if ((this.writing.get(storeId(store)) ?? 0) === 0) entries.push(...await this.compare(document, store));
      }
      if (entries.length) await this.record.append(entries);
      await this.save(document);
      for (const id of new Set(stores.map(storeId))) this.writing.set(id, (this.writing.get(id) ?? 0) + 1);
    });
    if (entries.length) await this.observer?.outside(entries);
    try {
      return await write();
    } finally {
      await this.mutex.run(async () => {
        try {
          const document = await this.load();
          for (const store of stores) await this.rebaseline(document, store);
          await this.save(document);
        } finally {
          for (const id of new Set(stores.map(storeId))) {
            const count = (this.writing.get(id) ?? 1) - 1;
            if (count > 0) this.writing.set(id, count); else this.writing.delete(id);
          }
        }
      });
    }
  }

  private async rebaseline(document: ObservedDocument, store: ObservedStore): Promise<void> {
    const text = await this.raw(store);
    const current = await this.values(store, text);
    if (!current) return;
    const id = storeId(store);
    const state = document.stores[id];
    const values = Object.fromEntries([...current].map(([instance, value]) => [instance, observed(value)]));
    const git = isProjectStore(store) ? await gitHeadState(store.root) : undefined;
    if (!state) {
      document.stores[id] = { digest: digestOf(text), values, tron: {}, outside: {}, ...(git ? { head: git.head, staged: [] } : {}), seen: this.now().toISOString() };
      return;
    }
    // An instance Tron rewrote is no longer the outside value its mark described.
    for (const instance of Object.keys(state.outside)) {
      if (fingerprint(state.values[instance]) !== fingerprint(values[instance])) delete state.outside[instance];
    }
    state.values = values;
    state.digest = digestOf(text);
    state.seen = this.now().toISOString();
    if (git) state.head = git.head;
  }

  private async load(): Promise<ObservedDocument> {
    if (this.document) return this.document;
    const stored = await readJsonDocument(this.path, value => {
      const candidate = value as ObservedDocument;
      if (!candidate || candidate.version !== 1 || typeof candidate.stores !== "object" || candidate.stores === null) {
        throw new GatewayError("conflict", "Observed settings state is invalid");
      }
      return candidate;
    }, 16 * 1024 * 1024);
    this.document = stored ?? { version: 1, stores: {} };
    return this.document;
  }

  private async save(document: ObservedDocument): Promise<void> {
    // Bound the known projects: the least recently read leave first.
    for (const prefix of ["project:", "project-mcp:"]) {
      const projects = Object.entries(document.stores).filter(([id]) => id.startsWith(prefix))
        .sort(([, left], [, right]) => left.seen.localeCompare(right.seen));
      for (const [id] of projects.slice(0, Math.max(0, projects.length - OBSERVED_PROJECT_LIMIT))) delete document.stores[id];
    }
    await durableAtomicWriteJson(this.path, document);
  }

  private async raw(store: ObservedStore): Promise<string | undefined> {
    const path = observedFile(store, this.agentDir);
    try { return await readFile(path, "utf8"); }
    catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined; throw error; }
  }

  private async values(store: ObservedStore, text: string | undefined): Promise<Map<string, ObservedValue> | undefined> {
    const subject = subjectOf(store);
    if (subject) {
      // An absent file has no entries; an unparseable one keeps the last observed state.
      if (text === undefined || !text.trim()) return new Map();
      try { return subjectInstances(JSON.parse(text) as unknown, subject); } catch { return undefined; }
    }
    if (store.kind === "trust") {
      if (text === undefined || !text.trim()) return new Map();
      try {
        const parsed = JSON.parse(text) as unknown;
        return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? trustInstances(parsed as Record<string, unknown>) : undefined;
      } catch { return undefined; }
    }
    if (store.kind === "mac") {
      try { return piInstances(await this.readers.mac(), "mac"); } catch { return undefined; }
    }
    // An unparseable project file (merge markers) has unknown values: keep the
    // last observed ones until it parses again, rather than reporting removals.
    const document = await this.readers.project((store as ProjectObservedStore).root).catch(() => undefined);
    return document === undefined ? undefined : piInstances(document, "project");
  }

  /** One store's comparison. With `planned`, the bracketed writes are Tron's. */
  private async compare(document: ObservedDocument, store: ObservedStore, planned?: ReadonlyMap<string, PlannedWrite>, applied?: ReadonlyMap<string, { git?: GitResult; changeId: string }>,
    knownHead?: GitHeadState, headKnown = false): Promise<ChangeEntry[]> {
    const id = storeId(store);
    const text = await this.raw(store);
    const digest = digestOf(text);
    const at = this.now().toISOString();
    let state = document.stores[id];
    const head = !isProjectStore(store) ? undefined : headKnown ? knownHead : await gitHeadState(store.root);
    // The repository state names the compared file: `.pi/mcp.json` beside `.pi/settings.json`.
    const git = head && store.kind === "project-mcp" ? { ...head, path: join(dirname(head.path), "mcp.json") } : head;
    if (state && !planned && state.digest === digest && (!git || git.head === (state.head ?? null))) {
      state.seen = at;
      return [];
    }
    const current = await this.values(store, text);
    if (!current) {
      if (state) state.seen = at;
      return [];
    }
    if (!state) {
      // First sight is the baseline: nothing to compare with yet.
      document.stores[id] = {
        digest, values: Object.fromEntries([...current].map(([instance, value]) => [instance, observed(value)])), tron: {}, outside: {},
        ...(git ? { head: git.head, staged: [] } : {}), seen: at,
      };
      if (!planned) return [];
      state = document.stores[id]!;
    }
    const entries: ChangeEntry[] = [];
    const floors = await this.readers.floors().catch(() => ({} as FloorOverrides));
    const instances = new Set([...Object.keys(state.values), ...current.keys()]);
    for (const instance of instances) {
      const before = state.values[instance];
      const after = current.has(instance) ? observed(current.get(instance)!) : undefined;
      const write = planned?.get(instance);
      if (write) {
        const landed = write.value === undefined ? after === undefined : after !== undefined && fingerprint(after) === fingerprint(observed({ key: after.key, value: write.value }));
        const recorded = applied?.get(write.changeId);
        if (landed && recorded) {
          // The recorded entry that holds this value (an approval's fact, not its request).
          state.tron[instance] = recorded.changeId;
          delete state.outside[instance];
          if (store.kind === "project" && recorded.git?.staged && recorded.git.blob) {
            state.staged = [...(state.staged ?? []).filter(item => item.changeId !== recorded.changeId),
              { changeId: recorded.changeId, path: recorded.git.path, blob: recorded.git.blob }].slice(-STAGED_LIMIT);
          }
        }
        continue;
      }
      if (fingerprint(before) === fingerprint(after)) continue;
      const entry = this.outsideEntry(store, (after ?? before)!, before, after, state.tron[instance], floors, git, at);
      entries.push(entry);
      state.outside[instance] = {
        changeId: entry.changeId, applyAgain: state.tron[instance] !== undefined,
        before: entry.redacted ? "Set" : formatStoredSetting(schemaKeyOrUndefined(entry.key)?.type, before?.value),
        after: entry.redacted ? (after ? "Set" : "Not set") : formatStoredSetting(schemaKeyOrUndefined(entry.key)?.type, after?.value),
      };
      delete state.tron[instance];
    }
    state.values = Object.fromEntries([...current].map(([instance, value]) => [instance, observed(value)]));
    state.digest = digest;
    state.seen = at;
    if (git) {
      if (git.head !== (state.head ?? null) && store.kind === "project") entries.push(...await this.committed(store, state, git.head, at));
      state.head = git.head;
    }
    return entries;
  }

  private outsideEntry(store: ObservedStore, value: ObservedValue, before: ObservedValue | undefined, after: ObservedValue | undefined,
    replaced: string | undefined, floors: FloorOverrides, git: { head: string | null; branch: string | null; root: string; path: string } | undefined, at: string): ChangeEntry {
    const key = schemaKeyOrUndefined(value.key);
    const subject = recordSubject(value.key);
    const qualifiers = value.qualifiers ?? {};
    const builtin = key ? builtinValue(key, qualifiers) : undefined;
    const redacted = key?.redacted === true || subject !== undefined;
    const direction = key?.direction && !redacted ? key.direction(before?.value ?? builtin, after?.value ?? builtin) : "widen";
    // An outside change cannot be gated: its tier, the key's (or record
    // subject's) floor for its direction, decides only whether it pushes (doc 5.6).
    const { floor, source } = key ? floorFor(key, direction, floors) : { floor: subject?.floor ?? "notify" as Tier, source: "code" as const };
    const file = observedFile(store, this.agentDir);
    return {
      changeId: randomUUID(), at, actor: { kind: "outside", id: file },
      target: isProjectStore(store) ? { kind: "project", cwd: store.root } : { kind: "mac" },
      layer: isProjectStore(store) ? "project" : "mac", key: value.key,
      ...(subject && before === undefined && after !== undefined ? { added: true as const } : {}),
      ...(Object.keys(qualifiers).length ? { qualifiers } : {}),
      op: after === undefined ? "unset" : "set",
      ...(redacted ? { changed: true as const, redacted: true as const } : {
        ...(before?.value === undefined ? {} : { before: before.value }), ...(after?.value === undefined ? {} : { after: after.value }),
      }),
      tier: floor, tierBasis: { direction, floor, floorSource: source, web: false, risk: null },
      status: "outside",
      ...(replaced ? { refersTo: replaced } : {}),
      ...(git ? { git: { root: git.root, path: git.path, staged: false, ...(git.head ? { head: git.head } : {}), ...(git.branch ? { branch: git.branch } : {}) } } : {}),
    };
  }

  /** A commit that holds Tron's staged blob appends `committed` to that change (doc 5.7). */
  private async committed(store: Extract<ObservedStore, { kind: "project" }>, state: StoreState, head: string | null, at: string): Promise<ChangeEntry[]> {
    if (!head || !state.staged?.length) return [];
    const facts: ChangeEntry[] = [];
    const remaining: NonNullable<StoreState["staged"]> = [];
    for (const item of state.staged) {
      const blob = await stagedBlob(store.root, `HEAD:${item.path}`);
      const found = blob === item.blob ? await this.record.entry(item.changeId) : undefined;
      if (!found) { remaining.push(item); continue; }
      facts.push({
        ...found.entry, changeId: randomUUID(), at, status: "committed", refersTo: item.changeId,
        git: { ...(found.entry.git ?? { root: store.root, path: item.path, staged: true }), head },
      });
    }
    state.staged = remaining;
    return facts;
  }
}
