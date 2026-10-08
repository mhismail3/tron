import { createHash, randomUUID } from "node:crypto";
import type { GatewayWorkHandle } from "../sessions/gateway-work-registry.js";
import type { RuntimeRegistry } from "../sessions/runtime-registry.js";
import type { OwnedOperationTerminal } from "../sessions/runtime-slot.js";
import { OwnedSessionDispatch } from "../sessions/owned-session-dispatch.js";
import { GatewayError } from "../errors.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { HomeTaskAuthorization, type HomeTaskAuthorizationDiagnostic } from "./home-task-authorization.js";
import { HomeTaskStore, type HomeTaskRecord, type HomeTaskStoreDiagnostic } from "./home-task-store.js";
import { HOME_TASK_MARKER, HOME_TASK_REPORT, HomeTaskReportOwner, type HomeTaskReport } from "./home-task-report.js";

export type HomeTaskDiagnostic =
  | HomeTaskAuthorizationDiagnostic
  | HomeTaskStoreDiagnostic
  | { event: "home.task.producer-refused"; taskHash: string; reason: import("./home-task-worker-extension.js").HomeTaskProducerRefusal }
  | { event: "home.task.detached-work"; taskHash: string; operationHash: string; reason: "detached-work-outlived-task" }
  | { event: "home.task.transition"; taskHash: string; revision: number; transition: HomeTaskRecord["lifecycle"]; reason: string; operationHash: string | null }
  | { event: "home.task.spend"; taskHash: string; spendReference: string; inputTokens: number; outputTokens: number; unpriced: true }
  | { event: "home.task.runaway-stop"; taskHash: string; operationHash: string; elapsedMs: number; cancelAndJoin: "joined" | "failed"; spendReference: string };
export interface HomeTaskDispatchRequest { taskId: string; intent: string; target: string }
export interface HomeTaskHandle { taskId: string; sessionId: string; operationId: string; completion: Promise<HomeTaskRecord> }
const reportDigest = (value: unknown) => createHash("sha256").update(JSON.stringify(value)).digest("hex");
const hash = (value: string) => createHash("sha256").update(value).digest("hex").slice(0, 16);

/** Installation capability owner. Each dispatch closure, not a parallel ID map,
 * owns its lease, cancellation signal, terminal promise and report lifetime. */
export class HomeTaskDispatcher {
  private readonly setup = new AsyncMutex();
  constructor(readonly store: HomeTaskStore, readonly authorization: HomeTaskAuthorization,
    private readonly sessions: RuntimeRegistry, private readonly diagnostic?: (record: HomeTaskDiagnostic) => void) {}

  async start(identity: { homeId: string; generation: number }, request: HomeTaskDispatchRequest): Promise<HomeTaskHandle> {
    const registry = this.sessions.administrativeWorkRegistry;
    const work = registry.begin({ kind: "queued-mutation", hostEpoch: registry.runtimeEpoch });
    try {
      const handle = await this.startOwned(identity, request, work);
      const completion = handle.completion.finally(() => work.settle());
      void completion.catch(() => {});
      return { ...handle, completion };
    } catch (error) { work.settle(); throw error; }
  }

