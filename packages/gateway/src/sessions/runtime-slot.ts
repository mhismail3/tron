import { randomUUID } from "node:crypto";
import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import type { ImageContent, Model } from "@earendil-works/pi-ai";
import {
  AgentSessionRuntime,
  createAgentSessionFromServices,
  createAgentSessionRuntime,
  createAgentSessionServices,
  type AgentSessionEvent,
  type CreateAgentSessionRuntimeFactory,
  type ExtensionCommandContextActions,
  type ModelRuntime,
  type SessionManager,
} from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import type {
  CommandInfo,
  JsonValue,
  QueuedMessageState,
  RetryState,
  SessionOperationState,
  SessionPhase,
  SessionSnapshot,
  SessionSummaryUpdate,
  SessionTreeNode,
  ToolExecutionState,
} from "../protocol/types.js";
import { AsyncMutex } from "../util/async-mutex.js";
import type { TrustService } from "../admin/trust-service.js";
import { BLOB_MAX_ITEM_BYTES, type BlobStore } from "./blob-store.js";
import { ExtensionUIBroker } from "./extension-ui.js";
import {
  fitSessionSnapshot,
  projectJson,
  projectMessage,
  projectToolOutput,
  projectToolResult,
  projectTranscriptPage,
  projectTree,
  safeJson,
  type ToolProjectionMetadata,
  type TranscriptPage,
} from "./projection.js";
import type { RunMarkerStore } from "./run-markers.js";

export type SessionBroadcast = (sessionId: string, topic: string, payload: JsonValue) => void;

type QueueBehavior = QueuedMessageState["behavior"];

type RuntimeQueuedMessage = QueuedMessageState & {
  runtimeText: string;
  attachmentEnvelope: string;
  images: ImageContent[];
  ordinal: number;
};

type PendingQueueAdmission = Omit<RuntimeQueuedMessage, "runtimeText" | "ordinal">;

const MAXIMUM_QUEUED_MESSAGES = 32;
const MAXIMUM_QUEUED_MESSAGE_BYTES = 64 * 1_024;
const MAXIMUM_QUEUED_TOTAL_BYTES = 256 * 1_024;

function boundedSummaryText(value: string, maximumBytes = 1_024): string {
  const encoded = Buffer.from(value);
  if (encoded.length <= maximumBytes) return value;
  const suffix = "…";
  const available = Math.max(0, maximumBytes - Buffer.byteLength(suffix));
  return `${encoded.subarray(0, available).toString("utf8").replace(/\uFFFD$/u, "")}${suffix}`;
}

export interface RuntimeSlotHooks {
  broadcast: SessionBroadcast;
  summaryChanged: (summary: SessionSummaryUpdate) => void;
  changed: (sessionId: string) => void;
  settled: (sessionId: string) => void;
  rekey: (previousId: string, nextId: string, slot: RuntimeSlot) => void;
}

export interface RuntimeSlotDependencies {
  agentDir: string;
  createModelRuntime: () => Promise<ModelRuntime>;
  trust: TrustService;
  blobs: BlobStore;
  markers: RunMarkerStore;
}

/**
 * Owns one live Pi runtime and the reconnect-safe mobile projection for its
 * canonical JSONL session. Every mutation runs through `lane`; distinct slots
 * remain concurrent.
 */
export class RuntimeSlot {
  private runtime!: AgentSessionRuntime;
  private unsubscribe: (() => void) | undefined;
  private readonly lane = new AsyncMutex();
  private readonly ui: ExtensionUIBroker;
  private readonly runtimeGeneration = randomUUID();
  private revision = 0;
  private eventSequence = 0;
  private phase: SessionPhase;
  private disposed = false;
  private snapshotTimer: NodeJS.Timeout | undefined;
  private activityHeartbeat: NodeJS.Timeout | undefined;
  private readonly toolProgressTimers = new Map<string, NodeJS.Timeout>();
  private readonly toolProgressPublishedAt = new Map<string, number>();
  private activeOperationId: string | undefined;
  private operation: SessionOperationState | undefined;
  private retry: RetryState | undefined;
  private resourceReloadOptions: { resolveProjectTrust: () => Promise<boolean> } | undefined;
  private projectTrustReloadOverride: boolean | undefined;
  private trustReloadPending = false;
  private readonly toolExecutions = new Map<string, ToolExecutionState>();
  /** Bounded runtime timing enriches the mobile projection without changing Pi
   * JSONL. Historical entries without retained metadata use timestamp fallback. */
  private readonly toolMetadata = new Map<string, ToolProjectionMetadata>();
  private nextToolOrder = 0;
  private lastPublishedSummary: SessionSummaryUpdate | undefined;
  private summaryContentDirty = true;
  private cachedSummaryContent: {
    name?: string;
    updatedAt: string;
    messageCount: number;
    firstMessage: string;
  } | undefined;
  private lastTouchedAt = Date.now();
  private queueRevision = 0;
  private nextQueueOrdinal = 0;
  private queuedMessages: RuntimeQueuedMessage[] = [];
  private pendingQueueAdmission: PendingQueueAdmission | undefined;
  private suppressQueueEvents = false;

  private constructor(
    private sessionManager: SessionManager,
    private readonly dependencies: RuntimeSlotDependencies,
    private readonly hooks: RuntimeSlotHooks,
    interrupted: boolean,
  ) {
    this.phase = interrupted ? "interrupted" : "idle";
    this.ui = new ExtensionUIBroker((topic, payload) => {
      this.revision += 1;
      this.emit(topic, payload);
    });
  }

  static async create(
    sessionManager: SessionManager,
    dependencies: RuntimeSlotDependencies,
    hooks: RuntimeSlotHooks,
    interrupted: boolean,
  ): Promise<RuntimeSlot> {
    const slot = new RuntimeSlot(sessionManager, dependencies, hooks, interrupted);
    await slot.initialize();
    return slot;
  }

  get id(): string {
    return this.runtime?.session.sessionId ?? this.sessionManager.getSessionId();
  }

  get cwd(): string {
    return this.runtime?.cwd ?? this.sessionManager.getCwd();
  }

  get modelRuntime(): ModelRuntime {
    this.assertNoTrustReload();
    return this.runtime.session.modelRuntime;
  }

  get isBusy(): boolean {
    return this.effectivePhase === "running"
      || this.effectivePhase === "compacting"
      || this.effectivePhase === "retrying"
      || this.runtime?.session.isBashRunning === true;
  }

