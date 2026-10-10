import { HOME_TASK_RESULT_MESSAGE, HOME_WAKE_CEILING, isWakeEvidence, WakeInboxOwner, type HomeWakeDelivery, type HomeWakeEvidence, type HomeWakeEvidenceScope, type HomeWakeMessage, type HomeWakeRoute, type HomeWakeTrigger } from "./home-wake-inbox.js";
import { visitCanonicalSessionEntries } from "../episodic/episodic-source.js";
import type { NotificationService } from "../notifications/notification-service.js";
import { randomUUID } from "node:crypto";
import type { RuntimeRegistry } from "../sessions/runtime-registry.js";
import { HomeTaskStore, HomeTaskStoreError } from "./home-task-store.js";
import { HomeTaskAuthorization } from "./home-task-authorization.js";
import { HomeTaskDispatcher, type HomeTaskDiagnostic, type HomeTaskDispatchRequest, type HomeTaskControlRequest } from "./home-task-dispatcher.js";
import type { HomeTaskSubagents } from "./home-task-subagents.js";
import { chmod, mkdir, open, realpath, stat } from "node:fs/promises";
import { dirname, join } from "node:path";
import type { HomeChapterList, HomeChapterSummary, HomeContextProjection, HomeDesignation, HomeMemoryStatus, HomeOpen, HomeStatus, ModelRef, HomeMemoryPage, HomeMemoryEvidence, HomeMemoryEvidencePage } from "../protocol/types.js";
import type { SessionEntry } from "@earendil-works/pi-coding-agent";
import { historyEntry } from "../sessions/history.js";
import type { EpisodicMemory } from "../episodic/episodic-memory.js";
import { homeMemoryRevisionChanged, homeMemorySourceUnavailable, type HomeMemoryPageRequest } from "./home-memory-browser.js";
import { GatewayError } from "../errors.js";
import type { TrustService } from "../admin/trust-service.js";
import { EPISODIC_DEFAULTS, EpisodicMemoryError } from "../episodic/episodic-contract.js";
import { EpisodicSourceChangedError } from "../episodic/episodic-source.js";
import { readCanonicalHomeDeltas, readCanonicalHomeIndex, readCanonicalHomeEvidence, type HomeSourceChapter, type HomeSourceSnapshot } from "../episodic/home-source.js";
import type { TronWorkspace } from "../workspace/tron-workspace.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { durablePublishBoundedJson, isDurablePublicationUncertain, syncDurably } from "../util/durable-json.js";
import { boundedString, boundedTimestamp } from "../util/json.js";
import { readSecureJson, SecureJsonFileError } from "../util/secure-json.js";
import {
  HomeMemory, homeMemoryToolUnavailable,
  type HomeMemoryDiagnostic, type HomeMemoryModelResolution, type HomeMemoryToolAccess, type HomeMemoryToolResult,
} from "./home-memory.js";
import { HomeMemoryRefusal, HomeRequestPolicy, type HomeActivationIdentity, type HomeActivationView, type HomeRequestRecord } from "./home-request-policy.js";
import { HOME_MAX_CHAPTERS, HOME_HARD_BYTES, HOME_HARD_ENTRIES, HOME_SOFT_BYTES, HOME_SOFT_ENTRIES, unsealedHomeChapterState, type HomeChapterState } from "./home-chapter-state.js";
import type { HomeDiagnostic, HomeDiagnosticRecord } from "./home-diagnostic.js";
import { homeSystemPrompt } from "./tron-home-extension.js";
import type { KnowledgeService } from "../knowledge/knowledge-service.js";

/** One Gateway installation keeps at most one Home. */
const VERSION = 2;
const MAXIMUM_RECORD_BYTES = 16 * 1_024 * 1_024;
const MAXIMUM_PROVIDER_BYTES = 120;
const MAXIMUM_MODEL_ID_BYTES = 300;
/** The curated Home profile this build writes. A record written against a newer
 * revision is still this build's record to read: only `version` gates admission,
 * because a profile change is not a format change. Revision 2 added the read-only
 * research tools (#724) and revision 3 the learned profile tool (#731); designation and
 * re-enable both write the current revision, so an older record advances the next time
 * Home is enabled. */
const HOME_POLICY_REVISION = 3;

export interface HomeChapter {
  sessionId: string;
  ordinal: number;
  state: "active" | "sealed" | "reserved" | "materializing";
  createdAt: string;
  activationStarted: boolean;
  sealedAt?: string;
  sizeAtSeal?: number;
  entriesAtSeal?: number;
  attemptId?: string;
  expectedPath?: string;
}

export interface HomeRecord {
  version: 2;
  homeId: string;
  chapters: HomeChapter[];
  bindingRevision: number;
  generation: number;
  routeGeneration: number;
  policyRevision: number;
  enabled: boolean;
  model: ModelRef;
  createdAt: string;
  updatedAt: string;
  /** Home's memory model. Absent until `home.configureMemory` records one: there
   * are no defaults (decision D4), so an unconfigured memory refuses. */
  memory?: { model: ModelRef; paused?: true };
}

/** What the Home record says about one session id. `unnamed` means the record
 * does not name that session, which is the only window in which a creation-time
 * profile argument applies. */
export type HomeSessionProfile = "home" | "ordinary" | "unnamed";

/** Knowledge's automatic observation never reads a Tron Home chapter: Home is one
 * private conversation whose memory is its own (docs/home.md). A chapter of a
 * disabled Home is no longer that runtime profile, so it is observed like any
 * ordinary session. The owner is read lazily: `sessions` is constructed after
 * the Knowledge service that consults this predicate. */
export function homeChapterObservationExcluded(homeOwner: () => Pick<HomeOwner, "chapterStateFor">): (sessionId: string) => boolean {
  // Every chapter the record names is Home's history, enabled or disabled: Home's
  // own memory already holds it, so Knowledge never observes it.
  return (sessionId) => homeOwner().chapterStateFor(sessionId).homeId !== undefined;
}

/** The session operations Home needs from the runtime owner. Kept narrow so the
 * Home record's authority is never a second session owner. */
export interface HomeSessionPort {
  /** Create one session whose very first runtime already has the Home profile. */
  createHomeSession(cwd: string): Promise<string>;
  /** Apply the recorded model to a live Home session through the slot's normal
   * `setModel` path, when the live model differs. */
  applySessionModel(sessionId: string, model: ModelRef): Promise<void>;
  /** Whether the session exists at all: a live runtime, or a canonical session
   * the catalog or disk still holds. */
  sessionPresent(sessionId: string): Promise<boolean>;
  /** The canonical session JSONL for one session id, when this installation can
   * name it. Resolved per memory open, because a session exists before its file
   * does and a runtime may be evicted while its memory stays open. */
  sessionFile(sessionId: string): Promise<string | undefined>;
  /** Whether the session currently holds a live runtime. */
  hasLiveRuntime(sessionId: string): boolean;
  /** Registry owns session mutation ordering. Seal enters it before taking the
   * Home recordMutex, so admitted attention/archive/delete work settles first. */
  serializeSessionMutation<T>(sessionId: string, commit: () => Promise<T>): Promise<T>;
  /** Quiescent canonical size used to seal a chapter at its soft boundary. */
  chapterMetrics(sessionId: string): Promise<{ bytes: number; entries: number; quiescent: boolean }>;
  /** Whether the exact current SDK file has a complete durable conversation message. */
  hasConversation(sessionId: string, expectedPath: string): Promise<boolean>;
  /** Replace the session's live runtime in place after `commit` changes the
   * profile decision for it, so the next prompt uses the new profile. A busy
   * session refuses retryably before `commit` runs. */
  replaceRuntimeForProfile(sessionId: string, commit: () => Promise<void>): Promise<void>;
  /** Synchronously stale-mark Home slots before any asynchronous reload work. */
  beginHomePublicationReconciliation(): void;
  /** Retire every live Home slot after uncertain publication; next admission
   * rebuilds from the record reloaded by this owner. */
  retireHomeRuntimes(reloaded: boolean): Promise<void>;
  /** Starts one wake activation for the Home session: admission, the trigger
   * result, and the run. `delivered` is false when no result could be delivered. */
  wakeHome(sessionId: string): Promise<{ delivered: boolean }>;
}

/** What the session runtime reports to Home's memory. Narrow on purpose: the
 * runtime knows that canonical entries changed; the memory owns what it reads,
 * how long it waits and how much it spends. */
export interface HomeMemoryPort {
  /** Canonical entries were committed. Fire and forget, never awaited inside
   * admission or a slot lane. */
  entriesCommitted(sessionId: string): void;
}

export interface HomeOwnerOptions {
  tronHome: string;
  trust: TrustService;
  sessions: HomeSessionPort;
  diagnostic?: HomeDiagnostic;
  /** The Tron internal workspace whose capability state holds Home's memory. */
  workspace: TronWorkspace;
  /** Resolves the compactor's model the way Knowledge resolves the model for its
   * own calls: from the Gateway's ModelRuntime, never a session's runtime. */
  memorySummarizer: (model: ModelRef) => HomeMemoryModelResolution;
  /** Where Home's memory reports its bounded records. */
  memoryDiagnostic?: (record: HomeMemoryDiagnostic) => void;
  /** Where Home's request seam reports one record per activation and per
   * refusal: the effective size of a turn and the readiness wait it took. */
  requestDiagnostic?: (record: HomeRequestRecord) => void;
  taskSessions: RuntimeRegistry;
  notifications?: NotificationService;
  machineId?: string;
  taskDiagnostic?: (record: HomeTaskDiagnostic) => void;
  /** Knowledge supplies the learned profile section of Home's system prompt. */
  knowledge: () => KnowledgeService | undefined;
}

/**
 * The one owner of Tron Home's designation for this Gateway installation: the
 * durable record under `<tronHome>/gateway/home/home.json`, the neutral working
 * directory beside it, and the profile decision for every session id.
 *
 * Designation is keyed by session id: any session id that is not Home's current
 * chapter is an ordinary session, so a fork never inherits Home's designation.
 *
 * Home also owns its memory (one `EpisodicMemory` over the Home session's
 * canonical entries) and the request seam that turns each activation into fresh
 * context plus the frozen memory view. The memory lives here rather than in a
 * session's runtime because a runtime is evicted, replaced and rebuilt while the
 * memory and its spend must outlive all of them.
 */
