import { stage } from "../../util/request-span.js";
import { RunEventsOwner } from "./run-events.js";
import type { SessionConfigurationBlocker } from "../../protocol/types.js";
import { admitPrompt } from "./prompt-admission.js";
import type { PromptOwnership } from "./prompt-input.js";
import { boundedSummaryText } from "../../sessions/summary-text.js";
import type { ImageContent } from "../pi/ai.js";
import type { QueuedMessageState, ResourceInvocation } from "../../protocol/types.js";
import type { QueueBehavior, PromptQueueDisplay } from "./queue-input.js";
import { MAXIMUM_QUEUED_MESSAGE_BYTES, resourceIsInvocable } from "./queue-commands.js";
import { HeldPromptQueue } from "./held-prompt-queue.js";
import { RunQueueCommands } from "./queue-commands.js";
import { RunQueueOwner } from "./run-queue-owner.js";
import { RunPersistence } from "./run-persistence.js";
import { RunWorkOwner } from "./run-work-owner.js";
import { RunAbortOwner } from "./run-abort-owner.js";
import { RunTerminalOwner } from "./run-terminal.js";
import { RunAttentionOwner } from "./run-attention.js";
import { RunInvocations } from "./run-invocations.js";
import { ManualCompactionOwner } from "./manual-compaction.js";
import { randomUUID } from "node:crypto";
import { performance } from "node:perf_hooks";
import type { Model } from "../pi/ai.js";
import type { AgentMessage } from "../pi/agent-core.js";
import type { SessionPhase, SessionOperationState, RetryState, PendingPromptState, JsonValue } from "../../protocol/types.js";
import { GatewayError, asUncertainOutcome } from "../../errors.js";
import { safeJson } from "../projection/projection.js";
import type { GatewayWorkHandle } from "./gateway-work-registry.js";
import { RunRuntime } from "./run-runtime.js";

const MAXIMUM_PENDING_PROMPT_BYTES = MAXIMUM_QUEUED_MESSAGE_BYTES;

/** Run authority; the concrete frame supplies native SDK and publication I/O. */
export abstract class RunOperations<FixedAt> extends RunRuntime<FixedAt> {
  readonly runAbort = new RunAbortOwner(this);
  readonly runWork = new RunWorkOwner(this);
  readonly runPersistence = new RunPersistence(this);
  readonly runQueue = new RunQueueOwner(this);
  readonly queueCommands = new RunQueueCommands(this);
  readonly heldQueue = new HeldPromptQueue(this);
  readonly runTerminal = new RunTerminalOwner(this);
  readonly runAttention = new RunAttentionOwner(this);
  /** Gateway-owned causal graph. Canonical receipts remain the durable source;
   * these bounded maps are only the live projection used by snapshots. */
  readonly runInvocations = new RunInvocations(this);
  readonly manualCompaction = new ManualCompactionOwner(this);
  readonly runEvents = new RunEventsOwner(this);
  revision = 0;
  phase!: SessionPhase;
  activeOperationId: string | undefined;
  operation: SessionOperationState | undefined;
  pendingExtensionCommand: SessionOperationState | undefined;
  retry: RetryState | undefined;
  pendingPrompt: PendingPromptState | undefined;
  /** Exact Pi message object claimed by the foreground pending prompt. */
  pendingPromptMessage: AgentMessage | undefined;
  operationWasHomeWake = false;
  compactionBaselineEntryId: string | undefined;
  /** Exact operation installed at compaction_start. A hook may launch a
   * successor before compaction_end, so the current operation is not reliable
   * completion ownership. */
  compactionOperation: SessionOperationState | undefined;

  /** Join live settlement and reconcile bounded canonical evidence before open. */
  async reconcileAttention(): Promise<void> {
    // Marker evidence and any pending settlement are disk work on the open path;
    // the request span names them instead of leaving them unaccounted.
    return stage("attention.reconcile", () => this.runAttention.reconcileAttentionBody());
  }