  /** AgentSession can start an extension-triggered continuation while an older
   * `agent_settled` callback is still unwinding. AgentSession's full streaming
   * lifecycle is the authoritative foreground owner in that overlap. */
  private get hasActiveAgentRun(): boolean {
    const session = this.runtime?.session;
    return session?.isStreaming === true || session?.state.isStreaming === true;
  }

  private get effectivePhase(): SessionPhase {
    if (this.hasActiveAgentRun && (this.phase === "idle" || this.phase === "interrupted")) return "running";
    return this.phase;
  }

  private ensureAgentProjection(): void {
    if (!this.hasActiveAgentRun) return;
    if (this.phase === "idle" || this.phase === "interrupted") this.phase = "running";
    this.activeOperationId ??= randomUUID();
    this.operation ??= { id: this.activeOperationId, kind: "prompt", startedAt: new Date().toISOString() };
    if (!this.activityHeartbeat) this.startActivityHeartbeat();
  }

  /** Lightweight dashboard projection. Catalog listing must not construct a
   * transcript-bearing session snapshot merely to read runtime activity. */
  get catalogPhase(): SessionPhase {
    return this.effectivePhase;
  }

  get touchedAt(): number {
    return this.lastTouchedAt;
  }

  get sessionFile(): string | undefined {
    return this.runtime.session.sessionFile;
  }

  sessionEnvironment(): Record<string, string> {
    this.assertNoTrustReload();
    const session = this.runtime.session;
    return {
      PI_SESSION_ID: session.sessionId,
      ...(session.sessionFile ? { PI_SESSION_FILE: session.sessionFile } : {}),
      PI_CWD: this.cwd,
      ...(session.model ? { PI_PROVIDER: session.model.provider, PI_MODEL: session.model.id } : {}),
      PI_REASONING_LEVEL: session.thinkingLevel,
    };
  }

  touch(): void {
    this.lastTouchedAt = Date.now();
  }

  private runtimeFactory(): CreateAgentSessionRuntimeFactory {
    return async ({ cwd, sessionManager, sessionStartEvent }) => {
      const trust = await this.dependencies.trust.requireResolved(cwd);
      // A ModelRuntime is scoped to one Pi session runtime. Extension provider
      // registration is mutable, so sharing one instance across projects would
      // leak project providers between concurrent Tron sessions. Credentials and
      // model files remain canonical through their shared file paths.
      const modelRuntime = await this.dependencies.createModelRuntime();
      this.resourceReloadOptions = {
        // Reload must re-read the canonical decision. Capturing the value from
        // runtime creation would leave project code loaded after trust changes.
        resolveProjectTrust: async () => (await this.dependencies.trust.inspect(trust.cwd)).effectiveDecision === true,
      };
      const services = await createAgentSessionServices({
        cwd: trust.cwd,
        agentDir: this.dependencies.agentDir,
        modelRuntime,
        resourceLoaderReloadOptions: this.resourceReloadOptions,
      });
      const created = await createAgentSessionFromServices({
        services,
        sessionManager,
        ...(sessionStartEvent ? { sessionStartEvent } : {}),
      });
      return { ...created, services, diagnostics: services.diagnostics };
    };
  }

  private async initialize(): Promise<void> {
    this.runtime = await createAgentSessionRuntime(this.runtimeFactory(), {
      cwd: this.sessionManager.getCwd(),
      agentDir: this.dependencies.agentDir,
      sessionManager: this.sessionManager,
      sessionStartEvent: { type: "session_start", reason: "resume" },
    });
    this.runtime.setRebindSession(async () => this.bindSession());
    await this.bindSession();
  }

  private effectiveResourceReloadOptions(): { resolveProjectTrust: () => Promise<boolean> } | undefined {
    const override = this.projectTrustReloadOverride;
    return override === undefined
      ? this.resourceReloadOptions
      : { resolveProjectTrust: async () => override };
  }

  private commandActions(): ExtensionCommandContextActions {
    return {
      waitForIdle: () => this.runtime.session.waitForIdle(),
      newSession: (options) => this.runtime.newSession(options),
      fork: (entryId, options) => this.runtime.fork(entryId, options),
      navigateTree: (targetId, options) => this.runtime.session.navigateTree(targetId, options),
      switchSession: (sessionPath, options) => this.runtime.switchSession(sessionPath, options),
      reload: async () => {
        await this.runtime.session.resourceLoader.reload(this.effectiveResourceReloadOptions());
        await this.runtime.session.reload();
        if (this.projectTrustReloadOverride === undefined) this.commitReload();
      },
    };
  }

  private async bindSession(): Promise<void> {
    const previousId = this.runtime?.session.sessionId ?? this.sessionManager.getSessionId();
    this.unsubscribe?.();
    const session = this.runtime.session;
    this.sessionManager = session.sessionManager;
    await session.bindExtensions({
      uiContext: this.ui.context(),
      mode: "rpc",
      commandContextActions: this.commandActions(),
      abortHandler: () => void this.abort(),
      shutdownHandler: () => this.emit("session.notification", { type: "warning", message: "An extension requested shutdown; Tron kept running" }),
      onError: (error) => this.emit("session.extensionError", safeJson(error)),
    });
    this.unsubscribe = session.subscribe((event) => this.onEvent(event));
    const nextId = session.sessionId;
    if (previousId !== nextId) this.hooks.rekey(previousId, nextId, this);
    this.revision += 1;
    this.publishSnapshot();
  }

  private emit(topic: string, data: JsonValue): void {
    this.eventSequence += 1;
    this.hooks.broadcast(this.id, topic, {
      runtimeGeneration: this.runtimeGeneration,
      eventSequence: this.eventSequence,
      revision: this.revision,
      data,
    });
  }

  private summary(): SessionSummaryUpdate {
    if (this.summaryContentDirty || !this.cachedSummaryContent) {
      const entries = this.sessionManager.getEntries();
      let firstMessage = "";
      let messageCount = 0;
      let updatedAt = this.sessionManager.getHeader()?.timestamp ?? new Date().toISOString();
      for (const entry of entries) {
        if (entry.type === "message") {
          messageCount += 1;
          if (!firstMessage && entry.message.role === "user") {
            firstMessage = boundedSummaryText((typeof entry.message.content === "string"
              ? entry.message.content
              : entry.message.content.flatMap((part) => part.type === "text" ? [part.text] : []).join(""))
              .trim());
          }
        }
        updatedAt = entry.timestamp;
      }
      const rawName = this.sessionManager.getSessionName();
      const name = rawName ? boundedSummaryText(rawName) : undefined;
      this.cachedSummaryContent = {
        ...(name ? { name } : {}),
        updatedAt,
        messageCount,
        firstMessage,
      };
      this.summaryContentDirty = false;
    }
    return {
      sessionId: this.id,
      summaryRevision: 0,
      phase: this.effectivePhase,
      ...this.cachedSummaryContent,
    };
  }

