import type { ExtensionArtifactDiscoveryOutcome } from "../../sessions/extension-artifact-discovery.js";
import { GatewayError } from "../../errors.js";
import { HOME_TASK_MARKER, type HomeTaskReportOwner } from "./task-report.js";
import { TASK_STOP_WAITING, type OwnedOperationTerminal } from "./owned-operation-terminal.js";
import type { TaskWorkerControl } from "./worker-contract.js";
import { controlSubagentRun } from "./subagent-control.js";
import { createHash } from "node:crypto";
import { DELEGATED_PROVIDER_TOOL_NAME, delegatedArtifactPathAllowed, delegatedProviderOrigin, isInstalledDelegatedTool, trustedDelegatedController } from "./delegated-provider.js";
import { realpathSync, watch, type FSWatcher } from "node:fs";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import { type ToolDefinition } from "../pi/coding-agent.js";
import type { HomeTaskSubagentRun } from "./task-subagents.js";
import type { ExtensionRunActivity, ExtensionToolOrigin } from "../../protocol/types.js";
import { safeJson } from "../projection/projection.js";
import { extensionActivityId, terminalLifecycleStates, type ExtensionArtifactRejectionReason } from "../projection/extension-run-projection.js";
import { subagentAbortRoute } from "../projection/process-activity.js";
import { type OwnedTurnRuntime, type ArtifactReceiptOwner } from "./owned-turn-runtime.js";
import { SubagentArtifactStatus, WORKFLOW_CHILD_ARTIFACT_DIRECTORIES } from "./subagent-artifact-status.js";
import { refreshSubagentActivityFromArtifact, refreshExtensionActivityFromArtifact } from "./subagent-artifact-reconcile.js";
import { liveActivitySubagentRuns, extensionActivityOwnsLiveWork, upsertExtensionActivity, canonicalExtensionRunFacts, publishExtensionActivity } from "./subagent-activity.js";

const EXTENSION_ARTIFACT_MISSING_GRACE_MS = 30_000;

export class OwnedTurnOwner {
  readonly extensionActivities = new Map<string, ExtensionRunActivity>();

  readonly extensionActivitySequences = new Map<string, number>();

  liveActivityRevision = 0;

  extensionActivityAsOf = new Date().toISOString();

  readonly extensionRunOwnership = new Map<string, {
    toolCallId: string;
    asyncDir?: string;
    terminal: boolean;
    pausedProcessQuiescentAt?: string;
    detachedChildKeys?: ReadonlyMap<string, string>;
  }>();

  readonly extensionActivityWatchers = new Map<string, {
    watcher: FSWatcher;
    children: Map<string, FSWatcher>;
    onChange: (eventType: string, filename: string | Buffer | null) => void;
    timer: NodeJS.Timeout | undefined;
    asyncDir: string;
    readRetries: number;
    bindingRetries: number;
  }>();

  readonly extensionActivityReadGenerations = new Map<string, number>();

  readonly extensionActivityPublishedReads = new Map<string, number>();

  private extensionArtifactReadTickets = 0;

  private readonly extensionArtifactReadsInFlight = new Set<number>();

  readonly extensionArtifactMissingSince = new Map<string, number>();

  readonly extensionArtifactWarnings = new Map<string, number>();

  readonly extensionReceiptWrites = new Map<string, Promise<void>>();

  readonly extensionReceiptOwners = new Map<string, ArtifactReceiptOwner>();
  readonly artifacts = new SubagentArtifactStatus(this);

  worker: HomeTaskReportOwner | undefined;
  readonly observers = new Map<string, (terminal: OwnedOperationTerminal) => Promise<void> | void>();
  waitingTask: { observer: (terminal: OwnedOperationTerminal) => Promise<void> | void; terminal: OwnedOperationTerminal; wakeOperationId?: string } | undefined;

  constructor(readonly operations: OwnedTurnRuntime) {}