export class HomeOwner {
  private readonly directory: string;
  private readonly recordPath: string;
  private workspacePath: string;
  private readonly mutex = new AsyncMutex();
  /** Serializes durable record commits with model callbacks that arrive from a
   * slot lane while a Home lifecycle mutation owns `mutex`. */
  private readonly recordMutex = new AsyncMutex();
  /** One memory per Home session id, replacing the previous session's. */
  private memory: { sessionId: string; owner: HomeMemory } | undefined;
  /** One request seam per Home session id, so a runtime replacement reuses the
   * open activation rather than dropping it. A fork is a new id, hence a new
   * seam and no activation. */
  private readonly policies = new Map<string, HomeRequestPolicy>();
  /** A creation-time Home profile exists before designation publishes its chapter. */
  private designating = false;
  private record: HomeRecord | undefined;
  private unavailable: string | undefined;
  private readonly tasks: HomeTaskDispatcher;
  private readonly inbox: WakeInboxOwner;
  /** The wake owner's single-flight state: one drain at a time, with one request
   * remembered while it runs. Nothing else starts a wake. */
  private wakeRequested = false;
  private wakeDrain: Promise<void> | undefined;
  /** Whether the last wake attempt delivered a trigger. Only a delivered wake
   * asks for another attempt when it ends, so a refused or failed wake cannot
   * retry itself in a loop. */
  private lastWakeDelivered = false;

  constructor(private readonly options: HomeOwnerOptions) {
    this.directory = join(options.tronHome, "gateway", "home");
    this.recordPath = join(this.directory, "home.json");
    this.workspacePath = join(this.directory, "workspace");
    const store = new HomeTaskStore(options.tronHome, options.workspace, options.taskDiagnostic ? { diagnostic: options.taskDiagnostic } : {});
    const authorization = new HomeTaskAuthorization({ store: store.authorization,
      ...(options.taskDiagnostic ? { diagnostic: options.taskDiagnostic } : {}),
      resolveTrustedTarget: async target => {
        const inspection = await options.trust.inspect(target);
        return inspection.effectiveDecision === true ? inspection.cwd : undefined;
      } });
    this.inbox = new WakeInboxOwner(store, {
      notify: input => options.notifications?.enqueue(input) ?? Promise.resolve("unavailable"),
      pushSession: homeId => this.openableChapterSession(homeId),
      ...(options.machineId ? { machineId: options.machineId } : {}),
      ...(options.taskDiagnostic ? { diagnostic: options.taskDiagnostic } : {}),
      result: taskId => this.immutableTaskReport(taskId),
      evidence: scope => this.inboxEvidence(scope),
      wakeAvailable: homeId => this.wakeAvailable(homeId),
      wake: () => this.requestWake(),
    });
    this.tasks = new HomeTaskDispatcher(store, authorization, options.taskSessions, options.taskDiagnostic, this.inbox);
  }

  /** Delegate authority is sampled for the exact enabled Home, never a fork or
   * disabled chapter. Home does not inherit a project's executable resources. */
  async dispatchTask(sessionId: string, request: HomeTaskDispatchRequest) {
    await this.taskOwner();
    const record = this.record;
    if (this.unavailable || !record?.enabled || homeSessionId(record) !== sessionId) {
      throw new GatewayError("conflict", "Task dispatch is unavailable for this Home");
    }
    return this.tasks.start({ homeId: record.homeId, generation: record.generation, routeGeneration: record.routeGeneration }, request);
  }

  /** Post-listen startup only (see `RuntimeRegistry.recoverHomeTasks`). Recovery
   * has no executable session lifetime to resurrect. */
  async recoverTasks(): Promise<void> {
    const recovery = await this.tasks.recover();
    // Recovery settled: pending results from before the restart may now wake Home. A refused recovery delivers nothing.
    if (recovery.available) this.requestWake();
  }

  private async taskOwner(): Promise<HomeTaskDispatcher> {
    await this.tasks.assertAvailable();
    return this.tasks;
  }

  async taskPermissions() { return (await this.taskOwner()).permissions(); }
  async revokeTaskScope(scopeId: string): Promise<{ accepted: true }> {
    await (await this.taskOwner()).revokeScope(scopeId); return { accepted: true };
  }
  async revokeTaskGrant(grantId: string): Promise<{ accepted: true }> {
    await (await this.taskOwner()).revokeGrant(grantId); return { accepted: true };
  }
  async decideTaskGrant(requestId: string, input: { decisionId: string; approved: boolean; expiresAt: number }) {
    return (await this.taskOwner()).decideGrant(requestId, input);
  }

  async reconfirmTaskPermissions(): Promise<{ reconfirmed: true }> {
    await (await this.taskOwner()).reconfirmPermissions();
    return { reconfirmed: true };
  }

  async steerTask(sessionId: string, control: HomeTaskControlRequest & { text: string }): Promise<void> {
    await this.taskOwner();
    const record = this.record;
    if (this.unavailable || !record?.enabled || homeSessionId(record) !== sessionId) throw new GatewayError("conflict", "Home task steering is unavailable");
    const task = await this.tasks.store.read(control.taskId);
    if (!task || task.homeId !== record.homeId || task.generation !== record.generation) throw new GatewayError("conflict", "Home task generation changed");
    await this.tasks.steer(control);
  }

  async taskTool(sessionId: string, request: import("./tron-home-extension.js").HomeTaskToolRequest): Promise<unknown> {
    await this.taskOwner();
    const record = this.record;
    if (this.unavailable || !record?.enabled || homeSessionId(record) !== sessionId) throw new GatewayError("conflict", "Home task control is unavailable");
    const task = await this.tasks.store.read(request.taskId);
    if (!task || task.homeId !== record.homeId) throw new GatewayError("conflict", "Home task identity changed");
    if (request.action === "status") return this.taskStatus(request.taskId);
    if (request.action === "report") {
      if (!Number.isSafeInteger(request.offset) || request.offset < 0 || !Number.isSafeInteger(request.limit) || request.limit < 1 || request.limit > 4096) throw new GatewayError("invalid_request", "Invalid report page");
      const { text } = await this.immutableTaskReport(request.taskId);
      const bytes = Buffer.from(text);
      if (request.offset > bytes.length || (request.offset < bytes.length && (bytes[request.offset]! & 0xc0) === 0x80)) throw new GatewayError("invalid_request", "Invalid report page offset");
      let end = Math.min(bytes.length, request.offset + request.limit);
      while (end < bytes.length && end > request.offset && (bytes[end]! & 0xc0) === 0x80) end--;
      if (end === request.offset && end < bytes.length) throw new GatewayError("invalid_request", "Report page is too small for the next UTF-8 character");
      return { taskId: task.taskId, offset: request.offset, bytes: bytes.length, text: bytes.subarray(request.offset, end).toString("utf8"), nextOffset: end < bytes.length ? end : null };
    }
    if (request.action !== "steer" && request.action !== "stop") throw new GatewayError("invalid_request", "Unknown Home task action");
    if (task.generation !== record.generation) throw new GatewayError("conflict", "Home task generation changed");
    if (request.action === "steer") await this.steerTask(sessionId, request);
    else await this.stopTask(request);
    return { accepted: true };
  }

  async maintainTask(control: HomeTaskControlRequest & { text: string }): Promise<void> {
    await (await this.taskOwner()).steer(control);
  }

  async stopTask(control: HomeTaskControlRequest): Promise<void> {
    await (await this.taskOwner()).stop(control);
  }

  async validateTaskMarker(sessionId: string, marker: unknown): Promise<void> {
    await (await this.taskOwner()).validateWorkerMarker(sessionId, marker);
  }

  private async immutableTaskReport(taskId: string): Promise<{ task: import("./home-task-store.js").HomeTaskRecord; text: string; subagents: HomeTaskSubagents }> {
    const task = await this.tasks.result(taskId);
    const report = task.reportRef;
    const entries = report && task.sessionId ? await this.options.taskSessions.readTaskEvidence(task.sessionId) : [];
    const entry = report && entries.find(entry => entry.id === report.entryId);
    return { task, subagents: await this.tasks.subagents(task),
      text: entry?.type === "custom" ? JSON.stringify(entry.data) : JSON.stringify({ evidence: task.terminalEvidence, spend: task.spend }) };
  }

  async taskList(input: { limit?: number; cursor?: string }) {
    const owner = await this.taskOwner();
    if (this.unavailable) throw new GatewayError("conflict", "Home is unavailable", false, { reason: this.unavailable });
    try { return await owner.store.page(input); }
    catch (error) {
      if (error instanceof HomeTaskStoreError) throw new GatewayError("conflict", "Home task list refused", false, { reason: error.code });
      throw error;
    }
  }

  async taskResult(taskId: string) {
    return (await this.taskOwner()).result(taskId);
  }

  /** The task record plus the worker's model, as the status RPC and Home's status tool show it. */
  async taskStatus(taskId: string) {
    return (await this.taskOwner()).status(taskId);
  }

  private wakeRoute(sessionId?: string): HomeWakeRoute | undefined {
    const record = this.record;
    if (this.unavailable || !record || (sessionId && homeSessionId(record) !== sessionId)) return undefined;
    return { homeId: record.homeId, routeGeneration: record.routeGeneration, generation: record.generation,
      enabled: record.enabled, sessionId: homeSessionId(record) };
  }

  /** Inbox delivery needs the task namespace's proof. While task recovery is
   * refused, nothing is delivered (and nothing this process admitted needs
   * settling), so the Home conversation itself stays usable. */
  private async inboxAvailable(): Promise<boolean> {
    return (await this.tasks.recoveryStatus()).available;
  }

  async admitTaskResults(sessionId: string, operationId: string, delivery: HomeWakeDelivery, append: (message: HomeWakeMessage) => Promise<void>, envelope: () => Promise<import("./home-wake-inbox.js").HomeWakeEnvelope>): Promise<HomeWakeTrigger | undefined> {
    const route = this.wakeRoute(sessionId);
    if (!route?.enabled || !(await this.inboxAvailable())) return undefined;
    await this.inbox.recover(route);
    return this.inbox.admit(route, operationId, delivery, append, envelope);
  }

  /** A wake whose trigger never reached the canonical session goes back to pending. */
  async releaseWakeTrigger(taskId: string, operationId: string): Promise<void> {
    await this.inbox.releaseTrigger(taskId, operationId);
  }

  async settleTaskResults(sessionId: string, operationId: string): Promise<void> {
    const route = this.wakeRoute(sessionId);
    if (route && await this.inboxAvailable()) await this.inbox.settle(route, operationId);
  }

