import type { QueueModelState } from "../providers/model-queue-extension.js";
import { createHash, randomUUID } from "node:crypto";
import type { ImageContent } from "@earendil-works/pi-ai";
import { clampThinkingLevel } from "@earendil-works/pi-ai";
import type { FileEntry } from "@earendil-works/pi-coding-agent";
import type { GatewayWorkHandle } from "../sessions/gateway-work-registry.js";
import type { RuntimeRegistry } from "../sessions/runtime-registry.js";
import { TASK_STOP_WAITING, type OwnedOperationTerminal } from "../sessions/runtime-slot.js";
import { OwnedSessionDispatch, type OwnedOperationDeadline } from "../sessions/owned-session-dispatch.js";
import { INVOCATION_RECEIPT_TYPE, parseInvocationReceipt } from "../sessions/invocation-receipts.js";
import { GatewayError } from "../errors.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { HomeTaskAuthorization, HomeTaskAuthorizationError, type HomeTaskAuthorizationDiagnostic } from "./home-task-authorization.js";
import { HomeTaskStore, HomeTaskStoreError, taskIntentDigest, type HomeTaskRecord, type HomeTaskStoreDiagnostic, type HomeTaskStoreCode } from "./home-task-store.js";
import { homeTaskSpend } from "./home-task-spend.js";
import type { WakeInboxOwner, HomeWakeDiagnostic } from "./home-wake-inbox.js";
import { HOME_TASK_ATTENTION_INTERVAL_MS, HOME_TASK_CHECKIN_LIMIT, HOME_TASK_CHECKIN_VISIBLE, type HomeTaskCheckin } from "./home-task-checkin.js";
import { HOME_TASK_MARKER, HOME_TASK_REPORT, HomeTaskReportOwner, homeTaskOperationSpan, parseHomeTaskReport, type HomeTaskReport } from "./home-task-report.js";
import type { HomeTaskWorkerChoice } from "./home-task-worker-choice.js";
import type { FixedSetting } from "../admin/settings-resolver.js";
import { HOME_TASK_SUBAGENTS, HOME_TASK_STATUS_RUN_LIMIT, homeTaskSubagentLaunches, homeTaskSubagentsProjection, parseHomeTaskSubagentsEntry, type HomeTaskSubagentRuns, type HomeTaskSubagents } from "./home-task-subagents.js";
import type { HomeTaskCounts, HomeTaskDisplay, HomeTaskPage, HomeTaskSummary } from "../protocol/types.js";
import { basename } from "node:path";
import { TRON_ASK_USER_INTERRUPTED } from "../extensions/tron-ask-user-contract.js";
import { abortableRead } from "../util/abortable-read.js";
import { HostPressure, type HostPressureDiagnostic } from "./host-pressure.js";

/** One shared home.taskList store pass and the readers waiting on it. */
interface ListFlight { result: Promise<HomeTaskPage>; readers: number; controller: AbortController }

export type HomeTaskDiagnostic =
  | HomeTaskAuthorizationDiagnostic
  | HomeTaskStoreDiagnostic
  | HomeWakeDiagnostic
  | { event: "home.task.producer-refused"; taskHash: string; reason: import("./home-task-worker-extension.js").HomeTaskProducerRefusal }
  | { event: "home.task.detached-work"; taskHash: string; operationHash: string; reason: "detached-work-outlived-task" }
  | { event: "home.task.subagents"; taskHash: string; operationHash: string; started: number; stoppedAtEnd: number | null; noticesUndelivered: number }
  | { event: "home.task.transition"; taskHash: string; revision: number; transition: HomeTaskRecord["lifecycle"]; reason: string; operationHash: string | null; errorCode?: string }
  | { event: "home.task.checkin"; taskHash: string; operationHash: string; revision: number; attention: HomeTaskCheckin["attention"] }
  | { event: "home.task.spend"; taskHash: string; spendReference: string; inputTokens: number; outputTokens: number }
  | { event: "home.task.control"; taskHash: string; operationHash: string; action: "steer" | "stop"; disposition: "accepted" | "persisted" }
  | { event: "home.inbox.admission-slow"; delivery: "user" | "wake"; durationMs: number }
  | { event: "home.task.dispatch-stage"; taskHash: string; stage: HomeTaskDispatchStage; outcome: "slow" | "timeout" | "cancelled"; durationMs: number }
  | HostPressureDiagnostic
  | { event: "home.task.runaway-stop"; taskHash: string; operationHash: string; elapsedMs: number; cancelAndJoin: "joined" | "failed"; spendReference: string };
export type HomeTaskRecoveryStatus = { available: true } | { available: false; reason: HomeTaskStoreCode | "not-started" };
/** `title` names the worker session; it is never persisted with the task record. */
export interface HomeTaskDispatchRequest extends HomeTaskWorkerChoice {
  taskId: string; intent: string; target: string; title?: string; reason?: string;
  /** Internal Home boundary metadata, never accepted by the delegate tool schema. */
  provenance?: { model: Pick<FixedSetting, "via" | "reason">; thinking: Pick<FixedSetting, "via" | "reason"> };
}
/** The durable record plus the worker's model from its own transcript. The model is
 * projected per read, never persisted with the task. */
export interface HomeTaskOwnerSettlement {
  taskId: string; sessionId: string; operationId: string;
  markerEntryId: string; terminalEntryId: string; settlementEntryId: string; stoppedAtEnd: number;
}
export type HomeTaskStatus = HomeTaskRecord & HomeTaskDisplay & { workerModel: { provider: string; id: string } | null; subagents: HomeTaskSubagents; subagentRuns: HomeTaskSubagentRuns; ownerSettlement: HomeTaskOwnerSettlement | null };
export interface HomeTaskControlRequest { taskId: string; operationId: string }
/** A task as Home's `task` tool lists it: enough to choose and send the next control. */
export interface HomeTaskControlRow {
  taskId: string;
  title: string;
  state: "starting" | "running" | "settled";
  outcome: string | null;
  reason?: string;
  detail?: string;
  sessionId: string | null;
  operationId: string | null;
  resumes?: string;
  continuedAs?: string;
  updatedAt: string;
  checkins: HomeTaskCheckin[];
  actions: Array<"status" | "report" | "steer" | "stop" | "resume">;
}

/** Levenshtein distance, for suggesting a task ID close to a mistyped one. */
function editDistance(a: string, b: string): number {
  let previous = Array.from({ length: b.length + 1 }, (_, index) => index);
  for (let i = 1; i <= a.length; i += 1) {
    const current = [i];
    for (let j = 1; j <= b.length; j += 1) current[j] = Math.min(previous[j]! + 1, current[j - 1]! + 1, previous[j - 1]! + (a[i - 1] === b[j - 1] ? 0 : 1));
    previous = current;
  }
  return previous[b.length]!;
}
/** Resume a settled task in place: `taskId`/`operationId` name the stopped task's exact operation. */
export interface HomeTaskResumeRequest extends HomeTaskControlRequest { text?: string }

/** The one successor of a task: `<base>.resume-<n+1>` for `<base>.resume-<n>`, else `<id>.resume-1`. */
export function successorTaskId(taskId: string): string {
  const match = /^(.*)\.resume-([1-9][0-9]{0,5})$/u.exec(taskId);
  const next = match ? `${match[1]}.resume-${Number(match[2]) + 1}` : `${taskId}.resume-1`;
  if (next.length > 160) throw new GatewayError("conflict", "Task lineage is too long to resume again");
  return next;
}

interface InterruptedQuestion { title: string; questions: unknown[] }
/** The newest question the operation was stopped before it was answered, from the
 * ask_user tool's own canonical record (it covers questions asked inside codemode). */
function interruptedQuestion(run: readonly FileEntry[]): InterruptedQuestion | undefined {
  const entry = run.findLast(candidate => candidate.type === "custom" && candidate.customType === TRON_ASK_USER_INTERRUPTED);
  const data = entry?.type === "custom" ? entry.data as { title?: unknown; questions?: unknown } : undefined;
  return data && typeof data.title === "string" && Array.isArray(data.questions) && data.questions.length > 0
    ? { title: data.title, questions: data.questions } : undefined;
}

/** The resumed operation's brief. The authorized intent is this exact text. `instructions` are
 * oldest first: those of earlier resumes refused before they started (#959), then this one's. */
