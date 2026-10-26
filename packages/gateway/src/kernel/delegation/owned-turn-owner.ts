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
  /** K5 owns run/lifecycle admission. Native invocation rows are SDK progress
   * projections; this bounded view also retains completed work for Manage Session. */
  readonly extensionActivities = new Map<string, ExtensionRunActivity>();

  /** Monotonic lifecycle projection ordering and terminal latches are runtime
   * facts; producer timestamps are display evidence only. */
  readonly extensionActivitySequences = new Map<string, number>();

  liveActivityRevision = 0;

  extensionActivityAsOf = new Date().toISOString();

  /** Gateway-owned correlation keeps one activity identity across Pi lifecycle
   * payloads and independently-written async artifacts. */
  readonly extensionRunOwnership = new Map<string, {
    toolCallId: string;
    asyncDir?: string;
    terminal: boolean;
    /** Gateway-observed instant of this run's paused process-terminal proof;
     * absent while the run owns live processes or is not paused. */
    pausedProcessQuiescentAt?: string;
    /** Exact detached child run IDs by workflow key, excluding admitted paused
     * exit proofs. Status and Stop consume this same artifact-frame binding. */
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

  readonly extensionArtifactMissingSince = new Map<string, number>();

  readonly extensionArtifactWarnings = new Map<string, number>();

  readonly extensionReceiptWrites = new Map<string, Promise<void>>();

  readonly extensionReceiptOwners = new Map<string, ArtifactReceiptOwner>();
  readonly artifacts = new SubagentArtifactStatus(this);

  /** The live report-owner binding. Creation seeds it once; only an idle rebind replaces it. */
  worker: HomeTaskReportOwner | undefined;
  readonly observers = new Map<string, (terminal: OwnedOperationTerminal) => Promise<void> | void>();
  /** A task worker's operation between turns: its last turn ended with live owned runs and no
   * report, so the dispatcher's observer is held here instead of settling the task. A provider
   * wake starts the next turn of the same task (`wakeOperationId` set once that turn runs). Only
   * this instance holds it: a restart leaves a waiting task to cold reconciliation. */
  waitingTask: { observer: (terminal: OwnedOperationTerminal) => Promise<void> | void; terminal: OwnedOperationTerminal; wakeOperationId?: string } | undefined;

  constructor(readonly operations: OwnedTurnRuntime) {}

  /** Resume the settled worker in its actual native lane. State and validation belong
   * here; SDK reconstruction, canonical evidence and publication use the same frame. */
  async bindWorker(report: HomeTaskReportOwner, exceptWorkToken?: string): Promise<void> {
    await this.operations.lane.run(async () => {
      this.operations.assertUsable();
      this.operations.assertChapterWritable();
      // Any live work in this session refuses the rebind, named.
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
        this.worker = report;
        await this.operations.replaceRuntime();
        this.operations.revision += 1;
        this.operations.emit("session.resourcesChanged", {});
        this.operations.publishSnapshot();
      } finally {
        work.settle();
      }
    });
  }

  async notifyOwnedTerminal(terminal: OwnedOperationTerminal): Promise<void> {
    // A held task's next turn reports to the task, even when Home's steering started that turn;
    // the steering's own observer still learns its terminal.
    const own = this.observers.get(terminal.operationId);
    const wake = this.waitingTask?.wakeOperationId === terminal.operationId ? this.waitingTask.observer : undefined;
    const observer = wake ?? own;
    if (!observer) return;
    this.observers.delete(terminal.operationId);
    if (wake && own) await own(terminal);
    // Only the task's own turns (its first operation, then each wake) hold or settle it; a steer
    // or other owned operation reports to its own observer and never touches the wait.
    if (this.worker && (terminal.operationId === this.worker.identity.operationId || this.waitingTask?.wakeOperationId === terminal.operationId)) {
      if (this.taskTurnAwaitsWake(terminal)) {
        this.waitingTask = { observer, terminal };
        return;
      }
      this.waitingTask = undefined;
    }
    await observer(terminal);
  }

  /** A message the maintainer sent, or Home's exact-operation steering, to this worker's task. */
  sharedTaskSteering(ownership: { readonly taskFence?: TaskWorkerControl } | undefined): boolean {
    if (!this.worker) return false;
    if (!ownership) return true;
    const fence = ownership.taskFence;
    return !!fence && fence.taskId === this.worker.identity.taskId && fence.operationId === this.worker.identity.operationId;
  }

  /** The task operation a turn reports under. A wake that continues the held task is the task's
   * next turn, so its report seals the task's operation, not the wake's own. */
  taskTurnOperationId(operationId: string): string {
    return this.waitingTask?.wakeOperationId === operationId && this.worker ? this.worker.identity.operationId : operationId;
  }

  /** The task operation the live turn belongs to, or undefined when no turn runs. Task controls
   * target the task's operation, so a provider wake's turn (its own operation) is the live task turn (#1251). */
  liveTaskOperationId(): string | undefined {
    return this.operations.activeOperationId === undefined ? undefined : this.taskTurnOperationId(this.operations.activeOperationId);
  }

  /** A task turn that completed normally, without a report, while owned runs are live. The
   * provider's completion or supervisor request wakes the same task for its next turn. A sealed or
   * stopping task, a length, error or aborted turn, and a task with no live run settle now. */
  private taskTurnAwaitsWake(terminal: OwnedOperationTerminal): boolean {
    if (terminal.lifecycle !== "completed" || !this.worker?.acceptsSteering) return false;
    const last = this.operations.sessionManager.getBranch().findLast(entry => entry.type === "message" && entry.message.role === "assistant");
    return last?.type === "message" && last.message.role === "assistant" && last.message.stopReason === "stop"
      && this.operations.hasDetachedDashboardWork();
  }

  /** Task cancellation follows the root prompt owner, not its disposable
   * presentation primitive (automatic compaction/retry may have another ID). */
  async cancelHomeTaskOperation(operationId: string, reason: string): Promise<void> {
    if (!this.worker || this.worker.identity.operationId !== operationId) throw new GatewayError("conflict", "Task cancellation owner changed");
    // Between turns no turn runs to abort: the held observer settles the waiting task now. The
    // runs it still owns are stopped and joined by settlement, as for an interrupted turn.
    if (this.waitingTask && this.waitingTask.wakeOperationId === undefined) {
      const { observer, terminal } = this.waitingTask;
      this.waitingTask = undefined;
      await observer({ lifecycle: "interrupted", operationId, invocationId: terminal.invocationId, errorCode: TASK_STOP_WAITING });
      return;
    }
    // A provider wake's turn is the task's running turn: its abort is the task's Stop.
    const turnOperationId = this.waitingTask?.wakeOperationId ?? operationId;
    if (this.operations.activeOperationId !== turnOperationId && this.operations.operation?.id !== turnOperationId) return;
    await this.operations.abort("agent", turnOperationId, reason);
  }



  /** The run ids settlement stops through the provider. A live run is stopped as itself,
   * and a workflow's stop reaches its children. A run that completed while runner-backed
   * children stay live cannot be stopped by its own state, so each live child is named by
   * its run id from the run's status. */
  asyncStopTargets(): string[] {
    // Selection has no awaits: a refresh cannot reorder the map mid-selection,
    // and Stop cannot disagree with status by re-reading a different artifact.
    return this.liveExtensionActivities().flatMap(activity => {
      const binding = activity.runId === undefined ? undefined : this.extensionRunOwnership.get(activity.runId);
      return binding?.asyncDir === undefined ? [] : liveActivitySubagentRuns(this, activity).map(run => run.runId);
    });
  }


  /** The live subagent runs this worker shows in task status. Read from the same live
   * projection as the report gate and settlement, never persisted. The run id is the
   * provider's; a run not yet published is identified by its launch call. */
  liveSubagentRuns(): HomeTaskSubagentRun[] {
    return this.liveExtensionActivities().flatMap(activity => liveActivitySubagentRuns(this, activity));
  }


  /** The activities that own live work under the one liveness rule below. Dashboard
   * accounting, drain, settlement and the report gate all read this list. */
  liveExtensionActivities(): ExtensionRunActivity[] {
    return [...this.extensionActivities.values()].filter(activity => extensionActivityOwnsLiveWork(this, activity));
  }


  /** Provider artifact shape policy lives in the delegated-provider module. */
  extensionArtifactPathAllowed(asyncPath: string): boolean {
    return delegatedArtifactPathAllowed(asyncPath, this.operations.cwd, this.operations.dependencies.delegatedArtifactRoot);
  }


  subagentExtensionOrigin(): ExtensionToolOrigin {
    return delegatedProviderOrigin(this.operations.runtime?.session.resourceLoader.getExtensions().extensions ?? []);
  }


  isForegroundSubagentTool(toolName: string, origin: ExtensionToolOrigin | undefined): boolean {
    return isInstalledDelegatedTool(toolName, origin, this.subagentExtensionOrigin().owner?.id);
  }


  /** Return only the exact installed controller already admitted for subagent
   * projection. Pi can reload a package through its resolved local path,
   * so the opaque installed-owner identity—not the mutable source label—is the
   * authority boundary. */
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


  /** Run identities and exact directories ambient discovery can attribute to
   * this slot. Every route this slot can accept requires one of them: a
   * canonical JSONL fact, a live ownership binding or a projected activity row
   * names the run, and the artifact's declared directory must agree with the
   * directory it was found in. A directory none of them names can only be
   * rejected, so the registry skips it instead of reopening its `status.json` on
   * every pass (G-8d). Run identities never contain a path separator, so one set
   * can hold both keys. */
  extensionAmbientArtifactAttribution(): ReadonlySet<string> {
    const attributed = new Set<string>();
    const addDirectory = (asyncDir: string): void => {
      attributed.add(resolve(asyncDir));
      try { attributed.add(realpathSync(asyncDir)); } catch { /* a directory that is gone stays attributable lexically */ }
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


  /** Exact directories already bound by a live tool result outrank ambient
   * discovery, especially while administrative drain needs terminal evidence. */
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


  /** Called only by the Gateway-scoped bounded artifact discovery owner or by
   * a watcher attached after this slot proved canonical ownership. The outcome
   * tells a caller whether it may record this exact artifact as dealt with: an
   * offer the slot could not decide (`transient`) must leave no record, or a
   * run known only from a saved session log is never offered again (G-8a). */
  discoverExtensionArtifact(asyncDir: string): Promise<ExtensionArtifactDiscoveryOutcome> {
    return refreshSubagentActivityFromArtifact(this, asyncDir);
  }


  /** Report admission uses the same fenced refresh as live artifact watchers,
   * including completed workflow roots whose children still own live work. */
  async reconcileLiveExtensionArtifacts(): Promise<void> {
    for (const activity of this.liveExtensionActivities()) {
      const binding = activity.runId ? this.extensionRunOwnership.get(activity.runId) : undefined;
      if (binding?.asyncDir) {
        await refreshExtensionActivityFromArtifact(this, binding.toolCallId, binding.asyncDir);
      }
    }
  }

  /** Administrative drain gets a direct, bounded reconciliation lane for
   * exact-owned artifacts instead of depending on watcher delivery or ambient
   * discovery scheduling. Genuine nonterminal work remains a blocker. */
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
        // Observe from the admitted parent's tree so a not-yet-created child
        // directory and later atomic status writes share one edge subscription.
        const childName = basename(directory);
        const watcher = watch(dirname(directory), { recursive: true }, (eventType, filename) => {
          const path = filename?.toString();
          if (path === undefined || path === childName || path === join(childName, "status.json")
            || path === join(childName, "process-terminal.json")) {
            tracked.onChange(eventType, "status.json");
          }
        });
        // Failure stays local to this child's observation. Neither the root
        // watcher nor its other authoritative edges are retired by that error.
        watcher.on("error", () => tracked.onChange("change", "status.json"));
        tracked.children.set(directory, watcher);
        // The root read that named this child ran before it was subscribed, so a
        // terminal write in between would be lost. Re-read once after subscribing.
        tracked.onChange("change", "status.json");
      } catch {
        // Optional observation cannot refuse otherwise valid root evidence.
      }
    }
  }


  stopExtensionActivityWatcher(toolCallId: string): void {
    this.extensionActivityReadGenerations.set(
      toolCallId,
      (this.extensionActivityReadGenerations.get(toolCallId) ?? 0) + 1
    );
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
      // Only a synthetic placeholder may be replaced by a real Pi identity.
      if (!existing.toolCallId.startsWith("subagent:") || binding.toolCallId.startsWith("subagent:")) return false;
    }
    const asyncDir = existing?.asyncDir ?? binding.asyncDir;
    const detachedChildKeys = binding.detachedChildKeys ?? existing?.detachedChildKeys;
    this.extensionRunOwnership.set(runId, {
      toolCallId: binding.toolCallId,
      ...(asyncDir ? { asyncDir } : {}),
      terminal: Boolean(existing?.terminal || binding.terminal),
      // Each admitted frame states the proof it observed: the bound instant is
      // current, never a latch, so resumed live work clears it again.
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
      // A missing or inaccessible extension artifact remains a generic live row.
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

    // A synchronous subagent is the parent session's current foreground tool.
    // Fence the same settled abort path used by the ordinary composer control
    // to the operation captured when this exact transcript lease opened.
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


  /** Whether this session owns a run: one its canonical history launched (a launch or a resume
   * result), or a child run a workflow of this session names in its own provider status. Task
   * controls use it to refuse a control of any run the task did not start, including a foreign
   * workflow's child. Only this owner decides, so a control and a reply cannot disagree. */
  async ownsSubagentRun(runId: string): Promise<boolean> {
    const facts = canonicalExtensionRunFacts(this);
    if (facts.has(runId)) return true;
    for (const fact of facts.values()) {
      // The status reader opens only a canonical directory: a launch result's path may name a symlinked root.
      const directory = fact.asyncDir === undefined ? undefined : this.canonicalExtensionArtifactDirectory(fact.asyncDir);
      if (directory === undefined) continue;
      const status = await this.artifacts.readExtensionStatusArtifact(directory, false).catch(() => undefined);
      if (status?.mode === "workflow" && Array.isArray(status.steps)
        && status.steps.some(step => (step as { runId?: unknown } | null)?.runId === runId)) return true;
    }
    return false;
  }


  /** Whether a supervisor request came from a run this session owns. The request is canonical
   * evidence: its `subagent_supervisor_request` message names the child's run. */
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

  /** Canonical branch changes discard the old branch's disposable run projection. */
  resetArtifactBranch(): void {
    this.clearExtensionActivityWatchers();
    this.extensionActivities.clear();
    this.extensionActivitySequences.clear();
    this.extensionRunOwnership.clear();
  }

  /** Retire current watches and fence outstanding watched reads before physical SDK disposal. */
  retireArtifactWatches(): void {
    this.clearExtensionActivityWatchers();
    this.extensionArtifactMissingSince.clear();
    this.extensionRunOwnership.clear();
  }
}