  /** The Home session went idle after a user activation or a delivered wake. Only these two events can
   * ask for another wake: a refused or failed wake never does. A run that Stop or abort ended never
   * reaches this idle notice (home-wake.e2e Stop cases), so its pending results wait for the next event. */
  noteHomeIdle(sessionId: string, by: "user" | "wake"): void {
    if (!this.wakeRoute(sessionId)?.enabled) return;
    if (by === "user" || this.lastWakeDelivered) this.requestWake();
  }

  private requestWake(): void {
    this.wakeRequested = true;
    // A drain that fails must not become an unhandled rejection: the attempt is
    // reported and no further attempt starts until the next event.
    this.wakeDrain ??= this.drainWakes().catch(() => {
      this.wakeRequested = false;
      this.options.diagnostic?.({ outcome: "wake", decision: "refused", reason: "failed" });
    });
  }

  /** One drain at a time. An attempt that finds Home busy stops the drain: the
   * activation that holds Home settles later and asks again. */
  private async drainWakes(): Promise<void> {
    try {
      while (this.wakeRequested) {
        this.wakeRequested = false;
        if (await this.wakeOnce() === "busy") return;
      }
    } finally {
      this.wakeDrain = undefined;
    }
  }

  /** One wake attempt. Refusals decide each candidate's push once, so nothing
   * is announced twice: a disabled, paused or blocked Home keeps the task-finished
   * notice; a ceiling or an undeliverable result says Home is waiting. */
  private async wakeOnce(): Promise<"busy" | "done"> {
    const record = this.record;
    if (this.unavailable || !record || !(await this.inboxAvailable())) return "done";
    const sessionId = homeSessionId(record);
    if (!(await this.inbox.pendingTasks(record.homeId)).length) { this.lastWakeDelivered = false; return "done"; }
    // An attempt runs after recovery, so the task namespace and the session catalog are settled here.
    // A Home that never wrote its conversation has no session to run.
    const refusal = !(await this.options.sessions.sessionPresent(sessionId)) ? "unavailable" : await this.homeRefusal(record);
    if (refusal) {
      this.lastWakeDelivered = false;
      this.options.diagnostic?.({ outcome: "wake", decision: "refused", reason: refusal });
      await this.inbox.pushPending(record.homeId, "task");
      return "done";
    }
    if (await this.consecutiveWakes() >= HOME_WAKE_CEILING) {
      this.lastWakeDelivered = false;
      this.options.diagnostic?.({ outcome: "wake", decision: "refused", reason: "ceiling" });
      await this.inbox.pushPending(record.homeId, "waiting");
      return "done";
    }
    let delivered: boolean;
    try {
      ({ delivered } = await this.options.sessions.wakeHome(sessionId));
    } catch (error) {
      if (error instanceof GatewayError && error.code === "busy") {
        this.options.diagnostic?.({ outcome: "wake", decision: "deferred", reason: "busy" });
        return "busy";
      }
      this.lastWakeDelivered = false;
      this.options.diagnostic?.({ outcome: "wake", decision: "refused", reason: "failed" });
      await this.inbox.pushPending(record.homeId, "waiting");
      return "done";
    }
    this.lastWakeDelivered = delivered;
    if (!delivered) {
      this.options.diagnostic?.({ outcome: "wake", decision: "refused", reason: "nothing-deliverable" });
      await this.inbox.pushPending(record.homeId, "waiting");
    } else {
      this.options.diagnostic?.({ outcome: "wake", decision: "admitted", reason: "delivered" });
    }
    return "done";
  }

  /** Why Home's own state refuses a wake, or undefined. Eligibility reads only this: publish runs
   * inside task recovery, which must not wait on itself. */
  private async homeRefusal(record: HomeRecord): Promise<"disabled" | "paused" | "blocked" | undefined> {
    if (!record.enabled) return "disabled";
    const memory = await this.memoryStatus();
    if (!memory.configured || memory.blocked) return "blocked";
    if (memory.paused) return "paused";
    return undefined;
  }

  /** Whether a settled result may wake Home now: the record's own refusals. */
  private async wakeAvailable(homeId: string): Promise<boolean> {
    const record = this.record;
    return record?.homeId === homeId && (await this.homeRefusal(record)) === undefined;
  }

  /** Consecutive wake activations since the last user message, derived from the
   * canonical result messages: a wake delivers its results under its own operation
   * with no user message after them. Chapters are read newest first; the count
   * continues into an older chapter only while the newer ones hold no user message.
   * It is never stored, so the Home and task records keep their formats (#749). */
  private async consecutiveWakes(): Promise<number> {
    const record = this.record;
    if (!record) return 0;
    const operations = new Set<string>();
    for (const chapter of [...record.chapters].reverse()) {
      const path = await this.options.sessions.sessionFile(chapter.sessionId);
      // A chapter whose file was never created holds no entries.
      if (!path || !(await stat(path).then(() => true, () => false))) continue;
      let since = new Set<string>();
      let userSeen = false;
      await visitCanonicalSessionEntries({ path, sessionId: chapter.sessionId, maxLineBytes: EPISODIC_DEFAULTS.maxSourceLineBytes, visit: entry => {
        if (entry.type === "message" && (entry.raw.message as { role?: unknown } | undefined)?.role === "user") { since = new Set(); userSeen = true; }
        else if (entry.type === "custom_message" && entry.raw.customType === HOME_TASK_RESULT_MESSAGE) {
          const operationId = (entry.raw.details as { operationId?: unknown } | undefined)?.operationId;
          if (typeof operationId === "string") since.add(operationId);
        }
      } });
      for (const operation of since) operations.add(operation);
      if (userSeen || operations.size >= HOME_WAKE_CEILING) break;
    }
    return operations.size;
  }

  async redeliverTaskResult(taskId: string, expected: { homeId: string; routeGeneration: number }): Promise<{ accepted: true }> {
    await this.taskOwner();
    return this.recordMutex.run(async () => {
      const route = this.wakeRoute();
      if (!route || expected.homeId !== route.homeId || expected.routeGeneration !== route.routeGeneration) throw new GatewayError("conflict", "Home inbox route is unavailable or stale");
      await this.inbox.redeliver(taskId, route);
      return { accepted: true };
    });
  }

  /** Streams one chapter and keeps only this delivery's proof entries. A chapter
   * that is not part of this Home yields none, so its delivery is unproven. */
  private async inboxEvidence(scope: HomeWakeEvidenceScope): Promise<HomeWakeEvidence[]> {
    if (!this.record?.chapters.some(chapter => chapter.sessionId === scope.sessionId)) return [];
    const path = await this.options.sessions.sessionFile(scope.sessionId);
    if (!path) return [];
    // SDK append proves visibility, not power-loss durability. The inbox may
    // retire only after canonical bytes and their directory entry are synced.
    for (const durablePath of [path, dirname(path)]) {
      const handle = await open(durablePath, "r");
      try { await syncDurably(handle); } finally { await handle.close(); }
    }
    const entries: HomeWakeEvidence[] = [];
    await visitCanonicalSessionEntries({ path, sessionId: scope.sessionId, maxLineBytes: EPISODIC_DEFAULTS.maxSourceLineBytes, visit: entry => {
      const evidence = { ...entry.raw, type: entry.type, id: entry.id, sessionId: scope.sessionId } as HomeWakeEvidence;
      if (isWakeEvidence(scope, evidence)) entries.push(evidence);
    } });
    return entries;
  }

  /** Load the durable record once, before any runtime can ask for a profile. */
  async initialize(): Promise<void> {
    // Runtime cwd is canonicalized by TrustService; match that identity even
    // when the installation path itself contains symlinks.
    try {
      this.workspacePath = await realpath(this.workspacePath);
    } catch {
      // A malformed record can still coexist with an uncreated workspace. Its
      // existing parent is enough to canonicalize the future child identity.
      try { this.workspacePath = join(await realpath(this.directory), "workspace"); } catch { /* no Home directory yet */ }
    }
    await this.load();
  }

  async status(): Promise<HomeStatus> {
    const taskRecovery = await this.tasks.recoveryStatus();
    const memory = await this.memoryStatus();
    const activation = this.contextStatus();
    if (this.unavailable) {
      return {
        taskRecovery, phase: "unavailable", activation, readiness: { ready: false, gaps: ["record-unavailable"] },
        recovery: { action: "inspect-record", reason: this.unavailable },
        available: false, reason: this.unavailable, enabled: false, live: false, sessionPresent: false, memory,
      };
    }
    const record = this.record;
    if (!record) return {
      taskRecovery, phase: "undesignated", activation, readiness: { ready: false, gaps: ["not-designated"] },
      recovery: { action: "designate" },
      available: true, enabled: false, live: false, sessionPresent: false, memory,
    };
    const sessionId = homeSessionId(record);
    const currentChapter = record.chapters.at(-1)!;
    const live = this.options.sessions.hasLiveRuntime(sessionId);
    const sessionPresent = await this.options.sessions.sessionPresent(sessionId);
    const openable = openableChapter(record);
    const openSessionPresent = openable === undefined ? false
      : openable === currentChapter ? sessionPresent : await this.options.sessions.sessionPresent(openable.sessionId);
    const openSessionId = openable !== undefined && openSessionPresent ? openable.sessionId : undefined;
    // Missing-session recovery is a status, never zero-valued admission metrics.
    const activeMetrics = sessionPresent && currentChapter.state === "active"
      ? await this.options.sessions.chapterMetrics(currentChapter.sessionId)
      : undefined;
    const gaps: string[] = [];
    if (!record.enabled) gaps.push("disabled");
    if (!sessionPresent) gaps.push("session-missing");
    if (!memory.configured) gaps.push("memory-not-configured");
    if (memory.blocked) gaps.push(`memory-${memory.blocked}`);
    if (memory.paused) gaps.push("memory-paused");
    const recovery: HomeStatus["recovery"] = !record.enabled || !sessionPresent
      ? { action: "designate", ...(!sessionPresent ? { reason: "Home session is missing" } : {}) }
      : !memory.configured ? { action: "configure-memory" }
        : memory.paused || memory.blocked ? { action: "resume-memory", reason: memory.paused ? "memory-paused" : memory.blocked! }
          : { action: "none" };
    const ready = gaps.length === 0;
    const phase: HomeStatus["phase"] = !record.enabled ? "disabled"
      : record.chapters.at(-1)!.state === "reserved" || record.chapters.at(-1)!.state === "materializing" ? "rollover-pending"
        : !sessionPresent ? "missing-session"
          : memory.blocked || !memory.configured ? "blocked"
          : activation.available && activation.activationOpen ? "active" : memory.paused ? "paused" : "ready";
    return {
      taskRecovery, phase, activation, readiness: { ready, gaps }, recovery,
      available: true,
      enabled: record.enabled,
      homeId: record.homeId,
      sessionId,
      ...(openSessionId === undefined ? {} : { openSessionId }),
      bindingRevision: record.bindingRevision,
      generation: record.generation,
      routeGeneration: record.routeGeneration,
      model: { ...record.model },
      live,
      sessionPresent,
      memory,
      chapter: {
        count: record.chapters.length,
        ...((activeMetrics?.bytes ?? currentChapter.sizeAtSeal) === undefined ? {} : { currentBytes: activeMetrics?.bytes ?? currentChapter.sizeAtSeal }),
        ...((activeMetrics?.entries ?? currentChapter.entriesAtSeal) === undefined ? {} : { currentEntries: activeMetrics?.entries ?? currentChapter.entriesAtSeal }),
        recoveryDecision: currentChapter.state === "reserved" ? "reserved"
          : currentChapter.state === "materializing" ? "materializing" : "none",
      },
    };
  }