function resumeBrief(previous: HomeTaskRecord, instructions: readonly string[], pending: InterruptedQuestion | undefined): string {
  const parts = [`Continue Home task ${previous.taskId} in place. It stopped (${previous.terminalEvidence?.outcome ?? "unknown"}: ${previous.terminalEvidence?.reason ?? "unknown"}); this is the same worker session, so its worktree, branch and work claim are still yours. Pick up exactly where it stopped: re-check the state you were in before acting.`];
  if (instructions.length === 1) parts.push(`Instruction:\n${instructions[0]}`);
  else if (instructions.length > 1) parts.push(`Instructions, oldest first (the earlier ones never reached you because a previous resume was refused):\n\n${instructions.join("\n\n---\n\n")}`);
  if (pending) {
    let question = JSON.stringify({ title: pending.title, questions: pending.questions }, null, 2);
    if (Buffer.byteLength(question) > 24 * 1024) question = `${question.slice(0, 24 * 1024)}\n(truncated)`;
    parts.push(`Your last ask_user question was interrupted before it was answered. Unless the instruction above already answers it, ask it again with ask_user, unchanged, before you continue:\n${question}`);
  }
  return parts.join("\n\n");
}
/** A started task names its worker and operation. */
export interface HomeTaskHandle { taskId: string; sessionId: string; operationId: string; completion: Promise<HomeTaskRecord>;
  /** The worker choice the delegate boundary resolved, as the brief states it; the `delegate` tool's details carry it. */
  worker?: HomeTaskWorkerSummary;
  /** The subagent queue's availability at delegation, in fallback order. */
  subagentModels?: readonly QueueModelState[] }
/** A delegation's resolved worker: display references and where each value came from,
 * with the worker queue's availability when the worker came from it. */
export interface HomeTaskWorkerSummary { model: string; thinking: string; modelSource: string; thinkingSource: string; note?: string;
  queue?: readonly QueueModelState[] }
interface HomeTaskLaunch {
  task: HomeTaskRecord; authority: Awaited<ReturnType<HomeTaskAuthorization["authorize"]>>;
  input: HomeTaskDispatchRequest; title: string | undefined;
  choice: Awaited<ReturnType<RuntimeRegistry["admitTaskWorkerChoice"]>>; deferredThinking: HomeTaskDispatchRequest["thinking"];
  /** A settled task continued in place (#929): its predecessor's worker session is rebound, not
   * created or configured, and the maintainer's attachments go with the first prompt. */
  resume?: { sessionId: string; images: ImageContent[]; exceptWorkToken?: string };
  /** The worker operation a resume fixes before its worker starts. */
  operationId?: string;
}
const reportDigest = (value: unknown) => createHash("sha256").update(JSON.stringify(value)).digest("hex");
const hash = (value: string) => createHash("sha256").update(value).digest("hex").slice(0, 16);
/** Every awaited step of delegate admission, in order (#919). Each is bounded by
 * the stage deadline and the delegating turn's Stop, and logs when slow. */
export type HomeTaskDispatchStage = "choice" | "setup" | "lookup" | "budget" | "target" | "create"
  | "authorize" | "restore-epoch" | "create-worker" | "configure-worker" | "bind";
/** No single admission step may hold the delegating Home turn longer than this. */
export const HOME_TASK_DISPATCH_STAGE_DEADLINE_MS = 60_000;
/** A step slower than this is logged with its stage even when it completes. */
export const HOME_TASK_DISPATCH_STAGE_SLOW_MS = 5_000;

/** A dispatch step the delegating turn stopped or the stage deadline expired. The
 * step itself may still be running; its owner hands any late result back. */
class HomeTaskDispatchStageError extends GatewayError {
  constructor(readonly stage: HomeTaskDispatchStage, readonly outcome: "timeout" | "cancelled") {
    super(outcome === "timeout" ? "busy" : "cancelled", outcome === "timeout"
      ? `Task dispatch step ${stage} did not finish in time` : `Task dispatch was stopped at ${stage}`, outcome === "timeout", { stage });
  }
}

/** The longest refusal message a task's terminal evidence keeps. */
export const HOME_TASK_REFUSAL_DETAIL_CHARACTERS = 500;

/** The longest name a task or its worker session is shown by. */
export const HOME_TASK_TITLE_CHARACTERS = 80;

/** The name a task is shown by: the worker session's name when it has one, else the brief's first non-empty line. */
export function homeTaskTitle(brief: string, workerName: string | undefined): string {
  const name = workerName?.trim();
  const line = name || brief.split("\n").map(candidate => candidate.trim()).find(candidate => candidate.length > 0) || "";
  return [...line].slice(0, HOME_TASK_TITLE_CHARACTERS).join("");
}

/** Installation capability owner. Each dispatch closure, not a parallel ID map,
 * owns its lease, cancellation signal, terminal promise and report lifetime. */
export class HomeTaskDispatcher {
  private readonly listFlights = new Map<string, ListFlight>();
  /** Tasks launching or running, until they settle. There is no running cap (#1023):
   * workers never wait; the memory-heavy steps they run wait in the host heavy queue
   * (docs/host-load.md). */
  private readonly running = new Set<string>();
  private readonly pressure: HostPressure;
  private readonly setup = new AsyncMutex();
  private recovery: Promise<HomeTaskRecoveryStatus> | undefined;
  constructor(readonly store: HomeTaskStore, readonly authorization: HomeTaskAuthorization,
    private readonly sessions: RuntimeRegistry, private readonly diagnostic: ((record: HomeTaskDiagnostic) => void) | undefined,
    private readonly inbox: WakeInboxOwner) {
    this.pressure = new HostPressure(record => this.diagnostic?.(record));
  }

  /** Only startup calls this, before live dispatch closures can exist. The
   * durable record outlives a process; its executable lease never does. */
  recover(): Promise<HomeTaskRecoveryStatus> {
    return this.recovery ??= this.recoverOwned().then(() => ({ available: true as const }), error => {
      const reason = error instanceof HomeTaskStoreError ? error.code : "unsafe-state";
      // Store errors already emitted their single owning diagnostic. Refusal
      // is a process-lifetime result, not a retry or an unrelated Gateway stop.
      if (!(error instanceof HomeTaskStoreError)) this.diagnostic?.({ event: "home.task.store-refused", reason });
      return { available: false as const, reason };
    });
  }

  recoveryStatus(): Promise<HomeTaskRecoveryStatus> {
    return this.recovery ?? Promise.resolve({ available: false, reason: "not-started" });
  }

  async assertAvailable(): Promise<void> {
    const result = await this.recoveryStatus();
    if (!result.available) throw new GatewayError("conflict", "Home task recovery is unavailable", false, { reason: result.reason });
  }

  private async recoverOwned(): Promise<void> {
    await this.store.removeAbandonedTemporaries();
    // The recovery pass already reads every record; it seeds the catalog's
    // worker index in one batch rather than a second ledger scan.
    // A worker is named by the task that created it, as live binding records it
    // (first wins): a resumed task's successor rebinds the same session, so the
    // ledger's order must not let a successor name it after a restart.
    const workers: Array<[string, string]> = [];
    const successors: Array<[string, string]> = [];
    try {
      for await (const task of this.store.records()) {
        if (task.sessionId) (task.resumes ? successors : workers).push([task.sessionId, task.taskId]);
        await this.recoverTask(task);
      }
    } finally {
      if (workers.length + successors.length > 0) this.sessions.recordTaskWorkers([...workers, ...successors]);
    }
  }

  private async recoverTask(task: HomeTaskRecord): Promise<void> {
    if (task.lifecycle === "terminal" && task.wake?.push !== "pending") return;
    if (task.lifecycle !== "terminal") return void await this.reconcile(task, "cold");
    // Includes a crash after terminal/outbox co-commit but before advisory
    // publication. The inbox's durable decision makes repeats harmless.
    await this.inbox.publish(task.taskId);
  }