  private async startOwned(identity: { homeId: string; generation: number }, request: HomeTaskDispatchRequest, work: GatewayWorkHandle): Promise<HomeTaskHandle> {
    const input = structuredClone(request);
    if (Object.keys(input).sort().join(",") !== "intent,target,taskId"
      || typeof input.taskId !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$/u.test(input.taskId)
      || typeof input.intent !== "string" || !input.intent.trim() || Buffer.byteLength(input.intent) > 65536) throw new GatewayError("invalid_request", "Invalid task intent");
    const epoch = await this.setup.run(async () => {
      const created = await this.store.initialize();
      const current = await this.store.restoreEpoch();
      if (created) await this.authorization.enableInitialScope(current);
      return current;
    });
    if (await this.store.read(input.taskId)) throw new GatewayError("conflict", "Task already exists; accepted work is never replayed");
    let task: HomeTaskRecord = {
      version: 1, taskId: input.taskId, revision: 1, homeId: identity.homeId, generation: identity.generation,
      intent: { revision: 1, text: input.intent }, intentDigest: createHash("sha256").update(JSON.stringify({ revision: 1, text: input.intent })).digest("hex"),
      target: await this.sessions.canonicalTaskTarget(input.target), workerProfile: "home-task-v1", policyRevision: 1,
      grantRef: null, scopeRef: null, lifecycle: "pending", sessionId: null, operationId: null, controllerGeneration: null,
      spend: null, reportRefs: null, terminalEvidence: null,
    };
    await this.store.put(task, null);
    this.transition(task, "created");
    let lease: Awaited<ReturnType<OwnedSessionDispatch["createWorker"]>> | undefined;
    try {
      const authority = await this.authorization.authorize({ intentRevision: task.intent.revision, intentDigest: task.intentDigest,
        target: task.target, authorizationScope: "full-work", workerProfile: task.workerProfile, policyRevision: task.policyRevision, restoreEpoch: epoch });
      if (epoch !== await this.store.restoreEpoch()) throw new GatewayError("conflict", "Task namespace identity changed during admission");
      const operationId = `task-${randomUUID()}`;
      const reports = new HomeTaskReportOwner({ taskId: task.taskId, intentRevision: task.intent.revision, homeId: task.homeId, generation: task.generation, operationId });
      const dispatch = new OwnedSessionDispatch(this.sessions);
      // Trust is rechecked by the neutral creation/admission boundary too.
      lease = await dispatch.createWorker(task.target, reports);
      const { slot } = lease;
      task = { ...task, revision: task.revision + 1, lifecycle: "active", sessionId: slot.id, operationId,
        controllerGeneration: 1, grantRef: authority.kind === "one-use-grant" ? authority.grantId : null,
        scopeRef: authority.kind === "standing-scope" ? authority.scopeId : null };
      await this.store.put(task, task.revision - 1);
      this.transition(task, "operation-bound");
      let resolve!: (terminal: OwnedOperationTerminal) => void;
      const terminal = new Promise<OwnedOperationTerminal>(done => { resolve = done; });
      const signal = new AbortController();
      const cancellation = async (reason = "interrupted") => {
        signal.abort();
        if (slot.snapshot().operation?.id === operationId) await slot.abort("agent", operationId, reason);
      };
      let deadlineDiagnostic: { operationHash: string; elapsedMs: number; cancelAndJoin: "joined" | "failed" } | undefined;
      const deadline = new OwnedSessionDispatch(this.sessions, { diagnostic: record => { deadlineDiagnostic = record; } });
      // Arm before the first asynchronous prompt preflight; cancellation never
      // queues behind the lane whose blocked admission it must interrupt.
      const bounded = deadline.enforceDeadline({ operationId, completion: terminal, cancel: cancellation });
      work.transition("foreground-agent-operation");
      const admitted = dispatch.admit(slot, `${task.intent.text}\n\nThis is a finite Home task. Use report with explicit evidence to finish. A normal reply is not a task result.`, [], undefined, undefined, undefined,
        { operationId, signal: signal.signal, origin: { kind: "gateway", ownerId: task.taskId, title: "Home task", confidence: "boundary" }, onTerminal: resolve });
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
        // A report is canonical append evidence; generic completed is not final.
        const entries = slot.canonicalSessionEntries();
        const markerIndex = entries.findIndex(entry => entry.type === "custom" && entry.customType === HOME_TASK_MARKER
          && (entry.data as { operationId?: string }).operationId === operationId);
        if (markerIndex >= 0) await this.validateWorkerMarker(slot.id, (entries[markerIndex] as { data: unknown }).data);
        const runEntries = markerIndex < 0 ? [] : entries.slice(markerIndex + 1);
        const reportEntries = runEntries.filter(entry => entry.type === "custom" && entry.customType === HOME_TASK_REPORT);
        if (reportEntries.length > 1) throw new GatewayError("conflict", "Conflicting canonical task reports");
        const reportEntry = reportEntries[0];
        const report = reportEntry?.type === "custom" ? reportEntry.data as HomeTaskReport : undefined;
        if (report && (report.taskId !== active.taskId || report.intentRevision !== active.intent.revision || report.homeId !== active.homeId
          || report.generation !== active.generation || report.operationId !== operationId || report.sessionId !== slot.id)) throw new GatewayError("conflict", "Task report reference is contradictory");
        const last = runEntries.findLast(entry => entry.type === "message" && entry.message.role === "assistant");
        const lastMessage = last?.type === "message" && last.message.role === "assistant" ? last.message : undefined;
        const deadlineStopped = outcome.state === "deadline-stopped";
        const detached = slot.catalogHasActiveSubagents;
        const spend: NonNullable<HomeTaskRecord["spend"]> = { inputTokens: 0, outputTokens: 0, knownCostUSD: null, pricingProvenance: null, unpriced: true };
        for (const entry of runEntries) {
          if (entry.type !== "message" || entry.message.role !== "assistant") continue;
          const usage = entry.message.usage;
          spend.inputTokens += usage.input + usage.cacheRead + usage.cacheWrite;
          spend.outputTokens += usage.output;
        }
        const final: HomeTaskRecord = { ...active, revision: active.revision + 1, lifecycle: "terminal", spend,
          reportRefs: report && reportEntry ? [{ resultId: report.resultId, sessionId: slot.id, entryId: reportEntry.id, digest: reportDigest(report) }] : null,
          terminalEvidence: { outcome: detached || deadlineStopFailed || reportStopFailed ? "unknown" : report ? report.outcome : deadlineStopped || lastMessage?.stopReason === "length" ? "limited" : "unknown",
            sessionId: slot.id, entryIds: reportEntry ? [reportEntry.id] : last ? [last.id] : [],
            reason: detached ? "detached-work-outlived-task" : deadlineStopFailed ? "deadline-stop-failed" : reportStopFailed ? "report-stop-failed" : report ? "explicit-report" : deadlineStopped ? "deadline" : lastMessage?.stopReason === "length" ? "length" : "no-report" } };
        // Exact task existence/CAS and report identity are checked before commit.
        if (!await this.store.read(active.taskId)) throw new GatewayError("conflict", "Referenced task is missing");
        await this.store.put(final, active.revision);
        this.transition(final, final.terminalEvidence!.reason);
        if (detached) this.diagnostic?.({ event: "home.task.detached-work", taskHash: hash(final.taskId), operationHash: hash(operationId), reason: "detached-work-outlived-task" });
        const spendReference = `${hash(final.taskId)}:${final.revision}`;
        this.diagnostic?.({ event: "home.task.spend", taskHash: hash(final.taskId), spendReference,
          inputTokens: spend.inputTokens, outputTokens: spend.outputTokens, unpriced: true });
        if (deadlineDiagnostic) this.diagnostic?.({ event: "home.task.runaway-stop", taskHash: hash(final.taskId),
          operationHash: deadlineDiagnostic.operationHash, elapsedMs: deadlineDiagnostic.elapsedMs,
          cancelAndJoin: deadlineDiagnostic.cancelAndJoin, spendReference });
        await dispatch.acknowledge(slot.id, operationId, ownedLease);
        return final;
      })().finally(() => ownedLease.release());
      // Tool callers return admission immediately, but failures remain observed.
      void completion.catch(() => {});
      return { taskId: task.taskId, sessionId: slot.id, operationId, completion };
    } catch (error) {
      lease?.release();
      // Accepted identity remains durable and cannot be used for prompt replay.
      const final: HomeTaskRecord = { ...task, revision: task.revision + 1, lifecycle: "terminal",
        terminalEvidence: { outcome: "unknown", sessionId: task.sessionId, entryIds: [], reason: "admission-refused" } };
      await this.store.put(final, task.revision);
      this.transition(final, "admission-refused");
      throw error;
    }
  }

  async validateWorkerMarker(sessionId: string, marker: unknown): Promise<void> {
    const value = marker as Record<string, unknown>;
    if (!value || Object.keys(value).sort().join(",") !== "generation,homeId,intentRevision,operationId,receiptId,sessionId,taskId,version"
      || value.version !== 1 || typeof value.taskId !== "string" || value.sessionId !== sessionId) throw new GatewayError("conflict", "Invalid task marker");
    const task = await this.store.read(value.taskId);
    if (!task || task.sessionId !== sessionId || task.operationId !== value.operationId || task.intent.revision !== value.intentRevision
      || task.homeId !== value.homeId || task.generation !== value.generation || value.receiptId !== `task:${task.operationId}`) throw new GatewayError("conflict", "Referenced task is missing or contradictory");
  }

  async result(taskId: string): Promise<HomeTaskRecord> {
    const task = await this.store.read(taskId);
    if (!task) throw new GatewayError("conflict", "Referenced task is missing");
    if (task.reportRefs?.length) {
      if (!task.sessionId || !task.operationId) throw new GatewayError("conflict", "Task evidence is missing");
      const entries = (await this.sessions.acquire(task.sessionId)).canonicalTaskEvidence();
      const markers = entries.filter(entry => entry.type === "custom" && entry.customType === HOME_TASK_MARKER);
      if (markers.length !== 1 || markers[0]?.type !== "custom") throw new GatewayError("conflict", "Task marker is missing or contradictory");
      await this.validateWorkerMarker(task.sessionId, markers[0].data);
      for (const ref of task.reportRefs) {
        const entry = entries.find(candidate => candidate.id === ref.entryId);
        const report = entry?.type === "custom" && entry.customType === HOME_TASK_REPORT ? entry.data as HomeTaskReport : undefined;
        if (!report || reportDigest(report) !== ref.digest || report.taskId !== taskId || report.resultId !== ref.resultId || report.sessionId !== ref.sessionId
          || report.operationId !== task.operationId || report.intentRevision !== task.intent.revision || report.homeId !== task.homeId || report.generation !== task.generation) throw new GatewayError("conflict", "Task report reference is missing or contradictory");
      }
    }
    return task;
  }
  private transition(task: HomeTaskRecord, reason: string): void {
    this.diagnostic?.({ event: "home.task.transition", taskHash: hash(task.taskId), revision: task.revision,
      transition: task.lifecycle, reason, operationHash: task.operationId ? hash(task.operationId) : null });
  }
}