  /**
   * `home.chapterList`: the full chapter ledger as one bounded read (#740).
   * Sealed chapters answer exactly their recorded seal metrics (a chapter sealed
   * by disable has none); only the active chapter is measured live, and only when
   * its session is present, so a missing session is absent sizes, never zero. The
   * limits are the shared rollover constants, not a second copy.
   */
  async chapterList(): Promise<HomeChapterList> {
    this.assertAvailable();
    const record = this.record;
    if (!record) throw new GatewayError("not_found", "Tron Home is not designated");
    const chapters: HomeChapterSummary[] = [];
    for (const chapter of record.chapters) {
      const sessionPresent = await this.options.sessions.sessionPresent(chapter.sessionId);
      let bytes = chapter.sizeAtSeal;
      let entries = chapter.entriesAtSeal;
      if (chapter.state === "active" && sessionPresent) {
        const metrics = await this.options.sessions.chapterMetrics(chapter.sessionId);
        bytes = metrics.bytes;
        entries = metrics.entries;
      }
      chapters.push({
        sessionId: chapter.sessionId,
        ordinal: chapter.ordinal,
        state: chapter.state,
        createdAt: chapter.createdAt,
        activationStarted: chapter.activationStarted,
        sessionPresent,
        ...(chapter.sealedAt === undefined ? {} : { sealedAt: chapter.sealedAt }),
        ...(bytes === undefined ? {} : { bytes }),
        ...(entries === undefined ? {} : { entries }),
      });
    }
    return {
      homeId: record.homeId,
      generation: record.generation,
      enabled: record.enabled,
      limits: { softBytes: HOME_SOFT_BYTES, softEntries: HOME_SOFT_ENTRIES, hardBytes: HOME_HARD_BYTES, hardEntries: HOME_HARD_ENTRIES },
      chapters,
    };
  }

  /** The admitted model for the enabled Home at the runtime construction
   * boundary; ordinary sessions keep their transcript-selected model. */
  modelFor(sessionId: string): ModelRef | undefined {
    const record = this.record;
    return record?.enabled && record.chapters.some(chapter => chapter.sessionId === sessionId) ? { ...record.model } : undefined;
  }

  /** Only the current active chapter is writable; sealed and in-progress
   * successor entries fail closed until their owning lifecycle transition lands. */
  chapterStateFor(sessionId: string): HomeChapterState {
    const chapter = this.record?.chapters.find(candidate => candidate.sessionId === sessionId);
    if (chapter?.state === "materializing") return {
      sessionId, sealed: true, materializing: true, homeId: this.record!.homeId,
      ordinal: chapter.ordinal,
      ...(chapter.attemptId ? { attemptId: chapter.attemptId } : {}),
      ...(chapter.expectedPath ? { expectedPath: chapter.expectedPath } : {}),
    };
    if (chapter?.state === "sealed" || chapter?.state === "reserved") {
      return { sessionId, sealed: true, homeId: this.record!.homeId, ordinal: chapter.ordinal };
    }
    return chapter
      ? { sessionId, sealed: false, homeId: this.record!.homeId, ordinal: chapter.ordinal }
      : unsealedHomeChapterState(sessionId);
  }

  noteRouteBound(category: Extract<HomeDiagnosticRecord, { outcome: "route-bound" }>["category"]): void {
    this.options.diagnostic?.({ outcome: "route-bound", category });
  }

  /** One admission policy for logical binding and serialized physical prompts.
   * A physical target cannot silently transfer to the successor. */
  assertChapterAdmission(sessionId: string, metrics: { bytes: number; entries: number }): void {
    const chapter = this.record?.chapters.find(candidate => candidate.sessionId === sessionId);
    if (!chapter) return;
    const reason = metrics.bytes >= HOME_HARD_BYTES ? "hard-bytes"
      : metrics.entries >= HOME_HARD_ENTRIES ? "hard-entries" : undefined;
    if (!reason) return;
    this.options.diagnostic?.({ outcome: "chapter-refused", chapterOrdinal: chapter.ordinal, reason });
    throw new GatewayError("conflict", "This Home chapter has reached its hard limit; continue through Home", true, { reason });
  }

  /** Hard admission is a durable chapter transition before the command receipt binds a target. */
  async ensureChapterBelowHardLimit(): Promise<void> {
    const chapter = this.record?.chapters.at(-1);
    if (!chapter || chapter.state !== "active") return;
    const metrics = await this.options.sessions.chapterMetrics(chapter.sessionId);
    try { this.assertChapterAdmission(chapter.sessionId, metrics); }
    catch (error) {
      if (!(error instanceof GatewayError) || error.code !== "conflict") throw error;
      if (!metrics.quiescent) {
        throw new GatewayError("busy", "Tron Home is stopping an activation at the chapter limit; retry after it settles", true);
      }
      await this.chapterQuiescent(chapter.sessionId);
    }
  }

  open(): HomeOpen {
    const binding = this.routeBinding();
    const record = this.record!;
    return {
      logicalSessionId: "home",
      homeId: binding.homeId,
      bindingRevision: binding.bindingRevision,
      sessionId: binding.physicalSessionId,
      generation: record.generation,
      chapterState: record.chapters.at(-1)!.state,
    };
  }

  /** Stable logical route target. A reserved successor's next binding revision
   * is fixed before it can receive a command. */
  routeBinding(): { homeId: string; bindingRevision: number; physicalSessionId: string } {
    this.assertAvailable();
    const record = this.record;
    if (!record || !record.enabled) throw new GatewayError("not_found", "Tron Home is not enabled");
    const chapter = record.chapters.at(-1)!;
    return {
      homeId: record.homeId,
      bindingRevision: chapter.state === "active" ? record.bindingRevision : record.bindingRevision + 1,
      physicalSessionId: chapter.sessionId,
    };
  }

  assertRouteBinding(binding: { homeId: string; bindingRevision: number; physicalSessionId: string }): void {
    const current = this.routeBinding();
    if (current.homeId !== binding.homeId || current.bindingRevision !== binding.bindingRevision
      || current.physicalSessionId !== binding.physicalSessionId) {
      throw new GatewayError("conflict", "The Home route binding is stale; open Home again before sending", false, {
        reason: "binding-stale", bindingRevision: binding.bindingRevision,
      });
    }
  }

  async assertReservedChapterAttempt(sessionId: string, attemptId: string, expectedPath: string): Promise<void> {
    await this.recordMutex.run(async () => {
      const chapter = this.record?.chapters.find(candidate => candidate.sessionId === sessionId);
      if (!chapter
        || (chapter.state !== "materializing" && chapter.state !== "active")
        || (chapter.state === "materializing" && (chapter.attemptId !== attemptId || chapter.expectedPath !== expectedPath))) {
        this.options.diagnostic?.({ outcome: "chapter-refused", reason: "ownership-changed" });
        throw new GatewayError("conflict", "Home materialization attempt no longer owns its reservation", true);
      }
      if (chapter.state === "active" && !(await this.options.sessions.hasConversation(sessionId, expectedPath))) {
        this.options.diagnostic?.({ outcome: "chapter-refused", reason: "missing-conversation-evidence" });
        throw new GatewayError("conflict", "Published Home chapter lacks durable conversation evidence", true);
      }
    });
  }

  async assertPublishedHomeChapter(sessionId: string, expectedPath: string): Promise<void> {
    await this.recordMutex.run(async () => {
      const chapter = this.record?.chapters.find(candidate => candidate.sessionId === sessionId);
      if (chapter?.state !== "active" || !(await this.options.sessions.hasConversation(sessionId, expectedPath))) {
        this.options.diagnostic?.({ outcome: "chapter-refused", reason: "published-evidence-missing" });
        throw new GatewayError("conflict", "Active Home chapter lacks durable conversation evidence", true);
      }
    });
  }

  /** Claim a durable reserved successor for the Registry's single-flight owner.
   * Replacing an older attempt is recovery after the prior Gateway process exited. */
  async claimReservedChapter(sessionId: string, attemptId: string): Promise<HomeChapter> {
    return this.recordMutex.run(async () => {
      const current = this.record;
      const chapter = current?.chapters.find(candidate => candidate.sessionId === sessionId);
      if (!current || !chapter || (chapter.state !== "reserved" && chapter.state !== "materializing")) {
        throw new GatewayError("conflict", "Home chapter is not reserved for materialization");
      }
      const claimed: HomeChapter = { ...chapter, state: "materializing", attemptId };
      await this.writeLocked({
        ...current,
        chapters: current.chapters.map(candidate => candidate.sessionId === sessionId ? claimed : candidate),
        updatedAt: new Date().toISOString(),
      });
      return { ...claimed };
    });
  }

  /** Persist the exact SDK path before the caller can admit canonical input. */
  async recordReservedChapterPath(sessionId: string, attemptId: string, expectedPath: string): Promise<void> {
    await this.recordMutex.run(async () => {
      const current = this.record;
      const chapter = current?.chapters.find(candidate => candidate.sessionId === sessionId);
      if (!current || !chapter || chapter.state !== "materializing" || chapter.attemptId !== attemptId) {
        throw new GatewayError("conflict", "Home materialization attempt no longer owns its reservation");
      }
      await this.writeLocked({
        ...current,
        chapters: current.chapters.map(candidate => candidate.sessionId === sessionId
          ? { ...candidate, expectedPath }
          : candidate),
        updatedAt: new Date().toISOString(),
      });
    });
  }