  /** Settles a non-terminal task from its canonical file alone, with no runtime to stop or
   * replay through: at startup for every abandoned record (`cold`), and in process when a
   * worker's live settlement failed or Stop finds a task no launch owns (`live`, #1166). A
   * durable Stop intent with no report settles `interrupted`. */
  private async reconcile(task: HomeTaskRecord, origin: "cold" | "live", detail?: string): Promise<HomeTaskRecord> {
    const reasons = origin === "cold"
      ? { report: "cold-explicit-report", none: "cold-no-report", unavailable: "cold-evidence-unavailable" }
      : { report: "explicit-report", none: "settlement-failed", unavailable: "evidence-unavailable" };
    let report: HomeTaskReport | undefined;
    let entryId: string | undefined;
    let spend = task.spend;
    let entryIds: string[] = [];
    let reason = reasons.none;
    let evidenceRead = false;
    // No runtime exists here to stop an async run, so a run whose status cannot be
    // proven terminal makes the task unknown, even with a valid report.
    let detached = false;
    if (task.lifecycle === "active" && task.sessionId && task.operationId) {
      try {
        const entries = await this.sessions.readTaskEvidence(task.sessionId);
        const evidence = await this.reportEvidence(task, entries);
        report = evidence?.report; entryId = evidence?.entryId;
        const runEntries = homeTaskOperationSpan(entries, task.operationId).run;
        const observed = homeTaskSpend(runEntries);
        if (spend && (observed.inputTokens < spend.inputTokens || observed.outputTokens < spend.outputTokens)) throw new Error("Canonical spend regressed");
        spend = observed;
        const last = runEntries.findLast(entry => entry.type === "message" && entry.message.role === "assistant");
        entryIds = entryId ? [entryId] : last ? [last.id] : [];
        if (report) reason = reasons.report;
        const asyncDirs = homeTaskSubagentLaunches(runEntries).flatMap(launch => launch.asyncDir ? [launch.asyncDir] : []);
        // A malformed settlement fact refuses this evidence rather than being guessed.
        homeTaskSubagentsProjection(entries, task.operationId);
        detached = !await this.sessions.taskSubagentRunsSettled(asyncDirs);
        if (detached) this.diagnostic?.({ event: "home.task.detached-work", taskHash: hash(task.taskId), operationHash: hash(task.operationId), reason: "detached-work-outlived-task" });
        evidenceRead = true;
      } catch (error) {
        // Namespace refusal is not missing report evidence: retire this
        // process's capability instead of attempting a terminal write.
        if (error instanceof HomeTaskStoreError) throw error;
        // Contradictory or unproven bytes cannot qualify a result. Retain
        // already published spend/authority; never repair or replay work.
        report = undefined; entryId = undefined; entryIds = []; reason = reasons.unavailable;
      }
    }
    const final = await this.store.update(task.taskId, current => {
      if (current.lifecycle === "terminal" || current.operationId !== task.operationId) throw new GatewayError("conflict", "Task settled or changed during reconciliation");
      // A Stop intent is the maintainer's durable decision and the worker provably runs no more.
      const stopped = evidenceRead && !report && !detached && current.stopIntent !== null;
      const settledReason = detached ? "detached-work-outlived-task" : stopped ? "task-stop" : reason;
      return { ...current, lifecycle: "terminal", spend, wake: this.inbox.event(current),
        reportRef: report && entryId ? { resultId: report.resultId, sessionId: task.sessionId!, entryId, digest: reportDigest(report) } : null,
        terminalEvidence: { outcome: detached ? "unknown" : stopped ? "interrupted" : report?.outcome ?? "unknown", sessionId: task.sessionId, entryIds,
          reason: settledReason, ...(detail ? { detail: [...detail].slice(0, HOME_TASK_REFUSAL_DETAIL_CHARACTERS).join("") } : {}) } };
    });
    this.transition(final, final.terminalEvidence!.reason);
    await this.inbox.publish(task.taskId);
    return final;
  }

  private async reportEvidence(task: HomeTaskRecord, entries: readonly FileEntry[]): Promise<{ report: HomeTaskReport; entryId: string } | undefined> {
    // A resumed task shares its predecessor's session: each operation owns exactly one marker and at most one report.
    const ofOperation = (entry: FileEntry) => entry.type === "custom" && (entry.data as { operationId?: unknown } | null)?.operationId === task.operationId;
    const markers = entries.filter(entry => entry.type === "custom" && entry.customType === HOME_TASK_MARKER && ofOperation(entry));
    if (markers.length !== 1 || markers[0]?.type !== "custom" || !task.sessionId) throw new GatewayError("conflict", "Task marker is missing or contradictory");
    await this.validateMarkerEvidence(task.sessionId, markers[0].data);
    const reports = entries.filter(entry => entry.type === "custom" && entry.customType === HOME_TASK_REPORT && ofOperation(entry));
    if (reports.length > 1) throw new GatewayError("conflict", "Conflicting canonical task reports");
    const entry = reports[0];
    if (!entry || entry.type !== "custom") return undefined;
    const report = parseHomeTaskReport(entry.data);
    if (entries.indexOf(entry) <= entries.indexOf(markers[0]) || report.taskId !== task.taskId
      || report.homeId !== task.homeId || report.generation !== task.generation || report.operationId !== task.operationId || report.sessionId !== task.sessionId) throw new GatewayError("conflict", "Task report reference is contradictory");
    return { report, entryId: entry.id };
  }

  /** `signal` is the delegating turn's Stop. Admission never outlives it: a stopped
   * or expired step refuses the dispatch and settles any task record it created. */
  async start(identity: { homeId: string; generation: number; routeGeneration: number }, request: HomeTaskDispatchRequest, signal?: AbortSignal): Promise<HomeTaskHandle> {
    if (signal?.aborted) throw new HomeTaskDispatchStageError("choice", "cancelled");
    await this.assertAvailable();
    const registry = this.sessions.administrativeWorkRegistry;
    const work = registry.begin({ kind: "queued-mutation", hostEpoch: registry.runtimeEpoch });
    // From here startOwned owns `work`; the task settles it when it settles.
    try { return await this.startOwned(identity, request, work, signal); }
    catch (error) { work.settle(); throw error; }
  }

  /** Runs one admission step under the stage deadline and the turn's Stop. The step
   * cannot be interrupted (a stalled store or session lane ignores signals), so on
   * refusal its late result goes to `abandon`, never back into this admission. */
  private async stage<T>(stage: HomeTaskDispatchStage, taskId: string, signal: AbortSignal | undefined,
    run: () => Promise<T>, abandon?: (value: T) => unknown): Promise<T> {
    if (signal?.aborted) throw this.stageRefused(stage, taskId, "cancelled", 0);
    const started = Date.now();
    const step = run();
    let timer: NodeJS.Timeout | undefined;
    let stop: (() => void) | undefined;
    const refused = new Promise<never>((_resolve, reject) => {
      timer = setTimeout(() => reject(this.stageRefused(stage, taskId, "timeout", Date.now() - started)), HOME_TASK_DISPATCH_STAGE_DEADLINE_MS);
      stop = () => reject(this.stageRefused(stage, taskId, "cancelled", Date.now() - started));
      signal?.addEventListener("abort", stop, { once: true });
    });
    try {
      const value = await Promise.race([step, refused]);
      const durationMs = Date.now() - started;
      if (durationMs >= HOME_TASK_DISPATCH_STAGE_SLOW_MS) {
        this.diagnostic?.({ event: "home.task.dispatch-stage", taskHash: hash(taskId), stage, outcome: "slow", durationMs });
      }
      return value;
    } catch (error) {
      if (error instanceof HomeTaskDispatchStageError) void step.then(value => abandon?.(value), () => {});
      throw error;
    } finally {
      clearTimeout(timer);
      if (stop) signal?.removeEventListener("abort", stop);
    }
  }

  private stageRefused(stage: HomeTaskDispatchStage, taskId: string, outcome: "timeout" | "cancelled", durationMs: number) {
    this.diagnostic?.({ event: "home.task.dispatch-stage", taskHash: hash(taskId), stage, outcome, durationMs });
    return new HomeTaskDispatchStageError(stage, outcome);
  }

  /** Settles a task whose admission was refused after its record exists, like
   * every terminal task with its one result wake. Accepted identity stays durable
   * and is never replayed. */
  private async refuseAdmission(task: HomeTaskRecord, reason: "admission-cancelled" | "admission-timeout"): Promise<void> {
    const final = await this.store.update(task.taskId, current => current.lifecycle === "terminal" ? current : {
      ...current, lifecycle: "terminal", wake: this.inbox.event(current),
      terminalEvidence: { outcome: "unknown", sessionId: current.sessionId, entryIds: [], reason } });
    this.transition(final, reason);
    await this.inbox.publish(final.taskId);
  }

  /** Continues a settled task in place (#929): a successor task bound to the same worker
   * session, so its worktree and work claim stay with it. The stopped task's record stays
   * immutable; each task has at most one started successor, so a lineage never forks. A
   * successor refused before it started is not one (#959): the stopped task stays resumable
   * and the refused successor's instruction is carried into the next resume's brief. `text`
   * is the maintainer's or Home's instruction; the brief restates any question the run was
   * stopped before it was answered. A resume admits like any task and starts at once. */
  async resume(identity: { homeId: string; generation: number; routeGeneration: number }, request: HomeTaskResumeRequest,
    options: { signal?: AbortSignal; exceptWorkToken?: string; images?: ImageContent[] } = {}): Promise<HomeTaskHandle & { operationId: string }> {
    const { signal } = options;
    if (signal?.aborted) throw new HomeTaskDispatchStageError("choice", "cancelled");
    await this.assertAvailable();
    const registry = this.sessions.administrativeWorkRegistry;
    const work = registry.begin({ kind: "queued-mutation", hostEpoch: registry.runtimeEpoch });
    // From here resumeOwned owns `work`, as startOwned does.
    try { return await this.resumeOwned(identity, request, work, options); }
    catch (error) { work.settle(); throw error; }
  }