  async bindWorker(report: HomeTaskReportOwner, exceptWorkToken?: string): Promise<void> {
    await this.operations.lane.run(async () => {
      this.operations.assertUsable();
      this.operations.assertChapterWritable();
      const blocking = this.operations.dependencies.workRegistry.sessionWorkKinds(this.operations.id, exceptWorkToken);
      const drain = this.operations.administrativeDrainBlockers().map(fact => fact.category);
      if (this.operations.runtime.session.isStreaming || blocking.length || drain.length) {
        throw new GatewayError("busy", `The worker session is busy (${[...new Set([...blocking, ...drain])].join(", ") || "streaming"}); resume it when that finishes`, true);
      }
      if (this.operations.liveProfile().chapter || this.operations.dependencies.sessionLineage().state(this.operations.id).lineageId) {
        throw new GatewayError("conflict", "A Home chapter cannot run a task");
      }
      if (this.worker?.controlsActive || this.waitingTask || this.operations.activeOperationId !== undefined || this.operations.operation !== undefined
        || this.operations.catalogHasActiveSubagents || this.operations.isAgentAdmissionSettling) {
        throw new GatewayError("conflict", "The worker session is still running; stop it before resuming");
      }
      const markers = this.operations.canonicalTaskEvidence().filter(entry => entry.type === "custom" && entry.customType === HOME_TASK_MARKER);
      if (!markers.length) throw new GatewayError("conflict", "Only a Home task worker session can resume a task");
      const work = this.operations.dependencies.workRegistry.begin({
        kind: "administrative-provider-package-operation",
        sessionId: this.operations.id,
        hostEpoch: this.operations.ui.hostEpoch,
      });
      try {
        const previous = this.worker;
        this.worker = report;
        try { await this.operations.replaceRuntime(); }
        catch (error) { this.worker = previous; throw error; }
        this.operations.revision += 1;
        this.operations.emit("session.resourcesChanged", {});
        this.operations.publishSnapshot();
      } finally {
        work.settle();
      }
    });
  }

  async releaseUnadmittedWorker(report: HomeTaskReportOwner): Promise<void> {
    report.retire();
    await this.operations.lane.run(async () => {
      if (this.worker !== report) return;
      this.worker = undefined;
      if (this.operations.disposed) return;
      this.operations.assertUsable();
      await this.operations.replaceRuntime();
      this.operations.revision += 1;
      this.operations.emit("session.resourcesChanged", {});
      this.operations.publishSnapshot();
    });
  }

  async notifyOwnedTerminal(terminal: OwnedOperationTerminal): Promise<void> {
    const own = this.observers.get(terminal.operationId);
    const wake = this.waitingTask?.wakeOperationId === terminal.operationId ? this.waitingTask.observer : undefined;
    const observer = wake ?? own;
    if (!observer) return;
    this.observers.delete(terminal.operationId);
    if (wake && own) await own(terminal);
    if (this.worker && (terminal.operationId === this.worker.identity.operationId || this.waitingTask?.wakeOperationId === terminal.operationId)) {
      if (this.taskTurnAwaitsWake(terminal)) {
        this.waitingTask = { observer, terminal };
        return;
      }
      this.waitingTask = undefined;
    }
    await observer(terminal);
  }

  sharedTaskSteering(ownership: { readonly taskFence?: TaskWorkerControl } | undefined): boolean {
    if (!this.worker) return false;
    if (!ownership) return true;
    const fence = ownership.taskFence;
    return !!fence && fence.taskId === this.worker.identity.taskId && fence.operationId === this.worker.identity.operationId;
  }

  taskTurnOperationId(operationId: string): string {
    return this.waitingTask?.wakeOperationId === operationId && this.worker ? this.worker.identity.operationId : operationId;
  }

  liveTaskOperationId(): string | undefined {
    return this.operations.activeOperationId === undefined ? undefined : this.taskTurnOperationId(this.operations.activeOperationId);
  }

  private taskTurnAwaitsWake(terminal: OwnedOperationTerminal): boolean {
    if (terminal.lifecycle !== "completed" || !this.worker?.acceptsSteering) return false;
    const last = this.operations.sessionManager.getBranch().findLast(entry => entry.type === "message" && entry.message.role === "assistant");
    return last?.type === "message" && last.message.role === "assistant" && last.message.stopReason === "stop"
      && this.operations.hasDetachedDashboardWork();
  }

  async releaseWaitingTaskForDrain(): Promise<void> {
    if (!this.waitingTask || this.waitingTask.wakeOperationId !== undefined || this.operations.hasDetachedDashboardWork()) return;
    const { observer, terminal } = this.waitingTask;
    this.waitingTask = undefined;
    await observer(terminal);
  }