  /** Bounded chapter metadata consumed by Registry recovery; never exposes mutable record state. */
  reservedChapter(sessionId: string): HomeChapter | undefined {
    const chapter = this.record?.chapters.find(candidate => candidate.sessionId === sessionId);
    return chapter && (chapter.state === "reserved" || chapter.state === "materializing") ? { ...chapter } : undefined;
  }

  /** The canonical cwd used to locate Home's physical session directory. */
  homeWorkspacePath(): string { return this.workspacePath; }

  /** The chapter a task-result push opens for `homeId`: the same openable chapter
   * `home.status` reports, so a tap lands where the Home row would. */
  private openableChapterSession(homeId: string): string | undefined {
    const record = this.record;
    return record?.homeId === homeId ? openableChapter(record)?.sessionId : undefined;
  }

  /** What the record says about one session id. Runtime creation reads this for
   * every runtime it builds, so a replacement is never built from a stale
   * profile decision. */
  profileFor(sessionId: string, cwd?: string): HomeSessionProfile {
    const record = this.record;
    if (this.unavailable && cwd === this.workspacePath) {
      throw new GatewayError("conflict", `Tron Home is unavailable: ${this.unavailable}`);
    }
    if (!record || !record.chapters.some(chapter => chapter.sessionId === sessionId)) return "unnamed";
    return record.enabled ? "home" : "ordinary";
  }

  /**
   * The request seam for one session id, or undefined for every other session.
   * A runtime asks for it once per runtime creation, so a replacement (a reload,
   * a profile change) gets the same seam and keeps its open activation; only a
   * fork — a new session id — gets a fresh one.
   *
   * The caller has already decided the runtime is Home's. The only two sessions
   * that can be: the one the record names and enables, and the one a designation
   * in flight is creating (its first runtime is built before the record can name
   * it — the same window `isHomeProfile` covers with its explicit profile).
   */
  requestPolicyFor(sessionId: string): HomeRequestPolicy | undefined {
    const record = this.record;
    const designated = record !== undefined && record.enabled && record.chapters.some(chapter => chapter.sessionId === sessionId && (chapter.state === "active" || chapter.state === "materializing"));
    if (!designated && !this.designating) return undefined;
    let policy = this.policies.get(sessionId);
    if (!policy) {
      policy = new HomeRequestPolicy({
        prepareMemoryView: (activation: HomeActivationIdentity, signal: AbortSignal | undefined) => this.memoryView(activation, signal),
        prepareSystemPrompt: (base: string) => homeSystemPrompt(base, this.options.knowledge),
        ...(this.options.requestDiagnostic ? { onRecord: this.options.requestDiagnostic } : {}),
      });
      this.policies.set(sessionId, policy);
    }
    return policy;
  }

  /**
   * The canonical entries of one session changed (a persisted message, a context
   * edit, a navigation). Fire and forget: the memory re-reads the log after its
   * cursor and drains its pump under its own bounds, so no caller waits on it.
   *
   * A session whose memory is not open yet is not opened here: designation and
   * `home.configureMemory` decide when a memory starts spending.
   */
  noteEntriesCommitted(sessionId: string): void {
    const record = this.record;
    const chapter = record?.chapters.find(candidate => candidate.sessionId === sessionId);
    if (!record || !record.enabled || !chapter || (chapter.state !== "active" && chapter.state !== "materializing")) return;
    if (this.memory?.sessionId === record.homeId) this.memory.owner.noteEntriesCommitted();
    if (chapter.state === "materializing" && chapter.attemptId && chapter.expectedPath) {
      void this.publishObservedMaterialization(sessionId, chapter.attemptId, chapter.expectedPath).catch(() => {
        this.options.diagnostic?.({ outcome: "chapter-refused", reason: "publication-failed" });
      });
    }
  }

  /** Called by the Slot only after the completed turn has reached a quiescent boundary. */
  async chapterQuiescent(sessionId: string): Promise<void> {
    const record = this.record;
    const chapter = record?.chapters.find(candidate => candidate.sessionId === sessionId);
    if (!record || !record.enabled || !chapter) return;
    if (chapter.state === "materializing" && chapter.attemptId && chapter.expectedPath) {
      const published = await this.publishObservedMaterialization(sessionId, chapter.attemptId, chapter.expectedPath);
      if (!published) this.options.diagnostic?.({ outcome: "chapter-refused", reason: "conversation-not-durable" });
      return;
    }
    if (chapter.state !== "active") return;
    // Registry session ordering is outermost; remeasure after admitted
    // mutations settle, then take recordMutex only for the final ledger write.
    const rolled = await this.options.sessions.serializeSessionMutation(sessionId, async () => {
      const metrics = await this.options.sessions.chapterMetrics(sessionId);
      if (!metrics.quiescent || (metrics.bytes < HOME_SOFT_BYTES && metrics.entries < HOME_SOFT_ENTRIES
        && metrics.bytes < HOME_HARD_BYTES && metrics.entries < HOME_HARD_ENTRIES)) return undefined;
      const sealed = await this.recordMutex.run(async () => {
        const current = this.record;
        const active = current?.chapters.find(candidate => candidate.sessionId === sessionId);
        if (!current || !active || active.state !== "active") return false;
        const now = new Date().toISOString();
        const successor: HomeChapter = {
          sessionId: randomUUID(), ordinal: active.ordinal + 1, state: "reserved", createdAt: now, activationStarted: false,
        };
        await this.writeLocked({
          ...current,
          chapters: current.chapters.map(candidate => candidate.sessionId === sessionId
            ? { ...candidate, state: "sealed" as const, sealedAt: now, sizeAtSeal: metrics.bytes, entriesAtSeal: metrics.entries }
            : candidate).concat(successor),
          updatedAt: now,
        });
        return true;
      });
      return sealed ? metrics : undefined;
    });
    if (rolled) this.options.diagnostic?.({
      outcome: "chapter-rollover", chapterOrdinal: chapter.ordinal,
      reason: rolled.bytes >= HOME_HARD_BYTES ? "hard-byte-limit"
        : rolled.entries >= HOME_HARD_ENTRIES ? "hard-entry-limit"
          : rolled.bytes >= HOME_SOFT_BYTES ? "soft-byte-limit" : "soft-entry-limit",
    });
  }

  async publishObservedMaterialization(sessionId: string, attemptId: string, expectedPath: string): Promise<boolean> {
    return this.recordMutex.run(async () => {
      const current = this.record;
      const chapter = current?.chapters.find(candidate => candidate.sessionId === sessionId);
      if (!current || !current.enabled || chapter?.state !== "materializing"
        || chapter.attemptId !== attemptId || chapter.expectedPath !== expectedPath) return false;
      const currentPath = await this.options.sessions.sessionFile(sessionId);
      const observed = currentPath === expectedPath && await this.options.sessions.hasConversation(sessionId, expectedPath);
      if (!currentPath || currentPath !== expectedPath || !observed) return false;
      const now = new Date().toISOString();
      await this.writeLocked({
        ...current,
        chapters: current.chapters.map(candidate => candidate.sessionId === sessionId
          ? { sessionId, ordinal: candidate.ordinal, state: "active", createdAt: candidate.createdAt, activationStarted: candidate.activationStarted }
          : candidate),
        bindingRevision: current.bindingRevision + 1,
        updatedAt: now,
      });
      this.options.diagnostic?.({ outcome: "chapter-recovery", reason: "conversation-published" });
      return true;
    });
  }

  /**
   * The memory tools for one session id, or undefined for every session that is
   * not the enabled Home. The slot builds a Home runtime's extension factories
   * once, but the answer is resolved at each call: the record, the open store, a
   * block and a reconfiguration all change while a runtime is alive, and no tool
   * may read a superseded memory. A tool call is only reachable from an
   * activation, which has already opened the memory it runs on, so this accessor
   * never opens or configures one.
   */
  memoryToolsFor(sessionId: string): HomeMemoryToolAccess | undefined {
    const record = this.record;
    if (!record || !record.enabled || !record.chapters.some(chapter => chapter.sessionId === sessionId && (chapter.state === "active" || chapter.state === "materializing"))) return undefined;
    return {
      zoom: (id, n) => this.toolMemory(sessionId, memory => memory.zoom(id, n)),
      date: id => this.toolMemory(sessionId, memory => memory.date(id)),
      search: (query, from, to) => this.toolMemory(sessionId, memory => memory.search(query, from, to)),
    };
  }

  /**
   * `home.configureMemory`: record the model Home's memory runs its compactor
   * calls on. There is no budget to manage (#493): the memory's spend is bounded
   * by construction and grows only with the conversation. The memory is opened (or re-opened, when the model changed)
   * before the record is written, so a refused configuration changes nothing and
   * a different model resumes a blocked memory without losing the nodes it built.
   */
  async configureMemory(input: { model: ModelRef }): Promise<HomeMemoryStatus> {
    return this.clientControl("configureMemory", () => this.mutex.run(async () => {
      this.assertAvailable();
      const record = this.record;
      if (!record) throw new GatewayError("not_found", "Tron Home is not designated");
      if (!record.enabled) {
        // A disabled Home runs no activations, so a memory configuration would
        // name spending nothing can use. Designate it first.
        throw new GatewayError("conflict", "Tron Home is disabled: designate it before configuring its memory");
      }
      const memory = { ...record.memory, model: { ...input.model } };
      const owner = this.ownerFor(record.homeId);
      await owner.configure(memory);
      await this.recordMutex.run(async () => {
        const current = this.record;
        if (!current || current.homeId !== record.homeId || !current.enabled) {
          throw new GatewayError("conflict", "Tron Home changed while configuring its memory");
        }
        await this.writeLocked({ ...current, memory, updatedAt: new Date().toISOString() });
      });
      // Configuration is not a designation/profile transition.
      return this.memoryStatus();
    }));
  }

  /** Durable suspension is a memory decision, not a runtime profile change.
   * Already-frozen activations retain their view; outstanding readiness waits
   * refuse explicitly. The pump finishes accepted nodes, then stops admission. */
  async pauseMemory(): Promise<HomeMemoryStatus> {
    return this.clientControl("pauseMemory", () => this.mutex.run(async () => {
      const record = this.requireEnabledMemory();
      await this.commitMemoryPause(record, true);
      this.memory?.owner.notePause();
      return this.memoryStatus();
    }));
  }

