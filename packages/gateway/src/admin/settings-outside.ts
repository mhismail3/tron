import { createHash, randomUUID } from "node:crypto";
import { watch, type FSWatcher } from "node:fs";
import { readFile, stat } from "node:fs/promises";
import { dirname, join } from "node:path";
import { GatewayError } from "../errors.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { durableAtomicWriteJson } from "../foundation/durable-json.js";
import { readJsonDocument } from "../foundation/json.js";
import { gitHeadState, projectSettingsPath, stagedBlob, type GitHeadState } from "./project-settings-writer.js";
import type { ChangeEntry, SettingsChangeRecord } from "../kernel/settings/settings-record.js";
import { type GitResult, type Qualifiers } from "../kernel/settings/tool-contract.js";
import type { OutsideMark, ObservedStore, PlannedWrite } from "../kernel/settings/settings-types.js";
import { recordSubject, type SettingsSchema, type Binding, type KeyDeclaration } from "../kernel/settings/settings-schema.js";
import { readPath } from "../kernel/settings/settings-resolver.js";
import { instanceId } from "../kernel/settings/scope-resolution.js";
import { formatStoredSetting } from "../kernel/settings/settings-types.js";
import { tronHomePath } from "../foundation/tron-home-layout.js";

type ProjectObservedStore = Extract<ObservedStore, { root: string }>;
const isProjectStore = (store: ObservedStore): store is ProjectObservedStore => store.kind === "project" || store.kind === "project-mcp";

const PROJECT_FILES = new Set(["settings.json", "mcp.json"]);
const STAGED_LIMIT = 20;

interface ObservedValue { key: string; qualifiers?: Qualifiers; value?: unknown; hash?: string }

interface StoreState {
  digest: string;
  values: Record<string, ObservedValue>;
  tron: Record<string, string>;
  outside: Record<string, OutsideMark>;
  staged?: Array<{ changeId: string; path: string; blob: string }>;
  head?: string | null;
}

interface ObservedDocument { version: 1; stores: Record<string, StoreState> }

interface OutsideObserver {
  outside(entries: readonly ChangeEntry[]): void | Promise<void>;
  providerFilesChanged?(): void;
}

export interface ObservedReaders {
  global(): Promise<Record<string, unknown>>;
  project(root: string): Promise<Record<string, unknown> | undefined>;
}


function storeId(store: ObservedStore): string {
  return isProjectStore(store) ? `${store.kind}:${store.root}` : store.kind;
}

export function projectStores(root: string): ObservedStore[] {
  return [{ kind: "project", root }, { kind: "project-mcp", root }];
}

function observedFile(store: ObservedStore, agentDir: string): string {
  switch (store.kind) {
    case "global": return join(agentDir, "settings.json");
    case "trust": return join(agentDir, "trust.json");
    case "mcp": return join(agentDir, "mcp.json");
    case "models": return join(agentDir, "models.json");
    case "project": return projectSettingsPath(store.root);
    case "project-mcp": return join(store.root, ".pi", "mcp.json");
  }
}


export function observedInstance(key: KeyDeclaration, layer: string, binding: Binding, qualifiers: Qualifiers, projectRoot: string | undefined): { store: ObservedStore; instance: string } | undefined {
  const fixed = key.fixed ?? {};
  if (binding.store === "trust") {
    return qualifiers.project === undefined ? undefined : { store: { kind: "trust" }, instance: instanceId(key.id, { ...fixed, project: qualifiers.project }) };
  }
  if (binding.store !== "pi" && binding.store !== "pi-model-ref") return undefined;
  const store: ObservedStore | undefined = layer === "global" ? { kind: "global" } : layer === "project" && projectRoot ? { kind: "project", root: projectRoot } : undefined;
  if (!store) return undefined;
  const modelQualified = binding.store === "pi" && qualifiers.model !== undefined
    && (binding.qualified !== undefined || binding.path.includes("{model}"));
  return { store, instance: instanceId(key.id, modelQualified ? { ...fixed, model: qualifiers.model! } : fixed) };
}