  private onEvent(event: AgentSessionEvent): void {
    this.revision += 1;
    this.touch();
    switch (event.type) {
      case "agent_start":
        this.phase = "running";
        this.toolExecutions.clear();
        this.nextToolOrder = 0;
        this.activeOperationId ??= randomUUID();
        this.operation ??= { id: this.activeOperationId, kind: "prompt", startedAt: new Date().toISOString() };
        void this.dependencies.markers.mark(this.id, this.activeOperationId);
        if (!this.activityHeartbeat) this.startActivityHeartbeat();
        this.publishSnapshot();
        break;
      case "agent_settled":
        // An extension completion can trigger the next turn while the previous
        // settlement callback is still unwinding. Never let that older callback
        // mark a newer agent-core run idle or erase its live tools.
        if (this.hasActiveAgentRun) {
          this.ensureAgentProjection();
          this.publishSnapshot();
          break;
        }
        this.phase = "idle";
        this.activeOperationId = undefined;
        this.operation = undefined;
        this.retry = undefined;
        this.toolExecutions.clear();
        this.nextToolOrder = 0;
        this.stopActivityHeartbeat();
        this.clearToolProgressTimers();
        void this.dependencies.markers.clear(this.id);
        this.hooks.settled(this.id);
        this.publishSnapshot();
        break;
      case "compaction_start":
        this.phase = "compacting";
        this.operation = { kind: "compaction", startedAt: new Date().toISOString(), reason: event.reason };
        this.publishSnapshot();
        break;
      case "compaction_end":
        this.retry = undefined;
        this.emit("session.compaction", safeJson(event));
        this.scheduleSnapshot();
        break;
      case "auto_retry_start":
        this.phase = "retrying";
        this.retry = {
          source: "agent",
          attempt: event.attempt,
          maxAttempts: event.maxAttempts,
          delayMs: event.delayMs,
          errorMessage: event.errorMessage,
        };
        this.operation = { kind: "retry", startedAt: new Date().toISOString() };
        this.publishSnapshot();
        break;
      case "summarization_retry_scheduled":
        this.phase = "retrying";
        this.retry = {
          source: this.operation?.kind === "branchSummary" ? "branchSummary" : "compaction",
          attempt: event.attempt,
          maxAttempts: event.maxAttempts,
          delayMs: event.delayMs,
          errorMessage: event.errorMessage,
        };
        this.publishSnapshot();
        break;
      case "summarization_retry_attempt_start":
        this.retry = this.retry ? { ...this.retry, source: event.source } : { source: event.source, attempt: 1 };
        this.publishSnapshot();
        break;
      case "summarization_retry_finished":
        this.retry = undefined;
        this.scheduleSnapshot();
        break;
      case "auto_retry_end":
        this.emit("session.retry", safeJson(event));
        // Retry completion is nested inside the overall AgentSession run. Only
        // `agent_settled` owns the foreground-to-idle transition; otherwise an
        // aborted/failed retry can hide a continuation that is already active.
        this.ensureAgentProjection();
        this.retry = undefined;
        this.scheduleSnapshot();
        break;
      case "message_update": {
        if (!this.hasActiveAgentRun) break;
        this.ensureAgentProjection();
        const message = projectMessage("streaming", null, new Date().toISOString(), event.message, this.dependencies.blobs);
        this.emit("session.progress", safeJson({ message }));
        break;
      }
      case "tool_execution_start": {
        if (!this.hasActiveAgentRun) break;
        this.ensureAgentProjection();
        const now = new Date().toISOString();
        const existing = this.toolExecutions.get(event.toolCallId);
        const startedAt = existing?.startedAt ?? now;
        const progressSequence = (existing?.progressSequence ?? 0) + 1;
        const state: ToolExecutionState = {
          toolCallId: event.toolCallId,
          toolName: event.toolName,
          order: existing?.order ?? this.nextToolOrder++,
          status: "running",
          arguments: projectJson(event.args),
          isError: false,
          startedAt,
          updatedAt: now,
          lastProgressAt: now,
          progressSequence,
        };
        this.toolExecutions.set(event.toolCallId, state);
        this.rememberToolMetadata(event.toolCallId, state);
        this.publishToolProgress(state, true);
        this.scheduleSnapshot();
        break;
      }
      case "tool_execution_update": {
        if (!this.hasActiveAgentRun) break;
        this.ensureAgentProjection();
        const now = new Date().toISOString();
        const existing = this.toolExecutions.get(event.toolCallId);
        const output = projectToolOutput(event.partialResult);
        const state: ToolExecutionState = {
          toolCallId: event.toolCallId,
          toolName: event.toolName,
          order: existing?.order ?? this.nextToolOrder++,
          status: "running",
          arguments: projectJson(event.args),
          partialResult: projectToolResult(event.partialResult),
          ...(output.output === undefined
            ? (existing?.output === undefined ? {} : {
                output: existing.output,
                ...(existing.outputTruncated ? { outputTruncated: true } : {}),
              })
            : output),
          isError: false,
          startedAt: existing?.startedAt ?? now,
          updatedAt: now,
          lastProgressAt: now,
          progressSequence: (existing?.progressSequence ?? 0) + 1,
        };
        this.toolExecutions.set(event.toolCallId, state);
        this.rememberToolMetadata(event.toolCallId, state);
        this.publishToolProgress(state);
        break;
      }
      case "tool_execution_end": {
        if (!this.hasActiveAgentRun) break;
        this.ensureAgentProjection();
        const now = new Date().toISOString();
        const existing = this.toolExecutions.get(event.toolCallId);
        const startedAt = existing?.startedAt ?? now;
        const output = projectToolOutput(event.result);
        const state: ToolExecutionState = {
          toolCallId: event.toolCallId,
          toolName: event.toolName,
          order: existing?.order ?? this.nextToolOrder++,
          status: event.isError ? "failed" : "completed",
          arguments: existing?.arguments ?? null,
          ...(existing?.partialResult === undefined ? {} : { partialResult: existing.partialResult }),
          result: projectToolResult(event.result),
          ...(output.output === undefined
            ? (existing?.output === undefined ? {} : {
                output: existing.output,
                ...(existing.outputTruncated ? { outputTruncated: true } : {}),
              })
            : output),
          isError: event.isError,
          startedAt,
          updatedAt: now,
          lastProgressAt: now,
          completedAt: now,
          durationMs: Number.isFinite(Date.parse(startedAt)) ? Math.max(0, Date.parse(now) - Date.parse(startedAt)) : 0,
          progressSequence: (existing?.progressSequence ?? 0) + 1,
        };
        this.toolExecutions.set(event.toolCallId, state);
        this.rememberToolMetadata(event.toolCallId, state);
        this.publishToolProgress(state, true);
        this.scheduleSnapshot();
        break;
      }
      case "bash_execution_update":
        this.emit("session.bashProgress", safeJson(event));
        break;
      case "entry_appended":
        this.summaryContentDirty = true;
        if (event.entry.type === "message" && event.entry.message.role === "toolResult") {
          // The canonical result now owns presentation. Keeping the same payload
          // in the live overlay for the rest of a long run duplicates output and
          // can grow snapshots without bound.
          this.toolExecutions.delete(event.entry.message.toolCallId);
        }
        this.emit("session.structureChanged", { branchChanged: false });
        this.scheduleSnapshot();
        break;
      case "message_end":
        this.scheduleSnapshot();
        break;
      case "queue_update":
        if (!this.suppressQueueEvents) this.reconcileQueuedMessages();
        this.scheduleSnapshot();
        break;
      case "thinking_level_changed":
        this.emit("session.contextChanged", {});
        this.scheduleSnapshot();
        break;
      case "session_info_changed":
        this.summaryContentDirty = true;
        this.scheduleSnapshot();
        this.hooks.changed(this.id);
        break;
      default:
        break;
    }
  }