  clearPendingPrompt(): void { this.pendingPrompt = undefined; this.pendingPromptMessage = undefined; }

  publishChanged(): void { this.revision += 1; this.publishSnapshot(); }

  async setModel(provider: string, modelId: string, initiatingWorkToken?: string, expectation?: { runtimeGeneration: string; model: { provider: string; id: string } | null }, fixedAt?: FixedAt): Promise<number> {
    if (this.usesHomeSettings && this.dependencies.settings()) return this.changeHomeRecipe("model.ref[role=chat]", { provider, id: modelId }, initiatingWorkToken);
    return this.lane.run(() => this.applyModelConfiguration(provider, modelId, initiatingWorkToken, expectation, fixedAt));
  }

  protected async applyModelConfiguration(provider: string, modelId: string, initiatingWorkToken?: string, expectation?: { runtimeGeneration: string; model: { provider: string; id: string } | null }, fixedAt?: FixedAt): Promise<number> {
    this.assertConfigurationAdmissible(initiatingWorkToken);
    this.assertChapterWritable();
    if (expectation) this.assertConfigurationExpectation(expectation);
    const model = this.runtime.session.modelRuntime.getModel(provider, modelId);
    if (!model) throw new GatewayError("not_found", "Model is not registered in Tron");
    // The live runtime’s profile admits the choice, not a later designation
    // record. Ordinary sessions carry no extra model constraint and retain
    // their existing choice.
    this.liveProfile().modelSelection?.assertAllowed(model);
    const previousThinking = this.runtime.session.thinkingLevel;
    await this.runtime.session.setModel(model as Model<never>);
    await this.recordFixedSetting("model.ref[role=chat]", { provider, id: modelId }, fixedAt);
    if (this.runtime.session.thinkingLevel !== previousThinking) await this.recordFixedSetting("model.thinking[role=chat]", this.runtime.session.thinkingLevel);
    this.revision += 1;
    this.publishSnapshot();
    return this.revision;
  }

  async setContextWindow(provider: string, modelId: string, contextWindow: unknown, expectedRevision: number, expectedRuntimeGeneration: string, initiatingWorkToken?: string, fixedAt?: FixedAt): Promise<number> {
    return this.lane.run(async () => {
      this.assertNoLiveTaskConfiguration("context window");
      this.assertConfigurationIdle(initiatingWorkToken);
      this.assertChapterWritable();
      if (expectedRuntimeGeneration !== this.runtimeGeneration || expectedRevision !== this.revision) {
        throw new GatewayError("conflict", "Session changed; refresh before changing its context window");
      }
      const policy = this.contextPolicies.get(this.runtime.session);
      if (!policy) throw new GatewayError("conflict", "Session context configuration is unavailable");
      try {
        policy.set({ provider, id: modelId }, contextWindow);
        await this.recordFixedSetting("model.contextWindow", policy.snapshot()?.effective, fixedAt);
      } finally {
        // Pi may have staged the entry even when its disk append failed. Always
        // project the exact runtime outcome rather than leaving clients stale.
        this.revision += 1;
        this.emit("session.contextChanged", {});
        this.publishSnapshot();
      }
      return this.revision;
    });
  }

  async setThinking(level: "off" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max", initiatingWorkToken?: string, expectation?: { runtimeGeneration: string; model: { provider: string; id: string } | null }, fixedAt?: FixedAt): Promise<number> {
    if (this.usesHomeSettings && this.dependencies.settings()) return this.changeHomeRecipe("model.thinking[role=chat]", level, initiatingWorkToken);
    return this.lane.run(() => this.applyThinkingConfiguration(level, initiatingWorkToken, expectation, fixedAt));
  }

