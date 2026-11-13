import { createHash } from "node:crypto";
import { lstat, mkdir, open, opendir, readdir, rm } from "node:fs/promises";
import { isAbsolute, join } from "node:path";
import type { TronWorkspace } from "../../workspace/tron-workspace.js";
import { AsyncMutex } from "../../util/async-mutex.js";
import { durableAtomicWriteJson, isDurablePublicationUncertain, syncDurably, type DurableJsonFileSystem } from "../../foundation/durable-json.js";
import { readSecureJson, SecureJsonFileError } from "../../foundation/secure-json.js";
import { authorizationRequestId, type HomeTaskAuthorizationState, type HomeTaskAuthorizationStore } from "./home-task-authorization.js";
import type { HomeTaskCheckin, HomeTaskCounts } from "../../protocol/types.js";
import type { HomeWakeEvent } from "./home-wake-inbox.js";
import { homeTaskPromptTokens } from "./home-task-spend.js";
import { HOME_TASK_CHECKIN_LIMIT, parseHomeTaskCheckin } from "../../kernel/delegation/task-checkin.js";
import { currentHomeTask, homeTaskLineages, homeTaskNeedsAttention } from "./home-task-lineage.js";
import { tronHomePath } from "../../foundation/tron-home-layout.js";

const TASK_BYTES = 256 * 1_024;
const AUTHORIZATION_BYTES = 4 * 1_024 * 1_024;
const WRITE_JOURNAL = 1_024;
const ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$/u;
const OUTCOMES = ["progress", "needs-input", "final", "limited", "interrupted", "unknown"] as const;
const FAILURE_CAUSES = ["provider-usage-limit", "provider-error"] as const;
export type HomeTaskFailureCause = typeof FAILURE_CAUSES[number];
const ownedTemporaryName = /^(?:authorization|\d{13}-.+)\.json\.\d+\.[0-9a-f]{12}\.tmp$/u;

export interface HomeTaskRecord {
  version: 1;
  taskId: string;
  revision: number;
  createdAt: number;
  updatedAt: number;
  homeId: string;
  generation: number;
  routeGeneration: number;
  wake: HomeWakeEvent | null;
  checkins?: HomeTaskCheckin[];
  lastAttentionAt?: string;
  attention?: { checkin: HomeTaskCheckin; wake: HomeWakeEvent };
  intent: { text: string };
  intentDigest: string;
  target: string;
  grantRef: string | null;
  scopeRef: string | null;
  lifecycle: "pending" | "active" | "terminal";
  sessionId: string | null;
  operationId: string | null;
  stopIntent: { operationId: string; requestedAt: string } | null;
  spend: { sourceDigest: string; inputTokens: number; outputTokens: number; cacheReadTokens?: number; cacheWriteTokens?: number } | null;
  budget?: { inputTokens?: number; outputTokens?: number };
  resumes?: { taskId: string; operationId: string; instruction?: string };
  queuedAt?: string;
  reportRef: { resultId: string; sessionId: string; entryId: string; digest: string } | null;
  terminalEvidence: {
    outcome: typeof OUTCOMES[number];
    sessionId: string | null;
    entryIds: string[];
    reason: string;
    failureCause?: HomeTaskFailureCause;
    detail?: string;
  } | null;
}

export type HomeTaskWrite = Omit<HomeTaskRecord, "createdAt" | "updatedAt">;

export function taskIntentDigest(text: string): string {
  return createHash("sha256").update(text).digest("hex");
}

export type HomeTaskStoreCode = "not-initialized" | "missing-state" | "unsafe-state" | "invalid-record"
  | "revision-conflict" | "write-failed" | "publication-uncertain";
export interface HomeTaskStoreDiagnostic {
  event: "home.task.store-refused";
  reason: HomeTaskStoreCode;
}
export class HomeTaskStoreError extends Error {
  constructor(readonly code: HomeTaskStoreCode) {
    super(`Home task namespace refused: ${code}`);
    this.name = "HomeTaskStoreError";
  }
}
interface Options {
  diagnostic?: (record: HomeTaskStoreDiagnostic) => void;
  fileSystem?: DurableJsonFileSystem;
}

interface HomeTaskPageItem {
  task: HomeTaskRecord;
  pendingGrant: boolean;
}

export class HomeTaskStore {
  private readonly mutex = new AsyncMutex();
  private readonly home: string;
  private readonly directory: string;
  private readonly authorizationPath: string;
  private readonly uncertain = new Set<string>();
  readonly authorization: HomeTaskAuthorizationStore;
  private writes = 0;
  get writeCount(): number { return this.writes; }
  private readonly journal: Array<string | null> = [];