  private async resumeOwned(identity: { homeId: string; generation: number; routeGeneration: number }, request: HomeTaskResumeRequest, work: GatewayWorkHandle,
    options: { signal?: AbortSignal; exceptWorkToken?: string; images?: ImageContent[] }): Promise<HomeTaskHandle & { operationId: string }> {
    const { signal } = options;
    const text = request.text?.trim();
    if (typeof request.taskId !== "string" || typeof request.operationId !== "string"
      || (request.text !== undefined && (typeof request.text !== "string" || Buffer.byteLength(request.text) > 32768))) throw new GatewayError("invalid_request", "Invalid task resume");
    const previous = await this.store.read(request.taskId).catch(error => {
      if (error instanceof HomeTaskStoreError && error.code === "not-initialized") return undefined;
      throw error;
    });
    if (!previous) throw new GatewayError("not_found", "No task with this id");
    if (previous.homeId !== identity.homeId) throw new GatewayError("conflict", "Home task identity changed");
    if (previous.lifecycle !== "terminal" || previous.operationId !== request.operationId || !previous.sessionId)
      throw new GatewayError("conflict", "Only a settled task with a worker session can be resumed in place");
    const sessionId = previous.sessionId;
    // Successors refused or settled before they started never bound the session (#959): they
    // are skipped, and the instructions they carried are delivered with this one.
    const carried: string[] = [];
    let taskId = successorTaskId(previous.taskId);
    for (;;) {
      const existing = await this.stage("lookup", taskId, signal, () => this.store.read(taskId));
      if (!existing) break;
      if (existing.lifecycle !== "terminal" || existing.operationId !== null || existing.resumes?.taskId !== previous.taskId) {
        throw new GatewayError("conflict", `Task was already resumed as ${taskId}`);
      }
      if (existing.resumes.instruction) carried.push(existing.resumes.instruction);
      taskId = successorTaskId(taskId);
    }
    const instructions = [...carried, ...(text ? [text] : [])];
    const epoch = await this.stage("setup", taskId, signal, () => this.store.restoreEpoch());
    const budget = await this.stage("budget", taskId, signal, () => this.sessions.homeTaskBudget());
    const entries = await this.sessions.readTaskEvidence(sessionId);
    const brief = resumeBrief(previous, instructions, interruptedQuestion(homeTaskOperationSpan(entries, previous.operationId!).run));
    const task = await this.stage("create", taskId, signal, () => this.store.put({
      version: 1, taskId, revision: 1, homeId: identity.homeId, generation: identity.generation, routeGeneration: identity.routeGeneration, wake: null,
      intent: { text: brief }, intentDigest: taskIntentDigest(brief), target: previous.target,
      grantRef: null, scopeRef: null, lifecycle: "pending", sessionId: null, operationId: null,
      stopIntent: null, spend: null, reportRef: null, terminalEvidence: null,
      ...(previous.checkins ? { checkins: previous.checkins } : {}),
      ...(previous.lastAttentionAt ? { lastAttentionAt: previous.lastAttentionAt } : {}),
      resumes: { taskId: previous.taskId, operationId: previous.operationId!, ...(text ? { instruction: text } : {}) },
      ...(budget && Object.keys(budget).length ? { budget } : {}),
    }, null), created => { this.transition(created, "created"); void this.refuseAdmission(created, "admission-cancelled").catch(() => {}); });
    this.transition(task, "created");
    let authority: Awaited<ReturnType<HomeTaskAuthorization["authorize"]>>;
    try {
      authority = await this.stage("authorize", taskId, signal, () => this.authorization.authorize({ intentDigest: task.intentDigest,
        target: task.target, authorizationScope: "full-work", restoreEpoch: epoch }));
      if (epoch !== await this.stage("restore-epoch", taskId, signal, () => this.store.restoreEpoch())) throw new GatewayError("conflict", "Task namespace identity changed during admission");
    } catch (error) { await this.admissionFailed(task, error); throw error; }
    const operationId = `task-${randomUUID()}`;
    const handle = await this.admit({ task, authority, input: { taskId, intent: brief, target: task.target }, title: undefined, choice: {}, deferredThinking: undefined,
      resume: { sessionId, images: options.images ?? [], ...(options.exceptWorkToken ? { exceptWorkToken: options.exceptWorkToken } : {}) }, operationId }, work, signal);
    return { ...handle, sessionId, operationId };
  }

  private async startOwned(identity: { homeId: string; generation: number; routeGeneration: number }, request: HomeTaskDispatchRequest, work: GatewayWorkHandle, signal: AbortSignal | undefined): Promise<HomeTaskHandle> {
    const input = structuredClone(request);
    const keys = Object.keys(input);
    if (!["taskId", "intent", "target"].every(key => keys.includes(key)) || keys.some(key => !["taskId", "intent", "target", "model", "thinking", "title", "reason", "provenance"].includes(key))
      || typeof input.taskId !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$/u.test(input.taskId)
      || typeof input.intent !== "string" || !input.intent.trim() || Buffer.byteLength(input.intent) > 65536) throw new GatewayError("invalid_request", "Invalid task intent");
    const title = typeof input.title === "string" ? input.title.trim() : undefined;
    if (input.title !== undefined && (!title || [...title].length > HOME_TASK_TITLE_CHARACTERS)) throw new GatewayError("invalid_request", "Invalid task title");
    // Refused before any task record, namespace initialization or worker exists.
    const deferredThinking = input.provenance && !input.model ? input.thinking : undefined;
    const taskId = input.taskId;
    const choice = await this.stage("choice", taskId, signal, () => this.sessions.admitTaskWorkerChoice(deferredThinking === undefined ? input : {}));
    const epoch = await this.stage("setup", taskId, signal, () => this.setup.run(async () => {
      const created = await this.store.initialize();
      const current = await this.store.restoreEpoch();
      if (created) await this.authorization.enableInitialScope(current);
      return current;
    }));
    if (await this.stage("lookup", taskId, signal, () => this.store.read(taskId))) throw new GatewayError("conflict", "Task already exists; accepted work is never replayed");
    // The Home profile's task budget, fixed at the task's start (settings-model.md 6.1):
    // a later raise never reaches this task; a later lower applies at its next turn.
    const budget = await this.stage("budget", taskId, signal, () => this.sessions.homeTaskBudget());
    const target = await this.stage("target", taskId, signal, () => this.sessions.canonicalTaskTarget(input.target));
    // A record published after its admission was refused is settled, never left pending.
    let task = await this.stage("create", taskId, signal, () => this.store.put({
      version: 1, taskId, revision: 1, homeId: identity.homeId, generation: identity.generation, routeGeneration: identity.routeGeneration, wake: null,
      intent: { text: input.intent }, intentDigest: taskIntentDigest(input.intent), target,
      grantRef: null, scopeRef: null, lifecycle: "pending", sessionId: null, operationId: null,
      stopIntent: null, spend: null, reportRef: null, terminalEvidence: null,
      ...(budget && Object.keys(budget).length ? { budget } : {}),
    }, null), created => { this.transition(created, "created"); void this.refuseAdmission(created, "admission-cancelled").catch(() => {}); });
    this.transition(task, "created");
    let authority: Awaited<ReturnType<HomeTaskAuthorization["authorize"]>>;
    try {
      authority = await this.stage("authorize", taskId, signal, () => this.authorization.authorize({ intentDigest: task.intentDigest,
        target: task.target, authorizationScope: "full-work", restoreEpoch: epoch }));
      if (epoch !== await this.stage("restore-epoch", taskId, signal, () => this.store.restoreEpoch())) throw new GatewayError("conflict", "Task namespace identity changed during admission");
    } catch (error) { await this.admissionFailed(task, error); throw error; }
    return this.admit({ task, authority, input, title, choice, deferredThinking }, work, signal);
  }

  /** Starts an authorized task's worker at once, a resume too (#959). */
  private async admit(launch: HomeTaskLaunch, work: GatewayWorkHandle, signal: AbortSignal | undefined): Promise<HomeTaskHandle> {
    this.running.add(launch.task.taskId);
    return this.launch(launch, work, signal);
  }