  protected async applyThinkingConfiguration(level: "off" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max", initiatingWorkToken?: string, expectation?: { runtimeGeneration: string; model: { provider: string; id: string } | null }, fixedAt?: FixedAt): Promise<number> {
    this.assertConfigurationAdmissible(initiatingWorkToken);
    this.assertChapterWritable();
    if (expectation) this.assertConfigurationExpectation(expectation);
    this.runtime.session.setThinkingLevel(level);
    await this.recordFixedSetting("model.thinking[role=chat]", this.runtime.session.thinkingLevel, fixedAt);
    this.revision += 1;
    this.publishSnapshot();
    return this.revision;
  }

  async setTools(toolNames: string[], initiatingWorkToken?: string, fixedAt?: FixedAt): Promise<void> {
    if (this.usesHomeSettings && this.dependencies.settings()) { await this.changeHomeRecipe("tools.active", toolNames, initiatingWorkToken); return; }
    return this.lane.run(() => this.applyToolsConfiguration(toolNames, initiatingWorkToken, fixedAt));
  }

  protected async applyToolsConfiguration(toolNames: string[], initiatingWorkToken?: string, fixedAt?: FixedAt): Promise<void> {
    this.assertNoLiveTaskConfiguration("active tools");
    this.assertIdle(false, initiatingWorkToken);
    const tools = this.runtime.session.getAllTools();
    const known = new Set(tools.map((tool) => tool.name));
    const unknown = toolNames.filter((name) => !known.has(name));
    if (unknown.length > 0) throw new GatewayError("invalid_request", `Unknown agent tools: ${unknown.join(", ")}`);
    const hidden = toolNames.filter((name) => tools.find((tool) => tool.name === name)?.exposure === "hidden");
    if (hidden.length > 0) throw new GatewayError("invalid_request", `Hidden agent tools cannot be activated: ${hidden.join(", ")}`);
    this.runtime.session.setActiveToolsByName(toolNames);
    await this.recordFixedSetting("tools.active", this.runtime.session.getActiveToolNames(), fixedAt);
    this.revision += 1;
    this.emit("session.contextChanged", {});
    this.publishSnapshot();
  }

  async executeBash(command: string, excludeFromContext: boolean, initiatingWorkToken?: string): Promise<JsonValue> {
    let work: GatewayWorkHandle | undefined;
    try {
      return await this.lane.run(async () => {
        this.assertIdle(false, initiatingWorkToken);
        // Bash is Gateway-admitted agent work, so it clears retained archive
        // state on the same lane turn that admits it.
        await this.dependencies.beforeRunAdmission(this.id);
        // Admission and the first canonical Bash call are in one lane turn with
        // no suspension between them. The new token therefore cannot make its
        // own idle check fail and no competing session mutation can enter.
        work = this.dependencies.workRegistry.begin({
          kind: "foreground-agent-operation",
          sessionId: this.id,
          hostEpoch: this.ui.hostEpoch,
        });
        const operationId = randomUUID();
        // The marker is written before dispatch: a failure here is definitive
        // (the shell command never started) and stays retryable.
        await this.runPersistence.trackOwnershipWrite(
          () => this.runPersistence.retryDurableWrite(`marker:mark:${operationId}`, () => this.dependencies.markers.mark(this.id, operationId)),
          work,
        );
        try {
          const startedAt = new Date().toISOString();
          this.phase = "running";
          this.operation = { id: operationId, kind: "bash", startedAt };
          this.noteDashboardActivity(startedAt);
          if (!this.activityHeartbeat) this.startActivityHeartbeat();
          this.revision += 1;
          this.publishSnapshot();
          const previousEntryIDs = new Set(this.sessionManager.getBranch().map((entry) => entry.id));
          const startedMonotonicMs = performance.now();
          const result = await this.runtime.session.executeBash(command, undefined, {
            excludeFromContext,
            id: operationId,
            operations: this.directBashProcesses!.shellOperations(),
          });
          const completedAt = new Date().toISOString();
          const bashEntries = this.sessionManager.getBranch().filter((entry) =>
            !previousEntryIDs.has(entry.id)
              && entry.type === "message"
              && entry.message.role === "bashExecution");
          // Pi currently appends exactly one Bash entry. Match by branch delta
          // rather than leaf position so a future post-execution hook cannot
          // silently detach timing by appending another canonical entry.
          if (bashEntries.length === 1) {
            this.rememberProjectionMetadata(this.bashMetadata, bashEntries[0]!.id, {
              startedAt,
              completedAt,
              durationMs: Math.max(0, Math.round(performance.now() - startedMonotonicMs)),
              lastProgressAt: completedAt,
              progressSequence: 1,
            });
          }
          return safeJson(result);
        } catch (error) {
          // The shell command may already have run: a duplicate replay is worse
          // than an explicit uncertainty, so the idempotency receipt must keep
          // its fence instead of reporting a definitive rejection.
          throw asUncertainOutcome(error, "Bash execution was dispatched but its outcome could not be confirmed; refresh session state instead of replaying");
        } finally {
          let cleanupFailure: unknown;
          try {
            await this.clearMarkerOwnership(operationId, work);
          } catch (error) {
            cleanupFailure = error;
          }
          this.phase = "idle";
          this.operation = undefined;
          this.noteDashboardActivity();
          if (!this.hasCurrentDashboardWork()) this.stopActivityHeartbeat();
          this.revision += 1;
          this.publishSnapshot();
          if (cleanupFailure !== undefined) {
            throw asUncertainOutcome(cleanupFailure, "Bash completed but its ownership marker could not be cleared; refresh session state instead of replaying");
          }
        }
      });
    } finally {
      work?.settle();
    }
  }