  private publishToolProgress(state: ToolExecutionState, immediate = false): void {
    const minimumIntervalMs = 200;
    const now = Date.now();
    const last = this.toolProgressPublishedAt.get(state.toolCallId) ?? 0;
    const pending = this.toolProgressTimers.get(state.toolCallId);
    if (immediate || now - last >= minimumIntervalMs) {
      if (pending) clearTimeout(pending);
      this.toolProgressTimers.delete(state.toolCallId);
      this.toolProgressPublishedAt.set(state.toolCallId, now);
      this.emit("session.toolProgress", safeJson(state));
      return;
    }
    if (pending) return;
    const timer = setTimeout(() => {
      this.toolProgressTimers.delete(state.toolCallId);
      const current = this.toolExecutions.get(state.toolCallId);
      if (!current) return;
      this.toolProgressPublishedAt.set(state.toolCallId, Date.now());
      this.emit("session.toolProgress", safeJson(current));
    }, minimumIntervalMs - (now - last));
    timer.unref();
    this.toolProgressTimers.set(state.toolCallId, timer);
  }

  private clearToolProgressTimers(): void {
    for (const timer of this.toolProgressTimers.values()) clearTimeout(timer);
    this.toolProgressTimers.clear();
    this.toolProgressPublishedAt.clear();
  }

  private startActivityHeartbeat(): void {
    this.stopActivityHeartbeat();
    this.activityHeartbeat = setInterval(() => {
      if (this.disposed || !this.isBusy) return;
      this.emit("session.heartbeat", safeJson({
        phase: this.effectivePhase,
        ...(this.activeOperationId ? { operationId: this.activeOperationId } : {}),
        activeToolCallIds: [...this.toolExecutions.values()]
          .filter((tool) => tool.status === "running")
          .map((tool) => tool.toolCallId),
      }));
    }, 10_000);
    this.activityHeartbeat.unref();
  }

  private stopActivityHeartbeat(): void {
    if (this.activityHeartbeat) clearInterval(this.activityHeartbeat);
    this.activityHeartbeat = undefined;
  }

  private rememberToolMetadata(toolCallId: string, state: ToolExecutionState): void {
    this.toolMetadata.delete(toolCallId);
    this.toolMetadata.set(toolCallId, {
      startedAt: state.startedAt,
      ...(state.completedAt ? { completedAt: state.completedAt } : {}),
      ...(state.durationMs === undefined ? {} : { durationMs: state.durationMs }),
      lastProgressAt: state.lastProgressAt,
      progressSequence: state.progressSequence,
    });
    while (this.toolMetadata.size > 2_048) {
      const oldest = this.toolMetadata.keys().next().value as string | undefined;
      if (!oldest) break;
      this.toolMetadata.delete(oldest);
    }
  }

  private scheduleSnapshot(): void {
    if (this.snapshotTimer) return;
    this.snapshotTimer = setTimeout(() => {
      this.snapshotTimer = undefined;
      this.publishSnapshot();
    }, 20);
  }

  private reconcileQueuedMessages(): void {
    const session = this.runtime.session;
    const actual: Record<QueueBehavior, readonly string[]> = {
      steer: session.getSteeringMessages(),
      followUp: session.getFollowUpMessages(),
    };
    const previous = this.queuedMessages;
    const reconciled: RuntimeQueuedMessage[] = [];

    for (const behavior of ["steer", "followUp"] as const) {
      const old = previous.filter((item) => item.behavior === behavior);
      const nextTexts = actual[behavior];
      let overlap = Math.min(old.length, nextTexts.length);
      while (overlap > 0) {
        const oldStart = old.length - overlap;
        let matches = true;
        for (let index = 0; index < overlap; index += 1) {
          if (old[oldStart + index]?.runtimeText !== nextTexts[index]) {
            matches = false;
            break;
          }
        }
        if (matches) break;
        overlap -= 1;
      }

      reconciled.push(...old.slice(old.length - overlap));
      for (const runtimeText of nextTexts.slice(overlap)) {
        const admission = this.pendingQueueAdmission?.behavior === behavior
          ? this.pendingQueueAdmission
          : undefined;
        if (admission) this.pendingQueueAdmission = undefined;
        reconciled.push({
          id: admission?.id ?? randomUUID(),
          behavior,
          text: admission?.text ?? runtimeText,
          attachmentCount: admission?.attachmentCount ?? 0,
          runtimeText,
          attachmentEnvelope: admission?.attachmentEnvelope ?? "",
          images: admission?.images ?? [],
          ordinal: this.nextQueueOrdinal++,
        });
      }
    }

    reconciled.sort((left, right) => left.behavior === right.behavior
      ? left.ordinal - right.ordinal
      : left.behavior === "steer" ? -1 : 1);
    const changed = previous.length !== reconciled.length || previous.some((item, index) => {
      const next = reconciled[index];
      return next === undefined
        || item.id !== next.id
        || item.behavior !== next.behavior
        || item.text !== next.text
        || item.runtimeText !== next.runtimeText
        || item.attachmentCount !== next.attachmentCount;
    });
    this.queuedMessages = reconciled;
    if (changed) this.queueRevision += 1;
  }