  /** Starts an authorized task's worker. It counts as running until the task
   * settles or its launch fails. */
  private async launch(launch: HomeTaskLaunch, work: GatewayWorkHandle, signal: AbortSignal | undefined): Promise<HomeTaskHandle> {
    let { task } = launch;
    const { authority, input, title, choice, deferredThinking } = launch;
    const taskId = task.taskId;
    let lease: Awaited<ReturnType<OwnedSessionDispatch["createWorker"]>> | undefined;
    let deadline: OwnedOperationDeadline | undefined;
    try {
      const operationId = launch.operationId ?? `task-${randomUUID()}`;
      const reports = new HomeTaskReportOwner({ taskId: task.taskId, homeId: task.homeId, generation: task.generation, operationId }, async () => {
        await this.store.update(task.taskId, current => {
          if (current.lifecycle !== "active" || current.operationId !== operationId) throw new GatewayError("conflict", "Task operation changed before Stop");
          return current.stopIntent ? current : { ...current, stopIntent: { operationId, requestedAt: new Date().toISOString() } };
        });
        this.diagnostic?.({ event: "home.task.control", taskHash: hash(task.taskId), operationHash: hash(operationId), action: "stop", disposition: "persisted" });
        await cancellation("task-stop");
      }, async (sessionId, request) => {
        let accepted!: HomeTaskCheckin;
        const saved = await this.store.update(task.taskId, current => {
          if (current.lifecycle !== "active" || current.stopIntent || current.operationId !== operationId || current.sessionId !== sessionId) throw new GatewayError("conflict", "Check-in operation is no longer active");
          const now = Date.now();
          const attention = !request.needsAttention ? "none"
            : current.lastAttentionAt && now - Date.parse(current.lastAttentionAt) < HOME_TASK_ATTENTION_INTERVAL_MS ? "rate-limited"
              : current.attention && !["acknowledged", "blocked", "outcome-unknown"].includes(current.attention.wake.state) ? "pending" : "requested";
          accepted = { ...request, id: randomUUID(), taskId: current.taskId, sessionId, operationId, at: new Date(now).toISOString(), attention };
          return { ...current, checkins: [...current.checkins ?? [], accepted].slice(-HOME_TASK_CHECKIN_LIMIT),
            ...(attention === "requested" ? { lastAttentionAt: accepted.at, attention: { checkin: accepted, wake: this.inbox.attentionEvent(current, accepted) } } : {}) };
        });
        this.diagnostic?.({ event: "home.task.checkin", taskHash: hash(saved.taskId), operationHash: hash(operationId), revision: saved.revision, attention: accepted.attention });
        // The durable outbox owns the wake. Publication never changes acceptance.
        if (accepted.attention === "requested") await this.inbox.publishAttention(saved.taskId).catch(() => {});
        return accepted;
      });
      reports.limitBudget(async entries => {
        const current = await this.sessions.homeTaskBudget().catch(() => undefined);
        const limit = (field: "inputTokens" | "outputTokens") => Math.min(task.budget?.[field] ?? Infinity, current?.[field] ?? Infinity);
        if (limit("inputTokens") === Infinity && limit("outputTokens") === Infinity) return false;
        const span = homeTaskOperationSpan(entries, operationId);
        if (span.index < 0) return false;
        // The same canonical projection the record publishes; never a second counter.
        let spend: ReturnType<typeof homeTaskSpend>;
        try { spend = homeTaskSpend(span.run); } catch { return false; }
        return spend.inputTokens >= limit("inputTokens") || spend.outputTokens >= limit("outputTokens");
      });
      const dispatch = new OwnedSessionDispatch(this.sessions);
      // Trust is rechecked by the neutral creation/admission boundary too.
      // A worker created after admission was refused is released, never prompted.
      const resume = launch.resume;
      lease = resume
        // A resumed task rebinds its predecessor's worker session in place (#929).
        ? await this.stage("create-worker", taskId, signal, () => dispatch.resumeWorker(resume.sessionId, reports, resume.exceptWorkToken), late => late.release())
        : await this.stage("create-worker", taskId, signal, () => dispatch.createWorker(task.target, reports), late => late.release());
      const { slot } = lease;
      const appliedChoice = resume ? "" : await (async () => {
      const configured = await this.stage("configure-worker", taskId, signal, async () => {
      // Name the worker before its first prompt; the slot persists the canonical transcript entry.
      if (title) await slot.rename(title);
      // The slot's own configuration owners record the choice in the worker's transcript
      // before its first prompt. An omitted model keeps the session's default.
      const fixedAt = (value: unknown, field: "model" | "thinking"): FixedSetting => ({ value,
        from: "delegate", at: new Date().toISOString(), ref: randomUUID(), ...input.provenance?.[field] });
      const model = choice.model ?? (input.provenance ? slot.snapshot().model ?? undefined : undefined);
      if (model) await slot.setModel(model.provider, model.id, undefined, undefined, fixedAt(model, "model"));
      const requestedThinking = choice.thinking ?? deferredThinking;
      const definition = model ? slot.modelRuntime.getModel(model.provider, model.id) : undefined;
      const thinking = requestedThinking !== undefined && definition ? clampThinkingLevel(definition, requestedThinking) : requestedThinking;
      const clamped = thinking !== requestedThinking ? `${requestedThinking} clamped to ${thinking}` : undefined;
      if (thinking !== undefined) {
        const source = fixedAt(thinking, "thinking");
        if (clamped) source.reason = [source.reason, clamped].filter(Boolean).join("; ");
        await slot.setThinking(thinking, undefined, undefined, source);
      }
      return { model, clamped };
      });
      const { model, clamped } = configured;
      // The canonical worker brief records the actual fallback capability choice;
      // the authorized task intent/digest is never rewritten after admission.
      const appliedChoice = input.provenance
        ? `\n\nWorker at start: ${model ? `${model.provider}/${model.id}` : "worker default"}; thinking ${slot.snapshot().thinkingLevel}${clamped ? `; ${clamped}` : ""}.`
        : "";
      return appliedChoice;
      })();
      task = { ...task, revision: task.revision + 1, lifecycle: "active", sessionId: slot.id, operationId,
        grantRef: authority.kind === "one-use-grant" ? authority.grantId : null,
        scopeRef: authority.kind === "standing-scope" ? authority.scopeId : null };
      const bound = task;
      // Once bound, the record names this worker and operation; a late bind is
      // refused by settlement rather than prompted.
      task = await this.stage("bind", taskId, signal, () => this.store.put(bound, bound.revision - 1),
        late => { this.transition(late, "operation-bound"); void this.refuseAdmission(late, "admission-cancelled").catch(() => {}); });
      this.transition(task, "operation-bound");
      let resolve!: (terminal: OwnedOperationTerminal) => void;
      const terminal = new Promise<OwnedOperationTerminal>(done => { resolve = done; });
      const cancellation = async (reason = "interrupted") => {
        reports.cancel();
        await slot.cancelHomeTaskOperation(operationId, reason);
      };
      // Arm before the first asynchronous prompt preflight; cancellation never
      // queues behind the lane whose blocked admission it must interrupt. The same
      // deadline bounds the subagent join below, so it is disarmed only at settlement.
      deadline = dispatch.armDeadline();
      const bounded = dispatch.enforceDeadline({ operationId, completion: terminal, cancel: cancellation }, deadline);
      work.transition("foreground-agent-operation");
      const admitted = dispatch.admit(slot, `${task.intent.text}${appliedChoice}\n\nThis is a finite Home task. Send a short checkin at milestones and about every 30 minutes (step, done, next; optional blocker/refs). It does not pause or finish work. Use needsAttention only for blockers needing Home; it is rate-limited. Use report with explicit evidence to finish. A normal reply is not a task result.`, launch.resume?.images ?? [], undefined, undefined, undefined,
        { operationId, signal: reports.signal, origin: { kind: "gateway", ownerId: task.taskId, title: "Home task", confidence: "boundary" }, onTerminal: resolve });
      void admitted.catch(async () => {
        await cancellation("admission-refused").catch(() => {});
        if (slot.snapshot().operation?.id !== operationId) resolve({ lifecycle: "outcomeUnknown", operationId, invocationId: "admission-unknown", errorCode: "admission-refused" });
      });
      const active = task;
      const ownedLease = lease;
      const completion = (async () => {
        const outcome = await bounded;
        work.transition("terminal-receipt-persistence");
        const deadlineStopFailed = outcome.state === "deadline-stop-failed";
        if (!deadlineStopFailed) await admitted.catch(() => {});
        let reportStopFailed = false;
        try { await reports.joinStop(); } catch { reportStopFailed = true; }
        // Async runs the task started are stopped and joined before the evidence cut,
        // so the cut records every stop and the outcome reads the join's result.
        const settled = await slot.settleTaskSubagents(operationId, deadline!.signal);
        // Share cold recovery's durable file cut before publishing any terminal
        // references/outbox or acknowledging the operation. SDK append visibility
        // alone cannot guarantee the worker evidence survives a power loss.
        const cut = await this.sessions.readLiveTaskEvidence(slot.id, operationId);
        // Spend and last-reply evidence remain selected-branch projections;
        // immutable report addresses are qualified across the durable file.
        const entries = cut.state === "present" ? cut.branch : [];
        const runEntries = homeTaskOperationSpan(entries, operationId).run;
        const evidence = cut.state === "present" ? await this.reportEvidence(active, cut.entries) : undefined;
        const report = evidence?.report;
        const last = runEntries.findLast(entry => entry.type === "message" && entry.message.role === "assistant");
        const lastMessage = last?.type === "message" && last.message.role === "assistant" ? last.message : undefined;
        const deadlineStopped = outcome.state === "deadline-stopped";
        const detached = slot.catalogHasActiveSubagents;
        const spend = homeTaskSpend(runEntries);
        const interruption = outcome.state !== "terminal" || outcome.terminal.lifecycle !== "interrupted" ? undefined
          : runEntries.find(entry => {
            if (entry.type !== "custom" || entry.customType !== INVOCATION_RECEIPT_TYPE) return false;
            const receipt = parseInvocationReceipt(entry.data);
            return receipt?.receiptKind === "terminal" && receipt.lifecycle === "interrupted"
              && receipt.operationId === outcome.terminal.operationId && receipt.invocationId === outcome.terminal.invocationId && receipt.sessionId === slot.id;
          });
        // A Stop that landed between turns interrupted no turn, so it has no interruption receipt to
        // pin: the waiting terminal and the durable stop intent are its proof.
        const interrupted = interruption !== undefined || (outcome.state === "terminal" && outcome.terminal.errorCode === TASK_STOP_WAITING);
        // Stop intent is append-only. Qualify before entering the store update:
        // missing proof is not namespace corruption or a publication attempt.
        const stoppedBeforeConversation = cut.state === "absent";
        if (stoppedBeforeConversation && (!cut.operationSettled || !(await this.store.read(active.taskId))?.stopIntent || deadlineStopFailed || reportStopFailed || detached)) {
          throw new GatewayError("conflict", "Task canonical evidence is unavailable");
        }
        const final = await this.store.update(active.taskId, current => ({ ...current, lifecycle: "terminal", spend, wake: this.inbox.event(current),
          reportRef: report && evidence ? { resultId: report.resultId, sessionId: slot.id, entryId: evidence.entryId, digest: reportDigest(report) } : null,
          terminalEvidence: { outcome: stoppedBeforeConversation ? "interrupted" : detached || deadlineStopFailed || reportStopFailed ? "unknown" : report ? report.outcome : reports.budgetExceeded || deadlineStopped || lastMessage?.stopReason === "length" ? "limited" : interrupted && current.stopIntent ? "interrupted" : "unknown",
            sessionId: slot.id, entryIds: evidence ? [evidence.entryId] : [...(interruption ? [interruption.id] : []), ...(last ? [last.id] : [])],
            reason: stoppedBeforeConversation ? "stopped-before-conversation" : detached ? "detached-work-outlived-task" : deadlineStopFailed ? "deadline-stop-failed" : reportStopFailed ? current.stopIntent ? "task-stop-failed" : "report-stop-failed" : report ? "explicit-report" : reports.budgetExceeded ? "budget" : deadlineStopped ? "deadline" : lastMessage?.stopReason === "length" ? "length" : interrupted && current.stopIntent ? "task-stop" : "no-report" } }));
        this.transition(final, final.terminalEvidence!.reason);
        if (detached) this.diagnostic?.({ event: "home.task.detached-work", taskHash: hash(final.taskId), operationHash: hash(operationId), reason: "detached-work-outlived-task" });
        const subagents = cut.state === "present" ? homeTaskSubagentsProjection(entries, operationId) : { started: 0, stoppedAtEnd: 0 };
        this.diagnostic?.({ event: "home.task.subagents", taskHash: hash(final.taskId), operationHash: hash(operationId), started: subagents.started, stoppedAtEnd: subagents.stoppedAtEnd, noticesUndelivered: settled.noticesUndelivered });
        const spendReference = `${hash(final.taskId)}:${final.revision}`;
        this.diagnostic?.({ event: "home.task.spend", taskHash: hash(final.taskId), spendReference,
          inputTokens: spend.inputTokens, outputTokens: spend.outputTokens });
        if (outcome.state === "deadline-stopped" || outcome.state === "deadline-stop-failed") this.diagnostic?.({ event: "home.task.runaway-stop", taskHash: hash(final.taskId),
          operationHash: hash(operationId), elapsedMs: outcome.elapsedMs,
          cancelAndJoin: deadlineStopped ? "joined" : "failed", spendReference });
        await dispatch.acknowledge(slot.id, operationId, ownedLease);
        await this.inbox.publish(final.taskId);
        return (await this.store.read(final.taskId))!;
      })().catch(async (error: unknown) => {
        // The worker's operation is over and its lease retires below, so nothing else would ever
        // settle this task in process: it settles now from its canonical file, as cold recovery
        // would, and names the failure (#1166). A failure after the terminal write is publication's:
        // cold recovery republishes it.
        if ((await this.store.read(active.taskId))?.lifecycle === "terminal") throw error;
        const final = await this.reconcile(active, "live", error instanceof Error && error.message.trim() ? error.message.trim() : "settlement failed");
        await dispatch.acknowledge(slot.id, operationId, ownedLease).catch(() => {});
        return final;
      }).finally(() => { deadline!.disarm(); reports.retire(); ownedLease.release(); work.settle(); this.releaseSlot(taskId); });
      // Tool callers return admission immediately, but failures remain observed.
      void completion.catch(() => {});
      return { taskId: task.taskId, sessionId: slot.id, operationId, completion };
    } catch (error) {
      deadline?.disarm();
      lease?.release();
      this.releaseSlot(taskId);
      await this.admissionFailed(task, error);
      throw error;
    }
  }