  taskWritesSince(since: number): string[] | undefined {
    const first = this.writes - this.journal.length;
    if (!Number.isSafeInteger(since) || since < first || since > this.writes) return undefined;
    return this.journal.slice(since - first).filter((taskId): taskId is string => taskId !== null);
  }

  constructor(private readonly tronHome: string, private readonly workspace: TronWorkspace, private readonly options: Options = {}) {
    this.home = tronHomePath(tronHome, "state/home");
    this.directory = join(this.home, "tasks");
    this.authorizationPath = join(this.directory, "authorization.json");
    this.authorization = {
      load: () => this.run(async () => {
        const state = await this.inspectAuthority();
        if (!state) throw new HomeTaskStoreError("not-initialized");
        return state;
      }),
      save: state => {
        const next = structuredClone(state);
        return this.run(async () => {
          validateAuthorization({ version: 1, ...next });
          const current = await this.inspectAuthority();
          if (!current) throw new HomeTaskStoreError("not-initialized");
          if (next.revision !== current.revision || !positive(current.revision + 1)) throw new HomeTaskStoreError("revision-conflict");
          if (current.scopes.some(scope => !next.scopes.some(candidate => candidate.id === scope.id))
            || current.grants.some(grant => !next.grants.some(candidate => candidate.id === grant.id))) invalid();
          await this.publish(this.authorizationPath, { version: 1, ...next, revision: current.revision + 1 }, AUTHORIZATION_BYTES);
        });
      },
    };
  }

  async initialize(): Promise<boolean> {
    return this.run(async () => {
      if (await this.inspect()) return false;
      await mkdir(this.home, { mode: 0o700 }).catch(error => {
        if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
      });
      await assertDirectory(this.home);
      await mkdir(this.directory, { mode: 0o700 });
      await this.publish(this.authorizationPath, { version: 1, revision: 1, scopes: [], requests: [], decisions: [], grants: [] }, AUTHORIZATION_BYTES);
      for (const path of [this.home, tronHomePath(this.tronHome, "state")]) {
        const handle = await open(path, "r");
        try { await syncDurably(handle); } finally { await handle.close(); }
      }
      await this.workspace.markFeatureInitialized("home-tasks");
      return true;
    });
  }

  async restoreEpoch(): Promise<string> {
    return this.run(async () => {
      if (!(await this.inspectAuthority())) throw new HomeTaskStoreError("not-initialized");
      return this.directoryEpoch();
    });
  }

  async *records(): AsyncGenerator<HomeTaskRecord> {
    let authority = await this.run(() => this.inspect());
    if (!authority) return;
    for await (const name of this.taskNames()) {
      const task = await this.run(async () => {
        if (!await this.assertNamespace()) throw new HomeTaskStoreError("missing-state");
        const current = await this.readNamedTask(name);
        if (!authorityReferencesResolve(current, authority!)) {
          const refreshed = await this.inspectAuthority();
          if (!refreshed) throw new HomeTaskStoreError("missing-state");
          authority = refreshed;
          validateAuthorityReferences(current, authority);
        }
        return current;
      });
      yield task;
    }
  }

  async read(taskId: string): Promise<HomeTaskRecord | undefined> {
    return this.run(async () => {
      if (!identifier(taskId) || taskId === "authorization") throw new HomeTaskStoreError("invalid-record");
      const authority = await this.inspectAuthority();
      if (!authority) throw new HomeTaskStoreError("not-initialized");
      return this.readTask(taskId, authority);
    });
  }

  async put(record: HomeTaskWrite, expectedRevision: number | null): Promise<HomeTaskRecord> {
    const input = structuredClone(record);
    return this.run(async () => {
      const authorization = await this.inspectAuthority();
      if (!authorization) throw new HomeTaskStoreError("not-initialized");
      if (!identifier(input.taskId) || input.taskId === "authorization") invalid();
      const current = await this.readTask(input.taskId, authorization);
      let creationTime = Date.now();
      if (!current) for await (const name of this.taskNames()) creationTime = Math.max(creationTime, name.createdAt + 1);
      const createdAt = current?.createdAt ?? creationTime;
      const next: HomeTaskRecord = { ...input, createdAt, updatedAt: Math.max(Date.now(), current?.updatedAt ?? createdAt) };
      validateTask(next);
      validateAuthorityReferences(next, authorization);
      if ((current?.revision ?? null) !== expectedRevision
        || next.revision !== (expectedRevision ?? 0) + 1) throw new HomeTaskStoreError("revision-conflict");
      if (current?.lifecycle === "terminal") throw new HomeTaskStoreError("invalid-record");
      if (current && (immutableTask(current) !== immutableTask(next)
        || (current.stopIntent !== null && JSON.stringify(current.stopIntent) !== JSON.stringify(next.stopIntent))
        || spendRegressed(current.spend, next.spend)
        || ((current.grantRef !== null || current.scopeRef !== null)
          && (current.grantRef !== next.grantRef || current.scopeRef !== next.scopeRef)))) throw new HomeTaskStoreError("invalid-record");
      await this.publish(this.taskPath(next), next, TASK_BYTES);
      return next;
    });
  }