function modelsAt(document: Record<string, unknown>, path: readonly string[]): string[] {
  const container = readPath(document, path.slice(0, path.indexOf("{model}")));
  return container && typeof container === "object" && !Array.isArray(container) ? Object.keys(container) : [];
}


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


async function projectRemoved(root: string): Promise<boolean> {
  try { await stat(root); return false; }
  catch (error) { return (error as NodeJS.ErrnoException).code === "ENOENT"; }
}

const digestOf = (text: string | undefined) => text === undefined ? "" : createHash("sha256").update(text).digest("hex");

const fingerprint = (value: ObservedValue | undefined) => value === undefined ? null : value.hash ?? JSON.stringify(value.value ?? null);
const subjectOf = (store: ObservedStore) => store.kind === "mcp" || store.kind === "project-mcp" ? "tools.mcp.server" : store.kind === "models" ? "accounts.models.provider" : undefined;

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
  private changed = false;

  constructor(
    private readonly schema: SettingsSchema,
    private readonly tronHome: string,
    private readonly agentDir: string,
    private readonly record: SettingsChangeRecord,
    private readonly readers: ObservedReaders,
    private readonly now: () => Date = () => new Date(),
  ) {}

  get path(): string { return tronHomePath(this.tronHome, "gateway/settings/observed.json"); }

  observe(observer: OutsideObserver): void {
    if (this.observer && this.observer !== observer) throw new Error("Outside changes already have an observer");
    this.observer = observer;
  }

  reconcile(stores: readonly ObservedStore[], heads?: ReadonlyMap<string, GitHeadState | undefined>): Promise<void> {
    if (this.retired) return Promise.reject(new Error("Outside settings comparison is disposed"));
    const work = this.compareStores(stores, heads);
    this.reconciliations.add(work);
    void work.then(() => this.reconciliations.delete(work), () => this.reconciliations.delete(work));
    return work;
  }

  private piInstances(document: Record<string, unknown>, layer: "global" | "project"): Map<string, ObservedValue> {
    const values = new Map<string, ObservedValue>();
    const add = (key: KeyDeclaration, qualifiers: Qualifiers, value: unknown) => {
      if (value === undefined) return;
      values.set(instanceId(key.id, qualifiers), { key: key.id, ...(Object.keys(qualifiers).length ? { qualifiers } : {}), value });
    };
    for (const key of this.schema.KEYS) {
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

  private trustInstances(document: Record<string, unknown>): Map<string, ObservedValue> {
    const key = this.schema.schemaKey("permissions.projectTrust");
    const values = new Map<string, ObservedValue>();
    for (const [project, decision] of Object.entries(document)) {
      if (typeof decision !== "boolean") continue;
      const qualifiers = { ...(key.fixed ?? {}), project };
      values.set(instanceId(key.id, qualifiers), { key: key.id, qualifiers, value: decision });
    }
    return values;
  }

  private observed(value: ObservedValue): ObservedValue {
    if (!this.schemaKeyOrUndefined(value.key)?.redacted || value.value === undefined) return value;
    const { value: secret, ...rest } = value;
    return { ...rest, hash: createHash("sha256").update(JSON.stringify(secret)).digest("hex") };
  }

  private schemaKeyOrUndefined(id: string): KeyDeclaration | undefined { return this.schema.KEYS.find(key => key.id === id); }

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
      if (this.changed) await this.save(document);
      this.changed = false;
    });
    if (entries.length) await this.observer?.outside(entries);
  }

  startWatching(failed: (error: unknown) => void): void {
    if (this.disposal) throw new Error("Outside settings comparison is disposed");
    this.watching = true;
    this.failed = failed;
    this.watchDirectory("agent", this.agentDir, () => true, [{ kind: "global" }, { kind: "trust" }, { kind: "mcp" }, { kind: "models" }]);
    this.watchDirectory("auth", this.agentDir, name => name === "auth.json", [], () => this.observer?.providerFilesChanged?.());
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
    if (this.watchDirectory(`project:${root}`, join(root, ".pi"), name => PROJECT_FILES.has(name), projectStores(root))) {
      this.watchers.get(`project-parent:${root}`)?.close();
      this.watchers.delete(`project-parent:${root}`);
      return;
    }
    if (this.watchers.has(`project-parent:${root}`)) return;
    this.watchDirectory(`project-parent:${root}`, root, name => name === ".pi", projectStores(root));
  }

  private watchDirectory(id: string, directory: string, relevant: (name: string) => boolean, stores: ObservedStore[], changed?: () => void): boolean {
    try {
      const watcher = watch(directory, { persistent: false }, (_event, name) => {
        if (!this.watching || (name !== null && !relevant(String(name))) || this.timers.has(id)) return;
        this.timers.set(id, setTimeout(() => {
          this.timers.delete(id);
          if (!this.watching) return;
          changed?.();
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

  async marks(store: ObservedStore): Promise<Record<string, OutsideMark>> {
    const document = await this.mutex.run(() => this.load());
    return { ...(document.stores[storeId(store)]?.outside ?? {}) };
  }

  async begin(writes: readonly PlannedWrite[]): Promise<void> {
    await this.mutex.run(async () => {
      for (const id of new Set(writes.map(write => storeId(write.store)))) this.writing.set(id, (this.writing.get(id) ?? 0) + 1);
    });
  }

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
        this.changed = false;
      } finally {
        for (const id of byStore.keys()) {
          const count = (this.writing.get(id) ?? 1) - 1;
          if (count > 0) this.writing.set(id, count); else this.writing.delete(id);
        }
      }
    });
    if (entries.length) await this.observer?.outside(entries);
  }

  async adopt<T>(stores: readonly ObservedStore[], write: () => Promise<T>): Promise<T> {
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
    const values = Object.fromEntries([...current].map(([instance, value]) => [instance, this.observed(value)]));
    const git = isProjectStore(store) ? await gitHeadState(store.root) : undefined;
    if (!state) {
      document.stores[id] = { digest: digestOf(text), values, tron: {}, outside: {}, ...(git ? { head: git.head, staged: [] } : {}) };
      return;
    }
    for (const instance of Object.keys(state.outside)) {
      if (fingerprint(state.values[instance]) !== fingerprint(values[instance])) delete state.outside[instance];
    }
    state.values = values;
    state.digest = digestOf(text);
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
    const roots = new Set(Object.keys(document.stores).flatMap(id => id.startsWith("project:") ? [id.slice("project:".length)]
      : id.startsWith("project-mcp:") ? [id.slice("project-mcp:".length)] : []));
    for (const root of roots) if (await projectRemoved(root)) this.forgetProject(document, root);
    await durableAtomicWriteJson(this.path, document);
  }

  private forgetProject(document: ObservedDocument, root: string): void {
    for (const store of projectStores(root)) delete document.stores[storeId(store)];
    for (const id of [`project:${root}`, `project-parent:${root}`]) {
      this.watchers.get(id)?.close();
      this.watchers.delete(id);
    }
  }

  private async raw(store: ObservedStore): Promise<string | undefined> {
    const path = observedFile(store, this.agentDir);
    try { return await readFile(path, "utf8"); }
    catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined; throw error; }
  }

  private async values(store: ObservedStore, text: string | undefined): Promise<Map<string, ObservedValue> | undefined> {
    const subject = subjectOf(store);
    if (subject) {
      if (text === undefined || !text.trim()) return new Map();
      try { return subjectInstances(JSON.parse(text) as unknown, subject); } catch { return undefined; }
    }
    if (store.kind === "trust") {
      if (text === undefined || !text.trim()) return new Map();
      try {
        const parsed = JSON.parse(text) as unknown;
        return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? this.trustInstances(parsed as Record<string, unknown>) : undefined;
      } catch { return undefined; }
    }
    if (store.kind === "global") {
      try { return this.piInstances(await this.readers.global(), "global"); } catch { return undefined; }
    }
    const document = await this.readers.project((store as ProjectObservedStore).root).catch(() => undefined);
    return document === undefined ? undefined : this.piInstances(document, "project");
  }

  private async compare(document: ObservedDocument, store: ObservedStore, planned?: ReadonlyMap<string, PlannedWrite>, applied?: ReadonlyMap<string, { git?: GitResult; changeId: string }>,
    knownHead?: GitHeadState, headKnown = false): Promise<ChangeEntry[]> {
    const id = storeId(store);
    if (isProjectStore(store) && await projectRemoved(store.root)) {
      if (document.stores[id]) this.changed = true;
      this.forgetProject(document, store.root);
      return [];
    }
    const text = await this.raw(store);
    const digest = digestOf(text);
    const at = this.now().toISOString();
    let state = document.stores[id];
    const head = !isProjectStore(store) ? undefined : headKnown ? knownHead : await gitHeadState(store.root);
    const git = head && store.kind === "project-mcp" ? { ...head, path: join(dirname(head.path), "mcp.json") } : head;
    if (state && !planned && state.digest === digest && (!git || git.head === (state.head ?? null))) return [];
    const current = await this.values(store, text);
    if (!current) return [];
    this.changed = true;
    if (!state) {
      document.stores[id] = {
        digest, values: Object.fromEntries([...current].map(([instance, value]) => [instance, this.observed(value)])), tron: {}, outside: {},
        ...(git ? { head: git.head, staged: [] } : {}),
      };
      if (!planned) return [];
      state = document.stores[id]!;
    }
    const entries: ChangeEntry[] = [];
    const instances = new Set([...Object.keys(state.values), ...current.keys()]);
    for (const instance of instances) {
      const before = state.values[instance];
      const after = current.has(instance) ? this.observed(current.get(instance)!) : undefined;
      const write = planned?.get(instance);
      if (write) {
        const landed = write.value === undefined ? after === undefined : after !== undefined && fingerprint(after) === fingerprint(this.observed({ key: after.key, value: write.value }));
        const recorded = applied?.get(write.changeId);
        if (landed && recorded) {
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
      const entry = this.outsideEntry(store, (after ?? before)!, before, after, state.tron[instance], git, at);
      entries.push(entry);
      state.outside[instance] = {
        changeId: entry.changeId, applyAgain: state.tron[instance] !== undefined,
        before: entry.redacted ? "Set" : formatStoredSetting(this.schemaKeyOrUndefined(entry.key)?.type, before?.value),
        after: entry.redacted ? (after ? "Set" : "Not set") : formatStoredSetting(this.schemaKeyOrUndefined(entry.key)?.type, after?.value),
      };
      delete state.tron[instance];
    }
    state.values = Object.fromEntries([...current].map(([instance, value]) => [instance, this.observed(value)]));
    state.digest = digest;
    if (git) {
      if (git.head !== (state.head ?? null) && store.kind === "project") entries.push(...await this.committed(store, state, git.head, at));
      state.head = git.head;
    }
    return entries;
  }

  private outsideEntry(store: ObservedStore, value: ObservedValue, before: ObservedValue | undefined, after: ObservedValue | undefined,
    replaced: string | undefined, git: { head: string | null; branch: string | null; root: string; path: string } | undefined, at: string): ChangeEntry {
    const key = this.schemaKeyOrUndefined(value.key);
    const subject = recordSubject(value.key);
    const qualifiers = value.qualifiers ?? {};
    const redacted = key?.redacted === true || subject !== undefined;
    const file = observedFile(store, this.agentDir);
    return {
      changeId: randomUUID(), at, actor: { kind: "outside", id: file },
      target: isProjectStore(store) ? { kind: "project", cwd: store.root } : { kind: "global" },
      layer: isProjectStore(store) ? "project" : "global", key: value.key,
      ...(subject && before === undefined && after !== undefined ? { added: true as const } : {}),
      ...(Object.keys(qualifiers).length ? { qualifiers } : {}),
      op: after === undefined ? "unset" : "set",
      ...(redacted ? { changed: true as const, redacted: true as const } : {
        ...(before?.value === undefined ? {} : { before: before.value }), ...(after?.value === undefined ? {} : { after: after.value }),
      }),
      status: "outside",
      ...(replaced ? { refersTo: replaced } : {}),
      ...(git ? { git: { root: git.root, path: git.path, staged: false, ...(git.head ? { head: git.head } : {}), ...(git.branch ? { branch: git.branch } : {}) } } : {}),
    };
  }

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