  /** Settles a task whose admission failed after its pending record exists. */
  private async admissionFailed(task: HomeTaskRecord, error: unknown): Promise<void> {
    {
      if (error instanceof HomeTaskDispatchStageError) {
        // The refused step may still hold the store queue, so the turn's Stop never
        // waits for this settlement; cold recovery is its backstop if it fails.
        void this.refuseAdmission(task, error.outcome === "timeout" ? "admission-timeout" : "admission-cancelled")
          .catch(() => { /* A store refusal emits its own diagnostic. */ });
        return;
      }
      // Accepted identity remains durable and cannot be used for prompt replay.
      // The refusal's own message is kept, so Home and the app can say why (#959).
      const detail = error instanceof Error && error.message.trim() ? [...error.message.trim()].slice(0, HOME_TASK_REFUSAL_DETAIL_CHARACTERS).join("") : undefined;
      const final: HomeTaskRecord = { ...task, revision: task.revision + 1, lifecycle: "terminal", wake: this.inbox.event(task),
        terminalEvidence: { outcome: "unknown", sessionId: task.sessionId, entryIds: [], reason: "admission-refused", ...(detail ? { detail } : {}) } };
      await this.store.put(final, task.revision);
      this.transition(final, "admission-refused", error instanceof GatewayError ? error.code : "internal");
      await this.inbox.publish(final.taskId);
    }
  }

  private releaseSlot(taskId: string): void {
    this.running.delete(taskId);
  }

  /** Workers running now, for Home status. */
  workers(): { running: number } {
    return { running: this.running.size };
  }

  hostPressure() { return this.pressure.sample(); }

  async validateWorkerMarker(sessionId: string, marker: unknown): Promise<void> {
    await this.assertAvailable();
    await this.validateMarkerEvidence(sessionId, marker);
  }

  private async validateMarkerEvidence(sessionId: string, marker: unknown): Promise<void> {
    const value = marker as Record<string, unknown>;
    if (!value || Object.keys(value).sort().join(",") !== "generation,homeId,operationId,receiptId,sessionId,taskId,version"
      || value.version !== 1 || typeof value.taskId !== "string" || value.sessionId !== sessionId) throw new GatewayError("conflict", "Invalid task marker");
    const task = await this.store.read(value.taskId);
    if (!task || task.sessionId !== sessionId || task.operationId !== value.operationId
      || task.homeId !== value.homeId || task.generation !== value.generation || value.receiptId !== `task:${task.operationId}`) throw new GatewayError("conflict", "Referenced task is missing or contradictory");
  }

  async permissions() { await this.assertAvailable(); return this.authorization.list(); }
  async revokeScope(scopeId: string) { await this.assertAvailable(); await this.authorization.revokeScope(scopeId); }
  async revokeGrant(grantId: string) { await this.assertAvailable(); await this.authorization.revokeGrant(grantId); }
  async decideGrant(requestId: string, input: { decisionId: string; approved: boolean; expiresAt: number }) {
    await this.assertAvailable();
    return this.setup.run(async () => {
      const restoreEpoch = await this.store.restoreEpoch();
      const result = await this.authorization.recordDecisionAndGrant(requestId, { ...input, restoreEpoch }).catch(error => {
        if (error instanceof HomeTaskAuthorizationError) throw new GatewayError("conflict", error.code);
        throw error;
      });
      if (restoreEpoch !== await this.store.restoreEpoch()) throw new GatewayError("conflict", "Task namespace changed during decision");
      return result;
    });
  }