  async update(taskId: string, change: (current: HomeTaskRecord) => HomeTaskRecord): Promise<HomeTaskRecord> {
    return this.run(async () => {
      if (!identifier(taskId) || taskId === "authorization") throw new HomeTaskStoreError("invalid-record");
      const authorization = await this.inspectAuthority();
      if (!authorization) throw new HomeTaskStoreError("not-initialized");
      const current = await this.readTask(taskId, authorization);
      if (!current) throw new HomeTaskStoreError("missing-state");
      const next = structuredClone(change(structuredClone(current)));
      if (JSON.stringify(next) === JSON.stringify(current)) return current;
      next.revision = current.revision + 1;
      next.updatedAt = Math.max(Date.now(), current.updatedAt);
      validateTask(next);
      validateAuthorityReferences(next, authorization);
      if (current.lifecycle === "terminal" || immutableTask(current) !== immutableTask(next)
        || current.operationId !== next.operationId || current.sessionId !== next.sessionId
        || current.grantRef !== next.grantRef || current.scopeRef !== next.scopeRef
        || spendRegressed(current.spend, next.spend)
        || (current.stopIntent !== null && JSON.stringify(current.stopIntent) !== JSON.stringify(next.stopIntent))) throw new HomeTaskStoreError("invalid-record");
      await this.publish(this.taskPath(next), next, TASK_BYTES);
      return next;
    }, undefined, taskId);
  }

  async updateWake(taskId: string, change: (wake: HomeWakeEvent) => HomeWakeEvent, eventId?: string): Promise<HomeTaskRecord> {
    return this.run(async () => {
      if (!identifier(taskId) || taskId === "authorization") throw new HomeTaskStoreError("invalid-record");
      const authorization = await this.inspectAuthority();
      if (!authorization) throw new HomeTaskStoreError("not-initialized");
      const current = await this.readTask(taskId, authorization);
      const attention = eventId !== undefined && current?.attention?.wake.eventId === eventId;
      const before = attention ? current?.attention?.wake : current?.wake;
      if (!current || !before || (eventId !== undefined && before.eventId !== eventId)) throw new HomeTaskStoreError("missing-state");
      const wake = structuredClone(change(structuredClone(before)));
      if (JSON.stringify(wake) === JSON.stringify(before)) return current;
      if (wake.eventId !== before.eventId || wake.createdAt !== before.createdAt
        || before.state === "acknowledged" || (before.push === "decided" && wake.push !== "decided")) throw new HomeTaskStoreError("invalid-record");
      const next = { ...current, revision: current.revision + 1, updatedAt: Math.max(Date.now(), current.updatedAt),
        ...(attention ? { attention: { ...current.attention!, wake } } : { wake }) };
      validateTask(next);
      await this.publish(this.taskPath(next), next, TASK_BYTES);
      return next;
    });
  }

  async removeAbandonedTemporaries(): Promise<void> {
    await this.run(async () => {
      if (!(await this.inspectAuthority())) return;
      for (const name of await readdir(this.directory)) {
        if (!ownedTemporaryName.test(name)) continue;
        const path = join(this.directory, name);
        const info = await lstat(path);
        if (!info.isFile() || info.isSymbolicLink() || info.uid !== process.getuid?.()) throw new HomeTaskStoreError("unsafe-state");
        await rm(path, { force: true });
      }
    });
  }

  private async run<T>(operation: () => Promise<T>, signal?: AbortSignal, repairs?: string): Promise<T> {
    return this.mutex.run(async () => {
      try {
        if (this.uncertain.size && !(repairs !== undefined && this.uncertain.has(repairs))) throw new HomeTaskStoreError("publication-uncertain");
        return await operation();
      } catch (error) {
        if (isDurablePublicationUncertain(error)) this.uncertain.add("namespace");
        const refusal = this.uncertain.size ? new HomeTaskStoreError("publication-uncertain")
          : error instanceof HomeTaskStoreError ? error
            : new HomeTaskStoreError(error instanceof SecureJsonFileError && error.kind === "invalid" ? "invalid-record" : "unsafe-state");
        this.options.diagnostic?.({ event: "home.task.store-refused", reason: refusal.code });
        throw refusal;
      }
    }, signal);
  }