  async cancelHomeTaskOperation(operationId: string, reason: string): Promise<void> {
    if (!this.worker || this.worker.identity.operationId !== operationId) throw new GatewayError("conflict", "Task cancellation owner changed");
    if (this.waitingTask && this.waitingTask.wakeOperationId === undefined) {
      const { observer, terminal } = this.waitingTask;
      this.waitingTask = undefined;
      await observer({ lifecycle: "interrupted", operationId, invocationId: terminal.invocationId, errorCode: TASK_STOP_WAITING });
      return;
    }
    const turnOperationId = this.waitingTask?.wakeOperationId ?? operationId;
    if (this.operations.activeOperationId !== turnOperationId && this.operations.operation?.id !== turnOperationId) return;
    await this.operations.abort("agent", turnOperationId, reason);
  }



  asyncStopTargets(): string[] {
    return this.liveExtensionActivities().flatMap(activity => {
      const binding = activity.runId === undefined ? undefined : this.extensionRunOwnership.get(activity.runId);
      return binding?.asyncDir === undefined ? [] : liveActivitySubagentRuns(this, activity).map(run => run.runId);
    });
  }


  liveSubagentRuns(): HomeTaskSubagentRun[] {
    return this.liveExtensionActivities().flatMap(activity => liveActivitySubagentRuns(this, activity));
  }


  liveExtensionActivities(): ExtensionRunActivity[] {
    return [...this.extensionActivities.values()].filter(activity => extensionActivityOwnsLiveWork(this, activity));
  }


  extensionArtifactPathAllowed(asyncPath: string): boolean {
    return delegatedArtifactPathAllowed(asyncPath, this.operations.cwd, this.operations.dependencies.delegatedArtifactRoot);
  }


  subagentExtensionOrigin(): ExtensionToolOrigin {
    return delegatedProviderOrigin(this.operations.runtime?.session.resourceLoader.getExtensions().extensions ?? []);
  }


  isForegroundSubagentTool(toolName: string, origin: ExtensionToolOrigin | undefined): boolean {
    return isInstalledDelegatedTool(toolName, origin, this.subagentExtensionOrigin().owner?.id);
  }


  trustedSubagentController(): ToolDefinition | undefined {
    const session = this.operations.runtime?.session;
    if (!session) return undefined;
    return trustedDelegatedController({
      toolName: DELEGATED_PROVIDER_TOOL_NAME,
      origin: this.operations.extensionToolOrigin(DELEGATED_PROVIDER_TOOL_NAME),
      installedOwnerId: this.subagentExtensionOrigin().owner?.id,
      definitionFor: (name: string) => session.extensionRunner.getToolDefinition(name),
    });
  }


  extensionAmbientArtifactAttribution(): ReadonlySet<string> {
    const attributed = new Set<string>();
    const addDirectory = (asyncDir: string): void => {
      attributed.add(resolve(asyncDir));
      try { attributed.add(realpathSync(asyncDir)); } catch { }
    };
    for (const [runId, binding] of this.extensionRunOwnership) {
      attributed.add(runId);
      if (binding.asyncDir) addDirectory(binding.asyncDir);
    }
    for (const [runId, fact] of canonicalExtensionRunFacts(this)) {
      attributed.add(runId);
      if (fact.asyncDir) addDirectory(fact.asyncDir);
    }
    for (const activity of this.extensionActivities.values()) {
      if (activity.runId) attributed.add(activity.runId);
    }
    return attributed;
  }


  ownedExtensionArtifactDirectories(): string[] {
    const terminalStates = new Set(["completed", "failed", "stopped", "rejected"]);
    const candidates: Array<{ directory: string; updatedAt: string }> = [];
    for (const binding of this.extensionRunOwnership.values()) {
      if (binding.terminal || !binding.asyncDir) continue;
      const activity = this.extensionActivities.get(binding.toolCallId);
      if (activity?.lifecycle && terminalStates.has(activity.lifecycle.state)) continue;
      const directory = this.canonicalExtensionArtifactDirectory(binding.asyncDir)
        ?? (this.extensionArtifactPathAllowed(resolve(binding.asyncDir)) ? resolve(binding.asyncDir) : undefined);
      if (directory) candidates.push({ directory, updatedAt: activity?.updatedAt ?? "" });
    }
    candidates.sort((left, right) => left.updatedAt.localeCompare(right.updatedAt)
      || left.directory.localeCompare(right.directory));
    return [...new Set(candidates.map((candidate) => candidate.directory))].slice(0, 64);
  }


