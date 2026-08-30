import { createHash, randomUUID } from "node:crypto";
import type { AgentMessage } from "@earendil-works/pi-agent-core";
import { closeSync, existsSync, fstatSync, lstatSync, openSync, readSync, realpathSync, watch, type FSWatcher } from "node:fs";
import { performance } from "node:perf_hooks";
import { copyFile, mkdtemp, open, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import type { ImageContent, Model } from "@earendil-works/pi-ai";
import {
  AgentSessionRuntime,
  createAgentSessionFromServices,
  createAgentSessionRuntime,
  createAgentSessionServices,
  type AgentSession,
  type AgentSessionEvent,
  type CreateAgentSessionRuntimeFactory,
  type ExtensionCommandContextActions,
  type Extension,
  type ModelRuntime,
  SessionManager,
} from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import type {
  ChatOrigin,
  CommandDetail,
  CommandInfo,
  ExtensionRunActivity,
  ExtensionRunChild,
  ExtensionToolOrigin,
  SessionProcessActivity,
  SessionProcessHistoryPage,
  SessionProcessOverview,
  JsonValue,
  QueuedMessageState,
  RetryState,
  SessionOperationState,
  SessionPhase,
  AdministrativeDrainBlockerCategory,
  SessionSnapshot,
  PendingPromptState,
  SessionSummaryUpdate,
  SessionTreeNode,
  ToolExecutionState,
  ResourceInvocation,
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
  boundCommandContent,
  boundStreamingProgressItem,
  fitSessionSnapshot,
  projectJson,
  projectMessage,
  mergeLiveToolOutput,
  projectToolOutput,
  projectToolResult,
  projectTranscriptPage,
  canonicalToolResultCallIDs,
  projectTree,
  toolSegmentId,
  safeJson,
  type ToolProjectionMetadata,
  type TranscriptPage,
} from "./projection.js";
import { RunMarkerCompletionConflictError, type RunMarkerEvidence, type RunMarkerStore } from "./run-markers.js";
import { attributeExtensions, currentExtensionOwner, currentInvocationContext, extensionOwnerFor, trustedExtensionOriginKind, withInvocationContext } from "../extensions/owner-attribution.js";
import { EXTENSION_LIFECYCLE_ARTIFACT_VERSION, admitExtensionRunActivity, boundExtensionActivities, extensionActivityId, extensionActivityStatusFromTool, extensionLifecycleState, extensionRunAsyncDir, extensionRunChildProducerId, hasForegroundSubagentRunActivity, hasStructuredExtensionRunActivity, inspectExtensionLifecycleArtifact, normalizeExtensionArtifact, projectExtensionRunActivity, terminalLifecycleStates, usesForegroundSubagentChildIdentity, type ExtensionArtifactRejectionReason, type ExtensionRunChildIdentityStrategy } from "./extension-run-projection.js";
import { EXTENSION_ACTIVITY_RECEIPT_TYPE, extensionActivityHistoryRevision, extensionActivityReceipts, extensionReceiptActivity, listExtensionActivityHistory, makeExtensionActivityReceipt } from "./extension-activity-history.js";
import { CONTEXT_DELIVERY_RECEIPT_TYPE, makeContextDeliveryReceipt } from "./context-delivery-receipts.js";
import { INVOCATION_RECEIPT_TYPE, invocationProjection, invocationReceipts, makeInvocationReceipt, receiptJSON, type InvocationProjection } from "./invocation-receipts.js";
import { ExtensionActivityRecency, type ActivityExpiryFrame, type ActivityVisibility } from "./extension-activity-recency.js";
import { ProcessActivityRecency, type ProcessActivityExpiryFrame } from "./process-activity-recency.js";
import {
  boundProcessActivities,
  listProcessHistory,
  processHistoryDetail,
  processOverview,
  subagentProcessesFromActivity,
} from "./process-activity.js";
import type { ExtensionActivityHistoryPage } from "./extension-activity-history.js";
import type { NotificationService } from "../notifications/notification-service.js";
import type { GatewayWorkHandle, GatewayWorkKind, GatewayWorkRegistry } from "./gateway-work-registry.js";
import { createTronNotifyExtension } from "../notifications/tron-notify-extension.js";

export type SessionBroadcast = (sessionId: string, topic: string, payload: JsonValue) => void;

type QueueBehavior = QueuedMessageState["behavior"];

type RuntimeQueuedMessage = QueuedMessageState & {
  runtimeText: string;
  resourceInvocation?: ResourceInvocation;
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

type ExtensionArtifactDirectoryIdentity = { dev: number; ino: number };
type OpenedExtensionArtifact = {
  handle: Awaited<ReturnType<typeof open>>;
  directory: ExtensionArtifactDirectoryIdentity;
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
const DEFAULT_RUNTIME_DISPOSAL_GRACE_MS = 5_000;
const MAX_PRESENTATION_IDENTITY_BINDINGS = 512;
const MAX_VALIDATED_CHILD_SESSION_PATHS = 2_048;
const RECOVERY_SESSION_OWNER = Symbol("recovery-session-owner");
const MAX_EXTENSION_ARTIFACT_BYTES = 256 * 1_024;
const MAX_EXTENSION_EVENT_TAIL_BYTES = 64 * 1_024;
const MAX_EXTENSION_EVENT_LINES = 256;

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

/** Recover only the canonical completion owned by durable run-marker evidence. */
export function completionOwnedByMarker(
  manager: Pick<SessionManager, "getEntry">,
  marker: RunMarkerEvidence,
): CanonicalAssistantCompletion | undefined {
  if (marker.assistantCompletionId === undefined) return undefined;
  const completion = successfulAssistantCompletion(manager.getEntry(marker.assistantCompletionId));
  return completion ? { ...completion, operationId: marker.operationId } : undefined;
}

export interface RuntimeSlotHooks {
  broadcast: SessionBroadcast;
  summaryChanged: (summary: SessionSummaryUpdate) => void;
  changed: (sessionId: string) => void;
  settled: (sessionId: string) => void;
  assistantResponseCompleted: (sessionId: string, completion: CanonicalAssistantCompletion, recovery: boolean) => Promise<void>;
  rekey: (
    previousId: string,
    nextId: string,
    slot: RuntimeSlot,
    disposition: SessionAttentionRebindDisposition,
    commitIdentity: () => void,
  ) => Promise<void>;
  closed?: (sessionId: string, slot: RuntimeSlot) => void;
}

export interface RuntimeSlotDependencies {
  agentDir: string;
  createModelRuntime: () => Promise<ModelRuntime>;
  trust: TrustService;
  blobs: BlobStore;
  markers: RunMarkerStore;
  extensionActivityRecency: ExtensionActivityRecency;
  processActivityRecency: ProcessActivityRecency;
  workRegistry: GatewayWorkRegistry;
  machineId?: string;
  notifications?: NotificationService;
  extensionArtifactWarning?: (warning: { reason: ExtensionArtifactRejectionReason; owner: string }) => void;
  /** Extension cleanup is advisory once runtime disposal begins. A handler that
   * never settles must not strand the canonical session behind idle eviction. */
  runtimeDisposalTimedOut?: (graceMs: number) => void;
}

type CompletionOwnershipItem = {
  completion: CanonicalAssistantCompletion;
  stamp: Promise<void> | undefined;
  fallbackWork?: GatewayWorkHandle;
};

export interface RuntimeDrainBlockerFact {
  key: string;
  category: AdministrativeDrainBlockerCategory;
  state: "active" | "settling" | "suspect";
  admittedAt?: string;
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
  private readonly stateChangeWaiters = new Set<() => void>();
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
  /** Exact SDK assistant objects already bound to canonical entries cannot be
   * re-admitted if Pi briefly retains them as streaming state. */
  private readonly canonicalizedStreamingMessages = new WeakSet<object>();
  /** Exact successful canonical assistant completion awaiting durable attention admission. */
  private pendingAssistantCompletion: CanonicalAssistantCompletion | undefined;
  /** `message_end` precedes Pi's synchronous canonical append. Capture immutable
   * operation ownership in that callback turn so an immediate extension
   * continuation cannot inherit the completion's already-consumed owner. */
  private readonly pendingAssistantBindings = new Map<object, {
    operationId?: string;
    ownsPromptOperation: boolean;
  }>();
  /** Exact completions retain canonical attention order. Their durable stamps
   * are started independently so a failed projection head cannot hide a newer
   * continuation from restart reconciliation. */
  private readonly completionOwnershipQueue: CompletionOwnershipItem[] = [];
  private readonly completionWorkOwners = new Map<string, string>();
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
  private readonly operationWork = new Map<string, GatewayWorkHandle>();
  private activeExports = 0;
  private operation: SessionOperationState | undefined;
  private pendingExtensionCommand: SessionOperationState | undefined;
  /** Gateway-owned causal graph. Canonical receipts remain the durable source;
   * these bounded maps are only the live projection used by snapshots. */
  private readonly invocations = new Map<string, InvocationProjection>();
  private readonly invocationFailures = new Map<string, string>();
  private retry: RetryState | undefined;
  private resourceReloadOptions: { resolveProjectTrust: () => Promise<boolean> } | undefined;
  private projectTrustReloadOverride: boolean | undefined;
  private trustReloadPending = false;
  private trustReloadWork: GatewayWorkHandle | undefined;
  private readonly toolExecutions = new Map<string, ToolExecutionState>();
  /** Tool-result message_end is Pi's ordinary persistence handoff. Keep a
   * bounded exact-ID latch across continuation/settlement callbacks so a late
   * terminal lifecycle event cannot resurrect a runtime row after that handoff.
   * Canonical branch ownership is the durable backstop used by snapshots. */
  private readonly canonicalToolResultHandoffs = new Set<string>();
  /** Latched declaration facts keyed by exact Pi tool call ID. Runtime-only;
   * never persisted to canonical Pi JSONL. */
  private readonly toolInvocationGroups = new Map<string, Pick<
    ToolProjectionMetadata,
    "toolSegmentId" | "groupId" | "groupIndex" | "groupCount" | "groupFinalized"
  >>();
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
  private readonly extensionActivityWatchers = new Map<string, {
    watcher: FSWatcher;
    timer: NodeJS.Timeout | undefined;
    asyncDir: string;
    readRetries: number;
    bindingRetries: number;
  }>();
  private readonly extensionActivityReadGenerations = new Map<string, number>();
  private readonly extensionArtifactWarnings = new Map<string, number>();
  /** Receipt persistence is runtime work: eviction and restart drain wait for
   * this bounded barrier rather than disposing the Pi manager underneath it. */
  private readonly pendingReceiptWrites = new Set<Promise<void>>();
  private readonly durableWrites = new Map<string, Promise<void>>();
  private readonly extensionReceiptWrites = new Map<string, Promise<void>>();
  private readonly extensionReceiptOwners = new Map<string, GatewayWorkHandle>();
  private extensionShutdownWork: GatewayWorkHandle | undefined;
  private extensionShutdownInFlight = false;
  private extensionShutdownRetryTimer: NodeJS.Timeout | undefined;
  /** Follow-up queue owners removed by Pi immediately before their agent_start. */
  private readonly dequeuedFollowUpOwners: string[] = [];
  private readonly unregisterExtensionExpiry: () => void;
  private readonly unregisterProcessExpiry: () => void;
  private readonly processActivities = new Map<string, SessionProcessActivity>();
  private readonly processIDsByToolCall = new Map<string, Set<string>>();
  private readonly pendingProcessRemovalsByToolCall = new Map<string, Set<string>>();
  private readonly validatedChildSessionPaths = new Map<string, string>();
  /** Exact process-scoped binding; a reused child session ref must never
   * overwrite the producer identity of another current or historical row. */
  private readonly childSessionBindings = new Map<string, { ref: string; producerId: string; sessionOwnerId?: string }>();
  private processRevision = 0;
  private processAsOf = new Date().toISOString();
  /** Bounded runtime timing enriches the mobile projection without changing Pi
   * JSONL. Historical entries without retained metadata use timestamp fallback. */
  private readonly toolMetadata = new Map<string, ToolProjectionMetadata>();
  private nextToolOrder = 0;
  private lastPublishedSummary: SessionSummaryUpdate | undefined;
  /** Disposable live activity overlays the canonical tail timestamp in catalog
   * summaries. It is never written into Pi JSONL; the registry may retain the
   * last published summary for revision continuity until Gateway restart. */
  private latestDashboardActivityAt: string | undefined;
  /** Stable for one continuous dashboard-active period. Live progress and
   * heartbeats advance latestDashboardActivityAt without moving the row. */
  private dashboardActiveSince: string | undefined;
  private summaryContentDirty = true;
  private cachedSummaryContent: {
    name?: string;
    updatedAt: string;
    messageCount: number;
    firstMessage: string;
  } | undefined;
  /** Snapshot-derived SDK scans are exact but need not repeat while the
   * RuntimeSlot revision is unchanged. A canonical event/rebind/branch change
   * increments revision before publication, naturally invalidating this cut. */
  private cachedSnapshotDerived: {
    revision: number;
    stats: ReturnType<AgentSession["getSessionStats"]>;
    latestCacheHitRate?: number;
  } | undefined;
  private lastTouchedAt = Date.now();
  private queueRevision = 0;
  private nextQueueOrdinal = 0;
  private queuedMessages: RuntimeQueuedMessage[] = [];
  private pendingQueueAdmission: PendingQueueAdmission | undefined;
  private pendingPrompt: PendingPromptState | undefined;
  /** Exact Pi message object claimed by the foreground pending prompt. */
  private pendingPromptMessage: AgentMessage | undefined;
  /** Canonical user messages produced by queued resource/plain invocations. */
  private readonly pendingInvocationUserMessages = new WeakMap<AgentMessage, {
    operationId: string;
    invocationId: string;
  }>();
  /** Exact custom messages observed at Pi's message boundary. Their producer
   * and delivery receipt is appended only after Pi persists that same object. */
  private readonly pendingContextMessages = new WeakMap<AgentMessage, {
    delivery: "stored" | "triggeredTurn";
    origin?: ExtensionToolOrigin;
  }>();
  private pendingManualCompaction: PendingManualCompaction | undefined;
  private compactionBaselineEntryId: string | undefined;
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
    this.unregisterProcessExpiry = dependencies.processActivityRecency.registerExpiryCallback((frame) => this.onProcessActivityExpiry(frame));
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
    return this.sessionManager.getSessionId();
  }

  get cwd(): string {
    return this.sessionManager.getCwd();
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
    return this.dependencies.workRegistry.hasSessionWork(this.id)
      || this.administrativeDrainBlockers().length > 0;
  }

  administrativeDrainBlockers(): RuntimeDrainBlockerFact[] {
    const facts: RuntimeDrainBlockerFact[] = [];
    for (const activity of this.extensionActivities.values()) {
      const state = activity.lifecycle?.state;
      if (state === "queued" || state === "running" || state === "paused") {
        facts.push({
          category: "detached-extension-run",
          key: activity.activityId ?? activity.toolCallId,
          admittedAt: activity.startedAt,
          state: "active",
        });
      }
    }
    const uiOwned = this.dependencies.workRegistry.facts().some((work) => work.sessionId === this.id
      && (work.kind === "prompt-preflight" || work.kind === "foreground-agent-operation"
        || work.kind === "extension-command-prompt-ui"));
    if (this.lifecycle.pendingUICount > 0 && !uiOwned) {
      facts.push({ category: "extension-command-prompt-ui", key: "unowned-extension-ui", state: "active" });
    }
    return facts.slice(0, 256);
  }

  /** Synchronous admission cutoff used in the restart RPC turn. */
  beginAdministrativeDrainCutoff(): void {
    this.lifecycle.beginDrain();
  }

  async prepareForAdministrativeDrain(): Promise<void> {
    // Accepted steering/follow-up work remains authoritative. The exact queue
    // tokens drain only when Pi consumes them or a client explicitly clears them.
    this.beginAdministrativeDrainCutoff();
  }

  private beginOperationWork(operationId: string, kind: GatewayWorkKind = "prompt-preflight"): GatewayWorkHandle {
    const existing = this.operationWork.get(operationId);
    if (existing) {
      existing.transition(kind);
      return existing;
    }
    const work = this.dependencies.workRegistry.begin({
      kind,
      sessionId: this.id,
      hostEpoch: this.ui.hostEpoch,
    });
    this.operationWork.set(operationId, work);
    return work;
  }

  private beginDerivedOperationWork(operationId: string, kind: GatewayWorkKind): GatewayWorkHandle {
    const existing = this.operationWork.get(operationId);
    if (existing) {
      existing.transition(kind);
      return existing;
    }
    const work = this.dependencies.workRegistry.beginDerived({
      kind,
      sessionId: this.id,
      hostEpoch: this.ui.hostEpoch,
    });
    this.operationWork.set(operationId, work);
    return work;
  }

  private settleOperationWork(operationId: string | undefined): void {
    if (!operationId) return;
    this.lifecycle.cancelPreflight(operationId);
    // PendingPrompt is a provisional projection, not independent ownership.
    // Once its exact operation settles it must not keep an idle composer row
    // alive merely because Pi omitted or replaced the expected user callback.
    if (this.pendingPrompt?.id === operationId) {
      this.pendingPrompt = undefined;
      this.pendingPromptMessage = undefined;
    }
    const work = this.operationWork.get(operationId);
    if (!work) return;
    this.operationWork.delete(operationId);
    work.settle();
  }

  private retainedOperationWorkIDs(): Set<string> {
    return new Set([
      this.activeOperationId,
      this.operation?.id,
      this.pendingPrompt?.id,
      this.pendingExtensionCommand?.id,
      this.pendingAssistantCompletion?.operationId,
      this.pendingQueueAdmission?.id,
      ...this.completionOwnershipQueue.map((item) => item.completion.operationId),
      ...this.completionWorkOwners.values(),
      ...this.queuedMessages.map((item) => item.id),
      ...this.dequeuedFollowUpOwners,
    ].filter((value): value is string => typeof value === "string"));
  }

  private administrativeRetainedOperationWorkIDs(): Set<string> {
    const retained = this.retainedOperationWorkIDs();
    // A provisional prompt cannot represent foreground work after both Pi and
    // the Gateway have reached an operation-free terminal phase.
    if (!this.hasActiveAgentRun
      && (this.phase === "idle" || this.phase === "interrupted")
      && this.activeOperationId === undefined
      && this.operation === undefined
      && this.pendingAssistantCompletion === undefined
      && this.pendingPrompt) {
      retained.delete(this.pendingPrompt.id);
    }
    return retained;
  }

  /** Foreground tokens without an exact runtime, queue, or settlement owner
   * are orphaned projections. Age alone never makes work suspect. */
  administrativeSuspectForegroundWorkTokens(): ReadonlySet<string> {
    // Pi's broad streaming state is authoritative even if a projection callback
    // is temporarily missing. Ambiguous live ownership must wait, never repair.
    if (this.hasActiveAgentRun) return new Set();
    const retained = this.administrativeRetainedOperationWorkIDs();
    return new Set([...this.operationWork.entries()].flatMap(([operationId, work]) =>
      retained.has(operationId) ? [] : [work.token]
    ));
  }

  private settleRetiredOperationWork(): void {
    const retained = this.retainedOperationWorkIDs();
    for (const operationId of [...this.operationWork.keys()]) {
      if (!retained.has(operationId)) this.settleOperationWork(operationId);
    }
  }

  /** Administrative drain repairs only proven-orphaned foreground ownership.
   * Its exact durable marker is removed before the process-local token; active,
   * queued, and terminal-receipt owners remain untouched without a deadline. */
  private async reconcileOrphanedForegroundWorkForDrain(): Promise<void> {
    // Never synthesize or transfer identity during repair. Once Pi settles, its
    // sequenced callback or the next reconciliation pass can prove an orphan.
    if (this.hasActiveAgentRun) return;
    const workFacts = new Map(this.dependencies.workRegistry.facts().map((fact) => [fact.token, fact]));
    const retained = this.administrativeRetainedOperationWorkIDs();
    const candidates = [...this.operationWork.entries()].filter(([operationId, work]) => {
      const fact = workFacts.get(work.token);
      return fact?.kind === "foreground-agent-operation" && !retained.has(operationId);
    });
    for (const [operationId, work] of candidates) {
      await this.clearMarkerOwnership(operationId, work);
      // A delayed exact callback may have restored ownership while marker I/O
      // yielded. Reassert its marker rather than retiring live work.
      if (this.administrativeRetainedOperationWorkIDs().has(operationId)) {
        await this.enqueueMarkerOwnership(operationId);
        continue;
      }
      this.settleOperationWork(operationId);
    }
  }

  private hasRuntimeWork(): boolean {
    return this.dependencies.workRegistry.hasSessionWork(this.id)
      // Detached nonterminal extension work remains the explicit compatibility
      // authority until the extension host offers direct registration tokens.
      || this.hasDetachedDashboardWork();
  }

  /** User-visible detached activity only. Durable receipt persistence and other
   * administrative work can keep operational drain busy but must not leave a
   * dashboard row stuck in the running phase. */
  private hasDetachedDashboardWork(): boolean {
    return [...this.extensionActivities.values()].some((activity) => activity.lifecycle?.state === "queued"
      || activity.lifecycle?.state === "running"
      || activity.lifecycle?.state === "paused");
  }

  /** AgentSession can start an extension-triggered continuation while an older
   * `agent_settled` callback is still unwinding. AgentSession's full streaming
   * lifecycle is the authoritative foreground owner in that overlap. */
  private get hasActiveAgentRun(): boolean {
    const session = this.runtime?.session;
    return session?.isStreaming === true || session?.state.isStreaming === true;
  }

  /** Pi 0.84.1 can clear isStreaming before its agent_settled choreography has
   * reached this runtime. Keep ordinary admission behind the existing Gateway
   * operation owner until the sequenced state transition is published. */
  private get isAgentAdmissionSettling(): boolean {
    // Compaction has its own Pi abort controller and cannot accept Agent input,
    // even when the SDK's broad streaming flag remains true. Wait until the
    // continuation or idle transition, then re-evaluate steer/follow-up.
    if (this.phase === "compacting") return true;
    if (this.hasActiveAgentRun) return false;
    return this.phase === "running"
      || this.phase === "retrying"
      || this.activeOperationId !== undefined
      || this.operation !== undefined
      || this.pendingAssistantCompletion !== undefined;
  }

  private waitForStateChange(): Promise<void> {
    return new Promise((resolve) => { this.stateChangeWaiters.add(resolve); });
  }

  private publishStateChange(): void {
    const waiters = [...this.stateChangeWaiters];
    this.stateChangeWaiters.clear();
    for (const resolve of waiters) resolve();
  }

  private get effectivePhase(): SessionPhase {
    if (this.hasActiveAgentRun && (this.phase === "idle" || this.phase === "interrupted")) return "running";
    return this.phase;
  }

  /** Dashboard activity includes detached extension work even after the
   * foreground Pi turn settles. Chat snapshots retain the narrower foreground
   * phase; only the catalog projection widens idle/interrupted to running. */
  private get dashboardPhase(): SessionPhase {
    const phase = this.effectivePhase;
    return (phase === "idle" || phase === "interrupted") && this.hasDetachedDashboardWork()
      ? "running"
      : phase;
  }

  private hasCurrentDashboardWork(): boolean {
    const phase = this.dashboardPhase;
    return phase === "running" || phase === "compacting" || phase === "retrying";
  }

  private noteDashboardActivity(at = new Date().toISOString()): void {
    const candidate = Date.parse(at);
    if (!Number.isFinite(candidate)) return;
    const current = this.latestDashboardActivityAt === undefined
      ? Number.NEGATIVE_INFINITY
      : Date.parse(this.latestDashboardActivityAt);
    if (!Number.isFinite(current) || candidate > current) this.latestDashboardActivityAt = at;
  }

  private currentDashboardActiveSince(): string | undefined {
    if (!this.hasCurrentDashboardWork()) {
      this.dashboardActiveSince = undefined;
      return undefined;
    }
    if (!this.dashboardActiveSince) {
      const operationStartedAt = this.operation?.startedAt;
      this.dashboardActiveSince = operationStartedAt && Number.isFinite(Date.parse(operationStartedAt))
        ? operationStartedAt
        : this.latestDashboardActivityAt ?? new Date().toISOString();
    }
    return this.dashboardActiveSince;
  }

  private ensureAgentProjection(): void {
    if (!this.hasActiveAgentRun) return;
    if (this.phase === "idle" || this.phase === "interrupted") this.phase = "running";
    this.activeOperationId ??= randomUUID();
    this.operation ??= { id: this.activeOperationId, kind: "prompt", startedAt: new Date().toISOString() };
    this.beginDerivedOperationWork(this.activeOperationId, "foreground-agent-operation");
    if (!this.activityHeartbeat) this.startActivityHeartbeat();
  }

  /** Lightweight dashboard projection. Catalog listing must not construct a
   * transcript-bearing session snapshot merely to read runtime activity. */
  get catalogPhase(): SessionPhase {
    return this.dashboardPhase;
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
                sessionTitle: () => this.notificationTitle(),
                ...(this.dependencies.machineId ? { machineId: this.dependencies.machineId } : {}),
                enqueue: (input) => notifications.enqueue(input),
              }),
            }],
          } : {}),
          extensionsOverride: (base) => attributeExtensions(base, {
            ...(notifications ? {
              askPresented: ({ toolCallId }) => notifications.askPresented(this.id, toolCallId, this.dependencies.machineId),
            } : {}),
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
    const previousId = this.sessionManager.getSessionId();
    const previousUnsubscribe = this.unsubscribe;
    if (this.hasBoundSession) this.rotateSemanticHost();
    this.hasBoundSession = true;
    const session = this.runtime.session;
    const nextManager = session.sessionManager;
    const nextId = nextManager.getSessionId();
    await session.bindExtensions({
      uiContext: this.extensionHost.context(),
      mode: "rpc",
      commandContextActions: this.commandActions(),
      abortHandler: () => void this.abort(),
      shutdownHandler: () => this.requestExtensionShutdown(),
      onError: (error) => {
        const context = currentInvocationContext();
        const invocationId = context?.invocationId;
        if (invocationId && this.pendingExtensionCommand?.invocationId === invocationId) {
          this.invocationFailures.set(invocationId, "extension-error");
        }
        this.emit("session.extensionError", safeJson({ error, ...(invocationId ? { invocationId } : {}) }));
      },
    });
    const nextUnsubscribe = session.subscribe((event) => this.onEvent(event));
    try {
      if (previousId !== nextId) {
        await this.hooks.rekey(
          previousId,
          nextId,
          this,
          this.rebindAttentionDisposition,
          () => {
            this.sessionManager = nextManager;
            this.clearExtensionActivityWatchers();
            this.extensionActivities.clear();
            this.extensionActivitySequences.clear();
            this.extensionRunOwnership.clear();
            this.clearProcessActivities();
          },
        );
      } else {
        this.sessionManager = nextManager;
      }
    } catch (error) {
      nextUnsubscribe();
      await this.restorePreviousRuntime(this.sessionManager);
      throw error;
    }
    previousUnsubscribe?.();
    this.unsubscribe = nextUnsubscribe;
    this.hydrateCanonicalExtensionActivities();
    this.revision += 1;
    this.publishSnapshot();
  }

  private async restorePreviousRuntime(previousManager: SessionManager): Promise<void> {
    await this.runtime.dispose().catch(() => {});
    this.runtime = await createAgentSessionRuntime(this.runtimeFactory(), {
      cwd: previousManager.getCwd(),
      agentDir: this.dependencies.agentDir,
      sessionManager: previousManager,
      sessionStartEvent: { type: "session_start", reason: "resume" },
    });
    this.runtime.setRebindSession(async () => this.bindSession());
    await this.bindSession();
  }

  private childSessionReferences(
    value: unknown,
    activity: ExtensionRunActivity,
    identityStrategy: ExtensionRunChildIdentityStrategy,
  ): Map<string, { ref: string; producerId: string; sessionOwnerId?: string }> {
    const references = new Map<string, { ref: string; producerId: string; sessionOwnerId?: string }>();
    const ambiguous = new Set<string>();
    if (!activity.runId) return references;
    const wrapper = value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : undefined;
    const root = wrapper?.details && typeof wrapper.details === "object" && !Array.isArray(wrapper.details)
      ? wrapper.details as Record<string, unknown> : wrapper;
    const declaredRun = [root?.runId, root?.asyncId]
      .find((item): item is string => typeof item === "string" && item.trim().length > 0)?.trim();
    // Exact producer run ownership is established before a child path can
    // enrich the already tool-owned activity. Generic nested records cannot
    // nominate arbitrary sessions.
    if (declaredRun !== activity.runId) return references;
    const visit = (candidate: unknown, depth: number, index: number, isChild: boolean): void => {
      if (depth > 4 || candidate === null || typeof candidate !== "object" || Array.isArray(candidate)) return;
      const record = candidate as Record<string, unknown>;
      const progress = record.progress && typeof record.progress === "object" && !Array.isArray(record.progress)
        ? record.progress as Record<string, unknown> : undefined;
      const childDepth = Math.max(0, depth - 1);
      const producerId = extensionRunChildProducerId(record, index, childDepth, identityStrategy);
      const recoverySessionOwner = identityStrategy === "piArtifact"
        ? (record as Record<PropertyKey, unknown>)[RECOVERY_SESSION_OWNER]
        : undefined;
      const sessionOwnerId = [recoverySessionOwner, record.runId, progress?.runId]
        .find((item): item is string => typeof item === "string" && item.trim().length > 0)?.trim();
      const rawLabel = [progress?.agent, record.agent]
        .find((item): item is string => typeof item === "string" && item.trim().length > 0)?.trim();
      const projectionID = producerId ?? `${rawLabel ?? `Child ${index + 1}`}:${index}`;
      const sessionFile = [record.sessionFile, progress?.sessionFile]
        .find((item): item is string => typeof item === "string" && item.trim().length > 0)?.trim();
      if (isChild && sessionFile && producerId !== activity.runId) {
        const admitted = this.validateChildSessionFile(sessionFile, activity.runId!, producerId, sessionOwnerId);
        if (admitted) {
          const evidence = {
            ref: admitted.ref,
            producerId: admitted.producerId,
            ...(admitted.sessionOwnerId ? { sessionOwnerId: admitted.sessionOwnerId } : {}),
          };
          const prior = references.get(projectionID);
          if (prior && (prior.ref !== evidence.ref || prior.producerId !== evidence.producerId
            || prior.sessionOwnerId !== evidence.sessionOwnerId)) {
            references.delete(projectionID);
            ambiguous.add(projectionID);
          } else if (!ambiguous.has(projectionID)) references.set(projectionID, evidence);
        }
      }
      for (const key of ["results", "steps", "children"] as const) {
        const nested = record[key];
        if (Array.isArray(nested)) nested.slice(0, 64).forEach((child, childIndex) => visit(child, depth + 1, childIndex, true));
      }
      if (Array.isArray(record.progress)) {
        record.progress.slice(0, 64).forEach((child, childIndex) => visit(child, depth + 1, childIndex, true));
      }
    };
    visit(root, 0, 0, false);
    return references;
  }

  private boundedSessionHeader(descriptor: number): {
    id: string;
    parentSession?: string;
  } | undefined {
    const maximum = 64 * 1_024;
    try {
      const bytes = Buffer.alloc(maximum + 1);
      const count = readSync(descriptor, bytes, 0, bytes.length, 0);
      const bounded = bytes.subarray(0, Math.min(count, maximum));
      const finalNewline = bounded.lastIndexOf(0x0a);
      if (finalNewline < 0) return undefined;
      const lines = bounded.subarray(0, finalNewline).toString("utf8").split("\n").filter(Boolean);
      if (lines.length === 0) return undefined;
      const header = JSON.parse(lines[0]!) as Record<string, unknown>;
      if (header.type !== "session" || typeof header.id !== "string" || !header.id.trim()) return undefined;
      const parentSession = typeof header.parentSession === "string" && header.parentSession.trim()
        ? header.parentSession.trim() : undefined;
      return {
        id: header.id,
        ...(parentSession ? { parentSession } : {}),
      };
    } catch { return undefined; }
  }

  private validateChildSessionFile(
    candidate: string,
    expectedRunId: string,
    declaredChildId?: string,
    declaredSessionOwnerId?: string,
  ): { ref: string; path: string; producerId: string; sessionOwnerId?: string } | undefined {
    if (!isAbsolute(candidate) || candidate.length > 4_096 || !expectedRunId || /[\\/\0]/u.test(expectedRunId)
      || declaredSessionOwnerId !== undefined
        && (Buffer.byteLength(declaredSessionOwnerId) > 256 || /[\\/\0]/u.test(declaredSessionOwnerId))) return undefined;
    let canonical: string;
    let identity: { dev: number; ino: number };
    try {
      const metadata = lstatSync(candidate);
      if (!metadata.isFile() || metadata.isSymbolicLink()) return undefined;
      identity = { dev: metadata.dev, ino: metadata.ino };
      canonical = realpathSync(candidate);
    } catch { return undefined; }
    const parentFile = this.sessionManager.getSessionFile();
    if (!parentFile) return undefined;
    let parentCanonical: string;
    try { parentCanonical = realpathSync(parentFile); } catch { return undefined; }
    const childRoot = join(dirname(parentCanonical), basename(parentCanonical, ".jsonl"));
    const ownedRelative = relative(childRoot, canonical);
    const pathParts = ownedRelative.split(sep);
    if (ownedRelative === "" || ownedRelative === ".." || ownedRelative.startsWith(`..${sep}`)
      || isAbsolute(ownedRelative)) return undefined;
    const forkContext = pathParts.length === 2 && pathParts[0] === "forks"
      && pathParts[1] !== ".jsonl" && pathParts[1]!.endsWith(".jsonl");
    const freshContext = pathParts.length === 3 && pathParts[0] !== "forks"
      && pathParts[2] === "session.jsonl" && /^run-\d+$/u.test(pathParts[1]!);
    if (!forkContext && !freshContext) return undefined;
    // A fresh path may be reserved by the root run (ordinary single/parallel/
    // chain) or by a detached workflow child. Keep that filesystem owner
    // separate from the stable child producer identity used by process rows.
    // Fork paths encode neither, so their exact artifact child identity remains
    // mandatory; filenames and transcript presentation never become evidence.
    const pathOwnerId = freshContext ? pathParts[0] : undefined;
    if (freshContext && pathOwnerId !== expectedRunId && pathOwnerId !== declaredSessionOwnerId) return undefined;
    // A path proves containment, never child ownership. Every admitted context
    // also needs a distinct producer identity from the trusted lifecycle shape.
    if (!declaredChildId) return undefined;
    const producerId = declaredChildId;
    if (Buffer.byteLength(producerId) > 256 || /[\\/\0]/u.test(producerId)) return undefined;
    let descriptor: number | undefined;
    try {
      descriptor = openSync(canonical, "r");
      const opened = fstatSync(descriptor);
      if (!opened.isFile() || opened.dev !== identity.dev || opened.ino !== identity.ino) return undefined;
      const header = this.boundedSessionHeader(descriptor);
      if (!header) return undefined;
      if (header.parentSession) {
        let headerParent: string;
        try { headerParent = realpathSync(header.parentSession); } catch { return undefined; }
        if (headerParent !== parentCanonical) return undefined;
      } else if (forkContext) {
        return undefined;
      }
      const after = lstatSync(canonical);
      if (!after.isFile() || after.isSymbolicLink() || after.dev !== opened.dev || after.ino !== opened.ino) return undefined;
      const ref = header.id;
      if (!ref || ref === this.id || Buffer.byteLength(ref) > 256) return undefined;
      const bindingKey = `${ref}\0${producerId}`;
      this.validatedChildSessionPaths.delete(bindingKey);
      this.validatedChildSessionPaths.set(bindingKey, canonical);
      while (this.validatedChildSessionPaths.size > MAX_VALIDATED_CHILD_SESSION_PATHS) {
        const oldest = this.validatedChildSessionPaths.keys().next().value;
        if (oldest === undefined) break;
        this.validatedChildSessionPaths.delete(oldest);
      }
      return { ref, path: canonical, producerId, ...(pathOwnerId ? { sessionOwnerId: pathOwnerId } : {}) };
    } catch { return undefined; }
    finally { if (descriptor !== undefined) closeSync(descriptor); }
  }

  private attachChildSessionReferences(
    activity: ExtensionRunActivity,
    value: unknown,
    identityStrategy: ExtensionRunChildIdentityStrategy = "declared",
  ): ExtensionRunActivity {
    const references = this.childSessionReferences(value, activity, identityStrategy);
    if (references.size === 0) return activity;
    const attach = (children: ExtensionRunActivity["children"]): ExtensionRunActivity["children"] => children.map((child) => {
      const evidence = references.get(child.id);
      return {
        ...child,
        ...(evidence ? {
          id: evidence.producerId,
          producerId: evidence.producerId,
          childSessionRef: evidence.ref,
          ...(evidence.sessionOwnerId ? { sessionOwnerId: evidence.sessionOwnerId } : {}),
        } : {}),
        ...(child.children ? { children: attach(child.children) } : {}),
      };
    });
    return { ...activity, children: attach(activity.children) };
  }

  /** Rebuild terminal extension cards from canonical receipts before backfilling
   * tool results. This preserves the canonical terminalAt across a restart;
   * receipts are authoritative when the disposable result projection is rebuilt. */
  private hydrateCanonicalExtensionActivities(): void {
    const branch = this.sessionManager.getBranch();
    const receipts = extensionActivityReceipts(branch, this.id);
    const receiptToolCallIDs = new Set(receipts.map(({ receipt }) => receipt.toolCallId));
    for (const { receipt } of receipts) {
      const activity = extensionReceiptActivity(receipt);
      const visibility = this.upsertExtensionActivity(activity).visibility;
      if (visibility === "current" || visibility === "recent") {
        this.extensionActivities.set(activity.toolCallId, activity);
      }
    }
    for (const entry of branch) {
      if (entry.type !== "message" || entry.message.role !== "toolResult"
        || receiptToolCallIDs.has(entry.message.toolCallId)) continue;
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

  private clearProcessActivities(): void {
    for (const processId of this.processActivities.keys()) this.dependencies.processActivityRecency.remove(processId);
    this.processActivities.clear();
    this.processIDsByToolCall.clear();
    this.pendingProcessRemovalsByToolCall.clear();
    this.validatedChildSessionPaths.clear();
    this.childSessionBindings.clear();
    this.processRevision += 1;
    this.processAsOf = new Date().toISOString();
  }

  private replaceProcessesForToolCall(toolCallId: string, projected: readonly SessionProcessActivity[]): void {
    const previousIDs = this.processIDsByToolCall.get(toolCallId) ?? new Set<string>();
    const projectedIDs = new Set(projected.map((activity) => activity.processId));
    const installedNextIDs = new Set<string>();
    const removed = new Set(this.pendingProcessRemovalsByToolCall.get(toolCallId) ?? []);
    for (const processId of previousIDs) {
      if (projectedIDs.has(processId)) continue;
      if (this.processActivities.delete(processId)) removed.add(processId);
      this.dependencies.processActivityRecency.remove(processId);
      this.processRevision += 1;
    }
    for (const projectedCandidate of projected) {
      const previous = this.processActivities.get(projectedCandidate.processId);
      const previousTerminal = previous && ["completed", "failed", "stopped", "rejected", "interrupted"].includes(previous.lifecycle.state);
      const candidateTerminal = ["completed", "failed", "stopped", "rejected", "interrupted"].includes(projectedCandidate.lifecycle.state);
      // Repeated parent artifact frames must not move a child's already
      // admitted terminal clock. Canonical command settlement is reconciled
      // separately with an explicitly newer sequence.
      const candidate = projectedCandidate.kind === "subagent" && previousTerminal && candidateTerminal
        ? { ...projectedCandidate, lifecycle: {
            ...projectedCandidate.lifecycle,
            ...(previous!.lifecycle.terminalAt ? { terminalAt: previous!.lifecycle.terminalAt } : {}),
            ...(previous!.lifecycle.recentUntil ? { recentUntil: previous!.lifecycle.recentUntil } : {}),
          } }
        : projectedCandidate;
      const admitted = this.dependencies.processActivityRecency.upsert(candidate);
      if (!admitted.accepted) {
        if (this.processActivities.has(candidate.processId)) installedNextIDs.add(candidate.processId);
        continue;
      }
      if (admitted.activity.visibility !== "active" && admitted.activity.visibility !== "recent") {
        if (this.processActivities.delete(candidate.processId)) removed.add(candidate.processId);
        continue;
      }
      this.processActivities.set(candidate.processId, admitted.activity);
      installedNextIDs.add(candidate.processId);
      this.processRevision += 1;
    }
    if (installedNextIDs.size > 0) this.processIDsByToolCall.set(toolCallId, installedNextIDs);
    else this.processIDsByToolCall.delete(toolCallId);
    if (removed.size > 0) this.pendingProcessRemovalsByToolCall.set(toolCallId, removed);
    this.processAsOf = new Date().toISOString();
  }

  private childSessionBindingFromActivity(
    processId: string,
    activity: ExtensionRunActivity,
  ): { ref: string; producerId: string; sessionOwnerId?: string } | undefined {
    const process = subagentProcessesFromActivity(this.id, activity)
      .find((candidate) => candidate.processId === processId);
    if (!process?.childSessionRef) return undefined;
    const candidates = new Map<string, { ref: string; producerId: string; sessionOwnerId?: string }>();
    const visit = (children: readonly ExtensionRunChild[]): void => {
      for (const child of children) {
        const childSessionRef = child.childSessionRef;
        if (childSessionRef && childSessionRef === process.childSessionRef && child.producerId) {
          const candidate = {
            ref: childSessionRef,
            producerId: child.producerId,
            ...(child.sessionOwnerId ? { sessionOwnerId: child.sessionOwnerId } : {}),
          };
          candidates.set(`${candidate.producerId}\0${candidate.sessionOwnerId ?? ""}`, candidate);
        }
        if (child.children) visit(child.children);
      }
    };
    visit(activity.children);
    return candidates.size === 1 ? [...candidates.values()][0] : undefined;
  }

  private canonicalChildSessionBinding(processId: string): { ref: string; producerId: string; sessionOwnerId?: string } | undefined {
    let admitted: { ref: string; producerId: string; sessionOwnerId?: string } | undefined;
    for (const { receipt } of extensionActivityReceipts(this.sessionManager.getBranch(), this.id)) {
      const candidate = this.childSessionBindingFromActivity(processId, extensionReceiptActivity(receipt));
      if (!candidate) continue;
      if (admitted && (admitted.ref !== candidate.ref || admitted.producerId !== candidate.producerId
        || admitted.sessionOwnerId !== candidate.sessionOwnerId)) return undefined;
      admitted = candidate;
    }
    return admitted;
  }

  private syncSubagentProcesses(activity: ExtensionRunActivity): void {
    const projected = subagentProcessesFromActivity(this.id, activity);
    for (const processId of this.processIDsByToolCall.get(activity.toolCallId) ?? []) {
      this.childSessionBindings.delete(processId);
    }
    this.replaceProcessesForToolCall(activity.toolCallId, projected);
    for (const process of projected) {
      if (!this.processActivities.has(process.processId)) continue;
      const binding = this.childSessionBindingFromActivity(process.processId, activity);
      if (binding) this.childSessionBindings.set(process.processId, binding);
    }
  }

  private currentProcessProjection(): { activities: SessionProcessActivity[]; overview: SessionProcessOverview } {
    const visible = [...this.processActivities.values()]
      .map((activity) => this.dependencies.processActivityRecency.wire(activity))
      .filter((activity) => activity.visibility === "active" || activity.visibility === "recent");
    const bounded = boundProcessActivities(visible);
    const omissions = bounded.omittedCount > 0 ? {
      count: bounded.omittedCount,
      bytes: bounded.omittedBytes,
      reason: bounded.hitCount && bounded.hitBytes ? "countAndBytes" as const : bounded.hitCount ? "count" as const : "bytes" as const,
    } : undefined;
    return {
      activities: bounded.activities,
      overview: processOverview(visible, this.processRevision, this.processAsOf, omissions),
    };
  }

  private publishProcessDelta(activity: SessionProcessActivity | undefined, removedProcessIds?: string[]): void {
    if (activity) {
      const installed = this.processActivities.get(activity.processId);
      if (!installed) return;
      const current = this.dependencies.processActivityRecency.wire(installed);
      if (current.visibility !== "active" && current.visibility !== "recent") return;
      activity = current;
    }
    if (!activity && (!removedProcessIds || removedProcessIds.length === 0)) return;
    this.emit("session.processActivity", safeJson({
      ...(activity ? { activity } : {}),
      ...(removedProcessIds && removedProcessIds.length > 0 ? { removedProcessIds } : {}),
      processRevision: this.processRevision,
      processAsOf: this.processAsOf,
      overview: this.currentProcessProjection().overview,
    }));
  }

  private publishProcessesForToolCall(toolCallId: string): void {
    const removals = [...(this.pendingProcessRemovalsByToolCall.get(toolCallId) ?? [])].sort();
    this.pendingProcessRemovalsByToolCall.delete(toolCallId);
    let emitted = false;
    for (const processId of this.processIDsByToolCall.get(toolCallId) ?? []) {
      const activity = this.processActivities.get(processId);
      if (!activity) continue;
      this.publishProcessDelta(activity, emitted ? undefined : removals);
      emitted = true;
    }
    if (!emitted && removals.length > 0) this.publishProcessDelta(undefined, removals);
  }

  private upsertExtensionActivity(activity: ExtensionRunActivity): ActivityVisibility {
    const visibility = this.dependencies.extensionActivityRecency.upsert(activity);
    if (visibility.accepted) {
      this.liveActivityRevision += 1;
      this.extensionActivityAsOf = new Date().toISOString();
      this.syncSubagentProcesses(activity);
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
    if (!this.extensionShutdownWork) {
      try {
        this.extensionShutdownWork = this.dependencies.workRegistry.beginDerived({
          kind: "extension-command-prompt-ui",
          sessionId: this.id,
          hostEpoch: this.ui.hostEpoch,
        });
      } catch (error) {
        this.emit("session.extensionError", safeJson(error));
        return;
      }
    }
    this.lifecycle.requestShutdown();
    this.revision += 1;
    this.ui.context().notify("Extension requested a graceful session close", "info");
    this.maybePerformExtensionShutdown();
  }

  private maybePerformExtensionShutdown(): void {
    if (!this.lifecycle.isShutdownRequested || this.lifecycle.hasPendingCommands || this.lifecycle.hasPendingPrompts
      || this.extensionShutdownInFlight || this.extensionShutdownRetryTimer || this.shuttingDown || this.disposed) return;
    this.extensionShutdownInFlight = true;
    void this.runtime.session.waitForIdle().then(async () => {
      await this.waitForReceiptWrites();
      return this.lane.run(async () => {
      if (!this.lifecycle.isShutdownRequested || this.lifecycle.hasPendingCommands || this.lifecycle.hasPendingPrompts || this.disposed) return;
      this.shuttingDown = true;
      const closedID = this.id;
      const hostEpoch = this.ui.hostEpoch;
      await this.disposeRuntime();
      await this.retryDurableWrite("marker:clear:all", () => this.dependencies.markers.clear(closedID));
      this.phase = "idle";
      this.operation = undefined;
      this.pendingExtensionCommand = undefined;
      this.retry = undefined;
      this.publishSummary();
      this.emit("session.closed", { reason: "extension_shutdown", hostEpoch });
      this.hooks.closed?.(closedID, this);
      this.extensionShutdownWork?.settle();
      this.extensionShutdownWork = undefined;
      });
    }).catch((error) => {
      this.shuttingDown = false;
      this.emit("session.extensionError", safeJson({ message: error instanceof Error ? error.message : String(error) }));
      if (!this.disposed && !this.extensionShutdownRetryTimer) {
        this.extensionShutdownRetryTimer = setTimeout(() => {
          this.extensionShutdownRetryTimer = undefined;
          this.maybePerformExtensionShutdown();
        }, 1_000);
        this.extensionShutdownRetryTimer.unref();
      }
    }).finally(() => {
      this.extensionShutdownInFlight = false;
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
      this.toolLabels(),
      undefined,
      this.activeOperationId ? toolSegmentId(this.activeOperationId) : undefined,
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
      this.toolLabels(),
      undefined,
      this.activeOperationId ? toolSegmentId(this.activeOperationId) : undefined,
    );
    if (!projected || projected.kind !== "message") return;
    this.finalizedStreamPresentationId = this.streamPresentationId;
    for (const part of projected.content) {
      if (part.type !== "toolCall" || !part.groupFinalized || !part.groupId
        || part.groupIndex === undefined || part.groupCount === undefined) continue;
      this.toolInvocationGroups.set(part.toolCallId, {
        ...(part.toolSegmentId ? { toolSegmentId: part.toolSegmentId } : {}),
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

  private rememberPresentationID(canonicalID: string, presentationID: string): void {
    if (!this.presentationIDs.has(canonicalID)) this.presentationIDOrder.push(canonicalID);
    this.presentationIDs.set(canonicalID, presentationID);
    const excess = this.presentationIDOrder.length - MAX_PRESENTATION_IDENTITY_BINDINGS;
    if (excess <= 0) return;
    for (const id of this.presentationIDOrder.slice(0, excess)) this.presentationIDs.delete(id);
    this.presentationIDOrder.splice(0, excess);
  }

  private bindCanonicalPresentation(message: AgentMessage): void {
    if (message.role !== "assistant") return;
    const presentationID = this.streamPresentationId;
    const binding = {
      ...(this.activeOperationId ? { operationId: this.activeOperationId } : {}),
      ownsPromptOperation: this.operation?.kind === "prompt",
    };
    const mayComplete = message.stopReason === "stop" || message.stopReason === "length";
    if (mayComplete && binding.ownsPromptOperation) this.pendingAssistantBindings.set(message, binding);
    // Pi notifies listeners before synchronously appending the finalized
    // message. Mutable operation state may advance before this microtask; the
    // callback-turn binding above remains the exact owner of this completion.
    queueMicrotask(() => {
      try {
        const canonicalID = this.runtime.session.sessionManager.getLeafId();
        const candidate = canonicalID
          ? this.runtime.session.sessionManager.getEntry(canonicalID)
          : undefined;
        if (candidate?.type !== "message"
          || candidate.message.role !== "assistant"
          || candidate.message !== message) return;
        this.canonicalizedStreamingMessages.add(message);
        if (presentationID) this.rememberPresentationID(candidate.id, presentationID);
        const completion = successfulAssistantCompletion(candidate);
        if (completion && binding.ownsPromptOperation) {
          const item = this.recordCompletionOwnership({
            ...completion,
            ...(binding.operationId ? { operationId: binding.operationId } : {}),
          });
          this.pendingAssistantCompletion = item.completion;
          // Pi has synchronously appended the canonical entry. Its exact durable
          // stamp has started; truthful agent settlement still gates projection.
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
      } finally {
        this.pendingAssistantBindings.delete(message);
      }
    });
  }

  private notificationTitle(): string {
    // agent_settled extension handlers run before RuntimeSlot's deferred summary
    // projection necessarily catches up. Read the canonical active branch here
    // so a new session's first completion cannot be titled "New session".
    const rawName = this.sessionManager.getSessionName()?.trim();
    const firstUser = this.sessionManager.getBranch().find((entry) => entry.type === "message"
      && entry.message.role === "user");
    const firstMessage = firstUser?.type === "message" && firstUser.message.role === "user"
      ? (typeof firstUser.message.content === "string"
        ? firstUser.message.content
        : firstUser.message.content.flatMap((part) => part.type === "text" ? [part.text] : []).join(""))
      : "";
    const title = rawName || firstMessage.trim() || "New session";
    return boundedSummaryText([...title].slice(0, 80).join(""), 256);
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
    const canonical = this.cachedSummaryContent;
    const canonicalTime = Date.parse(canonical.updatedAt);
    const liveTime = this.latestDashboardActivityAt === undefined
      ? Number.NEGATIVE_INFINITY
      : Date.parse(this.latestDashboardActivityAt);
    const updatedAt = Number.isFinite(liveTime) && (!Number.isFinite(canonicalTime) || liveTime > canonicalTime)
      ? this.latestDashboardActivityAt!
      : canonical.updatedAt;
    const activeSince = this.currentDashboardActiveSince();
    return {
      sessionId: this.id,
      summaryRevision: 0,
      phase: this.dashboardPhase,
      ...canonical,
      updatedAt,
      ...(activeSince ? { activeSince } : {}),
    };
  }

  private trackOwnershipWrite(
    startWrite: () => Promise<void>,
    existingOwner?: GatewayWorkHandle,
  ): Promise<void> {
    const derived = existingOwner === undefined;
    const work = existingOwner ?? this.dependencies.workRegistry.beginDerived({
      kind: "terminal-receipt-persistence",
      sessionId: this.id,
      hostEpoch: this.ui.hostEpoch,
    });
    work.progress();
    let write: Promise<void>;
    try {
      write = startWrite();
    } catch (error) {
      if (derived) work.settle();
      throw error;
    }
    this.pendingReceiptWrites.add(write);
    void write.finally(() => {
      this.pendingReceiptWrites.delete(write);
      if (derived) work.settle();
    }).catch(() => {});
    return write;
  }

  private retryDurableWrite(key: string, operation: () => Promise<void>): Promise<void> {
    const existing = this.durableWrites.get(key);
    if (existing) return existing;
    const write = (async () => {
      let attempt = 0;
      for (;;) {
        try {
          await operation();
          return;
        } catch (error) {
          // One operation can never own two canonical completions. Retrying
          // that conflict would hold session.open behind an impossible claim;
          // ordinary storage failures retain the existing durable retry.
          if (error instanceof RunMarkerCompletionConflictError) throw error;
          attempt += 1;
          if (attempt === 1 || attempt % 60 === 0) {
            this.emit("session.operationFailed", safeJson({ message: "Canonical ownership persistence is retrying" }));
          }
          await new Promise((resolve) => {
            const timer = setTimeout(resolve, Math.min(1_000, 25 * attempt));
            timer.unref();
          });
        }
      }
    })();
    this.durableWrites.set(key, write);
    void write.finally(() => {
      if (this.durableWrites.get(key) === write) this.durableWrites.delete(key);
    }).catch(() => {});
    return write;
  }

  private persistCanonicalCustomEntry(
    customType: string,
    data: JsonValue,
    identity: string,
    owner?: GatewayWorkHandle,
  ): Promise<void> {
    return this.trackOwnershipWrite(
      () => this.retryDurableWrite(`canonical:${customType}:${identity}`, async () => {
        const exists = this.sessionManager.getBranch().some((entry) => {
          if (entry.type !== "custom" || entry.customType !== customType) return false;
          const value = entry.data as { receiptId?: unknown; targetEntryId?: unknown };
          return value?.receiptId === identity || value?.targetEntryId === identity;
        });
        if (!exists) this.sessionManager.appendCustomEntry(customType, data);
      }),
      owner,
    );
  }

  private persistInvocationReceipt(receipt: ReturnType<typeof makeInvocationReceipt>, owner?: GatewayWorkHandle): Promise<void> {
    return this.persistCanonicalCustomEntry(INVOCATION_RECEIPT_TYPE, receiptJSON(receipt), receipt.receiptId, owner);
  }

  private invocationForOperation(operationId: string | undefined): InvocationProjection | undefined {
    if (!operationId) return undefined;
    const live = [...this.invocations.values()].find(
      invocation => invocation.operationId === operationId,
    );
    if (live) return live;
    const canonical = invocationProjection(invocationReceipts(
      this.sessionManager.getBranch(),
      this.id,
    )).find(invocation => invocation.operationId === operationId);
    if (canonical) this.invocations.set(canonical.invocationId, canonical);
    return canonical;
  }

  private async terminalizeInvocation(
    operationId: string | undefined,
    lifecycle: "completed" | "failed" | "interrupted" | "outcomeUnknown",
    errorCode?: string,
    owner?: GatewayWorkHandle,
  ): Promise<void> {
    const invocation = this.invocationForOperation(operationId);
    if (!invocation || ["completed", "failed", "interrupted", "outcomeUnknown"].includes(invocation.lifecycle)) return;
    await this.persistInvocationReceipt(makeInvocationReceipt({
      version: 1,
      receiptId: `terminal:${invocation.invocationId}`,
      receiptKind: "terminal",
      invocationId: invocation.invocationId,
      operationId: invocation.operationId,
      sessionId: this.id,
      source: invocation.source,
      ...(invocation.name ? { name: invocation.name } : {}),
      lifecycle,
      ...(errorCode ? { errorCode } : {}),
      origin: invocation.origin,
      sequence: this.revision + 1,
      createdAt: new Date().toISOString(),
    }), owner ?? this.operationWork.get(invocation.operationId));
    this.invocations.delete(invocation.invocationId);
  }

  private enqueueMarkerOwnership(operationId: string): Promise<void> {
    // An existing operation token already owns this marker write. Avoid spending
    // derived capacity for a second representation of the same accepted work.
    return this.trackOwnershipWrite(
      () => this.retryDurableWrite(`marker:mark:${operationId}`, () => this.dependencies.markers.mark(this.id, operationId)),
      this.operationWork.get(operationId),
    );
  }

  private clearMarkerOwnership(operationId?: string, existingOwner?: GatewayWorkHandle): Promise<void> {
    const key = operationId ?? "all";
    return this.trackOwnershipWrite(
      () => this.retryDurableWrite(`marker:clear:${key}`, () => this.dependencies.markers.clear(this.id, operationId)),
      existingOwner ?? (operationId ? this.operationWork.get(operationId) : undefined),
    );
  }

  private startCompletionStamp(item: CompletionOwnershipItem): Promise<void> {
    if (item.stamp) return item.stamp;
    const { completion } = item;
    if (!completion.operationId) return Promise.resolve();
    const stamp = this.trackOwnershipWrite(() => this.retryDurableWrite(
      `marker:completion:${completion.operationId}:${completion.id}`,
      () => this.dependencies.markers.reassertAssistantCompletion(
        this.id,
        completion.operationId!,
        completion.id,
        completion.completedAt,
      ),
    ), this.operationWork.get(completion.operationId) ?? item.fallbackWork);
    item.stamp = stamp;
    void stamp.catch(() => {
      if (item.stamp === stamp) item.stamp = undefined;
    });
    return stamp;
  }

  private recordCompletionOwnership(completion: CanonicalAssistantCompletion): CompletionOwnershipItem {
    let item = this.completionOwnershipQueue.find((candidate) => candidate.completion.id === completion.id);
    if (item) {
      const existingOperationId = item.completion.operationId;
      // The first callback-turn binding is immutable. A later settlement view
      // may fill a missing owner, but mutable runtime state cannot replace one.
      if (!existingOperationId && completion.operationId) {
        item.completion = { ...item.completion, operationId: completion.operationId };
      }
    } else {
      const operationId = completion.operationId ?? this.completionWorkOwners.get(completion.id);
      const exactOwner = operationId ? this.operationWork.get(operationId) : undefined;
      item = {
        completion: operationId && !completion.operationId ? { ...completion, operationId } : completion,
        stamp: undefined,
        ...(exactOwner ? {} : {
          fallbackWork: this.dependencies.workRegistry.beginDerived({
            kind: "terminal-receipt-persistence",
            sessionId: this.id,
            hostEpoch: this.ui.hostEpoch,
          }),
        }),
      };
      this.completionOwnershipQueue.push(item);
    }
    void this.startCompletionStamp(item).catch(() => {});
    return item;
  }

  private beginAttentionSettlement(completion: CanonicalAssistantCompletion): Promise<void> {
    this.recordCompletionOwnership(completion);
    return this.drainCompletionOwnership();
  }

  private drainCompletionOwnership(): Promise<void> {
    if (this.attentionBarrier) return this.attentionBarrier;
    const operation = (async () => {
      while (this.completionOwnershipQueue.length > 0) {
        const item = this.completionOwnershipQueue[0]!;
        await this.startCompletionStamp(item);
        await this.settleAssistantCompletion(item);
        this.completionOwnershipQueue.shift();
        item.fallbackWork?.settle();
      }
    })().finally(() => {
      this.pendingReceiptWrites.delete(operation);
      if (this.attentionBarrier === operation) this.attentionBarrier = undefined;
      this.settleRetiredOperationWork();
    });
    this.attentionBarrier = operation;
    this.pendingReceiptWrites.add(operation);
    void operation.catch(() => {});
    return operation;
  }

  private async settleAssistantCompletion(item: CompletionOwnershipItem): Promise<void> {
    const { completion } = item;
    try {
      let lastError: unknown;
      for (let attempt = 0; attempt < 3; attempt += 1) {
        try {
          await this.hooks.assistantResponseCompleted(this.id, completion, false);
          lastError = undefined;
          break;
        } catch (error) {
          lastError = error;
        }
      }
      if (lastError !== undefined) throw lastError;
      await this.terminalizeInvocation(
        completion.operationId,
        "completed",
        undefined,
        item.fallbackWork,
      );
      if (!this.pendingManualCompaction) {
        await this.clearMarkerOwnership(completion.operationId, item.fallbackWork);
      }
      const completionWorkOwner = completion.operationId ?? this.completionWorkOwners.get(completion.id);
      this.settleOperationWork(completionWorkOwner);
      this.completionWorkOwners.delete(completion.id);
      if (this.pendingAssistantCompletion?.id === completion.id) this.pendingAssistantCompletion = undefined;
      // A continuation may already own the agent while this older durable write
      // unwinds. Settlement retires only its exact completion; the newer run
      // remains operationally running and owns final idle transition.
      if (this.hasActiveAgentRun) {
        this.ensureAgentProjection();
        this.publishSnapshot();
        return;
      }
      if (this.pendingManualCompaction) {
        // The already-accepted compaction inherits the run marker. Start it only
        // after the preceding response's attention fact is durable.
        this.phase = "idle";
        this.revision += 1;
        this.publishSnapshot();
        this.startPendingManualCompaction();
        return;
      }
      this.hooks.settled(this.id);
      this.phase = "idle";
      this.revision += 1;
      this.publishSnapshot();
    } catch (error) {
      // The failed exact completion stays at the ownership-lane head and retains
      // its durable marker. Reconciliation retries it before any continuation
      // marker or later completion can advance.
      this.phase = "interrupted";
      this.revision += 1;
      this.publishSnapshot();
      throw error;
    }
  }

  /** Join live settlement and reconcile bounded canonical evidence before open. */
  async reconcileAttention(): Promise<void> {
    if (this.attentionBarrier) {
      try {
        await this.attentionBarrier;
      } catch (error) {
        // A failed queue head remains retryable below; only an unowned barrier
        // failure is terminal to reconciliation.
        if (this.completionOwnershipQueue.length === 0) throw error;
      }
    }
    if (this.completionOwnershipQueue.length > 0) {
      await this.drainCompletionOwnership();
      return;
    }
    if (this.pendingAssistantCompletion) {
      await this.beginAttentionSettlement(this.pendingAssistantCompletion);
      return;
    }
    const markers = await this.dependencies.markers.evidenceFor(this.id);
    for (const marker of markers) {
      const completion = completionOwnedByMarker(this.sessionManager, marker);
      if (!completion) continue;
      await this.hooks.assistantResponseCompleted(this.id, completion, true);
      await this.clearMarkerOwnership(marker.operationId);
    }
  }

  private onEvent(event: AgentSessionEvent): void {
    this.revision += 1;
    this.touch();
    this.noteDashboardActivity(event.type === "entry_appended"
      ? event.entry.timestamp
      : new Date().toISOString());
    switch (event.type) {
      case "agent_start": {
        const continuationFromSettlement = this.pendingAssistantCompletion !== undefined
          || this.pendingAssistantBindings.size > 0;
        const dequeuedOwner = this.dequeuedFollowUpOwners[0];
        const queuedOwner = dequeuedOwner
          ?? this.queuedMessages.find((item) => item.behavior === "followUp")?.id;
        const preflightOwner = this.pendingExtensionCommand?.id
          ?? queuedOwner
          ?? this.activeOperationId;
        const requiresDistinctAgentOwner = queuedOwner === undefined
          && (continuationFromSettlement || this.pendingExtensionCommand !== undefined);
        if (continuationFromSettlement) {
          if (this.pendingAssistantCompletion) {
            if (!this.pendingAssistantCompletion.operationId && this.activeOperationId) {
              this.pendingAssistantCompletion = { ...this.pendingAssistantCompletion, operationId: this.activeOperationId };
            }
            if (this.activeOperationId) this.completionWorkOwners.set(this.pendingAssistantCompletion.id, this.activeOperationId);
            // Pi may start an extension continuation before the older settlement
            // callback unwinds. Preserve and immediately commit the prior exact
            // completion, then give the continuation a distinct marker owner so
            // cleanup from the older settlement cannot erase the newer run.
            // Attention is ordered durable presentation state, not authorization
            // to continue already-accepted canonical agent work. A failed queue
            // head remains marked/interrupted and blocks later attention commits,
            // while the continuation may finish and stamp its own completion for
            // ordered restart recovery. Aborting here would silently discard that
            // accepted continuation and strand its durable ownership test.
            void this.beginAttentionSettlement(this.pendingAssistantCompletion).catch(() => {});
          }
          // `message_end` may still be waiting for Pi's canonical append. Its
          // callback-turn binding owns the preceding operation even before a
          // completion object exists, so the new run must rotate now.
          this.activeOperationId = undefined;
          this.operation = undefined;
        }
        if (!this.lifecycle.admitAgentStartDuringDrain(preflightOwner)) {
          const rejectedOperationId = preflightOwner;
          if (dequeuedOwner && rejectedOperationId === dequeuedOwner) this.dequeuedFollowUpOwners.shift();
          this.phase = "interrupted";
          this.operation = undefined;
          this.activeOperationId = undefined;
          if (this.pendingExtensionCommand?.id === rejectedOperationId) this.pendingExtensionCommand = undefined;
          this.settleOperationWork(rejectedOperationId);
          this.emit("session.operationFailed", {
            message: "Extension continuation was rejected after the administrative drain cutoff",
          });
          void this.runtime.session.abort();
          this.publishSnapshot();
          break;
        }
        if (dequeuedOwner && preflightOwner === dequeuedOwner) this.dequeuedFollowUpOwners.shift();
        if (queuedOwner && preflightOwner === queuedOwner && this.activeOperationId !== queuedOwner) {
          this.activeOperationId = undefined;
          this.operation = undefined;
        }
        this.phase = "running";
        this.toolExecutions.clear();
        this.toolInvocationGroups.clear();
        this.toolStartedAtMonotonicMs.clear();
        this.nextToolOrder = 0;
        this.activeOperationId ??= requiresDistinctAgentOwner ? randomUUID() : (preflightOwner ?? randomUUID());
        const activeInvocation = this.invocationForOperation(this.activeOperationId);
        this.operation ??= {
          id: this.activeOperationId,
          kind: "prompt",
          startedAt: new Date().toISOString(),
          ...(activeInvocation ? { invocationId: activeInvocation.invocationId } : {}),
        };
        this.beginDerivedOperationWork(this.activeOperationId, "foreground-agent-operation");
        void this.enqueueMarkerOwnership(this.activeOperationId)
          .catch(() => this.runtime.session.abort());
        if (!this.activityHeartbeat) this.startActivityHeartbeat();
        this.publishSnapshot();
        break;
      }
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
        if (!this.hasCurrentDashboardWork()) this.stopActivityHeartbeat();
        this.clearToolProgressTimers();
        if (this.pendingManualCompaction) {
          // The independently admitted compaction token already owns the queued
          // mutation, so the settled foreground token can retire without a gap.
          this.settleOperationWork(settledOperationId);
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
        // A command-triggered turn owns a distinct foreground token. The
        // command may still be unwinding when agent_settled arrives; only skip
        // this lane if the command itself somehow owns the settled identity.
        if (this.pendingExtensionCommand === undefined
          || this.pendingExtensionCommand.id !== settledOperationId) {
          if (this.pendingAssistantCompletion) {
            if (!this.pendingAssistantCompletion.operationId && settledOperationId) {
              this.pendingAssistantCompletion = { ...this.pendingAssistantCompletion, operationId: settledOperationId };
            }
            if (settledOperationId) this.completionWorkOwners.set(this.pendingAssistantCompletion.id, settledOperationId);
            this.operationWork.get(settledOperationId ?? "")?.transition("terminal-receipt-persistence");
            // Pi has settled, but the Gateway remains operationally running until
            // the exact canonical completion is durable. This is the open/drain
            // barrier that prevents a snapshot from outrunning attention truth.
            this.phase = "running";
            this.publishSnapshot();
            void this.beginAttentionSettlement(this.pendingAssistantCompletion).catch(() => {});
            break;
          }
          if (settledOperationId) {
            this.operationWork.get(settledOperationId)?.transition("terminal-receipt-persistence");
            const markerClear = this.terminalizeInvocation(settledOperationId, "completed")
              .then(() => this.clearMarkerOwnership(settledOperationId));
            // The foreground token remains the exact owner; do not create a second
            // receipt token or report drain completion while marker I/O is active.
            void markerClear.then(
              () => undefined,
              (error) => this.emit("session.operationFailed", safeJson({
                operationId: settledOperationId,
                message: error instanceof Error ? error.message : String(error),
              })),
            ).finally(() => {
              this.settleOperationWork(settledOperationId);
              this.hooks.settled(this.id);
              this.publishSnapshot();
            });
          } else {
            // A duplicate/late SDK callback has no exact marker authority. Never
            // interpret undefined as permission to clear every session marker.
            this.hooks.settled(this.id);
          }
        }
        this.publishSnapshot();
        break;
      case "compaction_start":
        this.phase = "compacting";
        this.compactionBaselineEntryId = [...this.sessionManager.getBranch()]
          .reverse()
          .find((entry) => entry.type === "compaction")?.id;
        // Manual compaction already has its own command identity. Automatic
        // preflight compaction receives a distinct runtime identity so repeated
        // maintenance within one prompt can never collide with the prompt row
        // or another canonical compaction.
        this.operation = {
          id: this.operation?.kind === "compaction"
            ? (this.operation.id ?? randomUUID())
            : randomUUID(),
          kind: "compaction",
          startedAt: new Date().toISOString(),
          reason: event.reason,
        };
        this.publishSnapshot();
        break;
      case "compaction_end": {
        this.retry = undefined;
        const completedOperation = this.operation;
        if (completedOperation?.kind === "compaction" && completedOperation.id) {
          const canonicalCompaction = [...this.sessionManager.getBranch()]
            .reverse()
            .find((entry) => entry.type === "compaction");
          if (canonicalCompaction && canonicalCompaction.id !== this.compactionBaselineEntryId) {
            this.rememberPresentationID(canonicalCompaction.id, completedOperation.id);
          }
        }
        this.compactionBaselineEntryId = undefined;
        // Hooks may append canonical entries after the compaction. A single-row
        // delta cannot describe that branch and consumes the client's next
        // cursor when rejected. Publish one immediate bounded authority frame.
        if (this.pendingPrompt) {
          this.phase = "running";
          this.operation = {
            id: this.pendingPrompt.id,
            kind: "prompt",
            startedAt: this.pendingPrompt.createdAt ?? new Date().toISOString(),
          };
        } else if (this.hasActiveAgentRun) {
          this.phase = "running";
          this.activeOperationId ??= randomUUID();
          this.operation = {
            id: this.activeOperationId,
            kind: "prompt",
            startedAt: new Date().toISOString(),
          };
        } else if (completedOperation?.kind === "compaction"
          && completedOperation.reason === "manual") {
          // The wrapper still owns durable marker retirement. Canonical presence
          // suppresses the spinner, while phase remains truthful until cleanup.
          this.phase = "compacting";
          this.operation = completedOperation;
        } else {
          this.phase = "idle";
          this.operation = undefined;
        }
        this.publishSnapshot();
        break;
      }
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
        } else if (event.message.role === "user") {
          // Foreground admission is serialized. Claim the exact Pi object;
          // repeated text and crossing user callbacks cannot impersonate it.
          if (this.pendingPrompt && this.pendingPromptMessage === undefined) {
            this.pendingPromptMessage = event.message;
          } else {
            const operationId = this.activeOperationId;
            const invocation = this.invocationForOperation(operationId);
            if (operationId && invocation) {
              this.pendingInvocationUserMessages.set(event.message, {
                operationId,
                invocationId: invocation.invocationId,
              });
            }
          }
        } else if (event.message.role === "custom") {
          // Every Pi custom_message is model-context input, including an idle
          // non-triggering message retained for a later turn. Capture producer
          // identity only at the Gateway callback boundary; customType, text,
          // details, and renderer registration are never attribution evidence.
          const callbackOwner = currentExtensionOwner();
          this.pendingContextMessages.set(event.message, {
            delivery: this.hasActiveAgentRun ? "triggeredTurn" : "stored",
            ...(callbackOwner ? { origin: { source: callbackOwner.source, owner: callbackOwner } } : {}),
          });
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
        if (this.canonicalToolResultHandoffs.has(event.toolCallId)) break;
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
        const toolLabel = existing?.toolLabel ?? this.toolLabel(event.toolName);
        const extensionActivity = this.updateExtensionActivity(
          event.toolCallId, event.toolName, extensionOrigin, "running", startedAt, now, undefined, undefined, durationMs
        );
        const state: ToolExecutionState = {
          toolCallId: event.toolCallId,
          toolName: event.toolName,
          ...(toolLabel ? { toolLabel } : {}),
          order: existing?.order ?? this.nextToolOrder++,
          status: "running",
          arguments: projectJson(event.args),
          isError: false,
          startedAt,
          updatedAt: now,
          lastProgressAt: now,
          durationMs,
          progressSequence,
          toolSegmentId: toolSegmentId(this.activeOperationId!),
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
        if (this.canonicalToolResultHandoffs.has(event.toolCallId)) break;
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
        const toolLabel = existing?.toolLabel ?? this.toolLabel(event.toolName);
        const extensionActivity = this.updateExtensionActivity(
          event.toolCallId, event.toolName, extensionOrigin, "running", startedAt, now, event.partialResult, undefined, durationMs
        );
        const state: ToolExecutionState = {
          toolCallId: event.toolCallId,
          toolName: event.toolName,
          ...(toolLabel ? { toolLabel } : {}),
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
          toolSegmentId: existing?.toolSegmentId ?? toolSegmentId(this.activeOperationId!),
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
        const toolLabel = existing?.toolLabel ?? this.toolLabel(event.toolName);
        const extensionActivity = this.updateExtensionActivity(
          event.toolCallId, event.toolName, extensionOrigin, event.isError ? "failed" : "completed", startedAt, now, event.result, now, durationMs
        );
        const state: ToolExecutionState = {
          toolCallId: event.toolCallId,
          toolName: event.toolName,
          ...(toolLabel ? { toolLabel } : {}),
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
          toolSegmentId: existing?.toolSegmentId ?? toolSegmentId(this.activeOperationId!),
          ...(this.toolInvocationGroups.get(event.toolCallId) ?? {}),
          ...(extensionOrigin ? { extensionOrigin } : {}),
          ...(extensionActivity ? { extensionActivity } : {}),
        };
        this.rememberToolMetadata(event.toolCallId, state);
        this.toolStartedAtMonotonicMs.delete(event.toolCallId);
        // A tool-result message_end can precede this terminal callback in Pi.
        // Keep its timing/lineage metadata for canonical enrichment, but never
        // re-admit the exact call to the disposable runtime overlay.
        if (this.isCanonicalToolResultOwned(event.toolCallId)) {
          this.toolExecutions.delete(event.toolCallId);
          this.scheduleSnapshot();
          break;
        }
        this.toolExecutions.set(event.toolCallId, state);
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
          // Keep this compatibility path for extension/custom persistence, but
          // ordinary Pi tool results arrive through message_end below.
          this.markCanonicalToolResultHandoff(event.entry.message.toolCallId);
        }
        this.emit("session.structureChanged", { branchChanged: false });
        this.scheduleSnapshot();
        break;
      case "message_end":
        if (event.message.role === "toolResult") {
          // Pi 0.84.1 invokes listeners immediately before appending this exact
          // object. Verify canonical call-ID ownership in the next microtask;
          // a failed persistence attempt must not create a runtime/canonical
          // gap merely because message_end was observed.
          this.observeCanonicalToolResultHandoff(event.message);
        } else if (event.message.role === "assistant") {
          this.finalizeToolInvocationGroups(event.message);
          this.bindCanonicalPresentation(event.message);
        } else if (event.message.role === "custom") {
          const input = this.pendingContextMessages.get(event.message);
          if (input) {
            this.pendingContextMessages.delete(event.message);
            const parentBeforePersistence = this.sessionManager.getLeafId();
            const message = event.message;
            // Canonicalize the exact custom message on the session lane. This
            // prevents a concurrent branch mutation from appending a receipt
            // to the wrong leaf and makes failures owned/retryable rather than
            // detached microtask exceptions.
            void this.lane.run(async () => {
              // Resolve against the complete canonical branch, not its current
              // leaf: assistant/tool entries can be appended before this lane
              // continuation runs. Object identity is the admission key; the
              // content reference is only used for Pi's wrapped custom_message
              // representation, with the captured parent as an additional guard.
              const candidate = this.sessionManager.getBranch().find((entry) =>
                entry.parentId === parentBeforePersistence
                && ((entry.type === "message" && entry.message === message)
                  || (entry.type === "custom_message"
                    && entry.content === message.content)));
              const canonicalID = candidate?.id;
              if (!canonicalID) return;
              await this.persistCanonicalCustomEntry(
                CONTEXT_DELIVERY_RECEIPT_TYPE,
                safeJson(makeContextDeliveryReceipt(canonicalID, input.delivery, input.origin)),
                canonicalID,
              );
              this.scheduleSnapshot();
            }).catch((error) => this.emit("session.extensionError", safeJson({ message: error instanceof Error ? error.message : String(error) })));

          }
        } else if (event.message.role === "user") {
          const queuedBinding = this.pendingInvocationUserMessages.get(event.message);
          if (queuedBinding) this.pendingInvocationUserMessages.delete(event.message);
          const operationID = this.pendingPromptMessage === event.message
            ? this.pendingPrompt?.id
            : queuedBinding?.operationId;
          const invocationID = operationID
            ? queuedBinding?.invocationId ?? this.invocationForOperation(operationID)?.invocationId
            : undefined;
          if (!operationID || !invocationID) {
            this.scheduleSnapshot();
            break;
          }
          const message = event.message;
          // AgentSession persists immediately after listeners return. Resolve
          // that exact object on the session lane and scan the whole branch;
          // later assistant/tool entries must not hide the canonical target.
          void this.lane.run(async () => {
            const candidate = this.sessionManager.getBranch().find((entry) =>
              entry.type === "message" && entry.message.role === "user" && entry.message === message);
            if (!candidate || candidate.type !== "message") return;
            this.rememberPresentationID(candidate.id, operationID);
            const invocation = this.invocations.get(invocationID);
            await this.persistCanonicalCustomEntry(
              INVOCATION_RECEIPT_TYPE,
              receiptJSON(makeInvocationReceipt({
                version: 1,
                receiptId: `binding:${invocationID}`,
                receiptKind: "binding",
                invocationId: invocationID,
                operationId: operationID,
                sessionId: this.id,
                source: invocation?.source ?? "plain",
                ...(invocation?.name ? { name: invocation.name } : {}),
                canonicalEntryId: candidate.id,
                sequence: this.revision + 1,
                createdAt: new Date().toISOString(),
              })),
              `binding:${invocationID}`,
              this.operationWork.get(operationID),
            );
            if (this.pendingPrompt?.id === operationID
              && this.pendingPromptMessage === message) {
              this.pendingPrompt = undefined;
              this.pendingPromptMessage = undefined;
            }
            this.scheduleSnapshot();
          }).catch((error) => this.emit("session.operationFailed", safeJson({ operationId: operationID, message: error instanceof Error ? error.message : String(error) })));
        }
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

  private extensionArtifactPathAllowed(asyncPath: string): boolean {
    if (!isAbsolute(asyncPath)) return false;
    // Do not normalize away traversal before applying the allowlist. The only
    // accepted inputs are the run directory or its direct lifecycle contract files.
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
        && (temporaryParts.length === 3 || temporaryParts[3] === "status.json"
          || temporaryParts[3] === "events.jsonl" || temporaryParts[3] === "recovery-descriptor.json");
      if (temporaryRun) return true;

      const projectRelative = relative(projectRoot, value);
      if (projectRelative === "" || isAbsolute(projectRelative)
        || projectRelative === ".." || projectRelative.startsWith(`..${sep}`)) return false;
      const projectParts = projectRelative.split(/[\\/]/u).filter(Boolean);
      return projectParts.length >= 1
        && projectParts.length <= 2
        && projectParts[0] !== ""
        && (projectParts.length === 1 || projectParts[1] === "status.json"
          || projectParts[1] === "events.jsonl" || projectParts[1] === "recovery-descriptor.json");
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

  private isForegroundSubagentTool(toolName: string, origin: ExtensionToolOrigin | undefined): boolean {
    if (toolName !== "subagent" || !origin?.owner) return false;
    const installedOwner = this.subagentExtensionOrigin().owner;
    return installedOwner !== undefined && installedOwner.id === origin.owner.id;
  }

  private async openOwnedExtensionArtifact(
    asyncDir: string,
    name: "status.json" | "events.jsonl" | "recovery-descriptor.json",
    expectedDirectory?: ExtensionArtifactDirectoryIdentity,
  ): Promise<OpenedExtensionArtifact | undefined> {
    const canonicalAsyncDir = realpathSync(asyncDir);
    if (canonicalAsyncDir !== asyncDir || !this.extensionArtifactPathAllowed(canonicalAsyncDir)) return undefined;
    const directory = await stat(canonicalAsyncDir);
    if (!directory.isDirectory()
      || expectedDirectory && (directory.dev !== expectedDirectory.dev || directory.ino !== expectedDirectory.ino)) return undefined;
    const lexicalPath = join(canonicalAsyncDir, name);
    const canonicalPath = realpathSync(lexicalPath);
    if (dirname(canonicalPath) !== canonicalAsyncDir || !this.extensionArtifactPathAllowed(canonicalPath)) return undefined;
    const handle = await open(lexicalPath, "r");
    try {
      const [opened, observed, observedDirectory] = await Promise.all([
        handle.stat(), stat(canonicalPath), stat(canonicalAsyncDir),
      ]);
      if (!opened.isFile() || !observed.isFile() || !observedDirectory.isDirectory()
        || realpathSync(lexicalPath) !== canonicalPath
        || opened.dev !== observed.dev || opened.ino !== observed.ino
        || directory.dev !== observedDirectory.dev || directory.ino !== observedDirectory.ino) {
        await handle.close();
        return undefined;
      }
      return { handle, directory: { dev: directory.dev, ino: directory.ino } };
    } catch (error) {
      await handle.close();
      throw error;
    }
  }

  private async readExtensionStatusArtifact(asyncDir: string): Promise<Record<string, unknown> | undefined> {
    if (!this.extensionArtifactPathAllowed(asyncDir)) return undefined;
    const opened = await this.openOwnedExtensionArtifact(asyncDir, "status.json");
    if (!opened) return undefined;
    try {
      const buffer = Buffer.alloc(MAX_EXTENSION_ARTIFACT_BYTES + 1);
      const { bytesRead } = await opened.handle.read(buffer, 0, buffer.length, 0);
      if (bytesRead > MAX_EXTENSION_ARTIFACT_BYTES) {
        return this.readOversizedTerminalExtensionArtifact(
          asyncDir,
          buffer.subarray(0, MAX_EXTENSION_ARTIFACT_BYTES),
          opened.directory,
        );
      }
      const parsed: unknown = JSON.parse(buffer.subarray(0, bytesRead).toString("utf8"));
      if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return undefined;
      return this.attachRecoverySessionOwner(asyncDir, parsed as Record<string, unknown>, opened.directory);
    } finally {
      await opened.handle.close();
    }
  }

  /** Async single-run status steps intentionally keep the stable child producer
   * positional, while their fresh session directory is reserved by the root
   * fan-out run. The exact-owned private recovery descriptor is the producer's
   * canonical bridge between those identities; neither the path segment nor a
   * presentation field may nominate the owner. */
  private async attachRecoverySessionOwner(
    asyncDir: string,
    status: Record<string, unknown>,
    directoryIdentity: ExtensionArtifactDirectoryIdentity,
  ): Promise<Record<string, unknown>> {
    if (status.mode !== "single" || typeof status.runId !== "string" || !status.runId
      || Buffer.byteLength(status.runId) > 256 || /[\\/\0]/u.test(status.runId)
      || !Array.isArray(status.steps) || status.steps.length !== 1) return status;
    const step = status.steps[0];
    if (!step || typeof step !== "object" || Array.isArray(step)) return status;
    const stepRecord = step as Record<string, unknown>;
    const sessionFile = typeof stepRecord.sessionFile === "string" ? stepRecord.sessionFile : undefined;
    if (!sessionFile || !isAbsolute(sessionFile)) return status;
    const opened = await this.openOwnedExtensionArtifact(
      asyncDir,
      "recovery-descriptor.json",
      directoryIdentity,
    ).catch(() => undefined);
    if (!opened) return status;
    try {
      const buffer = Buffer.alloc(MAX_EXTENSION_ARTIFACT_BYTES + 1);
      const { bytesRead } = await opened.handle.read(buffer, 0, buffer.length, 0);
      if (bytesRead > MAX_EXTENSION_ARTIFACT_BYTES) return status;
      const parsed: unknown = JSON.parse(buffer.subarray(0, bytesRead).toString("utf8"));
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return status;
      const descriptor = parsed as Record<string, unknown>;
      const budget = descriptor.runFanoutBudget;
      if (descriptor.version !== 1 || descriptor.sourceRunId !== status.runId
        || descriptor.sessionFile !== sessionFile
        || !budget || typeof budget !== "object" || Array.isArray(budget)) return status;
      const budgetRecord = budget as Record<string, unknown>;
      const sessionOwnerId = budgetRecord.rootRunId;
      if (budgetRecord.version !== 1 || typeof sessionOwnerId !== "string" || !sessionOwnerId
        || Buffer.byteLength(sessionOwnerId) > 256 || /[\\/\0]/u.test(sessionOwnerId)) return status;
      return {
        ...status,
        steps: [{ ...stepRecord, [RECOVERY_SESSION_OWNER]: sessionOwnerId }],
      };
    } catch {
      return status;
    } finally {
      await opened.handle.close();
    }
  }

  /** A workflow status can exceed the projection byte cap because producer
   * step details are retained after completion. For an exact directory, admit
   * only its small top-level header plus a matching terminal event from the
   * bounded events tail; never parse or project the oversized step payload. */
  private async readOversizedTerminalExtensionArtifact(
    asyncDir: string,
    headerBytes: Buffer,
    directoryIdentity: ExtensionArtifactDirectoryIdentity,
  ): Promise<Record<string, unknown> | undefined> {
    const headerText = headerBytes.toString("utf8");
    const steps = /,\s*"steps"\s*:/u.exec(headerText);
    if (!steps) return undefined;
    let header: unknown;
    try {
      header = JSON.parse(`${headerText.slice(0, steps.index)}\n}`);
    } catch {
      return undefined;
    }
    if (!header || typeof header !== "object" || Array.isArray(header)) return undefined;
    const candidate = header as Record<string, unknown>;
    const runId = typeof candidate.runId === "string" ? candidate.runId : undefined;
    const headerState = extensionLifecycleState(candidate.state ?? candidate.status);
    if (!runId || !terminalLifecycleStates.has(headerState)) return undefined;

    const openedEvents = await this.openOwnedExtensionArtifact(asyncDir, "events.jsonl", directoryIdentity);
    if (!openedEvents) return undefined;
    try {
      const metadata = await openedEvents.handle.stat();
      if (!metadata.isFile()) return undefined;
      const length = Math.min(metadata.size, MAX_EXTENSION_EVENT_TAIL_BYTES);
      const offset = Math.max(0, metadata.size - length);
      const buffer = Buffer.alloc(length);
      const { bytesRead } = await openedEvents.handle.read(buffer, 0, length, offset);
      let text = buffer.subarray(0, bytesRead).toString("utf8");
      if (offset > 0) {
        const firstNewline = text.indexOf("\n");
        if (firstNewline < 0) return undefined;
        text = text.slice(firstNewline + 1);
      }
      const lines = text.split("\n").filter(Boolean).slice(-MAX_EXTENSION_EVENT_LINES);
      for (let index = lines.length - 1; index >= 0; index -= 1) {
        const line = lines[index]!;
        if (Buffer.byteLength(line) > MAX_EXTENSION_EVENT_TAIL_BYTES) continue;
        let event: unknown;
        try { event = JSON.parse(line); } catch { continue; }
        if (!event || typeof event !== "object" || Array.isArray(event)) continue;
        const value = event as Record<string, unknown>;
        if (value.runId !== runId || !Number.isSafeInteger(value.ts) || (value.ts as number) < 0) continue;
        const recognizedTerminalEvent = value.type === "subagent.workflow.completed"
          || value.type === "subagent.run.completed" || value.type === "subagent.run.stopped";
        if (!recognizedTerminalEvent) continue;
        const eventState = value.type === "subagent.workflow.completed"
          ? extensionLifecycleState(value.state)
          : value.type === "subagent.run.completed"
            ? extensionLifecycleState(value.status)
            : "stopped";
        if (eventState !== headerState || !terminalLifecycleStates.has(eventState)) return undefined;
        const persistedAt = typeof candidate.lastUpdate === "number" && Number.isSafeInteger(candidate.lastUpdate)
          ? Math.max(candidate.lastUpdate, value.ts as number)
          : value.ts;
        return { ...candidate, state: eventState, endedAt: value.ts, lastUpdate: persistedAt };
      }
      return undefined;
    } finally {
      await openedEvents.handle.close();
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

  private extensionArtifactOwnerForDirectory(directory: string): string | undefined {
    for (const [runId, binding] of this.extensionRunOwnership) {
      if (!binding.asyncDir) continue;
      const owned = this.canonicalExtensionArtifactDirectory(binding.asyncDir);
      if (owned === directory) return `${runId}\0${binding.toolCallId}`;
    }
    return undefined;
  }

  private warnExtensionArtifact(reason: ExtensionArtifactRejectionReason, owner: string): void {
    if (!this.dependencies.extensionArtifactWarning) return;
    const opaqueOwner = createHash("sha256").update(`${this.id}\0${owner}`).digest("hex").slice(0, 24);
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
    this.dependencies.extensionArtifactWarning({ reason, owner: opaqueOwner });
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
    if (this.completionOwnershipQueue.length > 0 && !this.attentionBarrier) {
      await this.drainCompletionOwnership().catch(() => {
        this.emit("session.operationFailed", safeJson({ message: "Canonical completion persistence is retrying" }));
      });
    }
    const canonicalFacts = this.canonicalExtensionRunFacts();
    for (const asyncDir of this.ownedExtensionArtifactDirectories()) {
      await this.refreshSubagentActivityFromArtifact(asyncDir, canonicalFacts);
    }
    await this.reconcileOrphanedForegroundWorkForDrain();
  }

  private async refreshSubagentActivityFromArtifact(
    asyncDir: string,
    canonicalFacts?: ReadonlyMap<string, CanonicalExtensionRunFact>,
  ): Promise<void> {
    let diagnosticOwner: string | undefined;
    let claimedReceipt: { activityId: string; owner: GatewayWorkHandle } | undefined;
    try {
      const realAsyncDir = this.canonicalExtensionArtifactDirectory(asyncDir);
      if (!realAsyncDir) return;
      diagnosticOwner = this.extensionArtifactOwnerForDirectory(realAsyncDir);
      const rawValue = await this.readExtensionStatusArtifact(realAsyncDir);
      if (rawValue === undefined) {
        if (diagnosticOwner) this.warnExtensionArtifact("artifact-replacement-in-progress", diagnosticOwner);
        return;
      }
      // Registry discovery is bounded but grants no ownership. Historical
      // artifacts become admissible only here, where the canonical tool result
      // or an exact live asyncDir binding proves the owning session/tool call.
      const admission = inspectExtensionLifecycleArtifact(rawValue, { exactOwnedLegacy: true });
      if (!admission.accepted) {
        if (diagnosticOwner) this.warnExtensionArtifact(admission.reason, diagnosticOwner);
        return;
      }
      const raw = admission.artifact;
      const runId = raw.runId as string;
      if (!runId) return;
      // The file's declared directory is advisory. If present, it must agree
      // with the directory that was actually discovered/read.
      if (typeof raw.asyncDir === "string") {
        const declaredAsyncDir = this.canonicalExtensionArtifactDirectory(raw.asyncDir);
        if (!declaredAsyncDir || declaredAsyncDir !== realAsyncDir) {
          if (diagnosticOwner) this.warnExtensionArtifact("ownership-mismatch", diagnosticOwner);
          return;
        }
      }
      const ownership = this.extensionRunOwnership.get(runId);
      const canonical = (canonicalFacts ?? this.canonicalExtensionRunFacts()).get(runId);
      const historicalArtifact = raw.lifecycleArtifactVersion !== EXTENSION_LIFECYCLE_ARTIFACT_VERSION;
      if (historicalArtifact && !ownership?.asyncDir && !canonical?.asyncDir) return;
      // A duplicated runId in canonical JSONL has no safe artifact owner.
      if (canonical?.ambiguous) {
        if (diagnosticOwner) this.warnExtensionArtifact("ownership-mismatch", diagnosticOwner);
        return;
      }
      if (ownership?.asyncDir) {
        const ownershipAsyncDir = this.canonicalExtensionArtifactDirectory(ownership.asyncDir);
        if (!ownershipAsyncDir || ownershipAsyncDir !== realAsyncDir) {
          if (diagnosticOwner) this.warnExtensionArtifact("ownership-mismatch", diagnosticOwner);
          return;
        }
      }
      if (canonical?.asyncDir) {
        const canonicalAsyncDir = this.canonicalExtensionArtifactDirectory(canonical.asyncDir);
        if (!canonicalAsyncDir || canonicalAsyncDir !== realAsyncDir) {
          if (diagnosticOwner) this.warnExtensionArtifact("ownership-mismatch", diagnosticOwner);
          return;
        }
      }
      if (canonical?.toolCallId && ownership && ownership.toolCallId !== canonical.toolCallId) {
        // A synthetic artifact row may be re-keyed to its first real tool call,
        // but a real ownership binding must never switch to another call.
        if (!ownership.toolCallId.startsWith("subagent:") || ownership.toolCallId === canonical.toolCallId) {
          if (diagnosticOwner) this.warnExtensionArtifact("ownership-mismatch", diagnosticOwner);
          return;
        }
      }
      const matchingEntries = [...this.extensionActivities.entries()].filter(([, activity]) => activity.runId === runId);
      // Correlation is Gateway-owned; never pick an arbitrary activity when a
      // malformed or legacy payload has produced duplicate run identities.
      if (!ownership && !canonical?.toolCallId && matchingEntries.length > 1) {
        if (diagnosticOwner) this.warnExtensionArtifact("ownership-mismatch", diagnosticOwner);
        return;
      }
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
      if (!normalized) {
        if (diagnosticOwner) this.warnExtensionArtifact("invalid-timestamp", diagnosticOwner);
        return;
      }
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
      const activity = this.attachChildSessionReferences(projectExtensionRunActivity(artifactValue, {
        id: previous?.id ?? toolCallId,
        activityId: activityKey,
        toolCallId,
        source: previous?.source ?? this.subagentExtensionOrigin(),
        title: previous?.title ?? "Subagents",
        mode: "asynchronous",
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
        childIdentityStrategy: "piArtifact",
      }), artifactValue, "piArtifact");
      // Ambient discovery is another producer of lifecycle candidates. Apply
      // the same Gateway terminal latch and sequence admission as live tool
      // events before replacing an existing row.
      if (admitExtensionRunActivity(previous, activity) === previous) return;
      const terminalReceiptOwner = activity.status === "running"
        ? undefined
        : this.claimExtensionReceiptOwnership(activityKey);
      if (activity.status !== "running" && !terminalReceiptOwner) return;
      if (terminalReceiptOwner) claimedReceipt = { activityId: activityKey, owner: terminalReceiptOwner };
      const ownershipAccepted = this.bindExtensionRunOwnership(runId, {
        toolCallId,
        asyncDir: realAsyncDir,
        terminal: activity.status !== "running" || Boolean(ownership?.terminal),
      });
      if (!ownershipAccepted) {
        this.releaseExtensionReceiptOwnership(activityKey, terminalReceiptOwner);
        claimedReceipt = undefined;
        if (diagnosticOwner) this.warnExtensionArtifact("ownership-mismatch", diagnosticOwner);
        return;
      }
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
          claimedReceipt = undefined;
        }
        this.stopExtensionActivityWatcher(toolCallId);
      }
      this.trimExtensionActivities();
      this.publishExtensionActivity(activity);
    } catch (error) {
      if (claimedReceipt) this.releaseExtensionReceiptOwnership(claimedReceipt.activityId, claimedReceipt.owner);
      if (diagnosticOwner) this.warnExtensionArtifact(
        error instanceof SyntaxError ? "malformed-artifact" : "artifact-replacement-in-progress",
        diagnosticOwner,
      );
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
    let claimedReceiptOwner: GatewayWorkHandle | undefined;
    let claimedReceiptActivityId: string | undefined;
    try {
      const rawValue = await this.readExtensionStatusArtifact(realAsyncDir);
      if (rawValue === undefined) {
        const tracked = this.extensionActivityWatchers.get(toolCallId);
        if (tracked && tracked.asyncDir === realAsyncDir && tracked.readRetries < 3 && !tracked.timer) {
          tracked.readRetries += 1;
          tracked.timer = setTimeout(() => {
            tracked.timer = undefined;
            void this.refreshExtensionActivityFromArtifact(toolCallId, realAsyncDir);
          }, tracked.readRetries * 100);
          tracked.timer.unref();
          return;
        }
        this.warnExtensionArtifact("artifact-replacement-in-progress", `${previous.runId ?? "run"}\0${toolCallId}`);
        return;
      }
      const tracked = this.extensionActivityWatchers.get(toolCallId);
      if (tracked?.asyncDir === realAsyncDir) tracked.readRetries = 0;
      const admission = inspectExtensionLifecycleArtifact(rawValue, { exactOwnedLegacy: true });
      if (!admission.accepted) {
        this.warnExtensionArtifact(admission.reason, `${previous.runId ?? "run"}\0${toolCallId}`);
        return;
      }
      const raw = admission.artifact;
      if (this.disposed || this.extensionActivityReadGenerations.get(toolCallId) !== generation) return;
      const runId = raw.runId as string;
      if (!runId || runId !== previous.runId) return;
      if (typeof raw.asyncDir === "string") {
        const declaredAsyncDir = this.canonicalExtensionArtifactDirectory(raw.asyncDir);
        if (!declaredAsyncDir || declaredAsyncDir !== realAsyncDir) {
          this.warnExtensionArtifact("ownership-mismatch", `${runId}\0${toolCallId}`);
          return;
        }
      }
      const canonical = this.canonicalExtensionRunFacts().get(runId);
      const ownership = this.extensionRunOwnership.get(runId);
      // Watcher refresh is bound to one tool and one canonical directory. A
      // duplicate canonical runId or either mismatch fails closed.
      if (canonical?.ambiguous || (canonical?.toolCallId && canonical.toolCallId !== toolCallId)
        || !ownership || ownership.toolCallId !== toolCallId) {
        this.warnExtensionArtifact("ownership-mismatch", `${runId}\0${toolCallId}`);
        return;
      }
      if (ownership.asyncDir) {
        const ownershipAsyncDir = this.canonicalExtensionArtifactDirectory(ownership.asyncDir);
        if (!ownershipAsyncDir || ownershipAsyncDir !== realAsyncDir) {
          this.warnExtensionArtifact("ownership-mismatch", `${runId}\0${toolCallId}`);
          return;
        }
      }
      if (canonical?.asyncDir) {
        const canonicalAsyncDir = this.canonicalExtensionArtifactDirectory(canonical.asyncDir);
        if (!canonicalAsyncDir || canonicalAsyncDir !== realAsyncDir) {
          this.warnExtensionArtifact("ownership-mismatch", `${runId}\0${toolCallId}`);
          return;
        }
      }
      const normalized = normalizeExtensionArtifact(raw, {
        now: new Date().toISOString(),
        fallbackStartedAt: previous.startedAt,
        useArtifactStartedAt: false,
      });
      if (!normalized) {
        this.warnExtensionArtifact("invalid-timestamp", `${runId}\0${toolCallId}`);
        return;
      }
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
      const activity = this.attachChildSessionReferences(projectExtensionRunActivity(artifactValue, {
        id: previous.id,
        activityId: activityKey,
        toolCallId,
        source: previous.source,
        title: previous.title,
        mode: "asynchronous",
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
        childIdentityStrategy: "piArtifact",
      }), artifactValue, "piArtifact");
      const current = this.extensionActivities.get(toolCallId);
      if (!current) return;
      if (admitExtensionRunActivity(current, activity) === current) return;
      if (current.lifecycle?.sequence !== undefined && activity.lifecycle?.sequence !== undefined
        && activity.lifecycle.sequence <= current.lifecycle.sequence) return;
      if (activity.status !== "running") {
        claimedReceiptOwner = this.claimExtensionReceiptOwnership(activityKey);
        if (!claimedReceiptOwner) return;
        claimedReceiptActivityId = activityKey;
      }
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
      if (activity.status === "running") {
        const tracked = this.extensionActivityWatchers.get(toolCallId);
        if (this.activityNeedsChildSessionBinding(activity.children)
          && this.artifactPublishesChildSession(artifactValue)) {
          this.scheduleExtensionBindingRetry(toolCallId, realAsyncDir);
        } else if (tracked?.asyncDir === realAsyncDir) {
          tracked.bindingRetries = 0;
        }
      }
      if (activity.status !== "running") {
        this.stopExtensionActivityWatcher(toolCallId);
        claimedReceiptOwner = undefined;
        claimedReceiptActivityId = undefined;
        void this.appendExtensionActivityReceipt(activity).catch((error) => this.emit("session.extensionError", safeJson(error)));
      }
    } catch (error) {
      if (claimedReceiptActivityId) this.releaseExtensionReceiptOwnership(claimedReceiptActivityId, claimedReceiptOwner);
      // The next filesystem event or normal snapshot retries; warning is bounded.
      this.warnExtensionArtifact(
        error instanceof SyntaxError ? "malformed-artifact" : "artifact-replacement-in-progress",
        `${previous.runId ?? "run"}\0${toolCallId}`,
      );
    }
  }

  private artifactPublishesChildSession(value: unknown): boolean {
    const root = value && typeof value === "object" && !Array.isArray(value)
      ? value as Record<string, unknown>
      : undefined;
    const details = root?.details && typeof root.details === "object" && !Array.isArray(root.details)
      ? root.details as Record<string, unknown>
      : root;
    if (!details) return false;
    const visit = (candidate: unknown, depth: number): boolean => {
      if (depth > 4 || !candidate || typeof candidate !== "object" || Array.isArray(candidate)) return false;
      const record = candidate as Record<string, unknown>;
      const progress = record.progress && typeof record.progress === "object" && !Array.isArray(record.progress)
        ? record.progress as Record<string, unknown>
        : undefined;
      if (typeof record.sessionFile === "string" || typeof progress?.sessionFile === "string") return true;
      for (const key of ["results", "steps", "children", "progress"] as const) {
        const nested = record[key];
        if (Array.isArray(nested) && nested.slice(0, 64).some((child) => visit(child, depth + 1))) return true;
      }
      return false;
    };
    return visit(details, 0);
  }

  private activityNeedsChildSessionBinding(children: readonly ExtensionRunChild[]): boolean {
    return children.some((child) => child.childSessionRef === undefined
      || child.children !== undefined && this.activityNeedsChildSessionBinding(child.children));
  }

  private scheduleExtensionBindingRetry(toolCallId: string, asyncDir: string): void {
    const tracked = this.extensionActivityWatchers.get(toolCallId);
    if (!tracked || tracked.asyncDir !== asyncDir || tracked.timer || tracked.bindingRetries >= 4) return;
    tracked.bindingRetries += 1;
    tracked.timer = setTimeout(() => {
      tracked.timer = undefined;
      void this.refreshExtensionActivityFromArtifact(toolCallId, asyncDir);
    }, tracked.bindingRetries * 150);
    tracked.timer.unref();
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
        tracked.readRetries = 0;
        tracked.bindingRetries = 0;
        tracked.timer = setTimeout(() => {
          tracked.timer = undefined;
          void this.refreshExtensionActivityFromArtifact(toolCallId, realAsyncDir);
        }, 50);
        tracked.timer.unref();
      });
      watcher.on("error", () => this.stopExtensionActivityWatcher(toolCallId));
      this.extensionActivityWatchers.set(toolCallId, {
        watcher,
        timer: undefined,
        asyncDir: realAsyncDir,
        readRetries: 0,
        bindingRetries: 0,
      });
      void this.refreshExtensionActivityFromArtifact(toolCallId, realAsyncDir);
    } catch {
      // A missing or inaccessible extension artifact remains a generic live row.
    }
  }

  private claimExtensionReceiptOwnership(activityId: string): GatewayWorkHandle | undefined {
    const existing = this.extensionReceiptOwners.get(activityId);
    if (existing) return existing;
    try {
      const owner = this.dependencies.workRegistry.beginDerived({
        kind: "terminal-receipt-persistence",
        sessionId: this.id,
        hostEpoch: this.ui.hostEpoch,
      });
      this.extensionReceiptOwners.set(activityId, owner);
      return owner;
    } catch {
      return undefined;
    }
  }

  private releaseExtensionReceiptOwnership(activityId: string, owner?: GatewayWorkHandle): void {
    if (!owner || this.extensionReceiptOwners.get(activityId) !== owner) return;
    this.extensionReceiptOwners.delete(activityId);
    owner.settle();
  }

  private appendExtensionActivityReceipt(activity: ExtensionRunActivity): Promise<void> {
    if (!activity.lifecycle || !["completed", "failed", "stopped", "rejected"].includes(activity.lifecycle.state)) return Promise.resolve();
    const receipt = makeExtensionActivityReceipt(activity, this.id);
    const activityId = receipt?.activityId ?? activity.activityId ?? activity.toolCallId;
    const owner = this.extensionReceiptOwners.get(activityId);
    if (!receipt) {
      this.releaseExtensionReceiptOwnership(activityId, owner);
      return Promise.resolve();
    }
    const existingWrite = this.extensionReceiptWrites.get(receipt.activityId);
    if (existingWrite) return existingWrite;
    if (!owner) return Promise.reject(new GatewayError("busy", "Extension receipt ownership is unavailable", true));
    const write = this.trackOwnershipWrite(() => this.retryDurableWrite(
      `extension-receipt:${receipt.activityId}`,
      async () => {
        await this.lane.run(async () => {
          const existing = extensionActivityReceipts(this.runtime.session.sessionManager.getEntries(), this.id)
            .some((entry) => entry.receipt.activityId === receipt.activityId);
          if (existing) return;
          this.runtime.session.sessionManager.appendCustomEntry(EXTENSION_ACTIVITY_RECEIPT_TYPE, receipt);
          this.revision += 1;
          this.scheduleSnapshot();
        });
      },
    ), owner);
    this.extensionReceiptWrites.set(receipt.activityId, write);
    void write.finally(() => {
      if (this.extensionReceiptWrites.get(receipt.activityId) === write) this.extensionReceiptWrites.delete(receipt.activityId);
      this.releaseExtensionReceiptOwnership(receipt.activityId, owner);
    }).catch(() => {});
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
    const foregroundSubagentOwner = this.isForegroundSubagentTool(toolName, extensionOrigin);
    const admittedForegroundSubagent = foregroundSubagentOwner && hasForegroundSubagentRunActivity(value);
    const childIdentityStrategy: ExtensionRunChildIdentityStrategy = foregroundSubagentOwner
      && current?.mode !== "asynchronous"
      && usesForegroundSubagentChildIdentity(value, { allowTerminalResults: status !== "running" })
      ? "piForeground" : "declared";
    if (!current && !hasStructuredExtensionRunActivity(value) && !admittedForegroundSubagent) return undefined;
    const activityKey = current?.activityId ?? extensionActivityId(this.runtime.session.sessionManager.getSessionId(), toolCallId);
    const terminalStates = ["completed", "failed", "stopped", "rejected"];
    if (current?.lifecycle && terminalStates.includes(current.lifecycle.state)) {
      // Terminal admission is a Gateway fact: neither wall-clock order nor a
      // producer's later contradictory terminal may replace it.
      if (status === "running") return current;
      const requestedTerminal = status === "failed" ? "failed" : "completed";
      if (requestedTerminal !== current.lifecycle.state) return current;
      void this.appendExtensionActivityReceipt(current).catch(() => {});
      return current;
    }
    const sequence = (this.extensionActivitySequences.get(activityKey) ?? current?.lifecycle?.sequence ?? 0) + 1;
    this.extensionActivitySequences.set(activityKey, sequence);
    // Returning an async launch receipt completes only the outer tool call. The
    // delegated run remains current until its lifecycle artifact reaches a
    // terminal state; treating this acknowledgement as terminal made pills
    // flash directly into Recently Finished with a near-zero duration.
    const requestedAsyncDir = extensionRunAsyncDir(value);
    const asyncDir = requestedAsyncDir ? this.canonicalExtensionArtifactDirectory(requestedAsyncDir) : undefined;
    const invalidDetachedDirectory = requestedAsyncDir !== undefined && asyncDir === undefined;
    const derivedStatus = extensionActivityStatusFromTool(value, status);
    // An async acknowledgement without an admitted observable directory cannot
    // author a detached live row. Settle the launcher projection instead of
    // creating unwatched runtime/drain ownership.
    const terminal = invalidDetachedDirectory ? true : derivedStatus.terminal;
    const reportedTerminal = derivedStatus.reportedTerminal;
    const effectiveStatus = invalidDetachedDirectory ? (status === "failed" ? "failed" : "completed") : derivedStatus.status;
    const observedAt = new Date().toISOString();
    const terminalAt = terminal ? current?.lifecycle?.terminalAt ?? observedAt : current?.lifecycle?.terminalAt;
    const recentUntil = terminalAt ? new Date(Date.parse(terminalAt) + 900_000).toISOString() : undefined;
    const activity = this.attachChildSessionReferences(projectExtensionRunActivity(value, {
      id: toolCallId,
      activityId: activityKey,
      toolCallId,
      source: extensionOrigin,
      title: this.toolLabel(toolName) ?? toolName,
      ...(asyncDir ? { mode: "asynchronous" } : {}),
      status: current?.lifecycle && terminalStates.includes(current.lifecycle.state) ? current.status : effectiveStatus,
      authoritativeStatus: invalidDetachedDirectory || reportedTerminal || Boolean(current?.lifecycle && terminalStates.includes(current.lifecycle.state)),
      startedAt,
      updatedAt,
      ...(terminal && completedAt ? { completedAt } : {}),
      ...(!terminal || durationMs === undefined ? {} : { durationMs }),
      ...(current ? { previous: current } : {}),
      sequence,
      observedAt,
      ...(terminalAt ? { terminalAt } : {}),
      ...(recentUntil ? { recentUntil } : {}),
      childIdentityStrategy,
    }), value, childIdentityStrategy);
    if (admitExtensionRunActivity(current, activity) === current) return current;
    const terminalReceiptOwner = terminal ? this.claimExtensionReceiptOwnership(activityKey) : undefined;
    if (terminal && !terminalReceiptOwner) return current;
    if (activity.runId && !this.bindExtensionRunOwnership(activity.runId, {
      toolCallId,
      ...(asyncDir === undefined ? {} : { asyncDir }),
      terminal: activity.status !== "running",
    })) {
      this.releaseExtensionReceiptOwnership(activityKey, terminalReceiptOwner);
      return current;
    }
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
      const merged = this.attachChildSessionReferences(projectExtensionRunActivity(value, {
        id: toolCallId,
        activityId: activityKey,
        toolCallId,
        source: extensionOrigin,
        title: this.toolLabel(toolName) ?? toolName,
        ...(asyncDir ? { mode: "asynchronous" } : {}),
        status,
        startedAt,
        updatedAt,
        ...(completedAt ? { completedAt } : {}),
        ...(durationMs === undefined ? {} : { durationMs }),
        sequence,
        observedAt,
        ...(terminalAt ? { terminalAt } : {}),
        ...(recentUntil ? { recentUntil } : {}),
        childIdentityStrategy,
        previous: current
          ? {
              ...synthetic,
              ...current,
              children: current.children.length > 0 ? current.children : synthetic.children,
            }
          : synthetic,
      }), value, childIdentityStrategy);
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
      this.publishProcessesForToolCall(state.toolCallId);
      return;
    }
    if (pending) return;
    const timer = setTimeout(() => {
      this.toolProgressTimers.delete(state.toolCallId);
      const current = this.toolExecutions.get(state.toolCallId);
      if (!current) return;
      this.toolProgressPublishedAt.set(state.toolCallId, Date.now());
      this.emit("session.toolProgress", safeJson(this.toolProgressWire(current)));
      this.publishProcessesForToolCall(current.toolCallId);
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
    this.noteDashboardActivity(this.extensionActivityAsOf);
    if (this.hasDetachedDashboardWork() && !this.activityHeartbeat) this.startActivityHeartbeat();
    this.emit("session.extensionActivity", safeJson({
      activity: this.extensionActivityWire(activity),
      liveActivityRevision: this.liveActivityRevision,
      extensionActivityAsOf: this.extensionActivityAsOf,
    }));
    this.publishProcessesForToolCall(activity.toolCallId);
    // Detached lifecycle updates do not rebuild the full transcript snapshot,
    // but they are authoritative live catalog activity and must reorder rows.
    this.publishSummary();
    if (!this.hasCurrentDashboardWork()) this.stopActivityHeartbeat();
  }

  private clearToolProgressTimers(): void {
    for (const timer of this.toolProgressTimers.values()) clearTimeout(timer);
    this.toolProgressTimers.clear();
    this.toolProgressPublishedAt.clear();
    this.toolStartedAtMonotonicMs.clear();
  }

  private startActivityHeartbeat(): void {
    this.stopActivityHeartbeat();
    this.activityHeartbeat = setInterval(() => this.publishActivityHeartbeat(), 10_000);
    this.activityHeartbeat.unref();
  }

  private publishActivityHeartbeat(): void {
    if (this.disposed || !this.hasCurrentDashboardWork()) {
      this.stopActivityHeartbeat();
      return;
    }
    this.noteDashboardActivity();
    this.emit("session.heartbeat", safeJson({
      phase: this.effectivePhase,
      ...(this.activeOperationId ? { operationId: this.activeOperationId } : {}),
      activeToolCallIds: [...this.toolExecutions.values()]
        .filter((tool) => tool.status === "running")
        .map((tool) => tool.toolCallId),
    }));
    // Heartbeats keep a legitimately active foreground or detached session's
    // catalog timestamp current without rebuilding its transcript snapshot.
    this.publishSummary();
  }

  private stopActivityHeartbeat(): void {
    if (this.activityHeartbeat) clearInterval(this.activityHeartbeat);
    this.activityHeartbeat = undefined;
  }

  private toolLabel(toolName: string): string | undefined {
    const label = this.runtime?.session.extensionRunner.getToolDefinition(toolName)?.label.trim();
    if (!label || Buffer.byteLength(label) > 256
      || [...label].some((character) => {
        const code = character.codePointAt(0)!;
        return code < 0x20 || code === 0x7f;
      })) return undefined;
    return label;
  }

  private toolLabels(): ReadonlyMap<string, string> {
    const labels = new Map<string, string>();
    for (const tool of this.runtime?.session.getAllTools() ?? []) {
      const label = this.toolLabel(tool.name);
      if (label) labels.set(tool.name, label);
    }
    return labels;
  }

  toolPresentationLabels(): ReadonlyMap<string, string> {
    this.assertNoTrustReload();
    return this.toolLabels();
  }

  private extensionCommandOrigin(commandName: string): ChatOrigin {
    const extensions = this.runtime?.session.resourceLoader.getExtensions().extensions.filter(
      extension => extension.commands.has(commandName),
    ) ?? [];
    if (extensions.length !== 1) return { kind: "unknown", confidence: "unknown" };
    const owner = extensionOwnerFor(extensions[0]!);
    return {
      kind: trustedExtensionOriginKind(owner),
      ownerId: owner.id,
      title: owner.title,
      confidence: "adapter",
    };
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
    return this.projectExtensionOrigin(extension);
  }

  private projectExtensionOrigin(extension: Extension): ExtensionToolOrigin | undefined {
    const owner = extensionOwnerFor(extension);
    const source = owner.source.trim().slice(0, 256);
    return source ? { source, owner } : undefined;
  }

  private isCanonicalToolResultOwned(toolCallId: string): boolean {
    if (this.canonicalToolResultHandoffs.has(toolCallId)) return true;
    // The bounded transcript tail is not sufficient evidence: a result can be
    // canonical while its row is paged out. Consult the full current branch as
    // the authoritative, order-independent backstop.
    return canonicalToolResultCallIDs(this.runtime.session.sessionManager).has(toolCallId);
  }

  private observeCanonicalToolResultHandoff(
    message: Extract<AgentMessage, { role: "toolResult" }>,
  ): void {
    queueMicrotask(() => {
      // Canonical JSONL is the authority. Exact object identity proves the
      // current Pi handoff; exact call identity is the forward-compatible
      // fallback if a future SDK persists a cloned message value.
      const owned = this.runtime.session.sessionManager.getBranch().some((entry) =>
        entry.type === "message"
          && entry.message.role === "toolResult"
          && (entry.message === message || entry.message.toolCallId === message.toolCallId));
      if (!owned) return;
      this.markCanonicalToolResultHandoff(message.toolCallId);
      this.scheduleSnapshot();
    });
  }

  private markCanonicalToolResultHandoff(toolCallId: string): void {
    if (!toolCallId) return;
    this.canonicalToolResultHandoffs.delete(toolCallId);
    this.canonicalToolResultHandoffs.add(toolCallId);
    while (this.canonicalToolResultHandoffs.size > 4_096) {
      const oldest = this.canonicalToolResultHandoffs.values().next().value as string | undefined;
      if (!oldest) break;
      this.canonicalToolResultHandoffs.delete(oldest);
    }
    // Metadata deliberately survives this transition: Pi does not persist
    // timing, grouping, or extension provenance in JSONL, so canonical
    // projection still needs the bounded enrichment map.
    this.toolExecutions.delete(toolCallId);
    this.toolStartedAtMonotonicMs.delete(toolCallId);
  }

  private rememberToolMetadata(toolCallId: string, state: ToolExecutionState): void {
    this.toolMetadata.delete(toolCallId);
    this.toolMetadata.set(toolCallId, {
      startedAt: state.startedAt,
      ...(state.completedAt ? { completedAt: state.completedAt } : {}),
      ...(state.durationMs === undefined ? {} : { durationMs: state.durationMs }),
      lastProgressAt: state.lastProgressAt,
      progressSequence: state.progressSequence,
      ...(state.toolSegmentId ? { toolSegmentId: state.toolSegmentId } : {}),
      ...(state.groupId ? { groupId: state.groupId } : {}),
      ...(state.groupIndex === undefined ? {} : { groupIndex: state.groupIndex }),
      ...(state.groupCount === undefined ? {} : { groupCount: state.groupCount }),
      ...(state.groupFinalized ? { groupFinalized: true } : {}),
      ...(state.extensionOrigin ? { extensionOrigin: state.extensionOrigin } : {}),
      ...(state.toolLabel ? { toolLabel: state.toolLabel } : {}),
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
    return {
      ...activity,
      lifecycle: {
        ...activity.lifecycle,
        visibility: recency.visibility,
        ...(recency.remainingMs === undefined ? {} : { remainingMs: recency.remainingMs }),
      },
    };
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

  private onProcessActivityExpiry(frame: ProcessActivityExpiryFrame): void {
    if (this.disposed) return;
    let removed = false;
    for (const processId of frame.expiredProcessIds) {
      if (!this.processActivities.delete(processId)) continue;
      this.childSessionBindings.delete(processId);
      removed = true;
      for (const [toolCallId, processIDs] of this.processIDsByToolCall) {
        processIDs.delete(processId);
        if (processIDs.size === 0) this.processIDsByToolCall.delete(toolCallId);
      }
    }
    if (!removed) return;
    this.processRevision += 1;
    this.processAsOf = frame.asOf;
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
          ...(admission?.resourceInvocation === undefined ? {} : { resourceInvocation: admission.resourceInvocation }),
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
    for (const item of reconciled) {
      if (!this.operationWork.has(item.id)) this.beginDerivedOperationWork(item.id, "queued-mutation");
    }
    const removed = previous.filter((item) => !reconciled.some((candidate) => candidate.id === item.id));
    if (removed.length > 0 && this.hasActiveAgentRun) {
      this.ensureAgentProjection();
      if (this.activeOperationId) this.beginDerivedOperationWork(this.activeOperationId, "foreground-agent-operation");
    }
    for (const item of removed) {
      if (item.behavior === "followUp" && this.operationWork.has(item.id)) {
        if (!this.hasActiveAgentRun) {
          // Pi can remove a follow-up immediately before emitting its next
          // agent_start. Retain the exact accepted owner across that event gap;
          // the start consumes this FIFO latch instead of deriving new work.
          if (!this.dequeuedFollowUpOwners.includes(item.id)) this.dequeuedFollowUpOwners.push(item.id);
          this.operationWork.get(item.id)?.transition("foreground-agent-operation");
          continue;
        }
        if (this.activeOperationId !== item.id) {
          // Pi can emit agent_start before queue_update. The exact removed
          // follow-up then retrospectively transfers its pre-cutoff token into
          // the already-started foreground run; retire only the synthetic owner.
          const syntheticOwner = this.activeOperationId;
          this.activeOperationId = item.id;
          this.operation = {
            id: item.id,
            kind: "prompt",
            startedAt: new Date().toISOString(),
            ...(this.invocationForOperation(item.id)?.invocationId
              ? { invocationId: this.invocationForOperation(item.id)!.invocationId }
              : {}),
          };
          // Queue removal can follow agent_start. Durably transfer the marker
          // before retiring the synthetic event-time owner, so completion stamps
          // cannot race a missing exact marker.
          void this.enqueueMarkerOwnership(item.id).then(async () => {
            if (syntheticOwner) await this.clearMarkerOwnership(syntheticOwner);
            this.settleOperationWork(syntheticOwner);
          }).catch(() => this.runtime.session.abort());
        }
        this.operationWork.get(item.id)?.transition("foreground-agent-operation");
        const pendingIndex = this.dequeuedFollowUpOwners.indexOf(item.id);
        if (pendingIndex >= 0) this.dequeuedFollowUpOwners.splice(pendingIndex, 1);
      } else {
        this.settleOperationWork(item.id);
      }
    }
    const changed = previous.length !== reconciled.length || previous.some((item, index) => {
      const next = reconciled[index];
      return next === undefined
        || item.id !== next.id
        || item.behavior !== next.behavior
        || item.text !== next.text
        || item.runtimeText !== next.runtimeText
        || JSON.stringify(item.resourceInvocation) !== JSON.stringify(next.resourceInvocation)
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
      id, behavior, text, attachmentCount, photoCount, fileAttachmentCount, attachments, resourceInvocation,
    }) => ({
      id,
      behavior,
      text,
      attachmentCount,
      ...(photoCount === undefined ? {} : { photoCount }),
      ...(fileAttachmentCount === undefined ? {} : { fileAttachmentCount }),
      ...(attachments === undefined ? {} : { attachments }),
      ...(resourceInvocation === undefined ? {} : { resourceInvocation }),
    }));
  }

  private static queueText(text: string, attachmentEnvelope: string): string {
    return [text.trim(), attachmentEnvelope].filter(Boolean).join("\n\n");
  }

  private static validateQueue(items: Array<Pick<QueuedMessageState, "text" | "attachmentCount"> & { resourceInvocation?: ResourceInvocation }>): void {
    if (items.length > MAXIMUM_QUEUED_MESSAGES) {
      throw new GatewayError("invalid_request", `At most ${MAXIMUM_QUEUED_MESSAGES} messages may be queued`);
    }
    let totalBytes = 0;
    for (const item of items) {
      const bytes = Buffer.byteLength(item.text);
      if (bytes > MAXIMUM_QUEUED_MESSAGE_BYTES) {
        throw new GatewayError("invalid_request", "A queued message is too large to manage safely");
      }
      if (item.text.trim().length === 0 && item.attachmentCount === 0 && item.resourceInvocation === undefined) {
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
    const derived = this.cachedSnapshotDerived?.revision === this.revision
      ? this.cachedSnapshotDerived
      : (() => {
          const stats = session.getSessionStats();
          const latestCacheHitRate = this.latestCacheHitRate();
          const computed = {
            revision: this.revision,
            stats,
            ...(latestCacheHitRate === undefined ? {} : { latestCacheHitRate }),
          };
          this.cachedSnapshotDerived = computed;
          return computed;
        })();
    const contextUsage = derived.stats.contextUsage;
    const stats = derived.stats;
    const latestCacheHitRate = derived.latestCacheHitRate;
    // Pi exposes streamingMessage before an async message_start hook returns,
    // so the SDK object may establish the initial Gateway identity. Once that
    // exact object is canonically bound, however, Pi can retain it briefly;
    // never let a snapshot recreate a second stream ID from that stale value.
    const sdkStreamingMessage = session.state.streamingMessage;
    const streamingMessage = this.streamPresentationId
      ? (sdkStreamingMessage ?? this.latestStreamingMessage)
      : sdkStreamingMessage && !this.canonicalizedStreamingMessages.has(sdkStreamingMessage)
        ? sdkStreamingMessage
        : undefined;
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
          this.toolLabels(),
          undefined,
          this.activeOperationId ? toolSegmentId(this.activeOperationId) : undefined,
        );
      })()
      : undefined;
    const canonicalTranscriptPage = this.transcriptPage();
    const liveCommand = this.pendingExtensionCommand;
    const liveCommandLifecycle = this.ui.presentation.state().pendingInteractions.length > 0
      ? "waitingForInput" as const
      : "running" as const;
    const transcriptPage: TranscriptPage = liveCommand
      ? {
          ...canonicalTranscriptPage,
          items: canonicalTranscriptPage.items.map(item =>
            item.semantic?.kind === "command"
              && item.semantic.operationId === liveCommand.id
              ? { ...item, semantic: { ...item.semantic, lifecycle: liveCommandLifecycle } }
              : item),
        }
      : canonicalTranscriptPage;
    // transcriptPage is intentionally bounded; use the full canonical branch
    // for ownership so paged-out results cannot leave a duplicate runtime row.
    const canonicalToolResultIDs = canonicalToolResultCallIDs(session.sessionManager);
    const queuedItems = this.projectedQueue();
    const processProjection = this.currentProcessProjection();
    // Canonical receipts are authoritative after runtime recreation; live maps
    // only enrich the current projection and never replace persisted facts.
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
      ...(this.retry ? { retry: this.retry } : {}),
      toolExecutions: [...this.toolExecutions.values()]
        .filter((tool) => !canonicalToolResultIDs.has(tool.toolCallId))
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
      ...(processProjection.activities.length > 0 ? { processActivities: processProjection.activities } : {}),
      processOverview: processProjection.overview,
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
          this.toolLabels(),
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

  processHistory(cursor?: string, limit = 25, filter?: { kind?: "command" | "subagent"; state?: SessionProcessActivity["lifecycle"]["state"] }): SessionProcessHistoryPage {
    this.assertNoTrustReload();
    return listProcessHistory(this.runtime.session.sessionManager, cursor, limit, filter);
  }

  processDetail(processId: string, expectedHistoryRevision?: string): SessionProcessActivity | undefined {
    this.assertNoTrustReload();
    try {
      // History detail is canonical-only. Mutable mounted state has its own
      // process revision and must never be returned under a history revision.
      return processHistoryDetail(this.runtime.session.sessionManager, processId, expectedHistoryRevision);
    } catch (error) {
      if (error instanceof Error && error.message.includes("generation conflict")) {
        throw new GatewayError("conflict", "Process history generation changed; refresh history", true);
      }
      throw error;
    }
  }

  private processForViewer(processId: string): SessionProcessActivity | undefined {
    return this.processActivities.get(processId)
      ?? processHistoryDetail(this.runtime.session.sessionManager, processId);
  }

  async reconcileProcessChildSessionBinding(processId: string): Promise<void> {
    if (this.processChildSessionBinding(processId)) return;
    const process = this.processActivities.get(processId);
    if (!process || process.kind !== "subagent" || !process.runId || !process.toolCallId) return;
    const ownership = this.extensionRunOwnership.get(process.runId);
    if (!ownership?.asyncDir || ownership.toolCallId !== process.toolCallId) return;
    const asyncDir = this.canonicalExtensionArtifactDirectory(ownership.asyncDir);
    if (!asyncDir) return;
    await this.refreshExtensionActivityFromArtifact(ownership.toolCallId, asyncDir);
  }

  processChildSessionBinding(processId: string): { ref: string; producerId: string; sessionOwnerId?: string; runId?: string } | undefined {
    const process = this.processForViewer(processId);
    const binding = this.childSessionBindings.get(processId) ?? this.canonicalChildSessionBinding(processId);
    return process?.childSessionRef && binding?.ref === process.childSessionRef
      ? { ...binding, ...(process.runId ? { runId: process.runId } : {}) }
      : undefined;
  }

  processChildSessionRef(processId: string): string | undefined {
    return this.processChildSessionBinding(processId)?.ref;
  }

  processChildSessionPath(processId: string): { ref: string; producerId: string; path: string; runId?: string } | undefined {
    const binding = this.processChildSessionBinding(processId);
    const path = binding ? this.validatedChildSessionPaths.get(`${binding.ref}\0${binding.producerId}`) : undefined;
    return binding && path ? {
      ref: binding.ref,
      producerId: binding.producerId,
      path,
      ...(binding.runId ? { runId: binding.runId } : {}),
    } : undefined;
  }

  publishSnapshot(): void {
    if (this.disposed || this.trustReloadPending) return;
    this.publishStateChange();
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
      || summary.activeSince !== this.lastPublishedSummary.activeSince
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
      resourceInvocation?: ResourceInvocation;
      attachmentEnvelope: string;
      attachmentCount: number;
      photoCount?: number;
      fileAttachmentCount?: number;
      attachments?: QueuedMessageState["attachments"];
    },
    onAdmitted?: (result: { operationId: string }) => void,
  ): Promise<{ operationId: string }> {
    return this.lane.run(async () => {
      this.assertUsable();
      try {
        if (this.attentionBarrier) await this.attentionBarrier;
      } catch {
        throw new GatewayError("busy", "The prior response is still committing durable attention state", true);
      }
      if (this.completionOwnershipQueue.length > 0 || this.pendingAssistantCompletion) {
        throw new GatewayError("busy", "The prior response is still committing durable attention state", true);
      }
      if (this.lifecycle.isDraining) throw new GatewayError("busy", "Session is draining for an administrative restart", true);
      const session = this.runtime.session;
      while (this.isAgentAdmissionSettling) {
        await this.waitForStateChange();
        this.assertUsable();
      }
      if (queueDisplay?.attachments !== undefined
        && (queueDisplay.attachments.length > MAXIMUM_PROMPT_ATTACHMENTS
          || queueDisplay.attachments.length !== queueDisplay.attachmentCount)) {
        throw new GatewayError("invalid_request", "Prompt attachment descriptors do not match the bounded attachment count");
      }
      if (queueDisplay?.resourceInvocation !== undefined) {
        const resource = queueDisplay.resourceInvocation;
        const catalogName = resource.source === "skill"
          ? `skill:${resource.name.startsWith("skill:") ? resource.name.slice("skill:".length) : resource.name}`
          : resource.name;
        const commands = this.commands();
        const matches = commands.filter(
          command => command.source === resource.source && command.name === catalogName,
        );
        const shadowed = resource.source !== "extension"
          && commands.some(command => command.source === "extension" && command.name === catalogName);
        if (matches.length !== 1 || shadowed) {
          throw new GatewayError("conflict", "The selected resource is no longer unambiguous for this session");
        }
      }
      // Pi 0.84.1 uses the first literal ASCII space as its command
      // delimiter. Keep admission byte-for-byte identical: tabs/newlines are
      // part of the command name and therefore remain ordinary prompt text.
      const extensionCommandName = text.startsWith("/")
        ? text.slice(1).split(" ", 1)[0]
        : undefined;
      const isExactExtensionCommand = extensionCommandName !== undefined
        && session.extensionRunner.getCommand(extensionCommandName) !== undefined;
      const queuesIntoActiveRun = session.isStreaming && behavior !== undefined && !isExactExtensionCommand;
      const operationId = randomUUID();
      const invocationId = randomUUID();
      const invocationSource: InvocationProjection["source"] = isExactExtensionCommand
        ? "extension"
        : queueDisplay?.resourceInvocation?.source ?? "plain";
      const invocationName = isExactExtensionCommand
        ? extensionCommandName
        : queueDisplay?.resourceInvocation?.name;
      const invocation: InvocationProjection = {
        version: 1,
        invocationId,
        operationId,
        source: invocationSource,
        ...(invocationName ? { name: invocationName } : {}),
        ...(queueDisplay?.resourceInvocation?.arguments === undefined ? {} : { arguments: queueDisplay.resourceInvocation.arguments }),
        disposition: isExactExtensionCommand ? "extensionCommand" : queuesIntoActiveRun ? "queuedPrompt" : "canonicalPrompt",
        lifecycle: "staged",
        origin: invocationSource === "extension" && invocationName
          ? this.extensionCommandOrigin(invocationName)
          : { kind: "user", confidence: "boundary" },
        sequence: this.revision + 1,
        updatedAt: new Date().toISOString(),
      };
      if (session.isStreaming && !behavior && !isExactExtensionCommand) {
        this.invocations.delete(invocationId);
        throw new GatewayError("busy", "Session is running; choose steer or follow-up");
      }
      if (queuesIntoActiveRun) {
        this.reconcileQueuedMessages();
        if (this.pendingQueueAdmission) {
          throw new GatewayError(
            "busy",
            "The prior queued prompt is still publishing its authoritative identity",
            true,
          );
        }
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
          ...(display.resourceInvocation === undefined ? {} : { resourceInvocation: display.resourceInvocation }),
        }]);
        this.pendingQueueAdmission = {
          // The returned operation identity is also the stable projected queue
          // identity, giving clients an exact settlement receipt.
          id: operationId, behavior: behavior!, text: display.text,
          attachmentCount: display.attachmentCount,
          ...(display.resourceInvocation === undefined ? {} : { resourceInvocation: display.resourceInvocation }),
          ...(display.photoCount === undefined ? {} : { photoCount: display.photoCount }),
          ...(display.fileAttachmentCount === undefined
            ? {}
            : { fileAttachmentCount: display.fileAttachmentCount }),
          ...(display.attachments === undefined ? {} : { attachments: display.attachments }),
          attachmentEnvelope: display.attachmentEnvelope, images,
        };
      }

      let operationWork!: GatewayWorkHandle;
      let preflightStarted = false;
      let acceptedResolve!: (accepted: boolean) => void;
      const accepted = new Promise<boolean>((resolve) => { acceptedResolve = resolve; });
      let sdkRun: Promise<void>;
      let startPersisted = false;
      try {
        this.invocations.set(invocationId, invocation);
        while (this.invocations.size > 128) this.invocations.delete(this.invocations.keys().next().value!);
        operationWork = this.beginOperationWork(operationId);
        // Exact preflight ownership begins synchronously before marker I/O, so a
        // drain that starts while the marker is pending snapshots this owner.
        this.lifecycle.beginPreflight(operationId);
        preflightStarted = true;

        // Canonical invocation ownership must precede every extension side
        // effect. This custom entry is intentionally hidden from model context
        // and ordinary transcript projection, but survives runtime restart.
        const startReceipt = makeInvocationReceipt({
          version: 1,
          receiptId: `start:${invocationId}`,
          receiptKind: "start",
          invocationId,
          operationId,
          sessionId: this.id,
          source: invocationSource,
          ...(invocationName ? { name: invocationName } : {}),
          ...(queueDisplay?.resourceInvocation?.arguments
            ? { arguments: queueDisplay.resourceInvocation.arguments }
            : {}),
          lifecycle: "staged",
          origin: invocation.origin,
          sequence: this.revision + 1,
          createdAt: new Date().toISOString(),
        });
        // Durable staging precedes the Pi call so an extension handler can
        // never emit output before Gateway has recorded its invocation owner.
        await this.persistInvocationReceipt(startReceipt, operationWork);
        startPersisted = true;

        if (isExactExtensionCommand) {
          this.pendingExtensionCommand = { id: operationId, kind: "command", startedAt: new Date().toISOString(), invocationId, lifecycle: "staged" };
          // Exact commands run before Pi's preflight callback and can wait on UI
          // indefinitely. Persist the provisional admission before invoking Pi.
          await this.enqueueMarkerOwnership(operationId);
          this.revision += 1;
          this.publishSnapshot();
        } else if (!queuesIntoActiveRun) {
          this.activeOperationId = operationId;
          this.operation = { id: operationId, kind: "prompt", startedAt: new Date().toISOString(), invocationId, lifecycle: "staged" };
          this.pendingPromptMessage = undefined;
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

        sdkRun = withInvocationContext({ invocationId, operationId }, () => session.prompt(text, {
          images,
          ...(queuesIntoActiveRun ? { streamingBehavior: behavior } : {}),
          source: "rpc",
          preflightResult: acceptedResolve,
        }));
        // Pi awaits an extension command handler before invoking its preflight
        // callback. The Gateway has already durably admitted the exact command
        // and started its SDK promise, so release the RPC response while this
        // session lane continues to serialize the handler and its side effects.
        if (isExactExtensionCommand) onAdmitted?.({ operationId });
      } catch (error) {
        if (preflightStarted) this.lifecycle.cancelPreflight(operationId);
        this.pendingQueueAdmission = undefined;
        if (this.activeOperationId === operationId) this.activeOperationId = undefined;
        if (this.operation?.id === operationId) this.operation = undefined;
        if (this.pendingPrompt?.id === operationId) {
          this.pendingPrompt = undefined;
          this.pendingPromptMessage = undefined;
        }
        if (this.pendingExtensionCommand?.id === operationId) this.pendingExtensionCommand = undefined;
        if (startPersisted) {
          await this.persistInvocationReceipt(makeInvocationReceipt({
            version: 1,
            receiptId: `terminal:${invocationId}`,
            receiptKind: "terminal",
            invocationId,
            operationId,
            sessionId: this.id,
            source: invocationSource,
            ...(invocationName ? { name: invocationName } : {}),
            lifecycle: "outcomeUnknown",
            origin: invocation.origin,
            sequence: this.revision + 1,
            createdAt: new Date().toISOString(),
          }), operationWork);
        }
        this.invocations.delete(invocationId);
        this.settleOperationWork(operationId);
        throw error;
      }
      let runSettled = false;
      let commandSettled = false;
      let terminalReceiptPersisted = false;
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
        if (this.pendingPrompt?.id === operationId) {
          this.pendingPrompt = undefined;
          this.pendingPromptMessage = undefined;
        }
        if (!this.pendingManualCompaction) await this.clearMarkerOwnership(operationId);
        // Marker I/O may suspend behind a newer run. Clear only this run's live
        // projection; conditional marker deletion already protects its successor.
        if (this.activeOperationId === operationId) this.activeOperationId = undefined;
        if (this.operation?.id === operationId) this.operation = undefined;
        this.settleOperationWork(operationId);
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

      // Pi's callback is authoritative. A local timeout could reject while the
      // same uncancelled input handler later accepts canonical work.
      const admitted = await accepted;
      if (queuesIntoActiveRun && admitted) this.reconcileQueuedMessages();
      if (!queuesIntoActiveRun || !admitted) this.pendingQueueAdmission = undefined;
      this.lifecycle.resolvePreflight(operationId, admitted);
      admissionFinalized = true;
      if (!admitted) {
        await this.persistInvocationReceipt(makeInvocationReceipt({
          version: 1,
          receiptId: `terminal:${invocationId}`,
          receiptKind: "terminal",
          invocationId,
          operationId,
          sessionId: this.id,
          source: invocationSource,
          ...(invocationName ? { name: invocationName } : {}),
          lifecycle: "failed",
          errorCode: "preflight-rejected",
          origin: invocation.origin,
          sequence: this.revision + 1,
          createdAt: new Date().toISOString(),
        }), operationWork);
        this.invocations.delete(invocationId);
        if (this.activeOperationId === operationId) this.activeOperationId = undefined;
        if (this.operation?.id === operationId) this.operation = undefined;
        if (this.pendingPrompt?.id === operationId) {
          this.pendingPrompt = undefined;
          this.pendingPromptMessage = undefined;
        }
        if (this.pendingExtensionCommand?.id === operationId) this.pendingExtensionCommand = undefined;
        await this.clearMarkerOwnership(operationId);
        this.settleOperationWork(operationId);
        this.revision += 1;
        this.publishSnapshot();
        throw new GatewayError("invalid_request", "The agent runtime rejected the prompt before admission");
      }

      await this.persistInvocationReceipt(makeInvocationReceipt({
        version: 1,
        receiptId: `accepted:${invocationId}`,
        receiptKind: "transition",
        invocationId,
        operationId,
        sessionId: this.id,
        source: invocationSource,
        lifecycle: "accepted",
        sequence: this.revision + 1,
        createdAt: new Date().toISOString(),
      }), operationWork);
      this.invocations.set(invocationId, {
        ...invocation,
        lifecycle: queuesIntoActiveRun ? "queued" : "accepted",
        updatedAt: new Date().toISOString(),
      });
      if (isExactExtensionCommand) operationWork.transition("extension-command-prompt-ui");
      else if (queuesIntoActiveRun) operationWork.transition("queued-mutation");
      else {
        operationWork.transition("foreground-agent-operation");
        await this.enqueueMarkerOwnership(operationId);
      }
      this.revision += 1;
      this.publishSnapshot();
      if (!isExactExtensionCommand) onAdmitted?.({ operationId });

      if (isExactExtensionCommand) {
        const finishCommand = async () => {
          if (this.pendingExtensionCommand?.id !== operationId) return;
          // Latch the terminal fact before marker transfer or attention
          // settlement. Those branches may return early while a continuation
          // owns the assistant completion; the invocation must already be
          // durably terminal in that overlap window.
          if (!terminalReceiptPersisted) {
            const terminalLifecycle = this.invocationFailures.delete(invocationId)
              ? "failed"
              : commandSettled ? "completed" : "outcomeUnknown";
            await this.persistInvocationReceipt(makeInvocationReceipt({
              version: 1,
              receiptId: `terminal:${invocationId}`,
              receiptKind: "terminal",
              invocationId,
              operationId,
              sessionId: this.id,
              source: invocationSource,
              ...(invocationName ? { name: invocationName } : {}),
              lifecycle: terminalLifecycle,
              origin: invocation.origin,
              sequence: this.revision + 1,
              createdAt: new Date().toISOString(),
            }), this.operationWork.get(operationId));
            terminalReceiptPersisted = true;
            this.invocations.delete(invocationId);
          }
          if (this.hasActiveAgentRun && this.activeOperationId !== undefined) {
            // Transfer marker ownership back to the foreground/new agent run:
            // commit its record before retiring the command's provisional one.
            await this.enqueueMarkerOwnership(this.activeOperationId);
            await this.clearMarkerOwnership(operationId);
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
            await this.clearMarkerOwnership(operationId);
            this.hooks.settled(this.id);
          }
          if (this.pendingExtensionCommand?.id !== operationId) return;
          this.pendingExtensionCommand = undefined;
          this.settleOperationWork(operationId);
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

  async abort(
    kind: "agent" | "compaction" | "retry" | "branchSummary" | "bash" = "agent",
    expectedOperationId?: string,
  ): Promise<void> {
    this.assertUsable();
    if (expectedOperationId !== undefined && this.operation?.id !== expectedOperationId) {
      throw new GatewayError("conflict", "The active operation changed before it could be stopped", true);
    }
    const session = this.runtime.session;
    const abortedOperationId = this.operation?.id;
    switch (kind) {
      case "compaction": session.abortCompaction(); break;
      case "retry": session.abortRetry(); break;
      case "branchSummary": session.abortBranchSummary(); break;
      case "bash": session.abortBash(); break;
      case "agent":
        await session.abort();
        await this.terminalizeInvocation(abortedOperationId, "interrupted", "user-abort");
        break;
    }
    this.revision += 1;
    this.publishSnapshot();
  }

  async clearQueue(): Promise<void> {
    return this.lane.run(() => {
      this.assertUsable();
      this.suppressQueueEvents = true;
      try {
        this.runtime.session.clearQueue();
      } finally {
        this.suppressQueueEvents = false;
      }
      for (const item of this.queuedMessages) this.settleOperationWork(item.id);
      this.queuedMessages = [];
      this.queueRevision += 1;
      this.revision += 1;
      this.publishSnapshot();
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
            : previous.resourceInvocation === undefined
              ? visibleRuntimeText
              : `/${previous.resourceInvocation.source === "skill" ? `skill:${previous.resourceInvocation.name}` : previous.resourceInvocation.name}${visibleRuntimeText ? ` ${visibleRuntimeText}` : ""}`,
          ordinal: this.nextQueueOrdinal++,
        };
      });
      RuntimeSlot.validateQueue(next);

      const commands = this.commands();
      const extensionCommands = new Set(
        commands.filter((command) => command.source === "extension").map((command) => command.name),
      );
      for (const item of next) {
        if (item.resourceInvocation !== undefined) {
          const resource = item.resourceInvocation;
          const invocationName = resource.source === "skill" && !resource.name.startsWith("skill:")
            ? `skill:${resource.name}` : resource.name;
          const matches = commands.filter(command => command.source === resource.source && command.name === invocationName);
          if (matches.length !== 1 || (resource.source === "skill" && extensionCommands.has(invocationName))) {
            throw new GatewayError("conflict", "A queued resource is no longer unambiguous for this session", true);
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
      for (const item of this.queuedMessages) {
        if (!survivors.some((candidate) => candidate.id === item.id)) this.settleOperationWork(item.id);
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
    let work: GatewayWorkHandle;
    try {
      work = this.dependencies.workRegistry.begin({
        kind: "compaction-export",
        sessionId: this.id,
        hostEpoch: this.ui.hostEpoch,
      });
    } catch (error) {
      if (this.manualCompactionClaim === claim) this.manualCompactionClaim = undefined;
      throw error;
    }

    const operationId = randomUUID();
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
        await this.performManualCompaction(instructions, false, operationId, work);
        return false;
      });

      // Keep the command receipt pending until the exact queued mutation has
      // completed. A disconnected client therefore cannot turn accepted work
      // into an acknowledged-but-unperformed compaction.
      if (queuedCompletion) await queuedCompletion;
      return { queued };
    } finally {
      if (this.manualCompactionClaim === claim) this.manualCompactionClaim = undefined;
      work.settle();
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

  private async performManualCompaction(
    instructions: string | undefined,
    queued: boolean,
    operationId?: string,
    work?: GatewayWorkHandle,
  ): Promise<void> {
    let operationError: unknown;
    if (!queued) {
      if (!operationId || !work) throw new Error("Direct compaction ownership is missing");
      await this.trackOwnershipWrite(
        () => this.retryDurableWrite(`marker:mark:${operationId}`, () => this.dependencies.markers.mark(this.id, operationId)),
        work,
      );
    }
    const startedAt = new Date().toISOString();
    this.phase = "compacting";
    this.operation = { ...(operationId ? { id: operationId } : {}), kind: "compaction", startedAt, reason: "manual" };
    this.noteDashboardActivity(startedAt);
    if (!this.activityHeartbeat) this.startActivityHeartbeat();
    this.revision += 1;
    this.publishSnapshot();
    try {
      await this.runtime.session.compact(instructions);
    } catch (error) {
      operationError = error;
    }

    if (queued) {
      // The queued command inherited the foreground marker. Reliable cleanup
      // keeps the accepted-work token live through durable deletion.
      await this.clearMarkerOwnership();
      this.queuedManualCompactionInFlight = false;
      this.hooks.settled(this.id);
    } else {
      await this.clearMarkerOwnership(operationId, work);
    }

    this.phase = "idle";
    this.operation = undefined;
    this.retry = undefined;
    this.noteDashboardActivity();
    if (!this.hasCurrentDashboardWork()) this.stopActivityHeartbeat();
    this.revision += 1;
    this.publishSnapshot();
    if (operationError !== undefined) throw operationError;
  }

  async executeBash(command: string, excludeFromContext: boolean): Promise<JsonValue> {
    let work: GatewayWorkHandle | undefined;
    try {
      return await this.lane.run(async () => {
        this.assertIdle();
        // Admission and the first canonical Bash call are in one lane turn with
        // no suspension between them. The new token therefore cannot make its
        // own idle check fail and no competing session mutation can enter.
        work = this.dependencies.workRegistry.begin({
          kind: "foreground-agent-operation",
          sessionId: this.id,
          hostEpoch: this.ui.hostEpoch,
        });
        const operationId = randomUUID();
        await this.trackOwnershipWrite(
          () => this.retryDurableWrite(`marker:mark:${operationId}`, () => this.dependencies.markers.mark(this.id, operationId)),
          work,
        );
        const startedAt = new Date().toISOString();
        this.phase = "running";
        this.operation = { id: operationId, kind: "bash", startedAt };
        this.noteDashboardActivity(startedAt);
        if (!this.activityHeartbeat) this.startActivityHeartbeat();
        this.revision += 1;
        this.publishSnapshot();
        try {
          return safeJson(await this.runtime.session.executeBash(command, undefined, { excludeFromContext, id: operationId }));
        } finally {
          await this.clearMarkerOwnership(operationId, work);
          this.phase = "idle";
          this.operation = undefined;
          this.noteDashboardActivity();
          if (!this.hasCurrentDashboardWork()) this.stopActivityHeartbeat();
          this.revision += 1;
          this.publishSnapshot();
        }
      });
    } finally {
      work?.settle();
    }
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
      const result = await this.withRebindAttentionDisposition("reset", () => this.runtime.fork(entryId, { position }));
      if (result.cancelled) throw new GatewayError("cancelled", "Fork was cancelled by an extension");
      const next = this.id;
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
      const work = ownsBranchSummary ? this.dependencies.workRegistry.begin({
        kind: "compaction-export",
        sessionId: this.id,
        hostEpoch: this.ui.hostEpoch,
      }) : undefined;
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
        work?.settle();
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
      resourceSource: command.sourceInfo.source,
      resourceScope: command.sourceInfo.scope,
      resourceOrigin: command.sourceInfo.origin,
    }));
    const prompts: CommandInfo[] = session.promptTemplates.map((prompt) => ({
      name: prompt.name,
      ...(prompt.description ? { description: prompt.description } : {}),
      ...(prompt.argumentHint ? { argumentHint: prompt.argumentHint } : {}),
      source: "prompt",
      sourcePath: prompt.filePath,
      resourceSource: prompt.sourceInfo.source,
      resourceScope: prompt.sourceInfo.scope,
      resourceOrigin: prompt.sourceInfo.origin,
    }));
    const skills: CommandInfo[] = session.resourceLoader.getSkills().skills.map((skill) => ({
      name: `skill:${skill.name}`,
      ...(skill.description ? { description: skill.description } : {}),
      source: "skill",
      sourcePath: skill.filePath,
      resourceSource: skill.sourceInfo.source,
      resourceScope: skill.sourceInfo.scope,
      resourceOrigin: skill.sourceInfo.origin,
    }));
    return admitCommandCatalog(
      [...extension, ...prompts, ...skills].sort((a, b) => a.name.localeCompare(b.name)),
    );
  }

  async commandDetail(source: CommandInfo["source"], name: string): Promise<CommandDetail> {
    this.assertNoTrustReload();
    const command = this.commands().find((candidate) =>
      candidate.source === source && candidate.name === name
    );
    if (!command) throw new GatewayError("not_found", "That command is no longer available");

    let content: string | undefined;
    if (source === "prompt") {
      content = this.runtime.session.promptTemplates.find((prompt) => prompt.name === name)?.content;
    } else if (command.sourcePath) {
      try {
        content = await readFile(command.sourcePath, "utf8");
      } catch {
        throw new GatewayError("not_found", "The command source content is no longer available");
      }
    }
    return content === undefined ? command : { ...command, ...boundCommandContent(content) };
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
        ...(this.toolLabel(tool.name) ? { label: this.toolLabel(tool.name)! } : {}),
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
    this.trustReloadWork = this.dependencies.workRegistry.begin({
      kind: "administrative-provider-package-operation",
      sessionId: this.id,
      hostEpoch: this.ui.hostEpoch,
    });
    this.trustReloadPending = true;
  }

  async reload(projectTrusted?: boolean, publish = true, trustTransition = false): Promise<void> {
    await this.lane.run(async () => {
      if (this.trustReloadWork) this.assertUsable(true);
      else this.assertIdle(trustTransition);
      const work = this.trustReloadWork ?? this.dependencies.workRegistry.begin({
        kind: "administrative-provider-package-operation",
        sessionId: this.id,
        hostEpoch: this.ui.hostEpoch,
      });
      const previousOverride = this.projectTrustReloadOverride;
      this.projectTrustReloadOverride = projectTrusted;
      try {
        await this.reloadBoundSession();
        if (publish) this.commitReload();
      } finally {
        this.projectTrustReloadOverride = previousOverride;
        work.settle();
        if (this.trustReloadWork === work) this.trustReloadWork = undefined;
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
    const work = this.dependencies.workRegistry.begin({
      kind: "compaction-export",
      sessionId: this.id,
      hostEpoch: this.ui.hostEpoch,
    });
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
      work.settle();
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
    return this.lane.run(async () => {
      if (this.disposed) return false;
      // Automatic eviction never waits behind canonical receipt persistence.
      // Receipt work protects the existing slot; a later idle pass may retry
      // only after that authority settles. Explicit shutdown/delete continues
      // to join receipt writes through dispose()/performShutdown().
      if (this.isBusy || this.pendingReceiptWrites.size > 0 || this.trustReloadPending) {
        throw new GatewayError("busy", "Cannot dispose a busy session runtime");
      }
      if (!shouldDispose()) return false;
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
      if (this.extensionShutdownRetryTimer) clearTimeout(this.extensionShutdownRetryTimer);
      this.extensionShutdownRetryTimer = undefined;
      this.extensionShutdownWork?.settle();
      this.extensionShutdownWork = undefined;
    });
  }

  private async disposeRuntime(): Promise<void> {
    this.unregisterExtensionExpiry();
    this.unregisterProcessExpiry();
    for (const activity of this.extensionActivities.values()) {
      this.dependencies.extensionActivityRecency.remove(activity.activityId ?? activity.id);
    }
    for (const processId of this.processActivities.keys()) {
      this.dependencies.processActivityRecency.remove(processId);
    }
    this.processActivities.clear();
    this.processIDsByToolCall.clear();
    this.pendingProcessRemovalsByToolCall.clear();
    this.validatedChildSessionPaths.clear();
    this.childSessionBindings.clear();
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
    this.pendingPromptMessage = undefined;
    this.stopActivityHeartbeat();
    this.clearToolProgressTimers();
    this.clearExtensionActivityWatchers();
    this.extensionRunOwnership.clear();
    this.unsubscribe?.();
    this.ui.cancelAll();
    this.extensionHost.retire("Session runtime disposed");
    await this.disposeAgentRuntime();
    for (const operationId of [...this.operationWork.keys()]) this.settleOperationWork(operationId);
    this.lifecycle.retire();
    this.ui.retire();
    this.disposed = true;
    this.publishStateChange();
  }

  /** Pi gives extensions a session-shutdown callback before invalidating their
   * context. That callback is third-party cleanup, not canonical authority. If
   * it never settles, force-invalidating the AgentSession after a bounded grace
   * keeps idle eviction from making every later session.open wait forever. */
  private async disposeAgentRuntime(): Promise<void> {
    const graceMs = DEFAULT_RUNTIME_DISPOSAL_GRACE_MS;
    const disposal = this.runtime.dispose();
    let timer: NodeJS.Timeout | undefined;
    const outcome = await Promise.race([
      disposal.then(
        () => ({ state: "settled" as const }),
        (error: unknown) => ({ state: "failed" as const, error }),
      ),
      new Promise<{ state: "timedOut" }>((resolveTimeout) => {
        timer = setTimeout(() => resolveTimeout({ state: "timedOut" }), graceMs);
      }),
    ]);
    if (timer) clearTimeout(timer);
    if (outcome.state === "failed") throw outcome.error;
    if (outcome.state === "settled") return;

    // Observability must never become another disposal barrier.
    try { this.dependencies.runtimeDisposalTimedOut?.(graceMs); } catch { /* advisory instrumentation */ }
    // AgentSession.dispose() is synchronous and invalidates every extension
    // context before disconnecting listeners. A timed-out shutdown promise may
    // later unwind and dispose idempotently, but can no longer mutate the slot.
    this.runtime.session.dispose();
    void disposal.catch(() => {});
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