  /** Resume operator pause and/or block recovery. Committed nodes remain owned
   * by the same store, so resuming never rebuilds them merely due to suspension. */
  async resumeMemory(): Promise<HomeMemoryStatus> {
    return this.clientControl("resumeMemory", () => this.mutex.run(async () => {
      const record = this.requireEnabledMemory();
      const owner = this.ownerFor(record.homeId);
      await owner.configure(record.memory!);
      if (!record.memory!.paused && !owner.status().blocked) {
        throw new GatewayError("conflict", "Home memory is neither paused nor blocked");
      }
      await this.commitMemoryPause(record, false);
      try { await owner.resume(); }
      catch (error) {
        if (error instanceof HomeMemoryRefusal) throw new GatewayError("conflict", error.message);
        throw error;
      }
      return this.memoryStatus();
    }));
  }

  private requireEnabledMemory(): HomeRecord {
    this.assertAvailable();
    const record = this.record;
    if (!record) throw new GatewayError("not_found", "Tron Home is not designated");
    if (!record.enabled) throw new GatewayError("conflict", "Tron Home is disabled: designate it before controlling its memory");
    if (!record.memory) throw new GatewayError("conflict", "Home memory is not configured: configure it with home.configureMemory");
    return record;
  }

  private async commitMemoryPause(record: HomeRecord, paused: boolean): Promise<void> {
    await this.options.sessions.serializeSessionMutation(homeSessionId(record), () => this.recordMutex.run(async () => {
      const current = this.requireEnabledMemory();
      if (current.homeId !== record.homeId) throw new GatewayError("conflict", "Tron Home changed during memory control");
      if (Boolean(current.memory!.paused) === paused) return;
      await this.writeLocked({
        ...current,
        memory: { model: { ...current.memory!.model }, ...(paused ? { paused: true as const } : {}) },
        updatedAt: new Date().toISOString(),
      });
    }));
  }

  private async clientControl<T>(operation: "configureMemory" | "pauseMemory" | "resumeMemory", run: () => Promise<T>): Promise<T> {
    try {
      const result = await run();
      this.options.diagnostic?.({ outcome: "client-control", operation, reason: "completed" });
      return result;
    } catch (error) {
      this.options.diagnostic?.({ outcome: "client-control", operation, reason: error instanceof GatewayError ? error.code : "failed" });
      throw error;
    }
  }

  /**
   * The bounded memory status `home.status` reports. A memory whose store is not
   * open yet still reports what a restart would restore (its recorded spend and
   * the block that refuses every activation), read from the store's own state
   * document without opening it.
   */
  async memoryStatus(): Promise<HomeMemoryStatus> {
    const record = this.record;
    if (!record) return { configured: false, open: false, paused: false };
    const paused = Boolean(record.memory?.paused);
    const owner = this.memory?.sessionId === record.homeId ? this.memory.owner : undefined;
    if (owner?.open) return { ...owner.status(), paused };
    const base: HomeMemoryStatus = record.memory
      ? { configured: true, open: false, model: { ...record.memory.model } }
      : { configured: false, open: false };
    base.paused = paused;
    const persisted = await (owner ?? this.ownerFor(record.homeId)).persistedState().catch(() => undefined);
    if (!persisted) return base;
    return {
      ...base,
      spentTokens: persisted.spend,
      ...(persisted.blocked ? { blocked: persisted.blocked.reason } : {}),
    };
  }

  async memoryPage(request: HomeMemoryPageRequest, signal?: AbortSignal): Promise<HomeMemoryPage> {
    return this.browserRead(async memory => memory.browserPage(request), signal);
  }

  async memoryEvidence(evidence: HomeMemoryEvidence, offset: number, signal?: AbortSignal): Promise<HomeMemoryEvidencePage> {
    return this.browserRead(async (memory, source) => {
      // Refuse arbitrary/cross-chapter references before opening evidence.
      memory.assertBrowserEvidence(evidence);
      const cursor = memory.browserCursor();
      if (!cursor) throw homeMemorySourceUnavailable();
      const entry = await readCanonicalHomeEvidence(source, cursor, evidence, EPISODIC_DEFAULTS, signal);
      signal?.throwIfAborted();
      const { runtimeGeneration: _generation, entryId: _entryId, ...content } = historyEntry(
        { getEntry: id => id === entry.id ? entry.raw as unknown as SessionEntry : undefined },
        memory.browserRevision(), evidence.entryId, offset,
      );
      return { format: "canonical-history", evidence: { ...evidence }, ...content };
    }, signal);
  }

  /** One read boundary proves every admitted chapter and fences both ledger
   * and memory revisions. No partial success, cursor registry or transcript cache. */
  private async browserRead<T>(read: (memory: EpisodicMemory, source: HomeSourceSnapshot) => Promise<T>, signal?: AbortSignal): Promise<T> {
    return this.mutex.run(async () => {
      signal?.throwIfAborted();
      this.assertAvailable();
      const record = this.record;
      if (!record?.memory) throw new GatewayError("conflict", "Home memory is not configured");
      const owner = this.ownerFor(record.homeId);
      try {
        await owner.configure(record.memory);
        signal?.throwIfAborted();
        return await owner.browserRead(async memory => {
          const cursor = memory.browserCursor();
          if (!cursor) throw homeMemorySourceUnavailable();
          const source = await this.readHomeSource();
          signal?.throwIfAborted();
          // Consume to completion: a late chapter failure cannot publish an
          // earlier chapter as a complete page or exact evidence.
          for await (const _entry of readCanonicalHomeIndex(source, cursor, EPISODIC_DEFAULTS, signal)) { /* proof only */ }
          signal?.throwIfAborted();
          const result = await read(memory, source);
          signal?.throwIfAborted();
          if (this.record !== record || this.memory?.owner !== owner) throw homeMemoryRevisionChanged();
          return result;
        }, signal);
      } catch (error) {
        signal?.throwIfAborted();
        if (error instanceof GatewayError) throw error;
        if (error instanceof EpisodicMemoryError || error instanceof EpisodicSourceChangedError || error instanceof HomeMemoryRefusal) throw homeMemorySourceUnavailable();
        throw error;
      }
    }, signal);
  }

  /**
   * `home.context`: the bounded request context of Home's current or last
   * activation. Sizes and identifiers only, never a message body: the frozen
   * view text stays in the request that carried it.
   */
  contextStatus(): HomeContextProjection {
    const record = this.record;
    if (!record) return { available: false };
    const evidence = this.policies.get(homeSessionId(record))?.contextEvidence();
    if (!evidence) return { available: false };
    const step = evidence.step;
    return {
      available: true,
      activationStartEntryId: evidence.activationStartEntryId,
      activationOpen: evidence.activationOpen,
      // Absent until the activation prepared a request: an activation refused
      // before that has a start entry and a reason, and no sizes.
      ...(step ? {
        viewLines: step.viewLines,
        viewBytes: step.viewBytes,
        effectiveTokens: step.effectiveTokens,
        contextWindow: step.contextWindow,
      } : {}),
      ...(evidence.refusal ? { lastRefusalReason: evidence.refusal.reason, lastRefusalDetail: evidence.refusal.detail } : {}),
    };
  }

  /** The memory a tool read runs against, or the typed answer for why there is
   * none. A missing memory is `memory-not-configured` when the record holds no
   * configuration and `memory-unavailable` when it holds one the store has not
   * opened. */
  private toolMemory(sessionId: string, read: (memory: HomeMemory) => Promise<HomeMemoryToolResult>): Promise<HomeMemoryToolResult> {
    const record = this.record;
    const memory = record && record.enabled
      && record.chapters.some(chapter => chapter.sessionId === sessionId && (chapter.state === "active" || chapter.state === "materializing"))
      && this.memory?.sessionId === record.homeId
      ? this.memory.owner
      : undefined;
    if (memory) return read(memory);
    return Promise.resolve(homeMemoryToolUnavailable(record?.memory ? "memory-unavailable" : "memory-not-configured"));
  }

  /** Release the memory store and the request seams. */
  async dispose(): Promise<void> {
    this.policies.clear();
    const memory = this.memory;
    this.memory = undefined;
    await memory?.owner.dispose();
  }

  /**
   * The frozen memory view for one activation: the memory must be configured
   * (decision D4's no-defaults rule), must be able to place the activation's
   * start entry, and must be able to cover it before the request is built.
   */
  private async memoryView(activation: HomeActivationIdentity, signal: AbortSignal | undefined): Promise<HomeActivationView> {
    // Reachable only through a seam, which exists only for the enabled Home
    // session or for the session a designation in flight is creating.
    const record = this.record;
    if (!record || !record.enabled) {
      throw new HomeMemoryRefusal("memory-not-configured", "Tron Home is not enabled");
    }
    if (!record.memory) {
      throw new HomeMemoryRefusal("memory-not-configured", "Home memory is not configured");
    }
    if (record.memory.paused) {
      throw new HomeMemoryRefusal("memory-paused", "Home memory is paused; resume memory before sending another input");
    }
    const owner = this.ownerFor(record.homeId);
    // After a Gateway restart the record still holds the configuration; the
    // first activation opens the store from it.
    const chapter = record.chapters.at(-1)!;
    const path = await this.options.sessions.sessionFile(chapter.sessionId);
    const present = path ? await stat(path).then(() => true, error => { if ((error as NodeJS.ErrnoException).code === "ENOENT") return false; throw error; }) : false;
    if (!present && chapter.activationStarted) throw new HomeMemoryRefusal("memory-unavailable", "A started Home chapter has lost its canonical file");
    await owner.configure(record.memory);
    let view: HomeActivationView;
    if (!present && chapter.ordinal === 1) {
      view = owner.emptyChapterView(signal);
    } else if (!present) {
      // The current chapter has no preceding messages yet. Its prefix is the
      // validated sealed history, not an installation-wide empty exception.
      view = await owner.precedingChapterView(signal);
    } else {
      view = await owner.activationView(activation, signal);
    }
    if (!chapter.activationStarted) await this.recordMutex.run(async () => {
      const current = this.record;
      if (!current || current.generation !== record.generation || current.chapters.at(-1)?.sessionId !== chapter.sessionId) throw new HomeMemoryRefusal("memory-unavailable", "Home chapter changed during activation admission");
      if (!current.chapters.at(-1)!.activationStarted) await this.writeLocked({ ...current,
        chapters: current.chapters.map(candidate => candidate.sessionId === chapter.sessionId ? { ...candidate, activationStarted: true } : candidate), updatedAt: new Date().toISOString() });
    });
    return view;
  }