  extensionArtifactOwnerForDirectory(directory: string): string | undefined {
    for (const [runId, binding] of this.extensionRunOwnership) {
      if (!binding.asyncDir) continue;
      const owned = this.canonicalExtensionArtifactDirectory(binding.asyncDir);
      if (owned === directory) return `${runId}\0${binding.toolCallId}`;
    }
    return undefined;
  }


  warnExtensionArtifact(reason: ExtensionArtifactRejectionReason, owner: string): void {
    if (!this.operations.dependencies.extensionArtifactWarning) return;
    const opaqueOwner = createHash("sha256").update(`${this.operations.id}\0${owner}`).digest("hex").slice(0, 24);
    const key = `${opaqueOwner}:${reason}`;
    const now = Date.now();
    const previous = this.extensionArtifactWarnings.get(key);
    if (previous !== undefined && now - previous < 60_000) return;
    this.extensionArtifactWarnings.delete(key);
    this.extensionArtifactWarnings.set(key, now);
    while (this.extensionArtifactWarnings.size > 256) {
      const oldest = this.extensionArtifactWarnings.keys().next().value as string | undefined;
      if (!oldest) break;
      this.extensionArtifactWarnings.delete(oldest);
    }
    this.operations.dependencies.extensionArtifactWarning({ reason, owner: opaqueOwner });
  }


  observeMissingExtensionArtifact(toolCallId: string): void {
    const now = Date.now();
    const missingSince = this.extensionArtifactMissingSince.get(toolCallId);
    if (missingSince === undefined) {
      this.extensionArtifactMissingSince.set(toolCallId, now);
      return;
    }
    if (now - missingSince < EXTENSION_ARTIFACT_MISSING_GRACE_MS) return;
    const previous = this.extensionActivities.get(toolCallId);
    if (!previous || previous.lifecycle && terminalLifecycleStates.has(previous.lifecycle.state)
      || previous.lifecycle?.state === "unknown") return;
    const activityKey = previous.activityId
      ?? extensionActivityId(this.operations.runtime.session.sessionManager.getSessionId(), toolCallId);
    const sequence = (this.extensionActivitySequences.get(activityKey)
      ?? previous.lifecycle?.sequence ?? 0) + 1;
    this.extensionActivitySequences.set(activityKey, sequence);
    const observedAt = new Date().toISOString();
    const unavailable: ExtensionRunActivity = {
      ...previous,
      updatedAt: observedAt,
      lifecycle: {
        version: 1,
        state: "unknown",
        attention: "none",
        sequence,
        observedAt,
      },
    };
    this.extensionActivities.set(toolCallId, unavailable);
    upsertExtensionActivity(this, unavailable);
    publishExtensionActivity(this, unavailable);
    this.stopExtensionActivityWatcher(toolCallId);
  }


  discoverExtensionArtifact(asyncDir: string): Promise<ExtensionArtifactDiscoveryOutcome> {
    return refreshSubagentActivityFromArtifact(this, asyncDir);
  }


  async reconcileLiveExtensionArtifacts(): Promise<void> {
    for (const activity of this.liveExtensionActivities()) {
      const binding = activity.runId ? this.extensionRunOwnership.get(activity.runId) : undefined;
      if (binding?.asyncDir) {
        await refreshExtensionActivityFromArtifact(this, binding.toolCallId, binding.asyncDir);
      }
    }
  }

  async reconcileOwnedExtensionArtifactsForDrain(): Promise<void> {
    if (this.operations.runAttention.completionOwnershipQueue.length > 0 && !this.operations.runAttention.attentionBarrier) {
      await this.operations.runAttention.drainCompletionOwnership().catch(() => {
        this.operations.emit("session.diagnostic", safeJson({
          code: "canonical-completion-persistence-retrying",
          message: "Canonical completion persistence is retrying",
        }));
      });
    }
    const canonicalFacts = canonicalExtensionRunFacts(this);
    for (const asyncDir of this.ownedExtensionArtifactDirectories()) {
      await refreshSubagentActivityFromArtifact(this, asyncDir, canonicalFacts);
    }
    await this.operations.runWork.reconcileOrphanedForegroundWorkForDrain();
  }