  private async publish(path: string, document: unknown, maximumBytes: number): Promise<void> {
    this.writes += 1;
    this.journal.push(path === this.authorizationPath ? null : (document as HomeTaskRecord).taskId);
    if (this.journal.length > WRITE_JOURNAL) this.journal.shift();
    if (Buffer.byteLength(`${JSON.stringify(document, null, 2)}\n`) > maximumBytes) throw new HomeTaskStoreError("invalid-record");
    const key = path === this.authorizationPath ? "authorization" : (document as HomeTaskRecord).taskId;
    try { await durableAtomicWriteJson(path, document, 0o600, this.options.fileSystem); }
    catch (error) {
      if (!isDurablePublicationUncertain(error)) throw new HomeTaskStoreError("write-failed");
      this.uncertain.add(key);
      throw new HomeTaskStoreError("publication-uncertain");
    }
    this.uncertain.delete(key);
  }

  private async assertNamespace(): Promise<boolean> {
    if (!(await this.workspace.describe()).available) throw new HomeTaskStoreError("unsafe-state");
    await assertDirectory(this.tronHome);
    await assertDirectory(tronHomePath(this.tronHome, "state"));
    await assertDirectory(tronHomePath(this.tronHome, "state/workspace-state"));
    const initialized = await this.workspace.featureInitialized("home-tasks").catch(() => { throw new HomeTaskStoreError("invalid-record"); });
    const homePresent = await directoryPresent(this.home);
    const present = homePresent && await directoryPresent(this.directory);
    if (!present) {
      if (initialized) throw new HomeTaskStoreError("missing-state");
      return false;
    }
    if (!initialized) throw new HomeTaskStoreError("missing-state");
    return true;
  }

  private async inspectAuthority(): Promise<HomeTaskAuthorizationState | undefined> {
    if (!await this.assertNamespace()) return undefined;
    const auth = await readSecureJson<unknown>(this.authorizationPath, AUTHORIZATION_BYTES);
    if (!auth.present) throw new HomeTaskStoreError("missing-state");
    return validateAuthorization(auth.value);
  }

  private async inspect(): Promise<HomeTaskAuthorizationState | undefined> {
    const state = await this.inspectAuthority();
    if (!state) return undefined;
    for await (const name of this.taskNames()) {
      const task = await this.readNamedTask(name);
      validateAuthorityReferences(task, state);
    }
    return state;
  }



  private taskPath(task: Pick<HomeTaskRecord, "createdAt" | "taskId">): string {
    return join(this.directory, `${String(task.createdAt).padStart(13, "0")}-${task.taskId}.json`);
  }

  private async *taskNames(): AsyncGenerator<TaskName> {
    const taskIds = new Set<string>();
    for await (const entry of await opendir(this.directory, { bufferSize: 32 })) {
      if (!isTaskEntry(entry.name)) continue;
      const name = parseTaskName(entry.name);
      if (taskIds.has(name.taskId)) invalid();
      taskIds.add(name.taskId);
      yield name;
    }
  }

  private async readTask(taskId: string, authority: HomeTaskAuthorizationState): Promise<HomeTaskRecord | undefined> {
    let name: TaskName | undefined;
    for await (const candidate of this.taskNames()) {
      if (candidate.taskId === taskId) name = candidate;
    }
    if (!name) return undefined;
    const task = await this.readNamedTask(name);
    validateAuthorityReferences(task, authority);
    return task;
  }

  private async readNamedTask(name: TaskName): Promise<HomeTaskRecord> {
    const read = await readSecureJson<unknown>(this.taskPath(name), TASK_BYTES);
    if (!read.present) throw new HomeTaskStoreError("missing-state");
    const task = validateTask(read.value);
    if (task.taskId !== name.taskId || task.createdAt !== name.createdAt) invalid();
    return task;
  }

  private async directoryEpoch(): Promise<string> {
    const info = await lstat(this.directory, { bigint: true });
    if (!info.isDirectory() || info.isSymbolicLink() || info.birthtimeNs <= 0n) throw new HomeTaskStoreError("unsafe-state");
    return createHash("sha256").update(`${info.dev}:${info.ino}:${info.birthtimeNs}`).digest("hex");
  }