  async reconfirmPermissions(): Promise<void> {
    await this.assertAvailable();
    await this.setup.run(async () => {
      const epoch = await this.store.restoreEpoch();
      await this.authorization.reconfirmPermissions(epoch);
      if (epoch !== await this.store.restoreEpoch()) throw new GatewayError("conflict", "Task namespace changed during reconfirmation");
    });
  }

  async steer(control: HomeTaskControlRequest & { text: string }): Promise<void> {
    const task = await this.activeControl(control);
    // A steer would start a fresh turn in a session no task operation owns.
    if (!this.running.has(task.taskId)) throw new GatewayError("conflict", "Task has no live worker; stop settles it");
    if (typeof control.text !== "string" || !control.text.trim() || Buffer.byteLength(control.text) > 65536) throw new GatewayError("invalid_request", "Invalid task steering text");
    const slot = await this.sessions.acquire(task.sessionId!);
    await slot.steerHomeTask(control, control.text);
  }

  /** The current task of a worker session: the newest bound to it. Tasks resumed in place
   * share their predecessor's session, and each task has at most one successor. */
  async latestTaskForSession(sessionId: string): Promise<HomeTaskRecord | undefined> {
    await this.assertAvailable();
    let latest: HomeTaskRecord | undefined;
    for await (const task of this.store.records()) {
      if (task.sessionId !== sessionId) continue;
      if (!latest || task.createdAt > latest.createdAt || (task.createdAt === latest.createdAt && task.resumes?.taskId === latest.taskId)) latest = task;
    }
    return latest;
  }

  async stop(control: HomeTaskControlRequest): Promise<void> {
    await this.assertAvailable();
    const task = await this.activeControl(control);
    // An active task no launch in this process owns has no worker to stop: its live settlement
    // and that settlement's fallback both failed. The durable intent settles it (#1166).
    if (!this.running.has(task.taskId)) {
      const stopped = await this.store.update(task.taskId, current => {
        if (current.lifecycle !== "active" || current.operationId !== control.operationId) throw new GatewayError("conflict", "Task operation changed before Stop");
        return current.stopIntent ? current : { ...current, stopIntent: { operationId: control.operationId, requestedAt: new Date().toISOString() } };
      });
      this.diagnostic?.({ event: "home.task.control", taskHash: hash(task.taskId), operationHash: hash(control.operationId), action: "stop", disposition: "persisted" });
      await this.reconcile(stopped, "live");
      return;
    }
    // No session mutation lane here: Stop must be able to cancel its admission.
    await (await this.sessions.acquire(task.sessionId!)).stopHomeTask(control);
  }

  /** One task as Home's `task` tool shows it: its state, the operation a control would act on and
   * the actions it allows now. `continuedAs` names a later in-place resume of the same worker. */
  async controlRow(task: HomeTaskRecord, continuedAs?: string): Promise<HomeTaskControlRow> {
    const state: HomeTaskControlRow["state"] = task.lifecycle === "active" ? "running" : task.lifecycle === "terminal" ? "settled" : "starting";
    const actions: HomeTaskControlRow["actions"] = continuedAs ? ["status", "report"]
      : state === "running" ? ["status", "steer", "stop"]
      : state === "settled" ? ["status", "report", ...(task.sessionId ? ["resume" as const] : [])] : ["status"];
    const evidence = task.terminalEvidence;
    return { taskId: task.taskId, title: (await this.display(task)).title, state, outcome: evidence?.outcome ?? null,
      ...(evidence ? { reason: evidence.reason } : {}), ...(evidence?.detail ? { detail: evidence.detail } : {}),
      sessionId: task.sessionId, operationId: task.operationId, checkins: (task.checkins ?? []).slice(-HOME_TASK_CHECKIN_VISIBLE),
      ...(task.resumes ? { resumes: task.resumes.taskId } : {}),
      ...(continuedAs ? { continuedAs } : {}), updatedAt: new Date(task.updatedAt).toISOString(), actions };
  }

  /** Home's newest tasks as control rows, newest first. A settled task whose worker a newer task
   * in the page continues names it, so a control is sent to the current one. */
  async controlCatalog(limit: number): Promise<{ tasks: HomeTaskControlRow[]; counts: HomeTaskCounts; more: boolean }> {
    await this.assertAvailable();
    const page = await this.store.page({ limit });
    const newestBySession = new Map<string, string>();
    const tasks: HomeTaskControlRow[] = [];
    for (const { task } of page.items) {
      const newer = task.sessionId ? newestBySession.get(task.sessionId) : undefined;
      if (task.sessionId && !newer) newestBySession.set(task.sessionId, task.taskId);
      tasks.push(await this.controlRow(task, newer));
    }
    return { tasks, counts: page.counts, more: page.nextCursor !== undefined };
  }

  /** Up to five task IDs close to one that does not exist, newest first, for an actionable miss. */
  async similarTaskIds(taskId: string): Promise<string[]> {
    const wanted = taskId.toLowerCase();
    const scored: Array<{ taskId: string; createdAt: number; score: number }> = [];
    for await (const task of this.store.records()) {
      const id = task.taskId.toLowerCase();
      const score = id.includes(wanted) || wanted.includes(id) ? 0 : editDistance(id, wanted);
      if (score <= Math.max(2, Math.floor(Math.max(id.length, wanted.length) / 3))) scored.push({ taskId: task.taskId, createdAt: task.createdAt, score });
    }
    return scored.sort((a, b) => a.score - b.score || b.createdAt - a.createdAt).slice(0, 5).map(item => item.taskId);
  }

  private async activeControl(control: HomeTaskControlRequest): Promise<HomeTaskRecord> {
    await this.assertAvailable();
    const task = await this.store.read(control.taskId);
    if (!task || task.lifecycle !== "active" || !task.sessionId || task.operationId !== control.operationId) throw new GatewayError("conflict", "Stale or terminal task operation");
    return task;
  }

  async status(taskId: string): Promise<HomeTaskStatus> {
    const task = await this.result(taskId);
    const workerModel = task.sessionId ? await this.sessions.taskWorkerModel(task.sessionId) ?? null : null;
    const status = { ...task, checkins: (task.checkins ?? []).slice(-HOME_TASK_CHECKIN_VISIBLE), ...await this.display(task), workerModel, subagents: await this.subagents(task),
      subagentRuns: await this.liveSubagentRuns(task), ownerSettlement: await this.ownerSettlement(task) };
    // Neither a transcript read nor a prior terminal projection fences a replaced
    // task identity. Recheck after every projection await, without updating spend.
    if (task.lifecycle === "terminal" && task.terminalEvidence?.reason === "no-report") {
      const current = await this.store.read(taskId);
      if (!current || current.taskId !== task.taskId || current.sessionId !== task.sessionId
        || current.operationId !== task.operationId || current.homeId !== task.homeId || current.generation !== task.generation
        || current.lifecycle !== task.lifecycle || JSON.stringify(current.terminalEvidence) !== JSON.stringify(task.terminalEvidence)) {
        throw new GatewayError("conflict", "Task identity or lifecycle changed during status inspection");
      }
    }
    return status;
  }