  private projectedQueue(): QueuedMessageState[] {
    this.reconcileQueuedMessages();
    return this.queuedMessages.map(({ id, behavior, text, attachmentCount }) => ({
      id,
      behavior,
      text,
      attachmentCount,
    }));
  }

  private static queueText(text: string, attachmentEnvelope: string): string {
    return [text.trim(), attachmentEnvelope].filter(Boolean).join("\n\n");
  }

  private static validateQueue(items: Array<Pick<QueuedMessageState, "text" | "attachmentCount">>): void {
    if (items.length > MAXIMUM_QUEUED_MESSAGES) {
      throw new GatewayError("invalid_request", `At most ${MAXIMUM_QUEUED_MESSAGES} messages may be queued`);
    }
    let totalBytes = 0;
    for (const item of items) {
      const bytes = Buffer.byteLength(item.text);
      if (bytes > MAXIMUM_QUEUED_MESSAGE_BYTES) {
        throw new GatewayError("invalid_request", "A queued message is too large to manage safely");
      }
      if (item.text.trim().length === 0 && item.attachmentCount === 0) {
        throw new GatewayError("invalid_request", "Queued messages cannot be empty");
      }
      totalBytes += bytes;
    }
    if (totalBytes > MAXIMUM_QUEUED_TOTAL_BYTES) {
      throw new GatewayError("invalid_request", "The queued message total is too large to manage safely");
    }
  }

  snapshot(sequence = this.eventSequence): SessionSnapshot {
    this.assertNoTrustReload();
    const session = this.runtime.session;
    this.ensureAgentProjection();
    const contextUsage = session.getContextUsage();
    const stats = session.getSessionStats();
    const latestCacheHitRate = this.latestCacheHitRate();
    const streaming = session.state.streamingMessage
      ? projectMessage("streaming", null, new Date().toISOString(), session.state.streamingMessage, this.dependencies.blobs)
      : undefined;
    const transcriptPage = this.transcriptPage();
    const queuedItems = this.projectedQueue();
    return fitSessionSnapshot({
      sessionId: session.sessionId,
      runtimeGeneration: this.runtimeGeneration,
      revision: this.revision,
      eventSequence: sequence,
      phase: this.effectivePhase,
      ...(session.sessionName ? { name: session.sessionName } : {}),
      cwd: session.sessionManager.getCwd(),
      ...(session.sessionManager.getHeader()?.parentSession ? { parentSessionId: session.sessionManager.getHeader()!.parentSession } : {}),
      ...(session.model ? { model: { provider: session.model.provider, id: session.model.id } } : {}),
      thinkingLevel: session.thinkingLevel,
      availableThinkingLevels: session.getAvailableThinkingLevels(),
      ...(contextUsage ? { contextUsage } : {}),
      stats: {
        userMessages: stats.userMessages,
        assistantMessages: stats.assistantMessages,
        toolCalls: stats.toolCalls,
        toolResults: stats.toolResults,
        totalMessages: stats.totalMessages,
        tokens: stats.tokens,
        ...(latestCacheHitRate === undefined ? {} : { latestCacheHitRate }),
        cost: stats.cost,
      },
      queued: { steering: [...session.getSteeringMessages()], followUp: [...session.getFollowUpMessages()] },
      queueRevision: this.queueRevision,
      queuedItems,
      transcript: transcriptPage.items,
      transcriptStart: transcriptPage.start,
      transcriptTotal: transcriptPage.total,
      ...(streaming ? { streaming } : {}),
      ...(session.sessionManager.getLeafId() ? { leafEntryId: session.sessionManager.getLeafId()! } : {}),
      ...(this.operation ? { operation: this.operation } : {}),
      ...(this.retry ? { retry: this.retry } : {}),
      toolExecutions: [...this.toolExecutions.values()]
        .filter((tool) => this.effectivePhase === "running" || tool.status !== "running")
        .sort((left, right) => left.order - right.order),
      extensionUI: this.ui.state(),
      diagnostics: this.runtime.diagnostics.map((diagnostic) => ({ type: diagnostic.type, message: diagnostic.message })),
    });
  }

  transcriptPage(before?: number, expectedNextEntryId?: string): TranscriptPage {
    this.assertNoTrustReload();
    try {
      return projectTranscriptPage(
        this.runtime.session.sessionManager,
        this.dependencies.blobs,
        before,
        undefined,
        expectedNextEntryId,
        this.toolMetadata,
      );
    } catch (error) {
      if (error instanceof Error && error.message.includes("anchor changed")) {
        throw new GatewayError("conflict", "The session branch changed while loading history. Refresh the session and try again.", true);
      }
      throw error;
    }
  }

  publishSnapshot(): void {
    if (this.disposed || this.trustReloadPending) return;
    this.eventSequence += 1;
    this.hooks.broadcast(this.id, "session.snapshot", this.snapshot(this.eventSequence) as unknown as JsonValue);
    const summary = this.summary();
    if (!this.lastPublishedSummary
      || summary.sessionId !== this.lastPublishedSummary.sessionId
      || summary.phase !== this.lastPublishedSummary.phase
      || summary.name !== this.lastPublishedSummary.name
      || summary.updatedAt !== this.lastPublishedSummary.updatedAt
      || summary.messageCount !== this.lastPublishedSummary.messageCount
      || summary.firstMessage !== this.lastPublishedSummary.firstMessage) {
      this.lastPublishedSummary = summary;
      this.hooks.summaryChanged(summary);
    }
  }