  async prompt(
    text: string,
    images: ImageContent[] = [],
    behavior?: QueueBehavior,
    queueDisplay?: PromptQueueDisplay,
    onAdmitted?: (result: { operationId: string }) => void,
    ownership?: PromptOwnership<{ taskId: string; operationId: string }>,
  ): Promise<{ operationId: string }> {
    // Once Stop closes Pi's queue, new client work stays Gateway-owned until
    // the stopped originals are admitted as one serialized continuation.
    if (!ownership && this.runAbort.stopRecoveryQueueClosed) {
      return this.heldQueue.holdPrompt(text, images, behavior, queueDisplay, true);
    }
    // Automation owns its own dispatch and terminal observers, so only client
    // prompts join the Gateway-owned compaction queue.
    this.assertHomePromptAdmission();
    if (!ownership && !this.taskWorker && this.heldQueue.holdsPromptsForCompaction(text, queueDisplay)) {
      const result = this.heldQueue.holdPrompt(text, images, behavior, queueDisplay);
      onAdmitted?.(result);
      return result;
    }
    return admitPrompt(this,
      text, images, behavior, queueDisplay, onAdmitted, ownership,
      ownership?.operationId ?? randomUUID(),
    );
  }


  attentionPendingError(): GatewayError {
    const completion = this.runAttention.pendingAssistantCompletion ?? this.runAttention.completionOwnershipQueue[0]?.completion;
    const ageMs = completion ? Math.max(0, Date.now() - Date.parse(completion.completedAt)) : undefined;
    const completionId = completion?.operationId ?? completion?.id;
    this.emit("session.diagnostic", {
      code: "attention-pending",
      ...(completionId ? { operationId: completionId } : {}),
      ...(ageMs !== undefined ? { ageMs } : {}),
    });
    return new GatewayError(
      "busy",
      completion
        ? `The prior response is still committing durable attention state (completion ${completionId} pending for ${Math.floor((ageMs ?? 0) / 1000)} s)`
        : "The prior response is still committing durable attention state",
      true,
      { reason: "attention-pending", ...(completionId ? { operationId: completionId } : {}), ...(ageMs !== undefined ? { ageMs } : {}) },
      "attention-pending",
    );
  }


