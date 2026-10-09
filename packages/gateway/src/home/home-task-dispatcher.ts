import { createHash, randomUUID } from "node:crypto";
import type { FileEntry } from "@earendil-works/pi-coding-agent";
import type { GatewayWorkHandle } from "../sessions/gateway-work-registry.js";
import type { RuntimeRegistry } from "../sessions/runtime-registry.js";
import type { OwnedOperationTerminal } from "../sessions/runtime-slot.js";
import { OwnedSessionDispatch } from "../sessions/owned-session-dispatch.js";
import { INVOCATION_RECEIPT_TYPE, parseInvocationReceipt } from "../sessions/invocation-receipts.js";
import { GatewayError } from "../errors.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { HomeTaskAuthorization, HomeTaskAuthorizationError, type HomeTaskAuthorizationDiagnostic } from "./home-task-authorization.js";
import { HomeTaskStore, HomeTaskStoreError, type HomeTaskRecord, type HomeTaskStoreDiagnostic, type HomeTaskStoreCode } from "./home-task-store.js";
import { homeTaskSpend } from "./home-task-spend.js";
import type { WakeInboxOwner, HomeWakeDiagnostic } from "./home-wake-inbox.js";
import { HOME_TASK_MARKER, HOME_TASK_REPORT, HomeTaskReportOwner, parseHomeTaskReport, type HomeTaskReport } from "./home-task-report.js";

export type HomeTaskDiagnostic =
  | HomeTaskAuthorizationDiagnostic
  | HomeTaskStoreDiagnostic
  | HomeWakeDiagnostic
  | { event: "home.task.producer-refused"; taskHash: string; reason: import("./home-task-worker-extension.js").HomeTaskProducerRefusal }
  | { event: "home.task.detached-work"; taskHash: string; operationHash: string; reason: "detached-work-outlived-task" }
  | { event: "home.task.transition"; taskHash: string; revision: number; transition: HomeTaskRecord["lifecycle"]; reason: string; operationHash: string | null }
  | { event: "home.task.spend"; taskHash: string; spendReference: string; inputTokens: number; outputTokens: number; unpriced: true }
  | { event: "home.task.control"; taskHash: string; operationHash: string; action: "steer" | "stop"; disposition: "accepted" | "persisted"; controllerGeneration: number }
  | { event: "home.task.runaway-stop"; taskHash: string; operationHash: string; elapsedMs: number; cancelAndJoin: "joined" | "failed"; spendReference: string };
export type HomeTaskRecoveryStatus = { available: true } | { available: false; reason: HomeTaskStoreCode | "not-started" };
export interface HomeTaskDispatchRequest { taskId: string; intent: string; target: string }
export interface HomeTaskControlRequest { taskId: string; operationId: string; controllerGeneration: number }
export interface HomeTaskHandle { taskId: string; sessionId: string; operationId: string; completion: Promise<HomeTaskRecord> }
const reportDigest = (value: unknown) => createHash("sha256").update(JSON.stringify(value)).digest("hex");
const hash = (value: string) => createHash("sha256").update(value).digest("hex").slice(0, 16);

/** Installation capability owner. Each dispatch closure, not a parallel ID map,
 * owns its lease, cancellation signal, terminal promise and report lifetime. */