  async prompt(
    text: string,
    images: ImageContent[] = [],
    behavior?: QueueBehavior,
    queueDisplay?: { text: string; attachmentEnvelope: string; attachmentCount: number },
  ): Promise<{ operationId: string }> {
    return this.lane.run(async () => {
      this.assertUsable();
      const session = this.runtime.session;
      if (session.isStreaming && !behavior) throw new GatewayError("busy", "Session is running; choose steer or follow-up");
      if (session.isStreaming && behavior) {
        this.reconcileQueuedMessages();
        const display = queueDisplay ?? { text, attachmentEnvelope: "", attachmentCount: images.length };
        RuntimeSlot.validateQueue([
          ...this.queuedMessages,
          { text: display.text, attachmentCount: display.attachmentCount },
        ]);
        this.pendingQueueAdmission = {
          id: randomUUID(),
          behavior,
          text: display.text,
          attachmentCount: display.attachmentCount,
          attachmentEnvelope: display.attachmentEnvelope,
          images,
        };
      }
      const operationId = randomUUID();
      this.activeOperationId = operationId;
      this.operation = { id: operationId, kind: "prompt", startedAt: new Date().toISOString() };
      let acceptedResolve!: (accepted: boolean) => void;
      const accepted = new Promise<boolean>((resolve) => { acceptedResolve = resolve; });
      const run = session.prompt(text, {
        images,
        ...(behavior ? { streamingBehavior: behavior } : {}),
        source: "rpc",
        preflightResult: acceptedResolve,
      });
      void run.catch((error) => {
        this.emit("session.operationFailed", safeJson({ operationId, message: error instanceof Error ? error.message : String(error) }));
        if (!session.isStreaming) {
          this.phase = "idle";
          this.activeOperationId = undefined;
          this.operation = undefined;
          void this.dependencies.markers.clear(this.id);
          this.hooks.settled(this.id);
          this.publishSnapshot();
        }
      });
      let admitted: boolean;
      try {
        // Pi's preflight callback is the sole authority for whether canonical work
        // was admitted. A gateway-local deadline cannot safely reject this RPC:
        // the same uncancelled runtime call could still accept and start later.
        admitted = await accepted;
      } finally {
        this.pendingQueueAdmission = undefined;
      }
      if (!admitted) {
        this.operation = undefined;
        throw new GatewayError("invalid_request", "The agent runtime rejected the prompt before admission");
      }
      await this.dependencies.markers.mark(this.id, operationId);
      this.revision += 1;
      this.publishSnapshot();
      return { operationId };
    });
  }

  async abort(kind: "agent" | "compaction" | "retry" | "branchSummary" | "bash" = "agent"): Promise<void> {
    this.assertUsable();
    const session = this.runtime.session;
    switch (kind) {
      case "compaction": session.abortCompaction(); break;
      case "retry": session.abortRetry(); break;
      case "branchSummary": session.abortBranchSummary(); break;
      case "bash": session.abortBash(); break;
      case "agent": await session.abort(); break;
    }
    this.revision += 1;
    this.publishSnapshot();
  }

  async clearQueue(): Promise<{ steering: string[]; followUp: string[] }> {
    return this.lane.run(() => {
      this.assertUsable();
      this.suppressQueueEvents = true;
      let cleared: { steering: string[]; followUp: string[] };
      try {
        cleared = this.runtime.session.clearQueue();
      } finally {
        this.suppressQueueEvents = false;
      }
      this.queuedMessages = [];
      this.queueRevision += 1;
      this.revision += 1;
      this.publishSnapshot();
      return { steering: [...cleared.steering], followUp: [...cleared.followUp] };
    });
  }

  async replaceQueue(
    expectedRevision: number,
    items: Array<Pick<QueuedMessageState, "id" | "behavior" | "text">>,
  ): Promise<{ queueRevision: number; items: QueuedMessageState[] }> {
    return this.lane.run(async () => {
      this.assertUsable();
      const session = this.runtime.session;
      this.reconcileQueuedMessages();
      if (expectedRevision !== this.queueRevision) {
        throw new GatewayError("conflict", "The message queue changed. Review the latest queue and try again.", true);
      }
      if (!session.isStreaming && items.length > 0) {
        throw new GatewayError("conflict", "The active run finished before the queue could be updated.", true);
      }

      const previousByID = new Map(this.queuedMessages.map((item) => [item.id, item]));
      const seen = new Set<string>();
      const next = items.map((item) => {
        const previous = previousByID.get(item.id);
        if (!previous || !seen.add(item.id)) {
          throw new GatewayError("conflict", "The message queue changed. Review the latest queue and try again.", true);
        }
        const text = item.text.trim();
        return {
          ...previous,
          behavior: item.behavior,
          text,
          runtimeText: text === previous.text
            ? previous.runtimeText
            : RuntimeSlot.queueText(text, previous.attachmentEnvelope),
          ordinal: this.nextQueueOrdinal++,
        };
      });
      RuntimeSlot.validateQueue(next);

      const extensionCommands = new Set(
        this.commands().filter((command) => command.source === "extension").map((command) => command.name),
      );
      for (const item of next) {
        if (!item.runtimeText.startsWith("/")) continue;
        const command = item.runtimeText.slice(1).split(/\s/u, 1)[0] ?? "";
        if (extensionCommands.has(command)) {
          throw new GatewayError("invalid_request", `Extension command "/${command}" cannot be queued`);
        }
      }

      let rebuildError: unknown;
      this.suppressQueueEvents = true;
      try {
        session.clearQueue();
        const queued = next.map((item) => item.behavior === "steer"
          ? session.steer(item.runtimeText, item.images)
          : session.followUp(item.runtimeText, item.images));
        await Promise.all(queued);
      } catch (error) {
        rebuildError = error;
      } finally {
        this.suppressQueueEvents = false;
      }
      if (rebuildError !== undefined) {
        this.reconcileQueuedMessages();
        this.revision += 1;
        this.publishSnapshot();
        throw rebuildError;
      }

      const actual: Record<QueueBehavior, readonly string[]> = {
        steer: session.getSteeringMessages(),
        followUp: session.getFollowUpMessages(),
      };
      const survivors: RuntimeQueuedMessage[] = [];
      for (const behavior of ["steer", "followUp"] as const) {
        const desired = next.filter((item) => item.behavior === behavior);
        const texts = actual[behavior];
        const retained = desired.slice(Math.max(0, desired.length - texts.length));
        const aligned = retained.slice(Math.max(0, retained.length - texts.length));
        for (let index = 0; index < aligned.length; index += 1) {
          survivors.push({ ...aligned[index]!, runtimeText: texts[texts.length - aligned.length + index]! });
        }
      }
      this.queuedMessages = survivors.sort((left, right) => left.behavior === right.behavior
        ? left.ordinal - right.ordinal
        : left.behavior === "steer" ? -1 : 1);
      this.queueRevision += 1;
      this.revision += 1;
      this.publishSnapshot();
      return { queueRevision: this.queueRevision, items: this.projectedQueue() };
    });
  }