  syncWorkflowChildArtifactWatchers(toolCallId: string, value: Record<string, unknown>): void {
    const tracked = this.extensionActivityWatchers.get(toolCallId);
    if (!tracked) return;
    const directories = (value as Record<PropertyKey, unknown>)[WORKFLOW_CHILD_ARTIFACT_DIRECTORIES];
    const next = new Set(Array.isArray(directories) ? directories as string[] : []);
    for (const [directory, watcher] of tracked.children) if (!next.has(directory)) {
      watcher.close();
      tracked.children.delete(directory);
    }
    for (const directory of next) if (!tracked.children.has(directory)) {
      try {
        const childName = basename(directory);
        const watcher = watch(dirname(directory), { recursive: true }, (eventType, filename) => {
          const path = filename?.toString();
          if (path === undefined || path === childName || path === join(childName, "status.json")
            || path === join(childName, "process-terminal.json")) {
            tracked.onChange(eventType, "status.json");
          }
        });
        watcher.on("error", () => tracked.onChange("change", "status.json"));
        tracked.children.set(directory, watcher);
        tracked.onChange("change", "status.json");
      } catch {
      }
    }
  }


  beginExtensionArtifactRead(toolCallId?: string): number {
    const ticket = ++this.extensionArtifactReadTickets;
    if (toolCallId !== undefined) this.extensionActivityReadGenerations.set(toolCallId, ticket);
    this.extensionArtifactReadsInFlight.add(ticket);
    return ticket;
  }


  finishExtensionArtifactRead(ticket: number): void {
    this.extensionArtifactReadsInFlight.delete(ticket);
    this.pruneExtensionArtifactReadTickets();
  }


  extensionArtifactReadSuperseded(toolCallId: string, ticket: number): boolean {
    return (this.extensionActivityPublishedReads.get(toolCallId) ?? 0) > ticket;
  }


  recordPublishedExtensionArtifactRead(toolCallId: string, ticket: number): void {
    this.extensionActivityPublishedReads.set(toolCallId, ticket);
  }


  forgetExtensionArtifactReads(toolCallId: string): void {
    this.extensionActivityReadGenerations.delete(toolCallId);
    this.pruneExtensionArtifactReadTickets();
  }


  private pruneExtensionArtifactReadTickets(): void {
    let oldestInFlight = Infinity;
    for (const ticket of this.extensionArtifactReadsInFlight) oldestInFlight = Math.min(oldestInFlight, ticket);
    for (const [toolCallId, published] of this.extensionActivityPublishedReads) {
      if (published < oldestInFlight && !this.extensionActivities.has(toolCallId)) {
        this.extensionActivityPublishedReads.delete(toolCallId);
      }
    }
  }


  stopExtensionActivityWatcher(toolCallId: string): void {
    this.extensionActivityReadGenerations.set(toolCallId, ++this.extensionArtifactReadTickets);
    const tracked = this.extensionActivityWatchers.get(toolCallId);
    if (!tracked) return;
    if (tracked.timer) clearTimeout(tracked.timer);
    tracked.watcher.close();
    for (const watcher of tracked.children.values()) watcher.close();
    this.extensionActivityWatchers.delete(toolCallId);
  }


  clearExtensionActivityWatchers(): void {
    for (const toolCallId of this.extensionActivityWatchers.keys()) this.stopExtensionActivityWatcher(toolCallId);
    this.extensionActivityReadGenerations.clear();
  }


  canonicalExtensionArtifactDirectory(asyncDir: string): string | undefined {
    if (!isAbsolute(asyncDir) || !this.extensionArtifactPathAllowed(asyncDir)) return undefined;
    try {
      const realAsyncDir = realpathSync(asyncDir);
      return this.extensionArtifactPathAllowed(realAsyncDir) ? realAsyncDir : undefined;
    } catch {
      return undefined;
    }
  }


