import { createHash } from "node:crypto";
import { lstat, mkdir, open, opendir } from "node:fs/promises";
import { isAbsolute, join } from "node:path";
import type { TronWorkspace } from "../workspace/tron-workspace.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { durableAtomicWriteJson, isDurablePublicationUncertain, syncDurably, type DurableJsonFileSystem } from "../util/durable-json.js";
import { readSecureJson, SecureJsonFileError } from "../util/secure-json.js";
import { authorizationRequestId, type HomeTaskAuthorizationState, type HomeTaskAuthorizationStore } from "./home-task-authorization.js";
import type { HomeTaskPage, HomeTaskSummary } from "../protocol/types.js";
import type { HomeWakeEvent } from "./home-wake-inbox.js";

const TASK_BYTES = 256 * 1_024;
const AUTHORIZATION_BYTES = 4 * 1_024 * 1_024;
const ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$/u;
const OUTCOMES = ["progress", "needs-input", "final", "limited", "interrupted", "unknown"] as const;

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
  intent: { revision: number; text: string };
  /** SHA-256 of JSON.stringify({ revision, text }), in that key order. */
  intentDigest: string;
  target: string;
  workerProfile: string;
  policyRevision: number;
  grantRef: string | null;
  scopeRef: string | null;
  lifecycle: "pending" | "active" | "terminal";
  sessionId: string | null;
  operationId: string | null;
  controllerGeneration: number | null;
  stopIntent: { operationId: string; controllerGeneration: number; requestedAt: string } | null;
  spend: {
    sourceDigest: string;
    inputTokens: number;
    outputTokens: number;
    knownCostUSD: number | null;
    pricingProvenance: string | null;
    unpriced: boolean;
  } | null;
  reportRefs: Array<{ resultId: string; sessionId: string; entryId: string; digest: string }> | null;
  terminalEvidence: {
    outcome: typeof OUTCOMES[number];
    sessionId: string | null;
    entryIds: string[];
    reason: string;
  } | null;
}

export type HomeTaskWrite = Omit<HomeTaskRecord, "createdAt" | "updatedAt">;

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

/** Durable namespace authority only; dispatch and domain lifecycle belong to
 * their later owners. One store per installation shares the workspace lease.
 * Enumeration streams files, never builds a second task catalog. */
export class HomeTaskStore {
  private readonly mutex = new AsyncMutex();
  private readonly home: string;
  private readonly directory: string;
  private readonly authorizationPath: string;
  private publicationUncertain = false;
  readonly authorization: HomeTaskAuthorizationStore;

  constructor(private readonly tronHome: string, private readonly workspace: TronWorkspace, private readonly options: Options = {}) {
    this.home = join(tronHome, "gateway", "home");
    this.directory = join(this.home, "tasks");
    this.authorizationPath = join(this.directory, "authorization.json");
    this.authorization = {
      load: () => this.run(async () => {
        const state = await this.inspect();
        if (!state) throw new HomeTaskStoreError("not-initialized");
        return state;
      }),
      save: state => {
        const next = structuredClone(state);
        return this.run(async () => {
          validateAuthorization({ version: 1, ...next });
          const current = await this.inspect(task => validateAuthorityReferences(task, next));
          if (!current) throw new HomeTaskStoreError("not-initialized");
          if (next.revision !== current.revision || !positive(current.revision + 1)) throw new HomeTaskStoreError("revision-conflict");
          await this.publish(this.authorizationPath, { version: 1, ...next, revision: current.revision + 1 }, AUTHORIZATION_BYTES);
        });
      },
    };
  }

  /** Explicit setup only. A partial prior setup is evidence, not permission to
   * finish or repair it. Marker publication follows durable namespace creation. */
  async initialize(): Promise<boolean> {
    return this.run(async () => {
      if (await this.inspect()) return false;
      await mkdir(this.home, { mode: 0o700 }).catch(error => {
        if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
      });
      await assertDirectory(this.home);
      await mkdir(this.directory, { mode: 0o700 });
      await this.publish(this.authorizationPath, { version: 1, revision: 1, scopes: [], requests: [], decisions: [], grants: [] }, AUTHORIZATION_BYTES);
      // The init marker must not outlive a directory entry still in a volatile
      // parent cache, including the newly created Home directory.
      for (const path of [this.home, join(this.tronHome, "gateway")]) {
        const handle = await open(path, "r");
        try { await syncDurably(handle); } finally { await handle.close(); }
      }
      await this.workspace.markFeatureInitialized("home-tasks");
      return true;
    });
  }