  /** One memory owner and persisted namespace for the stable installation Home. */
  private async readHomeSource(): Promise<HomeSourceSnapshot> {
    const record = this.record;
    if (!record) throw new GatewayError("conflict", "Tron Home is unavailable");
    const chapters: HomeSourceChapter[] = [];
    for (const chapter of record.chapters) {
      if (chapter.state !== "sealed" && chapter.state !== "active" && chapter.state !== "materializing") continue;
      let path: string | undefined;
      try { path = await this.options.sessions.sessionFile(chapter.sessionId); }
      catch (error) {
        if (chapter.state === "sealed") throw new EpisodicMemoryError("source", `Sealed Home chapter ${chapter.sessionId} cannot be resolved: ${String(error)}`);
        throw error;
      }
      if (!path) {
        if (chapter.state === "sealed") throw new EpisodicMemoryError("source", `Sealed Home chapter ${chapter.sessionId} has no catalog path`);
        continue;
      }
      const info = await stat(path).catch(error => {
        if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
        throw error;
      });
      if (!info?.isFile()) {
        if (chapter.state === "sealed") throw new EpisodicMemoryError("source", `Sealed Home chapter ${chapter.sessionId} is unavailable`);
        continue;
      }
      chapters.push({ sessionId: chapter.sessionId, path, sealed: chapter.state === "sealed" });
    }
    if (chapters.length === 0) throw new GatewayError("conflict", "Home has no canonical chapter file to read");
    return {
      homeId: record.homeId,
      ledgerRevision: record.bindingRevision,
      chapters,
    };
  }

  private ownerFor(homeId: string): HomeMemory {
    const current = this.memory;
    if (current && current.sessionId === homeId) return current.owner;
    if (current) void current.owner.dispose();
    const source = () => this.readHomeSource();
    const owner = new HomeMemory({
      workspace: this.options.workspace,
      sessionId: homeId,
      sessionFile: async () => {
        // A new chapter's SDK file is staged until its first user entry. Memory
        // still belongs to the installation and validates all prior chapters.
        const chapters = this.record?.chapters ?? [];
        for (let i = chapters.length - 1; i >= 0; i--) {
          const chapter = chapters[i]!;
          const path = await this.options.sessions.sessionFile(chapter.sessionId);
          if (path && await stat(path).then(info => info.isFile(), error => { if ((error as NodeJS.ErrnoException).code === "ENOENT") return false; throw error; })) return path;
        }
        return undefined;
      },
      sessionSource: {
        read: async function* (cursor, limits) { yield* readCanonicalHomeDeltas(await source(), cursor, limits); },
        branchAtCursor: async function* (cursor, limits) { yield* readCanonicalHomeIndex(await source(), cursor, limits); },
      },
      modelSummarizer: this.options.memorySummarizer,
      isPaused: () => Boolean(this.record?.memory?.paused),
      ...(this.options.memoryDiagnostic ? { diagnostic: this.options.memoryDiagnostic } : {}),
    });
    this.memory = { sessionId: homeId, owner };
    return owner;
  }

  /** Drop the memory a record no longer owns: the session changed, or Home is
   * disabled and its session is ordinary again. */
  private async releaseMemory(): Promise<void> {
    const memory = this.memory;
    this.memory = undefined;
    await memory?.owner.dispose().catch(() => {});
  }

  /**
   * `home.designate`. An enabled record whose session still exists is idempotent,
   * but cannot change the session-owned model; callers use `session.setModel` for
   * that. A disabled record is re-enabled on the same session. A record whose
   * session is gone is kept and given a fresh session, because the record is the
   * only evidence of the designation.
   */
  async designate(input: { model?: ModelRef }, defaultModel: () => ModelRef): Promise<HomeDesignation> {
    return this.mutex.run(async () => {
      this.assertAvailable();
      const existing = this.record;
      const pendingChapter = existing?.chapters.find(chapter => chapter.state === "reserved" || chapter.state === "materializing");
      if (pendingChapter && existing?.enabled) {
        throw new GatewayError("conflict", "Tron Home has an unresolved chapter reservation; recover that chapter before designation");
      }
      const existingSessionId = existing ? homeSessionId(existing) : undefined;
      if (existing && existingSessionId && (
        (pendingChapter !== undefined && !existing.enabled)
        || await this.options.sessions.sessionPresent(existingSessionId)
      )) {
        if (existing.enabled) {
          if (input.model && (input.model.provider !== existing.model.provider || input.model.id !== existing.model.id)) {
            this.options.diagnostic?.({ outcome: "refused", reason: "model-change-requires-session-set-model" });
            throw new GatewayError("conflict", "Tron Home is already enabled with a different model; use session.setModel to change its model");
          }
          return designation(existing);
        }
        // The model is the request's, else the one the record was last
        // designated with; both were admitted before they were recorded.
        const model = input.model ?? existing.model;
        let next: HomeRecord | undefined;
        await this.commitProfileChange(existingSessionId!, current => {
          next = {
            ...current,
            enabled: true,
            generation: current.generation + 1,
            policyRevision: HOME_POLICY_REVISION,
            model: { ...model },
            updatedAt: new Date().toISOString(),
          };
          return next;
        });
        if (!next) throw new Error("Home re-enable did not commit its record");
        const nextSessionId = homeSessionId(next);
        if (this.options.sessions.hasLiveRuntime(nextSessionId)) {
          await this.options.sessions.applySessionModel(nextSessionId, model);
        }
        this.options.diagnostic?.({ outcome: "enabled" });
        return designation(next);
      }

      const cwd = await this.ensureWorkspace();
      // An explicit decision, so `requireResolved` never blocks on the neutral
      // directory and no project resource can load from it.
      await this.options.trust.set(cwd, false);
      const model = input.model ?? defaultModel();
      // A different session means the previous one is no longer Home's, so its
      // memory is released before the new session takes the designation.
      await this.releaseMemory();
      let sessionId: string;
      this.designating = true;
      try {
        sessionId = await this.options.sessions.createHomeSession(cwd);
      } finally {
        this.designating = false;
      }
      try {
        await this.options.sessions.applySessionModel(sessionId, model);
        const now = new Date().toISOString();
        const record: HomeRecord = {
          version: VERSION,
          homeId: existing?.homeId ?? randomUUID(),
          chapters: [
            ...(existing?.chapters.map(chapter => chapter.state === "active" ? { ...chapter, state: "sealed" as const, sealedAt: now } : chapter) ?? []),
            { sessionId, ordinal: (existing?.chapters.at(-1)?.ordinal ?? 0) + 1, state: "active", createdAt: now, activationStarted: false },
          ],
          bindingRevision: (existing?.bindingRevision ?? 0) + 1,
          generation: existing ? existing.generation + 1 : 1,
          routeGeneration: existing ? existing.routeGeneration + 1 : 1,
          policyRevision: HOME_POLICY_REVISION,
          enabled: true,
          model: { ...model },
          // The memory's configuration is the user's decision about *how* Home
          // remembers, so a replacement chapter keeps it and its pause decision.
          ...(existing?.memory ? { memory: { ...existing.memory, model: { ...existing.memory.model } } } : {}),
          createdAt: existing?.createdAt ?? now,
          updatedAt: now,
        };
        await this.write(record);
        this.options.diagnostic?.({ outcome: "designated" });
        return designation(record);
      } catch (error) {
        // No record names this session, so it must not keep the creation-time
        // Home profile: replace its runtime with what the record now says.
        await this.options.sessions.replaceRuntimeForProfile(sessionId, async () => {}).catch(() => {});
        throw error;
      }
    });
  }

  /** `home.disable`. The session stays an ordinary session afterwards. */
  async disable(): Promise<HomeDesignation> {
    return this.mutex.run(async () => {
      this.assertAvailable();
      const existing = this.record;
      if (!existing) throw new GatewayError("not_found", "Tron Home is not designated");
      if (!existing.enabled) return designation(existing);
      let next: HomeRecord | undefined;
      const update = (current: HomeRecord): HomeRecord => {
        next = { ...current, enabled: false, generation: current.generation + 1, updatedAt: new Date().toISOString() };
        return next;
      };
      // Registry owns both constructing and published runtimes. Catalog
      // absence is not absence of an in-flight writer/profile owner.
      await this.commitProfileChange(homeSessionId(existing), update);
      if (!next) throw new Error("Home disable did not commit its record");
      // Only once the change is committed: a refused (busy) disable must leave
      // the memory and the activation waiting in it exactly as they were.
      // Re-enabling re-opens the memory from the record and the store keeps every
      // node, so nothing is re-spent.
      await this.releaseMemory();
      this.options.diagnostic?.({ outcome: "disabled" });
      return designation(next);
    });
  }

  /**
   * The record is the single source of truth for Home's model, so a model
   * applied to the enabled Home session is recorded. A model applied to the same
   * session while it is disabled is an ordinary session's change and is not.
   */
  async noteModelApplied(sessionId: string, model: ModelRef): Promise<void> {
    await this.recordMutex.run(async () => {
      const record = this.record;
      if (!record || !record.enabled || !record.chapters.some(chapter => chapter.sessionId === sessionId && chapter.state === "active")) return;
      if (record.model.provider === model.provider && record.model.id === model.id) return;
      await this.writeLocked({ ...record, model: { ...model }, updatedAt: new Date().toISOString() });
    });
  }

  private assertAvailable(): void {
    if (!this.unavailable) return;
    this.options.diagnostic?.({ outcome: "unavailable", reason: "owner-fenced" });
    throw new GatewayError("conflict", `Tron Home is unavailable: ${this.unavailable}. The existing record was preserved.`);
  }

  /** Commit the record and rebuild the live runtime in one serialized step, so a
   * prompt cannot be admitted between the idle check, the write and the rebuild. */
  private async commitProfileChange(sessionId: string, update: (current: HomeRecord) => HomeRecord): Promise<void> {
    try {
      await this.options.sessions.replaceRuntimeForProfile(sessionId, async () => {
        await this.recordMutex.run(async () => {
          const current = this.record;
          if (!current || homeSessionId(current) !== sessionId) throw new GatewayError("conflict", "Tron Home changed during profile update");
          await this.writeLocked(update(current));
        });
      });
    } catch (error) {
      if (error instanceof GatewayError && error.code === "busy") {
        this.options.diagnostic?.({ outcome: "refused", reason: "session-busy" });
      }
      throw error;
    }
  }

  /** Create the neutral working directory owner-only, and resolve it the way
   * the trust store does so the recorded decision is the one sessions see. */
  private async ensureWorkspace(): Promise<string> {
    await mkdir(this.workspacePath, { recursive: true, mode: 0o700 });
    await chmod(this.workspacePath, 0o700);
    this.workspacePath = await this.options.trust.canonicalDirectory(this.workspacePath);
    return this.workspacePath;
  }

  private async write(record: HomeRecord): Promise<void> {
    await this.recordMutex.run(() => this.writeLocked(record));
  }