  bindExtensionRunOwnership(
    runId: string,
    binding: { toolCallId: string; asyncDir?: string; terminal: boolean; pausedProcessQuiescentAt?: string; detachedChildKeys?: ReadonlyMap<string, string> },
  ): boolean {
    const existing = this.extensionRunOwnership.get(runId);
    if (existing && existing.toolCallId !== binding.toolCallId) {
      if (!existing.toolCallId.startsWith("subagent:") || binding.toolCallId.startsWith("subagent:")) return false;
    }
    const asyncDir = existing?.asyncDir ?? binding.asyncDir;
    const detachedChildKeys = binding.detachedChildKeys ?? existing?.detachedChildKeys;
    this.extensionRunOwnership.set(runId, {
      toolCallId: binding.toolCallId,
      ...(asyncDir ? { asyncDir } : {}),
      terminal: Boolean(existing?.terminal || binding.terminal),
      ...(binding.pausedProcessQuiescentAt
        ? { pausedProcessQuiescentAt: binding.pausedProcessQuiescentAt }
        : {}),
      ...(detachedChildKeys ? { detachedChildKeys } : {}),
    });
    return true;
  }


  scheduleExtensionBindingRetry(toolCallId: string, asyncDir: string): void {
    const tracked = this.extensionActivityWatchers.get(toolCallId);
    if (!tracked || tracked.asyncDir !== asyncDir || tracked.timer || tracked.bindingRetries >= 4) return;
    tracked.bindingRetries += 1;
    tracked.timer = setTimeout(() => {
      tracked.timer = undefined;
      void refreshExtensionActivityFromArtifact(this, toolCallId, asyncDir);
    }, tracked.bindingRetries * 150);
    tracked.timer.unref();
  }


  startExtensionActivityWatcher(toolCallId: string, asyncDir: string): void {
    if (!this.extensionArtifactPathAllowed(asyncDir)) return;
    let realAsyncDir: string;
    try {
      realAsyncDir = realpathSync(asyncDir);
    } catch {
      return;
    }
    if (!this.extensionArtifactPathAllowed(realAsyncDir)) return;
    const existing = this.extensionActivityWatchers.get(toolCallId);
    if (existing?.asyncDir === realAsyncDir) {
      void refreshExtensionActivityFromArtifact(this, toolCallId, realAsyncDir);
      return;
    }
    this.stopExtensionActivityWatcher(toolCallId);
    try {
      const onChange = (_eventType: string, filename: string | Buffer | null) => {
        if (filename !== null && filename.toString() !== "status.json") return;
        const tracked = this.extensionActivityWatchers.get(toolCallId);
        if (!tracked) return;
        if (tracked.timer) clearTimeout(tracked.timer);
        tracked.readRetries = 0;
        tracked.bindingRetries = 0;
        tracked.timer = setTimeout(() => {
          tracked.timer = undefined;
          void refreshExtensionActivityFromArtifact(this, toolCallId, realAsyncDir);
        }, 50);
        tracked.timer.unref();
      };
      const watcher = watch(realAsyncDir, onChange);
      watcher.on("error", () => this.stopExtensionActivityWatcher(toolCallId));
      this.extensionActivityWatchers.set(toolCallId, {
        watcher,
        children: new Map(),
        onChange,
        timer: undefined,
        asyncDir: realAsyncDir,
        readRetries: 0,
        bindingRetries: 0,
      });
      void refreshExtensionActivityFromArtifact(this, toolCallId, realAsyncDir);
    } catch {
    }
  }


  claimExtensionReceiptOwnership(activityId: string): ArtifactReceiptOwner | undefined {
    const existing = this.extensionReceiptOwners.get(activityId);
    if (existing) return existing;
    try {
      const owner = this.operations.dependencies.workRegistry.beginDerived({
        kind: "terminal-receipt-persistence",
        sessionId: this.operations.id,
        hostEpoch: this.operations.ui.hostEpoch,
      });
      this.extensionReceiptOwners.set(activityId, owner);
      return owner;
    } catch {
      return undefined;
    }
  }


  releaseExtensionReceiptOwnership(activityId: string, owner?: ArtifactReceiptOwner): void {
    if (!owner || this.extensionReceiptOwners.get(activityId) !== owner) return;
    this.extensionReceiptOwners.delete(activityId);
    owner.settle();
  }