  async activeTargets(signal?: AbortSignal): Promise<string[]> {
    return this.run(async () => {
      const authority = await this.inspectAuthority();
      if (!authority) return [];
      const targets: string[] = [];
      for await (const name of this.taskNames()) {
        signal?.throwIfAborted();
        const task = await this.readNamedTask(name);
        validateAuthorityReferences(task, authority);
        if (task.lifecycle !== "terminal") targets.push(task.target);
      }
      return targets;
    }, signal);
  }

  async page(input: { limit?: number; cursor?: string; lineages?: boolean; filter?: "all" | "open" | "finished" }, signal?: AbortSignal): Promise<{ items: HomeTaskPageItem[]; nextCursor?: string; counts: HomeTaskCounts }> {
    return this.run(async () => {
      const limit = input.limit ?? 20;
      if (!Number.isSafeInteger(limit) || limit < 1 || limit > 50) invalid();
      const authority = await this.inspectAuthority();
      if (!authority) {
        if (input.cursor) invalid();
        return { items: [], counts: { active: 0, finished: 0 } };
      }
      const epoch = await this.directoryEpoch();
      let after: TaskName | undefined;
      if (input.cursor) {
        try {
          const value = JSON.parse(Buffer.from(input.cursor, "base64url").toString("utf8"));
          if (!keys(value, ["epoch", "createdAt", "taskId"], ["filter"]) || value.epoch !== epoch
            || value.filter !== input.filter
            || !timestamp(value.createdAt) || !identifier(value.taskId)) invalid();
          after = { createdAt: value.createdAt as number, taskId: value.taskId as string };
        } catch { invalid(); }
      }
      const counts: HomeTaskCounts = { active: 0, finished: 0 };
      const selected: HomeTaskRecord[] = [];
      const lineageRecords: HomeTaskRecord[] = [];
      const select = (task: HomeTaskRecord) => {
        if (task.lifecycle === "terminal") counts.finished += 1;
        else counts.active += 1;
        const open = task.lifecycle !== "terminal" || homeTaskNeedsAttention(task);
        if ((input.filter === "open" && !open) || (input.filter === "finished" && open)) return;
        if (after && compareTaskNames(task, after) <= 0) return;
        selected.push(task); selected.sort(compareTaskNames);
        if (selected.length > limit + 1) selected.pop();
      };
      for await (const name of this.taskNames()) {
        const task = await this.readNamedTask(name);
        validateAuthorityReferences(task, authority);
        if (input.lineages) lineageRecords.push(task);
        else select(task);
      }
      if (input.lineages) for (const lineage of homeTaskLineages(lineageRecords)) select(currentHomeTask(lineage));
      const items = selected.slice(0, limit).map(task => ({ task,
        pendingGrant: task.lifecycle === "pending" && authority.requests.some(pending => pending.request.intentDigest === task.intentDigest
          && pending.request.target === task.target && !authority.decisions.some(decision => decision.requestId === pending.id)) }));
      const last = selected[Math.min(limit, selected.length) - 1];
      return { items, counts, ...(selected.length > limit && last
        ? { nextCursor: Buffer.from(JSON.stringify({ epoch, createdAt: last.createdAt, taskId: last.taskId, ...(input.filter ? { filter: input.filter } : {}) })).toString("base64url") } : {}) };
    }, signal);
  }

}

