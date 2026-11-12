import type { TaskWorkerControl, TaskControlRefusalReason, TaskWorkerDiagnostic } from "../../kernel/delegation/worker-contract.js";
import { settleTaskSubagents } from "../../kernel/delegation/subagent-settlement.js";
import { isUsageLimitError, type QueueModelState } from "../../providers/model-queue-extension.js";
import { createHash, randomUUID } from "node:crypto";
import type { AssistantMessage, ImageContent } from "../../kernel/pi/ai.js";
import { clampThinkingLevel } from "../../kernel/pi/ai.js";
import type { FileEntry } from "../../kernel/pi/coding-agent.js";
import type { GatewayWorkHandle } from "../../kernel/run/gateway-work-registry.js";
import type { SessionOperations } from "../../kernel/session/runtime-registry.js";
import { TASK_STOP_WAITING, type OwnedOperationTerminal } from "../../kernel/delegation/owned-operation-terminal.js";
import type { OwnedOperationDeadline } from "../../kernel/delegation/delegation-operations.js";
import { INVOCATION_RECEIPT_TYPE, parseInvocationReceipt } from "../../kernel/receipts/invocation-receipts.js";
import { GatewayError } from "../../errors.js";
import { AsyncMutex } from "../../util/async-mutex.js";
import { injectedText } from "../../kernel/host/injected-text.js";
import { HomeTaskAuthorization, HomeTaskAuthorizationError, type HomeTaskAuthorizationDiagnostic } from "./home-task-authorization.js";
import { changeReview } from "../../kernel/settings/settings-types.js";
import type { ConfirmChange } from "../../kernel/settings/tool-contract.js";

export type HomeTaskGrantApproval = { confirm: ConfirmChange } | { maintainerCommand: string };
const HOME_TASK_GRANT_USE_MS = 60_000;
import { HomeTaskStore, HomeTaskStoreError, taskIntentDigest, type HomeTaskRecord, type HomeTaskWrite, type HomeTaskFailureCause, type HomeTaskStoreDiagnostic, type HomeTaskStoreCode } from "./home-task-store.js";
import { homeTaskPromptTokens, homeTaskSpend, type HomeTaskSpend } from "./home-task-spend.js";
import type { WakeInboxOwner, HomeWakeDiagnostic } from "./home-wake-inbox.js";
import { HOME_TASK_ATTENTION_INTERVAL_MS, HOME_TASK_CHECKIN_LIMIT, HOME_TASK_CHECKIN_VISIBLE } from "../../kernel/delegation/task-checkin.js";
import { HOME_TASK_MARKER, HOME_TASK_REPORT, HomeTaskReportOwner, homeTaskOperationSpan, parseHomeTaskReport, type HomeTaskReport } from "../../kernel/delegation/task-report.js";
import type { HomeTaskWorkerChoice, HomeTaskPolicy } from "./home-task-worker-choice.js";
import type { FixedSetting } from "../../kernel/settings/tool-contract.js";
import { HOME_TASK_SUBAGENTS, HOME_TASK_STATUS_RUN_LIMIT, homeTaskSubagentLaunches, homeTaskSubagentsProjection, parseHomeTaskSubagentsEntry, type HomeTaskSubagentRuns, type HomeTaskSubagents } from "../../kernel/delegation/task-subagents.js";
import type { HomeTaskCheckin, HomeTaskCounts, HomeTaskDisplay, HomeTaskPage, HomeTaskSummary } from "../../protocol/types.js";
import { basename } from "node:path";
import { TRON_ASK_USER_INTERRUPTED } from "../../extensions/tron-ask-user-contract.js";
import { abortableRead } from "../../util/abortable-read.js";
import { HostPressure, type HostPressureDiagnostic } from "./host-pressure.js";
import { TaskCommandSweep, type TaskCommandDiagnostic } from "./task-command-sweep.js";
import { homeTaskNeedsAttention } from "./home-task-lineage.js";
import { readHomeTaskHistory } from "./home-task-history.js";

interface ListFlight { result: Promise<HomeTaskPage>; readers: number; controller: AbortController }

const CONTROL_REFUSAL_REASONS: ReadonlyMap<string, TaskControlRefusalReason> = new Map([
  ["Stale or terminal task operation", "stale-operation"],
  ["Task has no live worker; stop settles it", "no-live-worker"],
  ["Invalid task steering text", "invalid-steering-text"],
  ["Stale or settled task operation cannot accept steering", "steer-not-admitted"],
  ["Task operation changed before Stop", "operation-changed"],
  ["Task operation changed before Interrupt", "operation-changed"],
]);

export type HomeTaskDiagnostic =
  | TaskWorkerDiagnostic
  | HomeTaskAuthorizationDiagnostic
  | HomeTaskStoreDiagnostic
  | HomeWakeDiagnostic
  | { event: "home.task.detached-work"; taskHash: string; operationHash: string; reason: "detached-work-outlived-task" }
  | { event: "home.task.subagents"; taskHash: string; operationHash: string; started: number; stoppedAtEnd: number | null; noticesUndelivered: number }
  | { event: "home.task.transition"; taskHash: string; revision: number; transition: HomeTaskRecord["lifecycle"]; reason: string; operationHash: string | null; errorCode?: string; failureCause?: HomeTaskFailureCause }
  | { event: "home.task.history-summary"; taskHash: string; counts: { lineages: number; operations: number; resumes: number; complete: number; rootCreatedAtMs: number } }
  | { event: "home.task.checkin"; taskHash: string; operationHash: string; revision: number; attention: HomeTaskCheckin["attention"] }
  | { event: "home.task.spend"; taskHash: string; spendReference: string; inputTokens: number; cacheReadTokens: number; cacheWriteTokens: number; outputTokens: number }
  | { event: "home.inbox.admission-slow"; delivery: "user" | "wake"; durationMs: number }
  | { event: "home.task.dispatch-stage"; taskHash: string; stage: HomeTaskDispatchStage; outcome: "slow" | "timeout" | "cancelled" | "abandon-failed"; durationMs: number }
  | HostPressureDiagnostic
  | TaskCommandDiagnostic
  | { event: "home.task.runaway-stop"; taskHash: string; operationHash: string; elapsedMs: number; cancelAndJoin: "joined" | "failed"; spendReference: string };