  processSubagentAbortAuthority(
    processId: string,
    expectedRunId: string,
  ): { expectedOperationId?: string } | undefined {
    this.operations.assertNoTrustReload();
    const tool = this.trustedSubagentController();
    const capturedOperationId = this.operations.processOperationIDs.get(processId);
    const currentOperationId = capturedOperationId === this.operations.operation?.id
      ? capturedOperationId
      : undefined;
    const route = subagentAbortRoute(
      this.operations.processActivities.get(processId),
      this.operations.processChildSessionBinding(processId),
      expectedRunId,
      currentOperationId,
      tool !== undefined,
    );
    return route?.kind === "foreground"
      ? { expectedOperationId: route.expectedOperationId }
      : route ? {} : undefined;
  }


  async abortSubagentProcess(
    processId: string,
    expectedRunId: string,
    expectedOperationId?: string,
  ): Promise<void> {
    const tool = this.trustedSubagentController();
    const capturedOperationId = this.operations.processOperationIDs.get(processId);
    const currentOperationId = capturedOperationId === this.operations.operation?.id
      ? capturedOperationId
      : undefined;
    const route = subagentAbortRoute(
      this.operations.processActivities.get(processId),
      this.operations.processChildSessionBinding(processId),
      expectedRunId,
      currentOperationId,
      tool !== undefined,
    );
    if (!route) {
      throw new GatewayError("conflict", "The subagent execution changed before it could be stopped", true);
    }

    if (route.kind === "foreground") {
      if (!expectedOperationId || route.expectedOperationId !== expectedOperationId) {
        throw new GatewayError("conflict", "The foreground operation changed before it could be stopped", true);
      }
      await this.operations.abort("agent", expectedOperationId);
      return;
    }

    if (!tool) throw new GatewayError("unsupported", "The installed subagent controller is unavailable");
    await controlSubagentRun(this.operations.runtime.session, tool, { action: "stop", id: route.runId, childId: route.childId });
  }


  async ownsSubagentRun(runId: string): Promise<boolean> {
    const facts = canonicalExtensionRunFacts(this);
    if (facts.has(runId)) return true;
    for (const fact of facts.values()) {
      const directory = fact.asyncDir === undefined ? undefined : this.canonicalExtensionArtifactDirectory(fact.asyncDir);
      if (directory === undefined) continue;
      const status = await this.artifacts.readExtensionStatusArtifact(directory, false).catch(() => undefined);
      if (status?.mode === "workflow" && Array.isArray(status.steps)
        && status.steps.some(step => (step as { runId?: unknown } | null)?.runId === runId)) return true;
    }
    return false;
  }


  async ownsSupervisorRequest(requestId: string): Promise<boolean> {
    const request = this.operations.sessionManager.getBranch().findLast(entry => entry.type === "custom_message"
      && entry.customType === "subagent_supervisor_request" && (entry.details as { requestId?: unknown } | undefined)?.requestId === requestId);
    const runId = request?.type === "custom_message" ? (request.details as { runId?: unknown } | undefined)?.runId : undefined;
    return typeof runId === "string" && await this.ownsSubagentRun(runId);
  }
  async reconcileProcessChildSessionBinding(processId: string): Promise<void> {
    if (this.operations.processChildSessionBinding(processId)) return;
    const process = this.operations.processActivities.get(processId);
    if (!process || process.kind !== "subagent" || !process.runId || !process.toolCallId) return;
    const ownership = this.extensionRunOwnership.get(process.runId);
    if (!ownership?.asyncDir || ownership.toolCallId !== process.toolCallId) return;
    const asyncDir = this.canonicalExtensionArtifactDirectory(ownership.asyncDir);
    if (!asyncDir) return;
    await refreshExtensionActivityFromArtifact(this, ownership.toolCallId, asyncDir);
  }

  resetArtifactBranch(): void {
    this.clearExtensionActivityWatchers();
    this.extensionActivities.clear();
    this.extensionActivitySequences.clear();
    this.extensionRunOwnership.clear();
    this.pruneExtensionArtifactReadTickets();
  }

  retireArtifactWatches(): void {
    this.clearExtensionActivityWatchers();
    this.extensionArtifactMissingSince.clear();
    this.extensionRunOwnership.clear();
  }
}