  /** Physical namespace identity is outside the restored document authority.
   * Restart and atomic file replacement retain it; directory recreation does not. */
  async restoreEpoch(): Promise<string> {
    return this.run(async () => {
      if (!(await this.inspectAuthority())) throw new HomeTaskStoreError("not-initialized");
      const info = await lstat(this.directory, { bigint: true });
      if (!info.isDirectory() || info.isSymbolicLink() || info.birthtimeNs <= 0n) throw new HomeTaskStoreError("unsafe-state");
      return createHash("sha256").update(`${info.dev}:${info.ino}:${info.birthtimeNs}`).digest("hex");
    });
  }

  /** Calls a synchronous visitor for each secure bounded record. Uninitialized
   * absence is an empty read, not setup or a refusal; missing-after-init still
   * fails closed. The caller owns its projection; there is no task-count cap. */
  async list(visit: (record: HomeTaskRecord) => void): Promise<void> {
    await this.run(async () => {
      await this.inspect(visit);
    });
  }

  /** Sequential consumers may await mutations between records. Namespace
   * validation finishes under the mutex; no lock is held across a yield. */
  async *records(): AsyncGenerator<HomeTaskRecord> {
    if (!await this.run(() => this.inspect())) return;
    const directory = await this.run(() => opendir(this.directory, { bufferSize: 32 }));
    for await (const entry of directory) {
      if (entry.name === "authorization.json") continue;
      const task = await this.run(async () => {
        const name = parseTaskName(entry.name);
        const authority = await this.inspectAuthority();
        if (!authority) throw new HomeTaskStoreError("missing-state");
        const current = await this.readTask(name.taskId);
        if (!current) throw new HomeTaskStoreError("missing-state");
        validateAuthorityReferences(current, authority);
        return current;
      });
      yield task;
    }
  }

  /** Exact-reference owners must block on undefined, never recreate a missing
   * referenced task. Unreferenced absence carries no initialization evidence. */
  async read(taskId: string): Promise<HomeTaskRecord | undefined> {
    return this.run(async () => {
      if (!identifier(taskId) || taskId === "authorization") throw new HomeTaskStoreError("invalid-record");
      if (!(await this.inspect())) throw new HomeTaskStoreError("not-initialized");
      return this.readTask(taskId);
    });
  }