  /** A no-report result says nothing about success. Only a durable, ordered cut
   * proves this worker ended and joined its children; terminal run counts are synthetic. */
  private async ownerSettlement(task: HomeTaskRecord): Promise<HomeTaskOwnerSettlement | null> {
    if (task.lifecycle !== "terminal" || task.terminalEvidence?.outcome !== "unknown"
      || task.terminalEvidence.reason !== "no-report" || !task.sessionId || !task.operationId
      || task.terminalEvidence.sessionId !== task.sessionId) return null;
    try {
      const entries = await this.sessions.readTaskEvidence(task.sessionId);
      // The operation's own span: a resumed successor appends its operation after it.
      const span = homeTaskOperationSpan(entries, task.operationId);
      if (span.index < 0) return null;
      const operation = [entries[span.index]!, ...span.run];
      const markers = operation.filter(entry => entry.type === "custom" && entry.customType === HOME_TASK_MARKER);
      const terminals = operation.filter(entry => entry.type === "custom" && entry.customType === INVOCATION_RECEIPT_TYPE
        && (entry.data as { receiptKind?: unknown } | null)?.receiptKind === "terminal");
      const settlements = operation.filter(entry => entry.type === "custom" && entry.customType === HOME_TASK_SUBAGENTS);
      if (markers.length !== 1 || terminals.length !== 1 || settlements.length !== 1) return null;
      const marker = markers[0]!, terminal = terminals[0]!, settlement = settlements[0]!;
      if (marker.type !== "custom" || terminal.type !== "custom" || settlement.type !== "custom") return null;
      await this.validateMarkerEvidence(task.sessionId, marker.data);
      const binding = marker.data as { taskId: string; operationId: string; homeId: string; generation: number };
      if (binding.taskId !== task.taskId || binding.operationId !== task.operationId
        || binding.homeId !== task.homeId || binding.generation !== task.generation) return null;
      const receipt = parseInvocationReceipt(terminal.data);
      if (!receipt || receipt.receiptKind !== "terminal" || receipt.operationId !== task.operationId
        || receipt.sessionId !== task.sessionId || receipt.source !== "plain" || receipt.lifecycle === "outcomeUnknown"
        || receipt.receiptId !== `terminal:${receipt.invocationId}` || receipt.origin?.kind !== "gateway"
        || receipt.origin.ownerId !== task.taskId || receipt.origin.confidence !== "boundary") return null;
      const starts = operation.filter(entry => entry.type === "custom" && entry.customType === INVOCATION_RECEIPT_TYPE
        && (entry.data as { receiptKind?: unknown } | null)?.receiptKind === "start");
      if (starts.length !== 1 || starts[0]?.type !== "custom") return null;
      const start = parseInvocationReceipt(starts[0].data);
      if (!start || start.receiptKind !== "start" || start.invocationId !== receipt.invocationId
        || start.operationId !== task.operationId || start.sessionId !== task.sessionId || start.source !== "plain"
        || start.origin.kind !== receipt.origin.kind || start.origin.ownerId !== receipt.origin.ownerId
        || start.origin.confidence !== receipt.origin.confidence || start.origin.title !== receipt.origin.title) return null;
      const fact = parseHomeTaskSubagentsEntry(settlement.data, task.operationId);
      if (fact.stoppedAtEnd === null || entries.indexOf(marker) >= entries.indexOf(terminal)
        || entries.indexOf(starts[0]) >= entries.indexOf(terminal) || entries.indexOf(terminal) >= entries.indexOf(settlement)
        || operation.at(-1)?.id !== settlement.id) return null;
      const counts = homeTaskSubagentsProjection(entries, task.operationId);
      if (fact.stoppedAtEnd > counts.started) return null;
      return { taskId: task.taskId, sessionId: task.sessionId, operationId: task.operationId,
        markerEntryId: marker.id, terminalEntryId: terminal.id, settlementEntryId: settlement.id, stoppedAtEnd: fact.stoppedAtEnd };
    } catch {
      // Missing, malformed, or racing canonical bytes are absence of proof, not
      // authority to repair the transcript or infer settlement from zero counts.
      return null;
    }
  }

  /** The list page of the newest tasks, each with its display, from one store pass
   * and never a report body. Identical reads in flight share that pass (#906): a
   * client that re-asks while one read is pending adds no store work. The pass
   * leaves the store queue once every reader waiting on it has gone. */
  async list(input: { limit?: number; cursor?: string }, signal?: AbortSignal): Promise<HomeTaskPage> {
    const key = JSON.stringify([input.limit ?? null, input.cursor ?? null]);
    let flight = this.listFlights.get(key);
    if (!flight) {
      const controller = new AbortController();
      const created: ListFlight = { readers: 0, controller, result: this.readList(input, controller.signal)
        .finally(() => { if (this.listFlights.get(key) === created) this.listFlights.delete(key); }) };
      this.listFlights.set(key, created);
      flight = created;
    }
    const joined = flight;
    joined.readers += 1;
    try {
      return await abortableRead(signal, () => joined.result);
    } finally {
      joined.readers -= 1;
      if (joined.readers === 0 && signal?.aborted) {
        if (this.listFlights.get(key) === joined) this.listFlights.delete(key);
        joined.controller.abort(signal.reason);
      }
    }
  }

  private async readList(input: { limit?: number; cursor?: string }, signal: AbortSignal): Promise<HomeTaskPage> {
    const page = await this.store.page(input, signal);
    const items: HomeTaskSummary[] = [];
    for (const { task, pendingGrant } of page.items) {
      items.push({
        taskId: task.taskId, createdAt: task.createdAt, updatedAt: task.updatedAt, sessionId: task.sessionId, target: task.target,
        lifecycle: task.lifecycle, outcome: task.terminalEvidence?.outcome ?? null, spend: task.spend,
        attention: task.terminalEvidence?.outcome === "needs-input" || task.terminalEvidence?.outcome === "unknown",
        checkins: (task.checkins ?? []).slice(-HOME_TASK_CHECKIN_VISIBLE), pendingGrant, ...await this.display(task),
      });
    }
    return { items, counts: page.counts, ...(page.nextCursor ? { nextCursor: page.nextCursor } : {}) };
  }

  /** A task's display. A worker's name is read from its canonical session, never a transcript scan. */
  private async display(task: HomeTaskRecord): Promise<HomeTaskDisplay> {
    const workerName = task.sessionId ? await this.sessions.taskWorkerName(task.sessionId) : undefined;
    return { title: homeTaskTitle(task.intent.text, workerName), project: basename(task.target) };
  }

  /** The worker's live subagent runs, newest first and bounded for status. Only an active
   * task has a live worker to read; a settled task lists none. */
  async liveSubagentRuns(task: HomeTaskRecord): Promise<HomeTaskSubagentRuns> {
    if (task.lifecycle !== "active" || !task.sessionId) return { total: 0, runs: [] };
    const runs = (await this.sessions.acquire(task.sessionId)).liveSubagentRuns();
    const newestFirst = [...runs].sort((left, right) => Date.parse(right.startedAt) - Date.parse(left.startedAt));
    return { total: runs.length, runs: newestFirst.slice(0, HOME_TASK_STATUS_RUN_LIMIT) };
  }

  /** The operation's subagent counts, read from the worker's canonical evidence and
   * never persisted with the task. A task without a worker or operation launched none. */
  async subagents(task: HomeTaskRecord): Promise<HomeTaskSubagents> {
    return task.sessionId && task.operationId
      ? this.sessions.taskWorkerSubagents(task.sessionId, task.operationId)
      : { started: 0, stoppedAtEnd: 0 };
  }

  async result(taskId: string): Promise<HomeTaskRecord> {
    await this.assertAvailable();
    let task = await this.store.read(taskId).catch(error => {
      if (error instanceof HomeTaskStoreError && error.code === "not-initialized") return undefined;
      throw error;
    });
    if (!task) throw new GatewayError("not_found", "No task with this id");
    if (task.lifecycle === "active" && task.sessionId && task.operationId) {
      const slot = await this.sessions.acquire(task.sessionId);
      task = await this.store.update(taskId, current => {
        if (current.lifecycle !== "active") return current;
        // Read canonical deltas while this publication owns the store mutex;
        // an older status read cannot replace a newer usage projection.
        const spend = homeTaskSpend(homeTaskOperationSpan(slot.canonicalSessionEntries(), current.operationId!).run);
        return JSON.stringify(current.spend) === JSON.stringify(spend) ? current : { ...current, spend };
      });
      this.diagnostic?.({ event: "home.task.spend", taskHash: hash(task.taskId), spendReference: `${hash(task.taskId)}:${task.revision}`,
        inputTokens: task.spend?.inputTokens ?? 0, outputTokens: task.spend?.outputTokens ?? 0 });
    }
    if (task.reportRef) {
      if (!task.sessionId || !task.operationId) throw new GatewayError("conflict", "Task evidence is missing");
      const entries = await this.sessions.readTaskEvidence(task.sessionId);
      const evidence = await this.reportEvidence(task, entries);
      const ref = task.reportRef;
      if (!evidence || evidence.entryId !== ref.entryId || evidence.report.resultId !== ref.resultId
        || evidence.report.sessionId !== ref.sessionId || reportDigest(evidence.report) !== ref.digest) throw new GatewayError("conflict", "Task report reference is missing or contradictory");
    }
    return task;
  }
  private transition(task: HomeTaskRecord, reason: string, errorCode?: string): void {
    this.diagnostic?.({ event: "home.task.transition", taskHash: hash(task.taskId), revision: task.revision,
      transition: task.lifecycle, reason, operationHash: task.operationId ? hash(task.operationId) : null, ...(errorCode ? { errorCode } : {}) });
    // A bound task names its worker; the catalog marks that row a Home worker.
    if (task.sessionId) this.sessions.recordTaskWorkers([[task.sessionId, task.taskId]]);
    // Every terminal write reaches here once; attention is presentation state,
    // so a failed mark never affects the task's own settlement.
    if (task.lifecycle === "terminal" && task.sessionId) {
      const sessionId = task.sessionId;
      void Promise.resolve().then(() => this.sessions.taskWorkerSettled(sessionId, task.taskId)).catch(() => {});
    }
  }
}