export class HomeTaskDispatcher {
  private readonly setup = new AsyncMutex();
  private recovery: Promise<HomeTaskRecoveryStatus> | undefined;
  constructor(readonly store: HomeTaskStore, readonly authorization: HomeTaskAuthorization,
    private readonly sessions: RuntimeRegistry, private readonly diagnostic: ((record: HomeTaskDiagnostic) => void) | undefined,
    private readonly inbox: WakeInboxOwner) {}

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
    for await (const task of this.store.records()) {
      if (task.lifecycle === "terminal" && task.wake?.push !== "pending") continue;
      if (task.lifecycle !== "terminal") {
        let report: HomeTaskReport | undefined;
        let entryId: string | undefined;
        let spend = task.spend;
        let entryIds: string[] = [];
        let reason = "cold-no-report";
        if (task.lifecycle === "active" && task.sessionId && task.operationId) {
          try {
            const entries = await this.sessions.readTaskEvidence(task.sessionId);
            const evidence = await this.reportEvidence(task, entries);
            report = evidence?.report; entryId = evidence?.entryId;
            const marker = entries.findIndex(entry => entry.type === "custom" && entry.customType === HOME_TASK_MARKER);
            const runEntries = entries.slice(marker + 1);
            const observed = homeTaskSpend(runEntries);
            if (spend && (observed.inputTokens < spend.inputTokens || observed.outputTokens < spend.outputTokens)) throw new Error("Canonical spend regressed");
            spend = observed;
            const last = runEntries.findLast(entry => entry.type === "message" && entry.message.role === "assistant");
            entryIds = entryId ? [entryId] : last ? [last.id] : [];
            if (report) reason = "cold-explicit-report";
          } catch (error) {
            // Namespace refusal is not missing report evidence: retire this
            // process's capability instead of attempting a terminal write.
            if (error instanceof HomeTaskStoreError) throw error;
            // Contradictory or unproven bytes cannot qualify a result. Retain
            // already published spend/authority; never repair or replay work.
            report = undefined; entryId = undefined; entryIds = []; reason = "cold-evidence-unavailable";
          }
        }
        const final = await this.store.update(task.taskId, current => ({ ...current, lifecycle: "terminal", spend,
          wake: this.inbox.event(current),
          reportRefs: report && entryId ? [{ resultId: report.resultId, sessionId: task.sessionId!, entryId, digest: reportDigest(report) }] : null,
          terminalEvidence: { outcome: report?.outcome ?? "unknown", sessionId: task.sessionId, entryIds, reason } }));
        this.transition(final, reason);
      }
      // Includes a crash after terminal/outbox co-commit but before advisory
      // publication. The inbox's durable decision makes repeats harmless.
      await this.inbox.publish(task.taskId);
    }
  }

  private async reportEvidence(task: HomeTaskRecord, entries: readonly FileEntry[]): Promise<{ report: HomeTaskReport; entryId: string } | undefined> {
    const markers = entries.filter(entry => entry.type === "custom" && entry.customType === HOME_TASK_MARKER);
    if (markers.length !== 1 || markers[0]?.type !== "custom" || !task.sessionId) throw new GatewayError("conflict", "Task marker is missing or contradictory");
    await this.validateMarkerEvidence(task.sessionId, markers[0].data);
    const reports = entries.filter(entry => entry.type === "custom" && entry.customType === HOME_TASK_REPORT);
    if (reports.length > 1) throw new GatewayError("conflict", "Conflicting canonical task reports");
    const entry = reports[0];
    if (!entry || entry.type !== "custom") return undefined;
    const report = parseHomeTaskReport(entry.data);
    if (entries.indexOf(entry) <= entries.indexOf(markers[0]) || report.taskId !== task.taskId || report.intentRevision !== task.intent.revision
      || report.homeId !== task.homeId || report.generation !== task.generation || report.operationId !== task.operationId || report.sessionId !== task.sessionId) throw new GatewayError("conflict", "Task report reference is contradictory");
    return { report, entryId: entry.id };
  }

  async start(identity: { homeId: string; generation: number; routeGeneration: number }, request: HomeTaskDispatchRequest): Promise<HomeTaskHandle> {
    await this.assertAvailable();
    const registry = this.sessions.administrativeWorkRegistry;
    const work = registry.begin({ kind: "queued-mutation", hostEpoch: registry.runtimeEpoch });
    try {
      const handle = await this.startOwned(identity, request, work);
      const completion = handle.completion.finally(() => work.settle());
      void completion.catch(() => {});
      return { ...handle, completion };
    } catch (error) { work.settle(); throw error; }
  }

  private async startOwned(identity: { homeId: string; generation: number; routeGeneration: number }, request: HomeTaskDispatchRequest, work: GatewayWorkHandle): Promise<HomeTaskHandle> {
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
    let task = await this.store.put({
      version: 1, taskId: input.taskId, revision: 1, homeId: identity.homeId, generation: identity.generation, routeGeneration: identity.routeGeneration, wake: null,
      intent: { revision: 1, text: input.intent }, intentDigest: createHash("sha256").update(JSON.stringify({ revision: 1, text: input.intent })).digest("hex"),
      target: await this.sessions.canonicalTaskTarget(input.target), workerProfile: "home-task-v1", policyRevision: 1,
      grantRef: null, scopeRef: null, lifecycle: "pending", sessionId: null, operationId: null, controllerGeneration: null,
      stopIntent: null, spend: null, reportRefs: null, terminalEvidence: null,
    }, null);
    this.transition(task, "created");
    let lease: Awaited<ReturnType<OwnedSessionDispatch["createWorker"]>> | undefined;
    try {
      const authority = await this.authorization.authorize({ intentRevision: task.intent.revision, intentDigest: task.intentDigest,
        target: task.target, authorizationScope: "full-work", workerProfile: task.workerProfile, policyRevision: task.policyRevision, restoreEpoch: epoch });
      if (epoch !== await this.store.restoreEpoch()) throw new GatewayError("conflict", "Task namespace identity changed during admission");
      const operationId = `task-${randomUUID()}`;
      const reports = new HomeTaskReportOwner({ taskId: task.taskId, intentRevision: task.intent.revision, homeId: task.homeId, generation: task.generation, operationId }, async () => {
        await this.store.update(task.taskId, current => {
          if (current.lifecycle !== "active" || current.operationId !== operationId || current.controllerGeneration !== 1) throw new GatewayError("conflict", "Task operation changed before Stop");
          return current.stopIntent ? current : { ...current, stopIntent: { operationId, controllerGeneration: 1, requestedAt: new Date().toISOString() } };
        });
        this.diagnostic?.({ event: "home.task.control", taskHash: hash(task.taskId), operationHash: hash(operationId), action: "stop", disposition: "persisted", controllerGeneration: 1 });
        await cancellation("task-stop");
      });
      const dispatch = new OwnedSessionDispatch(this.sessions);
      // Trust is rechecked by the neutral creation/admission boundary too.
      lease = await dispatch.createWorker(task.target, reports);
      const { slot } = lease;
      task = { ...task, revision: task.revision + 1, lifecycle: "active", sessionId: slot.id, operationId,
        controllerGeneration: 1, grantRef: authority.kind === "one-use-grant" ? authority.grantId : null,
        scopeRef: authority.kind === "standing-scope" ? authority.scopeId : null };
      task = await this.store.put(task, task.revision - 1);
      this.transition(task, "operation-bound");
      let resolve!: (terminal: OwnedOperationTerminal) => void;
      const terminal = new Promise<OwnedOperationTerminal>(done => { resolve = done; });
      const cancellation = async (reason = "interrupted") => {
        reports.cancel();
        await slot.cancelHomeTaskOperation(operationId, reason);
      };
      let deadlineDiagnostic: { operationHash: string; elapsedMs: number; cancelAndJoin: "joined" | "failed" } | undefined;
      const deadline = new OwnedSessionDispatch(this.sessions, { diagnostic: record => { deadlineDiagnostic = record; } });
      // Arm before the first asynchronous prompt preflight; cancellation never
      // queues behind the lane whose blocked admission it must interrupt.
      const bounded = deadline.enforceDeadline({ operationId, completion: terminal, cancel: cancellation });
      work.transition("foreground-agent-operation");
      const admitted = dispatch.admit(slot, `${task.intent.text}\n\nThis is a finite Home task. Use report with explicit evidence to finish. A normal reply is not a task result.`, [], undefined, undefined, undefined,
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
        // Share cold recovery's durable file cut before publishing any terminal
        // references/outbox or acknowledging the operation. SDK append visibility
        // alone cannot guarantee the worker evidence survives a power loss.
        const cut = await this.sessions.readLiveTaskEvidence(slot.id, operationId);
        // Spend and last-reply evidence remain selected-branch projections;
        // immutable report addresses are qualified across the durable file.
        const entries = cut.state === "present" ? cut.branch : [];
        const markerIndex = entries.findIndex(entry => entry.type === "custom" && entry.customType === HOME_TASK_MARKER
          && (entry.data as { operationId?: string }).operationId === operationId);
        const runEntries = markerIndex < 0 ? [] : entries.slice(markerIndex + 1);
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
              && receipt.operationId === operationId && receipt.invocationId === outcome.terminal.invocationId && receipt.sessionId === slot.id;
          });
        const interrupted = interruption !== undefined;
        // Stop intent is append-only. Qualify before entering the store update:
        // missing proof is not namespace corruption or a publication attempt.
        const stoppedBeforeConversation = cut.state === "absent";
        if (stoppedBeforeConversation && (!cut.operationSettled || !(await this.store.read(active.taskId))?.stopIntent || deadlineStopFailed || reportStopFailed || detached)) {
          throw new GatewayError("conflict", "Task canonical evidence is unavailable");
        }
        const final = await this.store.update(active.taskId, current => ({ ...current, lifecycle: "terminal", spend, wake: this.inbox.event(current),
          reportRefs: report && evidence ? [{ resultId: report.resultId, sessionId: slot.id, entryId: evidence.entryId, digest: reportDigest(report) }] : null,
          terminalEvidence: { outcome: stoppedBeforeConversation ? "interrupted" : detached || deadlineStopFailed || reportStopFailed ? "unknown" : report ? report.outcome : deadlineStopped || lastMessage?.stopReason === "length" ? "limited" : interrupted && current.stopIntent ? "interrupted" : "unknown",
            sessionId: slot.id, entryIds: evidence ? [evidence.entryId] : [...(interruption ? [interruption.id] : []), ...(last ? [last.id] : [])],
            reason: stoppedBeforeConversation ? "stopped-before-conversation" : detached ? "detached-work-outlived-task" : deadlineStopFailed ? "deadline-stop-failed" : reportStopFailed ? current.stopIntent ? "task-stop-failed" : "report-stop-failed" : report ? "explicit-report" : deadlineStopped ? "deadline" : lastMessage?.stopReason === "length" ? "length" : interrupted && current.stopIntent ? "task-stop" : "no-report" } }));
        this.transition(final, final.terminalEvidence!.reason);
        if (detached) this.diagnostic?.({ event: "home.task.detached-work", taskHash: hash(final.taskId), operationHash: hash(operationId), reason: "detached-work-outlived-task" });
        const spendReference = `${hash(final.taskId)}:${final.revision}`;
        this.diagnostic?.({ event: "home.task.spend", taskHash: hash(final.taskId), spendReference,
          inputTokens: spend.inputTokens, outputTokens: spend.outputTokens, unpriced: true });
        if (deadlineDiagnostic) this.diagnostic?.({ event: "home.task.runaway-stop", taskHash: hash(final.taskId),
          operationHash: deadlineDiagnostic.operationHash, elapsedMs: deadlineDiagnostic.elapsedMs,
          cancelAndJoin: deadlineDiagnostic.cancelAndJoin, spendReference });
        await dispatch.acknowledge(slot.id, operationId, ownedLease);
        await this.inbox.publish(final.taskId);
        return (await this.store.read(final.taskId))!;
      })().finally(() => { reports.retire(); ownedLease.release(); });
      // Tool callers return admission immediately, but failures remain observed.
      void completion.catch(() => {});
      return { taskId: task.taskId, sessionId: slot.id, operationId, completion };
    } catch (error) {
      lease?.release();
      // Accepted identity remains durable and cannot be used for prompt replay.
      const final: HomeTaskRecord = { ...task, revision: task.revision + 1, lifecycle: "terminal", wake: this.inbox.event(task),
        terminalEvidence: { outcome: "unknown", sessionId: task.sessionId, entryIds: [], reason: "admission-refused" } };
      await this.store.put(final, task.revision);
      this.transition(final, "admission-refused");
      await this.inbox.publish(final.taskId);
      throw error;
    }
  }

  async validateWorkerMarker(sessionId: string, marker: unknown): Promise<void> {
    await this.assertAvailable();
    await this.validateMarkerEvidence(sessionId, marker);
  }

  private async validateMarkerEvidence(sessionId: string, marker: unknown): Promise<void> {
    const value = marker as Record<string, unknown>;
    if (!value || Object.keys(value).sort().join(",") !== "generation,homeId,intentRevision,operationId,receiptId,sessionId,taskId,version"
      || value.version !== 1 || typeof value.taskId !== "string" || value.sessionId !== sessionId) throw new GatewayError("conflict", "Invalid task marker");
    const task = await this.store.read(value.taskId);
    if (!task || task.sessionId !== sessionId || task.operationId !== value.operationId || task.intent.revision !== value.intentRevision
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
    if (typeof control.text !== "string" || !control.text.trim() || Buffer.byteLength(control.text) > 65536) throw new GatewayError("invalid_request", "Invalid task steering text");
    const slot = await this.sessions.acquire(task.sessionId!);
    await slot.steerHomeTask(control, control.text);
  }

  async stop(control: HomeTaskControlRequest): Promise<void> {
    const task = await this.activeControl(control);
    // No session mutation lane here: Stop must be able to cancel its admission.
    await (await this.sessions.acquire(task.sessionId!)).stopHomeTask(control);
  }

  private async activeControl(control: HomeTaskControlRequest): Promise<HomeTaskRecord> {
    await this.assertAvailable();
    const task = await this.store.read(control.taskId);
    if (!task || task.lifecycle !== "active" || !task.sessionId || task.operationId !== control.operationId || task.controllerGeneration !== control.controllerGeneration) throw new GatewayError("conflict", "Stale or terminal task operation");
    return task;
  }

  async result(taskId: string): Promise<HomeTaskRecord> {
    await this.assertAvailable();
    let task = await this.store.read(taskId);
    if (!task) throw new GatewayError("conflict", "Referenced task is missing");
    if (task.lifecycle === "active" && task.sessionId && task.operationId) {
      const slot = await this.sessions.acquire(task.sessionId);
      task = await this.store.update(taskId, current => {
        if (current.lifecycle !== "active") return current;
        // Read canonical deltas while this publication owns the store mutex;
        // an older status read cannot replace a newer usage projection.
        const entries = slot.canonicalSessionEntries();
        const marker = entries.findIndex(entry => entry.type === "custom" && entry.customType === HOME_TASK_MARKER
          && (entry.data as { operationId?: string }).operationId === current.operationId);
        const spend = homeTaskSpend(marker < 0 ? [] : entries.slice(marker + 1));
        return JSON.stringify(current.spend) === JSON.stringify(spend) ? current : { ...current, spend };
      });
      this.diagnostic?.({ event: "home.task.spend", taskHash: hash(task.taskId), spendReference: `${hash(task.taskId)}:${task.revision}`,
        inputTokens: task.spend?.inputTokens ?? 0, outputTokens: task.spend?.outputTokens ?? 0, unpriced: true });
    }
    if (task.reportRefs?.length) {
      if (!task.sessionId || !task.operationId) throw new GatewayError("conflict", "Task evidence is missing");
      const entries = await this.sessions.readTaskEvidence(task.sessionId);
      const evidence = await this.reportEvidence(task, entries);
      const ref = task.reportRefs[0]!;
      if (!evidence || task.reportRefs.length !== 1 || evidence.entryId !== ref.entryId || evidence.report.resultId !== ref.resultId
        || evidence.report.sessionId !== ref.sessionId || reportDigest(evidence.report) !== ref.digest) throw new GatewayError("conflict", "Task report reference is missing or contradictory");
    }
    return task;
  }
  private transition(task: HomeTaskRecord, reason: string): void {
    this.diagnostic?.({ event: "home.task.transition", taskHash: hash(task.taskId), revision: task.revision,
      transition: task.lifecycle, reason, operationHash: task.operationId ? hash(task.operationId) : null });
  }
}