  promptDisplay(
    operationId: string,
    text: string,
    images: ImageContent[],
    queueDisplay: PromptQueueDisplay | undefined,
  ): PendingPromptState {
    const semantic = this.internalWakeSemantic(operationId);
    return {
      id: operationId,
      ...(semantic ? { semantic } : {}),
      createdAt: new Date().toISOString(),
      // Requested queue behavior is advisory until Pi actually enqueues.
      // A prompt admitted after the run settles remains ordinary.
      text: boundedSummaryText(
        queueDisplay?.text ?? text,
        MAXIMUM_PENDING_PROMPT_BYTES
      ),
      attachmentCount: queueDisplay?.attachmentCount ?? images.length,
      ...(queueDisplay?.resourceInvocations === undefined
        ? {}
        : { resourceInvocations: queueDisplay.resourceInvocations }),
      ...(queueDisplay?.photoCount === undefined && images.length === 0
        ? {}
        : { photoCount: queueDisplay?.photoCount ?? images.length }),
      ...(queueDisplay?.fileAttachmentCount === undefined && images.length === 0
        ? {}
        : {
            fileAttachmentCount: queueDisplay?.fileAttachmentCount
              ?? Math.max(0, (queueDisplay?.attachmentCount ?? images.length) - (queueDisplay?.photoCount ?? images.length)),
          }),
      ...(queueDisplay?.attachments === undefined ? {} : { attachments: queueDisplay.attachments }),
    };
  }


  abort(
    kind: "agent" | "compaction" | "retry" | "branchSummary" | "bash" = "agent",
    expectedOperationId?: string,
    terminalErrorCode = "user-abort",
  ): Promise<void> {
    return this.runAbort.abort(kind, expectedOperationId, terminalErrorCode);
  }


  clearQueue(): Promise<void> {
    return this.queueCommands.clearQueue();
  }


  replaceQueue(
    expectedRevision: number,
    items: Array<Pick<QueuedMessageState, "id" | "behavior" | "text">>,
  ): Promise<{ queueRevision: number; items: QueuedMessageState[] }> {
    return this.queueCommands.replaceQueue(expectedRevision, items);
  }


  compact(instructions?: string): Promise<{ queued: boolean }> {
    return this.manualCompaction.compact(instructions);
  }


  assertInvocableResources(resources: readonly ResourceInvocation[]): void {
    const commands = this.commands();
    if (!resources.every(resource => resourceIsInvocable(commands, resource))) {
      throw new GatewayError("conflict", "The selected resource is no longer unambiguous for this session");
    }
  }


  operationMatches(target: SessionOperationState): boolean {
    const current = this.operation;
    return current?.id === target.id
      && current?.kind === target.kind
      && current?.startedAt === target.startedAt;
  }


  /** A running task worker takes configuration between provider requests (#1336): Pi reads model
   * and thinking per turn and request, so the in-flight request never changes. Compaction refuses. */
  protected liveTaskConfiguration(): boolean {
    const worker = this.taskWorker;
    if (!worker?.acceptsSteering || this.disposed || this.shuttingDown || this.trustReloadPending || this.runPersistence.hasBlockedOwnershipWrite) return false;
    if (this.phase === "compacting" || this.activeOperationId !== undefined && this.runAbort.abortedOperations.has(this.activeOperationId)) return false;
    const session = this.runtime.session;
    if (session.isStreaming) return this.runTerminal.liveTaskOperationId() === worker.identity.operationId;
    return this.runTerminal.taskWait !== undefined && this.runTerminal.taskWait.wakeOperationId === undefined
      && this.activeOperationId === undefined && this.operation === undefined;
  }

  /** A running worker's context window and tool loadout have no supported mid-run
   * boundary here: say so instead of the generic busy refusal (#1336). */
  protected assertNoLiveTaskConfiguration(what: string): void {
    if (!this.liveTaskConfiguration()) return;
    throw new GatewayError("busy", `A running task worker's ${what} change only between runs: change it after task ${this.taskWorker!.identity.taskId} settles (it applies on resume). Model, thinking and Run settings apply from the worker's next model request.`, true);
  }

  /** Idle configuration, or a running Home task worker's live configuration (#1336). */
  protected assertConfigurationAdmissible(initiatingWorkToken?: string): void {
    if (this.liveTaskConfiguration()) {
      this.assertUsable();
      this.assertChapterWritable();
      return;
    }
    this.assertConfigurationIdle(initiatingWorkToken);
  }