type HomeTaskRecoveryStatus = { available: true } | { available: false; reason: HomeTaskStoreCode | "not-started" };
export interface HomeTaskDispatchRequest extends HomeTaskWorkerChoice {
  taskId: string; intent: string; target: string; title?: string; reason?: string;
  provenance?: { model: Pick<FixedSetting, "via" | "reason">; thinking: Pick<FixedSetting, "via" | "reason"> };
  modelQueues?: import("../../kernel/settings/tool-contract.js").TaskModelQueues;
}
export interface HomeTaskOwnerSettlement {
  taskId: string; sessionId: string; operationId: string;
  markerEntryId: string; terminalEntryId: string; settlementEntryId: string; stoppedAtEnd: number;
}
type HomeTaskStatus = Omit<HomeTaskRecord, "checkins"> & HomeTaskDisplay & { checkins: HomeTaskCheckin[]; workerModel: { provider: string; id: string } | null; subagents: HomeTaskSubagents; subagentRuns: HomeTaskSubagentRuns; ownerSettlement: HomeTaskOwnerSettlement | null };
interface HomeTaskControlRow {
  taskId: string;
  title: string;
  state: "starting" | "running" | "settled";
  outcome: string | null;
  reason?: string;
  failureCause?: HomeTaskFailureCause;
  detail?: string;
  sessionId: string | null;
  operationId: string | null;
  resumes?: string;
  continuedAs?: string;
  updatedAt: string;
  checkins: HomeTaskCheckin[];
  actions: Array<"status" | "report" | "steer" | "interrupt" | "stop" | "resume" | "rename">;
}

function editDistance(a: string, b: string): number {
  let previous = Array.from({ length: b.length + 1 }, (_, index) => index);
  for (let i = 1; i <= a.length; i += 1) {
    const current = [i];
    for (let j = 1; j <= b.length; j += 1) current[j] = Math.min(previous[j]! + 1, current[j - 1]! + 1, previous[j - 1]! + (a[i - 1] === b[j - 1] ? 0 : 1));
    previous = current;
  }
  return previous[b.length]!;
}
export interface HomeTaskResumeRequest extends TaskWorkerControl { text?: string }

export function successorTaskId(taskId: string): string {
  const match = /^(.*)\.resume-([1-9][0-9]{0,5})$/u.exec(taskId);
  const next = match ? `${match[1]}.resume-${Number(match[2]) + 1}` : `${taskId}.resume-1`;
  if (next.length > 160) throw new GatewayError("conflict", "Task lineage is too long to resume again");
  return next;
}

interface InterruptedQuestion { title: string; questions: unknown[] }
function interruptedQuestion(run: readonly FileEntry[]): InterruptedQuestion | undefined {
  const entry = run.findLast(candidate => candidate.type === "custom" && candidate.customType === TRON_ASK_USER_INTERRUPTED);
  const data = entry?.type === "custom" ? entry.data as { title?: unknown; questions?: unknown } : undefined;
  return data && typeof data.title === "string" && Array.isArray(data.questions) && data.questions.length > 0
    ? { title: data.title, questions: data.questions } : undefined;
}

function resumeBrief(previous: HomeTaskRecord, instructions: readonly string[], pending: InterruptedQuestion | undefined): string {
  const parts = [`Continue Home task ${previous.taskId} in place. It stopped (${previous.terminalEvidence?.outcome ?? "unknown"}: ${previous.terminalEvidence?.reason ?? "unknown"}); this is the same worker session, so its worktree and branch are still yours. Pick up exactly where it stopped: re-check the state you were in before acting.`];
  if (instructions.length === 1) parts.push(`Instruction:\n${instructions[0]}`);
  else if (instructions.length > 1) parts.push(`Instructions, oldest first (the earlier ones never reached you because a previous resume was refused):\n\n${instructions.join("\n\n---\n\n")}`);
  if (pending) {
    let question = JSON.stringify({ title: pending.title, questions: pending.questions }, null, 2);
    if (Buffer.byteLength(question) > 24 * 1024) question = `${question.slice(0, 24 * 1024)}\n(truncated)`;
    parts.push(`Your last ask_user question was interrupted before it was answered. Unless the instruction above already answers it, ask it again with ask_user, unchanged, before you continue:\n${question}`);
  }
  return parts.join("\n\n");
}
export interface HomeTaskHandle { taskId: string; sessionId: string; operationId: string; completion: Promise<HomeTaskRecord>;
  worker?: HomeTaskWorkerSummary;
  subagentModels?: readonly QueueModelState[] }
export interface HomeTaskWorkerSummary { model: string; thinking: string; modelSource: string; thinkingSource: string; note?: string;
  queue?: readonly QueueModelState[] }
interface HomeTaskLaunch {
  task: HomeTaskRecord; authority: Awaited<ReturnType<HomeTaskAuthorization["authorize"]>>;
  input: HomeTaskDispatchRequest; title: string | undefined;
  choice: HomeTaskWorkerChoice; deferredThinking: HomeTaskDispatchRequest["thinking"];
  resume?: { sessionId: string; images: ImageContent[]; exceptWorkToken?: string };
  operationId?: string;
}
const reportDigest = (value: unknown) => createHash("sha256").update(JSON.stringify(value)).digest("hex");
const hash = (value: string) => createHash("sha256").update(value).digest("hex").slice(0, 16);
export type HomeTaskDispatchStage = "choice" | "setup" | "lookup" | "budget" | "target" | "create"
  | "authorize" | "restore-epoch" | "create-worker" | "configure-worker" | "bind";
export const HOME_TASK_DISPATCH_STAGE_DEADLINE_MS = 60_000;
const HOME_TASK_DISPATCH_STAGE_SLOW_MS = 5_000;

class HomeTaskDispatchStageError extends GatewayError {
  constructor(readonly stage: HomeTaskDispatchStage, readonly outcome: "timeout" | "cancelled") {
    super(outcome === "timeout" ? "busy" : "cancelled", outcome === "timeout"
      ? `Task dispatch step ${stage} did not finish in time` : `Task dispatch was stopped at ${stage}`, outcome === "timeout", { stage });
  }
}

const HOME_TASK_REFUSAL_DETAIL_CHARACTERS = 500;

const HOME_TASK_TITLE_CHARACTERS = 80;

function homeTaskTitle(brief: string, workerName: string | undefined): string {
  const name = workerName?.trim();
  const line = name || brief.split("\n").map(candidate => candidate.trim()).find(candidate => candidate.length > 0) || "";
  return [...line].slice(0, HOME_TASK_TITLE_CHARACTERS).join("");
}