  async put(record: HomeTaskWrite, expectedRevision: number | null): Promise<HomeTaskRecord> {
    // Snapshot at the command boundary: a queued caller cannot mutate its
    // accepted command while an earlier durable write owns the mutex.
    const input = structuredClone(record);
    return this.run(async () => {
      const authorization = await this.inspect();
      if (!authorization) throw new HomeTaskStoreError("not-initialized");
      if (!identifier(input.taskId) || input.taskId === "authorization") invalid();
      const current = await this.readTask(input.taskId);
      // Creation is strictly monotonic even within one wall-clock millisecond.
      // The filename owns ordering across reopen; no clock/index state survives.
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
        || (current.spend !== null && (next.spend === null || next.spend.inputTokens < current.spend.inputTokens || next.spend.outputTokens < current.spend.outputTokens))
        || ((current.grantRef !== null || current.scopeRef !== null)
          && (current.grantRef !== next.grantRef || current.scopeRef !== next.scopeRef)))) throw new HomeTaskStoreError("invalid-record");
      await this.publish(this.taskPath(next), next, TASK_BYTES);
      return next;
    });
  }

  /** Domain mutations use the latest durable record under the same mutex as
   * publication. Terminal settlement cannot overwrite accepted Stop/spend. */
  async update(taskId: string, change: (current: HomeTaskRecord) => HomeTaskRecord): Promise<HomeTaskRecord> {
    return this.run(async () => {
      if (!identifier(taskId) || taskId === "authorization") throw new HomeTaskStoreError("invalid-record");
      const authorization = await this.inspect();
      if (!authorization) throw new HomeTaskStoreError("not-initialized");
      const current = await this.readTask(taskId);
      if (!current) throw new HomeTaskStoreError("missing-state");
      const next = structuredClone(change(structuredClone(current)));
      if (JSON.stringify(next) === JSON.stringify(current)) return current;
      next.revision = current.revision + 1;
      next.updatedAt = Math.max(Date.now(), current.updatedAt);
      validateTask(next);
      validateAuthorityReferences(next, authorization);
      if (current.lifecycle === "terminal" || immutableTask(current) !== immutableTask(next)
        || current.operationId !== next.operationId || current.sessionId !== next.sessionId
        || current.controllerGeneration !== next.controllerGeneration
        || current.grantRef !== next.grantRef || current.scopeRef !== next.scopeRef
        || (current.spend !== null && (next.spend === null || next.spend.inputTokens < current.spend.inputTokens || next.spend.outputTokens < current.spend.outputTokens))
        || (current.stopIntent !== null && JSON.stringify(current.stopIntent) !== JSON.stringify(next.stopIntent))) throw new HomeTaskStoreError("invalid-record");
      await this.publish(this.taskPath(next), next, TASK_BYTES);
      return next;
    });
  }

  /** Inbox is the sole mutable portion of a terminal task. Its result and
   * authority cannot be rewritten by delivery, recovery or notification. */
  async updateWake(taskId: string, change: (wake: HomeWakeEvent) => HomeWakeEvent): Promise<HomeTaskRecord> {
    return this.run(async () => {
      if (!identifier(taskId) || taskId === "authorization") throw new HomeTaskStoreError("invalid-record");
      if (!(await this.inspect())) throw new HomeTaskStoreError("not-initialized");
      const current = await this.readTask(taskId);
      if (!current || current.lifecycle !== "terminal" || !current.wake) throw new HomeTaskStoreError("missing-state");
      const wake = structuredClone(change(structuredClone(current.wake)));
      if (JSON.stringify(wake) === JSON.stringify(current.wake)) return current;
      if (wake.eventId !== current.wake.eventId || wake.createdAt !== current.wake.createdAt
        || current.wake.state === "acknowledged" || (current.wake.push === "decided" && wake.push !== "decided")) throw new HomeTaskStoreError("invalid-record");
      const next = { ...current, revision: current.revision + 1, updatedAt: Math.max(Date.now(), current.updatedAt), wake };
      validateTask(next);
      await this.publish(this.taskPath(next), next, TASK_BYTES);
      return next;
    });
  }

  private async run<T>(operation: () => Promise<T>): Promise<T> {
    return this.mutex.run(async () => {
      try {
        if (this.publicationUncertain) throw new HomeTaskStoreError("publication-uncertain");
        return await operation();
      } catch (error) {
        // Setup-marker and data-file publications share this one uncertainty
        // owner; no write path can continue after a visible uncertain commit.
        if (isDurablePublicationUncertain(error)) this.publicationUncertain = true;
        const refusal = this.publicationUncertain ? new HomeTaskStoreError("publication-uncertain")
          : error instanceof HomeTaskStoreError ? error
            : new HomeTaskStoreError(error instanceof SecureJsonFileError && error.kind === "invalid" ? "invalid-record" : "unsafe-state");
        this.options.diagnostic?.({ event: "home.task.store-refused", reason: refusal.code });
        throw refusal;
      }
    });
  }

  private async publish(path: string, document: unknown, maximumBytes: number): Promise<void> {
    if (Buffer.byteLength(`${JSON.stringify(document, null, 2)}\n`) > maximumBytes) throw new HomeTaskStoreError("invalid-record");
    try { await durableAtomicWriteJson(path, document, 0o600, this.options.fileSystem); }
    catch (error) {
      if (isDurablePublicationUncertain(error)) throw error;
      throw new HomeTaskStoreError("write-failed");
    }
  }

  private async inspectAuthority(): Promise<HomeTaskAuthorizationState | undefined> {
    if (!(await this.workspace.describe()).available) throw new HomeTaskStoreError("unsafe-state");
    await assertDirectory(this.tronHome);
    await assertDirectory(join(this.tronHome, "gateway"));
    await assertDirectory(join(this.tronHome, "gateway", "workspace-state"));
    const initialized = await this.workspace.featureInitialized("home-tasks").catch(() => { throw new HomeTaskStoreError("invalid-record"); });
    const homePresent = await directoryPresent(this.home);
    const present = homePresent && await directoryPresent(this.directory);
    if (!present) {
      if (initialized) throw new HomeTaskStoreError("missing-state");
      return undefined;
    }
    if (!initialized) throw new HomeTaskStoreError("missing-state");
    const auth = await readSecureJson<unknown>(this.authorizationPath, AUTHORIZATION_BYTES);
    if (!auth.present) throw new HomeTaskStoreError("missing-state");
    return validateAuthorization(auth.value);
  }

  private async inspect(visit?: (record: HomeTaskRecord) => void): Promise<HomeTaskAuthorizationState | undefined> {
    const state = await this.inspectAuthority();
    if (!state) return undefined;
    // opendir has a bounded entry buffer. Each file is validated and released
    // before the next one; filename/identity equality makes duplicates impossible.
    const directory = await opendir(this.directory, { bufferSize: 32 });
    for await (const entry of directory) {
      if (entry.name === "authorization.json") continue;
      const name = parseTaskName(entry.name);
      const task = await this.readTask(name.taskId);
      if (!task) throw new HomeTaskStoreError("missing-state");
      validateAuthorityReferences(task, state);
      visit?.(task);
    }
    return state;
  }

  private taskPath(task: Pick<HomeTaskRecord, "createdAt" | "taskId">): string {
    return join(this.directory, `${String(task.createdAt).padStart(13, "0")}-${task.taskId}.json`);
  }

  private async *taskNames(): AsyncGenerator<TaskName> {
    for await (const entry of await opendir(this.directory, { bufferSize: 32 })) {
      if (entry.name !== "authorization.json") yield parseTaskName(entry.name);
    }
  }

  private async readTask(taskId: string): Promise<HomeTaskRecord | undefined> {
    let name: TaskName | undefined;
    for await (const candidate of this.taskNames()) {
      if (candidate.taskId === taskId) {
        if (name) invalid();
        name = candidate;
      }
    }
    if (!name) return undefined;
    const read = await readSecureJson<unknown>(this.taskPath(name), TASK_BYTES);
    if (!read.present) throw new HomeTaskStoreError("missing-state");
    const task = validateTask(read.value);
    if (task.taskId !== taskId || task.createdAt !== name.createdAt) invalid();
    return task;
  }

  /** Maintainer list reads only the selected records, never report bodies.
   * A continuation is bound to the physical namespace, not installation text. */
  async page(input: { limit?: number; cursor?: string }): Promise<HomeTaskPage> {
    return this.run(async () => {
      const limit = input.limit ?? 20;
      if (!Number.isSafeInteger(limit) || limit < 1 || limit > 50) invalid();
      const authority = await this.inspectAuthority();
      if (!authority) {
        if (input.cursor) invalid();
        return { items: [] };
      }
      const info = await lstat(this.directory, { bigint: true });
      const epoch = createHash("sha256").update(`${info.dev}:${info.ino}:${info.birthtimeNs}`).digest("hex");
      let after: TaskName | undefined;
      if (input.cursor) {
        try {
          const value = JSON.parse(Buffer.from(input.cursor, "base64url").toString("utf8"));
          if (!keys(value, ["epoch", "createdAt", "taskId"]) || value.epoch !== epoch
            || !timestamp(value.createdAt) || !identifier(value.taskId)) invalid();
          after = { createdAt: value.createdAt as number, taskId: value.taskId as string };
        } catch { invalid(); }
      }
      const selected: TaskName[] = [];
      for await (const name of this.taskNames()) {
        if (after && compareTaskNames(name, after) <= 0) continue;
        selected.push(name);
        selected.sort(compareTaskNames);
        if (selected.length > limit + 1) selected.pop();
      }
      const items: HomeTaskSummary[] = [];
      for (const name of selected.slice(0, limit)) {
        const task = (await this.readTask(name.taskId))!;
        validateAuthorityReferences(task, authority);
        items.push({ taskId: task.taskId, createdAt: task.createdAt, updatedAt: task.updatedAt,
          title: [...task.intent.text].slice(0, 160).join(""), target: task.target, lifecycle: task.lifecycle,
          outcome: task.terminalEvidence?.outcome ?? null, spend: task.spend,
          attention: task.terminalEvidence?.outcome === "needs-input" || task.terminalEvidence?.outcome === "unknown",
          pendingGrant: task.lifecycle === "pending" && authority.requests.some(pending => pending.request.intentDigest === task.intentDigest
            && pending.request.intentRevision === task.intent.revision && pending.request.target === task.target
            && pending.request.workerProfile === task.workerProfile && pending.request.policyRevision === task.policyRevision
            && !authority.decisions.some(decision => decision.requestId === pending.id)) });
      }
      const last = selected[Math.min(limit, selected.length) - 1];
      return { items, ...(selected.length > limit && last
        ? { nextCursor: Buffer.from(JSON.stringify({ epoch, createdAt: last.createdAt, taskId: last.taskId })).toString("base64url") } : {}) };
    });
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
function object(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function keys(value: unknown, required: string[], optional: string[] = []): value is Record<string, unknown> {
  return object(value) && required.every(key => Object.hasOwn(value, key))
    && Object.keys(value).every(key => required.includes(key) || optional.includes(key));
}
function positive(value: unknown): value is number { return Number.isSafeInteger(value) && (value as number) > 0; }
function count(value: unknown): value is number { return Number.isSafeInteger(value) && (value as number) >= 0; }
function text(value: unknown, maximumBytes: number): value is string {
  return typeof value === "string" && value.length > 0 && !value.includes("\0") && Buffer.byteLength(value) <= maximumBytes;
}
function identifier(value: unknown): value is string { return typeof value === "string" && ID.test(value); }
function nullableId(value: unknown): boolean { return value === null || identifier(value); }
function timestamp(value: unknown): boolean { return typeof value === "number" && Number.isSafeInteger(value) && value >= 0; }
function unique(records: Record<string, unknown>[]): boolean { return new Set(records.map(record => record.id)).size === records.length; }
function invalid(): never { throw new HomeTaskStoreError("invalid-record"); }
function immutableTask(task: HomeTaskRecord): string {
  return JSON.stringify([task.createdAt, task.taskId, task.homeId, task.generation, task.routeGeneration, task.intent.revision, task.intent.text, task.intentDigest,
    task.target, task.workerProfile, task.policyRevision]);
}

function validateAuthorityReferences(task: HomeTaskRecord, authorization: HomeTaskAuthorizationState): void {
  if ((task.scopeRef !== null && !authorization.scopes.some(scope => scope.id === task.scopeRef))
    || (task.grantRef !== null && !authorization.grants.some(grant => grant.id === task.grantRef))) invalid();
}

function validateTask(value: unknown): HomeTaskRecord {
  if (!keys(value, ["version", "taskId", "revision", "createdAt", "updatedAt", "homeId", "generation", "intent", "intentDigest", "target", "workerProfile",
    "policyRevision", "grantRef", "scopeRef", "lifecycle", "sessionId", "operationId", "controllerGeneration", "stopIntent", "spend", "reportRefs", "terminalEvidence", "routeGeneration", "wake"])
    || value.version !== 1 || !identifier(value.taskId) || value.taskId === "authorization" || !positive(value.revision)
    || !timestamp(value.createdAt) || (value.createdAt as number) > 9_999_999_999_999
    || !timestamp(value.updatedAt) || (value.updatedAt as number) < (value.createdAt as number)
    || !identifier(value.homeId) || !positive(value.generation) || !positive(value.routeGeneration)
    || !keys(value.intent, ["revision", "text"]) || !positive(value.intent.revision) || !text(value.intent.text, 64 * 1_024)
    || value.intentDigest !== createHash("sha256").update(JSON.stringify({ revision: value.intent.revision, text: value.intent.text })).digest("hex")
    || !text(value.target, 4_096) || !isAbsolute(value.target) || !identifier(value.workerProfile) || !positive(value.policyRevision)
    || !nullableId(value.grantRef) || !nullableId(value.scopeRef) || (value.grantRef !== null && value.scopeRef !== null)
    || !["pending", "active", "terminal"].includes(value.lifecycle as string)
    || !nullableId(value.sessionId) || !nullableId(value.operationId)
    || (value.controllerGeneration !== null && !positive(value.controllerGeneration))) invalid();
  if (value.stopIntent !== null && (!keys(value.stopIntent, ["operationId", "controllerGeneration", "requestedAt"])
    || !identifier(value.stopIntent.operationId) || !positive(value.stopIntent.controllerGeneration)
    || value.stopIntent.operationId !== value.operationId || value.stopIntent.controllerGeneration !== value.controllerGeneration
    || !text(value.stopIntent.requestedAt, 64) || !Number.isFinite(Date.parse(value.stopIntent.requestedAt)))) invalid();
  if (value.spend !== null && (!keys(value.spend, ["sourceDigest", "inputTokens", "outputTokens", "knownCostUSD", "pricingProvenance", "unpriced"])
    || typeof value.spend.sourceDigest !== "string" || !/^[a-f0-9]{64}$/u.test(value.spend.sourceDigest)
    || !count(value.spend.inputTokens) || !count(value.spend.outputTokens) || typeof value.spend.unpriced !== "boolean"
    || (value.spend.knownCostUSD !== null && (typeof value.spend.knownCostUSD !== "number" || !Number.isFinite(value.spend.knownCostUSD) || value.spend.knownCostUSD < 0))
    || (value.spend.pricingProvenance !== null && !text(value.spend.pricingProvenance, 512))
    || ((value.spend.knownCostUSD === null) !== (value.spend.pricingProvenance === null)))) invalid();
  if (value.reportRefs !== null && (!Array.isArray(value.reportRefs) || value.reportRefs.length > 256
    || value.reportRefs.some(ref => !keys(ref, ["resultId", "sessionId", "entryId", "digest"]) || !identifier(ref.resultId) || !identifier(ref.sessionId) || !identifier(ref.entryId) || typeof ref.digest !== "string" || !/^[a-f0-9]{64}$/u.test(ref.digest))
    || new Set(value.reportRefs.map(ref => ref.resultId)).size !== value.reportRefs.length)) invalid();
  const evidence = value.terminalEvidence;
  if (evidence !== null && (!keys(evidence, ["outcome", "sessionId", "entryIds", "reason"])
    || !OUTCOMES.includes(evidence.outcome as typeof OUTCOMES[number]) || !nullableId(evidence.sessionId)
    || !Array.isArray(evidence.entryIds) || evidence.entryIds.length > 256 || evidence.entryIds.some(id => !identifier(id))
    || new Set(evidence.entryIds).size !== evidence.entryIds.length || !identifier(evidence.reason))) invalid();
  if ((value.lifecycle === "terminal") !== (evidence !== null)
    || (value.lifecycle === "active" && (value.sessionId === null || value.operationId === null || value.controllerGeneration === null
      || (value.grantRef === null && value.scopeRef === null)))
    || (evidence !== null && evidence.outcome === "final" && (value.reportRefs === null || value.reportRefs.length === 0))) invalid();
  const wake = value.wake;
  if ((value.lifecycle === "terminal") !== (wake !== null)) invalid();
  if (wake !== null) {
    if (value.lifecycle !== "terminal" || !keys(wake, ["eventId", "routeGeneration", "createdAt", "state", "push", "delivery", "acknowledgedAt", "redeliveries"])
      || wake.eventId !== `task-result-${createHash("sha256").update(value.taskId as string).digest("hex")}` || !positive(wake.routeGeneration)
      || !text(wake.createdAt, 64) || !Number.isFinite(Date.parse(wake.createdAt))
      || !["pending", "claimed", "admitted", "terminal", "acknowledged", "cancelled-before-admission", "blocked", "outcome-unknown"].includes(wake.state as string)
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
      || !keys(pending.request, ["intentRevision", "intentDigest", "target", "authorizationScope", "workerProfile", "policyRevision", "restoreEpoch"])
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
    if (!keys(grant, ["id", "decisionId", "intentRevision", "intentDigest", "target", "authorizationScope", "workerProfile", "policyRevision", "restoreEpoch", "expiresAt", "state"])
      || !identifier(grant.id) || !identifier(grant.decisionId) || !positive(grant.intentRevision) || !text(grant.intentDigest, 128)
      || !text(grant.target, 4_096) || !isAbsolute(grant.target) || !identifier(grant.authorizationScope) || !identifier(grant.workerProfile)
      || !positive(grant.policyRevision) || !identifier(grant.restoreEpoch) || !timestamp(grant.expiresAt)
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
  return positive(value.intentRevision) && text(value.intentDigest, 128) && text(value.target, 4_096) && isAbsolute(value.target as string)
    && identifier(value.authorizationScope) && identifier(value.workerProfile) && positive(value.policyRevision) && identifier(value.restoreEpoch);
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