  protected configurationBlocker(exceptWorkToken?: string): SessionConfigurationBlocker | null {
    if (this.disposed || this.shuttingDown || this.trustReloadPending) return "unavailable";
    if (this.runPersistence.hasBlockedOwnershipWrite) return "settling";
    if (this.runtime.session.isStreaming || this.runtime.session.isBashRunning
      || this.phase === "running" || this.phase === "compacting" || this.phase === "retrying"
      || this.activeOperationId !== undefined) return "running";
    if (this.pendingPrompt || this.runQueue.pendingQueueAdmission || this.runQueue.queuedMessages.length > 0
      || this.heldQueue.entries.length > 0 || this.manualCompaction.pendingManualCompaction || this.manualCompaction.queuedManualCompactionInFlight) return "queued";
    if (this.runAttention.pendingAssistantCompletion || this.runAttention.completionOwnershipQueue.length > 0) return "settling";
    if (this.pendingExtensionCommand || this.lifecycle.preventsNonRuntimeQuiescence) return "interaction";
    const work = this.dependencies.workRegistry.facts().filter(fact => fact.sessionId === this.id && fact.token !== exceptWorkToken);
    if (work.some(fact => fact.kind === "terminal-receipt-persistence" || fact.kind === "automation-terminal-persistence")) return "settling";
    if (work.length > 0) return "mutation";
    return null;
  }

  protected assertConfigurationIdle(initiatingWorkToken?: string): void {
    this.assertUsable();
    const blocker = this.configurationBlocker(initiatingWorkToken);
    if (blocker) throw new GatewayError("busy", "Session configuration is waiting for " + blocker, true,
      { configurationBlocker: blocker, phase: this.effectivePhase }, `session_configuration_${blocker}`);
  }

  protected assertConfigurationExpectation(expectation: { runtimeGeneration: string; model: { provider: string; id: string } | null }): void {
    const model = this.runtime.session.model;
    if (expectation.runtimeGeneration !== this.runtimeGeneration
      || (expectation.model?.provider ?? null) !== (model?.provider ?? null)
      || (expectation.model?.id ?? null) !== (model?.id ?? null)) {
      throw new GatewayError("conflict", "Session model or runtime changed; refresh before changing configuration", true);
    }
  }

  /** `exceptWorkToken` is the initiating request's own work entry, which is not
   * the session running. Every other entry, including a different request's,
   * still makes this busy. */
  protected assertIdle(allowTrustReload = false, exceptWorkToken?: string): void {
    this.assertUsable(allowTrustReload);
    this.assertChapterWritable();
    if (this.isRunningWork(exceptWorkToken)) throw new GatewayError("busy", "Session must be idle for this operation");
  }

  protected isRunningWork(exceptWorkToken?: string): boolean {
    return this.runtime.session.isStreaming || this.drainBusyExcept(exceptWorkToken);
  }

  /** Pi can clear isStreaming before its agent_settled choreography has
   * reached this runtime. Keep ordinary admission behind the existing Gateway
   * operation owner until the sequenced state transition is published. */
  public get isAgentAdmissionSettling(): boolean {
    // Compaction has its own Pi abort controller and cannot accept Agent input,
    // even when the SDK's broad streaming flag remains true. Wait until the
    // continuation or idle transition, then re-evaluate steer/follow-up.
    if (this.phase === "compacting") return true;
    if (this.hasActiveAgentRun) return false;
    return this.phase === "running"
      || this.phase === "retrying"
      || this.activeOperationId !== undefined
      || this.operation !== undefined
      || this.runAttention.pendingAssistantCompletion !== undefined;
  }

  public get effectivePhase(): SessionPhase {
    if (this.hasActiveAgentRun && (this.phase === "idle" || this.phase === "interrupted")) return "running";
    return this.phase;
  }

}