  async setModel(provider: string, modelId: string): Promise<void> {
    await this.lane.run(async () => {
      this.assertIdle();
      const model = this.runtime.session.modelRuntime.getModel(provider, modelId);
      if (!model) throw new GatewayError("not_found", "Model is not registered in Tron");
      await this.runtime.session.setModel(model as Model<never>);
      this.revision += 1;
      this.publishSnapshot();
    });
  }

  async setThinking(level: "off" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max"): Promise<void> {
    await this.lane.run(() => {
      this.assertIdle();
      this.runtime.session.setThinkingLevel(level);
      this.revision += 1;
      this.publishSnapshot();
    });
  }

  async setTools(toolNames: string[]): Promise<void> {
    await this.lane.run(() => {
      this.assertIdle();
      const known = new Set(this.runtime.session.getAllTools().map((tool) => tool.name));
      const unknown = toolNames.filter((name) => !known.has(name));
      if (unknown.length > 0) throw new GatewayError("invalid_request", `Unknown agent tools: ${unknown.join(", ")}`);
      this.runtime.session.setActiveToolsByName(toolNames);
      this.revision += 1;
      this.emit("session.contextChanged", {});
      this.publishSnapshot();
    });
  }

  async compact(instructions?: string): Promise<void> {
    await this.lane.run(async () => {
      this.assertIdle();
      this.phase = "compacting";
      this.operation = { kind: "compaction", startedAt: new Date().toISOString(), reason: "manual" };
      this.revision += 1;
      this.publishSnapshot();
      try {
        await this.runtime.session.compact(instructions);
      } finally {
        this.phase = "idle";
        this.operation = undefined;
        this.retry = undefined;
        this.revision += 1;
        this.publishSnapshot();
      }
    });
  }

  async executeBash(command: string, excludeFromContext: boolean): Promise<JsonValue> {
    return this.lane.run(async () => {
      this.assertIdle();
      const operationId = randomUUID();
      this.phase = "running";
      this.operation = { id: operationId, kind: "bash", startedAt: new Date().toISOString() };
      this.revision += 1;
      this.publishSnapshot();
      try {
        return safeJson(await this.runtime.session.executeBash(command, undefined, { excludeFromContext, id: operationId }));
      } finally {
        this.phase = "idle";
        this.operation = undefined;
        this.revision += 1;
        this.publishSnapshot();
      }
    });
  }

  async rename(name: string): Promise<void> {
    await this.lane.run(() => {
      this.assertUsable();
      this.runtime.session.setSessionName(name);
      this.summaryContentDirty = true;
      this.revision += 1;
      this.publishSnapshot();
      this.hooks.changed(this.id);
    });
  }

  async setLabel(entryId: string, label?: string): Promise<void> {
    await this.lane.run(() => {
      this.assertIdle();
      if (!this.sessionManager.getEntry(entryId)) throw new GatewayError("not_found", "Session entry was not found");
      this.sessionManager.appendLabelChange(entryId, label?.trim() || undefined);
      this.summaryContentDirty = true;
      this.revision += 1;
      this.emit("session.structureChanged", { branchChanged: false });
      this.publishSnapshot();
    });
  }

  async fork(entryId: string, position: "before" | "at" = "at"): Promise<{ sessionId: string; selectedText?: string }> {
    return this.lane.run(async () => {
      this.assertIdle();
      const previous = this.id;
      const result = await this.runtime.fork(entryId, { position });
      if (result.cancelled) throw new GatewayError("cancelled", "Fork was cancelled by an extension");
      const next = this.id;
      if (previous !== next) this.hooks.rekey(previous, next, this);
      this.summaryContentDirty = true;
      this.revision += 1;
      this.emit("session.structureChanged", { branchChanged: true });
      this.publishSnapshot();
      return { sessionId: next, ...(result.selectedText ? { selectedText: result.selectedText } : {}) };
    });
  }

  async navigate(
    targetId: string,
    options: { summarize: boolean; instructions?: string; replaceInstructions?: boolean; label?: string },
  ): Promise<{ editorText?: string }> {
    return this.lane.run(async () => {
      this.assertIdle();
      const ownsBranchSummary = options.summarize;
      this.operation = ownsBranchSummary ? { kind: "branchSummary", startedAt: new Date().toISOString() } : undefined;
      let completed = false;
      try {
        const result = await this.runtime.session.navigateTree(targetId, {
          summarize: options.summarize,
          ...(options.instructions ? { customInstructions: options.instructions } : {}),
          ...(options.replaceInstructions === undefined ? {} : { replaceInstructions: options.replaceInstructions }),
          ...(options.label ? { label: options.label } : {}),
        });
        if (result.cancelled) throw new GatewayError("cancelled", "Tree navigation was cancelled by an extension");
        this.summaryContentDirty = true;
        completed = true;
        this.revision += 1;
        this.emit("session.structureChanged", { branchChanged: true });
        return result.editorText ? { editorText: result.editorText } : {};
      } finally {
        if (this.operation?.kind === "branchSummary") this.operation = undefined;
        if (this.retry?.source === "branchSummary") {
          this.retry = undefined;
          if (this.phase === "retrying") this.phase = "idle";
        }
        if (!completed && ownsBranchSummary) this.revision += 1;
        if (completed || ownsBranchSummary) this.publishSnapshot();
      }
    });
  }

  private latestCacheHitRate(): number | undefined {
    const entries = this.runtime.session.sessionManager.getEntries();
    for (let index = entries.length - 1; index >= 0; index -= 1) {
      const entry = entries[index]!;
      if (entry.type !== "message" || entry.message.role !== "assistant") continue;
      const { input, cacheRead, cacheWrite } = entry.message.usage;
      const promptTokens = input + cacheRead + cacheWrite;
      return promptTokens > 0 ? (cacheRead / promptTokens) * 100 : undefined;
    }
    return undefined;
  }

  tree(): SessionTreeNode[] {
    this.assertNoTrustReload();
    return projectTree(this.runtime.session.sessionManager, this.dependencies.blobs);
  }