async function directoryPresent(path: string): Promise<boolean> {
  try { await assertDirectory(path); return true; }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return false;
    throw error;
  }
}
async function assertDirectory(path: string): Promise<void> {
  const info = await lstat(path);
  if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid?.() || (info.mode & 0o777) !== 0o700) {
    throw new HomeTaskStoreError("unsafe-state");
  }
}
function isTaskEntry(name: string): boolean {
  return name !== "authorization.json" && !ownedTemporaryName.test(name);
}
function object(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function keys(value: unknown, required: string[], optional: string[] = []): value is Record<string, unknown> {
  return object(value) && required.every(key => Object.hasOwn(value, key))
    && Object.keys(value).every(key => required.includes(key) || optional.includes(key));
}
function positive(value: unknown): value is number { return Number.isSafeInteger(value) && (value as number) > 0; }
function count(value: unknown): value is number { return Number.isSafeInteger(value) && (value as number) >= 0; }
function spendRegressed(current: HomeTaskRecord["spend"], next: HomeTaskRecord["spend"]): boolean {
  if (current === null) return false;
  return next === null || homeTaskPromptTokens(next) < homeTaskPromptTokens(current) || next.outputTokens < current.outputTokens
    || (current.cacheReadTokens !== undefined && next.cacheReadTokens === undefined);
}
function text(value: unknown, maximumBytes: number): value is string {
  return typeof value === "string" && value.length > 0 && !value.includes("\0") && Buffer.byteLength(value) <= maximumBytes;
}
function identifier(value: unknown): value is string { return typeof value === "string" && ID.test(value); }
function nullableId(value: unknown): boolean { return value === null || identifier(value); }
function timestamp(value: unknown): boolean { return typeof value === "number" && Number.isSafeInteger(value) && value >= 0; }
function unique(records: Record<string, unknown>[]): boolean { return new Set(records.map(record => record.id)).size === records.length; }
function invalid(): never { throw new HomeTaskStoreError("invalid-record"); }
function immutableTask(task: HomeTaskRecord): string {
  return JSON.stringify([task.createdAt, task.taskId, task.homeId, task.generation, task.routeGeneration, task.intent.text, task.intentDigest, task.target, task.budget ?? null, task.resumes ?? null]);
}

function authorityReferencesResolve(task: HomeTaskRecord, authorization: HomeTaskAuthorizationState): boolean {
  return (task.scopeRef === null || authorization.scopes.some(scope => scope.id === task.scopeRef))
    && (task.grantRef === null || authorization.grants.some(grant => grant.id === task.grantRef));
}

function validateAuthorityReferences(task: HomeTaskRecord, authorization: HomeTaskAuthorizationState): void {
  if (!authorityReferencesResolve(task, authorization)) invalid();
}

function validateTask(value: unknown): HomeTaskRecord {
  if (!keys(value, ["version", "taskId", "revision", "createdAt", "updatedAt", "homeId", "generation", "intent", "intentDigest", "target",
    "grantRef", "scopeRef", "lifecycle", "sessionId", "operationId", "stopIntent", "spend", "reportRef", "terminalEvidence", "routeGeneration", "wake"], ["budget", "resumes", "queuedAt", "checkins", "attention", "lastAttentionAt"])
    || value.version !== 1 || !identifier(value.taskId) || value.taskId === "authorization" || !positive(value.revision)
    || !timestamp(value.createdAt) || (value.createdAt as number) > 9_999_999_999_999
    || !timestamp(value.updatedAt) || (value.updatedAt as number) < (value.createdAt as number)
    || !identifier(value.homeId) || !positive(value.generation) || !positive(value.routeGeneration)
    || !keys(value.intent, ["text"]) || !text(value.intent.text, 64 * 1_024)
    || value.intentDigest !== taskIntentDigest(value.intent.text)
    || !text(value.target, 4_096) || !isAbsolute(value.target)
    || !nullableId(value.grantRef) || !nullableId(value.scopeRef) || (value.grantRef !== null && value.scopeRef !== null)
    || !["pending", "active", "terminal"].includes(value.lifecycle as string)
    || !nullableId(value.sessionId) || !nullableId(value.operationId)) invalid();
  if (value.stopIntent !== null && (!keys(value.stopIntent, ["operationId", "requestedAt"])
    || !identifier(value.stopIntent.operationId)
    || value.stopIntent.operationId !== value.operationId
    || !text(value.stopIntent.requestedAt, 64) || !Number.isFinite(Date.parse(value.stopIntent.requestedAt)))) invalid();
  if (value.spend !== null && (!keys(value.spend, ["sourceDigest", "inputTokens", "outputTokens"], ["cacheReadTokens", "cacheWriteTokens"])
    || typeof value.spend.sourceDigest !== "string" || !/^[a-f0-9]{64}$/u.test(value.spend.sourceDigest)
    || !count(value.spend.inputTokens) || !count(value.spend.outputTokens)
    || (value.spend.cacheReadTokens === undefined) !== (value.spend.cacheWriteTokens === undefined)
    || (value.spend.cacheReadTokens !== undefined && (!count(value.spend.cacheReadTokens) || !count(value.spend.cacheWriteTokens))))) invalid();
  if (value.queuedAt !== undefined && (!text(value.queuedAt, 64) || !Number.isFinite(Date.parse(value.queuedAt as string)))) invalid();
  if (value.budget !== undefined && (!keys(value.budget, [], ["inputTokens", "outputTokens"]) || Object.keys(value.budget).length === 0
    || Object.values(value.budget).some(tokens => !positive(tokens)))) invalid();
  if (value.resumes !== undefined && (!keys(value.resumes, ["taskId", "operationId"], ["instruction"]) || !identifier(value.resumes.taskId)
    || value.resumes.taskId === value.taskId || !identifier(value.resumes.operationId)
    || (value.resumes.instruction !== undefined && !text(value.resumes.instruction, 32 * 1_024)))) invalid();
  const reportRef = value.reportRef;
  if (reportRef !== null && (!keys(reportRef, ["resultId", "sessionId", "entryId", "digest"]) || !identifier(reportRef.resultId)
    || !identifier(reportRef.sessionId) || !identifier(reportRef.entryId) || typeof reportRef.digest !== "string" || !/^[a-f0-9]{64}$/u.test(reportRef.digest))) invalid();
  const evidence = value.terminalEvidence;
  if (evidence !== null && (!keys(evidence, ["outcome", "sessionId", "entryIds", "reason"], ["detail", "failureCause"])
    || (evidence.detail !== undefined && !text(evidence.detail, 2_048))
    || (evidence.failureCause !== undefined && !FAILURE_CAUSES.includes(evidence.failureCause as HomeTaskFailureCause))
    || !OUTCOMES.includes(evidence.outcome as typeof OUTCOMES[number]) || !nullableId(evidence.sessionId)
    || !Array.isArray(evidence.entryIds) || evidence.entryIds.length > 256 || evidence.entryIds.some(id => !identifier(id))
    || new Set(evidence.entryIds).size !== evidence.entryIds.length || !identifier(evidence.reason))) invalid();
  if ((value.lifecycle === "terminal") !== (evidence !== null)
    || (value.lifecycle === "active" && (value.sessionId === null || value.operationId === null
      || (value.grantRef === null && value.scopeRef === null)))
    || (evidence !== null && evidence.outcome === "final" && reportRef === null)) invalid();
  if (value.checkins !== undefined) {
    if (!Array.isArray(value.checkins) || value.checkins.length > HOME_TASK_CHECKIN_LIMIT) invalid();
    try { value.checkins.forEach(parseHomeTaskCheckin); } catch { invalid(); }
    if (new Set(value.checkins.map(item => item.id)).size !== value.checkins.length) invalid();
  }
  if (value.lastAttentionAt !== undefined && (!text(value.lastAttentionAt, 64) || !Number.isFinite(Date.parse(value.lastAttentionAt)))) invalid();
  if (value.attention !== undefined) {
    if (!keys(value.attention, ["checkin", "wake"]) || !object(value.attention.wake)) invalid();
    let checkin: HomeTaskCheckin;
    try { checkin = parseHomeTaskCheckin(value.attention.checkin); } catch { invalid(); }
    if (checkin.taskId !== value.taskId || checkin.operationId !== value.operationId || checkin.sessionId !== value.sessionId
      || checkin.attention !== "requested" || value.lastAttentionAt !== checkin.at) invalid();
  }
  if ((value.lifecycle === "terminal") !== (value.wake !== null)) invalid();
  const wakes = [{ wake: value.wake, id: `task-result-${createHash("sha256").update(value.taskId as string).digest("hex")}` },
    ...(value.attention ? [{ wake: value.attention.wake, id: `task-attention-${(value.attention.checkin as unknown as HomeTaskCheckin).id}` }] : [])];
  for (const { wake, id } of wakes) {
    if (wake === null) continue;
    if (!keys(wake, ["eventId", "routeGeneration", "createdAt", "state", "push", "delivery", "acknowledgedAt", "redeliveries"])
      || wake.eventId !== id || !positive(wake.routeGeneration)
      || !text(wake.createdAt, 64) || !Number.isFinite(Date.parse(wake.createdAt))
      || !["pending", "claimed", "admitted", "terminal", "acknowledged", "blocked", "outcome-unknown"].includes(wake.state as string)
      || !["pending", "decided"].includes(wake.push as string)
      || !Array.isArray(wake.redeliveries) || wake.redeliveries.some(item => !keys(item, ["from", "to"]) || !positive(item.from) || !positive(item.to))
      || ((wake.state === "acknowledged") !== (wake.acknowledgedAt !== null))
      || (wake.acknowledgedAt !== null && (!text(wake.acknowledgedAt, 64) || !Number.isFinite(Date.parse(wake.acknowledgedAt))))) invalid();
    if (wake.delivery !== null && (!keys(wake.delivery, ["sessionId", "operationId", "generation", "routeGeneration", "messageDigest"])
      || !identifier(wake.delivery.sessionId) || !identifier(wake.delivery.operationId) || !positive(wake.delivery.generation)
      || typeof wake.delivery.messageDigest !== "string" || !/^[a-f0-9]{64}$/u.test(wake.delivery.messageDigest)
      || wake.delivery.routeGeneration !== wake.routeGeneration)) invalid();
    if (["claimed", "admitted", "terminal", "acknowledged", "outcome-unknown"].includes(wake.state as string) === (wake.delivery === null)) invalid();
  }
  return value as unknown as HomeTaskRecord;
}

function validateAuthorization(value: unknown): HomeTaskAuthorizationState {
  if (!keys(value, ["version", "revision", "scopes", "requests", "decisions", "grants"]) || value.version !== 1 || !positive(value.revision)
    || !Array.isArray(value.scopes) || !Array.isArray(value.requests) || !Array.isArray(value.decisions) || !Array.isArray(value.grants)
    || [value.scopes, value.requests, value.decisions, value.grants].some(records => records.length > 10_000)) invalid();
  for (const scope of value.scopes) {
    if (!keys(scope, ["id", "kind", "active", "restoreEpoch", "createdAt"], ["revokedAt"])
      || !identifier(scope.id) || scope.kind !== "all-trusted-projects" || typeof scope.active !== "boolean"
      || !identifier(scope.restoreEpoch) || !timestamp(scope.createdAt)
      || (scope.active ? scope.revokedAt !== undefined : !timestamp(scope.revokedAt))
      || (scope.revokedAt !== undefined && (scope.revokedAt as number) < (scope.createdAt as number))) invalid();
  }
  if (value.scopes.filter(scope => scope.active).length > 1) invalid();
  for (const pending of value.requests) {
    if (!keys(pending, ["id", "request"]) || !identifier(pending.id)
      || !keys(pending.request, ["intentDigest", "target", "authorizationScope", "restoreEpoch"])
      || !validAuthorizationBinding(pending.request)
      || pending.id !== authorizationRequestId(pending.request as unknown as import("./home-task-authorization.js").HomeTaskAuthorizationRequest)) invalid();
  }
  for (const decision of value.decisions) {
    if (!keys(decision, ["id", "requestId", "decidedAt", "approved", "expiresAt"]) || !identifier(decision.id)
      || !timestamp(decision.decidedAt) || typeof decision.approved !== "boolean" || !timestamp(decision.expiresAt)
      || !value.requests.some(pending => pending.id === decision.requestId)) invalid();
  }
  if (new Set(value.decisions.map(decision => decision.requestId)).size !== value.decisions.length) invalid();
  const approvedDecisions = new Set(value.decisions.filter(decision => decision.approved).map(decision => decision.id));
  for (const grant of value.grants) {
    if (!keys(grant, ["id", "decisionId", "intentDigest", "target", "authorizationScope", "restoreEpoch", "expiresAt", "state"])
      || !identifier(grant.id) || !identifier(grant.decisionId) || !text(grant.intentDigest, 128)
      || !text(grant.target, 4_096) || !isAbsolute(grant.target) || !identifier(grant.authorizationScope)
      || !identifier(grant.restoreEpoch) || !timestamp(grant.expiresAt)
      || !["available", "consumed", "revoked"].includes(grant.state as string)
      || !approvedDecisions.has(grant.decisionId)) invalid();
    const decision = value.decisions.find(decision => decision.id === grant.decisionId)!;
    const pending = value.requests.find(pending => pending.id === decision.requestId)!;
    if (grant.expiresAt !== decision.expiresAt || authorizationRequestId(grant as unknown as import("./home-task-authorization.js").HomeTaskAuthorizationRequest) !== pending.id) invalid();
  }
  if (![value.scopes, value.requests, value.decisions, value.grants].every(unique)
    || new Set(value.grants.map(grant => grant.decisionId)).size !== value.grants.length) invalid();
  const { version: _version, ...state } = value;
  return state as unknown as HomeTaskAuthorizationState;
}

function validAuthorizationBinding(value: Record<string, unknown>): boolean {
  return text(value.intentDigest, 128) && text(value.target, 4_096) && isAbsolute(value.target as string)
    && identifier(value.authorizationScope) && identifier(value.restoreEpoch);
}

interface TaskName { createdAt: number; taskId: string }
function parseTaskName(value: string): TaskName {
  const match = /^(\d{13})-(.+)\.json$/u.exec(value);
  if (!match || !identifier(match[2]) || match[2] === "authorization") invalid();
  return { createdAt: Number(match[1]), taskId: match[2] };
}
function compareTaskNames(a: TaskName, b: TaskName): number {
  return b.createdAt - a.createdAt || (a.taskId < b.taskId ? -1 : a.taskId > b.taskId ? 1 : 0);
}
