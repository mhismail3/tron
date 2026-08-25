import { randomUUID } from "node:crypto";
import type { AgentMessage } from "@earendil-works/pi-agent-core";
import { existsSync, realpathSync, watch, type FSWatcher } from "node:fs";
import { performance } from "node:perf_hooks";
import { copyFile, mkdtemp, open, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, isAbsolute, join, relative, resolve } from "node:path";
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
  ExtensionRunActivity,
  ExtensionToolOrigin,
  JsonValue,
  QueuedMessageState,
  RetryState,
  SessionOperationState,
  SessionPhase,
  SessionSnapshot,
  PendingPromptState,
  SessionSummaryUpdate,
  SessionTreeNode,
  ToolExecutionState,
} from "../protocol/types.js";
import { AsyncMutex } from "../util/async-mutex.js";
import type { TrustService } from "../admin/trust-service.js";
import { BLOB_MAX_ITEM_BYTES, type BlobStore } from "./blob-store.js";
import { SemanticUIBroker } from "./semantic-ui-broker.js";
import { ExtensionPresentationStore } from "../extensions/host/extension-presentation-store.js";
import { ExtensionLifecycleCoordinator } from "./extension-lifecycle-coordinator.js";
import { RemotePiExtensionHost } from "../extensions/host/remote-pi-extension-host.js";
import {
  admitCommandCatalog,
  boundStreamingProgressItem,
  fitSessionSnapshot,
  projectJson,
  projectMessage,
  mergeLiveToolOutput,
  projectToolOutput,
  projectToolResult,
  projectTranscriptPage,
  projectTree,
  safeJson,
  type ToolProjectionMetadata,
  type TranscriptPage,
} from "./projection.js";
import type { RunMarkerStore } from "./run-markers.js";
import { attributeExtensions, extensionOwnerFor } from "../extensions/owner-attribution.js";
import { EXTENSION_LIFECYCLE_ARTIFACT_VERSION, admitExtensionLifecycleArtifact, admitExtensionRunActivity, boundExtensionActivities, extensionActivityId, extensionActivityStatusFromTool, extensionLifecycleState, extensionRunAsyncDir, hasStructuredExtensionRunActivity, normalizeExtensionArtifact, projectExtensionRunActivity } from "./extension-run-projection.js";
import { EXTENSION_ACTIVITY_RECEIPT_TYPE, extensionActivityHistoryRevision, extensionActivityReceipts, extensionReceiptActivity, listExtensionActivityHistory, makeExtensionActivityReceipt } from "./extension-activity-history.js";
import { ExtensionActivityRecency, type ActivityExpiryFrame, type ActivityVisibility } from "./extension-activity-recency.js";
import type { ExtensionActivityHistoryPage } from "./extension-activity-history.js";
import type { NotificationService } from "../notifications/notification-service.js";
import { createTronNotifyExtension } from "../notifications/tron-notify-extension.js";

export type SessionBroadcast = (sessionId: string, topic: string, payload: JsonValue) => void;

type QueueBehavior = QueuedMessageState["behavior"];

type RuntimeQueuedMessage = QueuedMessageState & {
  runtimeText: string;
  skillName?: string;
  attachmentEnvelope: string;
  images: ImageContent[];
  ordinal: number;
};

type PendingQueueAdmission = Omit<RuntimeQueuedMessage, "runtimeText" | "ordinal">;

type CanonicalExtensionRunFact = {
  toolCallId?: string;
  asyncDir?: string;
  terminal: boolean;
  ambiguous: boolean;
};

type PendingManualCompaction = {
  instructions?: string;
  resolve: () => void;
  reject: (error: unknown) => void;
};

const MAXIMUM_QUEUED_MESSAGES = 32;
const MAXIMUM_PROMPT_ATTACHMENTS = 10;
const MAXIMUM_QUEUED_MESSAGE_BYTES = 64 * 1_024;
const MAXIMUM_PENDING_PROMPT_BYTES = MAXIMUM_QUEUED_MESSAGE_BYTES;
const MAXIMUM_QUEUED_TOTAL_BYTES = 256 * 1_024;
/**
 * Streaming progress events republish the cumulative live message. Emitting
 * one per SDK update multiplies that payload across every subscribed mobile
 * connection and can overrun the synchronization quarantine during catch-up.
 * Coalescing keeps the first update immediate and republishes only the latest
 * cumulative state per window; intermediate frames are presentation-identical
 * because each payload fully replaces the client's streaming bubble.
 */
const STREAMING_PROGRESS_FLUSH_MS = 150;
const MAX_PRESENTATION_IDENTITY_BINDINGS = 512;
const MAX_EXTENSION_ARTIFACT_BYTES = 256 * 1_024;

function boundedSummaryText(value: string, maximumBytes = 1_024): string {
  const encoded = Buffer.from(value);
  if (encoded.length <= maximumBytes) return value;
  const suffix = "…";
  const available = Math.max(0, maximumBytes - Buffer.byteLength(suffix));
  return `${encoded.subarray(0, available).toString("utf8").replace(/\uFFFD$/u, "")}${suffix}`;
}

export type SessionAttentionRebindDisposition = "migrate" | "preserve" | "reset" | "discard";

export interface CanonicalAssistantCompletion {
  id: string;
  completedAt: string;
  operationId?: string;
}

type CanonicalCompletionEntry = {
  id: string;
  timestamp: string;
  type: string;
  message?: { role?: string; stopReason?: string };
};

export function successfulAssistantCompletion(
  entry: CanonicalCompletionEntry | undefined,
): CanonicalAssistantCompletion | undefined {
  if (entry?.type !== "message" || entry.message?.role !== "assistant") return undefined;
  if (entry.message.stopReason !== "stop" && entry.message.stopReason !== "length") return undefined;
  return { id: entry.id, completedAt: entry.timestamp };
}

export function latestSuccessfulAssistantCompletion(
  entries: readonly CanonicalCompletionEntry[],
): CanonicalAssistantCompletion | undefined {
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    const completion = successfulAssistantCompletion(entries[index]);
    if (completion) return completion;
  }
  return undefined;
}

export interface RuntimeSlotHooks {
  broadcast: SessionBroadcast;
  summaryChanged: (summary: SessionSummaryUpdate) => void;
  changed: (sessionId: string) => void;
  settled: (sessionId: string) => void;
  assistantResponseCompleted: (sessionId: string, completion: CanonicalAssistantCompletion, recovery: boolean) => Promise<void>;
  rekey: (previousId: string, nextId: string, slot: RuntimeSlot, disposition: SessionAttentionRebindDisposition) => Promise<void>;
  closed?: (sessionId: string, slot: RuntimeSlot) => void;
}

export interface RuntimeSlotDependencies {
  agentDir: string;
  createModelRuntime: () => Promise<ModelRuntime>;
  trust: TrustService;
  blobs: BlobStore;
  markers: RunMarkerStore;
  extensionActivityRecency: ExtensionActivityRecency;
  notifications?: NotificationService;
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
  private ui: SemanticUIBroker;
  private extensionHost: RemotePiExtensionHost;
  private lifecycle: ExtensionLifecycleCoordinator;
  private hasBoundSession = false;
  private readonly runtimeGeneration = randomUUID();
  /** Stable runtime-only catalog identity for a new session before Pi creates JSONL. */
  private readonly createdAt = new Date().toISOString();
  private revision = 0;
  private eventSequence = 0;
  private phase: SessionPhase;
  private disposed = false;
  private snapshotTimer: NodeJS.Timeout | undefined;
  private progressFlushTimer: NodeJS.Timeout | undefined;
  /** The latest cumulative SDK message is projected only at the wire flush boundary. */
  private pendingProgressMessage: AgentMessage | undefined;
  /** Last cumulative assistant projection survives Pi's pre-persistence
   * message_end hook window, when agent-core has already cleared its copy. */
  private latestStreamingMessage: AgentMessage | undefined;
  private streamIdentityMessage: AgentMessage | undefined;
  private streamAnchorId: string | null | undefined;
  private streamPresentationId: string | undefined;
  private streamStartedAt: string | undefined;
  private finalizedStreamPresentationId: string | undefined;
  /** Exact successful canonical assistant completion awaiting durable attention admission. */
  private pendingAssistantCompletion: CanonicalAssistantCompletion | undefined;
  private attentionBarrier: Promise<void> | undefined;
  private rebindAttentionDisposition: SessionAttentionRebindDisposition = "migrate";
  /** Disposable runtime-only bridge from canonical entry IDs to mounted turn IDs. */
  private readonly presentationIDs = new Map<string, string>();
  private readonly presentationIDOrder: string[] = [];
  private activityHeartbeat: NodeJS.Timeout | undefined;
  private readonly toolProgressTimers = new Map<string, NodeJS.Timeout>();
  private readonly toolProgressPublishedAt = new Map<string, number>();
  /** Monotonic invocation starts keep duration independent of wall-clock changes. */
  private readonly toolStartedAtMonotonicMs = new Map<string, number>();
  private activeOperationId: string | undefined;
  private activeExports = 0;
  private operation: SessionOperationState | undefined;
  private pendingExtensionCommand: SessionOperationState | undefined;
  private retry: RetryState | undefined;
  private resourceReloadOptions: { resolveProjectTrust: () => Promise<boolean> } | undefined;
  private projectTrustReloadOverride: boolean | undefined;
  private trustReloadPending = false;
  private readonly toolExecutions = new Map<string, ToolExecutionState>();
  /** Latched declaration facts keyed by exact Pi tool call ID. Runtime-only;
   * never persisted to canonical Pi JSONL. */
  private readonly toolInvocationGroups = new Map<string, Pick<ToolProjectionMetadata, "groupId" | "groupIndex" | "groupCount" | "groupFinalized">>();
  /** Bounded, disposable extension-owned run projections retain completed work
   * for Manage Session while the owning tool carries the live copy. */
  private readonly extensionActivities = new Map<string, ExtensionRunActivity>();
  /** Monotonic lifecycle projection ordering and terminal latches are runtime
   * facts; producer timestamps are display evidence only. */
  private readonly extensionActivitySequences = new Map<string, number>();
  private liveActivityRevision = 0;
  private extensionActivityAsOf = new Date().toISOString();
  /** Gateway-owned correlation keeps one activity identity across Pi lifecycle
   * payloads and independently-written async artifacts. */
  private readonly extensionRunOwnership = new Map<string, {
    toolCallId: string;
    asyncDir?: string;
    terminal: boolean;
  }>();
  private readonly extensionActivityWatchers = new Map<string, { watcher: FSWatcher; timer: NodeJS.Timeout | undefined; asyncDir: string }>();
  private readonly extensionActivityReadGenerations = new Map<string, number>();
  /** Receipt persistence is runtime work: eviction and restart drain wait for
   * this bounded barrier rather than disposing the Pi manager underneath it. */
  private readonly pendingReceiptWrites = new Set<Promise<void>>();
  private readonly unregisterExtensionExpiry: () => void;
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
  private pendingPrompt: PendingPromptState | undefined;
  private pendingManualCompaction: PendingManualCompaction | undefined;
  private manualCompactionClaim: symbol | undefined;
  private queuedManualCompactionInFlight = false;
  private shuttingDown = false;
  private shutdownPromise: Promise<void> | undefined;
  private suppressQueueEvents = false;

  private constructor(
    private sessionManager: SessionManager,
    private readonly dependencies: RuntimeSlotDependencies,
    private readonly hooks: RuntimeSlotHooks,
    interrupted: boolean,
  ) {
    this.phase = interrupted ? "interrupted" : "idle";
    this.ui = this.createSemanticBroker();
    this.extensionHost = new RemotePiExtensionHost(this.ui, { enableBlockingCustom: false });
    this.lifecycle = new ExtensionLifecycleCoordinator(this.ui.presentation, () => this.hasRuntimeWork());
    this.unregisterExtensionExpiry = dependencies.extensionActivityRecency.registerExpiryCallback((frame) => this.onExtensionActivityExpiry(frame));
  }