  commands(): CommandInfo[] {
    this.assertNoTrustReload();
    const session = this.runtime.session;
    const extension: CommandInfo[] = session.extensionRunner.getRegisteredCommands().map((command) => ({
      name: command.invocationName,
      ...(command.description ? { description: command.description } : {}),
      source: "extension",
      sourcePath: command.sourceInfo.path,
    }));
    const prompts: CommandInfo[] = session.promptTemplates.map((prompt) => ({
      name: prompt.name,
      ...(prompt.description ? { description: prompt.description } : {}),
      ...(prompt.argumentHint ? { argumentHint: prompt.argumentHint } : {}),
      source: "prompt",
      sourcePath: prompt.filePath,
    }));
    const skills: CommandInfo[] = session.resourceLoader.getSkills().skills.map((skill) => ({
      name: `skill:${skill.name}`,
      ...(skill.description ? { description: skill.description } : {}),
      source: "skill",
      sourcePath: skill.filePath,
    }));
    return [...extension, ...prompts, ...skills].sort((a, b) => a.name.localeCompare(b.name));
  }

  context(): JsonValue {
    this.assertNoTrustReload();
    const session = this.runtime.session;
    return safeJson({
      systemPrompt: session.systemPrompt,
      contextUsage: session.getContextUsage(),
      stats: session.getSessionStats(),
      activeTools: session.getActiveToolNames(),
      availableTools: session.getAllTools(),
      commands: this.commands(),
      ...this.resourcesValue(),
      diagnostics: this.runtime.diagnostics,
    });
  }

  resources(): JsonValue {
    this.assertNoTrustReload();
    return safeJson({ commands: this.commands(), ...this.resourcesValue() });
  }

  private resourcesValue(): Record<string, unknown> {
    const session = this.runtime.session;
    const loader = session.resourceLoader;
    return {
      tools: session.getAllTools().map((tool) => ({
        name: tool.name,
        description: tool.description,
        scope: tool.sourceInfo.scope,
        source: tool.sourceInfo.source,
        parameters: tool.parameters,
        promptGuidelines: tool.promptGuidelines,
      })),
      skills: {
        skills: loader.getSkills().skills.map((skill) => ({
          name: skill.name,
          description: skill.description,
          path: skill.filePath,
          scope: skill.sourceInfo.scope,
          source: skill.sourceInfo.source,
          disableModelInvocation: skill.disableModelInvocation,
        })),
        diagnostics: loader.getSkills().diagnostics,
      },
      prompts: {
        prompts: loader.getPrompts().prompts.map((prompt) => ({
          name: prompt.name,
          description: prompt.description,
          argumentHint: prompt.argumentHint,
          path: prompt.filePath,
          scope: prompt.sourceInfo.scope,
          source: prompt.sourceInfo.source,
        })),
        diagnostics: loader.getPrompts().diagnostics,
      },
      extensions: loader.getExtensions().extensions.map((extension) => ({
        name: basename(extension.path),
        path: extension.path,
        resolvedPath: extension.resolvedPath,
        scope: extension.sourceInfo.scope,
        source: extension.sourceInfo.source,
        tools: Array.from(extension.tools.keys()),
        commands: Array.from(extension.commands.keys()),
      })),
      contextFiles: loader.getAgentsFiles().agentsFiles.map((file) => ({
        name: basename(file.path),
        path: file.path,
      })),
    };
  }

  respondToInteraction(id: string, value: unknown, cancelled: boolean): void {
    this.assertNoTrustReload();
    this.ui.respond(id, value, cancelled);
  }

  beginTrustReload(): void {
    if (this.trustReloadPending) return;
    this.assertIdle();
    this.trustReloadPending = true;
  }

  async reload(projectTrusted?: boolean, publish = true, trustTransition = false): Promise<void> {
    await this.lane.run(async () => {
      this.assertIdle(trustTransition);
      const previousOverride = this.projectTrustReloadOverride;
      this.projectTrustReloadOverride = projectTrusted;
      try {
        await this.runtime.session.resourceLoader.reload(this.effectiveResourceReloadOptions());
        await this.runtime.session.reload();
        if (publish) this.commitReload();
      } finally {
        this.projectTrustReloadOverride = previousOverride;
      }
    });
  }

  commitReload(): void {
    this.trustReloadPending = false;
    this.revision += 1;
    this.emit("session.resourcesChanged", {});
    this.publishSnapshot();
  }

  async importFromJsonl(path: string, cwdOverride?: string): Promise<void> {
    await this.lane.run(async () => {
      this.assertIdle();
      const result = await this.runtime.importFromJsonl(path, cwdOverride);
      if (result.cancelled) throw new GatewayError("cancelled", "Session import was cancelled by an extension");
      this.summaryContentDirty = true;
      this.revision += 1;
      this.publishSnapshot();
      this.hooks.changed(this.id);
    });
  }

  async export(format: "html" | "jsonl"): Promise<{ blobId: string; name: string; mimeType: string }> {
    this.assertUsable();
    const directory = await mkdtemp(join(tmpdir(), "tron-session-export-"));
    try {
      const output = join(directory, `session.${format}`);
      const path = format === "html"
        ? await this.runtime.session.exportToHtml(output)
        : this.runtime.session.exportToJsonl(output);
      const mimeType = format === "html" ? "text/html; charset=utf-8" : "application/x-ndjson";
      const name = `${basename(this.runtime.session.sessionName ?? this.id).replace(/[^A-Za-z0-9._-]+/g, "-")}.${format}`;
      const metadata = await stat(path);
      if (!metadata.isFile() || metadata.size > BLOB_MAX_ITEM_BYTES) {
        throw new GatewayError("conflict", "Session export exceeds the 25 MiB limit");
      }
      return { blobId: this.dependencies.blobs.registerData(await readFile(path), mimeType), name, mimeType };
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  }

  async dispose(): Promise<void> {
    if (this.disposed) return;
    if (this.isBusy || this.trustReloadPending) throw new GatewayError("busy", "Cannot evict a busy session runtime");
    this.disposed = true;
    if (this.snapshotTimer) clearTimeout(this.snapshotTimer);
    this.stopActivityHeartbeat();
    this.clearToolProgressTimers();
    this.unsubscribe?.();
    this.ui.cancelAll();
    await this.runtime.dispose();
  }

  private assertNoTrustReload(): void {
    if (this.trustReloadPending) {
      throw new GatewayError("busy", "Project trust is being reconfigured", true);
    }
  }

  private assertUsable(allowTrustReload = false): void {
    if (this.disposed) throw new GatewayError("conflict", "Session runtime was disposed", true);
    if (!allowTrustReload) this.assertNoTrustReload();
    this.touch();
  }

  private assertIdle(allowTrustReload = false): void {
    this.assertUsable(allowTrustReload);
    if (this.runtime.session.isStreaming || this.isBusy) throw new GatewayError("busy", "Session must be idle for this operation");
  }
}