  private async writeLocked(record: HomeRecord): Promise<void> {
    this.assertAvailable();
    if (!admitRecord(record)) throw new GatewayError("conflict", "The Home record is invalid or exceeds its chapter bounds");
    try {
      await durablePublishBoundedJson(this.recordPath, record, MAXIMUM_RECORD_BYTES);
    } catch (error) {
      if (isDurablePublicationUncertain(error)) {
        // A visible replacement makes the caller's prior in-memory record
        // untrustworthy. Fence synchronous route readers before reloading.
        this.unavailable = "Home ledger publication is being reconciled";
        this.options.sessions.beginHomePublicationReconciliation();
        const reloaded = await this.load(false);
        // Do not await this here: writeLocked may be running inside a slot lane,
        // and Registry retirement queues behind that lane. Keep the owner fenced
        // until the retained retirement completes successfully.
        const retirement = Promise.resolve()
          .then(() => this.options.sessions.retireHomeRuntimes(reloaded))
          .then(() => {
            if (reloaded) this.unavailable = undefined;
          })
          .catch(error => {
            this.unavailable = "Home runtime retirement failed after ledger publication uncertainty";
            this.options.diagnostic?.({ outcome: "unavailable", reason: "publication-retirement-failed" });
            throw error;
          });
        void retirement.catch(() => {});
      }
      if (error instanceof Error && error.message === "JSON document exceeds its byte limit") {
        throw new GatewayError("conflict", "The Home chapter ledger exceeds its persisted size limit");
      }
      throw error;
    }
    this.record = record;
  }

  private async load(clearAvailability = true): Promise<boolean> {
    let loaded: unknown;
    try {
      const read = await readSecureJson<unknown>(this.recordPath, MAXIMUM_RECORD_BYTES);
      if (!read.present) {
        this.record = undefined;
        if (clearAvailability) this.unavailable = undefined;
        return true;
      }
      loaded = read.value;
    } catch (error) {
      // An empty, symlinked or permissively-readable file is not an absent one:
      // it is preserved and reported, never replaced.
      if (clearAvailability) this.record = undefined;
      this.unavailable = error instanceof SecureJsonFileError && error.kind === "invalid"
        ? "The Home record is malformed"
        : "The Home record is not a bounded owner-only regular file";
      this.options.diagnostic?.({ outcome: "unavailable", reason: "unreadable" });
      return false;
    }
    const admitted = admitRecord(loaded);
    if (!admitted) {
      if (clearAvailability) this.record = undefined;
      this.unavailable = "The Home record has an unsupported shape or version";
      this.options.diagnostic?.({ outcome: "unavailable", reason: "unsupported-record" });
      return false;
    }
    this.record = admitted;
    if (clearAvailability) this.unavailable = undefined;
    return true;
  }
}

/** The newest chapter a client may open. A reserved or materializing successor
 * has no session to open yet, so the sealed predecessor is the openable route
 * until the first logical prompt materializes the successor. */
function openableChapter(record: HomeRecord): HomeChapter | undefined {
  const current = record.chapters.at(-1);
  return current?.state === "reserved" || current?.state === "materializing" ? record.chapters.at(-2) : current;
}

function homeSessionId(record: HomeRecord): string {
  return record.chapters.find(chapter => chapter.state === "active")?.sessionId
    ?? record.chapters.at(-1)!.sessionId;
}

function designation(record: HomeRecord): HomeDesignation {
  return { homeId: record.homeId, sessionId: homeSessionId(record), generation: record.generation };
}

/** Admit one stored record, or undefined for anything this build cannot use.
 * Only the format version gates admission: a newer `policyRevision` is still a
 * record this build can read, preserve and re-enable. */
function admitRecord(value: unknown): HomeRecord | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const root = value as Record<string, unknown>;
  const model = root.model;
  if (!hasOnlyKeys(root, ["version", "homeId", "chapters", "bindingRevision", "generation", "routeGeneration", "policyRevision", "enabled", "model", "createdAt", "updatedAt", "memory"])
    || root.version !== VERSION
    || !boundedString(root.homeId, 200)
    || !Number.isSafeInteger(root.bindingRevision) || (root.bindingRevision as number) < 1
    || !Number.isSafeInteger(root.generation) || (root.generation as number) < 1
    || !Number.isSafeInteger(root.routeGeneration) || (root.routeGeneration as number) < 1
    || !Number.isSafeInteger(root.policyRevision) || (root.policyRevision as number) < 1
    || typeof root.enabled !== "boolean"
    || !boundedTimestamp(root.createdAt)
    || !boundedTimestamp(root.updatedAt)
    || !Array.isArray(root.chapters) || root.chapters.length === 0 || root.chapters.length > HOME_MAX_CHAPTERS
    || !model || typeof model !== "object" || Array.isArray(model)) return undefined;
  const modelRecord = model as Record<string, unknown>;
  if (!hasOnlyKeys(modelRecord, ["provider", "id"])
    || !boundedString(modelRecord.provider, MAXIMUM_PROVIDER_BYTES)
    || !boundedString(modelRecord.id, MAXIMUM_MODEL_ID_BYTES)) return undefined;
  const chapters = admitChapters(root.chapters);
  if (!chapters) return undefined;
  // An absent `memory` is the unconfigured state; malformed memory is preserved
  // and refused instead of silently dropping the user's projection.
  const memory = admitMemory(root.memory);
  if (memory === null) return undefined;
  return {
    version: VERSION,
    homeId: root.homeId,
    chapters,
    bindingRevision: root.bindingRevision as number,
    generation: root.generation as number,
    routeGeneration: root.routeGeneration as number,
    policyRevision: root.policyRevision as number,
    enabled: root.enabled,
    model: { provider: modelRecord.provider, id: modelRecord.id },
    createdAt: root.createdAt,
    updatedAt: root.updatedAt,
    ...(memory ? { memory } : {}),
  };
}

function admitChapters(value: unknown[]): HomeChapter[] | undefined {
  const chapters: HomeChapter[] = [];
  const sessionIds = new Set<string>();
  let activeCount = 0;
  for (let index = 0; index < value.length; index += 1) {
    const candidate = value[index];
    if (!candidate || typeof candidate !== "object" || Array.isArray(candidate)) return undefined;
    const chapter = candidate as Record<string, unknown>;
    if (typeof chapter.activationStarted !== "boolean" || !hasOnlyKeys(chapter, ["sessionId", "ordinal", "state", "createdAt", "activationStarted", "sealedAt", "sizeAtSeal", "entriesAtSeal", "attemptId", "expectedPath"])
      || !boundedString(chapter.sessionId, 200)
      || sessionIds.has(chapter.sessionId)
      || chapter.ordinal !== index + 1
      || !["active", "sealed", "reserved", "materializing"].includes(String(chapter.state))
      || !boundedTimestamp(chapter.createdAt)) return undefined;
    const state = chapter.state as HomeChapter["state"];
    if (state === "active") activeCount += 1;
    if (state === "sealed" && !boundedTimestamp(chapter.sealedAt)) return undefined;
    if (chapter.sealedAt !== undefined && !boundedTimestamp(chapter.sealedAt)) return undefined;
    for (const field of ["sizeAtSeal", "entriesAtSeal"] as const) {
      const amount = chapter[field];
      if (amount !== undefined && (typeof amount !== "number" || !Number.isSafeInteger(amount) || amount < 0)) return undefined;
    }
    if (state === "materializing" && !boundedString(chapter.attemptId, 200)) return undefined;
    if (chapter.attemptId !== undefined && !boundedString(chapter.attemptId, 200)) return undefined;
    if (chapter.expectedPath !== undefined && !boundedString(chapter.expectedPath, 4_096)) return undefined;
    if (state !== "sealed" && (chapter.sealedAt !== undefined || chapter.sizeAtSeal !== undefined || chapter.entriesAtSeal !== undefined)) return undefined;
    if (state !== "materializing" && (chapter.attemptId !== undefined || chapter.expectedPath !== undefined)) return undefined;
    sessionIds.add(chapter.sessionId);
    chapters.push({
      sessionId: chapter.sessionId, ordinal: chapter.ordinal as number, state,
      createdAt: chapter.createdAt as string, activationStarted: chapter.activationStarted as boolean,
      ...(chapter.sealedAt === undefined ? {} : { sealedAt: chapter.sealedAt as string }),
      ...(chapter.sizeAtSeal === undefined ? {} : { sizeAtSeal: chapter.sizeAtSeal as number }),
      ...(chapter.entriesAtSeal === undefined ? {} : { entriesAtSeal: chapter.entriesAtSeal as number }),
      ...(chapter.attemptId === undefined ? {} : { attemptId: chapter.attemptId as string }),
      ...(chapter.expectedPath === undefined ? {} : { expectedPath: chapter.expectedPath as string }),
    });
  }
  if (activeCount > 1) return undefined;
  const materializing = chapters.filter(chapter => chapter.state === "materializing");
  const reserved = chapters.filter(chapter => chapter.state === "reserved");
  if (materializing.length > 1 || reserved.length > 1 || (materializing.length > 0 && reserved.length > 0)) return undefined;
  if (activeCount === 1 && chapters.at(-1)?.state !== "active") return undefined;
  if (activeCount === 0 && chapters.at(-1)?.state !== "reserved" && chapters.at(-1)?.state !== "materializing") return undefined;
  if (chapters.slice(0, -1).some(chapter => chapter.state !== "sealed")) return undefined;
  return chapters;
}

function hasOnlyKeys(record: Record<string, unknown>, keys: readonly string[]): boolean {
  return Object.keys(record).every(key => keys.includes(key));
}

/** `undefined` for an absent field, the admitted value for a valid one, and
 * `null` for a field this build cannot use. */
function admitMemory(value: unknown): HomeRecord["memory"] | null {
  if (value === undefined) return undefined;
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const record = value as Record<string, unknown>;
  const model = record.model;
  if (!hasOnlyKeys(record, ["model", "paused"]) || (record.paused !== undefined && record.paused !== true) || !model || typeof model !== "object" || Array.isArray(model)) return null;
  const modelRecord = model as Record<string, unknown>;
  if (!hasOnlyKeys(modelRecord, ["provider", "id"])
    || !boundedString(modelRecord.provider, MAXIMUM_PROVIDER_BYTES)
    || !boundedString(modelRecord.id, MAXIMUM_MODEL_ID_BYTES)) return null;
  return { model: { provider: modelRecord.provider, id: modelRecord.id }, ...(record.paused === true ? { paused: true } : {}) };
}