function providerFailure(message: AssistantMessage | undefined): HomeTaskFailureCause | undefined {
  return message?.stopReason === "error"
    ? isUsageLimitError(message.errorMessage) ? "provider-usage-limit" : "provider-error"
    : undefined;
}

export class HomeTaskDispatcher {
  private readonly listFlights = new Map<string, ListFlight>();
  private readonly running = new Set<string>();
  private readonly pressure: HostPressure;
  readonly commands: TaskCommandSweep;
  private readonly setup = new AsyncMutex();
  private recovery: Promise<HomeTaskRecoveryStatus> | undefined;
  constructor(readonly store: HomeTaskStore, readonly authorization: HomeTaskAuthorization,
    private readonly sessions: SessionOperations, private readonly diagnostic: ((record: HomeTaskDiagnostic) => void) | undefined,
    private readonly inbox: WakeInboxOwner, private readonly policy: HomeTaskPolicy) {
    this.pressure = new HostPressure(record => this.diagnostic?.(record));
    this.commands = new TaskCommandSweep({ running: taskId => this.running.has(taskId),
      record: async taskId => { const task = await this.store.read(taskId); return task && { terminal: task.lifecycle === "terminal", sessionId: task.sessionId }; } },
    record => this.diagnostic?.(record));
  }

  recover(): Promise<HomeTaskRecoveryStatus> {
    return this.recovery ??= this.recoverOwned().then(() => { this.commands.start(); return { available: true as const }; }, error => {
      const reason = error instanceof HomeTaskStoreError ? error.code : "unsafe-state";
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
    if (task.lifecycle !== "terminal") await this.reconcile(task, "cold");
    else if (task.wake?.push === "pending") {
      await this.inbox.publish(task.taskId);
    }
    if (task.sessionId && task.operationId) await this.sessions.clearOwnedOperationMarker(task.sessionId, task.operationId);
  }

  private async reconcile(task: HomeTaskRecord, origin: "cold" | "live", detail?: string): Promise<HomeTaskRecord> {
    const reasons = origin === "cold"
      ? { report: "cold-explicit-report", none: "cold-no-report", unavailable: "cold-evidence-unavailable" }
      : { report: "explicit-report", none: "settlement-failed", unavailable: "evidence-unavailable" };
    let report: HomeTaskReport | undefined;
    let entryId: string | undefined;
    let spend = task.spend;
    let entryIds: string[] = [];
    let reason = reasons.none;
    let failureCause: HomeTaskFailureCause | undefined;
    let evidenceRead = false;
    let detached = false;
    if (task.lifecycle === "active" && task.sessionId && task.operationId) {
      try {
        const entries = await this.sessions.readTaskEvidence(task.sessionId);
        const evidence = await this.reportEvidence(task, entries);
        report = evidence?.report; entryId = evidence?.entryId;
        const runEntries = homeTaskOperationSpan(entries, task.operationId).run;
        const observed = homeTaskSpend(runEntries);
        if (spend && (homeTaskPromptTokens(observed) < homeTaskPromptTokens(spend) || observed.outputTokens < spend.outputTokens)) throw new Error("Canonical spend regressed");
        spend = observed;
        const last = runEntries.findLast(entry => entry.type === "message" && entry.message.role === "assistant");
        entryIds = entryId ? [entryId] : last ? [last.id] : [];
        if (report) reason = reasons.report;
        else failureCause = providerFailure(last?.type === "message" && last.message.role === "assistant" ? last.message : undefined);
        const asyncDirs = homeTaskSubagentLaunches(runEntries).flatMap(launch => launch.asyncDir ? [launch.asyncDir] : []);
        homeTaskSubagentsProjection(entries, task.operationId);
        detached = !await this.sessions.delegation.subagentRunsSettled(asyncDirs);
        if (detached) this.diagnostic?.({ event: "home.task.detached-work", taskHash: hash(task.taskId), operationHash: hash(task.operationId), reason: "detached-work-outlived-task" });
        evidenceRead = true;
      } catch (error) {
        if (error instanceof HomeTaskStoreError) throw error;
        report = undefined; entryId = undefined; entryIds = []; reason = reasons.unavailable; failureCause = undefined;
      }
    }
    const final = await this.store.update(task.taskId, current => {
      if (current.lifecycle === "terminal" || current.operationId !== task.operationId) throw new GatewayError("conflict", "Task settled or changed during reconciliation");
      const stopped = evidenceRead && !report && !detached && current.stopIntent !== null;
      const settledReason = detached ? "detached-work-outlived-task" : stopped ? "task-stop" : reason;
      return { ...current, lifecycle: "terminal", spend, wake: this.inbox.event(current),
        reportRef: report && entryId ? { resultId: report.resultId, sessionId: task.sessionId!, entryId, digest: reportDigest(report) } : null,
        terminalEvidence: { outcome: detached ? "unknown" : stopped ? "interrupted" : report?.outcome ?? "unknown", sessionId: task.sessionId, entryIds,
          reason: settledReason, ...(!stopped && failureCause ? { failureCause } : {}), ...(detail ? { detail: [...detail].slice(0, HOME_TASK_REFUSAL_DETAIL_CHARACTERS).join("") } : {}) } };
    });
    this.transition(final, final.terminalEvidence!.reason);
    await this.inbox.publish(task.taskId);
    return final;
  }

  private async reportEvidence(task: HomeTaskRecord, entries: readonly FileEntry[]): Promise<{ report: HomeTaskReport; entryId: string } | undefined> {
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

  async start(identity: { homeId: string; generation: number; routeGeneration: number }, request: HomeTaskDispatchRequest, signal?: AbortSignal, approval?: HomeTaskGrantApproval): Promise<HomeTaskHandle> {
    if (signal?.aborted) throw new HomeTaskDispatchStageError("choice", "cancelled");
    await this.assertAvailable();
    const registry = this.sessions.administrativeWorkRegistry;
    const work = registry.begin({ kind: "queued-mutation", hostEpoch: registry.runtimeEpoch });
    try { return await this.startOwned(identity, request, work, signal, approval); }
    catch (error) { work.settle(); throw error; }
  }

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
      if (error instanceof HomeTaskDispatchStageError) void step.then(value => abandon?.(value), () => {}).catch(() => {
        this.diagnostic?.({ event: "home.task.dispatch-stage", taskHash: hash(taskId), stage, outcome: "abandon-failed", durationMs: Date.now() - started });
      });
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

  private async refuseAdmission(task: Pick<HomeTaskRecord, "taskId">, reason: "admission-cancelled" | "admission-timeout"): Promise<void> {
    const final = await this.store.update(task.taskId, current => current.lifecycle === "terminal" ? current : {
      ...current, lifecycle: "terminal", wake: this.inbox.event(current),
      terminalEvidence: { outcome: "unknown", sessionId: current.sessionId, entryIds: [], reason } });
    this.transition(final, reason);
    await this.inbox.publish(final.taskId);
  }

  async resume(identity: { homeId: string; generation: number; routeGeneration: number }, request: HomeTaskResumeRequest,
    options: { signal?: AbortSignal; exceptWorkToken?: string; images?: ImageContent[]; approval?: HomeTaskGrantApproval } = {}): Promise<HomeTaskHandle & { operationId: string }> {
    const { signal } = options;
    if (signal?.aborted) throw new HomeTaskDispatchStageError("choice", "cancelled");
    await this.assertAvailable();
    const registry = this.sessions.administrativeWorkRegistry;
    const work = registry.begin({ kind: "queued-mutation", hostEpoch: registry.runtimeEpoch });
    try { return await this.resumeOwned(identity, request, work, options); }
    catch (error) { work.settle(); throw error; }
  }

  private async resumeOwned(identity: { homeId: string; generation: number; routeGeneration: number }, request: HomeTaskResumeRequest, work: GatewayWorkHandle,
    options: { signal?: AbortSignal; exceptWorkToken?: string; images?: ImageContent[]; approval?: HomeTaskGrantApproval }): Promise<HomeTaskHandle & { operationId: string }> {
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
    const budget = await this.stage("budget", taskId, signal, () => this.policy.budget());
    const entries = await this.sessions.readTaskEvidence(sessionId, { appendStable: true });
    const brief = resumeBrief(previous, instructions, interruptedQuestion(homeTaskOperationSpan(entries, previous.operationId!).run));
    const task = await this.create(taskId, signal, {
      version: 1, taskId, revision: 1, homeId: identity.homeId, generation: identity.generation, routeGeneration: identity.routeGeneration, wake: null,
      intent: { text: brief }, intentDigest: taskIntentDigest(brief), target: previous.target,
      grantRef: null, scopeRef: null, lifecycle: "pending", sessionId: null, operationId: null,
      stopIntent: null, spend: null, reportRef: null, terminalEvidence: null,
      ...(previous.checkins ? { checkins: previous.checkins } : {}),
      ...(previous.lastAttentionAt ? { lastAttentionAt: previous.lastAttentionAt } : {}),
      resumes: { taskId: previous.taskId, operationId: previous.operationId!, ...(text ? { instruction: text } : {}) },
      ...(budget && Object.keys(budget).length ? { budget } : {}),
    });
    this.transition(task, "created");
    let authority: Awaited<ReturnType<HomeTaskAuthorization["authorize"]>>;
    try {
      authority = await this.authorizeTask(task, epoch, signal, options.approval);
      if (epoch !== await this.stage("restore-epoch", taskId, signal, () => this.store.restoreEpoch())) throw new GatewayError("conflict", "Task namespace identity changed during admission");
    } catch (error) { await this.admissionFailed(task, error); throw error; }
    const operationId = `task-${randomUUID()}`;
    const handle = await this.admit({ task, authority, input: { taskId, intent: brief, target: task.target }, title: undefined, choice: {}, deferredThinking: undefined,
      resume: { sessionId, images: options.images ?? [], ...(options.exceptWorkToken ? { exceptWorkToken: options.exceptWorkToken } : {}) }, operationId }, work, signal);
    return { ...handle, sessionId, operationId };
  }

  private create(taskId: string, signal: AbortSignal | undefined, record: HomeTaskWrite): Promise<HomeTaskRecord> {
    return this.stage("create", taskId, signal, () => this.store.put(record, null).catch(async error => {
      if (error instanceof HomeTaskStoreError && error.code === "publication-uncertain") await this.admissionFailed(record, error).catch(() => {});
      throw error;
    }), created => { this.transition(created, "created"); void this.refuseAdmission(created, "admission-cancelled").catch(() => {}); });
  }

  private async authorizeTask(task: HomeTaskRecord, epoch: string, signal: AbortSignal | undefined, approval: HomeTaskGrantApproval | undefined) {
    const request = { intentDigest: task.intentDigest, target: task.target, authorizationScope: "full-work" as const, restoreEpoch: epoch };
    try { return await this.stage("authorize", task.taskId, signal, () => this.authorization.authorize(request)); }
    catch (error) {
      if (!(error instanceof HomeTaskAuthorizationError) || error.code !== "grant-required" || !error.requestId || !approval) throw error;
      const requestId = error.requestId;
      if ((await this.authorization.list()).decisions.some(decision => decision.requestId === requestId)) throw error;
      const grant = async (decisionId: string) => {
        await this.decideGrant(requestId, { decisionId, approved: true, expiresAt: Date.now() + HOME_TASK_GRANT_USE_MS });
        return this.authorization.authorize(request);
      };
      if ("maintainerCommand" in approval) return grant(approval.maintainerCommand);
      const brief = task.intent.text.replace(/\s+/gu, " ").trim();
      const review = changeReview({ subject: "home.task.grant", requestId }, { title: `Allow Home task ${task.taskId} once`, requiresTap: true,
        reason: "No standing scope covers this task; Home asks for one exact run.", items: [
          { label: "Task", before: "Not authorized", after: `One full-work run of ${task.taskId}`, exact: JSON.stringify({ requestId, intentDigest: task.intentDigest }) },
          { label: "Project", before: "No grant", after: task.target },
          { label: "Brief", before: "—", after: brief.length <= 400 ? brief : `${brief.slice(0, 399)}…`, detail: "The exact brief digest binds this tap." },
        ] });
      const authority = await approval.confirm(review, acceptance => grant(acceptance.commandId));
      if (!authority) throw new GatewayError("conflict", "The maintainer declined this task grant; nothing ran");
      return authority;
    }
  }

  private async startOwned(identity: { homeId: string; generation: number; routeGeneration: number }, request: HomeTaskDispatchRequest, work: GatewayWorkHandle, signal: AbortSignal | undefined, approval?: HomeTaskGrantApproval): Promise<HomeTaskHandle> {
    const input = structuredClone(request);
    const keys = Object.keys(input);
    if (!["taskId", "intent", "target"].every(key => keys.includes(key)) || keys.some(key => !["taskId", "intent", "target", "model", "thinking", "title", "reason", "provenance", "modelQueues"].includes(key))
      || typeof input.taskId !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$/u.test(input.taskId)
      || typeof input.intent !== "string" || !input.intent.trim() || Buffer.byteLength(input.intent) > 65536) throw new GatewayError("invalid_request", "Invalid task intent");
    const title = typeof input.title === "string" ? input.title.trim() : undefined;
    if (input.title !== undefined && (!title || [...title].length > HOME_TASK_TITLE_CHARACTERS)) throw new GatewayError("invalid_request", "Invalid task title");
    const deferredThinking = input.provenance && !input.model ? input.thinking : undefined;
    const taskId = input.taskId;
    const choice = await this.stage("choice", taskId, signal, () => this.policy.admitChoice(deferredThinking === undefined ? input : {}));
    const epoch = await this.stage("setup", taskId, signal, () => this.setup.run(async () => {
      const created = await this.store.initialize();
      const current = await this.store.restoreEpoch();
      if (created) await this.authorization.enableInitialScope(current);
      return current;
    }));
    if (await this.stage("lookup", taskId, signal, () => this.store.read(taskId))) throw new GatewayError("conflict", "Task already exists; accepted work is never replayed");
    const budget = await this.stage("budget", taskId, signal, () => this.policy.budget());
    const target = await this.stage("target", taskId, signal, () => this.policy.canonicalTarget(input.target));
    let task = await this.create(taskId, signal, {
      version: 1, taskId, revision: 1, homeId: identity.homeId, generation: identity.generation, routeGeneration: identity.routeGeneration, wake: null,
      intent: { text: input.intent }, intentDigest: taskIntentDigest(input.intent), target,
      grantRef: null, scopeRef: null, lifecycle: "pending", sessionId: null, operationId: null,
      stopIntent: null, spend: null, reportRef: null, terminalEvidence: null,
      ...(budget && Object.keys(budget).length ? { budget } : {}),
    });
    this.transition(task, "created");
    let authority: Awaited<ReturnType<HomeTaskAuthorization["authorize"]>>;
    try {
      authority = await this.authorizeTask(task, epoch, signal, approval);
      if (epoch !== await this.stage("restore-epoch", taskId, signal, () => this.store.restoreEpoch())) throw new GatewayError("conflict", "Task namespace identity changed during admission");
    } catch (error) { await this.admissionFailed(task, error); throw error; }
    return this.admit({ task, authority, input, title, choice, deferredThinking }, work, signal);
  }

  private async admit(launch: HomeTaskLaunch, work: GatewayWorkHandle, signal: AbortSignal | undefined): Promise<HomeTaskHandle> {
    this.running.add(launch.task.taskId);
    return this.launch(launch, work, signal);
  }

  private async launch(launch: HomeTaskLaunch, work: GatewayWorkHandle, signal: AbortSignal | undefined): Promise<HomeTaskHandle> {
    let { task } = launch;
    const { authority, input, title, choice, deferredThinking } = launch;
    const taskId = task.taskId;
    let lease: Awaited<ReturnType<SessionOperations["acquireOwnedSessionLease"]>> | undefined;
    let deadline: OwnedOperationDeadline | undefined;
    let admissionReport: HomeTaskReportOwner | undefined;
    const dispatch = this.sessions.delegation;
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
        if (accepted.attention === "requested") await this.inbox.publishAttention(saved.taskId).catch(() => {});
        return accepted;
      });
      admissionReport = reports;
      reports.limitBudget(async entries => {
        const current = await this.policy.budget().catch(() => undefined);
        const limit = (field: "inputTokens" | "outputTokens") => Math.min(task.budget?.[field] ?? Infinity, current?.[field] ?? Infinity);
        if (limit("inputTokens") === Infinity && limit("outputTokens") === Infinity) return false;
        const span = homeTaskOperationSpan(entries, operationId);
        if (span.index < 0) return false;
        let spend: HomeTaskSpend;
        try { spend = homeTaskSpend(span.run); } catch { return false; }
        return homeTaskPromptTokens(spend) >= limit("inputTokens") || spend.outputTokens >= limit("outputTokens");
      });
      const resume = launch.resume;
      lease = resume
        ? await this.stage("create-worker", taskId, signal, () => dispatch.resumeWorker(resume.sessionId, reports, resume.exceptWorkToken), late => dispatch.abandonWorker(late, reports))
        : await this.stage("create-worker", taskId, signal, () => dispatch.createWorker(task.target, reports), late => dispatch.abandonWorker(late, reports));
      const { slot } = lease;
      const appliedChoice = resume ? "" : await (async () => {
      const configured = await this.stage("configure-worker", taskId, signal, async () => {
      if (title) await slot.rename(title);
      await slot.setHomeTaskModelQueues(input.modelQueues ?? await this.policy.modelQueues());
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
      const appliedChoice = input.provenance
        ? `\n\nWorker at start: ${model ? `${model.provider}/${model.id}` : "worker default"}; thinking ${slot.snapshot().thinkingLevel}${clamped ? `; ${clamped}` : ""}.`
        : "";
      return appliedChoice;
      })();
      task = { ...task, revision: task.revision + 1, lifecycle: "active", sessionId: slot.id, operationId,
        grantRef: authority.kind === "one-use-grant" ? authority.grantId : null,
        scopeRef: authority.kind === "standing-scope" ? authority.scopeId : null };
      const bound = task;
      task = await this.stage("bind", taskId, signal, () => this.store.put(bound, bound.revision - 1),
        late => { this.transition(late, "operation-bound"); void this.refuseAdmission(late, "admission-cancelled").catch(() => {}); });
      this.transition(task, "operation-bound");
      this.commands.bind(slot.id, task.taskId);
      let resolve!: (terminal: OwnedOperationTerminal) => void;
      const terminal = new Promise<OwnedOperationTerminal>(done => { resolve = done; });
      const cancellation = async (reason = "interrupted") => {
        reports.cancel();
        await slot.ownedTurns.cancelHomeTaskOperation(operationId, reason);
      };
      deadline = dispatch.armDeadline();
      const bounded = dispatch.enforceDeadline({ operationId, completion: terminal, cancel: cancellation }, deadline);
      work.transition("foreground-agent-operation", slot.id);
      const admitted = slot.prompt(injectedText(`${task.intent.text}${appliedChoice}`, "tron-home", "brief", "task"), launch.resume?.images ?? [], undefined, undefined, undefined,
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
        const settled = await settleTaskSubagents(slot, operationId, deadline!.signal);
        await this.commands.settle(slot.id, active.taskId);
        const cut = await this.sessions.readLiveTaskEvidence(slot.id, operationId);
        const entries = cut.state === "present" ? cut.branch : [];
        const runEntries = homeTaskOperationSpan(entries, operationId).run;
        const evidence = cut.state === "present" ? await this.reportEvidence(active, cut.entries) : undefined;
        const report = evidence?.report;
        const last = runEntries.findLast(entry => entry.type === "message" && entry.message.role === "assistant");
        const lastMessage = last?.type === "message" && last.message.role === "assistant" ? last.message : undefined;
        const failureCause = report ? undefined : providerFailure(lastMessage);
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
        const interrupted = interruption !== undefined || (outcome.state === "terminal" && outcome.terminal.errorCode === TASK_STOP_WAITING);
        const stoppedBeforeConversation = cut.state === "absent";
        if (stoppedBeforeConversation && (!cut.operationSettled || !(await this.store.read(active.taskId))?.stopIntent || deadlineStopFailed || reportStopFailed || detached)) {
          throw new GatewayError("conflict", "Task canonical evidence is unavailable");
        }
        const final = await this.store.update(active.taskId, current => ({ ...current, lifecycle: "terminal", spend, wake: this.inbox.event(current),
          reportRef: report && evidence ? { resultId: report.resultId, sessionId: slot.id, entryId: evidence.entryId, digest: reportDigest(report) } : null,
          terminalEvidence: { outcome: stoppedBeforeConversation ? "interrupted" : detached || deadlineStopFailed || reportStopFailed ? "unknown" : report ? report.outcome : reports.budgetExceeded || deadlineStopped || lastMessage?.stopReason === "length" ? "limited" : interrupted && current.stopIntent ? "interrupted" : "unknown",
            sessionId: slot.id, entryIds: evidence ? [evidence.entryId] : [...(interruption ? [interruption.id] : []), ...(last ? [last.id] : [])],
            reason: stoppedBeforeConversation ? "stopped-before-conversation" : detached ? "detached-work-outlived-task" : deadlineStopFailed ? "deadline-stop-failed" : reportStopFailed ? current.stopIntent ? "task-stop-failed" : "report-stop-failed" : report ? "explicit-report" : reports.budgetExceeded ? "budget" : deadlineStopped ? "deadline" : lastMessage?.stopReason === "length" ? "length" : interrupted && current.stopIntent ? "task-stop" : "no-report",
            ...(failureCause && !current.stopIntent ? { failureCause } : {}) } }));
        this.transition(final, final.terminalEvidence!.reason);
        if (detached) this.diagnostic?.({ event: "home.task.detached-work", taskHash: hash(final.taskId), operationHash: hash(operationId), reason: "detached-work-outlived-task" });
        const subagents = cut.state === "present" ? homeTaskSubagentsProjection(entries, operationId) : { started: 0, stoppedAtEnd: 0 };
        this.diagnostic?.({ event: "home.task.subagents", taskHash: hash(final.taskId), operationHash: hash(operationId), started: subagents.started, stoppedAtEnd: subagents.stoppedAtEnd, noticesUndelivered: settled.noticesUndelivered });
        const spendReference = `${hash(final.taskId)}:${final.revision}`;
        this.diagnostic?.({ event: "home.task.spend", taskHash: hash(final.taskId), spendReference, ...spendCounters(spend) });
        if (outcome.state === "deadline-stopped" || outcome.state === "deadline-stop-failed") this.diagnostic?.({ event: "home.task.runaway-stop", taskHash: hash(final.taskId),
          operationHash: hash(operationId), elapsedMs: outcome.elapsedMs,
          cancelAndJoin: deadlineStopped ? "joined" : "failed", spendReference });
        await dispatch.acknowledge(slot.id, operationId, ownedLease);
        await this.inbox.publish(final.taskId);
        return (await this.store.read(final.taskId))!;
      })().catch(async (error: unknown) => {
        if ((await this.store.read(active.taskId))?.lifecycle === "terminal") { await this.commands.settle(slot.id, active.taskId); throw error; }
        const final = await this.reconcile(active, "live", error instanceof Error && error.message.trim() ? error.message.trim() : "settlement failed");
        await this.commands.settle(slot.id, active.taskId);
        await dispatch.acknowledge(slot.id, operationId, ownedLease).catch(() => {});
        return final;
      }).finally(() => { deadline!.disarm(); reports.retire(); ownedLease.release(); work.settle(); this.releaseSlot(taskId); });
      void completion.catch(() => {});
      return { taskId: task.taskId, sessionId: slot.id, operationId, completion };
    } catch (error) {
      deadline?.disarm();
      admissionReport?.retire();
      let failure = error;
      try {
        if (lease && admissionReport) await dispatch.abandonWorker(lease, admissionReport);
        else lease?.release();
      } catch (retirementError) {
        failure = new AggregateError([error, retirementError], "Task admission and worker retirement failed");
      }
      this.releaseSlot(taskId);
      await this.admissionFailed(task, error);
      throw failure;
    }
  }

  private async admissionFailed(task: Pick<HomeTaskRecord, "taskId">, error: unknown): Promise<void> {
    if (error instanceof HomeTaskDispatchStageError) {
      void this.refuseAdmission(task, error.outcome === "timeout" ? "admission-timeout" : "admission-cancelled")
        .catch(() => { });
      return;
    }
    const detail = error instanceof Error && error.message.trim() ? [...error.message.trim()].slice(0, HOME_TASK_REFUSAL_DETAIL_CHARACTERS).join("") : undefined;
    const final = await this.store.update(task.taskId, current => ({ ...current, lifecycle: "terminal", wake: this.inbox.event(current),
      terminalEvidence: { outcome: "unknown", sessionId: current.sessionId, entryIds: [], reason: "admission-refused", ...(detail ? { detail } : {}) } }));
    this.transition(final, "admission-refused", error instanceof GatewayError ? error.code : "internal");
    await this.inbox.publish(final.taskId);
  }

  private releaseSlot(taskId: string): void {
    this.running.delete(taskId);
  }

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

  async permissions() {
    await this.assertAvailable();
    const state = await this.authorization.list();
    const epoch = await this.store.restoreEpoch();
    return { ...state, needsReconfirmation: state.scopes.some(scope => scope.active && scope.restoreEpoch !== epoch) };
  }
  async revokeScope(scopeId: string) { await this.assertAvailable(); await this.authorization.revokeScope(scopeId); }
  async revokeGrant(grantId: string) { await this.assertAvailable(); await this.authorization.revokeGrant(grantId); }
  private async decideGrant(requestId: string, input: { decisionId: string; approved: boolean; expiresAt: number }) {
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

  async steer(control: TaskWorkerControl & { text: string }, from: "tron-home" | "maintainer" = "tron-home"): Promise<void> {
    await this.refusingControl("steer", control, async () => {
      const task = await this.activeControl(control);
      if (!this.running.has(task.taskId)) throw new GatewayError("conflict", "Task has no live worker; stop settles it");
      if (typeof control.text !== "string" || !control.text.trim() || Buffer.byteLength(control.text) > 65536) throw new GatewayError("invalid_request", "Invalid task steering text");
      await this.sessions.delegation.steerWorker(task.sessionId!, control, control.text, from);
    });
  }

  async interrupt(control: TaskWorkerControl & { text?: string }, by: string): Promise<{ interrupted: string[] }> {
    const interrupted = await this.refusingControl("interrupt", control, async () => {
      const task = await this.activeControl(control);
      if (!this.running.has(task.taskId)) throw new GatewayError("conflict", "Task has no live worker; stop settles it");
      if (control.text !== undefined && (typeof control.text !== "string" || !control.text.trim() || Buffer.byteLength(control.text) > 65536)) {
        throw new GatewayError("invalid_request", "Invalid task steering text");
      }
      return { taskId: task.taskId, interrupted: await this.sessions.delegation.interruptWorker(task.sessionId!, control, by, control.text) };
    });
    this.diagnostic?.({ event: "home.task.control", taskHash: hash(interrupted.taskId), operationHash: hash(control.operationId), action: "interrupt", disposition: "accepted", calls: interrupted.interrupted.length });
    return { interrupted: interrupted.interrupted };
  }

  async rename(task: HomeTaskRecord, title: string): Promise<{ title: string; previousTitle: string }> {
    const control = { taskId: task.taskId, ...(task.operationId === null ? {} : { operationId: task.operationId }) };
    const previousTitle = await (async () => {
      const name = title.replace(/[\r\n]+/g, " ").trim();
      if (!name || [...name].length > HOME_TASK_TITLE_CHARACTERS) {
        throw new GatewayError("invalid_request", `"title" must be 1 to ${HOME_TASK_TITLE_CHARACTERS} characters on one line`);
      }
      if (!task.sessionId) throw new GatewayError("conflict", "The task has not started a worker session yet; retry when status shows its sessionId", true);
      const previous = (await this.display(task)).title;
      await (await this.sessions.acquire(task.sessionId)).rename(name);
      return previous;
    })().catch(error => {
      if (error instanceof GatewayError) throw this.controlRefusal("rename", control, error);
      throw error;
    });
    this.diagnostic?.({ event: "home.task.control", taskHash: hash(task.taskId), operationHash: task.operationId === null ? null : hash(task.operationId), action: "rename", disposition: "accepted" });
    return { title: (await this.display(task)).title, previousTitle };
  }

  controlRefusal(action: "steer" | "interrupt" | "stop" | "rename", control: { taskId: string; operationId?: string }, error: GatewayError,
    reason: TaskControlRefusalReason = CONTROL_REFUSAL_REASONS.get(error.message) ?? error.code): GatewayError {
    this.diagnostic?.({ event: "home.task.control", taskHash: hash(control.taskId),
      ...(control.operationId === undefined ? {} : { operationHash: hash(control.operationId) }), action, disposition: "refused", reason });
    return error;
  }

  private async refusingControl<T>(action: "steer" | "interrupt" | "stop", control: TaskWorkerControl, admit: () => Promise<T>): Promise<T> {
    try {
      return await admit();
    } catch (error) {
      if (error instanceof GatewayError) throw this.controlRefusal(action, control, error);
      throw error;
    }
  }

  async latestTaskForSession(sessionId: string): Promise<HomeTaskRecord | undefined> {
    await this.assertAvailable();
    let latest: HomeTaskRecord | undefined;
    for await (const task of this.store.records()) {
      if (task.sessionId !== sessionId) continue;
      if (!latest || task.createdAt > latest.createdAt || (task.createdAt === latest.createdAt && task.resumes?.taskId === latest.taskId)) latest = task;
    }
    return latest;
  }

  async stop(control: TaskWorkerControl): Promise<void> {
    const task = await this.refusingControl("stop", control, () => this.activeControl(control));
    if (!this.running.has(task.taskId)) {
      const stopped = await this.refusingControl("stop", control, () => this.store.update(task.taskId, current => {
        if (current.lifecycle !== "active" || current.operationId !== control.operationId) throw new GatewayError("conflict", "Task operation changed before Stop");
        return current.stopIntent ? current : { ...current, stopIntent: { operationId: control.operationId, requestedAt: new Date().toISOString() } };
      }));
      this.diagnostic?.({ event: "home.task.control", taskHash: hash(task.taskId), operationHash: hash(control.operationId), action: "stop", disposition: "persisted" });
      await this.reconcile(stopped, "live");
      return;
    }
    await this.refusingControl("stop", control, () => this.sessions.delegation.stopWorker(task.sessionId!, control));
  }

  async controlRow(task: HomeTaskRecord, continuedAs?: string): Promise<HomeTaskControlRow> {
    const state: HomeTaskControlRow["state"] = task.lifecycle === "active" ? "running" : task.lifecycle === "terminal" ? "settled" : "starting";
    const actions: HomeTaskControlRow["actions"] = continuedAs ? ["status", "report"]
      : state === "running" ? ["status", "steer", "interrupt", "stop", "rename"]
      : state === "settled" ? ["status", "report", ...(task.sessionId ? ["resume" as const, "rename" as const] : [])] : ["status"];
    const evidence = task.terminalEvidence;
    return { taskId: task.taskId, title: (await this.display(task)).title, state, outcome: evidence?.outcome ?? null,
      ...(evidence ? { reason: evidence.reason } : {}), ...(evidence?.failureCause ? { failureCause: evidence.failureCause } : {}), ...(evidence?.detail ? { detail: evidence.detail } : {}),
      sessionId: task.sessionId, operationId: task.operationId, checkins: (task.checkins ?? []).slice(-HOME_TASK_CHECKIN_VISIBLE),
      ...(task.resumes ? { resumes: task.resumes.taskId } : {}),
      ...(continuedAs ? { continuedAs } : {}), updatedAt: new Date(task.updatedAt).toISOString(), actions };
  }

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

  private async activeControl(control: TaskWorkerControl): Promise<HomeTaskRecord> {
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

  private async ownerSettlement(task: HomeTaskRecord): Promise<HomeTaskOwnerSettlement | null> {
    if (task.lifecycle !== "terminal" || task.terminalEvidence?.outcome !== "unknown"
      || task.terminalEvidence.reason !== "no-report" || !task.sessionId || !task.operationId
      || task.terminalEvidence.sessionId !== task.sessionId) return null;
    try {
      const entries = await this.sessions.readTaskEvidence(task.sessionId, { appendStable: true });
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
      return null;
    }
  }

  async list(input: { limit?: number; cursor?: string; filter?: "all" | "open" | "finished" }, signal?: AbortSignal): Promise<HomeTaskPage> {
    const key = JSON.stringify([input.limit ?? null, input.cursor ?? null, input.filter ?? "all"]);
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

  activeTargets(signal?: AbortSignal): Promise<string[]> {
    return this.store.activeTargets(signal);
  }

  private async readList(input: { limit?: number; cursor?: string; filter?: "all" | "open" | "finished" }, signal: AbortSignal): Promise<HomeTaskPage> {
    const page = await this.store.page({ ...input, lineages: true }, signal);
    const items: HomeTaskSummary[] = [];
    for (const { task, pendingGrant } of page.items) {
      items.push({
        taskId: task.taskId, createdAt: task.createdAt, updatedAt: task.updatedAt, sessionId: task.sessionId, target: task.target,
        lifecycle: task.lifecycle, outcome: task.terminalEvidence?.outcome ?? null, spend: task.spend,
        attention: homeTaskNeedsAttention(task),
        checkins: (task.checkins ?? []).filter(checkin => checkin.operationId === task.operationId).slice(-HOME_TASK_CHECKIN_VISIBLE), pendingGrant, ...await this.display(task),
      });
    }
    return { items, counts: page.counts, ...(page.nextCursor ? { nextCursor: page.nextCursor } : {}) };
  }

  async history(input: { taskId: string; limit?: number; cursor?: string }, signal?: AbortSignal) {
    await this.assertAvailable();
    return readHomeTaskHistory(this.store, this.sessions, input, signal,
      summary => this.diagnostic?.({ event: "home.task.history-summary", ...summary }));
  }

  async display(task: HomeTaskRecord): Promise<HomeTaskDisplay> {
    const workerName = task.sessionId ? await this.sessions.taskWorkerName(task.sessionId) : undefined;
    return { title: homeTaskTitle(task.intent.text, workerName), project: basename(task.target) };
  }

  async liveSubagentRuns(task: HomeTaskRecord): Promise<HomeTaskSubagentRuns> {
    if (task.lifecycle !== "active" || !task.sessionId) return { total: 0, runs: [] };
    const runs = (await this.sessions.acquire(task.sessionId)).ownedTurns.liveSubagentRuns();
    const newestFirst = [...runs].sort((left, right) => Date.parse(right.startedAt) - Date.parse(left.startedAt));
    return { total: runs.length, runs: newestFirst.slice(0, HOME_TASK_STATUS_RUN_LIMIT) };
  }

  async subagents(task: HomeTaskRecord): Promise<HomeTaskSubagents> {
    if (task.sessionId && task.operationId) {
      const sessionId = task.sessionId;
      const operationId = task.operationId;
      return homeTaskSubagentsProjection(await this.sessions.readTaskWorkerEntries(sessionId), operationId);
    }
    return { started: 0, stoppedAtEnd: 0 };
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
        const spend = homeTaskSpend(homeTaskOperationSpan(slot.canonicalSessionEntries(), current.operationId!).run);
        return JSON.stringify(current.spend) === JSON.stringify(spend) ? current : { ...current, spend };
      });
      this.diagnostic?.({ event: "home.task.spend", taskHash: hash(task.taskId), spendReference: `${hash(task.taskId)}:${task.revision}`,
        ...spendCounters(task.spend) });
    }
    if (task.reportRef) {
      if (!task.sessionId || !task.operationId) throw new GatewayError("conflict", "Task evidence is missing");
      const entries = await this.sessions.readTaskEvidence(task.sessionId, { appendStable: true });
      const evidence = await this.reportEvidence(task, entries);
      const ref = task.reportRef;
      if (!evidence || evidence.entryId !== ref.entryId || evidence.report.resultId !== ref.resultId
        || evidence.report.sessionId !== ref.sessionId || reportDigest(evidence.report) !== ref.digest) throw new GatewayError("conflict", "Task report reference is missing or contradictory");
    }
    return task;
  }
  private transition(task: HomeTaskRecord, reason: string, errorCode?: string): void {
    this.diagnostic?.({ event: "home.task.transition", taskHash: hash(task.taskId), revision: task.revision,
      transition: task.lifecycle, reason, operationHash: task.operationId ? hash(task.operationId) : null, ...(errorCode ? { errorCode } : {}),
      ...(task.terminalEvidence?.failureCause ? { failureCause: task.terminalEvidence.failureCause } : {}) });
    if (task.sessionId) this.sessions.recordTaskWorkers([[task.sessionId, task.taskId]]);
    if (task.lifecycle === "terminal" && task.sessionId) {
      const sessionId = task.sessionId;
      void Promise.resolve().then(() => this.sessions.taskWorkerSettled(sessionId, task.taskId)).catch(() => {});
    }
  }
}

function spendCounters(spend: HomeTaskSpend | null): { inputTokens: number; cacheReadTokens: number; cacheWriteTokens: number; outputTokens: number } {
  return { inputTokens: spend?.inputTokens ?? 0, cacheReadTokens: spend?.cacheReadTokens ?? 0,
    cacheWriteTokens: spend?.cacheWriteTokens ?? 0, outputTokens: spend?.outputTokens ?? 0 };
}