  private createSemanticBroker(): SemanticUIBroker {
    const presentation = new ExtensionPresentationStore((topic, payload) => {
      this.revision += 1;
      this.emit(topic, payload);
    }, {
      capabilities: [
        "semantic.dialogs", "semantic.questionnaire.v1", "semantic.notifications", "semantic.status", "semantic.working",
        "semantic.hidden-thinking-label", "semantic.string-widgets", "semantic.title",
        "semantic.revisioned-editor", "semantic.tools-expanded", "surfaces.full-frame",
      ],
      diagnostics: [
        { code: "remote-components.enabled", message: "Retained component widgets are projected as bounded read-only surfaces; blocking custom and overlay UI remain deferred." },
        { code: "remote-components.overlay-deferred", message: "Overlay and interactive component UI remain deferred until native rendering and input leases are available." },
        { code: "theme.baseline-only", message: "Per-session process-global Pi theme synchronization is unavailable through the pinned public API." },
      ],
    });
    return new SemanticUIBroker(presentation);
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

  /** Actionable work only; decorative presentation must not block trust/delete. */
  get isBusy(): boolean {
    return this.lifecycle.preventsOperationalQuiescence || this.pendingAssistantCompletion !== undefined;
  }
  /** Retained presentation protects only automatic idle eviction. */
  get isEvictionProtected(): boolean { return this.lifecycle.preventsEviction; }
  get isDrainBusy(): boolean {
    return this.lifecycle.preventsAdministrativeDrain
      || this.pendingReceiptWrites.size > 0
      || this.pendingAssistantCompletion !== undefined;
  }

  async prepareForAdministrativeDrain(): Promise<void> {
    this.lifecycle.beginDrain();
    if (this.queuedMessages.length > 0 || this.runtime.session.getSteeringMessages().length > 0 || this.runtime.session.getFollowUpMessages().length > 0) {
      await this.clearQueue();
    }
  }

  private hasRuntimeWork(): boolean {
    return this.activeExports > 0
      || this.activeOperationId !== undefined
      || this.operation !== undefined
      || this.pendingExtensionCommand !== undefined
      || this.manualCompactionClaim !== undefined
      || this.pendingManualCompaction !== undefined
      || this.queuedManualCompactionInFlight
      || this.pendingQueueAdmission !== undefined
      || this.queuedMessages.length > 0
      || this.effectivePhase === "running"
      || this.effectivePhase === "compacting"
      || this.effectivePhase === "retrying"
      || this.runtime?.session.isBashRunning === true
      || this.pendingReceiptWrites.size > 0
      // Detached nonterminal extension work owns this session lane until a
      // terminal receipt or explicit resolution is observed.
      || [...this.extensionActivities.values()].some((activity) => activity.lifecycle?.state === "queued"
        || activity.lifecycle?.state === "running"
        || activity.lifecycle?.state === "paused" || activity.lifecycle?.attention === "needsAttention");
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

  /** Immutable while this Gateway owns the runtime slot. Empty sessions are
   * deliberately not persisted merely to retain this dashboard timestamp. */
  get catalogCreatedAt(): string {
    return this.createdAt;
  }

  get sessionFile(): string | undefined {
    return this.runtime.session.sessionFile;
  }

  /** Pi may reserve a future JSONL path before writing its first canonical
   * entry. Catalog membership treats only an existing file as persisted. */
  get persistedSessionFile(): string | undefined {
    const path = this.runtime.session.sessionFile;
    return path && existsSync(path) ? path : undefined;
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
      const notifications = this.dependencies.notifications;
      const services = await createAgentSessionServices({
        cwd: trust.cwd,
        agentDir: this.dependencies.agentDir,
        modelRuntime,
        resourceLoaderOptions: {
          ...(notifications ? {
            extensionFactories: [{
              name: "tron-notify",
              factory: createTronNotifyExtension({
                sessionId: () => this.id,
                enqueue: (input) => notifications.enqueue(input),
              }),
            }],
          } : {}),
          extensionsOverride: (base) => attributeExtensions(base, {
            ...(notifications ? { askPresented: ({ toolCallId }) => notifications.askPresented(this.id, toolCallId) } : {}),
          }),
        },
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
      newSession: (options) => this.withRebindAttentionDisposition("reset", () => this.runtime.newSession(options)),
      fork: (entryId, options) => this.withRebindAttentionDisposition("reset", () => this.runtime.fork(entryId, options)),
      navigateTree: (targetId, options) => this.runtime.session.navigateTree(targetId, options),
      switchSession: (sessionPath, options) => this.withRebindAttentionDisposition("preserve", () => this.runtime.switchSession(sessionPath, options)),
      reload: async () => {
        await this.reloadBoundSession();
        if (this.projectTrustReloadOverride === undefined) this.commitReload();
      },
    };
  }

  private rotateSemanticHost(reason = "Extension host reloaded or replaced"): void {
    this.extensionHost.retire(reason);
    this.ui.retire(reason);
    this.ui = this.createSemanticBroker();
    this.extensionHost = new RemotePiExtensionHost(this.ui, { enableBlockingCustom: false });
    this.lifecycle.replaceActivity(this.ui.presentation);
    // reload() has already built its new public runner and invokes this hook
    // before session_start. Updating it directly avoids bindExtensions(), which
    // would emit a duplicate session_start.
    this.runtime.session.extensionRunner.setUIContext(this.extensionHost.context(), "rpc");
  }

  private async reloadBoundSession(): Promise<void> {
    const session = this.runtime.session;
    await session.resourceLoader.reload(this.effectiveResourceReloadOptions());
    await session.reload({ beforeSessionStart: () => this.rotateSemanticHost() });
  }

  private async withRebindAttentionDisposition<T>(
    disposition: SessionAttentionRebindDisposition,
    operation: () => Promise<T>,
  ): Promise<T> {
    const previous = this.rebindAttentionDisposition;
    this.rebindAttentionDisposition = disposition;
    try {
      return await operation();
    } finally {
      this.rebindAttentionDisposition = previous;
    }
  }

  private async bindSession(): Promise<void> {
    const previousId = this.runtime?.session.sessionId ?? this.sessionManager.getSessionId();
    this.unsubscribe?.();
    if (this.hasBoundSession) this.rotateSemanticHost();
    this.hasBoundSession = true;
    const session = this.runtime.session;
    this.sessionManager = session.sessionManager;
    await session.bindExtensions({
      uiContext: this.extensionHost.context(),
      mode: "rpc",
      commandContextActions: this.commandActions(),
      abortHandler: () => void this.abort(),
      shutdownHandler: () => this.requestExtensionShutdown(),
      onError: (error) => this.emit("session.extensionError", safeJson(error)),
    });
    this.unsubscribe = session.subscribe((event) => this.onEvent(event));
    this.hydrateCanonicalExtensionActivities();
    const nextId = session.sessionId;
    if (previousId !== nextId) {
      this.clearExtensionActivityWatchers();
      this.extensionActivities.clear();
      this.extensionActivitySequences.clear();
      this.extensionRunOwnership.clear();
      await this.hooks.rekey(previousId, nextId, this, this.rebindAttentionDisposition);
    }
    this.revision += 1;
    this.publishSnapshot();
  }

  /** Rebuild terminal extension cards from canonical receipts before backfilling
   * tool results. This preserves the canonical terminalAt across a restart;
   * receipts are authoritative when the disposable result projection is rebuilt. */
  private hydrateCanonicalExtensionActivities(): void {
    for (const { receipt } of extensionActivityReceipts(this.sessionManager.getEntries(), this.id)) {
      const activity = extensionReceiptActivity(receipt);
      this.upsertExtensionActivity(activity);
      // Retain even an already-expired terminal latch in the disposable map so
      // tool-result backfill cannot manufacture a new terminalAt on restart;
      // snapshot visibility still omits historical rows.
      this.extensionActivities.set(activity.toolCallId, activity);
    }
    for (const entry of this.sessionManager.getEntries()) {
      if (entry.type !== "message" || entry.message.role !== "toolResult") continue;
      const toolName = entry.message.toolName;
      const origin = this.extensionToolOrigin(toolName);
      if (!origin) continue;
      const details = entry.message.details;
      if (!details || typeof details !== "object" || Array.isArray(details)) continue;
      const state = extensionLifecycleState((details as Record<string, unknown>).state ?? (details as Record<string, unknown>).status);
      if (!["completed", "failed", "stopped", "rejected"].includes(state)) continue;
      this.updateExtensionActivity(
        entry.message.toolCallId,
        toolName,
        origin,
        state === "failed" ? "failed" : "completed",
        new Date(entry.message.timestamp).toISOString(),
        new Date(entry.message.timestamp).toISOString(),
        details,
        new Date(entry.message.timestamp).toISOString(),
      );
    }
  }

  private upsertExtensionActivity(activity: ExtensionRunActivity): ActivityVisibility {
    const visibility = this.dependencies.extensionActivityRecency.upsert(activity);
    if (visibility.accepted) {
      this.liveActivityRevision += 1;
      this.extensionActivityAsOf = new Date().toISOString();
    }
    return visibility;
  }

  /** Evict disposable rows by bucket, never allowing a recent terminal row to
   * displace queued/running/paused work from the 64-entry runtime map. */
  private trimExtensionActivities(): void {
    while (this.extensionActivities.size > 64) {
      const candidates = [...this.extensionActivities.entries()];
      const ranked = candidates.sort((left, right) => {
        const bucket = (activity: ExtensionRunActivity): number => {
          const visibility = this.extensionActivityVisibility(activity);
          return visibility === "recent" || visibility === "historical" ? 0 : 1;
        };
        return bucket(left[1]) - bucket(right[1]) || left[1].updatedAt.localeCompare(right[1].updatedAt);
      });
      const oldest = ranked[0]?.[0];
      if (!oldest) break;
      this.stopExtensionActivityWatcher(oldest);
      this.extensionActivities.delete(oldest);
      for (const [runId, binding] of this.extensionRunOwnership) {
        if (binding.toolCallId === oldest) this.extensionRunOwnership.delete(runId);
      }
    }
  }

  private requestExtensionShutdown(): void {
    this.lifecycle.requestShutdown();
    this.revision += 1;
    this.ui.context().notify("Extension requested a graceful session close", "info");
    this.maybePerformExtensionShutdown();
  }

  private maybePerformExtensionShutdown(): void {
    if (!this.lifecycle.isShutdownRequested || this.lifecycle.hasPendingCommands || this.lifecycle.hasPendingPrompts || this.shuttingDown || this.disposed) return;
    void this.runtime.session.waitForIdle().then(() => this.lane.run(async () => {
      if (!this.lifecycle.isShutdownRequested || this.lifecycle.hasPendingCommands || this.lifecycle.hasPendingPrompts || this.disposed) return;
      this.shuttingDown = true;
      const closedID = this.id;
      const hostEpoch = this.ui.hostEpoch;
      // Pi owns session_shutdown; closure is truthful only after it completes.
      await this.disposeRuntime();
      await this.dependencies.markers.clear(closedID);
      this.phase = "idle";
      this.operation = undefined;
      this.pendingExtensionCommand = undefined;
      this.retry = undefined;
      // Persisted catalog membership survives runtime closure. Publish its
      // truthful idle row without inventing a structural list event.
      this.publishSummary();
      this.emit("session.closed", { reason: "extension_shutdown", hostEpoch });
      this.hooks.closed?.(closedID, this);
    })).catch((error) => {
      this.emit("session.extensionError", safeJson({ message: error instanceof Error ? error.message : String(error) }));
    });
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

  private emitProgress(message: AgentMessage): void {
    this.pendingProgressMessage = message;
    if (this.progressFlushTimer !== undefined) return;
    this.progressFlushTimer = setTimeout(() => {
      this.progressFlushTimer = undefined;
      this.flushPendingProgress();
    }, STREAMING_PROGRESS_FLUSH_MS);
    this.progressFlushTimer.unref();
    this.flushPendingProgress();
  }

  private flushPendingProgress(): void {
    const message = this.pendingProgressMessage;
    this.pendingProgressMessage = undefined;
    if (!message || message.role !== "assistant") return;
    this.captureStreamIdentity(message);
    if (!this.streamPresentationId || !this.streamStartedAt) return;
    const projected = projectMessage(
      "streaming",
      this.streamAnchorId ?? null,
      this.streamStartedAt,
      message,
      this.dependencies.blobs,
      undefined,
      this.streamPresentationId,
      false,
    );
    this.emit("session.progress", safeJson({
      message: projected === undefined ? undefined : boundStreamingProgressItem(projected),
    }));
  }

  /** Publish the assistant declaration at message_end before any subsequent
   * tool lifecycle event can be observed, and latch its exact call membership. */
  private finalizeToolInvocationGroups(message: AgentMessage): void {
    if (message.role !== "assistant") return;
    this.captureStreamIdentity(message);
    if (!this.streamPresentationId || !this.streamStartedAt) return;
    if (this.progressFlushTimer !== undefined) clearTimeout(this.progressFlushTimer);
    this.progressFlushTimer = undefined;
    this.pendingProgressMessage = undefined;
    const projected = projectMessage(
      "streaming",
      this.streamAnchorId ?? null,
      this.streamStartedAt,
      message,
      this.dependencies.blobs,
      undefined,
      this.streamPresentationId,
      true,
    );
    if (!projected || projected.kind !== "message") return;
    this.finalizedStreamPresentationId = this.streamPresentationId;
    for (const part of projected.content) {
      if (part.type !== "toolCall" || !part.groupFinalized || !part.groupId
        || part.groupIndex === undefined || part.groupCount === undefined) continue;
      this.toolInvocationGroups.set(part.toolCallId, {
        groupId: part.groupId,
        groupIndex: part.groupIndex,
        groupCount: part.groupCount,
        groupFinalized: true,
      });
    }
    while (this.toolInvocationGroups.size > 2_048) {
      const oldest = this.toolInvocationGroups.keys().next().value as string | undefined;
      if (!oldest) break;
      this.toolInvocationGroups.delete(oldest);
    }
    this.emit("session.progress", safeJson({ message: boundStreamingProgressItem(projected) }));
  }

  private captureStreamIdentity(message: AgentMessage, startsMessage = false): void {
    if (message.role !== "assistant") return;
    this.latestStreamingMessage = message;
    if (this.streamPresentationId !== undefined) {
      // snapshot() can observe agent-core's streaming message while Pi is still
      // awaiting an async message_start hook. The later Gateway message_start
      // notification owns that same object and must not rotate its published ID.
      if (!startsMessage || this.streamIdentityMessage === message) return;
    }
    this.streamIdentityMessage = message;
    this.streamAnchorId = this.runtime.session.sessionManager.getLeafId() ?? null;
    this.streamPresentationId = `stream:${randomUUID()}`;
    this.streamStartedAt = new Date().toISOString();
    this.finalizedStreamPresentationId = undefined;
  }

  private bindCanonicalPresentation(message: AgentMessage): void {
    if (message.role !== "assistant") return;
    const presentationID = this.streamPresentationId;
    // Pi notifies listeners before synchronously appending the finalized
    // message. The microtask runs after that append and before the next model
    // continuation, so the exact new leaf owns this live-turn identity.
    queueMicrotask(() => {
      const canonicalID = this.runtime.session.sessionManager.getLeafId();
      const candidate = canonicalID
        ? this.runtime.session.sessionManager.getEntry(canonicalID)
        : undefined;
      if (candidate?.type !== "message"
        || candidate.message.role !== "assistant"
        || candidate.message !== message) return;
      if (presentationID) {
        if (!this.presentationIDs.has(candidate.id)) this.presentationIDOrder.push(candidate.id);
        this.presentationIDs.set(candidate.id, presentationID);
      }
      const completion = successfulAssistantCompletion(candidate);
      if (completion && this.operation?.kind === "prompt") {
        this.pendingAssistantCompletion = {
          ...completion,
          ...(this.activeOperationId ? { operationId: this.activeOperationId } : {}),
        };
      }
      const excess = this.presentationIDOrder.length - MAX_PRESENTATION_IDENTITY_BINDINGS;
      if (excess > 0) {
        for (const id of this.presentationIDOrder.slice(0, excess)) this.presentationIDs.delete(id);
        this.presentationIDOrder.splice(0, excess);
      }
      if (presentationID && this.streamPresentationId === presentationID) {
        this.latestStreamingMessage = undefined;
        this.streamIdentityMessage = undefined;
        this.streamAnchorId = undefined;
        this.streamPresentationId = undefined;
        this.streamStartedAt = undefined;
        this.finalizedStreamPresentationId = undefined;
      }
      this.scheduleSnapshot();
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

  private beginAttentionSettlement(completion: CanonicalAssistantCompletion): Promise<void> {
    if (this.attentionBarrier) return this.attentionBarrier;
    const operation = (async () => {
      let lastError: unknown;
      for (let attempt = 0; attempt < 3; attempt += 1) {
        try {
          if (completion.operationId) {
            await this.dependencies.markers.markAssistantCompletion(
              this.id,
              completion.operationId,
              completion.id,
              completion.completedAt,
            );
          }
          await this.hooks.assistantResponseCompleted(this.id, completion, false);
          lastError = undefined;
          break;
        } catch (error) {
          lastError = error;
        }
      }
      if (lastError !== undefined) throw lastError;
      if (this.pendingAssistantCompletion?.id === completion.id) this.pendingAssistantCompletion = undefined;
      if (this.pendingManualCompaction) {
        // The already-accepted compaction inherits the run marker. Start it only
        // after the preceding response's attention fact is durable.
        this.phase = "idle";
        this.revision += 1;
        this.publishSnapshot();
        this.startPendingManualCompaction();
        return;
      }
      await this.dependencies.markers.clear(this.id);
      this.hooks.settled(this.id);
      this.phase = "idle";
      this.revision += 1;
      this.publishSnapshot();
    })().catch((error) => {
      // The canonical response remains recoverable from JSONL and the run marker
      // remains durable. Open/drain joins this barrier; a later open or restart
      // retries reconciliation rather than falsely declaring the response read.
      this.phase = "interrupted";
      this.revision += 1;
      this.publishSnapshot();
      throw error;
    });
    this.attentionBarrier = operation;
    this.pendingReceiptWrites.add(operation);
    void operation.catch(() => {}).finally(() => {
      this.pendingReceiptWrites.delete(operation);
      if (this.attentionBarrier === operation) this.attentionBarrier = undefined;
    });
    return operation;
  }

  /** Join live settlement and reconcile bounded canonical evidence before open. */
  async reconcileAttention(): Promise<void> {
    if (this.attentionBarrier) await this.attentionBarrier;
    if (this.pendingAssistantCompletion) {
      await this.beginAttentionSettlement(this.pendingAssistantCompletion);
      return;
    }
    const completion = successfulAssistantCompletion(this.sessionManager.getLeafEntry());
    if (completion) await this.hooks.assistantResponseCompleted(this.id, completion, true);
  }

  private onEvent(event: AgentSessionEvent): void {
    this.revision += 1;
    this.touch();
    switch (event.type) {
      case "agent_start":
        this.pendingAssistantCompletion = undefined;
        if (!this.lifecycle.admitAgentStartDuringDrain()) {
          this.phase = "interrupted";
          this.operation = undefined;
          this.activeOperationId = undefined;
          this.emit("session.operationFailed", {
            message: "Extension continuation was rejected after the administrative drain cutoff",
          });
          void this.runtime.session.abort();
          this.publishSnapshot();
          break;
        }
        this.phase = "running";
        this.toolExecutions.clear();
        this.toolInvocationGroups.clear();
        this.toolStartedAtMonotonicMs.clear();
        this.nextToolOrder = 0;
        this.activeOperationId ??= randomUUID();
        this.operation ??= { id: this.activeOperationId, kind: "prompt", startedAt: new Date().toISOString() };
        void this.dependencies.markers.mark(this.id, this.activeOperationId);
        if (!this.activityHeartbeat) this.startActivityHeartbeat();
        this.publishSnapshot();
        break;
      case "agent_settled":
        if (this.shuttingDown) break;
        // An extension completion can trigger the next turn while the previous
        // settlement callback is still unwinding. Never let that older callback
        // mark a newer agent-core run idle or erase its live tools.
        if (this.hasActiveAgentRun) {
          this.ensureAgentProjection();
          this.publishSnapshot();
          break;
        }
        if (this.queuedManualCompactionInFlight) {
          // A late settlement callback from the preceding prompt cannot retire
          // the queued maintenance operation that now owns the session.
          this.publishSnapshot();
          break;
        }
        this.latestStreamingMessage = undefined;
        this.streamIdentityMessage = undefined;
        this.streamAnchorId = undefined;
        this.streamPresentationId = undefined;
        this.streamStartedAt = undefined;
        this.finalizedStreamPresentationId = undefined;
        this.phase = "idle";
        const settledOperationId = this.activeOperationId;
        this.activeOperationId = undefined;
        this.operation = undefined;
        this.retry = undefined;
        this.toolExecutions.clear();
        this.toolInvocationGroups.clear();
        this.toolStartedAtMonotonicMs.clear();
        this.nextToolOrder = 0;
        this.stopActivityHeartbeat();
        this.clearToolProgressTimers();
        if (this.pendingManualCompaction) {
          // The accepted compaction command owns the existing run marker. If the
          // prompt produced a successful response, attention commits before the
          // canonical compaction is allowed to inherit that marker.
          if (this.pendingAssistantCompletion) {
            this.phase = "running";
            this.publishSnapshot();
            void this.beginAttentionSettlement(this.pendingAssistantCompletion).catch(() => {});
          } else {
            this.publishSnapshot();
            this.startPendingManualCompaction();
          }
          break;
        }
        if (this.pendingExtensionCommand === undefined) {
          if (this.pendingAssistantCompletion) {
            // Pi has settled, but the Gateway remains operationally running until
            // the exact canonical completion is durable. This is the open/drain
            // barrier that prevents a snapshot from outrunning attention truth.
            this.phase = "running";
            this.publishSnapshot();
            void this.beginAttentionSettlement(this.pendingAssistantCompletion).catch(() => {});
            break;
          }
          void this.dependencies.markers.clear(this.id, settledOperationId);
          this.hooks.settled(this.id);
        }
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
      case "message_start": {
        if (event.message.role === "assistant") {
          this.flushPendingProgress();
          this.captureStreamIdentity(event.message, true);
        }
        break;
      }
      case "message_update": {
        if (!this.hasActiveAgentRun) break;
        this.ensureAgentProjection();
        this.captureStreamIdentity(event.message);
        this.emitProgress(event.message);
        break;
      }
      case "tool_execution_start": {
        if (!this.hasActiveAgentRun) break;
        this.ensureAgentProjection();
        const now = new Date().toISOString();
        const existing = this.toolExecutions.get(event.toolCallId);
        const startedAt = existing?.startedAt ?? now;
        if (!this.toolStartedAtMonotonicMs.has(event.toolCallId)) {
          this.toolStartedAtMonotonicMs.set(event.toolCallId, performance.now());
        }
        const progressSequence = (existing?.progressSequence ?? 0) + 1;
        const durationMs = this.measureToolDuration(
          event.toolCallId,
          startedAt,
          now,
          performance.now()
        );
        const extensionOrigin = this.extensionToolOrigin(event.toolName);
        const extensionActivity = this.updateExtensionActivity(
          event.toolCallId, event.toolName, extensionOrigin, "running", startedAt, now, undefined, undefined, durationMs
        );
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
          durationMs,
          progressSequence,
          ...(this.toolInvocationGroups.get(event.toolCallId) ?? {}),
          ...(extensionOrigin ? { extensionOrigin } : {}),
          ...(extensionActivity ? { extensionActivity } : {}),
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
        const output = mergeLiveToolOutput(existing, projectToolOutput(event.partialResult));
        const startedAt = existing?.startedAt ?? now;
        const durationMs = this.measureToolDuration(
          event.toolCallId,
          startedAt,
          now,
          performance.now()
        );
        const extensionOrigin = this.extensionToolOrigin(event.toolName) ?? existing?.extensionOrigin;
        const extensionActivity = this.updateExtensionActivity(
          event.toolCallId, event.toolName, extensionOrigin, "running", startedAt, now, event.partialResult, undefined, durationMs
        );
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
          startedAt,
          updatedAt: now,
          lastProgressAt: now,
          durationMs,
          progressSequence: (existing?.progressSequence ?? 0) + 1,
          ...(this.toolInvocationGroups.get(event.toolCallId) ?? {}),
          ...(extensionOrigin ? { extensionOrigin } : {}),
          ...(extensionActivity ? { extensionActivity } : {}),
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
        const durationMs = this.measureToolDuration(
          event.toolCallId,
          startedAt,
          now,
          performance.now()
        );
        const output = projectToolOutput(event.result);
        const extensionOrigin = this.extensionToolOrigin(event.toolName) ?? existing?.extensionOrigin;
        const extensionActivity = this.updateExtensionActivity(
          event.toolCallId, event.toolName, extensionOrigin, event.isError ? "failed" : "completed", startedAt, now, event.result, now, durationMs
        );
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
          durationMs,
          progressSequence: (existing?.progressSequence ?? 0) + 1,
          ...(this.toolInvocationGroups.get(event.toolCallId) ?? {}),
          ...(extensionOrigin ? { extensionOrigin } : {}),
          ...(extensionActivity ? { extensionActivity } : {}),
        };
        this.toolExecutions.set(event.toolCallId, state);
        this.rememberToolMetadata(event.toolCallId, state);
        this.toolStartedAtMonotonicMs.delete(event.toolCallId);
        this.publishToolProgress(state, true);
        this.scheduleSnapshot();
        break;
      }
      case "bash_execution_update":
        this.emit("session.bashProgress", safeJson(event));
        break;
      case "entry_appended":
        this.summaryContentDirty = true;
        if (this.pendingPrompt && event.entry.type === "message" && event.entry.message.role === "user") {
          this.pendingPrompt = undefined;
        }
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
        if (event.message.role === "assistant") {
          this.finalizeToolInvocationGroups(event.message);
          this.bindCanonicalPresentation(event.message);
        }
        // Regular user messages are persisted by Pi at message_end; they do not
        // emit entry_appended. Retire the transient pending projection here so
        // it cannot survive the canonical prompt across reconnects.
        if (this.pendingPrompt && event.message.role === "user") {
          this.pendingPrompt = undefined;
        }
        this.scheduleSnapshot();
        break;
      case "queue_update":
        if (!this.suppressQueueEvents) this.reconcileQueuedMessages();
        if (this.lifecycle.isDraining && (this.runtime.session.getSteeringMessages().length > 0 || this.runtime.session.getFollowUpMessages().length > 0)) {
          void this.clearQueue().catch((error) => this.emit("session.operationFailed", safeJson({
            message: error instanceof Error ? error.message : String(error),
          })));
        }
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

  private extensionArtifactPathAllowed(asyncPath: string): boolean {
    if (!isAbsolute(asyncPath)) return false;
    // Do not normalize away traversal before applying the allowlist. The only
    // accepted inputs are the run directory or its direct status file.
    const lexicalParts = asyncPath.split(/[\\/]/u).filter(Boolean);
    if (lexicalParts.some((part) => part === "." || part === "..")) return false;
    const canonicalRoot = (value: string): string => {
      try { return realpathSync(value); } catch { return resolve(value); }
    };
    const temporaryRoot = canonicalRoot(tmpdir());
    const projectRoot = join(canonicalRoot(this.cwd), ".pi", "subagents", "async-subagent-runs");
    const isAllowedShape = (value: string): boolean => {
      const temporaryParts = relative(temporaryRoot, value).split(/[\\/]/u).filter(Boolean);
      const temporaryRun = temporaryParts[0]?.startsWith("pi-subagents-")
        && temporaryParts[1] === "async-subagent-runs"
        && temporaryParts.length >= 3
        && temporaryParts.length <= 4
        && temporaryParts[2] !== ""
        && (temporaryParts.length === 3 || temporaryParts[3] === "status.json");
      if (temporaryRun) return true;

      const projectParts = relative(projectRoot, value)
        .split(/[\\/]/u).filter(Boolean);
      return projectParts.length >= 1
        && projectParts.length <= 2
        && projectParts[0] !== ""
        && (projectParts.length === 1 || projectParts[1] === "status.json");
    };
    const candidate = resolve(asyncPath);
    // Validate the canonical target. The lexical segment check above rejects
    // traversal before realpath normalization; the canonical shape rejects
    // symlinked run directories and status files escaping the exact roots.
    try {
      return isAllowedShape(realpathSync(candidate));
    } catch {
      return false;
    }
  }

  private subagentExtensionOrigin(): ExtensionToolOrigin {
    const extensions = this.runtime?.session.resourceLoader.getExtensions().extensions ?? [];
    const extension = extensions.find((candidate) => {
      const paths = [candidate.path, candidate.resolvedPath, candidate.sourceInfo.path, candidate.sourceInfo.baseDir]
        .filter((value): value is string => typeof value === "string");
      return paths.some((value) => /(?:^|[\\/])pi-subagents(?:[\\/]|$)/u.test(value));
    });
    if (extension) {
      const owner = extensionOwnerFor(extension);
      return { source: owner.source, owner };
    }
    return { source: "pi-subagents" };
  }

  private async readExtensionStatusArtifact(asyncDir: string): Promise<Record<string, unknown> | undefined> {
    if (!this.extensionArtifactPathAllowed(asyncDir)) return undefined;
    const statusPath = realpathSync(join(asyncDir, "status.json"));
    if (!this.extensionArtifactPathAllowed(statusPath)) return undefined;
    const handle = await open(statusPath, "r");
    try {
      const buffer = Buffer.alloc(MAX_EXTENSION_ARTIFACT_BYTES + 1);
      const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
      if (bytesRead > MAX_EXTENSION_ARTIFACT_BYTES) return undefined;
      const parsed: unknown = JSON.parse(buffer.subarray(0, bytesRead).toString("utf8"));
      return parsed !== null && typeof parsed === "object" && !Array.isArray(parsed) ? parsed as Record<string, unknown> : undefined;
    } finally {
      await handle.close();
    }
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
      const directory = this.canonicalExtensionArtifactDirectory(binding.asyncDir);
      if (directory) candidates.push({ directory, updatedAt: activity?.updatedAt ?? "" });
    }
    candidates.sort((left, right) => left.updatedAt.localeCompare(right.updatedAt)
      || left.directory.localeCompare(right.directory));
    return [...new Set(candidates.map((candidate) => candidate.directory))].slice(0, 64);
  }

  /** Called only by the Gateway-scoped bounded artifact discovery owner or by
   * a watcher attached after this slot proved canonical ownership. */
  discoverExtensionArtifact(asyncDir: string): Promise<void> {
    return this.refreshSubagentActivityFromArtifact(asyncDir);
  }

  /** Administrative drain gets a direct, bounded reconciliation lane for
   * exact-owned artifacts instead of depending on watcher delivery or ambient
   * discovery scheduling. Genuine nonterminal work remains a blocker. */
  async reconcileOwnedExtensionArtifactsForDrain(): Promise<void> {
    const canonicalFacts = this.canonicalExtensionRunFacts();
    for (const asyncDir of this.ownedExtensionArtifactDirectories()) {
      await this.refreshSubagentActivityFromArtifact(asyncDir, canonicalFacts);
    }
  }

  private async refreshSubagentActivityFromArtifact(
    asyncDir: string,
    canonicalFacts?: ReadonlyMap<string, CanonicalExtensionRunFact>,
  ): Promise<void> {
    try {
      const realAsyncDir = this.canonicalExtensionArtifactDirectory(asyncDir);
      if (!realAsyncDir) return;
      const rawValue = await this.readExtensionStatusArtifact(realAsyncDir);
      // Registry discovery is bounded but grants no ownership. Historical
      // artifacts become admissible only here, where the canonical tool result
      // or an exact live asyncDir binding proves the owning session/tool call.
      const raw = admitExtensionLifecycleArtifact(rawValue, { exactOwnedLegacy: true });
      if (!raw) return;
      const runId = raw.runId as string;
      if (!runId) return;
      // The file's declared directory is advisory. If present, it must agree
      // with the directory that was actually discovered/read.
      if (typeof raw.asyncDir === "string") {
        const declaredAsyncDir = this.canonicalExtensionArtifactDirectory(raw.asyncDir);
        if (!declaredAsyncDir || declaredAsyncDir !== realAsyncDir) return;
      }
      const ownership = this.extensionRunOwnership.get(runId);
      const canonical = (canonicalFacts ?? this.canonicalExtensionRunFacts()).get(runId);
      const historicalArtifact = raw.lifecycleArtifactVersion !== EXTENSION_LIFECYCLE_ARTIFACT_VERSION;
      if (historicalArtifact && !ownership?.asyncDir && !canonical?.asyncDir) return;
      // A duplicated runId in canonical JSONL has no safe artifact owner.
      if (canonical?.ambiguous) return;
      if (ownership?.asyncDir) {
        const ownershipAsyncDir = this.canonicalExtensionArtifactDirectory(ownership.asyncDir);
        if (!ownershipAsyncDir || ownershipAsyncDir !== realAsyncDir) return;
      }
      if (canonical?.asyncDir) {
        const canonicalAsyncDir = this.canonicalExtensionArtifactDirectory(canonical.asyncDir);
        if (!canonicalAsyncDir || canonicalAsyncDir !== realAsyncDir) return;
      }
      if (canonical?.toolCallId && ownership && ownership.toolCallId !== canonical.toolCallId) {
        // A synthetic artifact row may be re-keyed to its first real tool call,
        // but a real ownership binding must never switch to another call.
        if (!ownership.toolCallId.startsWith("subagent:") || ownership.toolCallId === canonical.toolCallId) return;
      }
      const matchingEntries = [...this.extensionActivities.entries()].filter(([, activity]) => activity.runId === runId);
      // Correlation is Gateway-owned; never pick an arbitrary activity when a
      // malformed or legacy payload has produced duplicate run identities.
      if (!ownership && !canonical?.toolCallId && matchingEntries.length > 1) return;
      const boundToolCallId = canonical?.toolCallId ?? ownership?.toolCallId;
      let existingEntry: readonly [string, ExtensionRunActivity | undefined] | undefined = boundToolCallId
        ? ([boundToolCallId, this.extensionActivities.get(boundToolCallId)] as const)
        : matchingEntries[0];
      // Synthetic rows are placeholders only. Re-key one to the first real
      // canonical tool call instead of retaining two rows for the same run.
      if (canonical?.toolCallId && !existingEntry?.[1]) {
        const synthetic = matchingEntries.find(([id]) => id.startsWith("subagent:"));
        if (synthetic) existingEntry = [canonical.toolCallId, synthetic[1]];
      }
      // A tool result is the ownership proof for an activity. Once that proof
      // exists, the artifact may enrich it. Unmatched artifacts still require
      // the exact cwd/session guard.
      // Artifact files are enrichment only. A current tool execution or a
      // canonical terminal tool result must establish ownership first; cwd,
      // sessionId, and a lone running tool are not attribution evidence.
      if (!existingEntry?.[1] && !canonical?.toolCallId) return;
      if (!existingEntry?.[1] && canonical?.toolCallId) {
        existingEntry = [canonical.toolCallId, this.extensionActivities.get(canonical.toolCallId)];
      }
      const toolCallId = existingEntry?.[0];
      if (!toolCallId) return;
      const previous = existingEntry?.[1];
      const normalized = normalizeExtensionArtifact(raw, {
        now: new Date().toISOString(),
        ...(previous?.startedAt ? { fallbackStartedAt: previous.startedAt } : {}),
        ...(previous?.updatedAt ? { fallbackUpdatedAt: previous.updatedAt } : {}),
        useArtifactStartedAt: false,
      });
      if (!normalized) return;
      const { status: state, startedAt, updatedAt, completedAt, durationMs } = normalized;
      // A terminal lifecycle event is authoritative; a late running artifact
      // enriches neither status nor ownership and must not resurrect the pill.
      if (ownership?.terminal && state === "running") return;
      const artifactValue = ownership?.terminal
        ? { ...raw, state: previous?.status === "failed" ? "failed" : "completed" }
        : raw;
      const activityKey = previous?.activityId ?? extensionActivityId(this.runtime.session.sessionManager.getSessionId(), toolCallId);
      const sequence = (this.extensionActivitySequences.get(activityKey) ?? previous?.lifecycle?.sequence ?? 0) + 1;
      this.extensionActivitySequences.set(activityKey, sequence);
      const observedAt = new Date().toISOString();
      const terminalAt = state === "running"
        ? previous?.lifecycle?.terminalAt
        : previous?.lifecycle?.terminalAt ?? observedAt;
      const recentUntil = terminalAt ? new Date(Date.parse(terminalAt) + 900_000).toISOString() : undefined;
      const activity = projectExtensionRunActivity(artifactValue, {
        id: previous?.id ?? toolCallId,
        activityId: activityKey,
        toolCallId,
        source: previous?.source ?? this.subagentExtensionOrigin(),
        title: previous?.title ?? "Pi Subagents",
        status: state,
        authoritativeStatus: state !== "running" || previous?.lifecycle?.state === "completed" || previous?.lifecycle?.state === "failed" || previous?.lifecycle?.state === "stopped" || previous?.lifecycle?.state === "rejected",
        startedAt,
        updatedAt,
        ...(completedAt ? { completedAt } : {}),
        ...(durationMs === undefined ? {} : { durationMs }),
        ...(previous ? { previous } : {}),
        sequence,
        observedAt,
        ...(terminalAt ? { terminalAt } : {}),
        ...(recentUntil ? { recentUntil } : {}),
      });
      // Ambient discovery is another producer of lifecycle candidates. Apply
      // the same Gateway terminal latch and sequence admission as live tool
      // events before replacing an existing row.
      if (admitExtensionRunActivity(previous, activity) === previous) return;
      const ownershipAccepted = this.bindExtensionRunOwnership(runId, {
        toolCallId,
        asyncDir: realAsyncDir,
        terminal: activity.status !== "running" || Boolean(ownership?.terminal),
      });
      if (!ownershipAccepted) return;
      if (existingEntry) this.extensionActivities.delete(existingEntry[0]);
      const syntheticToolCallId = matchingEntries.find(([id]) => id.startsWith("subagent:") && id !== toolCallId)?.[0];
      if (syntheticToolCallId) this.extensionActivities.delete(syntheticToolCallId);
      this.extensionActivities.delete(toolCallId);
      this.extensionActivities.set(toolCallId, activity);
      this.upsertExtensionActivity(activity);
      if (activity.status === "running" && ownershipAccepted) {
        this.startExtensionActivityWatcher(toolCallId, realAsyncDir);
      } else {
        if (activity.status !== "running") {
          void this.appendExtensionActivityReceipt(activity).catch((error) => this.emit("session.extensionError", safeJson(error)));
        }
        this.stopExtensionActivityWatcher(toolCallId);
      }
      this.trimExtensionActivities();
      this.publishExtensionActivity(activity);
    } catch {
      // The artifact may be mid-replacement or may have been removed after the scan.
    }
  }

  private stopExtensionActivityWatcher(toolCallId: string): void {
    this.extensionActivityReadGenerations.set(
      toolCallId,
      (this.extensionActivityReadGenerations.get(toolCallId) ?? 0) + 1
    );
    const tracked = this.extensionActivityWatchers.get(toolCallId);
    if (!tracked) return;
    if (tracked.timer) clearTimeout(tracked.timer);
    tracked.watcher.close();
    this.extensionActivityWatchers.delete(toolCallId);
  }

  private clearExtensionActivityWatchers(): void {
    for (const toolCallId of this.extensionActivityWatchers.keys()) this.stopExtensionActivityWatcher(toolCallId);
    this.extensionActivityReadGenerations.clear();
  }

  private canonicalExtensionArtifactDirectory(asyncDir: string): string | undefined {
    if (!isAbsolute(asyncDir) || !this.extensionArtifactPathAllowed(asyncDir)) return undefined;
    try {
      const realAsyncDir = realpathSync(asyncDir);
      return this.extensionArtifactPathAllowed(realAsyncDir) ? realAsyncDir : undefined;
    } catch {
      return undefined;
    }
  }

  private bindExtensionRunOwnership(
    runId: string,
    binding: { toolCallId: string; asyncDir?: string; terminal: boolean },
  ): boolean {
    const existing = this.extensionRunOwnership.get(runId);
    if (existing && existing.toolCallId !== binding.toolCallId) {
      // Only a synthetic placeholder may be replaced by a real Pi identity.
      if (!existing.toolCallId.startsWith("subagent:") || binding.toolCallId.startsWith("subagent:")) return false;
    }
    const asyncDir = existing?.asyncDir ?? binding.asyncDir;
    this.extensionRunOwnership.set(runId, {
      toolCallId: binding.toolCallId,
      ...(asyncDir ? { asyncDir } : {}),
      terminal: Boolean(existing?.terminal || binding.terminal),
    });
    return true;
  }

  /** Canonical JSONL facts are the only reacquisition evidence for an
   * artifact-created activity. Runtime maps are intentionally disposable. */
  private canonicalExtensionRunFacts(): Map<string, CanonicalExtensionRunFact> {
    const facts = new Map<string, CanonicalExtensionRunFact>();
    for (const entry of this.runtime.session.sessionManager.getEntries()) {
      if (entry.type !== "message") continue;
      const message = entry.message as unknown as Record<string, unknown>;
      if (message.role !== "toolResult") continue;
      // Details.runId is untrusted presentation data. Require the canonical
      // tool identity and prove that its tool is currently extension-owned;
      // otherwise arbitrary tool results must not claim an artifact run.
      const toolCallId = typeof message.toolCallId === "string" ? message.toolCallId : undefined;
      const toolName = typeof message.toolName === "string" ? message.toolName : undefined;
      if (!toolCallId || !toolName || !this.extensionToolOrigin(toolName)) continue;
      const details = message.details !== null && typeof message.details === "object" && !Array.isArray(message.details)
        ? message.details as Record<string, unknown>
        : undefined;
      const runId = typeof details?.runId === "string"
        ? details.runId
        : typeof details?.asyncId === "string" ? details.asyncId : undefined;
      if (!runId) continue;
      const explicitTerminal = details?.state === "failed"
        || details?.state === "complete"
        || details?.state === "completed"
        || details?.state === "stopped"
        || details?.status === "failed"
        || details?.status === "complete"
        || details?.status === "completed"
        || details?.status === "stopped";
      // An async launcher acknowledgement has no child results and no explicit
      // terminal state; it remains live after the foreground tool returns.
      const detached = typeof details?.asyncId === "string"
        && (!Array.isArray(details.results) || details.results.length === 0)
        && !explicitTerminal;
      const asyncDir = typeof details?.asyncDir === "string" ? details.asyncDir : undefined;
      const terminal = !detached && (explicitTerminal || typeof details?.runId === "string");
      const previous = facts.get(runId);
      if (!previous) {
        facts.set(runId, { toolCallId, ...(asyncDir ? { asyncDir } : {}), terminal, ambiguous: false });
      } else if (previous.ambiguous) {
        previous.terminal ||= terminal;
      } else if (previous.toolCallId === toolCallId) {
        if (previous.asyncDir && asyncDir && previous.asyncDir !== asyncDir) previous.ambiguous = true;
        if (!previous.asyncDir && asyncDir) previous.asyncDir = asyncDir;
        previous.terminal ||= terminal;
      } else if (previous.toolCallId?.startsWith("subagent:") && !toolCallId.startsWith("subagent:")) {
        previous.toolCallId = toolCallId;
        if (!previous.asyncDir && asyncDir) previous.asyncDir = asyncDir;
        previous.terminal ||= terminal;
      } else if (toolCallId.startsWith("subagent:") && previous.toolCallId && !previous.toolCallId.startsWith("subagent:")) {
        previous.terminal ||= terminal;
      } else {
        // Distinct real tool calls sharing a runId are ambiguous. Retaining an
        // arbitrary last writer would let a foreign artifact rebind the first.
        delete previous.toolCallId;
        previous.ambiguous = true;
        previous.terminal ||= terminal;
      }
    }
    return facts;
  }

  private async refreshExtensionActivityFromArtifact(toolCallId: string, asyncDir: string): Promise<void> {
    const previous = this.extensionActivities.get(toolCallId);
    const realAsyncDir = this.canonicalExtensionArtifactDirectory(asyncDir);
    if (!previous || this.disposed || !realAsyncDir) return;
    const generation = (this.extensionActivityReadGenerations.get(toolCallId) ?? 0) + 1;
    this.extensionActivityReadGenerations.set(toolCallId, generation);
    try {
      const rawValue = await this.readExtensionStatusArtifact(realAsyncDir);
      const raw = admitExtensionLifecycleArtifact(rawValue, { exactOwnedLegacy: true });
      if (!raw) return;
      if (this.disposed || this.extensionActivityReadGenerations.get(toolCallId) !== generation) return;
      const runId = raw.runId as string;
      if (!runId || runId !== previous.runId) return;
      if (typeof raw.asyncDir === "string") {
        const declaredAsyncDir = this.canonicalExtensionArtifactDirectory(raw.asyncDir);
        if (!declaredAsyncDir || declaredAsyncDir !== realAsyncDir) return;
      }
      const canonical = this.canonicalExtensionRunFacts().get(runId);
      const ownership = this.extensionRunOwnership.get(runId);
      // Watcher refresh is bound to one tool and one canonical directory. A
      // duplicate canonical runId or either mismatch fails closed.
      if (canonical?.ambiguous || (canonical?.toolCallId && canonical.toolCallId !== toolCallId)) return;
      if (!ownership || ownership.toolCallId !== toolCallId) return;
      if (ownership.asyncDir) {
        const ownershipAsyncDir = this.canonicalExtensionArtifactDirectory(ownership.asyncDir);
        if (!ownershipAsyncDir || ownershipAsyncDir !== realAsyncDir) return;
      }
      if (canonical?.asyncDir) {
        const canonicalAsyncDir = this.canonicalExtensionArtifactDirectory(canonical.asyncDir);
        if (!canonicalAsyncDir || canonicalAsyncDir !== realAsyncDir) return;
      }
      const normalized = normalizeExtensionArtifact(raw, {
        now: new Date().toISOString(),
        fallbackStartedAt: previous.startedAt,
        useArtifactStartedAt: false,
      });
      if (!normalized) return;
      const { status: artifactState, updatedAt, completedAt, durationMs } = normalized;
      const terminalStates = ["completed", "failed", "stopped", "rejected"];
      if (ownership.terminal && artifactState === "running") return;
      if (terminalStates.includes(previous.lifecycle?.state ?? "") && artifactState !== "running") {
        const requestedTerminal = artifactState === "failed" ? "failed" : "completed";
        if (requestedTerminal !== previous.lifecycle?.state) return;
      }
      const artifactValue = ownership.terminal
        ? { ...raw, state: previous.status === "failed" ? "failed" : "completed" }
        : raw;
      const activityKey = previous.activityId ?? extensionActivityId(this.runtime.session.sessionManager.getSessionId(), toolCallId);
      const sequence = (this.extensionActivitySequences.get(activityKey) ?? previous.lifecycle?.sequence ?? 0) + 1;
      this.extensionActivitySequences.set(activityKey, sequence);
      const observedAt = new Date().toISOString();
      const terminalAt = artifactState === "running"
        ? previous.lifecycle?.terminalAt
        : previous.lifecycle?.terminalAt ?? observedAt;
      const recentUntil = terminalAt ? new Date(Date.parse(terminalAt) + 900_000).toISOString() : undefined;
      const activity = projectExtensionRunActivity(artifactValue, {
        id: previous.id,
        activityId: activityKey,
        toolCallId,
        source: previous.source,
        title: previous.title,
        status: previous.status,
        startedAt: previous.startedAt,
        updatedAt,
        ...(completedAt ? { completedAt } : {}),
        ...(durationMs === undefined ? {} : { durationMs }),
        previous,
        sequence,
        observedAt,
        ...(terminalAt ? { terminalAt } : {}),
        ...(recentUntil ? { recentUntil } : {}),
      });
      const current = this.extensionActivities.get(toolCallId);
      if (!current) return;
      if (admitExtensionRunActivity(current, activity) === current) return;
      if (current.lifecycle?.sequence !== undefined && activity.lifecycle?.sequence !== undefined
        && activity.lifecycle.sequence <= current.lifecycle.sequence) return;
      this.extensionActivities.delete(toolCallId);
      this.extensionActivities.set(toolCallId, activity);
      this.upsertExtensionActivity(activity);
      const tool = this.toolExecutions.get(toolCallId);
      if (tool) this.toolExecutions.set(toolCallId, { ...tool, extensionActivity: activity });
      this.publishExtensionActivity(activity);
      this.bindExtensionRunOwnership(runId, {
        toolCallId,
        asyncDir: realAsyncDir,
        terminal: activity.status !== "running" || Boolean(ownership.terminal),
      });
      if (activity.status !== "running") {
        this.stopExtensionActivityWatcher(toolCallId);
        void this.appendExtensionActivityReceipt(activity).catch((error) => this.emit("session.extensionError", safeJson(error)));
      }
    } catch {
      // The runner may be atomically replacing status.json. The next filesystem
      // event or the normal runtime snapshot will retry without surfacing noise.
    }
  }

  private startExtensionActivityWatcher(toolCallId: string, asyncDir: string): void {
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
      void this.refreshExtensionActivityFromArtifact(toolCallId, realAsyncDir);
      return;
    }
    this.stopExtensionActivityWatcher(toolCallId);
    try {
      const watcher = watch(realAsyncDir, (_eventType, filename) => {
        if (filename !== null && filename.toString() !== "status.json") return;
        const tracked = this.extensionActivityWatchers.get(toolCallId);
        if (!tracked) return;
        if (tracked.timer) clearTimeout(tracked.timer);
        tracked.timer = setTimeout(() => {
          tracked.timer = undefined;
          void this.refreshExtensionActivityFromArtifact(toolCallId, realAsyncDir);
        }, 50);
        tracked.timer.unref();
      });
      watcher.on("error", () => this.stopExtensionActivityWatcher(toolCallId));
      this.extensionActivityWatchers.set(toolCallId, { watcher, timer: undefined, asyncDir: realAsyncDir });
      void this.refreshExtensionActivityFromArtifact(toolCallId, realAsyncDir);
    } catch {
      // A missing or inaccessible extension artifact remains a generic live row.
    }
  }

  private appendExtensionActivityReceipt(activity: ExtensionRunActivity): Promise<void> {
    if (!activity.lifecycle || !["completed", "failed", "stopped", "rejected"].includes(activity.lifecycle.state)) return Promise.resolve();
    const receipt = makeExtensionActivityReceipt(activity, this.id);
    if (!receipt) return Promise.resolve();
    const write = (async () => {
      let lastError: unknown;
      for (let attempt = 0; attempt < 3; attempt += 1) {
        try {
          await this.lane.run(async () => {
            const existing = extensionActivityReceipts(this.runtime.session.sessionManager.getEntries(), this.id)
              .some((entry) => entry.receipt.activityId === receipt.activityId);
            if (existing) return;
            this.runtime.session.sessionManager.appendCustomEntry(EXTENSION_ACTIVITY_RECEIPT_TYPE, receipt);
            this.revision += 1;
            this.scheduleSnapshot();
          });
          return;
        } catch (error) {
          lastError = error;
          await new Promise((resolve) => setTimeout(resolve, 25 * (attempt + 1)));
        }
      }
      // Keep the failure observable to the owning barrier. The caller observes
      // the rejection; disposal/drain still awaits this tracked operation before
      // it can tear down the canonical session manager.
      if (lastError) throw lastError;
    })();
    this.pendingReceiptWrites.add(write);
    void write.then(
      () => this.pendingReceiptWrites.delete(write),
      () => this.pendingReceiptWrites.delete(write),
    );
    return write;
  }

  private updateExtensionActivity(
    toolCallId: string,
    toolName: string,
    extensionOrigin: ExtensionToolOrigin | undefined,
    status: "running" | "completed" | "failed",
    startedAt: string,
    updatedAt: string,
    value: unknown,
    completedAt?: string,
    durationMs?: number,
  ): ExtensionRunActivity | undefined {
    if (!extensionOrigin) return undefined;
    const current = this.extensionActivities.get(toolCallId);
    if (!current && !hasStructuredExtensionRunActivity(value)) return undefined;
    const activityKey = current?.activityId ?? extensionActivityId(this.runtime.session.sessionManager.getSessionId(), toolCallId);
    const terminalStates = ["completed", "failed", "stopped", "rejected"];
    if (current?.lifecycle && terminalStates.includes(current.lifecycle.state)) {
      // Terminal admission is a Gateway fact: neither wall-clock order nor a
      // producer's later contradictory terminal may replace it.
      if (status === "running") return current;
      const requestedTerminal = status === "failed" ? "failed" : "completed";
      if (requestedTerminal !== current.lifecycle.state) return current;
    }
    const sequence = (this.extensionActivitySequences.get(activityKey) ?? current?.lifecycle?.sequence ?? 0) + 1;
    this.extensionActivitySequences.set(activityKey, sequence);
    // Returning an async launch receipt completes only the outer tool call. The
    // delegated run remains current until its lifecycle artifact reaches a
    // terminal state; treating this acknowledgement as terminal made pills
    // flash directly into Recently Finished with a near-zero duration.
    const requestedAsyncDir = extensionRunAsyncDir(value);
    const derivedStatus = extensionActivityStatusFromTool(value, status);
    const { terminal, reportedTerminal } = derivedStatus;
    const effectiveStatus = derivedStatus.status;
    const observedAt = new Date().toISOString();
    const terminalAt = terminal ? current?.lifecycle?.terminalAt ?? observedAt : current?.lifecycle?.terminalAt;
    const recentUntil = terminalAt ? new Date(Date.parse(terminalAt) + 900_000).toISOString() : undefined;
    const activity = projectExtensionRunActivity(value, {
      id: toolCallId,
      activityId: activityKey,
      toolCallId,
      source: extensionOrigin,
      title: toolName,
      status: current?.lifecycle && terminalStates.includes(current.lifecycle.state) ? current.status : effectiveStatus,
      authoritativeStatus: reportedTerminal || Boolean(current?.lifecycle && terminalStates.includes(current.lifecycle.state)),
      startedAt,
      updatedAt,
      ...(terminal && completedAt ? { completedAt } : {}),
      ...(!terminal || durationMs === undefined ? {} : { durationMs }),
      ...(current ? { previous: current } : {}),
      sequence,
      observedAt,
      ...(terminalAt ? { terminalAt } : {}),
      ...(recentUntil ? { recentUntil } : {}),
    });
    if (admitExtensionRunActivity(current, activity) === current) return current;
    const asyncDir = requestedAsyncDir ? this.canonicalExtensionArtifactDirectory(requestedAsyncDir) : undefined;
    if (activity.runId && !this.bindExtensionRunOwnership(activity.runId, {
      toolCallId,
      ...(asyncDir === undefined ? {} : { asyncDir }),
      terminal: activity.status !== "running",
    })) return current;
    // A synchronous result can be the first lifecycle payload carrying runId.
    // Re-key any artifact-created synthetic row to the real Pi tool call.
    const ownership = activity.runId ? this.extensionRunOwnership.get(activity.runId) : undefined;
    const syntheticToolCallId = ownership?.toolCallId?.startsWith("subagent:")
      ? ownership.toolCallId
      : undefined;
    const synthetic = syntheticToolCallId && syntheticToolCallId !== toolCallId
      ? this.extensionActivities.get(syntheticToolCallId)
      : undefined;
    if (synthetic) {
      this.stopExtensionActivityWatcher(syntheticToolCallId!);
      this.extensionActivities.delete(syntheticToolCallId!);
      const merged = projectExtensionRunActivity(value, {
        id: toolCallId,
        activityId: activityKey,
        toolCallId,
        source: extensionOrigin,
        title: toolName,
        status,
        startedAt,
        updatedAt,
        ...(completedAt ? { completedAt } : {}),
        ...(durationMs === undefined ? {} : { durationMs }),
        sequence,
        observedAt,
        ...(terminalAt ? { terminalAt } : {}),
        ...(recentUntil ? { recentUntil } : {}),
        previous: current
          ? {
              ...synthetic,
              ...current,
              children: current.children.length > 0 ? current.children : synthetic.children,
            }
          : synthetic,
      });
      this.extensionActivities.delete(toolCallId);
      this.extensionActivities.set(toolCallId, merged);
      this.upsertExtensionActivity(merged);
    } else {
      this.extensionActivities.delete(toolCallId);
      this.extensionActivities.set(toolCallId, activity);
      this.upsertExtensionActivity(activity);
    }
    const retainedActivity = this.extensionActivities.get(toolCallId)!;
    this.trimExtensionActivities();
    if (asyncDir && retainedActivity.status === "running") this.startExtensionActivityWatcher(toolCallId, asyncDir);
    if (retainedActivity.status !== "running") {
      this.stopExtensionActivityWatcher(toolCallId);
      void this.appendExtensionActivityReceipt(retainedActivity).catch((error) => this.emit("session.extensionError", safeJson(error)));
    }
    return retainedActivity;
  }

  private measureToolDuration(
    toolCallId: string,
    startedAt: string,
    completedAt: string,
    completedMonotonicMs: number
  ): number {
    const startedMonotonicMs = this.toolStartedAtMonotonicMs.get(toolCallId);
    if (startedMonotonicMs !== undefined) {
      return Math.max(0, Math.round(completedMonotonicMs - startedMonotonicMs));
    }
    const startedWallClockMs = Date.parse(startedAt);
    const completedWallClockMs = Date.parse(completedAt);
    return Number.isFinite(startedWallClockMs) && Number.isFinite(completedWallClockMs)
      ? Math.max(0, completedWallClockMs - startedWallClockMs)
      : 0;
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
      this.emit("session.toolProgress", safeJson(this.toolProgressWire(state)));
      return;
    }
    if (pending) return;
    const timer = setTimeout(() => {
      this.toolProgressTimers.delete(state.toolCallId);
      const current = this.toolExecutions.get(state.toolCallId);
      if (!current) return;
      this.toolProgressPublishedAt.set(state.toolCallId, Date.now());
      this.emit("session.toolProgress", safeJson(this.toolProgressWire(current)));
    }, minimumIntervalMs - (now - last));
    timer.unref();
    this.toolProgressTimers.set(state.toolCallId, timer);
  }

  private toolProgressWire(state: ToolExecutionState): ToolExecutionState {
    return state.extensionActivity
      ? { ...state, liveActivityRevision: this.liveActivityRevision, extensionActivityAsOf: this.extensionActivityAsOf }
      : state;
  }

  /** Lifecycle updates are compact presentation deltas, not transcript
   * changes. Avoid rebuilding and sending the canonical transcript for every
   * status artifact heartbeat. */
  private publishExtensionActivity(activity: ExtensionRunActivity): void {
    this.emit("session.extensionActivity", safeJson({
      activity: this.extensionActivityWire(activity),
      liveActivityRevision: this.liveActivityRevision,
      extensionActivityAsOf: this.extensionActivityAsOf,
    }));
  }

  private clearToolProgressTimers(): void {
    for (const timer of this.toolProgressTimers.values()) clearTimeout(timer);
    this.toolProgressTimers.clear();
    this.toolProgressPublishedAt.clear();
    this.toolStartedAtMonotonicMs.clear();
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

  private extensionToolOrigin(toolName: string): ExtensionToolOrigin | undefined {
    const session = this.runtime?.session;
    if (!session) return undefined;
    const tool = session.getAllTools().find(candidate => candidate.name === toolName);
    if (!tool) return undefined;
    const extensions = session.resourceLoader.getExtensions().extensions.filter(extension => extension.tools.has(toolName));
    if (extensions.length !== 1) return undefined;
    const extension = extensions[0]!;
    if (tool.sourceInfo.path !== extension.path && tool.sourceInfo.path !== extension.resolvedPath) return undefined;
    const extensionOwner = extensionOwnerFor(extension);
    const source = extensionOwner.source.trim().slice(0, 256);
    return source ? { source, owner: extensionOwner } : undefined;
  }

  private rememberToolMetadata(toolCallId: string, state: ToolExecutionState): void {
    this.toolMetadata.delete(toolCallId);
    this.toolMetadata.set(toolCallId, {
      startedAt: state.startedAt,
      ...(state.completedAt ? { completedAt: state.completedAt } : {}),
      ...(state.durationMs === undefined ? {} : { durationMs: state.durationMs }),
      lastProgressAt: state.lastProgressAt,
      progressSequence: state.progressSequence,
      ...(state.groupId ? { groupId: state.groupId } : {}),
      ...(state.groupIndex === undefined ? {} : { groupIndex: state.groupIndex }),
      ...(state.groupCount === undefined ? {} : { groupCount: state.groupCount }),
      ...(state.groupFinalized ? { groupFinalized: true } : {}),
      ...(state.extensionOrigin ? { extensionOrigin: state.extensionOrigin } : {}),
    });
    while (this.toolMetadata.size > 2_048) {
      const oldest = this.toolMetadata.keys().next().value as string | undefined;
      if (!oldest) break;
      this.toolMetadata.delete(oldest);
    }
  }

  private extensionActivityWire(activity: ExtensionRunActivity): ExtensionRunActivity {
    if (!activity.lifecycle) return activity;
    const recency = this.dependencies.extensionActivityRecency.visibility(activity);
    return { ...activity, lifecycle: { ...activity.lifecycle, visibility: recency.visibility, remainingMs: recency.remainingMs } };
  }

  private extensionActivityVisibility(activity: ExtensionRunActivity): "current" | "recent" | "historical" | "unknown" {
    return this.dependencies.extensionActivityRecency.visibility(activity).visibility;
  }

  /** Recency is the sole expiry owner. At the wall-clock boundary remove the
   * disposable ambient rows, advance this slot's revision, and publish one
   * authoritative snapshot rather than waiting for a client request. */
  private onExtensionActivityExpiry(frame: ActivityExpiryFrame): void {
    if (this.disposed) return;
    let removed = false;
    for (const [toolCallId, activity] of this.extensionActivities) {
      const key = activity.activityId ?? activity.id;
      if (!frame.expiredActivityIds.includes(key)) continue;
      this.extensionActivities.delete(toolCallId);
      removed = true;
    }
    if (!removed) return;
    this.liveActivityRevision += 1;
    this.extensionActivityAsOf = frame.asOf;
    this.revision += 1;
    this.publishSnapshot();
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
          ...(admission?.skillName === undefined ? {} : { skillName: admission.skillName }),
          ...(admission?.photoCount === undefined ? {} : { photoCount: admission.photoCount }),
          ...(admission?.fileAttachmentCount === undefined ? {} : { fileAttachmentCount: admission.fileAttachmentCount }),
          ...(admission?.attachments === undefined ? {} : { attachments: admission.attachments }),
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
        || item.skillName !== next.skillName
        || item.attachmentCount !== next.attachmentCount
        || item.photoCount !== next.photoCount
        || item.fileAttachmentCount !== next.fileAttachmentCount
        || JSON.stringify(item.attachments) !== JSON.stringify(next.attachments);
    });
    this.queuedMessages = reconciled;
    if (changed) this.queueRevision += 1;
  }

  private projectedQueue(): QueuedMessageState[] {
    this.reconcileQueuedMessages();
    return this.queuedMessages.map(({
      id, behavior, text, attachmentCount, photoCount, fileAttachmentCount, attachments,
    }) => ({
      id,
      behavior,
      text,
      attachmentCount,
      ...(photoCount === undefined ? {} : { photoCount }),
      ...(fileAttachmentCount === undefined ? {} : { fileAttachmentCount }),
      ...(attachments === undefined ? {} : { attachments }),
    }));
  }

  private static queueText(text: string, attachmentEnvelope: string): string {
    return [text.trim(), attachmentEnvelope].filter(Boolean).join("\n\n");
  }

  private static validateQueue(items: Array<Pick<QueuedMessageState, "text" | "attachmentCount"> & { skillName?: string }>): void {
    if (items.length > MAXIMUM_QUEUED_MESSAGES) {
      throw new GatewayError("invalid_request", `At most ${MAXIMUM_QUEUED_MESSAGES} messages may be queued`);
    }
    let totalBytes = 0;
    for (const item of items) {
      const bytes = Buffer.byteLength(item.text);
      if (bytes > MAXIMUM_QUEUED_MESSAGE_BYTES) {
        throw new GatewayError("invalid_request", "A queued message is too large to manage safely");
      }
      if (item.text.trim().length === 0 && item.attachmentCount === 0 && item.skillName === undefined) {
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
    const streamingMessage = session.state.streamingMessage
      ?? (this.streamPresentationId ? this.latestStreamingMessage : undefined);
    const streaming = streamingMessage
      ? (() => {
        this.captureStreamIdentity(streamingMessage);
        return projectMessage(
          "streaming",
          this.streamAnchorId ?? null,
          this.streamStartedAt ?? new Date().toISOString(),
          streamingMessage,
          this.dependencies.blobs,
          undefined,
          this.streamPresentationId,
          this.finalizedStreamPresentationId === this.streamPresentationId,
        );
      })()
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
      ...(this.pendingPrompt ? { pendingPrompt: this.pendingPrompt } : {}),
      compactionQueued: this.pendingManualCompaction !== undefined,
      automaticCompactionEnabled: session.autoCompactionEnabled,
      transcript: transcriptPage.items,
      transcriptStart: transcriptPage.start,
      transcriptTotal: transcriptPage.total,
      ...(streaming ? { streaming } : {}),
      ...(session.sessionManager.getLeafId() ? { leafEntryId: session.sessionManager.getLeafId()! } : {}),
      ...(this.operation ? { operation: this.operation } : {}),
      ...(this.pendingExtensionCommand ? { extensionCommand: this.pendingExtensionCommand } : {}),
      ...(this.retry ? { retry: this.retry } : {}),
      toolExecutions: [...this.toolExecutions.values()]
        .filter((tool) => this.effectivePhase === "running" || tool.status !== "running")
        .sort((left, right) => left.order - right.order),
      ...(() => {
        const visible = [...this.extensionActivities.values()]
          .map((activity) => ({ activity, visibility: this.extensionActivityVisibility(activity) }))
          .filter(({ visibility }) => visibility === "current" || visibility === "recent")
          // Current work is always retained ahead of recent terminal rows when
          // count or byte bounds force omission.
          .sort((left, right) => {
            const bucket = (visibility: string) => visibility === "current" ? 0 : 1;
            return bucket(left.visibility) - bucket(right.visibility)
              || right.activity.updatedAt.localeCompare(left.activity.updatedAt);
          })
          .map(({ activity }) => this.extensionActivityWire(activity));
        const bounded = boundExtensionActivities(visible);
        return bounded.activities.length > 0 || bounded.omittedCount > 0
          ? {
              ...(bounded.activities.length > 0 ? { extensionActivities: bounded.activities } : {}),
              ...(bounded.omittedCount > 0 ? { extensionActivityOmissions: {
                count: bounded.omittedCount,
                bytes: bounded.omittedBytes,
                reason: bounded.hitCount && bounded.hitBytes ? "countAndBytes" : bounded.hitCount ? "count" : "bytes",
              } } : {}),
            }
          : {};
      })(),
      liveActivityRevision: this.liveActivityRevision,
      extensionActivityAsOf: this.extensionActivityAsOf,
      extensionPresentation: this.ui.state(),
      diagnostics: this.runtime.diagnostics.map((diagnostic) => ({ type: diagnostic.type, message: diagnostic.message })),
    });
  }

  transcriptPage(
    before?: number,
    expectedNextEntryId?: string,
    expectedRuntimeGeneration?: string,
    expectedLeafEntryId?: string,
  ): TranscriptPage {
    this.assertNoTrustReload();
    if (expectedRuntimeGeneration !== undefined && expectedRuntimeGeneration !== this.runtimeGeneration) {
      throw new GatewayError("conflict", "The session runtime changed while loading history. Refresh the session and try again.", true);
    }
    const leafEntryId = this.runtime.session.sessionManager.getLeafId();
    if (expectedLeafEntryId !== undefined && expectedLeafEntryId !== leafEntryId) {
      throw new GatewayError("conflict", "The session branch changed while loading history. Refresh the session and try again.", true);
    }
    try {
      return {
        ...projectTranscriptPage(
          this.runtime.session.sessionManager,
          this.dependencies.blobs,
          before,
          undefined,
          expectedNextEntryId,
          this.toolMetadata,
          this.presentationIDs,
        ),
        runtimeGeneration: this.runtimeGeneration,
        ...(leafEntryId ? { leafEntryId } : {}),
      };
    } catch (error) {
      if (error instanceof Error && error.message.includes("anchor changed")) {
        throw new GatewayError("conflict", "The session branch changed while loading history. Refresh the session and try again.", true);
      }
      throw error;
    }
  }

  /** Canonical reserved receipts are read independently of transcript/tree
   * projection. The page revision includes entry/parent identity so branch
   * changes invalidate cursors without creating a second history store. */
  extensionActivityHistory(cursor?: string, limit = 25, filter?: { ownerId?: string; runId?: string; state?: "completed" | "failed" | "stopped" | "rejected" }): ExtensionActivityHistoryPage {
    this.assertNoTrustReload();
    return listExtensionActivityHistory(
      this.runtime.session.sessionManager.getEntries(),
      this.id,
      cursor,
      limit,
      this.runtime.session.sessionManager.getLeafId() ?? "root",
      filter,
    );
  }

  extensionActivityDetail(activityId: string, expectedHistoryRevision?: string): ExtensionRunActivity | undefined {
    this.assertNoTrustReload();
    if (expectedHistoryRevision !== undefined) {
      const actual = extensionActivityHistoryRevision(this.runtime.session.sessionManager.getEntries(), this.id, this.runtime.session.sessionManager.getLeafId() ?? "root");
      if (actual !== expectedHistoryRevision) throw new GatewayError("conflict", "Extension activity generation changed; refresh history", true);
    }
    const receipts = extensionActivityReceipts(this.runtime.session.sessionManager.getEntries(), this.id);
    const receipt = receipts.find((entry) => entry.receipt.activityId === activityId)?.receipt;
    if (receipt) return extensionReceiptActivity(receipt);
    return [...this.extensionActivities.values()].find((activity) => (activity.activityId ?? activity.id) === activityId);
  }

  publishSnapshot(): void {
    if (this.disposed || this.trustReloadPending) return;
    // A coalesced streaming frame must not overtake the state transition this
    // snapshot publishes.
    this.flushPendingProgress();
    this.eventSequence += 1;
    this.hooks.broadcast(this.id, "session.snapshot", this.snapshot(this.eventSequence) as unknown as JsonValue);
    this.publishSummary();
  }

  private publishSummary(): void {
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
    queueDisplay?: {
      text: string;
      skillName?: string;
      attachmentEnvelope: string;
      attachmentCount: number;
      photoCount?: number;
      fileAttachmentCount?: number;
      attachments?: QueuedMessageState["attachments"];
    },
  ): Promise<{ operationId: string }> {
    return this.lane.run(async () => {
      this.assertUsable();
      if (this.lifecycle.isDraining) throw new GatewayError("busy", "Session is draining for an administrative restart", true);
      const session = this.runtime.session;
      if (queueDisplay?.attachments !== undefined
        && (queueDisplay.attachments.length > MAXIMUM_PROMPT_ATTACHMENTS
          || queueDisplay.attachments.length !== queueDisplay.attachmentCount)) {
        throw new GatewayError("invalid_request", "Prompt attachment descriptors do not match the bounded attachment count");
      }
      if (queueDisplay?.skillName !== undefined) {
        const invocationName = `skill:${queueDisplay.skillName}`;
        const commands = this.commands();
        const skillMatches = commands.filter(
          (command) => command.source === "skill" && command.name === invocationName,
        );
        const collidesWithExtension = commands.some(
          (command) => command.source === "extension" && command.name === invocationName,
        );
        if (skillMatches.length !== 1 || collidesWithExtension
            || (text !== `/${invocationName}` && !text.startsWith(`/${invocationName} `))) {
          throw new GatewayError("conflict", "The selected skill is no longer unambiguous for this session");
        }
      }
      const extensionCommandName = text.startsWith("/") ? text.slice(1).split(/\s/u, 1)[0] : undefined;
      const isExactExtensionCommand = extensionCommandName !== undefined
        && session.extensionRunner.getCommand(extensionCommandName) !== undefined;
      const queuesIntoActiveRun = session.isStreaming && behavior !== undefined && !isExactExtensionCommand;
      const operationId = randomUUID();
      if (session.isStreaming && !behavior && !isExactExtensionCommand) throw new GatewayError("busy", "Session is running; choose steer or follow-up");
      if (queuesIntoActiveRun) {
        this.reconcileQueuedMessages();
        const display = queueDisplay ?? {
          text,
          attachmentEnvelope: "",
          attachmentCount: images.length,
          ...(images.length > 0 ? { photoCount: images.length } : {}),
          ...(images.length > 0 ? { fileAttachmentCount: 0 } : {}),
        };
        RuntimeSlot.validateQueue([...this.queuedMessages, {
          text: display.text,
          attachmentCount: display.attachmentCount,
          ...(display.skillName === undefined ? {} : { skillName: display.skillName }),
        }]);
        this.pendingQueueAdmission = {
          // The returned operation identity is also the stable projected queue
          // identity, giving clients an exact settlement receipt.
          id: operationId, behavior: behavior!, text: display.text,
          attachmentCount: display.attachmentCount,
          ...(display.skillName === undefined ? {} : { skillName: display.skillName }),
          ...(display.photoCount === undefined ? {} : { photoCount: display.photoCount }),
          ...(display.fileAttachmentCount === undefined
            ? {}
            : { fileAttachmentCount: display.fileAttachmentCount }),
          ...(display.attachments === undefined ? {} : { attachments: display.attachments }),
          attachmentEnvelope: display.attachmentEnvelope, images,
        };
      }

      if (isExactExtensionCommand) {
        this.pendingExtensionCommand = { id: operationId, kind: "command", startedAt: new Date().toISOString() };
        // Exact commands run before Pi's preflight callback and can wait on UI
        // indefinitely. Persist the provisional admission before invoking Pi.
        await this.dependencies.markers.mark(this.id, operationId);
        this.revision += 1;
        this.publishSnapshot();
      } else if (!queuesIntoActiveRun) {
        this.activeOperationId = operationId;
        this.operation = { id: operationId, kind: "prompt", startedAt: new Date().toISOString() };
        this.pendingPrompt = {
          id: operationId,
          createdAt: new Date().toISOString(),
          ...(behavior === undefined ? {} : { behavior }),
          text: boundedSummaryText(
            queueDisplay?.text ?? text,
            MAXIMUM_PENDING_PROMPT_BYTES
          ),
          attachmentCount: queueDisplay?.attachmentCount ?? images.length,
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
        this.revision += 1;
        // Publish before entering Pi preflight. Automatic compaction can begin
        // inside that call before the RPC receives its admission result.
        this.publishSnapshot();
      }

      let acceptedResolve!: (accepted: boolean) => void;
      const accepted = new Promise<boolean>((resolve) => { acceptedResolve = resolve; });
      this.lifecycle.beginPreflight();
      const sdkRun = session.prompt(text, {
        images,
        ...(queuesIntoActiveRun ? { streamingBehavior: behavior } : {}),
        source: "rpc",
        preflightResult: acceptedResolve,
      });
      let runSettled = false;
      let commandSettled = false;
      let admissionFinalized = false;
      const promptRun = this.lifecycle.trackPrompt(sdkRun, () => {
        runSettled = true;
        this.maybePerformExtensionShutdown();
      });
      const run = isExactExtensionCommand
        ? this.lifecycle.trackCommand(promptRun, () => { commandSettled = true; this.maybePerformExtensionShutdown(); })
        : promptRun;

      const settleWithoutAgent = async () => {
        if (this.shuttingDown || this.hasActiveAgentRun || queuesIntoActiveRun) return;
        const owned = this.activeOperationId === operationId || this.operation?.id === operationId;
        if (!owned || this.queuedManualCompactionInFlight) return;
        if (this.pendingPrompt?.id === operationId) this.pendingPrompt = undefined;
        if (!this.pendingManualCompaction) await this.dependencies.markers.clear(this.id, operationId);
        // Marker I/O may suspend behind a newer run. Clear only this run's live
        // projection; conditional marker deletion already protects its successor.
        if (this.activeOperationId === operationId) this.activeOperationId = undefined;
        if (this.operation?.id === operationId) this.operation = undefined;
        if (this.activeOperationId !== undefined || this.hasActiveAgentRun) return;
        this.phase = "idle";
        if (this.pendingManualCompaction) {
          this.publishSnapshot();
          this.startPendingManualCompaction();
        } else {
          this.hooks.settled(this.id);
          this.revision += 1;
          this.publishSnapshot();
        }
      };

      void run.then(
        () => admissionFinalized ? settleWithoutAgent() : undefined,
        async (error) => {
          this.emit("session.operationFailed", safeJson({ operationId, message: error instanceof Error ? error.message : String(error) }));
          if (admissionFinalized) await settleWithoutAgent();
        },
      );

      let admitted: boolean;
      try {
        // Pi's callback is authoritative. A local timeout could reject while the
        // same uncancelled input handler later accepts canonical work.
        admitted = await accepted;
      } finally {
        this.pendingQueueAdmission = undefined;
        this.lifecycle.endPreflight();
      }
      admissionFinalized = true;
      if (!admitted) {
        if (this.activeOperationId === operationId) this.activeOperationId = undefined;
        if (this.operation?.id === operationId) this.operation = undefined;
        if (this.pendingPrompt?.id === operationId) this.pendingPrompt = undefined;
        if (this.pendingExtensionCommand?.id === operationId) this.pendingExtensionCommand = undefined;
        await this.dependencies.markers.clear(this.id, operationId);
        this.revision += 1;
        this.publishSnapshot();
        throw new GatewayError("invalid_request", "The agent runtime rejected the prompt before admission");
      }

      if (!queuesIntoActiveRun && !isExactExtensionCommand) await this.dependencies.markers.mark(this.id, operationId);
      this.revision += 1;
      this.publishSnapshot();

      if (isExactExtensionCommand) {
        const finishCommand = async () => {
          if (this.pendingExtensionCommand?.id !== operationId) return;
          if (this.hasActiveAgentRun && this.activeOperationId !== undefined) {
            // Transfer marker ownership atomically back to the foreground/new
            // agent run after the command's provisional marker.
            await this.dependencies.markers.mark(this.id, this.activeOperationId);
          } else if (this.activeOperationId === undefined) {
            if (this.pendingAssistantCompletion) {
              // No continuation claimed the final assistant entry. Retire the
              // command owner, then let the same durable attention barrier own
              // marker cleanup and truthful settlement.
              this.pendingExtensionCommand = undefined;
              await this.beginAttentionSettlement(this.pendingAssistantCompletion);
              this.maybePerformExtensionShutdown();
              return;
            }
            await this.dependencies.markers.clear(this.id, operationId);
            this.hooks.settled(this.id);
          }
          if (this.pendingExtensionCommand?.id !== operationId) return;
          this.pendingExtensionCommand = undefined;
          this.revision += 1;
          this.publishSnapshot();
          this.maybePerformExtensionShutdown();
        };
        if (!commandSettled) {
          try { await run; } finally { await finishCommand(); }
        } else {
          await finishCommand();
        }
      } else if (runSettled) {
        // Handles input action:"handled" (and any other accepted no-agent path)
        // after the marker exists, without touching a newer operation.
        await settleWithoutAgent();
      }
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
        const visibleRuntimeText = RuntimeSlot.queueText(text, previous.attachmentEnvelope);
        return {
          ...previous,
          behavior: item.behavior,
          text,
          runtimeText: text === previous.text
            ? previous.runtimeText
            : previous.skillName === undefined
              ? visibleRuntimeText
              : `/skill:${previous.skillName}${visibleRuntimeText ? ` ${visibleRuntimeText}` : ""}`,
          ordinal: this.nextQueueOrdinal++,
        };
      });
      RuntimeSlot.validateQueue(next);

      const commands = this.commands();
      const extensionCommands = new Set(
        commands.filter((command) => command.source === "extension").map((command) => command.name),
      );
      for (const item of next) {
        if (item.skillName !== undefined) {
          const invocationName = `skill:${item.skillName}`;
          const skillMatches = commands.filter(
            (command) => command.source === "skill" && command.name === invocationName,
          );
          if (skillMatches.length !== 1 || extensionCommands.has(invocationName)) {
            throw new GatewayError("conflict", "A queued skill is no longer unambiguous for this session", true);
          }
        }
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

  async compact(instructions?: string): Promise<{ queued: boolean }> {
    this.assertUsable();
    if (this.manualCompactionClaim) {
      throw new GatewayError("busy", "A manual compaction is already pending for this session");
    }
    const claim = Symbol("manual-compaction");
    this.manualCompactionClaim = claim;

    try {
      let queuedCompletion: Promise<void> | undefined;
      const queued = await this.lane.run(async () => {
        this.assertUsable();
        if (this.manualCompactionClaim !== claim) {
          throw new GatewayError("conflict", "Manual compaction ownership changed", true);
        }
        if (this.hasActiveAgentRun) {
          queuedCompletion = new Promise<void>((resolve, reject) => {
            this.pendingManualCompaction = {
              ...(instructions === undefined ? {} : { instructions }),
              resolve,
              reject,
            };
          });
          this.revision += 1;
          this.publishSnapshot();
          return true;
        }

        this.assertIdleForManualCompaction(claim);
        await this.performManualCompaction(instructions, false);
        return false;
      });

      // Keep the command receipt pending until the exact queued mutation has
      // completed. A disconnected client therefore cannot turn accepted work
      // into an acknowledged-but-unperformed compaction.
      if (queuedCompletion) await queuedCompletion;
      return { queued };
    } finally {
      if (this.manualCompactionClaim === claim) this.manualCompactionClaim = undefined;
    }
  }

  private startPendingManualCompaction(): void {
    const pending = this.pendingManualCompaction;
    if (!pending || this.shuttingDown) return;
    void this.lane.run(async () => {
      if (this.pendingManualCompaction !== pending || this.shuttingDown) return;
      // Another prompt can enter SDK preflight before this lane handoff runs.
      // Leave the exact compaction pending for that newer run's final settlement.
      if (this.hasActiveAgentRun) return;
      this.pendingManualCompaction = undefined;
      this.queuedManualCompactionInFlight = true;
      try {
        await this.performManualCompaction(pending.instructions, true);
        pending.resolve();
      } catch (error) {
        pending.reject(error);
      }
    }).catch((error) => {
      if (this.pendingManualCompaction === pending) {
        this.pendingManualCompaction = undefined;
        this.revision += 1;
        this.publishSnapshot();
      }
      pending.reject(error);
    });
  }

  private async performManualCompaction(instructions: string | undefined, queued: boolean): Promise<void> {
    let operationError: unknown;
    this.phase = "compacting";
    this.operation = { kind: "compaction", startedAt: new Date().toISOString(), reason: "manual" };
    this.revision += 1;
    this.publishSnapshot();
    try {
      await this.runtime.session.compact(instructions);
    } catch (error) {
      operationError = error;
    }

    if (queued) {
      try {
        // The queued command and restart-drain owner cannot settle ahead of the
        // durable marker that proves accepted work remains live across restart.
        await this.dependencies.markers.clear(this.id);
      } catch (markerError) {
        this.queuedManualCompactionInFlight = false;
        this.phase = "interrupted";
        this.operation = undefined;
        this.retry = undefined;
        this.revision += 1;
        this.publishSnapshot();
        if (operationError !== undefined) {
          throw new AggregateError([operationError, markerError], "Compaction and run-marker cleanup failed");
        }
        throw markerError;
      }
      this.queuedManualCompactionInFlight = false;
      this.hooks.settled(this.id);
    }

    this.phase = "idle";
    this.operation = undefined;
    this.retry = undefined;
    this.revision += 1;
    this.publishSnapshot();
    if (operationError !== undefined) throw operationError;
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
      const result = await this.withRebindAttentionDisposition("reset", () => this.runtime.fork(entryId, { position }));
      if (result.cancelled) throw new GatewayError("cancelled", "Fork was cancelled by an extension");
      const next = this.id;
      if (previous !== next) await this.hooks.rekey(previous, next, this, "reset");
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
    return admitCommandCatalog(
      [...extension, ...prompts, ...skills].sort((a, b) => a.name.localeCompare(b.name)),
    );
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

  respondToInteraction(id: string, hostEpoch: string, presentationRevision: number, value: unknown, cancelled: boolean): void {
    this.assertNoTrustReload();
    this.ui.respond(id, hostEpoch, presentationRevision, value, cancelled);
  }

  updateExtensionEditor(hostEpoch: string, baseRevision: number, operationId: string, text: string): JsonValue {
    this.assertNoTrustReload();
    return this.ui.updateEditor(hostEpoch, baseRevision, operationId, text) as unknown as JsonValue;
  }

  setExtensionToolsExpanded(hostEpoch: string, presentationRevision: number, expanded: boolean): JsonValue {
    this.assertNoTrustReload();
    const state = this.ui.presentation.state();
    if (state.hostEpoch !== hostEpoch) throw new GatewayError("conflict", "Extension presentation epoch is stale");
    if (state.revision !== presentationRevision) throw new GatewayError("conflict", "Extension presentation revision is stale");
    this.runtime.session.extensionRunner.getUIContext().setToolsExpanded(expanded);
    this.extensionHost.rerender();
    return { updated: true };
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
        await this.reloadBoundSession();
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
      const result = await this.withRebindAttentionDisposition("discard", () => this.runtime.importFromJsonl(path, cwdOverride));
      if (result.cancelled) throw new GatewayError("cancelled", "Session import was cancelled by an extension");
      this.summaryContentDirty = true;
      this.revision += 1;
      this.publishSnapshot();
      this.hooks.changed(this.id);
    });
  }

  async export(format: "html" | "jsonl"): Promise<{ blobId: string; name: string; mimeType: string }> {
    this.assertUsable();
    this.activeExports += 1;
    try {
      return await this.lane.run(() => this.dependencies.blobs.withFileProductionAdmission(async () => {
        this.assertUsable();
        if (this.runtime.session.isStreaming
          || this.effectivePhase === "running"
          || this.effectivePhase === "compacting"
          || this.effectivePhase === "retrying"
          || this.runtime.session.isBashRunning) {
          throw new GatewayError("busy", "Session must be idle for this operation");
        }
        const source = this.runtime.session.sessionFile;
        if (!source) throw new GatewayError("conflict", "Session has no file to export");
        const sourceMetadata = await stat(source);
        if (!sourceMetadata.isFile() || sourceMetadata.size > BLOB_MAX_ITEM_BYTES) {
          throw new GatewayError("conflict", "Session export exceeds the 25 MiB limit");
        }
        const directory = await mkdtemp(join(tmpdir(), "tron-session-export-"));
        try {
          const output = join(directory, `session.${format}`);
          let path: string;
          if (format === "html") {
            path = await this.runtime.session.exportToHtml(output);
          } else {
            // The SDK JSONL exporter linearizes only the active branch. A Tron
            // audit export must retain the canonical append-only tree verbatim,
            // including abandoned branches and their parent identities.
            await copyFile(source, output);
            path = output;
          }
          const mimeType = format === "html" ? "text/html; charset=utf-8" : "application/x-ndjson";
          const name = `${basename(this.runtime.session.sessionName ?? this.id).replace(/[^A-Za-z0-9._-]+/g, "-")}.${format}`;
          const metadata = await stat(path);
          if (!metadata.isFile() || metadata.size > BLOB_MAX_ITEM_BYTES) {
            throw new GatewayError("conflict", "Session export exceeds the 25 MiB limit");
          }
          return { blobId: await this.dependencies.blobs.registerFile(path, mimeType), name, mimeType };
        } finally {
          await rm(directory, { recursive: true, force: true });
        }
      }));
    } finally {
      this.activeExports = Math.max(0, this.activeExports - 1);
    }
  }

  private async waitForReceiptWrites(): Promise<void> {
    while (this.pendingReceiptWrites.size > 0) {
      await Promise.allSettled([...this.pendingReceiptWrites]);
    }
  }

  async dispose(): Promise<void> {
    if (this.disposed) return;
    if ((this.isBusy && this.pendingReceiptWrites.size === 0) || this.trustReloadPending) throw new GatewayError("busy", "Cannot dispose a busy session runtime");
    await this.waitForReceiptWrites();
    await this.disposeIf(() => true);
  }

  /**
   * Disposes an idle slot only if its registry reservation is still current
   * after any preceding lane work settles. This is the handoff point that lets
   * a newly acquired or subscribed session cancel idle eviction safely.
   */
  async disposeIf(shouldDispose: () => boolean): Promise<boolean> {
    if (this.disposed) return false;
    await this.waitForReceiptWrites();
    return this.lane.run(async () => {
      if (this.disposed || !shouldDispose()) return false;
      if (this.isBusy || this.trustReloadPending) {
        throw new GatewayError("busy", "Cannot dispose a busy session runtime");
      }
      await this.disposeRuntime();
      return true;
    });
  }

  get isDisposed(): boolean {
    return this.disposed;
  }

  async shutdown(): Promise<void> {
    if (this.disposed) return;
    if (this.shutdownPromise) return this.shutdownPromise;
    const operation = this.performShutdown();
    this.shutdownPromise = operation;
    try {
      await operation;
    } catch (error) {
      if (this.shutdownPromise === operation) this.shutdownPromise = undefined;
      throw error;
    }
  }

  private async performShutdown(): Promise<void> {
    const hadAdmittedWork = this.isBusy;
    const sessionID = this.id;
    this.shuttingDown = true;
    const cancellation = new GatewayError("cancelled", "Gateway shutdown cancelled queued compaction");
    const pending = this.pendingManualCompaction;
    if (pending) {
      this.pendingManualCompaction = undefined;
      pending.reject(cancellation);
    }

    // Abort every possible SDK owner before waiting on the lane it may hold.
    // These methods are idempotent no-ops when their owner is inactive.
    this.runtime.session.abortCompaction();
    this.runtime.session.abortRetry();
    this.runtime.session.abortBranchSummary();
    this.runtime.session.abortBash();
    await this.runtime.session.abort();
    await this.waitForReceiptWrites();
    // A command may hold the mutation lane while awaiting native UI. Cancel the
    // epoch's imperative interactions before joining that lane so shutdown cannot
    // deadlock behind a response that no client can deliver.
    this.ui.cancelAll("Gateway shutdown interrupted extension interaction");

    await this.lane.run(async () => {
      const latePending = this.pendingManualCompaction;
      if (latePending) {
        this.pendingManualCompaction = undefined;
        latePending.reject(cancellation);
      }
      this.queuedManualCompactionInFlight = false;
      await this.disposeRuntime();
      // Forced interruption intentionally leaves evidence for restart. Only a
      // verified clean, idle Pi shutdown removes its marker.
      if (!hadAdmittedWork) await this.dependencies.markers.clear(sessionID);
      this.phase = hadAdmittedWork ? "interrupted" : "idle";
      this.operation = undefined;
      this.pendingExtensionCommand = undefined;
      this.retry = undefined;
    });
  }

  private async disposeRuntime(): Promise<void> {
    this.unregisterExtensionExpiry();
    for (const activity of this.extensionActivities.values()) {
      this.dependencies.extensionActivityRecency.remove(activity.activityId ?? activity.id);
    }
    if (this.snapshotTimer) clearTimeout(this.snapshotTimer);
    if (this.progressFlushTimer) clearTimeout(this.progressFlushTimer);
    this.progressFlushTimer = undefined;
    this.pendingProgressMessage = undefined;
    this.latestStreamingMessage = undefined;
    this.streamIdentityMessage = undefined;
    this.streamAnchorId = undefined;
    this.streamPresentationId = undefined;
    this.streamStartedAt = undefined;
    this.finalizedStreamPresentationId = undefined;
    this.presentationIDs.clear();
    this.presentationIDOrder.splice(0);
    this.stopActivityHeartbeat();
    this.clearToolProgressTimers();
    this.clearExtensionActivityWatchers();
    this.extensionRunOwnership.clear();
    this.unsubscribe?.();
    this.ui.cancelAll();
    this.extensionHost.retire("Session runtime disposed");
    await this.runtime.dispose();
    this.lifecycle.retire();
    this.ui.retire();
    this.disposed = true;
  }

  private assertNoTrustReload(): void {
    if (this.trustReloadPending) {
      throw new GatewayError("busy", "Project trust is being reconfigured", true);
    }
  }

  private assertUsable(allowTrustReload = false): void {
    if (this.disposed) throw new GatewayError("conflict", "Session runtime was disposed", true);
    if (this.shuttingDown) throw new GatewayError("conflict", "Session runtime is shutting down", true);
    if (!allowTrustReload) this.assertNoTrustReload();
    this.touch();
  }

  private assertIdleForManualCompaction(claim: symbol): void {
    this.assertUsable();
    if (this.manualCompactionClaim !== claim) {
      throw new GatewayError("conflict", "Manual compaction ownership changed", true);
    }
    if (this.runtime.session.isStreaming
      || this.activeExports > 0
      || this.queuedManualCompactionInFlight
      || this.effectivePhase === "running"
      || this.effectivePhase === "compacting"
      || this.effectivePhase === "retrying"
      || this.runtime.session.isBashRunning) {
      throw new GatewayError("busy", "Session must be idle for this operation");
    }
  }

  private assertIdle(allowTrustReload = false): void {
    this.assertUsable(allowTrustReload);
    if (this.runtime.session.isStreaming || this.isDrainBusy) throw new GatewayError("busy", "Session must be idle for this operation");
  }
}
