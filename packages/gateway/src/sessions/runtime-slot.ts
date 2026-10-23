import * as activityProjection from "../kernel/projection/activity.js";
import * as sessionPages from "../kernel/projection/session-pages.js";
import { SnapshotProjection } from "../kernel/projection/snapshot.js";
import { modelQueueSessionExtension } from "./model-queue-session.js";
import { createSettingsManager } from "../admin/settings-sdk-manager.js";
import { applyModelAdmission, compactionAdmission } from "../admin/settings-admission.js";
import { readWorkerQueueSelection } from "../providers/model-queue-extension.js";
import type { ManagedSubagents } from "../kernel/delegation/managed-subagents.js";
import { createHash, randomUUID } from "node:crypto";
import type { SessionConfigurationBlocker } from "../protocol/types.js";
import { boundedSummaryText } from "./summary-text.js";
import { catalogActivityTimestamp } from "./catalog-metadata-index.js";
import { historyPage, historyEntry, type HistoryCursor } from "../kernel/projection/history.js";
import {
  DELEGATED_PROVIDER_TOOL_NAME,
  DELEGATED_SUPERVISOR_TOOL_NAME,
  delegatedArtifactPathAllowed,
  delegatedProviderOrigin,
  delegatedProviderToolVersion,
  isInstalledDelegatedTool,
  trustedDelegatedController,
} from "../kernel/delegation/delegated-provider.js";
import type { AgentMessage, AgentTurnDecision, ThinkingLevel } from "../kernel/pi/agent-core.js";
import { SESSION_SETTINGS_ENTRY, changeSessionSetting, readSessionSettings, readSessionRequestPins, readSessionFixedSettings, readSessionToolChoice } from "./session-settings.js";
import { constants, existsSync, lstatSync, realpathSync, watch, type FSWatcher } from "node:fs";
import { performance } from "node:perf_hooks";
import { mkdtemp, open, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import { type ImageContent, type Model } from "../kernel/pi/ai.js";
import { bindRuntimeSession, guardCanonicalAppend } from "../kernel/pi/adapters.js";
import {
  AgentSessionRuntime,
  createAgentSessionFromServices,
  createAgentSessionRuntime,
  createAgentSessionServices,
  type AgentSession,
  type AgentSessionEvent,
  type CreateAgentSessionRuntimeFactory,
  type ExtensionCommandContextActions,
  type ModelRuntime,
  type ToolDefinition,
  SessionManager,
  SettingsManager,
  type FileEntry,
} from "../kernel/pi/coding-agent.js";
import { GatewayError, asUncertainOutcome } from "../errors.js";
import { CanonicalCustomEntryConflictError, DEFAULT_OWNERSHIP_WRITE_RETRY_WINDOW_MS } from "../kernel/run/run-persistence.js";
import { type CommandReplacement } from "../kernel/run/run-invocations.js";
import { RunOperations } from "../kernel/run/run-operations.js";
import { successfulAssistantCompletion, type CanonicalAssistantCompletion, type SessionAttentionRebindDisposition } from "../kernel/run/completion-facts.js";
import { RunRequestPipeline } from "../kernel/run/request-pipeline.js";
import { boundToolCancellation, interruptToolCalls, ToolCallInterrupt } from "../kernel/run/bounded-tool-cancellation.js";
import { CompactionOperationPolicy } from "../kernel/run/compaction-policy.js";
import type { RequestPolicy } from "../kernel/host/request-policy.js";
import { HomeChapterIdentityReplacementError } from "../modules/home/home-chapter-state.js";
import type { SessionLineageState } from "../kernel/host/session-lineage.js";
import type { HomeMaterializationAuthority } from "../modules/home/home-append-guard.js";
import type { CanonicalAppendContext } from "../kernel/host/canonical-append.js";
import { SessionContextWindowPolicy } from "../providers/context-window-policy.js";
import { createHomeTaskWorkerExtension } from "../kernel/delegation/task-worker-extension.js";
import { HOME_TASK_SUBAGENTS, homeTaskSubagentLaunches, subagentsReceiptId, HOME_TASK_SUBAGENT_STOP_JOIN_MS, undeliveredSubagentNotices, type HomeTaskSubagentRun } from "../modules/home/home-task-subagents.js";
import { HOME_TASK_MARKER, HOME_TASK_REPORT, reportLiveRunsRefusal, type HomeTaskReportOwner } from "../kernel/delegation/task-report.js";
import { tronModuleFactories } from "../extensions/tron-modules.js";
import { ORDINARY_SESSION_PROFILE, type SessionProfile } from "../kernel/host/session-profile.js";
import type { ChangeContext, SessionAppliers, SessionSettingsSource, SettingsChangePath, SettingsModel, SettingsNotice } from "../admin/settings-model.js";
import { type SettingsSignal, type SettingsToolAccess, type TaskWorkerSettingsState, type FixedSetting } from "../kernel/settings/tool-contract.js";
import type { Actor } from "../kernel/settings/settings-record.js";
import { VIRTUAL_MODEL_API } from "../providers/virtual-model.js";
import { piBuiltinExtensions } from "../extensions/pi-builtins.js";
import { currentMcpAuthOperationId, currentMcpAuthTarget } from "../extensions/extension-adapters.js";
import type {
  ChatOrigin,
  ChatSemanticMetadata,
  CommandDetail,
  CommandInfo,
  ExtensionRunActivity,
  ExtensionRunChild,
  ExtensionToolOrigin,
  SessionProcessActivity,
  SessionProcessHistoryPage,
  JsonValue,
  SessionPhase,
  AdministrativeDrainBlockerCategory,
  SessionSnapshot,
  SessionSummaryUpdate,
  SessionTreeNode,
  ToolExecutionState,
  NestedToolExecutionState,
} from "../protocol/types.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { stage } from "../util/request-span.js";
import type { ResourceRecorder } from "../util/resource-recorder.js";
import type { TrustService } from "../admin/trust-service.js";
import type { BlobStore } from "./blob-store.js";
import {
  SESSION_EXPORT_MAX_ITEM_BYTES,
  copyCanonicalSessionCut,
  renderSessionCutToHtml,
  requireSessionExportDiskCapacity,
  writeSessionProjectionCut,
  type CanonicalSessionFileCut,
} from "./session-export.js";
import { SemanticUIBroker, type ExtensionNotificationInput } from "./semantic-ui-broker.js";
import { ExtensionPresentationStore } from "../extensions/host/extension-presentation-store.js";
import { ExtensionLifecycleCoordinator } from "./extension-lifecycle-coordinator.js";
import { RemotePiExtensionHost } from "../extensions/host/remote-pi-extension-host.js";
import {
  admitCommandCatalog,
  boundCommandContent,
  boundStreamingProgressItem,
  NESTED_ARGUMENT_CALL_BYTES,
  NESTED_ARGUMENT_TOTAL_BYTES,
  NESTED_CALL_LIMIT,
  projectJson,
  projectMessage,
  mergeLiveToolOutput,
  projectToolOutput,
  projectToolResult,
  canonicalToolResultCallIDs,
  projectTree,
  toolSegmentId,
  safeJson,
  type ToolProjectionMetadata,
  type TranscriptPage,
} from "../kernel/projection/projection.js";
import type { ForkBoundaryAnchor } from "./fork-boundary.js";
import { type RunMarkerStore } from "../kernel/run/run-markers.js";
import { attributeExtensions, attributedCommandOwner, attributedToolOwner, isBuiltinMcpCommand, currentExtensionOwner, currentInvocationContext } from "../extensions/owner-attribution.js";
import { capturedManagedMessage, isManagedProducerContent, type ManagedMessageCapture, type ManagedInternalWake } from "../extensions/managed-producer.js";
import { EXTENSION_LIFECYCLE_ARTIFACT_VERSION, MAX_EXTENSION_ARTIFACT_BYTES, MAX_EXTENSION_RUN_CHILDREN, MAX_EXTENSION_LIFECYCLE_HEADER_BYTES, admitExtensionRunActivity, extensionActivityId, extensionActivityStatusFromTool, extensionLifecycleState, extensionRunAsyncDir, hasExtensionLifecycleProjectionProperty, hasForegroundSubagentRunActivity, hasStructuredExtensionRunActivity, observedPausedProcessTerminalAt, recoveredReplacementClaim, inspectExtensionLifecycleProjection, inspectExtensionLifecycleArtifact, lifecycleProjectionArtifact, normalizeExtensionArtifact, parseExtensionLifecycleProjectionHeader, projectExtensionRunActivity, terminalLifecycleStates, usesForegroundSubagentChildIdentity, type ExtensionArtifactRejectionReason, type ExtensionRunChildIdentityStrategy } from "../kernel/projection/extension-run-projection.js";
import { ChildSessionAdmission, RECOVERY_SESSION_OWNER } from "../kernel/delegation/child-session-admission.js";
import { EXTENSION_ACTIVITY_RECEIPT_TYPE, extensionActivityReceipts, extensionReceiptActivity, makeExtensionActivityReceipt, type ExtensionActivityHistoryPage } from "./extension-activity-history.js";
import { CONTEXT_DELIVERY_RECEIPT_TYPE, makeContextDeliveryReceipt } from "../kernel/run/context-delivery-receipts.js";
import { INVOCATION_RECEIPT_TYPE, makeInvocationReceipt, receiptJSON } from "../kernel/run/invocation-receipts.js";
import type { InputTrigger } from "../kernel/host/input-admission.js";
import { EXTENSION_NOTIFICATION_RECEIPT_TYPE, extensionNotificationJSON, makeExtensionNotificationReceipt } from "./extension-notification-receipts.js";
import { userFacingPromptPreview, type ResourceExpansionCatalog } from "./resource-invocation.js";
import { ExtensionActivityRecency, type ActivityExpiryFrame, type ActivityVisibility } from "./extension-activity-recency.js";
import { ProcessActivityRecency, isActiveProcessLifecycle, type ProcessActivityExpiryFrame } from "../kernel/projection/process-activity-recency.js";
import {
  processHistoryDetail,
  subagentAbortRoute,
  subagentProcessId,
  subagentProcessesFromActivity,
} from "../kernel/projection/process-activity.js";
import type { GatewayWorkHandle, GatewayWorkRegistry } from "../kernel/run/gateway-work-registry.js";
import type { DisplayArtifactStore } from "../display/display-artifact-store.js";
import type { TronWorkspace } from "../workspace/tron-workspace.js";
import { tronContext } from "../workspace/tron-core-extension.js";
import { projectAgentInstructions, type AgentInstructions } from "./agent-instructions.js";
import type { ToolDisplayProjection } from "../kernel/projection/tool-result.js";
import { trustedExtensionOriginKind } from "../kernel/projection/extension-origin.js";
import { DirectBashProcessOwner } from "../kernel/run/direct-bash-process-owner.js";
import type { ModuleHost, SessionContext } from "../kernel/host/module-host.js";
import { projectHookRegistrations } from "../kernel/projection/hook-projection.js";
import { resourceDistribution } from "./resource-distribution.js";
import { skillTitle } from "./skill-title.js";
import { boundedUtf8Prefix } from "../util/bounded-text.js";
import { availableSubagentRow, loadSubagentCatalog, subagentDetail, type SubagentCatalog, type SubagentDetail } from "../kernel/delegation/subagent-catalog.js";
import type { SessionStore } from "../admin/settings-resolver.js";
import { KEYS, hasCompactionApplier, schemaKey } from "../admin/settings-schema.js";

// A lifecycle header is trusted only after RuntimeSlot has parsed and schema-
// admitted the first property from the exact-owned status file. A payload key
// named `lifecycleProjection` is presentation data until this private marker is
// attached, so tool results cannot nominate a fresh child-session owner.
const EMBEDDED_LIFECYCLE_ARTIFACT = Symbol("embedded-lifecycle-artifact");
type EmbeddedLifecycleArtifact = Record<string, unknown> & { [EMBEDDED_LIFECYCLE_ARTIFACT]?: true };
// Disposable exact child subscriptions travel with the admitted read, never
// with canonical activity data or a separate slot-wide child registry.
const WORKFLOW_CHILD_ARTIFACT_DIRECTORIES = Symbol("workflow-child-artifact-directories");
const WORKFLOW_CHILD_PROCESS_SETTLED = Symbol("workflow-child-process-settled");

/** Exact run IDs behind runner-backed workflow keys. Settled paused executions
 * stay in presentation history but cannot hold a task open or become Stop targets. */
function detachedWorkflowChildKeys(status: Record<string, unknown>): ReadonlyMap<string, string> {
  const keys = new Map<string, string>();
  const steps = Array.isArray(status.steps) ? status.steps.slice(0, MAX_EXTENSION_RUN_CHILDREN) : [];
  for (const step of steps) {
    const edge = step as Record<string, unknown> | null;
    if (edge?.async === true && typeof edge.workflowKey === "string" && typeof edge.runId === "string"
      && !(edge as Record<PropertyKey, unknown>)[WORKFLOW_CHILD_PROCESS_SETTLED]) keys.set(edge.workflowKey, edge.runId);
  }
  return keys;
}

function markEmbeddedLifecycleArtifact(value: Record<string, unknown>): Record<string, unknown> {
  Object.defineProperty(value, EMBEDDED_LIFECYCLE_ARTIFACT, { configurable: false, enumerable: false, value: true, writable: false });
  return value;
}

function isEmbeddedLifecycleArtifact(value: unknown): boolean {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    && (value as EmbeddedLifecycleArtifact)[EMBEDDED_LIFECYCLE_ARTIFACT] === true;
}

function preserveEmbeddedLifecycleMarker(source: unknown, value: Record<string, unknown>): Record<string, unknown> {
  return isEmbeddedLifecycleArtifact(source) ? markEmbeddedLifecycleArtifact(value) : value;
}

export type SessionBroadcast = (sessionId: string, topic: string, payload: JsonValue) => void;

type CanonicalExtensionRunFact = {
  toolCallId?: string;
  asyncDir?: string;
  terminal: boolean;
  ambiguous: boolean;
  recoveredReplacementRunId?: string;
  recoveredSourceRunId?: string;
};

type ExtensionArtifactDirectoryIdentity = { dev: number; ino: number };
type OpenedExtensionArtifact = {
  handle: Awaited<ReturnType<typeof open>>;
  directory: ExtensionArtifactDirectoryIdentity;
};

type PendingContextMessage = {
  kind: "context";
  targetEntryId?: string;
  delivery: "stored" | "triggeredTurn";
  origin?: ExtensionToolOrigin;
  managedMessage?: ManagedMessageCapture;
  /** Live presentation owner bound to the triggered canonical entry at message_end. */
  toolSegmentOwnerId?: string;
};

type PendingExtensionCanonicalEffect =
  | {
      kind: "context";
      targetEntryId: string;
      delivery: "stored" | "triggeredTurn";
      origin?: ExtensionToolOrigin;
      managedMessage?: ManagedMessageCapture;
    }
  | {
      kind: "notification";
      receiptId: string;
      message: string;
      tone: ExtensionNotificationInput["tone"];
      origin: ChatOrigin;
      invocationId?: string;
      operationId?: string;
      createdAt: string;
    };

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

class OversizedExtensionArtifactError extends Error {
  constructor() {
    super("Extension status artifact exceeds the legacy document limit");
    this.name = "OversizedExtensionArtifactError";
  }
}

class ForeignExtensionArtifactSessionError extends Error {
  constructor() {
    super("Extension lifecycle projection belongs to another canonical session");
    this.name = "ForeignExtensionArtifactSessionError";
  }
}

function extensionArtifactReadFailureReason(error: unknown): ExtensionArtifactRejectionReason {
  if (error instanceof OversizedExtensionArtifactError) return "oversized-artifact";
  if (error instanceof ForeignExtensionArtifactSessionError) return "ownership-mismatch";
  if (error instanceof SyntaxError) return "malformed-artifact";
  return "artifact-replacement-in-progress";
}

const EXTENSION_ARTIFACT_MISSING_GRACE_MS = 30_000;
/** A producer replaces status.json by an atomic rename, so a read can open the
 * old inode and stat the new one. The discovery lane owns no watcher for that
 * directory, so it re-reads a bounded number of times before reporting the
 * replacement; the producer's next replace is a whole status-update cadence
 * away, so an immediate retry lands in a settled window. */
const EXTENSION_ARTIFACT_DISCOVERY_READ_RETRIES = 3;
const MAX_EXTENSION_EVENT_TAIL_BYTES = 64 * 1_024;
const MAX_EXTENSION_EVENT_LINES = 256;

/** How one offer of a `status.json` to a slot ended, for the caller that decides
 * whether this exact artifact may be recorded as dealt with. `accepted` means
 * the slot projected a lifecycle from those bytes; `rejected` means no later
 * offer of the same bytes can decide differently (the artifact's own shape,
 * run identity, declared directory or timestamps rejected it, or a terminal
 * latch the identity cannot lift outranks it); `transient` means the slot could
 * not decide from its current state — a losing read, an unavailable terminal
 * receipt claim, an I/O error, or an ownership/attribution comparison that a
 * later pass may resolve — so the same artifact must be offered again. */
export type ExtensionArtifactDiscoveryOutcome = "accepted" | "rejected" | "transient";

interface RuntimeSlotHooks {
  broadcast: SessionBroadcast;
  summaryChanged: (summary: SessionSummaryUpdate) => void;
  changed: (sessionId: string) => void;
  settled: (sessionId: string) => void;
  assistantResponseCompleted: (
    sessionId: string,
    completion: CanonicalAssistantCompletion,
    recovery: boolean,
    observed: boolean,
  ) => Promise<void>;
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
  /** Home's `settings` tool with `taskId`: that task's worker and its live slot (#1336). */
  homeTaskSettings: (sessionId: string, taskId: string, purpose: "resolve" | "change") => Promise<{
    taskId: string; sessionId: string; operationId: string | null; state: string; resolvedFrom?: string; slot: RuntimeSlot;
  }>;
  validateTaskMarker: (sessionId: string, marker: unknown) => Promise<void>;
  homeTaskDiagnostic?: (record: import("../modules/home/home-task-dispatcher.js").HomeTaskDiagnostic) => void;
  managedSubagents?: ManagedSubagents;
  /** The model fallback queues (providers/model-queue.ts). */
  modelQueue?: import("../providers/model-queue.js").ModelQueueOwner;
  /** Provider-owned delegated artifacts are admitted only beneath this root. */
  delegatedArtifactRoot?: string;
  mcpAuth?: { openUrl(operationId: string, url: string, sessionId: string, server: string): void };
  createModelRuntime: () => Promise<ModelRuntime>;
  trust: TrustService;
  blobs: BlobStore;
  exports: BlobStore;
  displayArtifacts: DisplayArtifactStore;
  modules: ModuleHost; // started modules whose extensions this runtime registers
  /** The settings model and its one change path, late-bound:
   * installed on the registry after construction (docs/settings-model.md 5.1). */
  settings: () => { model: SettingsModel; changes: SettingsChangePath } | undefined;
  workspace: TronWorkspace;
  markers: RunMarkerStore;
  extensionActivityRecency: ExtensionActivityRecency;
  processActivityRecency: ProcessActivityRecency;
  workRegistry: GatewayWorkRegistry;
  isSessionPresented: (sessionId: string) => boolean;
  /** Subscribers the registry currently holds for a session; the slot's only
   * view of an audience at build time. */
  sessionAudience: (sessionId: string) => number;
  resources?: ResourceRecorder;
  machineId?: string;
  extensionArtifactWarning?: (warning: { reason: ExtensionArtifactRejectionReason; owner: string }) => void;
  /** Extension cleanup is advisory once runtime disposal begins. A handler that
   * never settles must not strand the canonical session behind idle eviction. */
  runtimeDisposalTimedOut?: (graceMs: number) => void;
  persistenceDiagnostic?: (sessionId: string, code: string) => void;
  compactionDiagnostic?: (diagnostic: { sessionId: string; operationId?: string; reason: "manual" | "threshold" | "overflow"; outcome: "success" | "failure" | "cancelled"; errorMessage?: string }) => void;
  stopSteeringDiagnostic?: (diagnostic: { sessionId: string; queuedSteerCount: number; outcome: "started" | "completed" | "stopped" | "failed" | "unknown" }) => void;
  manualCompactionAdopted?: NonNullable<RunOperations<FixedSetting>["dependencies"]["manualCompactionAdopted"]>;
  codemodeDiagnostic?: (diagnostic: { sessionId: string; outcome: "completed" | "failed" | "aborted" | "timeout"; durationMs: number; nestedCallCount: number; complete: boolean }) => void;
  /** Resolves inherited history once at canonical bind/rebind, never per snapshot. */
  resolveForkBoundary?: (manager: SessionManager) => Promise<ForkBoundaryAnchor | undefined>;
  /** Bounded recency for the shared model picker. Called once per admitted
   * user-session run start; implementations stay off the run's critical path. */
  /** Clears retained archive state before the Gateway admits a run, so a
   * session can never be working while it is hidden from the dashboard. Called
   * inside this slot's lane after `assertUsable()` and before run ownership
   * begins; a rejection aborts the run retryably. It must be a no-op with no
   * I/O while the session is not archived. */
  beforeRunAdmission: (sessionId: string) => Promise<void>;
  /** Gateway-owned archive projection for one session, read at snapshot time.
   * Archive state is registry-owned display state, so a slot neither writes nor
   * caches it: the value is absent while the session is visible. */
  archivedAt: (sessionId: string) => string | undefined;
  /** Physical chapter state is consulted only by mutation owners. The registry
   * answers it from the composed `sessionLineage` owner; any other session is unsealed. */
  lineageState: (sessionId: string) => SessionLineageState;
}

interface RuntimeDrainBlockerFact {
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
/** A run this Gateway first reads already terminal (after a restart or slot
 * reload) ended when its producer recorded, not when it was read: stamping the
 * read time would bring every old run back as recent, with a duration counted
 * from its start to now. A run the Gateway watched finish keeps its own
 * observation instant. A missing, malformed or future producer instant falls
 * back to the observation. */
function rediscoveredTerminalAt(state: string, producerEndedAt: string | undefined, observedAt: string): string {
  if (!["completed", "failed", "stopped", "rejected"].includes(state) || producerEndedAt === undefined) return observedAt;
  const ended = Date.parse(producerEndedAt);
  return Number.isFinite(ended) && ended <= Date.parse(observedAt) ? producerEndedAt : observedAt;
}

export class RuntimeSlot extends RunOperations<FixedSetting> {
  public readonly contextPolicies = new WeakMap<AgentSession, SessionContextWindowPolicy>();
  private readonly newSettingsSessions = new WeakSet<AgentSession>();
  public readonly compactionPolicies = new WeakMap<AgentSession, CompactionOperationPolicy>();
  /** The open Home activation of the live runtime, undefined for every ordinary
   * runtime. Re-resolved in `runtimeFactory`, so a profile change takes effect
   * with the runtime it applies to. */
  public homeRequestPolicy: RequestPolicy | undefined;
  private detachOpenAIEligibility: (() => void) | undefined;
  public runtime!: AgentSessionRuntime;
  private unsubscribe: (() => void) | undefined;
  public readonly lane = new AsyncMutex();
  public ui: SemanticUIBroker;
  private extensionHost: RemotePiExtensionHost;
  public lifecycle: ExtensionLifecycleCoordinator;
  private hasBoundSession = false;
  protected readonly runtimeGeneration = randomUUID();
  /** Stable runtime-only catalog identity for a new session before Pi creates JSONL. */
  private readonly createdAt = new Date().toISOString();
  /** Disposable derived annotation; canonical JSONL remains the authority. */
  private forkBoundary: ForkBoundaryAnchor | undefined;
  private displayArtifactReferenceKey: string | undefined;
  private displayArtifactReferences: string[] = [];
  private browserLiveReferences = new Set<string>();
  private eventSequence = 0;
  public disposed = false;
  /** Set by the registry when it publishes this slot as a live runtime. Only a
   * published slot is an eviction when it is disposed; a start that was retired
   * before publication never was one. */
  private published = false;
  private readonly stateChangeWaiters = new Set<() => void>();
  private retainedLeaseCount = 0;
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
  /** The session replacement a running extension command requested. */
  public commandReplacement: CommandReplacement | undefined;
  /** Disposable runtime-only bridge from canonical entry IDs to mounted turn IDs. */
  private readonly presentationIDs = new Map<string, string>();
  private readonly presentationIDOrder: string[] = [];
  public activityHeartbeat: NodeJS.Timeout | undefined;
  private readonly toolProgressTimers = new Map<string, NodeJS.Timeout>();
  private readonly toolProgressPublishedAt = new Map<string, number>();
  /** Monotonic invocation starts keep duration independent of wall-clock changes. */
  private readonly toolStartedAtMonotonicMs = new Map<string, number>();
  private readonly nestedToolRoots = new Map<string, string>();
  private readonly nestedToolStartedAt = new Map<string, number>();
  /** Display lineage survives tool-only agent continuations even when lifecycle
   * settlement rotates the operation owner. User, visible content, and compaction
   * barriers rotate it so live projection matches cold transcript derivation. */
  public activeToolSegmentOwnerId: string | undefined;
  /** A provisional no-match owner prevents old calls from reviving between a
   * canonical barrier and the next assistant message's stable presentation ID. */
  public toolSegmentAwaitsAssistantOwner = false;
  public activeExports = 0;
  private resourceReloadOptions: { resolveProjectTrust: () => Promise<boolean> } | undefined;
  private projectTrustReloadOverride: boolean | undefined;
  public trustReloadPending = false;
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
  /** Task-end joins waiting for a detached run's state to change. Each join owns its
   * entry and removes it when it stops waiting. */
  private readonly detachedWorkWaiters = new Set<() => void>();
  /** Task-end joins waiting for a completion notice's delivery receipt to be recorded. */
  private readonly canonicalDeliveryWaiters = new Set<() => void>();
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
    /** Gateway-observed instant of this run's paused process-terminal proof;
     * absent while the run owns live processes or is not paused. */
    pausedProcessQuiescentAt?: string;
    /** Exact detached child run IDs by workflow key, excluding admitted paused
     * exit proofs. Status and Stop consume this same artifact-frame binding. */
    detachedChildKeys?: ReadonlyMap<string, string>;
  }>();
  private readonly extensionActivityWatchers = new Map<string, {
    watcher: FSWatcher;
    children: Map<string, FSWatcher>;
    onChange: (eventType: string, filename: string | Buffer | null) => void;
    timer: NodeJS.Timeout | undefined;
    asyncDir: string;
    readRetries: number;
    bindingRetries: number;
  }>();
  private readonly extensionActivityReadGenerations = new Map<string, number>();
  private readonly extensionArtifactMissingSince = new Map<string, number>();
  private readonly extensionArtifactWarnings = new Map<string, number>();
  private readonly extensionReceiptWrites = new Map<string, Promise<void>>();
  private readonly extensionReceiptOwners = new Map<string, GatewayWorkHandle>();
  private extensionShutdownWork: GatewayWorkHandle | undefined;
  private extensionShutdownInFlight = false;
  private extensionShutdownRetryTimer: NodeJS.Timeout | undefined;
  private readonly unregisterExtensionExpiry: () => void;
  private readonly unregisterProcessExpiry: () => void;
  private readonly processActivities = new Map<string, SessionProcessActivity>();
  /** Foreground operation captured only while the owning subagent tool call is
   * actively executing. This fences a later sheet stop from newer parent work. */
  private readonly processOperationIDs = new Map<string, string>();
  private readonly processIDsByToolCall = new Map<string, Set<string>>();
  private readonly pendingProcessRemovalsByToolCall = new Map<string, Set<string>>();
  private readonly childSessionAdmission = new ChildSessionAdmission({
    parentSessionFile: () => this.sessionManager.getSessionFile(),
    parentSessionId: () => this.id,
    isEmbeddedLifecycleArtifact,
  });
  /** Exact process-scoped binding; a reused child session ref must never
   * overwrite the producer identity of another current or historical row. */
  private readonly childSessionBindings = new Map<string, { ref: string; producerId: string; sessionOwnerId?: string }>();
  private processRevision = 0;
  private processAsOf = new Date().toISOString();
  /** Bounded runtime timing enriches the mobile projection without changing Pi
   * JSONL. Identity domains remain separate so provider tool-call IDs cannot
   * collide with canonical direct-Bash entry IDs. */
  private readonly toolMetadata = new Map<string, ToolProjectionMetadata>();
  protected readonly bashMetadata = new Map<string, ToolProjectionMetadata>();
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
  /** Summary facts are folded from the entries appended since the last fold, so
   * publishing a change never re-walks a long transcript (G-11: a live session
   * with tens of thousands of entries otherwise spends its publish window on
   * history). An entry set that is not a pure append (branch switch, file
   * re-open, external rewrite) is walked whole instead. */
  private summaryContentFold: {
    messageCount: number;
    firstMessage: string;
    updatedAt: string | undefined;
    entryCount: number;
    lastEntryId: string | undefined;
  } | undefined;
  private lastTouchedAt = Date.now();
  /** Canonical user messages produced by queued resource/plain invocations. */
  private readonly pendingInvocationUserMessages = new WeakMap<AgentMessage, {
    operationId: string;
    invocationId: string;
  }>();
  /** Causal custom-message callbacks awaiting Pi's canonical branch identity.
   * FIFO callback order and the captured branch boundary—not cloned payload
   * identity—bind each delivery receipt after Pi persists its entry. */
  private pendingExtensionNotificationWrites = 0;
  private extensionCanonicalEffectFlushScheduled = false;
  private readonly pendingExtensionCanonicalEffects: PendingExtensionCanonicalEffect[] = [];
  private readonly pendingContextMessages: PendingContextMessage[] = [];
  /** Event IDs of the Home inbox messages being appended right now. The inbox
   * writes their exact context receipt itself, so generic custom-message
   * attribution must not claim them with a second, conflicting receipt. */
  public readonly inboxAttributedMessages = new Set<string>();
  private unregisterConfigurationWork: (() => void) | undefined;
  private publishedConfigurationBlocker: SessionConfigurationBlocker | null | undefined;
  public shuttingDown = false;
  private shutdownPromise: Promise<void> | undefined;
  /** Retirement waiters parked until this slot may have settled. */
  private readonly settleWaiters = new Set<() => void>();
  /** Exact process ownership for the built-in foreground bash tool only.
   * Extension-managed detached subagents remain outside this stop boundary. */
  public directBashProcesses: DirectBashProcessOwner | undefined;
  /** One-shot creation recipe, used only while its id is unrecorded. */
  private explicitProfile: { sessionId: string; profile: SessionProfile } | undefined;
  public readonly canonicalAppendContext: CanonicalAppendContext;
  /** The Home wake whose trigger is being sent: its canonical binding and receipt follow its message_end. */
  private homeWakeTrigger: { eventId: string; taskId: string; operationId: string } | undefined;
  /** Whether the admitted operation is a wake, so the activation's idle notice names it. */
  /** The curated profile each live runtime was built with. `setModel` and
   * `compact` read this, never the record, so a policy is never applied to a
   * runtime that did not load it. */
  private readonly runtimeProfiles = new WeakMap<AgentSession, SessionProfile>();

  protected get virtualModelAPI(): string { return VIRTUAL_MODEL_API; }

  private constructor(
    public sessionManager: SessionManager,
    public readonly dependencies: RuntimeSlotDependencies,
    public readonly hooks: RuntimeSlotHooks,
    interrupted: boolean,
    creationProfile: SessionProfile = ORDINARY_SESSION_PROFILE,
    homeMaterializationAuthority?: HomeMaterializationAuthority,
    // Rebound only by `bindTaskWorker` when a settled task resumes in place (#929).
    public taskWorker?: HomeTaskReportOwner,
  ) {
    super();
    this.explicitProfile = { sessionId: sessionManager.getSessionId(), profile: creationProfile };
    this.canonicalAppendContext = {
      owner: this,
      writeAuthority: homeMaterializationAuthority ? Object.freeze({ ...homeMaterializationAuthority }) : undefined,
      manager: () => this.sessionManager,
      sessionId: () => this.id,
      sessionFile: () => this.sessionFile,
      activeOperationId: () => this.activeOperationId,
      entryCount: () => this.canonicalEntryCount,
      guardedProfile: manager => this.profileFor(manager).chapter,
      abort: (operationId, reason) => this.abort("agent", operationId, reason),
      diagnostic: record => this.emit("session.diagnostic", record),
    };
    this.phase = interrupted ? "interrupted" : "idle";
    this.unregisterConfigurationWork = dependencies.workRegistry.observeSessions((sessionId) => {
      if (this.published && !this.disposed && sessionId === this.id) this.publishConfiguration();
    });
    this.ui = this.createSemanticBroker();
    this.extensionHost = new RemotePiExtensionHost(this.ui, { enableBlockingCustom: false });
    this.lifecycle = new ExtensionLifecycleCoordinator(this.ui.presentation, () => this.hasRuntimeWork());
    this.unregisterExtensionExpiry = dependencies.extensionActivityRecency.registerExpiryCallback((frame) => this.onExtensionActivityExpiry(frame));
    this.unregisterProcessExpiry = dependencies.processActivityRecency.registerExpiryCallback((frame) => this.onProcessActivityExpiry(frame));
  }

  private installCanonicalWriteGuard(sessionManager: SessionManager): void {
    // The guarded method belongs to the manager, not a runtime rebuild. Its
    // immutable owner also rejects sharing one writer instance across slots.
    const guarded = guardCanonicalAppend(sessionManager, this, (append) => {
      const policy = this.dependencies.modules.policy("appendGuard")?.(this.canonicalAppendContext);
      if (policy) policy.append(sessionManager, append);
      else append();
    });
    if (!guarded) throw new GatewayError("conflict", "Canonical session manager already has a runtime owner");
  }

  private createSemanticBroker(): SemanticUIBroker {
    const presentation = new ExtensionPresentationStore((topic, payload) => {
      this.revision += 1;
      this.emit(topic, payload);
      // Interaction admission and settlement change who can advance the
      // session even when no transcript entry changes. Publish that transition
      // immediately to shallow dashboard subscribers.
      this.publishSummary();
      this.publishConfiguration();
    }, {
      capabilities: [
        "semantic.dialogs", "tron.form.v1", "semantic.notifications", "semantic.status", "semantic.working",
        "semantic.hidden-thinking-label", "semantic.string-widgets", "semantic.title",
        "semantic.revisioned-editor", "semantic.tools-expanded", "surfaces.full-frame",
      ],
      diagnostics: [
        { code: "remote-components.enabled", message: "Retained string widgets and bounded read-only component frames are presented through the general extension-content sheet; blocking custom and overlay UI remain deferred." },
        { code: "remote-components.overlay-deferred", message: "Overlay and interactive component UI remain deferred until native rendering and input leases are available." },
        { code: "theme.baseline-only", message: "Per-session process-global Pi theme synchronization is unavailable through the pinned public API." },
      ],
    });
    return new SemanticUIBroker(
      presentation,
      (notification) => this.enqueueExtensionNotification(notification),
      (interaction) => {
        const interactionRequired = this.dependencies.modules.policy("interactionRequired")?.();
        if (!interactionRequired) return;
        // Sample the same token-bound foreground lease at the exact semantic
        // interaction admission boundary. The detached service call receives
        // that latched disposition, so a later close/open race cannot change
        // whether this input request was already visible to the user.
        const observed = this.dependencies.isSessionPresented(this.id);
        return interactionRequired({ sessionId: this.id, interactionId: interaction.id, observed });
      },
    );
  }

  private currentExtensionContextOrigin(): ExtensionToolOrigin | undefined {
    const callbackOwner = currentExtensionOwner();
    const callbackInvocation = currentInvocationContext();
    const invocation = callbackInvocation
      ? this.runInvocations.invocations.get(callbackInvocation.invocationId)
        ?? this.runInvocations.invocationForOperation(callbackInvocation.operationId)
      : this.runInvocations.invocationForOperation(this.pendingExtensionCommand?.id);
    const invocationOrigin = invocation?.name
      ? this.extensionCommandContextOrigin(invocation.name)
      : undefined;
    return invocationOrigin
      ?? (callbackOwner ? { source: callbackOwner.source, owner: callbackOwner } : undefined);
  }

  private enqueueExtensionNotification(notification: ExtensionNotificationInput): void {
    // notify is a void producer callback. Bound queued canonical writes so an
    // extension timer cannot create unbounded mutation-lane memory pressure.
    if (this.pendingExtensionNotificationWrites >= 128) {
      this.ui.presentation.recordRejectedCallback(
        "notify",
        new GatewayError("busy", "Extension notifications reached their pending write capacity", true),
      );
      return;
    }
    this.pendingExtensionNotificationWrites += 1;
    const invocation = notification.invocation
      ? this.runInvocations.invocations.get(notification.invocation.invocationId)
        ?? this.runInvocations.invocationForOperation(notification.invocation.operationId)
      : this.runInvocations.invocationForOperation(this.pendingExtensionCommand?.id);
    // The exact callback owner is the producer. The enclosing invocation adds
    // causality but must not restyle an extension tool notification as user UI.
    const origin: ChatOrigin = notification.owner
      ? {
          kind: trustedExtensionOriginKind(notification.owner),
          ownerId: notification.owner.id,
          title: notification.owner.title,
          confidence: "receipt",
        }
      : invocation?.origin ?? { kind: "unknown", confidence: "unknown" };
    this.enqueueExtensionCanonicalEffect({
      kind: "notification",
      receiptId: `notification:${randomUUID()}`,
      message: notification.message,
      tone: notification.tone,
      origin,
      ...(invocation ? { invocationId: invocation.invocationId, operationId: invocation.operationId } : {}),
      createdAt: new Date().toISOString(),
    });
  }

  private enqueueExtensionCanonicalEffect(effect: PendingExtensionCanonicalEffect): void {
    this.pendingExtensionCanonicalEffects.push(effect);
    this.scheduleExtensionCanonicalEffectFlush();
  }

  private scheduleExtensionCanonicalEffectFlush(): void {
    if (this.extensionCanonicalEffectFlushScheduled) return;
    this.extensionCanonicalEffectFlushScheduled = true;
    void this.lane.run(() => this.flushPendingExtensionCanonicalEffects())
      .catch((error) => this.emit("session.extensionError", safeJson({
        message: error instanceof Error ? error.message : String(error),
      })))
      .finally(() => {
        this.extensionCanonicalEffectFlushScheduled = false;
        if (!this.disposed && this.pendingExtensionCanonicalEffects.length > 0) {
          this.scheduleExtensionCanonicalEffectFlush();
        }
      });
  }

  private async flushPendingExtensionCanonicalEffects(): Promise<void> {
    let changed = false;
    while (this.pendingExtensionCanonicalEffects.length > 0) {
      const effect = this.pendingExtensionCanonicalEffects.shift()!;
      if (effect.kind === "notification") {
        try {
          const receipt = makeExtensionNotificationReceipt({
            version: 1,
            receiptId: effect.receiptId,
            sessionId: this.id,
            message: effect.message,
            tone: effect.tone,
            origin: effect.origin,
            ...(effect.invocationId ? { invocationId: effect.invocationId } : {}),
            ...(effect.operationId ? { operationId: effect.operationId } : {}),
            sequence: this.revision + 1,
            createdAt: effect.createdAt,
          });
          await this.persistCanonicalCustomEntry(
            EXTENSION_NOTIFICATION_RECEIPT_TYPE,
            extensionNotificationJSON(receipt),
            effect.receiptId,
          );
        } finally {
          this.pendingExtensionNotificationWrites -= 1;
        }
      } else {
        const candidate = this.sessionManager.getEntry(effect.targetEntryId);
        const isCustomMessage = candidate?.type === "custom_message"
          || (candidate?.type === "message" && candidate.message.role === "custom");
        if (!candidate || !isCustomMessage) {
          this.emit("session.extensionError", safeJson({
            message: "Custom message did not acquire canonical context identity",
          }));
          continue;
        }
        await this.persistCanonicalCustomEntry(
          CONTEXT_DELIVERY_RECEIPT_TYPE,
          safeJson(makeContextDeliveryReceipt(candidate.id, effect.delivery, effect.origin, effect.delivery === "stored" ? effect.managedMessage?.wakeOperationId : undefined)),
          candidate.id,
        );
        this.notifyCanonicalDelivery();
      }
      changed = true;
    }
    if (changed) this.scheduleSnapshot();
  }

  static async create(
    sessionManager: SessionManager,
    dependencies: RuntimeSlotDependencies,
    hooks: RuntimeSlotHooks,
    interrupted: boolean,
    creationProfile: SessionProfile = ORDINARY_SESSION_PROFILE,
    homeMaterializationAuthority?: HomeMaterializationAuthority,
    taskWorker?: HomeTaskReportOwner,
  ): Promise<RuntimeSlot> {
    const slot = new RuntimeSlot(sessionManager, dependencies, hooks, interrupted, creationProfile, homeMaterializationAuthority, taskWorker);
    try {
      await slot.initialize();
      return slot;
    } catch (error) {
      slot.detachOpenAIEligibility?.();
      slot.detachOpenAIEligibility = undefined;
      await slot.runtime?.dispose().catch(() => {});
      throw error;
    }
  }

  get id(): string {
    return this.sessionManager.getSessionId();
  }
  hasBuiltinMcpCommand(): boolean {
    return isBuiltinMcpCommand(this.runtime.session.extensionRunner.getCommand("mcp"));
  }

  /** Whether this is a Home task worker and whether its task operation still runs here.
   * `settled`: a worker session whose last task stopped or ended; a maintainer message
   * resumes it in place rather than being refused (#929). */
  get homeTaskWorkerState(): "none" | "active" | "settled" {
    if (this.taskWorker?.controlsActive) return "active";
    return this.taskWorker || this.canonicalTaskEvidence().some(entry => entry.type === "custom" && entry.customType === HOME_TASK_MARKER)
      ? "settled" : "none";
  }

  /** Immutable task addresses are file-wide evidence, not the selected model
   * branch. Harmless tree viewing must never lose an already sealed result. */
  canonicalTaskEvidence(): FileEntry[] {
    return this.sessionManager.getEntries().filter(entry => entry.type === "custom"
      && (entry.customType === HOME_TASK_MARKER || entry.customType === HOME_TASK_REPORT));
  }

  /** Live task settlement enters from outside the lane after terminal/Stop
   * joining. Keep late steering receipt writes out of its durable file cut.
   * Never await this seam from work already running on the session lane. */
  async inspectTaskSettlement<T>(operationId: string, inspect: (settled: boolean) => Promise<T>): Promise<T> {
    return this.lane.run(() => {
      this.assertUsable();
      if (this.taskWorker?.identity.operationId !== operationId) throw new GatewayError("conflict", "Task operation changed before settlement");
      return inspect(!this.hasActiveAgentRun && !this.isAgentAdmissionSettling && this.operation === undefined);
    });
  }

  /** Read-only owner seam for bounded derived projections; callers never
   * mutate. Branch-sensitive consumers must use the SDK-selected branch, not
   * the file-wide entry set (which also contains sibling fork history). */
  canonicalSessionEntries(): FileEntry[] {
    const header = this.sessionManager.getHeader();
    return header ? [header, ...this.sessionManager.getBranch()] : [];
  }

  /** Exact owner seam for derived search. This is a bounded snapshot of the
   * SDK-selected branch, never a second session runtime or file-tail guess. */
  searchCanonicalCut(): { entries: FileEntry[]; forkBoundary?: ForkBoundaryAnchor; runtimeGeneration: string; leafEntryId?: string } {
    const entries = this.canonicalSessionEntries();
    const leafEntryId = entries.at(-1)?.id;
    return {
      entries,
      ...(this.forkBoundary ? { forkBoundary: this.forkBoundary } : {}),
      runtimeGeneration: this.runtimeGeneration,
      ...(leafEntryId ? { leafEntryId } : {}),
    };
  }

  get cwd(): string {
    return this.sessionManager.getCwd();
  }

  /** The Project root the live runtime loaded its Project layer from. Trust and
   * Project-layer reloads address every chat of one root together. */
  get projectDir(): string {
    return this.runtime.session.projectDir;
  }

  get modelRuntime(): ModelRuntime {
    this.assertNoTrustReload();
    return this.runtime.session.modelRuntime;
  }

  /** A Home chapter has the Home recipe and no Project layer (settings-model.md 3.3). */
  get isHomeChapter(): boolean {
    // Creation-time Home is already isolated before its designation record is
    // committed. Settings/provenance must use that same runtime scope.
    return this.liveProfile().chapter || this.dependencies.lineageState(this.id).lineageId !== undefined;
  }

  /** Home's saved settings govern only a runtime running the Home profile; a
   * disabled Home's session is an ordinary session with its own Session scope. */
  get usesHomeSettings(): boolean {
    return this.liveProfile().chapter;
  }

  /** The `settings` tool's view of this chat (settings-model.md 5.1). It runs inside the run that
   * holds the lane, so lane setters refuse rather than wait; Home's `taskId` targets that worker (#1336). */
  private settingsToolAccess(): SettingsToolAccess | undefined {
    const owners = this.dependencies.settings();
    if (!owners) return undefined;
    const target = { kind: "session" as const, sessionId: this.id };
    const busy = (): never => { throw new GatewayError("busy", "This chat's own Session-scope settings change between runs, not during one"); };
    const source = () => ({
      ...this.settingsSource(),
      appliers: {
        setModel: busy, setThinking: busy, setContextWindow: busy, setTools: busy,
        // This tool already owns the running lane. It records the override;
        // request admission applies it, never a mutation of the active request.
        setSetting: (key: string, value: unknown, allowFixedDirection: boolean, fixedAt?: FixedSetting) => this.persistChatRunSetting(key, value, allowFixedDirection, fixedAt),
      },
    });
    const actor = (toolCallId: string): Actor => {
      const profileActor = this.liveProfile().settingsActor;
      const kind = profileActor === "agent" && this.taskWorker ? "worker" : profileActor;
      return { kind, id: this.id, sessionId: this.id, toolCallId, ...(this.taskWorker ? { taskId: this.taskWorker.identity.taskId } : {}) };
    };
    const worker = async (taskId: string, purpose: "resolve" | "change") => {
      if (!this.liveProfile().workerSettings) {
        throw new GatewayError("invalid_request", "settings: taskId targets a delegated worker and is available only in Tron Home");
      }
      const { slot, ...task } = await this.dependencies.homeTaskSettings(this.id, taskId, purpose);
      return { task, slot, target: { kind: "session" as const, sessionId: task.sessionId } };
    };
    return {
      resolve: async (keys, taskId) => {
        if (taskId === undefined) return owners.model.resolve(target, source(), keys);
        const { task, slot, target: workerTarget } = await worker(taskId, "resolve");
        const resolution = await owners.model.resolve(workerTarget, slot.taskWorkerSettingsSession(), keys);
        return { ...resolution, worker: { ...task, ...slot.taskWorkerSettingsState() } };
      },
      change: async (changes, input) => {
        if (input.taskId === undefined) {
          return owners.changes.change(target, changes, {
            actor: actor(input.toolCallId), reason: input.reason, web: input.web, session: source(),
            // Home's own tool already owns its running lane: the saved change takes
            // effect through the same in-turn appliers as an ordinary chat's.
            ...(this.usesHomeSettings ? { homeChapter: { ...this.settingsSource(), sessionId: this.id, mutate: operation => operation({ appliers: source().appliers }) } } : {}),
            ...(input.dryRun ? { dryRun: true } : {}),
          });
        }
        const { task, slot, target: workerTarget } = await worker(input.taskId, "change");
        const result = await owners.changes.change(workerTarget, changes, {
          // Home is the requester: approval outcomes return to Home's session, the task names the worker.
          actor: { kind: "home", id: this.id, sessionId: this.id, toolCallId: input.toolCallId, taskId: task.taskId },
          reason: input.reason, web: input.web, session: slot.taskWorkerSettingsSession(),
          ...(input.dryRun ? { dryRun: true } : {}),
        });
        return { ...result, worker: { ...task, ...slot.taskWorkerSettingsState() } };
      },
      takeOutcomes: () => owners.changes.takeOutcomes(this.id),
    };
  }

  /** This worker's Session scope and lane appliers for Home's `settings` tool (#1336): no client
   * fence (the caller resolved this slot); a running worker hears changes through `announce`. */
  taskWorkerSettingsSession(): SessionSettingsSource & { appliers: SessionAppliers } {
    return {
      ...this.settingsSource(),
      appliers: {
        setModel: (ref, fixedAt) => this.setModel(ref.provider, ref.id, undefined, undefined, fixedAt),
        setThinking: (level, fixedAt) => this.setThinking(level as ThinkingLevel, undefined, undefined, fixedAt),
        setContextWindow: (model, value, fixedAt) => this.setContextWindow(model.provider, model.id, value, this.revision, this.runtimeGeneration, undefined, fixedAt),
        setTools: (tools, fixedAt) => this.setTools(tools, undefined, fixedAt),
        setSetting: (key, value, allowFixedDirection, fixedAt) => this.setChatRunSetting(key, value, undefined, undefined, allowFixedDirection, fixedAt),
        announce: (notice) => this.announceSettingsChange(notice),
      },
    };
  }

  /** Home's view of a worker (#1336): `selected` drives the next request; `lastResponse` is what
   * the latest reply ran on, so a difference while `running` applies from the next request. */
  taskWorkerSettingsState(): TaskWorkerSettingsState {
    const session = this.runtime.session;
    const last = session.messages.findLast(message => message.role === "assistant");
    return {
      running: this.liveTaskConfiguration(),
      selected: { model: session.model ? `${session.model.provider}/${session.model.id}` : null, thinking: session.thinkingLevel },
      lastResponse: last?.role === "assistant"
        ? { model: `${last.provider}/${last.model}`, thinking: last.thinkingLevel ?? null, at: new Date(last.timestamp).toISOString() }
        : null,
    };
  }

  /** One steer in the worker's ordered steering lane (#1336), read at the boundary whose request
   * first uses the change. Never throws: the change is stored, so a refused steer is reported. */
  async announceSettingsChange(notice: SettingsNotice): Promise<SettingsSignal | undefined> {
    const worker = this.taskWorker;
    if (!worker) return undefined;
    const taskId = worker.identity.taskId;
    if (!this.liveTaskConfiguration()) return { status: "not-running", taskId, appliesFrom: "next-run" };
    const by = notice.actor.kind === "home" ? "Tron Home" : notice.actor.kind === "ui" ? "The maintainer" : notice.actor.kind === "worker" ? "This worker" : "An agent";
    const when = (effect: string) => effect === "next-turn" || effect === "next-request" ? "from your next model request"
      : effect === "next-compaction" ? "at the next compaction" : `at its effect point (${effect})`;
    const text = [
      `[Tron settings] ${by} changed this session's settings${notice.approved ? " (approved by the maintainer)" : ""} while you work on task ${taskId}${notice.reason ? `. Reason: ${notice.reason}` : ""}.`,
      ...notice.changes.map(change => `- ${change.label}: ${change.before === undefined ? "changed" : `${change.before} → ${change.after}`} (${when(change.effect)}; change ${change.changeId}).`),
      "The response in progress when this arrived kept its earlier settings. The same session, worktree and task continue; no reply is needed.",
    ].join("\n");
    try {
      const control = { taskId, operationId: worker.identity.operationId };
      const { operationId } = await this.prompt(text, [], "steer", undefined, undefined, {
        operationId: randomUUID(), taskFence: control,
        origin: { kind: "gateway", ownerId: taskId, title: "Settings changed", confidence: "boundary" }, onTerminal: () => {},
      });
      return { status: "queued", taskId, operationId, appliesFrom: "next-request" };
    } catch (error) {
      const code = error instanceof GatewayError ? error.code : "internal";
      return { status: "failed", taskId, appliesFrom: "next-request", error: { code, message: error instanceof Error ? error.message : String(error) } };
    }
  }

  /** The tools this chat's selection may name: its registry, less hidden tools
   * (`setTools` refuses those). */
  settingsToolCatalog(): Array<{ name: string; description?: string; resource: Record<string, unknown> }> {
    this.assertNoTrustReload();
    return this.runtime.session.getAllTools().filter(tool => tool.exposure !== "hidden")
      .map(tool => {
        const distribution = resourceDistribution(tool.sourceInfo);
        return {
          name: tool.name,
          ...(tool.description ? { description: tool.description } : {}),
          resource: {
            name: tool.name,
            ...(this.toolLabel(tool.name) ? { label: this.toolLabel(tool.name)! } : {}),
            description: tool.description,
            parameters: tool.parameters,
            source: tool.sourceInfo.source,
            ...(distribution ? { distribution } : {}),
            ...(tool.namespace ? { namespace: tool.namespace } : {}),
          },
        };
      });
  }

  /** This chat's resolver input, with `session` standing in for its Session scope. */
  settingsSource(session: SessionStore = this.settingsSessionLayer()): SessionSettingsSource {
    return { cwd: this.cwd, home: this.usesHomeSettings, session, modelRuntime: this.runtime.session.modelRuntime };
  }

  /** Requested choices come from canonical explicit/delegated evidence, not
   * an operational Project selection that currently masks those choices. */
  settingsSessionLayer(): SessionStore {
    this.assertNoTrustReload();
    const session = this.runtime.session;
    const policy = this.contextPolicies.get(session)?.snapshot();
    const branch = session.sessionManager.getBranch();
    const fixed = readSessionFixedSettings(branch);
    const modelChoice = fixed["model.ref[role=chat]"];
    const choiceIndex = modelChoice ? branch.findIndex(entry => entry.type === "custom" && entry.customType === SESSION_SETTINGS_ENTRY
      && (entry.data as { fixed?: Record<string, { ref: string }> } | null)?.fixed?.["model.ref[role=chat]"]?.ref === modelChoice.ref) : -1;
    const choice = (key: string, runtime: unknown) => !fixed[key] ? runtime : fixed[key].from === "session" || fixed[key].from === "delegate" ? fixed[key].value : undefined;
    const model = readWorkerQueueSelection(branch, choiceIndex) ?? choice("model.ref[role=chat]",
      session.model && { provider: session.model.provider, id: session.model.id }) as { provider: string; id: string } | undefined;
    const thinking = choice("model.thinking[role=chat]", session.thinkingLevel) as string | undefined;
    return {
      ...(model ? { model } : {}),
      ...(thinking ? { thinking } : {}),
      ...(policy && policy.override !== null ? { contextWindow: { model: `${policy.model.provider}/${policy.model.id}`, value: policy.override } } : {}),
      tools: session.getActiveToolNames(),
      settings: readSessionSettings(branch),
      requestPins: readSessionRequestPins(branch),
      fixed,
    };
  }

  public async applyLiveRunSettings(session: AgentSession): Promise<ReturnType<SettingsManager["getSettings"]> | undefined> {
    const owners = this.dependencies.settings();
    if (!owners) return;
    if (this.runtime.session !== session) throw new GatewayError("conflict", "Runtime changed before settings application");
    const branch = session.sessionManager.getBranch();
    const previousPins = readSessionRequestPins(branch);
    const explicitSettings = readSessionSettings(branch);
    const { requestPins: _pins, ...chat } = this.settingsSessionLayer();
    const { settings, requestPins, admission } = await owners.model.requestSettings(this.id, this.settingsSource({ ...chat, settings: explicitSettings }), previousPins);
    if (this.runtime.session !== session) throw new GatewayError("conflict", "Runtime changed during settings resolution");
    if (JSON.stringify(previousPins) !== JSON.stringify(requestPins)) {
      await this.persistSessionSettings({ settings: explicitSettings, requestPins });
    }
    await applyModelAdmission(session, admission, Boolean(this.taskWorker) || this.liveProfile().physicalModelsOnly === true);
    if (this.runtime.session !== session) throw new GatewayError("conflict", "Runtime changed during model admission");
    session.settingsManager.applyOverrides(settings);
    // These SDK controls are copied when Agent is created, not read from its
    // SettingsManager during queue draining. Never use setters that save defaults.
    session.agent.steeringMode = session.settingsManager.getSteeringMode();
    session.agent.followUpMode = session.settingsManager.getFollowUpMode();
    session.agent.transport = session.settingsManager.getTransport();
    session.agent.maxRetryDelayMs = session.settingsManager.getProviderRetrySettings().maxRetryDelayMs;
    return settings;
  }

  private async persistChatRunSetting(key: string, value: unknown, allowFixedDirection: boolean, fixedAt?: FixedSetting): Promise<number> {
    this.assertChapterWritable();
    const branch = this.sessionManager.getBranch();
    const settings = changeSessionSetting(readSessionSettings(branch), key, value);
    const fixed = readSessionFixedSettings(branch);
    if (schemaKey(key).timing === "fixed") {
      fixed[key] = { ...(fixedAt ?? { from: "session", at: new Date().toISOString(), ref: randomUUID() }), value };
    }
    const requestPins = readSessionRequestPins(branch);
    // Tier admission and timing are separate: lowering a floor must not make
    // an unapproved widening live. Only an approval or the maintainer's tap
    // releases the fixed-direction snapshot (including Follow the default).
    if (typeof schemaKey(key).timing !== "string" && allowFixedDirection) {
      const owners = this.dependencies.settings();
      if (!owners) throw new GatewayError("conflict", "Settings owner is unavailable");
      const { requestPins: _pins, ...chat } = this.settingsSessionLayer();
      const resolved = await owners.model.resolve({ kind: "session", sessionId: this.id }, this.settingsSource({ ...chat, settings }), [key]);
      const row = resolved.keys[0];
      if (!row) throw new GatewayError("conflict", "Settings default is unavailable");
      requestPins[key] = { value: row.value, from: row.layer, at: new Date().toISOString(), ref: randomUUID(), ...(row.qualifiers ? { qualifiers: row.qualifiers } : {}) };
    }
    await this.persistSessionSettings({ settings, requestPins, fixed });
    // The compaction projection follows the Session value at once; its budgets
    // reach the SDK at the next idle admission (refreshCompactionPolicy).
    if (hasCompactionApplier(schemaKey(key))) {
      try { this.compactionPolicies.get(this.runtime.session)?.refresh(); } catch { /* Published warning is authoritative. */ }
    }
    this.revision += 1;
    this.publishSnapshot();
    return this.revision;
  }

  /** Drop a fixed widening pin only after an approved/tapped default change.
   * The canonical chat entry makes the release survive a cold resume; explicit
   * Session values remain the source of truth and are never touched. */
  async releaseInheritedImageBlock(layer: "global" | "project"): Promise<void> {
    await this.lane.run(async () => {
      if (this.isDisposed) return;
      const branch = this.sessionManager.getBranch();
      const pins = readSessionRequestPins(branch);
      const pin = pins["context.images.block"];
      if (!pin || pin.value !== true) return;
      const explicit = readSessionSettings(branch);
      const images = explicit.images;
      if (images && typeof images === "object" && Object.prototype.hasOwnProperty.call(images, "blockImages")) return;
      const owners = this.dependencies.settings();
      if (!owners) return;
      const { requestPins: _pins, ...chat } = this.settingsSessionLayer();
      const resolved = await owners.model.resolve({ kind: "session", sessionId: this.id }, this.settingsSource(chat), ["context.images.block"]);
      const row = resolved.keys[0];
      // Approval of a lower layer is not approval to release a higher layer's
      // fixed policy, even if that higher store is subsequently edited outside Tron.
      if (row?.value !== false || row.layer === "session"
        || (layer === "global" && row.layer === "project")) return;
      delete pins["context.images.block"];
      await this.persistSessionSettings({ settings: explicit, requestPins: pins });
    });
  }

  async setChatRunSetting(key: string, value: unknown, initiatingWorkToken?: string,
    expectation?: { runtimeGeneration: string; model: { provider: string; id: string } | null }, allowFixedDirection = false, fixedAt?: FixedSetting): Promise<number> {
    if (this.usesHomeSettings && this.dependencies.settings()) return this.changeHomeRecipe(key, value, initiatingWorkToken);
    return this.lane.run(async () => {
      this.assertConfigurationAdmissible(initiatingWorkToken);
      if (expectation) this.assertConfigurationExpectation(expectation);
      return this.persistChatRunSetting(key, value, allowFixedDirection, fixedAt);
    });
  }

  /** Actionable work only; decorative presentation must not block trust/delete.
   * True from slot admission, which precedes the SDK's agent admission: a Stop in
   * that window revokes the prompt. A test that Stops a run waits for the run's own
   * entry, not for this. */
  get isBusy(): boolean {
    return this.isBusyExceptWorkToken();
  }
  isBusyExceptWorkToken(exceptWorkToken?: string): boolean {
    return this.runPersistence.hasBlockedOwnershipWrite
      || this.lifecycle.preventsNonRuntimeQuiescence
      || this.hasRuntimeWork(exceptWorkToken)
      || this.runAttention.pendingAssistantCompletion !== undefined
      || this.activeExports > 0
      || this.retainedLeaseCount > 0;
  }
  /** Why this session cannot be archived right now. Archive admission uses the
   * same ownership rule as delete (`isBusyExceptWorkToken`); the split is only
   * about retryability, so a client is not told to stop a session that is only
   * waiting on another request. A concurrent request's work entry or an
   * in-flight export clears by itself, while a blocked ownership write, detached
   * work, a pending completion or a retained lease is real activity. */
  archiveBlocker(exceptWorkToken?: string): "none" | "transient" | "active" {
    if (this.runPersistence.hasBlockedOwnershipWrite
      || this.lifecycle.preventsNonRuntimeQuiescence
      || this.hasDetachedDashboardWork()
      || this.runAttention.pendingAssistantCompletion !== undefined
      || this.retainedLeaseCount > 0) return "active";
    return this.dependencies.workRegistry.hasSessionWork(this.id, exceptWorkToken) || this.activeExports > 0
      ? "transient"
      : "none";
  }
  /** Retained operation and exact automation leases protect automatic idle eviction. */
  get isEvictionProtected(): boolean { return this.runPersistence.hasBlockedOwnershipWrite || this.lifecycle.preventsEviction || this.retainedLeaseCount > 0; }

  retainLease(): () => void {
    this.assertUsable();
    this.retainedLeaseCount += 1;
    this.touch();
    let released = false;
    return () => {
      if (released) return;
      released = true;
      this.retainedLeaseCount = Math.max(0, this.retainedLeaseCount - 1);
      this.touch();
    };
  }
  /** Archive idle admission and its durable commit inside ONE lane critical
   * section. This lane is the exact boundary that Gateway-admitted runs enter,
   * so no prompt, Bash call or compaction can start between the idle check and
   * the archive commit: whichever of the two enters the lane first decides, and
   * the other observes it. It cannot cover a turn Pi starts on its own (an
   * extension `triggerTurn` never enters this lane); the registry restores the
   * row if such a run is live when the record lands. `exceptWorkToken` is the
   * archiving request's own work, which is not the session running. */
  async commitArchiveWhileIdle<T>(exceptWorkToken: string | undefined, commit: () => Promise<T>): Promise<T> {
    return this.lane.run(async () => {
      this.assertUsable();
      this.assertChapterWritable();
      this.assertArchivable(exceptWorkToken);
      return commit();
    });
  }

  /** Shared by archive admission's pre-lane check and its in-lane commit, so
   * both report the same reason and retryability for the same state. */
  assertArchivable(exceptWorkToken?: string): void {
    const blocker = this.archiveBlocker(exceptWorkToken);
    if (blocker === "transient") throw new GatewayError("busy", "Another request is using this session", true);
    if (blocker === "active") {
      throw new GatewayError("busy", "Stop the session before archiving it", false, undefined, "session_operation_busy");
    }
  }

  /** Administrative drain blockers plus session work entries, optionally
   * ignoring the caller's own entry. A receipt-backed RPC holds one
   * `rpc-mutation` session work entry for its whole operation, so an idle check
   * that counted it would always reject the very request that owns it. Nothing
   * else is excluded: another request's entry and administrative drain blockers
   * still make the session busy. */
  public drainBusyExcept(exceptWorkToken?: string): boolean {
    return this.dependencies.workRegistry.hasSessionWork(this.id, exceptWorkToken)
      || this.administrativeDrainBlockers().length > 0;
  }

  get isDrainBusy(): boolean {
    return this.drainBusyExcept();
  }

  administrativeDrainBlockers(): RuntimeDrainBlockerFact[] {
    const facts: RuntimeDrainBlockerFact[] = [];
    for (const [key, write] of this.runPersistence.durableWrites) {
      if (write.blocked) facts.push({
        category: "terminal-receipt-persistence", key: `canonical:${key}`, state: "suspect", admittedAt: write.admittedAt,
      });
    }
    for (const activity of this.extensionActivities.values()) {
      if (this.extensionActivityOwnsLiveWork(activity)) {
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



  administrativeSuspectForegroundWorkTokens(): ReadonlySet<string> {
    return this.runWork.administrativeSuspectForegroundWorkTokens();
  }

  private hasRuntimeWork(exceptWorkToken?: string): boolean {
    return this.dependencies.workRegistry.hasSessionWork(this.id, exceptWorkToken)
      // Detached nonterminal extension work remains the explicit compatibility
      // authority until the extension host offers direct registration tokens.
      || this.hasDetachedDashboardWork();
  }

  /** User-visible detached activity only. Durable receipt persistence and other
   * administrative work can keep operational drain busy but must not leave a
   * dashboard row stuck in the running phase. A settled paused run owns no live
   * process, so it stops being live work and a drain blocker. */
  public hasDetachedDashboardWork(): boolean {
    return this.liveExtensionActivities().length > 0;
  }

  /** The activities that own live work under the one liveness rule below. Dashboard
   * accounting, drain, settlement and the report gate all read this list. */
  private liveExtensionActivities(): ExtensionRunActivity[] {
    return [...this.extensionActivities.values()].filter(activity => this.extensionActivityOwnsLiveWork(activity));
  }

  /** The live subagent runs this worker shows in task status. Read from the same live
   * projection as the report gate and settlement, never persisted. The run id is the
   * provider's; a run not yet published is identified by its launch call. */
  liveSubagentRuns(): HomeTaskSubagentRun[] {
    return this.liveExtensionActivities().flatMap(activity => this.liveActivitySubagentRuns(activity));
  }

  /** Status, report admission and Stop select the same exact executions. A completed
   * workflow is not stoppable: its live detached children must be named instead. */
  private liveActivitySubagentRuns(activity: ExtensionRunActivity): HomeTaskSubagentRun[] {
    if (this.extensionActivityOwnsOwnLiveWork(activity)) return [{
      runId: activity.runId ?? activity.toolCallId,
      agent: activity.children[0]?.label ?? activity.title,
      state: activity.lifecycle?.state ?? activity.status,
      startedAt: activity.startedAt,
      lastActivityAt: activity.lastActivityAt ?? null,
    }];
    const detached = activity.runId === undefined ? undefined : this.extensionRunOwnership.get(activity.runId)?.detachedChildKeys;
    return this.liveWorkflowChildren(activity).flatMap(child => {
      const runId = detached?.get(child.producerId ?? child.id);
      return runId === undefined ? [] : [{ runId, agent: child.label, state: child.lifecycle ?? child.status,
        startedAt: child.startedAt ?? activity.startedAt, lastActivityAt: child.lastActivityAt ?? null }];
    });
  }

  /** One liveness rule for detached extension work, shared by dashboard
   * accounting, administrative drain and task settlement. An async run is live
   * while it is, and also while a workflow child it launched is: a workflow can
   * complete while its detached children keep running. */
  private extensionActivityOwnsLiveWork(activity: ExtensionRunActivity): boolean {
    return this.extensionActivityOwnsOwnLiveWork(activity) || this.liveWorkflowChildren(activity).length > 0;
  }

  private extensionActivityOwnsOwnLiveWork(activity: ExtensionRunActivity): boolean {
    const state = activity.lifecycle?.state;
    if (state === "queued" || state === "running") return true;
    if (state !== "paused") return false;
    return this.pausedProcessSettlementAt(activity) === undefined;
  }

  /** Live runner-backed workflow children of a run, in the states of the run itself.
   * A child's state is its lifecycle when projected, else its coarse status. Their
   * exact-owned paused-process proof is admitted with the detached-child binding,
   * never copied from untrusted tool-result presentation fields. */
  private liveWorkflowChildren(activity: ExtensionRunActivity): ExtensionRunChild[] {
    const detached = activity.runId === undefined ? undefined : this.extensionRunOwnership.get(activity.runId)?.detachedChildKeys;
    if (!detached?.size) return [];
    return activity.children.filter(child => {
      const state = child.lifecycle ?? child.status;
      return detached.has(child.producerId ?? child.id) && (state === "queued" || state === "running" || state === "paused");
    });
  }

  /** A run stays observed while it is running or a runner-backed child is live, so the
   * child's own status change still reaches the projection and the join. */
  private extensionActivityWatchRequired(activity: ExtensionRunActivity): boolean {
    return activity.status === "running" || this.liveWorkflowChildren(activity).length > 0;
  }

  /** The Gateway-admitted settlement instant of one paused activity, recorded
   * when its artifact frame proved every process had exited. */
  private pausedProcessSettlementAt(activity: ExtensionRunActivity): string | undefined {
    if (activity.lifecycle?.state !== "paused" || !activity.runId) return undefined;
    const ownership = this.extensionRunOwnership.get(activity.runId);
    return ownership?.toolCallId === activity.toolCallId ? ownership.pausedProcessQuiescentAt : undefined;
  }

  /** AgentSession can start an extension-triggered continuation while an older
   * `agent_settled` callback is still unwinding. AgentSession's full streaming
   * lifecycle is the authoritative foreground owner in that overlap. */
  public get hasActiveAgentRun(): boolean {
    const session = this.runtime?.session;
    return session?.isStreaming === true || session?.state.isStreaming === true;
  }


  public waitForStateChange(): Promise<void> {
    return new Promise((resolve) => { this.stateChangeWaiters.add(resolve); });
  }

  private publishStateChange(): void {
    this.publishConfiguration();
    const waiters = [...this.stateChangeWaiters];
    this.stateChangeWaiters.clear();
    for (const resolve of waiters) resolve();
    this.heldQueue.scheduleHeldPromptFlush();
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

  public hasCurrentDashboardWork(): boolean {
    const phase = this.dashboardPhase;
    return phase === "running" || phase === "compacting" || phase === "retrying";
  }

  public noteDashboardActivity(at = new Date().toISOString()): void {
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

  /** Lightweight dashboard projection. Catalog listing must not construct a
   * transcript-bearing session snapshot merely to read runtime activity. */
  get catalogPhase(): SessionPhase {
    return this.dashboardPhase;
  }

  /** Narrow foreground truth for dashboard clients that distinguish a settled
   * parent agent from detached subagents that are still running. */
  get catalogForegroundPhase(): SessionPhase {
    return this.effectivePhase;
  }

  get catalogHasActiveSubagents(): boolean {
    return this.hasDetachedDashboardWork();
  }

  get catalogWaitingForUser(): boolean {
    return this.ui.hasPendingInteractions;
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

  /** The name `snapshot()` projects, without building a snapshot: list rows read it per task (#905). */
  get displayName(): string | undefined {
    return this.isHomeChapter ? "Home" : this.runtime.session.sessionName || undefined;
  }

  get canonicalEntryCount(): number {
    return this.runtime.session.sessionManager.getEntries().length;
  }

  /** Pi may reserve a future JSONL path before writing its first user or
   * assistant message. Catalog membership treats only an existing file as persisted. */
  get persistedSessionFile(): string | undefined {
    const path = this.runtime.session.sessionFile;
    return path && existsSync(path) ? path : undefined;
  }

  private refreshDisplayReferences(): void {
    const manager = this.runtime.session.sessionManager;
    const leafID = manager.getLeafId();
    const key = `${manager.getSessionId()}\0${leafID ?? "root"}`;
    if (this.displayArtifactReferenceKey !== key) {
      const branch = leafID ? manager.getBranch(leafID) : [];
      const references = this.dependencies.modules.policy("toolResultProjection")?.().references(branch, manager.getSessionId());
      this.displayArtifactReferences = references?.artifacts ?? [];
      this.browserLiveReferences = references?.liveViews ?? new Set();
      this.displayArtifactReferenceKey = key;
    }
  }

  displayArtifactIDs(): string[] {
    this.refreshDisplayReferences();
    return [...this.displayArtifactReferences];
  }

  referencesDisplayArtifact(artifactID: string): boolean {
    this.refreshDisplayReferences();
    return this.displayArtifactReferences.includes(artifactID);
  }

  referencesBrowserLiveView(viewId: string, generation: string): boolean {
    // Cache only admitted canonical display references for this exact leaf;
    // arbitrary tool details cannot grant live-view access.
    this.refreshDisplayReferences();
    return this.browserLiveReferences.has(`${viewId}\0${generation}`);
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

  /** Records decide at each runtime build and canonical append. Only an
   * unrecorded id may use its one-shot creation recipe; never a fork/reset id. */
  private profileFor(sessionManager: SessionManager): SessionProfile {
    const sessionId = sessionManager.getSessionId();
    const decision = this.dependencies.modules.policy("profileDecision")?.(sessionId, sessionManager.getCwd()) ?? "unrecorded";
    return decision === "unrecorded"
      ? this.explicitProfile?.sessionId === sessionId ? this.explicitProfile.profile : ORDINARY_SESSION_PROFILE
      : this.dependencies.modules.profile(decision);
  }

  /** The profile the live runtime was built with, not a fresh record decision. */
  public liveProfile(): SessionProfile {
    return this.runtimeProfiles.get(this.runtime.session) ?? ORDINARY_SESSION_PROFILE;
  }

  private runtimeFactory(): CreateAgentSessionRuntimeFactory {
    return async ({ cwd, sessionManager, sessionStartEvent }) => {
      this.installCanonicalWriteGuard(sessionManager);
      const trust = await this.dependencies.trust.requireResolved(cwd);
      // A ModelRuntime is scoped to one Pi session runtime. Extension provider
      // registration is mutable, so sharing one instance across projects would
      // leak project providers between concurrent Tron sessions. Credentials and
      // model files remain canonical through their shared file paths.
      // Home is the exception: it loads no project or package code, so nothing
      // can register a provider into its runtime, and it runs on the Gateway-wide
      // runtime where `home.designate` admitted its model and user provider
      // packages such as CortexKit's are registered (#480).
      const profile = this.profileFor(sessionManager);
      const binding = profile.modelRuntime === "gateway"
        ? await profile.acquireModelRuntime()
        : { runtime: await this.dependencies.createModelRuntime(), ownership: "owned" as const };
      const modelRuntime = binding.runtime;
      const requestPipeline = new RunRequestPipeline(modelRuntime);
      const modelRuntimePolicy = this.dependencies.modules.policy("modelRuntimeInstalled")?.();
      // Only the ModelRuntime owner installs filters. Home's borrowed view reads
      // the Gateway's installation without wrapping its providers on rebuild.
      const detachOpenAIEligibility = binding.ownership === "owned"
        ? modelRuntimePolicy?.attach(modelRuntime)
        : undefined;
      this.detachOpenAIEligibility?.();
      this.detachOpenAIEligibility = detachOpenAIEligibility;
      let contextPolicy: SessionContextWindowPolicy | undefined;
      let compactionPolicy: CompactionOperationPolicy | undefined;
      this.resourceReloadOptions = {
        // Reload must re-read the canonical decision. Capturing the value from
        // runtime creation would leave project code loaded after trust changes.
        // Home's project layer is never trusted: its loader sees only user-level
        // skills and prompt templates, never project `.pi/` or `.agents/` ones.
        resolveProjectTrust: profile.projectTrust === "never"
          ? async () => false
          : async () => (await this.dependencies.trust.inspect(trust.cwd)).effectiveDecision === true,
      };
      // One-shot: a brand-new Home session's first runtime carries the explicit
      // profile; every later runtime asks the record.
      this.explicitProfile = undefined;
      const sessionContext: SessionContext = {
        sessionId: () => this.id,
        cwd: () => this.cwd,
        modelRuntime, profile: () => this.liveProfile(),
        title: () => this.notificationTitle(),
        // Notify samples automatic alerts' foreground lease at its own admission.
        presented: () => this.dependencies.isSessionPresented(this.id),
        contextPolicy: () => contextPolicy,
        compaction: {
          policy: () => compactionPolicy,
          // Summary auth can finish after Stop, before display-ID rotation; keep automatic work's prompt fence.
          stopped: (event) => (this.operation?.id !== undefined && this.runAbort.abortedOperations.has(this.operation.id))
            || (event.reason !== "manual" && this.activeOperationId !== undefined && this.runAbort.abortedOperations.has(this.activeOperationId)),
          changed: () => { this.revision += 1; this.publishSnapshot(); },
        },
        joinTerminalReceiptWrites: () => this.runInvocations.joinTerminalReceiptWrites(),
        settings: () => this.settingsToolAccess(),
      };
      // Tron Home's curated profile: no agent-directory or project discovery,
      // Pi built-ins (codemode, tool-search, MCP) excluded, and only the kept
      // Tron modules plus tron-home.
      // Home delegates only through Home tasks, never through managed pi-subagents.
      const managedSubagents = profile.managedSubagents ? this.dependencies.managedSubagents : undefined;
      // The Project layer is the root's `.pi/` (settings-model decision 31); the
      // chat keeps its cwd for tools, context files and session grouping.
      const settingsManager = await createSettingsManager(trust.projectDir, this.dependencies.agentDir, profile.projectSettings && trust.trusted);
      const managedLoaderOptions = await managedSubagents?.loaderOptions(settingsManager,
        (content, options, owner, messages) => this.admitSubagentWake(content, options, owner, messages));
      const extensionFactories = profile.extensions !== "ordinary"
        ? this.dependencies.modules.registrations(profile.extensions, sessionContext)
        : [
            ...(managedLoaderOptions?.extensionFactories ?? []),
            ...piBuiltinExtensions(this.dependencies.agentDir, (url) => {
              const operationId = currentMcpAuthOperationId();
              if (!operationId || !this.dependencies.mcpAuth) {
                throw new Error("MCP authorization URL has no active Tron sign-in operation");
              }
              const target = currentMcpAuthTarget();
              if (!target?.sessionId || !target.server || target.sessionId !== this.id) {
                throw new Error("MCP authorization URL does not match the active session operation");
              }
              this.dependencies.mcpAuth.openUrl(operationId, url, this.id, target.server);
            }),
            ...tronModuleFactories(this.dependencies.modules, sessionContext),
            ...(this.dependencies.modelQueue ? [{ name: "tron-model-queue", factory: modelQueueSessionExtension({
              source: this.dependencies.modelQueue.source(role => this.taskQueueSelection(role)), worker: Boolean(this.taskWorker),
              publishProjection: () => {
                const queue = this.taskQueueSelection("subagent");
                return this.dependencies.modelQueue!.publishProjection(queue === undefined ? undefined : { sessionId: this.id, queue });
              },
              releaseProjection: () => this.dependencies.modelQueue!.releaseTaskProjection(this.id),
              taskChildExtension: (implementation: string) => this.taskQueueSelection("subagent") === undefined
                ? Promise.resolve(implementation) : this.dependencies.modelQueue!.taskChildExtension(this.id, implementation),
              ...(managedSubagents ? { requireChildExtensions: (sessionId: string, extensions: readonly { id: string; path: string }[]) =>
                managedSubagents.requireChildExtensions(sessionId, extensions) } : {}),
            }) }] : []),
            ...(this.taskWorker ? [{ name: "tron-home-task-worker", factory: createHomeTaskWorkerExtension({
              providerVersion: toolName => delegatedProviderToolVersion(this.runtime?.session.resourceLoader.getExtensions().extensions ?? [], toolName),
              refused: reason => this.dependencies.homeTaskDiagnostic?.({ event: "home.task.producer-refused",
                taskHash: createHash("sha256").update(this.taskWorker!.identity.taskId).digest("hex").slice(0, 16), reason }),
              reportSealed: () => this.taskWorker!.reportSealed,
              ownsSubagentRun: runId => this.ownsSubagentRun(runId),
              ownsSupervisorRequest: requestId => this.ownsSupervisorRequest(requestId),
            }) }] : []),
          ];
      const services = await createAgentSessionServices({
        settingsManager: managedLoaderOptions?.settingsManager ?? settingsManager,
        cwd: trust.cwd,
        projectDir: trust.projectDir,
        agentDir: this.dependencies.agentDir,
        modelRuntime,
        resourceLoaderOptions: {
          ...(managedLoaderOptions ?? {}),
          ...profile.resources,
          extensionFactories,
          extensionsOverride: (base) => attributeExtensions(base,
            this.dependencies.modules.policy("toolResultProjection")?.().beginBrowserLoad(sessionManager.getSessionId(), this.runtimeGeneration),
            { requireTronAskUser: true, ...(managedSubagents ? { managedSubagents } : {}) }),
        },
        resourceLoaderReloadOptions: this.resourceReloadOptions,
      });
      // Only the loader keeps the read-only package view. Session settings
      // mutations keep their canonical owner, never the filtered projection.
      services.settingsManager = settingsManager;
      await managedSubagents?.completeLoad(settingsManager, this.cwd, this.dependencies.agentDir, services.resourceLoader.getExtensions().extensions);
      // A runtime replacement must never strand a process owned by the outgoing
      // tool registry. Session replacement normally aborts Pi first; this exact
      // owner handoff is the independent fail-safe when that signal was stale.
      if (this.directBashProcesses?.hasActiveProcesses) {
        await this.directBashProcesses.abortAll();
      }
      const directBashProcesses = profile.directBash ? new DirectBashProcessOwner(services.settingsManager, sessionManager.getSessionId()) : undefined;
      this.directBashProcesses = directBashProcesses;
      let initialModel: Model<never> | undefined;
      if (sessionManager.getEntryCount() === 0) {
        initialModel = await modelRuntimePolicy?.initialModel(modelRuntime, services.settingsManager);
      }
      const startsNewChat = sessionManager.getEntryCount() === 0;
      // Pi treats a metadata-only chapter as new because it has no messages.
      // Canonical thinking is nevertheless an existing Session choice, not a default.
      const recordedThinking = sessionManager.getBranch().some(entry => entry.type === "thinking_level_change");
      const settingsOwner = this.dependencies.settings();
      const launchDefaults = startsNewChat && settingsOwner ? await settingsOwner.model.resolve(
        { kind: "session", sessionId: sessionManager.getSessionId() },
        { cwd: trust.cwd, home: profile.launchDefaults === "settings-home-recipe", session: { settings: {} }, modelRuntime },
        ["model.ref[role=chat]", "model.thinking[role=chat]", "tools.active"], { storeState: false },
      ) : undefined;
      const profileModel = launchDefaults?.keys.find(row => row.key === "model.ref[role=chat]" && row.layer === "session")?.value as { provider: string; id: string } | undefined;
      const selectedProfileModel = profile.launchDefaults === "settings-home-recipe" && profileModel
        ? modelRuntime.getPhysicalModel(profileModel.provider, profileModel.id) : undefined;
      if (profileModel && profile.launchDefaults === "settings-home-recipe" && !selectedProfileModel) throw new GatewayError("conflict", "Home's configured profile model is unavailable or virtual");
      // Pass the scope-resolved launch thinking explicitly: the SDK's merged
      // per-model map otherwise lets a Global value outrank a Project plain value.
      const launchThinking = launchDefaults?.keys.find(row => row.key === "model.thinking[role=chat]")?.value as ThinkingLevel | undefined;
      const created = await createAgentSessionFromServices({
        services,
        sessionManager,
        ...(initialModel ? { model: initialModel } : {}),
        ...(sessionStartEvent ? { sessionStartEvent } : {}),
        ...(selectedProfileModel ? { model: selectedProfileModel } : {}),
        ...(recordedThinking ? { thinkingLevel: sessionManager.buildSessionContext().thinkingLevel as ThinkingLevel }
          : launchThinking ? { thinkingLevel: launchThinking } : {}),
        // The allowlist is Home's executable ceiling. MCP tools cannot appear
        // under it because no MCP extension is loaded, and Tron's direct bash
        // tool is not registered at all for Home.
        ...(profile.tools ? { tools: [...profile.tools] } : {}),
        // Pi's generic ToolDefinition render state is invariant; the concrete
        // bash schema is nevertheless the exact SDK definition registered here.
        ...(directBashProcesses ? { customTools: [
          directBashProcesses.toolDefinition(trust.cwd) as unknown as ToolDefinition,
          ...(this.taskWorker ? [this.taskWorker.checkinTool(() => this.id, () => this.activeOperationId && !this.runAbort.abortedOperations.has(this.activeOperationId) ? this.runTerminal.taskTurnOperationId(this.activeOperationId) : undefined), this.taskWorker.tool(() => this.id, () => this.activeOperationId && !this.runAbort.abortedOperations.has(this.activeOperationId) ? this.runTerminal.taskTurnOperationId(this.activeOperationId) : undefined,
            async report => {
              // A sealed report decides the outcome, so no task-owned run may still be live then: settlement
              // would stop it after the outcome was fixed. Refuse under the liveness rule settlement uses.
              const live = this.liveSubagentRuns().length;
              if (live > 0) throw new GatewayError("conflict", reportLiveRunsRefusal(live), true);
              await this.persistCanonicalCustomEntry(HOME_TASK_REPORT, JSON.parse(JSON.stringify(report)), report.receiptId,
                this.runWork.get(report.operationId));
              const entry = this.sessionManager.getBranch().find(candidate => candidate.type === "custom"
                && candidate.customType === HOME_TASK_REPORT && (candidate.data as { receiptId?: string }).receiptId === report.receiptId);
              if (!entry) throw new GatewayError("conflict", "Canonical task report is missing");
              return entry.id;
            })] : []),
        ] } : {}),
      });
      if (startsNewChat) this.newSettingsSessions.add(created.session);
      // The transcript owns a chat's tool loadout. Pi's createAgentSession always
      // passes its configured defaults, which skips AgentSession's own transcript
      // restore, so a resumed, forked or reloaded chat would silently fall back
      // to the defaults and the next prompt would persist that (#327). Apply the
      // declared loadout here; a session without one keeps the defaults.
      const toolChoice = readSessionToolChoice(sessionManager.getBranch());
      if (toolChoice && toolChoice.fixed?.from !== "project") created.session.setActiveToolsByName(toolChoice.tools);
      else if (profile.launchDefaults === "settings-home-recipe") {
        const tools = launchDefaults?.keys.find(row => row.key === "tools.active" && row.layer === "session")?.value;
        if (Array.isArray(tools)) created.session.setActiveToolsByName(tools.filter((name): name is string => typeof name === "string" && profile.tools?.includes(name) === true));
      }
      this.runtimeProfiles.set(created.session, profile);
      this.homeRequestPolicy = profile.requestPolicy
        ? this.dependencies.modules.policy("requestPolicy")?.().forSession(sessionManager.getSessionId())
        : undefined;
      const homeRequestPolicy = this.homeRequestPolicy;
      const compactionSession = created.session;
      compactionPolicy = new CompactionOperationPolicy(compactionSession, this.dependencies.agentDir, compactionAdmission,
        profile.compaction === "disabled" ? { disabled: true } : { session: () => readSessionSettings(compactionSession.sessionManager.getBranch()) });
      const taskWorker = this.taskWorker;
      requestPipeline.install(created.session, {
        applySettings: () => this.applyLiveRunSettings(created.session),
        settingsApplied: () => {
          if (this.dependencies.settings()) {
            this.emit("session.diagnostic", safeJson({
              code: "settings-run-applied", retry: created.session.settingsManager.getRetrySettings(),
              imagesBlocked: created.session.settingsManager.getBlockImages(),
              transport: created.session.agent.transport,
              steeringMode: created.session.agent.steeringMode, followUpMode: created.session.agent.followUpMode,
            }));
          }
        },
        compactionStream: compactionPolicy.wrap.bind(compactionPolicy),
        ...(homeRequestPolicy ? {
          policyStream: baseStream => homeRequestPolicy.wrapStreamFunction(baseStream),
          // Outermost on both: the request is cut after the SDK's own projection,
          // and the digest expectation is recorded after every SDK context stage.
          outer: {
            transformContext: (transformContext, convertToLlm) => homeRequestPolicy.wrapTransformContext(transformContext, convertToLlm),
            prepareRequest: (prepareRequest) => homeRequestPolicy.wrapPrepareRequest(created.session, prepareRequest),
          },
        } : {}),
        ...(taskWorker ? {
          // A sealed report ends the task at its turn boundary, after the SDK's own
          // boundary handling, so no further model request starts. Steering queued
          // before the seal would be stranded by a quiet end, so it takes the task's
          // exact stop, which retires queued input as not delivered.
          finishTurn: (finishTurn) => async (turn, signal): Promise<AgentTurnDecision | undefined> => {
            const decision = await finishTurn?.(turn, signal);
            // A task that reached its budget ends here the same way (settings-model.md 6.1).
            const ending = taskWorker.reportSealed || await taskWorker.exceedsBudget(this.canonicalSessionEntries());
            if (!ending) {
              // A plain reply is not an immutable task result. Repair that omission
              // once inside the same invocation, before any terminal receipt. Live
              // children/queued input retain their own continuation and Stop wins.
              if (!decision && turn.message.stopReason === "stop" && !signal?.aborted
                && !created.session.agent.hasQueuedMessages() && !this.hasDetachedDashboardWork()
                && taskWorker.takeReportReminder()) {
                await created.session.sendCustomMessage({ customType: "tron.home-task-report-reminder.v1",
                  content: "Call report now with the current outcome and partial evidence. Do not continue implementation or validation. Use progress for unfinished work or needs-input for a blocker; do not claim final success without acceptance evidence. If you cannot report, the task will settle with no report.",
                  display: false }, { triggerTurn: true });
                this.dependencies.homeTaskDiagnostic?.({ event: "home.task.report-reminder",
                  taskHash: createHash("sha256").update(taskWorker.identity.taskId).digest("hex").slice(0, 16),
                  operationHash: createHash("sha256").update(taskWorker.identity.operationId).digest("hex").slice(0, 16) });
                return { action: "continue" };
              }
              return decision ?? undefined;
            }
            if (this.runQueue.queuedMessages.length > 0) {
              taskWorker.requestStop(() => this.abort("agent", taskWorker.identity.operationId, taskWorker.reportSealed ? "task-report" : "task-budget"));
            }
            return { action: "end" };
          },
        } : {}),
      });
      this.compactionPolicies.set(created.session, compactionPolicy);
      contextPolicy = new SessionContextWindowPolicy(created.session);
      this.contextPolicies.set(created.session, contextPolicy);
      return { ...created, services, diagnostics: services.diagnostics };
    };
  }

  private async initialize(): Promise<void> {
    // A task resumed in place appends its own marker after its predecessor's (#929): every
    // marker must name a distinct operation of a task bound to this session.
    const markers = this.canonicalTaskEvidence().filter(entry => entry.type === "custom" && entry.customType === HOME_TASK_MARKER);
    const operations = new Set(markers.map(marker => marker.type === "custom" ? (marker.data as { operationId?: unknown } | null)?.operationId : undefined));
    if (operations.size !== markers.length) throw new GatewayError("conflict", "Conflicting canonical task markers");
    for (const marker of markers) {
      if (marker.type !== "custom") throw new GatewayError("conflict", "Task authority is unavailable");
      await this.dependencies.validateTaskMarker(this.id, marker.data);
    }
    this.runtime = await createAgentSessionRuntime(this.runtimeFactory(), {
      cwd: this.sessionManager.getCwd(),
      agentDir: this.dependencies.agentDir,
      sessionManager: this.sessionManager,
      sessionStartEvent: { type: "session_start", reason: "resume" },
    });
    this.installRuntimeHooks();
    await this.bindSession();
  }

  private async captureFixedDefaults(): Promise<void> {
    const owners = this.dependencies.settings();
    if (!owners) return;
    const session = this.runtime.session;
    const keys = KEYS.filter(key => key.timing === "fixed" && (key.layers.session?.store === "session" || key.layers.session?.store === "session-settings"));
    const defaults = await owners.model.resolve({ kind: "session", sessionId: this.id }, this.settingsSource({ settings: {} }), keys.map(key => key.id));
    const actual = this.settingsSessionLayer();
    const policy = this.contextPolicies.get(session);
    const context = policy?.snapshot();
    const fixed: Record<string, FixedSetting> = {};
    for (const row of defaults.keys) {
      const binding = schemaKey(row.key).layers.session;
      if (binding?.store !== "session" && binding?.store !== "session-settings") continue;
      const value = binding.store === "session-settings" ? row.value
        : binding.field === "contextWindow" ? context?.effective : actual[binding.field];
      if (value === undefined) continue;
      // Startup fallback/explicit Home choices are not attributed to a default
      // that did not supply them. Existing chats never acquire invented history.
      const from = binding.store === "session" && binding.field === "model" && row.value !== undefined && JSON.stringify(value) !== JSON.stringify(row.value)
        ? "session" : row.layer;
      fixed[row.key] = { value, from, at: new Date().toISOString(), ref: randomUUID(), ...(row.qualifiers ? { qualifiers: row.qualifiers } : {}) };
    }
    if (context && session.model) policy!.set({ provider: session.model.provider, id: session.model.id }, context.effective);
    await this.persistSessionSettings({ fixed });
  }

  /** One canonical Session settings entry; a part not given keeps the branch's current value. */
  private async persistSessionSettings(entry: { settings?: Record<string, unknown>; requestPins?: Record<string, FixedSetting>; fixed?: Record<string, FixedSetting> }): Promise<void> {
    const branch = this.sessionManager.getBranch(), receiptId = randomUUID();
    await this.persistCanonicalCustomEntry(SESSION_SETTINGS_ENTRY, safeJson({ receiptId, settings: entry.settings ?? readSessionSettings(branch),
      requestPins: entry.requestPins ?? readSessionRequestPins(branch), fixed: entry.fixed ?? readSessionFixedSettings(branch) }), receiptId);
  }

  /** Home’s explicit launch policy is canonical worker state, not a live Home
   * inheritance layer. Cold opens read the same branch-local fixed evidence. */
  async setHomeTaskModelQueues(queues: import("../providers/model-queue.js").TaskModelQueues): Promise<void> {
    return this.lane.run(async () => {
      this.assertConfigurationIdle();
      if (!this.taskWorker) throw new GatewayError("invalid_request", "Only an admitted Home task owns task queue launch inputs");
      const fixed = readSessionFixedSettings(this.sessionManager.getBranch());
      for (const role of ["worker", "subagent"] as const) {
        const key = `model.queue[role=${role}]`;
        const value = await schemaKey(key).type.validate(queues[role], key);
        fixed[key] = { value, from: "delegate", at: new Date().toISOString(), ref: randomUUID(),
          via: "home-profile", reason: "Resolved at task launch; later Home profile changes do not retarget this worker" };
      }
      await this.persistSessionSettings({ fixed });
    });
  }

  private taskQueueSelection(role: string): readonly string[] | undefined {
    // Canonical launch inputs outlive the active task runtime. A cold-opened
    // completed worker still owns its recorded child policy; no marker flag or
    // current Home profile may replace that evidence.
    const value = readSessionFixedSettings(this.sessionManager.getBranch())[`model.queue[role=${role}]`]?.value;
    if (value === undefined) return undefined;
    if (!Array.isArray(value) || value.some(item => typeof item !== "string")) throw new GatewayError("conflict", "Invalid canonical task queue");
    return value;
  }

  protected async recordFixedSetting(key: string, value: unknown, origin?: FixedSetting): Promise<void> {
    const fixed = readSessionFixedSettings(this.sessionManager.getBranch());
    fixed[key] = { ...(origin ?? { from: "session", at: new Date().toISOString(), ref: randomUUID() }), value };
    await this.persistSessionSettings({ fixed });
  }

  private effectiveResourceReloadOptions(): { resolveProjectTrust: () => Promise<boolean> } | undefined {
    const override = this.projectTrustReloadOverride;
    // A trust transition never admits project resources into Home.
    return override === undefined || this.liveProfile().projectTrust === "never"
      ? this.resourceReloadOptions
      : { resolveProjectTrust: async () => override };
  }

  private assertAutomationMayNotReplaceSession(): void {
    if (this.taskWorker || currentInvocationContext()?.operationId?.startsWith("automation:")) {
      throw new GatewayError("conflict", "Scheduled automation turns cannot replace or navigate their target session");
    }
  }

  private commandActions(): ExtensionCommandContextActions {
    return {
      waitForIdle: () => this.runtime.session.waitForIdle(),
      newSession: (options) => {
        this.assertChapterWritable();
        this.assertAutomationMayNotReplaceSession();
        return this.replaceFromCommand("reset", () => this.runtime.newSession(options));
      },
      fork: (entryId, options) => {
        this.assertChapterWritable();
        this.assertAutomationMayNotReplaceSession();
        return this.replaceFromCommand("reset", () => this.runtime.fork(entryId, options));
      },
      navigateTree: async (targetId, options) => {
        this.assertChapterWritable();
        this.assertAutomationMayNotReplaceSession();
        const result = await this.runtime.session.navigateTree(targetId, options);
        if (!result.cancelled) {
          this.forkBoundary = await this.dependencies.resolveForkBoundary?.(this.sessionManager);
          this.noteCanonicalEntriesCommitted();
        }
        return result;
      },
      switchSession: (sessionPath, options) => {
        this.assertChapterWritable();
        this.assertAutomationMayNotReplaceSession();
        return this.replaceFromCommand("preserve", () => this.runtime.switchSession(sessionPath, options));
      },
      reload: async () => {
        this.assertChapterWritable();
        this.assertAutomationMayNotReplaceSession();
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
    if (this.liveProfile().managedSubagents) {
      await this.dependencies.managedSubagents?.completeLoad(session.settingsManager, this.cwd, this.dependencies.agentDir, session.resourceLoader.getExtensions().extensions);
    }
    await session.reload({ beforeSessionStart: () => this.rotateSemanticHost() });
  }

  /** Pi's replacement hooks for each runtime this slot constructs. */
  private installRuntimeHooks(): void {
    bindRuntimeSession(this.runtime, {
      beforeInvalidate: () => {
        this.runInvocations.handOffReplacedCommand();
        this.dependencies.modules.observers("sessionRetired").forEach(retire => { try { retire(this.id); } catch { /* Cleanup is best effort. */ } });
      },
      rebind: async () => this.bindSession(),
    });
  }

  /** A command that replaces its own session ends in that session. Pi commits
   * the replacement at `beforeSessionInvalidate`, after `session_before_switch`
   * can no longer refuse it and while the origin is still bound; the command's
   * terminal receipt and marker are settled there, so no receipt for it is ever
   * written under the replacement identity. Handler code after the call runs
   * unowned in the replacement, as Pi's stale-context model implies. */
  private async replaceFromCommand<T>(
    disposition: SessionAttentionRebindDisposition,
    operation: () => Promise<T>,
  ): Promise<T> {
    const replacement: CommandReplacement = {};
    this.commandReplacement = replacement;
    try {
      return await this.runAttention.withRebindAttentionDisposition(disposition, operation);
    } finally {
      if (this.commandReplacement === replacement) this.commandReplacement = undefined;
      await replacement.settlement?.catch((error) => this.emit("session.diagnostic", safeJson({
        code: "command-handoff-settlement-failed",
        message: error instanceof Error ? error.message : String(error),
      })));
    }
  }

  public assertSessionIdentityReplacement(): void {
    this.assertChapterWritable();
    if (this.taskWorker || this.canonicalTaskEvidence().some(entry => entry.type === "custom" && entry.customType === HOME_TASK_MARKER)) {
      throw new GatewayError("conflict", "Task worker session identity cannot be replaced");
    }
    if (this.dependencies.lineageState(this.id).lineageId || this.liveProfile().chapter) {
      throw new HomeChapterIdentityReplacementError(this.id);
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
    // Stop must settle even when a tool ignores cancellation (#961).
    boundToolCancellation(session);
    await session.bindExtensions({
      uiContext: this.extensionHost.context(),
      mode: "rpc",
      commandContextActions: this.commandActions(),
      abortHandler: () => { void this.abort().catch(error => this.emit("session.diagnostic", safeJson({
        code: "foreground-abort-unsettled", message: error instanceof Error ? error.message : String(error),
      }))); },
      shutdownHandler: () => this.requestExtensionShutdown(),
      onError: (error) => {
        const context = currentInvocationContext();
        const invocationId = context?.invocationId;
        if (invocationId && this.pendingExtensionCommand?.invocationId === invocationId) {
          this.runInvocations.invocationFailures.set(invocationId, "extension-error");
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
          this.runAttention.rebindAttentionDisposition,
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
      let rollbackError: unknown;
      try { await this.removeUncommittedForkArtifacts(this.sessionManager, nextManager); }
      catch (cleanupError) { rollbackError = cleanupError; }
      await this.restorePreviousRuntime(this.sessionManager);
      if (rollbackError) {
        throw new GatewayError(
          "internal",
          "Session replacement failed and its fork artifacts could not be rolled back",
          false,
          {
            failure: error instanceof Error ? error.message : "Unknown replacement failure",
            rollback: rollbackError instanceof Error ? rollbackError.message : "Unknown rollback failure",
          },
        );
      }
      throw error;
    }
    previousUnsubscribe?.();
    this.unsubscribe = nextUnsubscribe;
    this.forkBoundary = await this.dependencies.resolveForkBoundary?.(nextManager);
    this.hydrateCanonicalExtensionActivities();
    this.reconcileCanonicalDisplayArtifacts();
    if (this.newSettingsSessions.has(session)) {
      await this.captureFixedDefaults();
      this.newSettingsSessions.delete(session);
    }
    await this.applyLiveRunSettings(session);
    this.revision += 1;
    this.publishSnapshot();
  }

  private async removeUncommittedForkArtifacts(
    previousManager: SessionManager,
    nextManager: SessionManager,
  ): Promise<void> {
    if (this.runAttention.rebindAttentionDisposition !== "reset") return;
    const previousFile = previousManager.getSessionFile();
    const nextFile = nextManager.getSessionFile();
    const parentFile = nextManager.getHeader()?.parentSession;
    if (!previousFile || !nextFile || !parentFile || resolve(nextFile) === resolve(previousFile)) return;
    const canonicalPrevious = realpathSync(previousFile);
    const canonicalParent = realpathSync(parentFile);
    if (canonicalPrevious !== canonicalParent) return;
    await rm(nextFile, { force: true });
    await rm(join(dirname(nextFile), basename(nextFile, ".jsonl")), { recursive: true, force: true });
  }

  private async restorePreviousRuntime(previousManager: SessionManager): Promise<void> {
    await this.replaceRuntime(previousManager);
  }

  /** Rebuild this slot's runtime over the same session manager, keeping the
   * session identity, its subscribers and its presentation. The factory decides
   * the profile from the record, so this is also how a profile change takes
   * effect. */
  private async replaceRuntime(sessionManager: SessionManager = this.sessionManager): Promise<void> {
    await this.runtime.dispose().catch(() => {});
    this.runtime = await createAgentSessionRuntime(this.runtimeFactory(), {
      cwd: sessionManager.getCwd(),
      agentDir: this.dependencies.agentDir,
      sessionManager,
      sessionStartEvent: { type: "session_start", reason: "resume" },
    });
    this.installRuntimeHooks();
    await this.bindSession();
  }

  /**
   * Replace this slot's runtime in place after `commit` changes the profile
   * decision for its session. The whole sequence runs in the slot's lane, which
   * is also the lane prompt admission uses, so no prompt can be admitted between
   * the idle check, the durable commit and the rebuild: the next prompt always
   * sees the new profile. A busy slot refuses retryably and changes nothing.
   */
  /** A settled task resumes in place (#929): this session's next task operation is owned by
   * `report`. Refused while any run, admission, subagent or previous task operation is live,
   * so the predecessor's operation is never shared. The runtime is rebuilt over the same
   * session manager, keeping identity, subscribers and presentation, so the task worker's
   * tools and producer gates belong to the new operation. */
  async bindTaskWorker(report: HomeTaskReportOwner, exceptWorkToken?: string): Promise<void> {
    await this.lane.run(async () => {
      this.assertUsable();
      this.assertChapterWritable();
      // Any live work in this session refuses the rebind, named.
      const blocking = this.dependencies.workRegistry.sessionWorkKinds(this.id, exceptWorkToken);
      const drain = this.administrativeDrainBlockers().map(fact => fact.category);
      if (this.runtime.session.isStreaming || blocking.length || drain.length) {
        throw new GatewayError("busy", `The worker session is busy (${[...new Set([...blocking, ...drain])].join(", ") || "streaming"}); resume it when that finishes`, true);
      }
      if (this.liveProfile().chapter || this.dependencies.lineageState(this.id).lineageId) {
        throw new GatewayError("conflict", "A Home chapter cannot run a task");
      }
      if (this.taskWorker?.controlsActive || this.runTerminal.taskWait || this.activeOperationId !== undefined || this.operation !== undefined
        || this.catalogHasActiveSubagents || this.isAgentAdmissionSettling) {
        throw new GatewayError("conflict", "The worker session is still running; stop it before resuming");
      }
      const markers = this.canonicalTaskEvidence().filter(entry => entry.type === "custom" && entry.customType === HOME_TASK_MARKER);
      if (!markers.length) throw new GatewayError("conflict", "Only a Home task worker session can resume a task");
      const work = this.dependencies.workRegistry.begin({
        kind: "administrative-provider-package-operation",
        sessionId: this.id,
        hostEpoch: this.ui.hostEpoch,
      });
      try {
        this.taskWorker = report;
        await this.replaceRuntime();
        this.revision += 1;
        this.emit("session.resourcesChanged", {});
        this.publishSnapshot();
      } finally {
        work.settle();
      }
    });
  }

  async replaceRuntimeForProfile(commit: () => Promise<void>): Promise<void> {
    await this.lane.run(async () => {
      this.assertUsable();
      this.assertProfileChangeIdle();
      const work = this.dependencies.workRegistry.begin({
        kind: "administrative-provider-package-operation",
        sessionId: this.id,
        hostEpoch: this.ui.hostEpoch,
      });
      try {
        await commit();
        await this.replaceRuntime();
        this.revision += 1;
        this.emit("session.resourcesChanged", {});
        this.publishSnapshot();
      } finally {
        work.settle();
      }
    });
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

  private nestedToolCallsFromDetails(value: unknown): ToolExecutionState["nestedCalls"] | undefined {
    if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
    const details = (value as Record<string, unknown>).details;
    if (!details || typeof details !== "object" || Array.isArray(details)) return undefined;
    const sourceCalls = (details as Record<string, unknown>).calls;
    if (!Array.isArray(sourceCalls)) return undefined;
    let complete = sourceCalls.length <= NESTED_CALL_LIMIT;
    let argumentBudget = NESTED_ARGUMENT_TOTAL_BYTES;
    const calls = sourceCalls.slice(0, NESTED_CALL_LIMIT).flatMap((candidate): NestedToolExecutionState[] => {
      if (!candidate || typeof candidate !== "object" || Array.isArray(candidate)) return [];
      const item = candidate as Record<string, unknown>;
      if (typeof item.id !== "string" || typeof item.name !== "string") return [];
      const status: NestedToolExecutionState["status"] = item.status === "ok" ? "completed"
        : item.status === "error" || item.status === "cancelled" ? "failed"
          : item.status === "unfinished" ? "unfinished" : "running";
      if (status === "unfinished") complete = false;
      const error = typeof item.error === "string" ? boundedUtf8Prefix(item.error, 512) : undefined;
      const args = typeof item.args === "string" ? item.args : "";
      let argumentsValue: JsonValue | undefined;
      let argumentsBytes: number | undefined;
      if (args) {
        try {
          const parsed: unknown = JSON.parse(args);
          const bytes = Buffer.byteLength(JSON.stringify(parsed));
          if (bytes <= NESTED_ARGUMENT_CALL_BYTES && bytes <= argumentBudget) {
            argumentsValue = projectJson(parsed, NESTED_ARGUMENT_CALL_BYTES);
            argumentBudget -= bytes;
          } else { argumentsBytes = Buffer.byteLength(args); complete = false; }
        } catch { argumentsBytes = Buffer.byteLength(args); complete = false; }
      }
      const id = item.id.slice(0, 512);
      const durationMs = typeof item.durationMs === "number" && Number.isFinite(item.durationMs)
        ? Math.max(0, Math.round(item.durationMs)) : undefined;
      return [{
        id, parentToolCallId: id.slice(0, Math.max(0, id.lastIndexOf("/"))),
        toolName: item.name.slice(0, 256), status,
        ...(error === undefined ? {} : { error }),
        ...(argumentsValue === undefined ? {} : { arguments: argumentsValue }),
        ...(argumentsBytes === undefined ? {} : { argumentsBytes }),
        ...(durationMs === undefined ? {} : { durationMs }),
      }];
    });
    return { calls, complete };
  }

  private updateNestedExtensionActivity(
    event: { toolCallId: string; toolName: string },
    status: "running" | "completed" | "failed",
    value?: unknown,
  ): void {
    const now = new Date().toISOString();
    const startedAt = this.extensionActivities.get(event.toolCallId)?.startedAt ?? now;
    const activity = this.updateExtensionActivity(
      event.toolCallId,
      event.toolName,
      this.extensionToolOrigin(event.toolName),
      status,
      startedAt,
      now,
      value,
      status === "running" ? undefined : now,
      undefined,
      false,
    );
    if (activity) this.publishProcessesForToolCall(event.toolCallId);
  }

  private projectNestedToolExecution(
    event: { toolCallId: string; toolName: string; args?: unknown; parentToolCallId?: string },
    status: NestedToolExecutionState["status"],
  ): void {
    if (!event.parentToolCallId) return;
    const rootToolCallId = this.nestedToolRoots.get(event.parentToolCallId) ?? event.parentToolCallId;
    const parent = this.toolExecutions.get(rootToolCallId);
    if (!parent) return;
    const calls = parent.nestedCalls?.calls ?? [];
    const existing = calls.find((call) => call.id === event.toolCallId);
    if (!existing && calls.length >= NESTED_CALL_LIMIT) {
      this.toolExecutions.set(rootToolCallId, {
        ...parent,
        nestedCalls: { calls, complete: false },
        updatedAt: new Date().toISOString(),
        progressSequence: parent.progressSequence + 1,
      });
      this.publishToolProgress(this.toolExecutions.get(rootToolCallId)!);
      return;
    }
    let argumentsValue: JsonValue | undefined;
    let argumentsBytes: number | undefined;
    let complete = parent.nestedCalls?.complete ?? true;
    if (event.args !== undefined) {
      let encodedBytes = 0;
      try { encodedBytes = Buffer.byteLength(JSON.stringify(event.args)); } catch { encodedBytes = Number.MAX_SAFE_INTEGER; }
      // The budget left is what this parent's other calls have not used.
      const usedBytes = calls.reduce((total, call) => call.id === event.toolCallId || call.arguments === undefined
        ? total : total + Buffer.byteLength(JSON.stringify(call.arguments)), 0);
      if (encodedBytes <= NESTED_ARGUMENT_CALL_BYTES && usedBytes + encodedBytes <= NESTED_ARGUMENT_TOTAL_BYTES) {
        argumentsValue = projectJson(event.args);
      } else {
        argumentsBytes = encodedBytes;
        complete = false;
      }
    }
    const started = this.nestedToolStartedAt.get(event.toolCallId);
    if (!existing && status === "running") {
      this.nestedToolStartedAt.set(event.toolCallId, performance.now());
      this.nestedToolRoots.set(event.toolCallId, rootToolCallId);
    }
    const nested: NestedToolExecutionState = {
      id: event.toolCallId,
      parentToolCallId: event.parentToolCallId,
      toolName: event.toolName,
      status,
      ...(argumentsValue === undefined ? (existing?.arguments === undefined ? {} : { arguments: existing.arguments }) : { arguments: argumentsValue }),
      ...(argumentsBytes === undefined ? (existing?.argumentsBytes === undefined ? {} : { argumentsBytes: existing.argumentsBytes }) : { argumentsBytes }),
      ...(status === "running" || started === undefined
        ? (existing?.durationMs === undefined ? {} : { durationMs: existing.durationMs })
        : { durationMs: Math.max(0, Math.round(performance.now() - started)) }),
    };
    const nextCalls = existing
      ? calls.map((call) => call.id === event.toolCallId ? nested : call)
      : [...calls, nested];
    this.toolExecutions.set(rootToolCallId, {
      ...parent,
      nestedCalls: { calls: nextCalls, complete },
      updatedAt: new Date().toISOString(),
      progressSequence: parent.progressSequence + 1,
    });
    if (status !== "running") {
      this.nestedToolStartedAt.delete(event.toolCallId);
      this.nestedToolRoots.delete(event.toolCallId);
    }
    this.publishToolProgress(this.toolExecutions.get(rootToolCallId)!);
  }

  private clearProcessActivities(): void {
    for (const processId of this.processActivities.keys()) this.dependencies.processActivityRecency.remove(processId);
    this.processActivities.clear();
    this.processOperationIDs.clear();
    this.processIDsByToolCall.clear();
    this.pendingProcessRemovalsByToolCall.clear();
    this.childSessionAdmission.clear();
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
      this.processOperationIDs.delete(processId);
      this.dependencies.processActivityRecency.remove(processId);
      this.processRevision += 1;
    }
    for (const projectedCandidate of projected) {
      if (projectedCandidate.lifecycle.state === "unknown"
        || projectedCandidate.visibility === "unknown") {
        if (this.processActivities.delete(projectedCandidate.processId)) removed.add(projectedCandidate.processId);
        this.processOperationIDs.delete(projectedCandidate.processId);
        this.dependencies.processActivityRecency.remove(projectedCandidate.processId);
        this.processRevision += 1;
        continue;
      }
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
        this.processOperationIDs.delete(candidate.processId);
        continue;
      }
      this.processActivities.set(candidate.processId, admitted.activity);
      const operationId = this.operation?.id;
      const parentToolCallId = this.nestedToolRoots.get(toolCallId) ?? toolCallId;
      if (admitted.activity.executionMode === "synchronous"
        && isActiveProcessLifecycle(admitted.activity.lifecycle)
        && this.toolExecutions.get(parentToolCallId)?.status === "running"
        && operationId) {
        this.processOperationIDs.set(candidate.processId, operationId);
      } else {
        this.processOperationIDs.delete(candidate.processId);
      }
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
        // Resume steps share a canonical session, not a process identity. Match
        // the exact producer before checking whether its binding is ambiguous.
        if (childSessionRef && child.producerId
          && subagentProcessId(this.id, activity.toolCallId, child.producerId) === processId) {
          const candidate = {
            ref: childSessionRef,
            producerId: child.producerId,
            ...(child.sessionOwnerId ? { sessionOwnerId: child.sessionOwnerId } : {}),
          };
          candidates.set(`${candidate.ref}\0${candidate.producerId}\0${candidate.sessionOwnerId ?? ""}`, candidate);
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
    const pausedSettledAt = this.pausedProcessSettlementAt(activity);
    const candidates = subagentProcessesFromActivity(
      this.id,
      activity,
      pausedSettledAt === undefined ? {} : { pausedSettledAt },
    );
    const bindings = new Map(candidates.flatMap(process => {
      const binding = this.childSessionBindingFromActivity(process.processId, activity);
      return binding ? [[process.processId, binding] as const] : [];
    }));
    // A visible ref is an availability transition, not an unverified producer
    // hint. Keep process identity stable while exact ownership becomes known.
    const projected = candidates.map(process => {
      if (bindings.has(process.processId)) return process;
      const { childSessionRef: _unbound, ...unbound } = process;
      return unbound;
    });
    for (const processId of this.processIDsByToolCall.get(activity.toolCallId) ?? []) {
      this.childSessionBindings.delete(processId);
    }
    this.replaceProcessesForToolCall(activity.toolCallId, projected);
    for (const [processId, binding] of bindings) {
      if (this.processActivities.has(processId)) this.childSessionBindings.set(processId, binding);
    }
  }

  private activitySource(): activityProjection.ActivitySource {
    const slot = this;
    return {
      get processActivities() { return slot.processActivities; },
      get dependencies() { return slot.dependencies; },
      get extensionActivities() { return slot.extensionActivities; },
      get processRevision() { return slot.processRevision; },
      get processAsOf() { return slot.processAsOf; },
      measureToolDuration: (...args) => slot.measureToolDuration(...args),
      get liveActivityRevision() { return slot.liveActivityRevision; },
      get extensionActivityAsOf() { return slot.extensionActivityAsOf; },
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
      overview: activityProjection.currentProcessProjection(this.activitySource()).overview,
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
      this.notifyDetachedWork();
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
          const visibility = activityProjection.extensionActivityVisibility(this.activitySource(), activity);
          return visibility === "recent" || visibility === "historical" ? 0 : 1;
        };
        return bucket(left[1]) - bucket(right[1]) || left[1].updatedAt.localeCompare(right[1].updatedAt);
      });
      const oldest = ranked[0]?.[0];
      if (!oldest) break;
      this.stopExtensionActivityWatcher(oldest);
      this.extensionActivities.delete(oldest);
      this.extensionArtifactMissingSince.delete(oldest);
      this.replaceProcessesForToolCall(oldest, []);
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

  public maybePerformExtensionShutdown(): void {
    if (!this.lifecycle.isShutdownRequested || this.lifecycle.hasPendingCommands || this.lifecycle.hasPendingPrompts
      || this.extensionShutdownInFlight || this.extensionShutdownRetryTimer || this.shuttingDown || this.disposed) return;
    this.extensionShutdownInFlight = true;
    void this.runtime.session.waitForIdle().then(async () => {
      await this.runPersistence.waitForReceiptWrites();
      return this.lane.run(async () => {
      if (!this.lifecycle.isShutdownRequested || this.lifecycle.hasPendingCommands || this.lifecycle.hasPendingPrompts || this.disposed) return;
      this.shuttingDown = true;
      const closedID = this.id;
      const hostEpoch = this.ui.hostEpoch;
      await this.disposeRuntime();
      await this.runPersistence.retryDurableWrite("marker:clear:all", () => this.dependencies.markers.clear(closedID));
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

  public emit(topic: string, data: JsonValue): void {
    this.eventSequence += 1;
    this.hooks.broadcast(this.id, topic, {
      runtimeGeneration: this.runtimeGeneration,
      eventSequence: this.eventSequence,
      revision: this.revision,
      data,
    });
  }

  public ownToolSegment(ownerId: string | undefined): void {
    this.activeToolSegmentOwnerId = ownerId;
    this.toolSegmentAwaitsAssistantOwner = false;
  }

  public prepareAssistantOwnedToolSegment(): void {
    // Publish a fresh provisional generation immediately. It intentionally
    // matches no declaration and is replaced by the next assistant's stable
    // presentation ID before that message can publish tool progress.
    this.activeToolSegmentOwnerId = randomUUID();
    this.toolSegmentAwaitsAssistantOwner = true;
  }

  private activeToolSegmentId(): string | undefined {
    return this.activeToolSegmentOwnerId
      ? toolSegmentId(this.activeToolSegmentOwnerId)
      : undefined;
  }

  private emitProgress(message: AgentMessage): void {
    this.pendingProgressMessage = message;
    if (this.progressFlushTimer !== undefined) return;
    this.armProgressFlushTimer();
    this.flushPendingProgress();
  }

  /** Throttle, not debounce: the first update after a quiet window flushes
   * immediately, then at most one frame per window carries the newest message.
   * A window that sent re-arms, so a continuous stream never re-fires the
   * leading edge right after a trailing flush; only an empty window ends it. */
  private armProgressFlushTimer(): void {
    this.progressFlushTimer = setTimeout(() => {
      this.progressFlushTimer = undefined;
      if (this.flushPendingProgress()) this.armProgressFlushTimer();
    }, STREAMING_PROGRESS_FLUSH_MS);
    this.progressFlushTimer.unref();
  }

  /** Returns whether a `session.progress` frame was sent. */
  private flushPendingProgress(): boolean {
    const message = this.pendingProgressMessage;
    this.pendingProgressMessage = undefined;
    if (!message || message.role !== "assistant") return false;
    this.captureStreamIdentity(message);
    if (!this.streamPresentationId || !this.streamStartedAt) return false;
    // No audience, no projection, the rule `publishSnapshot` already follows: a
    // progress frame re-projects and re-serializes the whole cumulative
    // streaming message, so a session nobody subscribes to pays for a frame no
    // socket can receive. The subscriber record is the slot's audience fact;
    // stream identity is captured above either way, and a client that
    // subscribes mid-stream receives the streaming item in its snapshot and the
    // frames after it.
    if (this.dependencies.sessionAudience(this.id) === 0) return false;
    const projected = projectMessage(this.displayProjection,
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
      this.activeToolSegmentId(),
    );
    this.emit("session.progress", safeJson({
      message: projected === undefined ? undefined : boundStreamingProgressItem(projected),
    }));
    return true;
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
    const projected = projectMessage(this.displayProjection,
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
      this.activeToolSegmentId(),
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
    // The group latch above is slot state and stays whatever the audience is;
    // the frame itself follows the no-audience rule of `flushPendingProgress`.
    if (this.dependencies.sessionAudience(this.id) > 0) {
      this.emit("session.progress", safeJson({ message: boundStreamingProgressItem(projected) }));
    }
    const lastToolIndex = projected.content.findLastIndex(part => part.type === "toolCall");
    const lastBarrierIndex = projected.content.findLastIndex(part => part.type !== "toolCall");
    if (lastToolIndex < 0 || lastBarrierIndex > lastToolIndex) {
      this.prepareAssistantOwnedToolSegment();
    }
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

  public rememberPresentationID(canonicalID: string, presentationID: string): void {
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
    const binding = this.runAttention.captureAssistantBinding();
    const mayComplete = message.stopReason === "stop" || message.stopReason === "length";
    if (mayComplete && binding.ownsPromptOperation) this.runAttention.bindAssistant(message, binding);
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
          const item = this.runAttention.recordCompletionOwnership({
            ...completion,
            ...(binding.operationId ? { operationId: binding.operationId } : {}),
          });
          this.runAttention.pendingAssistantCompletion = item.completion;
          // Pi has synchronously appended the canonical entry. Settle this exact
          // completion immediately: a queued follow-up can start inside the same
          // agent loop without a continuation/agent-settled boundary in between.
          void this.runAttention.beginAttentionSettlement(item.completion).catch((error) =>
            this.runAttention.settleCompletionPersistenceFailure(item.completion, error, item.fallbackWork));
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
        this.runAttention.releaseAssistant(message);
      }
    });
  }

  /** The operation's canonical start cursor and the completion it last admitted
   * share the operation lifetime. Terminal receipts attribute their completion
   * from `observedCompletionId`; the cursor fences which completions belong to
   * this operation. (Knowledge observation no longer consumes these cuts, #1315.) */
  /** The process activity projection owns live delegated work that may wake
   * this session; paused and recent history are not pending work. */
  public pendingBackgroundProcesses(): string[] {
    return [...this.extensionActivities.values()]
      .filter((activity) => this.extensionActivityOwnsLiveWork(activity)
        && ["asynchronous", "workflow"].includes(activity.mode?.toLowerCase() ?? ""))
      .map((activity) => `${activity.toolCallId}:${activity.runId ?? activity.activityId ?? activity.id}`)
      .sort();
  }

  public notificationTitle(): string {
    if (this.isHomeChapter) return "Home";
    // Read canonical input rather than a deferred summary projection so a new
    // session's first terminal notification cannot be titled "New session".
    const rawName = this.sessionManager.getSessionName()?.trim();
    const firstUser = this.sessionManager.getBranch().find((entry) => entry.type === "message"
      && entry.message.role === "user");
    const firstMessage = firstUser?.type === "message" && firstUser.message.role === "user"
      ? (typeof firstUser.message.content === "string"
        ? firstUser.message.content
        : firstUser.message.content.flatMap((part) => part.type === "text" ? [part.text] : []).join(""))
      : "";
    const title = rawName || userFacingPromptPreview(firstMessage) || "New session";
    return boundedSummaryText([...title].slice(0, 80).join(""), 256);
  }

  /** Fold the summary facts over the entries appended since the previous fold.
   * `getEntries()` returns the file's entries in append order, so the previous
   * boundary id proves the earlier entries are still the same ones; anything
   * else (shorter array, different entry at the boundary) is not an append. */
  private foldSummaryContent(): { messageCount: number; firstMessage: string; updatedAt: string | undefined } {
    const entries = this.sessionManager.getEntries();
    const folded = this.summaryContentFold
      && this.summaryContentFold.entryCount <= entries.length
      && (this.summaryContentFold.entryCount === 0
        || entries[this.summaryContentFold.entryCount - 1]?.id === this.summaryContentFold.lastEntryId)
      ? this.summaryContentFold
      : (this.summaryContentFold = {
        messageCount: 0,
        firstMessage: "",
        updatedAt: undefined,
        entryCount: 0,
        lastEntryId: undefined,
      });
    for (let index = folded.entryCount; index < entries.length; index += 1) {
      const entry = entries[index]!;
      if (entry.type === "message") {
        // Pi 0.87 persists system-message transcript deltas for provider context;
        // they are canonical but not visible conversation rows.
        if (entry.message.role !== "system") folded.messageCount += 1;
        if (!folded.firstMessage && entry.message.role === "user") {
          folded.firstMessage = boundedSummaryText(userFacingPromptPreview(typeof entry.message.content === "string"
            ? entry.message.content
            : entry.message.content.flatMap((part) => part.type === "text" ? [part.text] : []).join("")));
        }
      }
      const activityAt = catalogActivityTimestamp(entry);
      if (activityAt !== undefined
        && (folded.updatedAt === undefined || activityAt > Date.parse(folded.updatedAt))) {
        folded.updatedAt = new Date(activityAt).toISOString();
      }
    }
    folded.entryCount = entries.length;
    folded.lastEntryId = entries[entries.length - 1]?.id;
    return folded;
  }

  private summary(): SessionSummaryUpdate {
    if (this.summaryContentDirty || !this.cachedSummaryContent) {
      const folded = this.foldSummaryContent();
      const rawName = this.sessionManager.getSessionName();
      const name = rawName ? boundedSummaryText(rawName) : undefined;
      this.cachedSummaryContent = {
        ...(name ? { name } : {}),
        updatedAt: folded.updatedAt ?? this.sessionManager.getHeader()?.timestamp ?? new Date().toISOString(),
        messageCount: folded.messageCount,
        firstMessage: folded.firstMessage,
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
      foregroundPhase: this.effectivePhase,
      hasActiveSubagents: this.hasDetachedDashboardWork(),
      waitingForUser: this.ui.hasPendingInteractions,
      ...canonical,
      ...(this.isHomeChapter ? { name: "Home" } : {}),
      updatedAt,
      ...(activeSince ? { activeSince } : {}),
    };
  }

  // Pi materializes a brand-new session when its first user or assistant message
  // is appended. Receipts written before that boundary become durable with the
  // message; receipts written before any message remain memory-only. Never write
  // Pi's JSONL directly or add a second receipt journal to bypass that boundary.
  /** Pi stages before appending. If a failed append left an entry in memory,
   * the enclosing durable-write owner fences the runtime; neither replay nor
   * memory-only presence can replace the missing canonical persistence proof. */
  private isInboxAttributed(message: AgentMessage): boolean {
    const eventId = (message as { details?: { eventId?: unknown } }).details?.eventId;
    return typeof eventId === "string" && this.inboxAttributedMessages.has(eventId);
  }

  private persistVerifiedCustomEntry(options: {
    describe: string;
    existing: () => "absent" | "matching" | "contradictory";
    append: () => void;
  }): void {
    const state = options.existing();
    if (state === "contradictory") {
      throw new CanonicalCustomEntryConflictError("Canonical custom entry identity is contradictory");
    }
    if (state === "matching") return;
    this.assertChapterWritable();
    try {
      options.append();
    } catch (error) {
      // A failure before Pi staged the entry (nothing in the live branch) leaves
      // the canonical record absent, so rethrow and let the bounded retry try
      // again. A failure after staging means the SDK mutated its in-memory branch
      // without persisting; retrying would append a contradictory duplicate
      // canonical record, so fail closed and report an unknown outcome.
      if (options.existing() !== "matching") throw error;
      throw asUncertainOutcome(error, `The ${options.describe} could not be persisted after Pi admitted it; refresh session state before retrying`);
    }
  }

  public persistCanonicalCustomEntry(
    customType: string,
    data: JsonValue,
    identity: string,
    owner?: GatewayWorkHandle,
  ): Promise<void> {
    // A receipt belongs to the session bound when it was requested. Retries run
    // after a delay and must not follow a rebind into the replacement's file.
    const manager = this.sessionManager;
    return this.runPersistence.trackOwnershipWrite(
      () => this.runPersistence.retryDurableWrite(`canonical:${customType}:${identity}`, async () => {
        this.persistVerifiedCustomEntry({
          describe: "canonical receipt",
          existing: () => {
            const entry = manager.getBranch().find((candidate) => {
              if (candidate.type !== "custom" || candidate.customType !== customType) return false;
              const value = candidate.data as { receiptId?: unknown; targetEntryId?: unknown };
              return value?.receiptId === identity || value?.targetEntryId === identity;
            });
            if (!entry) return "absent";
            return entry.type === "custom" && JSON.stringify(entry.data) === JSON.stringify(data)
              ? "matching"
              : "contradictory";
          },
          append: () => { manager.appendCustomEntry(customType, data); },
        });
      }),
      owner,
    );
  }

  public enqueueMarkerOwnership(operationId: string): Promise<void> {
    // An existing operation token already owns this marker write. Avoid spending
    // derived capacity for a second representation of the same accepted work.
    return this.runPersistence.trackOwnershipWrite(
      () => this.runPersistence.retryDurableWrite(`marker:mark:${operationId}`, () => this.dependencies.markers.mark(this.id, operationId)),
      this.runWork.get(operationId),
    );
  }

  public async clearMarkerOwnership(operationId?: string, existingOwner?: GatewayWorkHandle): Promise<void> {
    const key = operationId ?? "all";
    // A foreground prompt can answer before its exact marker fsync. Never let a
    // later clear overtake that publication and leave a stale marker on disk.
    if (operationId) await this.runPersistence.durableWrites.get(`marker:mark:${operationId}`)?.waiter;
    // Markers are keyed by the session that admitted the work; a retry after a
    // rebind still clears the origin's marker (see the command handoff).
    const sessionId = this.id;
    return this.runPersistence.trackOwnershipWrite(
      () => this.runPersistence.retryDurableWrite(`marker:clear:${key}`, () => this.dependencies.markers.clear(sessionId, operationId)),
      existingOwner ?? (operationId ? this.runWork.get(operationId) : undefined),
    );
  }


  public resetToolExecutionProjection(): void {
    this.toolExecutions.clear();
    this.toolInvocationGroups.clear();
    this.toolStartedAtMonotonicMs.clear();
    this.nextToolOrder = 0;
  }

  public resetStreamingProjection(): void {
    this.latestStreamingMessage = undefined;
    this.streamIdentityMessage = undefined;
    this.streamAnchorId = undefined;
    this.streamPresentationId = undefined;
    this.streamStartedAt = undefined;
    this.finalizedStreamPresentationId = undefined;
  }

  private onEvent(event: AgentSessionEvent): void {
    this.revision += 1;
    this.touch();
    // Session lifecycle/metadata events (notably session_start on a cold open)
    // are not user activity. Only canonical conversation entries and events during
    // owned dashboard work may advance recency; otherwise simply reopening an
    // old session would make it look newly active and reorder settled history.
    if (event.type === "entry_appended") {
      const activityAt = catalogActivityTimestamp(event.entry);
      if (activityAt !== undefined) this.noteDashboardActivity(new Date(activityAt).toISOString());
    } else if (event.type === "agent_start" || this.hasCurrentDashboardWork()) {
      this.noteDashboardActivity();
    }
    switch (event.type) {
      case "agent_start":
      case "agent_end":
      case "agent_settled":
      case "compaction_start":
      case "compaction_end":
      case "auto_retry_start":
      case "summarization_retry_scheduled":
      case "summarization_retry_attempt_start":
      case "summarization_retry_finished":
      case "auto_retry_end":
        this.runEvents.onEvent(event);
        break;
      case "message_start": {
        if (event.message.role === "assistant") {
          this.flushPendingProgress();
          this.captureStreamIdentity(event.message, true);
          if (this.toolSegmentAwaitsAssistantOwner) {
            this.ownToolSegment(this.streamPresentationId);
            // Segment authority must precede any progress/tool delta from this
            // assistant; otherwise iOS could briefly apply the new tool against
            // the preceding segment's snapshot owner.
            this.publishSnapshot();
          }
        } else if (event.message.role === "user") {
          this.flushPendingProgress();
          const precedingToolSegmentId = this.activeToolSegmentId();
          // User input is a hard display-chain boundary even when lifecycle
          // callbacks overlap a preceding completion.
          this.ownToolSegment(this.activeOperationId);
          // Foreground admission is serialized. Claim the exact Pi object;
          // repeated text and crossing user callbacks cannot impersonate it.
          if (this.pendingPrompt && this.pendingPromptMessage === undefined) {
            this.pendingPromptMessage = event.message;
            this.runAbort.consumeStopSteeringRecoveryOwner(this.pendingPrompt.id);
          } else {
            // Pi removes steering from its string queue and emits queue_update
            // before this callback. Preserve that exact queue operation across
            // the event boundary; activeOperationId still belongs to the
            // enclosing foreground run and cannot identify the steering item.
            const dequeuedSteeringOperationID = this.runQueue.dequeuedSteeringOwners.shift();
            // Pi can stop streaming while an async input hook is deciding a
            // prompt that the Gateway initially classified for the queue. In
            // that case no queue_update arrives: the next otherwise-unowned
            // user object is exact proof that Pi admitted an ordinary prompt.
            const activeInvocation = this.runInvocations.invocationForOperation(this.activeOperationId);
            const pendingQueueAdmission = this.runQueue.pendingQueueAdmission;
            const reclassifiedAdmission = dequeuedSteeringOperationID === undefined
              && (activeInvocation === undefined
                || this.activeOperationId === pendingQueueAdmission?.id)
              ? pendingQueueAdmission
              : undefined;
            if (reclassifiedAdmission) {
              this.runQueue.pendingQueueAdmission = undefined;
              reclassifiedAdmission.resolveDisposition("foreground");
              const displacedOwner = this.activeOperationId;
              if (displacedOwner !== reclassifiedAdmission.id) {
                this.runInvocations.terminalizeTransferredOperation(displacedOwner);
                this.runTerminal.retireOperationObservation(displacedOwner);
              }
              this.activeOperationId = reclassifiedAdmission.id;
              this.homeRequestPolicy?.transferOperation(displacedOwner, reclassifiedAdmission.id);
              const invocation = this.runInvocations.invocationForOperation(reclassifiedAdmission.id);
              this.operation = {
                id: reclassifiedAdmission.id,
                kind: "prompt",
                startedAt: new Date().toISOString(),
                ...(invocation?.invocationId ? { invocationId: invocation.invocationId } : {}),
              };
              this.ownToolSegment(reclassifiedAdmission.id);
              const work = this.runWork.get(reclassifiedAdmission.id)
                ?? this.runWork.beginDerivedOperationWork(reclassifiedAdmission.id, "foreground-agent-operation");
              work.transition("foreground-agent-operation");
              void this.enqueueMarkerOwnership(reclassifiedAdmission.id).then(async () => {
                if (displacedOwner) await this.clearMarkerOwnership(displacedOwner);
                this.runWork.settleOperationWork(displacedOwner);
              }).catch(() => this.runtime.session.abort());
            }
            const operationId = dequeuedSteeringOperationID
              ?? reclassifiedAdmission?.id
              ?? this.activeOperationId;
            // User input is also the canonical tool-segment boundary. Rotate to
            // the exact nested steering/reclassified prompt owner rather than
            // retaining the enclosing agent operation's older segment.
            if (operationId) this.ownToolSegment(operationId);
            const invocation = this.runInvocations.invocationForOperation(operationId);
            if (operationId && invocation) {
              this.pendingInvocationUserMessages.set(event.message, {
                operationId,
                invocationId: invocation.invocationId,
              });
              if (dequeuedSteeringOperationID) {
                this.runQueue.consumedSteeringOperationIDs.add(dequeuedSteeringOperationID);
                this.runAbort.consumeStopSteeringRecoveryOwner(dequeuedSteeringOperationID);
              }
            }
          }
          if (this.activeToolSegmentId() !== precedingToolSegmentId) {
            // Publish the new no-match owner before a new-segment tool delta can
            // arrive; the canonical user append follows on the scheduled frame.
            this.publishSnapshot();
          }
        } else if (event.message.role === "custom" && this.isInboxAttributed(event.message)) {
          this.flushPendingProgress();
        } else if (event.message.role === "custom") {
          this.flushPendingProgress();
          // Pi emits stored messages after their exact canonical append and
          // turn-triggering messages before it. Capture that ordering boundary,
          // never payload/type/renderer identity, then bind at message_end.
          if (this.pendingContextMessages.length >= 128) {
            this.pendingContextMessages.shift();
            this.emit("session.extensionError", safeJson({
              message: "Custom message attribution reached its pending capacity",
            }));
          }
          const latest = this.sessionManager.getLeafEntry();
          const storedTarget = latest && (latest.type === "custom_message"
              || (latest.type === "message" && latest.message.role === "custom"))
            ? latest.id : undefined;
          const managedMessage = capturedManagedMessage(event.message.content);
          const origin = isManagedProducerContent(event.message.content)
            ? managedMessage?.origin
            : this.currentExtensionContextOrigin();
          const toolSegmentOwnerId = event.message.display
            ? (storedTarget ? (this.presentationIDs.get(storedTarget) ?? storedTarget) : randomUUID())
            : undefined;
          if (toolSegmentOwnerId) {
            this.ownToolSegment(toolSegmentOwnerId);
            this.publishSnapshot();
          }
          this.pendingContextMessages.push({
            kind: "context",
            delivery: storedTarget ? "stored" : "triggeredTurn",
            ...(storedTarget ? { targetEntryId: storedTarget } : {}),
            ...(origin ? { origin } : {}),
            ...(managedMessage ? { managedMessage } : {}),
            ...(toolSegmentOwnerId ? { toolSegmentOwnerId } : {}),
          });
        }
        break;
      }
      case "message_update": {
        if (!this.hasActiveAgentRun) break;
        this.runAttention.ensureAgentProjection();
        this.captureStreamIdentity(event.message);
        this.emitProgress(event.message);
        break;
      }
      case "tool_execution_start": {
        if (!this.hasActiveAgentRun) break;
        if ("parentToolCallId" in event && event.parentToolCallId) {
          this.updateNestedExtensionActivity(event, "running");
          this.projectNestedToolExecution(event, "running");
          break;
        }
        if (this.canonicalToolResultHandoffs.has(event.toolCallId)) break;
        this.runAttention.ensureAgentProjection();
        const now = new Date().toISOString();
        const existing = this.toolExecutions.get(event.toolCallId);
        if (!existing) {
          // A fresh lifecycle owns fresh metadata. If this exact ID already has
          // a canonical result, fail closed as an invalid provider reuse;
          // otherwise discard interrupted/stale enrichment instead of merging
          // timing or lineage from an earlier invocation.
          if (this.toolMetadata.has(event.toolCallId)
            && this.isCanonicalToolResultOwned(event.toolCallId)) break;
          this.toolMetadata.delete(event.toolCallId);
          this.toolStartedAtMonotonicMs.delete(event.toolCallId);
        }
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
          toolSegmentId: this.activeToolSegmentId()!,
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
        if ("parentToolCallId" in event && event.parentToolCallId) {
          this.updateNestedExtensionActivity(event, "running", event.partialResult);
          this.projectNestedToolExecution(event, "running");
          break;
        }
        if (this.canonicalToolResultHandoffs.has(event.toolCallId)) break;
        this.runAttention.ensureAgentProjection();
        const now = new Date().toISOString();
        const existing = this.toolExecutions.get(event.toolCallId);
        const output = mergeLiveToolOutput(existing, projectToolOutput(event.partialResult, undefined, event.toolName));
        const startedAt = existing?.startedAt ?? now;
        const durationMs = this.measureToolDuration(
          event.toolCallId,
          startedAt,
          now,
          performance.now()
        );
        const extensionOrigin = this.extensionToolOrigin(event.toolName) ?? existing?.extensionOrigin;
        const nestedCalls = this.nestedToolCallsFromDetails(event.partialResult) ?? existing?.nestedCalls;
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
          partialResult: projectToolResult(event.partialResult, undefined, event.toolName),
          ...(nestedCalls ? { nestedCalls } : {}),
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
          toolSegmentId: existing?.toolSegmentId ?? this.activeToolSegmentId()!,
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
        if (!("parentToolCallId" in event && event.parentToolCallId) && event.toolName === "codemode") {
          const details = event.result && typeof event.result === "object" && "details" in event.result
            ? event.result.details as Record<string, unknown> | undefined : undefined;
          const nestedState = this.toolExecutions.get(event.toolCallId)?.nestedCalls;
          const status = typeof details?.status === "string" ? details.status : undefined;
          const outcome = status === "aborted" || status === "timeout" ? status : event.isError ? "failed" : "completed";
          const retained = this.toolMetadata.get(event.toolCallId);
          const startedAt = this.toolStartedAtMonotonicMs.get(event.toolCallId);
          const durationMs = startedAt === undefined ? retained?.durationMs ?? 0 : Math.max(0, performance.now() - startedAt);
          const complete = nestedState?.complete ?? (typeof details?.complete === "boolean" ? details.complete : true);
          this.dependencies.codemodeDiagnostic?.({ sessionId: this.id, outcome, durationMs, nestedCallCount: nestedState?.calls.length ?? 0, complete });
        }
        if ("parentToolCallId" in event && event.parentToolCallId) {
          this.updateNestedExtensionActivity(event, event.isError ? "failed" : "completed", event.result);
          this.projectNestedToolExecution(event, event.isError ? "failed" : "completed");
          break;
        }
        this.runAttention.ensureAgentProjection();
        const now = new Date().toISOString();
        const existing = this.toolExecutions.get(event.toolCallId);
        // Canonical handoff can precede a compatibility terminal callback.
        // Retained metadata and the monotonic start remain valid execution
        // evidence after the disposable runtime row is retired.
        const retained = this.toolMetadata.get(event.toolCallId);
        const startedAt = existing?.startedAt ?? retained?.startedAt ?? now;
        const canonicalOwned = this.isCanonicalToolResultOwned(event.toolCallId);
        const hasMonotonicStart = this.toolStartedAtMonotonicMs.has(event.toolCallId);
        // A continuation clears monotonic starts for the preceding run. If its
        // already-canonical terminal callback arrives afterward, retain the
        // handoff sample rather than extending it to callback-arrival wall time.
        const measuredDurationMs = !existing && retained && canonicalOwned && !hasMonotonicStart
          ? retained.durationMs ?? 0
          : this.measureToolDuration(
              event.toolCallId,
              startedAt,
              now,
              performance.now()
            );
        const durationMs = Math.max(
          measuredDurationMs,
          existing?.durationMs ?? 0,
          retained?.durationMs ?? 0
        );
        const output = projectToolOutput(event.result, undefined, event.toolName);
        const extensionOrigin = this.extensionToolOrigin(event.toolName)
          ?? existing?.extensionOrigin
          ?? retained?.extensionOrigin;
        const nestedCalls = this.nestedToolCallsFromDetails(event.result) ?? existing?.nestedCalls;
        const toolLabel = existing?.toolLabel ?? retained?.toolLabel ?? this.toolLabel(event.toolName);
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
          result: projectToolResult(event.result, undefined, event.toolName),
          ...(nestedCalls ? { nestedCalls } : {}),
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
          progressSequence: Math.max(existing?.progressSequence ?? 0, retained?.progressSequence ?? 0) + 1,
          toolSegmentId: existing?.toolSegmentId ?? retained?.toolSegmentId ?? this.activeToolSegmentId()!,
          ...(retained?.groupId ? { groupId: retained.groupId } : {}),
          ...(retained?.groupIndex === undefined ? {} : { groupIndex: retained.groupIndex }),
          ...(retained?.groupCount === undefined ? {} : { groupCount: retained.groupCount }),
          ...(retained?.groupFinalized === undefined ? {} : { groupFinalized: retained.groupFinalized }),
          ...(this.toolInvocationGroups.get(event.toolCallId) ?? {}),
          ...(extensionOrigin ? { extensionOrigin } : {}),
          ...(extensionActivity ? { extensionActivity } : {}),
        };
        this.rememberToolMetadata(event.toolCallId, state);
        this.toolStartedAtMonotonicMs.delete(event.toolCallId);
        // A tool-result message_end can precede this terminal callback in Pi.
        // Keep its timing/lineage metadata for canonical enrichment, but never
        // re-admit the exact call to the disposable runtime overlay.
        if (canonicalOwned) {
          this.toolExecutions.delete(event.toolCallId);
          this.scheduleSnapshot();
          break;
        }
        this.toolExecutions.set(event.toolCallId, state);
        this.publishToolProgress(state, true);
        this.scheduleSnapshot();
        break;
      }
      case "entry_appended":
        this.summaryContentDirty = true;
        // Custom entries — context edits, extension callbacks — reach the log
        // only here, and they change what the memory projects just as messages do.
        this.noteCanonicalEntriesCommitted();
        if (event.entry.type === "message" && event.entry.message.role === "toolResult") {
          // Keep this compatibility path for extension/custom persistence, but
          // ordinary Pi tool results arrive through message_end below.
          this.markCanonicalToolResultHandoff(event.entry.message.toolCallId);
          if (event.entry.message.toolName === "display") this.reconcileCanonicalDisplayArtifacts();
        }
        this.emit("session.structureChanged", { branchChanged: false });
        this.scheduleSnapshot();
        break;
      case "message_end":
        // Pi emits message_end immediately before the canonical append and does
        // not emit entry_appended for ordinary prompt/response messages. Retire
        // the cached row facts now and publish after the append microtask so a
        // new session's first prompt updates its title without a Gateway restart.
        this.summaryContentDirty = true;
        this.scheduleSnapshot();
        this.noteCanonicalEntriesCommitted();
        if (event.message.role === "toolResult") {
          // Pi invokes listeners immediately before appending this exact
          // object. Verify canonical call-ID ownership in the next microtask;
          // a failed persistence attempt must not create a runtime/canonical
          // gap merely because message_end was observed.
          this.observeCanonicalToolResultHandoff(event.message);
        } else if (event.message.role === "assistant") {
          this.finalizeToolInvocationGroups(event.message);
          this.bindCanonicalPresentation(event.message);
        } else if (event.message.role === "custom" && this.isInboxAttributed(event.message)) {
          // Ordinary inbox messages are persisted by the inbox after their send
          // returns. A wake's trigger is persisted by its run, so its receipts must
          // exist before the run's reply can complete the operation.
          const trigger = this.homeWakeTrigger;
          if (trigger && (event.message.details as { eventId?: unknown } | undefined)?.eventId === trigger.eventId) this.bindHomeWakeTrigger(trigger);
        } else if (event.message.role === "custom") {
          // Custom callbacks are serial. Stored sends already exposed their
          // exact canonical ID at message_start; triggered sends append as soon
          // as this listener returns, before the queued microtask runs.
          const pending = this.pendingContextMessages.shift();
          if (pending?.targetEntryId) {
            if (pending.toolSegmentOwnerId) {
              this.rememberPresentationID(pending.targetEntryId, pending.toolSegmentOwnerId);
            }
            this.enqueueExtensionCanonicalEffect({
              kind: "context",
              targetEntryId: pending.targetEntryId,
              delivery: pending.delivery,
              ...(pending.origin ? { origin: pending.origin } : {}),
              ...(pending.managedMessage ? { managedMessage: pending.managedMessage } : {}),
            });
          } else if (pending) {
            queueMicrotask(() => {
              const candidate = this.sessionManager.getLeafEntry();
              const isCustomMessage = candidate?.type === "custom_message"
                || (candidate?.type === "message" && candidate.message.role === "custom");
              if (!candidate || !isCustomMessage) {
                this.emit("session.extensionError", safeJson({
                  message: "Custom message did not acquire canonical context identity",
                }));
                return;
              }
              if (pending.toolSegmentOwnerId) {
                this.rememberPresentationID(candidate.id, pending.toolSegmentOwnerId);
              }
              this.enqueueExtensionCanonicalEffect({
                kind: "context",
                targetEntryId: candidate.id,
                delivery: pending.delivery,
                ...(pending.origin ? { origin: pending.origin } : {}),
                ...(pending.managedMessage ? { managedMessage: pending.managedMessage } : {}),
              });
            });
          }
        } else if (event.message.role === "user") {
          const queuedBinding = this.pendingInvocationUserMessages.get(event.message);
          if (queuedBinding) this.pendingInvocationUserMessages.delete(event.message);
          const operationID = this.pendingPromptMessage === event.message
            ? this.pendingPrompt?.id
            : queuedBinding?.operationId;
          const invocationID = operationID
            ? queuedBinding?.invocationId ?? this.runInvocations.invocationForOperation(operationID)?.invocationId
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
            // Pi can admit a same-agent queued follow-up without emitting a
            // second agent_start. The canonical user binding is the exact
            // prospective cut boundary; never fall back to session history.
            // Steering is nested input in the foreground run, not an observation owner.
            const isConsumedSteering = this.runQueue.consumedSteeringOperationIDs.has(operationID);
            const observationOwnerId = isConsumedSteering ? this.activeOperationId ?? operationID : operationID;
            if (isConsumedSteering || !this.runTerminal.operationObservations.get(observationOwnerId)?.cursor) {
              const canonical = this.canonicalSessionEntries();
              const entryIndex = canonical.findIndex(entry => entry.id === candidate.id);
              if (entryIndex >= 0) this.runTerminal.observationFor(observationOwnerId).cursor = { entryIndex };
            }
            // The live map is only an optimization. A fast run may already
            // have terminalized and evicted it; recover immutable ownership
            // from the canonical start receipt before binding.
            const invocation = this.runInvocations.invocationForOperation(operationID);
            if (!invocation || invocation.invocationId !== invocationID) {
              throw new Error("canonical invocation start receipt is unavailable");
            }
            await this.persistCanonicalCustomEntry(
              INVOCATION_RECEIPT_TYPE,
              receiptJSON(makeInvocationReceipt({
                version: 1,
                receiptId: `binding:${invocationID}`,
                receiptKind: "binding",
                invocationId: invocationID,
                operationId: operationID,
                sessionId: this.id,
                source: invocation.source,
                canonicalEntryId: candidate.id,
                sequence: this.revision + 1,
                createdAt: new Date().toISOString(),
              })),
              `binding:${invocationID}`,
              this.runWork.get(operationID),
            );
            // A steering item is a prompt admission nested inside the existing
            // foreground run. Its queue operation completes when this exact
            // canonical user entry is bound; the enclosing run retains its own
            // activeOperationId and completion lifecycle.
            if (this.runQueue.consumedSteeringOperationIDs.delete(operationID)) {
              await this.runInvocations.terminalizeInvocation(
                operationID,
                "completed",
                undefined,
                this.runWork.get(operationID),
              );
              this.runWork.settleOperationWork(operationID);
            }
            if (this.pendingPrompt?.id === operationID
              && this.pendingPromptMessage === message) {
              this.pendingPrompt = undefined;
              this.pendingPromptMessage = undefined;
            }
            this.scheduleSnapshot();
          }).catch((error) => this.emit("session.diagnostic", safeJson({
            code: "canonical-binding-persistence-failed",
            operationId: operationID,
            message: error instanceof Error ? error.message : String(error),
          })));
        }
        this.scheduleSnapshot();
        break;
      case "queue_update":
        if (!this.runQueue.suppressQueueEvents) this.runQueue.reconcileQueuedMessages();
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
      // Turn boundaries and incremental bash output carry no Gateway runtime
      // state: canonical entries and the message/tool cases above own every
      // projection, and attention settlement keys off agent_start/agent_settled.
      case "turn_start":
      case "turn_end":
      case "bash_execution_update":
        break;
      default: {
        // Unreachable for the pinned SDK: every AgentSessionEvent type is
        // classified above. A new SDK event fails this assignment instead of
        // being ignored without a runtime projection.
        event satisfies never;
        break;
      }
    }
  }

  /** Provider artifact shape policy lives in the delegated-provider module. */
  private extensionArtifactPathAllowed(asyncPath: string): boolean {
    return delegatedArtifactPathAllowed(asyncPath, this.cwd, this.dependencies.delegatedArtifactRoot);
  }

  private subagentExtensionOrigin(): ExtensionToolOrigin {
    return delegatedProviderOrigin(this.runtime?.session.resourceLoader.getExtensions().extensions ?? []);
  }

  private isForegroundSubagentTool(toolName: string, origin: ExtensionToolOrigin | undefined): boolean {
    return isInstalledDelegatedTool(toolName, origin, this.subagentExtensionOrigin().owner?.id);
  }

  /** Return only the exact installed controller already admitted for subagent
   * projection. Pi can reload a package through its resolved local path,
   * so the opaque installed-owner identity—not the mutable source label—is the
   * authority boundary. */
  private trustedSubagentController(): ToolDefinition | undefined {
    const session = this.runtime?.session;
    if (!session) return undefined;
    return trustedDelegatedController({
      toolName: DELEGATED_PROVIDER_TOOL_NAME,
      origin: this.extensionToolOrigin(DELEGATED_PROVIDER_TOOL_NAME),
      installedOwnerId: this.subagentExtensionOrigin().owner?.id,
      definitionFor: (name: string) => session.extensionRunner.getToolDefinition(name),
    });
  }

  private async openOwnedExtensionArtifact(
    asyncDir: string,
    name: "status.json" | "events.jsonl" | "recovery-descriptor.json" | "process-terminal.json",
    expectedDirectory?: ExtensionArtifactDirectoryIdentity,
  ): Promise<OpenedExtensionArtifact | undefined> {
    const canonicalAsyncDir = realpathSync(asyncDir);
    if (canonicalAsyncDir !== asyncDir || !this.extensionArtifactPathAllowed(canonicalAsyncDir)) return undefined;
    const directory = await stat(canonicalAsyncDir);
    if (!directory.isDirectory()
      || expectedDirectory && (directory.dev !== expectedDirectory.dev || directory.ino !== expectedDirectory.ino)) return undefined;
    const lexicalPath = join(canonicalAsyncDir, name);
    let canonicalPath: string;
    try {
      canonicalPath = realpathSync(lexicalPath);
    } catch (error) {
      // Status artifacts are atomically replaced. A bounded watcher retry owns
      // the brief unlink/rename window; do not turn it into an unretried read
      // failure that can strand the previous running projection.
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
      throw error;
    }
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

  /** Released workflows keep execution details in their detached children's
   * status, not the workflow edge. Join only exact reciprocal producer edges;
   * root identity/order remains authoritative and every read is disposable. */
  private async readWorkflowChildDetails(asyncDir: string, status: Record<string, unknown>): Promise<Record<string, unknown>> {
    if (status.mode !== "workflow" || typeof status.runId !== "string" || !Array.isArray(status.steps)) return status;
    const directories: string[] = [];
    let unavailableChildren = 0;
    const steps: unknown[] = [];
    for (const value of status.steps.slice(0, MAX_EXTENSION_RUN_CHILDREN)) {
      if (!value || typeof value !== "object" || Array.isArray(value)) { steps.push(value); continue; }
      const edge = value as Record<string, unknown>;
      steps.push(edge);
      if (edge.async !== true || typeof edge.runId !== "string" || !edge.runId
        || Buffer.byteLength(edge.runId) > 256 || /[\\/\0]/u.test(edge.runId)
        || typeof edge.workflowKey !== "string" || typeof edge.sessionOwnerId !== "string"
        || typeof edge.sessionFile !== "string") continue;
      const directory = join(dirname(asyncDir), edge.runId);
      if (dirname(directory) !== dirname(asyncDir) || directory === asyncDir) continue;
      // Observation follows the root edge, never the optional read result.
      // Even an absent directory must remain subscribed for its first status.
      directories.push(directory);
      unavailableChildren += 1;
      const child = await this.readExtensionStatusArtifact(directory, false).catch(() => undefined);
      if (!child || child.runId !== edge.runId || child.parentWorkflowRunId !== status.runId
        || child.workflowKey !== edge.workflowKey || child.sessionOwnerId !== edge.sessionOwnerId || child.sessionId !== status.sessionId
        || child.mode !== "single" || !Array.isArray(child.steps) || child.steps.length !== 1) continue;
      const detail = child.steps[0];
      if (!detail || typeof detail !== "object" || Array.isArray(detail)) continue;
      const source = detail as Record<string, unknown>;
      if (source.sessionFile !== edge.sessionFile || source.agent !== edge.agent
        || !this.childSessionAdmission.admit(edge.sessionFile, status.runId, edge.workflowKey, edge.sessionOwnerId)) continue;
      unavailableChildren -= 1;
      // Do not copy child identity, declarations or control authority. Only
      // provider-authored display facts cross this already verified edge.
      const projected = { ...edge };
      for (const key of ["model", "thinking", "currentTool", "currentPath", "lastActivityAt", "currentToolStartedAt",
        "toolCount", "turnCount", "recentOutput", "output", "error", "attention", "attentionState", "startedAt", "endedAt", "durationMs", "status"] as const) {
        if (source[key] !== undefined) projected[key] = source[key];
      }
      // The child run's own state is the authority for whether it is still live. Its runner
      // records the step's terminal status first and persists the run's terminal state only
      // after finishing its result, so a terminal step under a running run is still live work
      // that settlement must join (#1021).
      if (typeof child.state === "string") projected.state = child.state;
      // A paused child remains resumable history, not running work, once its own
      // runner's exit proof is admitted. Keep that fact private to this exact read.
      if (observedPausedProcessTerminalAt(child, edge.runId) !== undefined) {
        Object.assign(projected, { [WORKFLOW_CHILD_PROCESS_SETTLED]: true });
      }
      // The released single-child snapshot omits a zero total until its first
      // tool event; an explicitly empty recent-tools list proves that zero.
      if (source.toolCount === undefined && Array.isArray(source.recentTools) && source.recentTools.length === 0) projected.toolCount = 0;
      steps[steps.length - 1] = projected;
    }
    const omission = status.lifecycleOmissions as { children?: number; byteLimitExceeded?: boolean } | undefined;
    const omittedChildren = typeof omission?.children === "number" && Number.isSafeInteger(omission.children) && omission.children >= 0
      ? omission.children : 0;
    return Object.assign({ ...status, steps: [...steps, ...status.steps.slice(MAX_EXTENSION_RUN_CHILDREN)],
      ...(unavailableChildren > 0 ? { lifecycleOmissions: {
        children: omittedChildren + unavailableChildren,
        byteLimitExceeded: omission?.byteLimitExceeded === true,
      } } : {}),
    }, { [WORKFLOW_CHILD_ARTIFACT_DIRECTORIES]: directories });
  }

  private syncWorkflowChildArtifactWatchers(toolCallId: string, value: Record<string, unknown>): void {
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

  private async readExtensionStatusArtifact(asyncDir: string, includeWorkflowChildren = true): Promise<Record<string, unknown> | undefined> {
    if (!this.extensionArtifactPathAllowed(asyncDir)) return undefined;
    const opened = await this.openOwnedExtensionArtifact(asyncDir, "status.json");
    if (!opened) return undefined;
    try {
      // The compact header admits parent/run ownership. Native children and
      // details come from the full bounded status, not the widget's eight-row
      // summary. Keep the header as bounded lifecycle evidence on overflow.
      const headerBuffer = Buffer.alloc(MAX_EXTENSION_LIFECYCLE_HEADER_BYTES);
      const { bytesRead: headerBytesRead } = await opened.handle.read(headerBuffer, 0, headerBuffer.length, 0);
      const headerBytes = headerBuffer.subarray(0, headerBytesRead);
      const lifecycleHeader = parseExtensionLifecycleProjectionHeader(headerBytes);
      if (lifecycleHeader !== undefined) {
        const projection = inspectExtensionLifecycleProjection(lifecycleHeader);
        if (!projection) throw new SyntaxError("Invalid extension lifecycle projection header");
        // The producer retains the original parent session identity across resumes.
        // Exact run/tool/path ownership does not authorize a header copied from another session.
        const parentIdentity = this.sessionFile ? resolve(this.sessionFile) : this.id;
        if (projection.sessionId !== undefined && projection.sessionId !== parentIdentity) {
          throw new ForeignExtensionArtifactSessionError();
        }
        const buffer = Buffer.alloc(MAX_EXTENSION_ARTIFACT_BYTES + 1);
        const { bytesRead } = await opened.handle.read(buffer, 0, buffer.length, 0);
        const full: unknown = bytesRead <= MAX_EXTENSION_ARTIFACT_BYTES ? JSON.parse(buffer.subarray(0, bytesRead).toString("utf8")) : undefined;
        if (full !== undefined && (!full || typeof full !== "object" || Array.isArray(full))) throw new SyntaxError("Invalid full extension status");
        const status = full as Record<string, unknown> | undefined;
        if (status && (status.runId !== projection.runId
          || (projection.toolCallId !== undefined && status.toolCallId !== projection.toolCallId))) throw new ForeignExtensionArtifactSessionError();
        const projected = status ? { ...status, lifecycleArtifactVersion: EXTENSION_LIFECYCLE_ARTIFACT_VERSION }
          : lifecycleProjectionArtifact({ ...projection, omitted: { ...projection.omitted, byteLimitExceeded: true } });
        const detailed = includeWorkflowChildren ? await this.readWorkflowChildDetails(asyncDir, projected) : projected;
        const withRecovery = await this.attachRecoverySessionOwner(asyncDir, detailed, opened.directory);
        const withProof = await this.attachProcessTerminalProof(asyncDir, withRecovery, opened.directory);
        return markEmbeddedLifecycleArtifact(withProof);
      }
      // A first lifecycleProjection key marks a modern artifact even when its
      // value is truncated or malformed; do not fall back to report parsing.
      if (hasExtensionLifecycleProjectionProperty(headerBytes)) {
        throw new SyntaxError("Incomplete extension lifecycle projection header");
      }
      const buffer = Buffer.alloc(MAX_EXTENSION_ARTIFACT_BYTES + 1);
      const { bytesRead } = await opened.handle.read(buffer, 0, buffer.length, 0);
      const bytes = buffer.subarray(0, bytesRead);
      if (bytesRead > MAX_EXTENSION_ARTIFACT_BYTES) {
        const terminal = await this.readOversizedTerminalExtensionArtifact(
          asyncDir,
          bytes.subarray(0, MAX_EXTENSION_ARTIFACT_BYTES),
          opened.directory,
        );
        if (!terminal) throw new OversizedExtensionArtifactError();
        return terminal;
      }
      const parsed: unknown = JSON.parse(bytes.toString("utf8"));
      if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return undefined;
      const recovered = await this.attachRecoverySessionOwner(asyncDir, parsed as Record<string, unknown>, opened.directory);
      return this.attachProcessTerminalProof(asyncDir, recovered, opened.directory);
    } finally {
      await opened.handle.close();
    }
  }

  /** The producer persists process-terminal.json before best-effort status
   * overlay. Read that exact-owned sidecar so an interrupted overlay cannot
   * leave an exited paused runner blocking restart forever. */
  private async attachProcessTerminalProof(
    asyncDir: string,
    status: Record<string, unknown>,
    directoryIdentity: ExtensionArtifactDirectoryIdentity,
  ): Promise<Record<string, unknown>> {
    const withoutProof = (): Record<string, unknown> => {
      const { processTerminal: _processTerminal, ...remaining } = status;
      return remaining;
    };
    const runId = typeof status.runId === "string" ? status.runId : undefined;
    if (!runId || Buffer.byteLength(runId) > 256 || /[\\/\0]/u.test(runId)) return withoutProof();
    const opened = await this.openOwnedExtensionArtifact(
      asyncDir,
      "process-terminal.json",
      directoryIdentity,
    ).catch(() => undefined);
    if (!opened) return status;
    try {
      const buffer = Buffer.alloc(MAX_EXTENSION_ARTIFACT_BYTES + 1);
      const { bytesRead } = await opened.handle.read(buffer, 0, buffer.length, 0);
      if (bytesRead > MAX_EXTENSION_ARTIFACT_BYTES) return withoutProof();
      const parsed: unknown = JSON.parse(buffer.subarray(0, bytesRead).toString("utf8"));
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)
        || (parsed as Record<string, unknown>).runId !== runId) return withoutProof();
      return { ...status, processTerminal: parsed as Record<string, unknown> };
    } catch {
      return withoutProof();
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
    for (const [runId, fact] of this.canonicalExtensionRunFacts()) {
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

  private observeMissingExtensionArtifact(toolCallId: string): void {
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
      ?? extensionActivityId(this.runtime.session.sessionManager.getSessionId(), toolCallId);
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
    this.upsertExtensionActivity(unavailable);
    this.publishExtensionActivity(unavailable);
    this.stopExtensionActivityWatcher(toolCallId);
  }

  /** Called only by the Gateway-scoped bounded artifact discovery owner or by
   * a watcher attached after this slot proved canonical ownership. The outcome
   * tells a caller whether it may record this exact artifact as dealt with: an
   * offer the slot could not decide (`transient`) must leave no record, or a
   * run known only from a saved session log is never offered again (G-8a). */
  discoverExtensionArtifact(asyncDir: string): Promise<ExtensionArtifactDiscoveryOutcome> {
    return this.refreshSubagentActivityFromArtifact(asyncDir);
  }

  /** Administrative drain gets a direct, bounded reconciliation lane for
   * exact-owned artifacts instead of depending on watcher delivery or ambient
   * discovery scheduling. Genuine nonterminal work remains a blocker. */
  async reconcileOwnedExtensionArtifactsForDrain(): Promise<void> {
    if (this.runAttention.completionOwnershipQueue.length > 0 && !this.runAttention.attentionBarrier) {
      await this.runAttention.drainCompletionOwnership().catch(() => {
        this.emit("session.diagnostic", safeJson({
          code: "canonical-completion-persistence-retrying",
          message: "Canonical completion persistence is retrying",
        }));
      });
    }
    const canonicalFacts = this.canonicalExtensionRunFacts();
    for (const asyncDir of this.ownedExtensionArtifactDirectories()) {
      await this.refreshSubagentActivityFromArtifact(asyncDir, canonicalFacts);
    }
    await this.runWork.reconcileOrphanedForegroundWorkForDrain();
  }

  private async refreshSubagentActivityFromArtifact(
    asyncDir: string,
    canonicalFacts?: ReadonlyMap<string, CanonicalExtensionRunFact>,
  ): Promise<ExtensionArtifactDiscoveryOutcome> {
    let diagnosticOwner: string | undefined;
    let missingToolCallId: string | undefined;
    let claimedReceipt: { activityId: string; owner: GatewayWorkHandle } | undefined;
    try {
      const lexicalDirectory = resolve(asyncDir);
      const realAsyncDir = this.canonicalExtensionArtifactDirectory(asyncDir);
      const bound = [...this.extensionRunOwnership.entries()].find(([, binding]) =>
        binding.asyncDir !== undefined && (resolve(binding.asyncDir) === lexicalDirectory
          || realAsyncDir !== undefined
            && this.canonicalExtensionArtifactDirectory(binding.asyncDir) === realAsyncDir));
      missingToolCallId = bound?.[1].toolCallId;
      if (!realAsyncDir) {
        if (bound) this.observeMissingExtensionArtifact(bound[1].toolCallId);
        return "transient";
      }
      diagnosticOwner = this.extensionArtifactOwnerForDirectory(realAsyncDir);
      const rawValue = await this.readExtensionStatusArtifactWithReplacementRetry(realAsyncDir);
      if (rawValue === undefined) {
        if (bound) this.observeMissingExtensionArtifact(bound[1].toolCallId);
        if (diagnosticOwner) this.warnExtensionArtifact("artifact-replacement-in-progress", diagnosticOwner);
        return "transient";
      }
      if (bound) this.extensionArtifactMissingSince.delete(bound[1].toolCallId);
      // Registry discovery is bounded but grants no ownership. Historical
      // artifacts become admissible only here, where the canonical tool result
      // or an exact live asyncDir binding proves the owning session/tool call.
      const admission = inspectExtensionLifecycleArtifact(rawValue, { exactOwnedLegacy: true });
      if (!admission.accepted) {
        if (diagnosticOwner) this.warnExtensionArtifact(admission.reason, diagnosticOwner);
        return "rejected";
      }
      const raw = admission.artifact;
      const runId = raw.runId as string;
      if (!runId) return "rejected";
      // The file's declared directory is advisory. If present, it must agree
      // with the directory that was actually discovered/read; a declared path
      // this slot cannot resolve is retried rather than recorded.
      if (typeof raw.asyncDir === "string") {
        const declaredAsyncDir = this.canonicalExtensionArtifactDirectory(raw.asyncDir);
        if (!declaredAsyncDir) return "transient";
        if (declaredAsyncDir !== realAsyncDir) {
          if (diagnosticOwner) this.warnExtensionArtifact("ownership-mismatch", diagnosticOwner);
          return "rejected";
        }
      }
      const ownership = this.extensionRunOwnership.get(runId);
      const canonical = (canonicalFacts ?? this.canonicalExtensionRunFacts()).get(runId);
      const historicalArtifact = raw.lifecycleArtifactVersion !== EXTENSION_LIFECYCLE_ARTIFACT_VERSION;
      if (historicalArtifact && !ownership?.asyncDir && !canonical?.asyncDir) return "transient";
      // A duplicated runId in canonical JSONL has no safe artifact owner.
      if (canonical?.ambiguous) {
        if (diagnosticOwner) this.warnExtensionArtifact("ownership-mismatch", diagnosticOwner);
        return "transient";
      }
      // An ownership or canonical comparison is decided against state this slot
      // re-reads every pass, so the same bytes may be admissible later.
      if (ownership?.asyncDir) {
        const ownershipAsyncDir = this.canonicalExtensionArtifactDirectory(ownership.asyncDir);
        if (!ownershipAsyncDir || ownershipAsyncDir !== realAsyncDir) {
          if (diagnosticOwner) this.warnExtensionArtifact("ownership-mismatch", diagnosticOwner);
          return "transient";
        }
      }
      if (canonical?.asyncDir) {
        const canonicalAsyncDir = this.canonicalExtensionArtifactDirectory(canonical.asyncDir);
        if (!canonicalAsyncDir || canonicalAsyncDir !== realAsyncDir) {
          if (diagnosticOwner) this.warnExtensionArtifact("ownership-mismatch", diagnosticOwner);
          return "transient";
        }
      }
      if (canonical?.toolCallId && ownership && ownership.toolCallId !== canonical.toolCallId) {
        // A synthetic artifact row may be re-keyed to its first real tool call,
        // but a real ownership binding must never switch to another call.
        if (!ownership.toolCallId.startsWith("subagent:") || ownership.toolCallId === canonical.toolCallId) {
          if (diagnosticOwner) this.warnExtensionArtifact("ownership-mismatch", diagnosticOwner);
          return "transient";
        }
      }
      const matchingEntries = [...this.extensionActivities.entries()].filter(([, activity]) => activity.runId === runId);
      // Correlation is Gateway-owned; never pick an arbitrary activity when a
      // malformed or legacy payload has produced duplicate run identities.
      if (!ownership && !canonical?.toolCallId && matchingEntries.length > 1) {
        if (diagnosticOwner) this.warnExtensionArtifact("ownership-mismatch", diagnosticOwner);
        return "transient";
      }
      const boundToolCallId = canonical?.toolCallId ?? ownership?.toolCallId;
      if (isEmbeddedLifecycleArtifact(rawValue) && raw.toolCallId !== undefined && raw.toolCallId !== boundToolCallId) {
        if (diagnosticOwner) this.warnExtensionArtifact("ownership-mismatch", diagnosticOwner);
        return "rejected";
      }
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
      if (!existingEntry?.[1] && !canonical?.toolCallId) return "transient";
      if (!existingEntry?.[1] && canonical?.toolCallId) {
        existingEntry = [canonical.toolCallId, this.extensionActivities.get(canonical.toolCallId)];
      }
      const toolCallId = existingEntry?.[0];
      if (!toolCallId) return "transient";
      const previous = existingEntry?.[1];
      const normalized = normalizeExtensionArtifact(raw, {
        now: new Date().toISOString(),
        ...(previous?.startedAt ? { fallbackStartedAt: previous.startedAt } : {}),
        ...(previous?.updatedAt ? { fallbackUpdatedAt: previous.updatedAt } : {}),
        // A recovery handoff has no launcher row to supply a start time.
        // Once admitted, keep that first start stable across later updates.
        useArtifactStartedAt: previous === undefined,
      });
      if (!normalized) {
        if (diagnosticOwner) this.warnExtensionArtifact("invalid-timestamp", diagnosticOwner);
        return "rejected";
      }
      const { status: state, startedAt, updatedAt, completedAt, durationMs } = normalized;
      const facts = canonicalFacts ?? this.canonicalExtensionRunFacts();
      const recoveryClaim = recoveredReplacementClaim(raw);
      const sourceFact = facts.get(runId);
      const pausedProcessSettledAt = observedPausedProcessTerminalAt(raw, runId);
      const processTerminal = pausedProcessSettledAt !== undefined;
      const rawLastUpdate = raw.lastUpdate;
      const rawEndedAt = raw.endedAt;
      // Only the exact provider recovery receipt plus the original paused
      // runner's terminal proof can settle this source. A later explicit
      // resume leaves the historical marker behind but has a new live state or
      // timestamps, so it must not be terminalized by that old marker.
      const superseded = extensionLifecycleState(raw.state ?? raw.status) === "paused"
        && recoveryClaim !== undefined
        && sourceFact?.recoveredReplacementRunId === recoveryClaim.replacementRunId
        && sourceFact.ambiguous !== true
        && processTerminal
        && typeof rawLastUpdate === "number" && Number.isSafeInteger(rawLastUpdate)
        && rawLastUpdate <= recoveryClaim.recoveredAt
        && typeof rawEndedAt === "number" && Number.isSafeInteger(rawEndedAt)
        && rawEndedAt <= recoveryClaim.recoveredAt;
      const effectiveState = superseded ? "completed" : state;
      const effectiveCompletedAt = superseded ? completedAt ?? updatedAt : completedAt;
      // A terminal lifecycle event is authoritative; a late running artifact
      // enriches neither status nor ownership and must not resurrect the pill.
      // The latch cannot lift for this identity, so the bytes are rejected.
      if (ownership?.terminal && state === "running") return "rejected";
      const artifactValue = ownership?.terminal
        ? preserveEmbeddedLifecycleMarker(raw, { ...raw, state: previous?.status === "failed" ? "failed" : "completed" })
        : superseded
          ? preserveEmbeddedLifecycleMarker(raw, { ...raw, state: "stopped", supersededByRunId: recoveryClaim!.replacementRunId })
          : raw;
      const activityKey = previous?.activityId ?? extensionActivityId(this.runtime.session.sessionManager.getSessionId(), toolCallId);
      const sequence = (this.extensionActivitySequences.get(activityKey) ?? previous?.lifecycle?.sequence ?? 0) + 1;
      this.extensionActivitySequences.set(activityKey, sequence);
      const observedAt = new Date().toISOString();
      const terminalAt = effectiveState === "running"
        ? previous?.lifecycle?.terminalAt
        : previous?.lifecycle?.terminalAt
          ?? (previous === undefined ? rediscoveredTerminalAt(effectiveState, effectiveCompletedAt, observedAt) : observedAt);
      const recentUntil = terminalAt ? new Date(Date.parse(terminalAt) + 900_000).toISOString() : undefined;
      const activity = this.childSessionAdmission.attach(projectExtensionRunActivity(artifactValue, {
        id: previous?.id ?? toolCallId,
        activityId: activityKey,
        toolCallId,
        source: previous?.source ?? this.subagentExtensionOrigin(),
        title: previous?.title ?? "Subagents",
        mode: "asynchronous",
        status: effectiveState,
        authoritativeStatus: effectiveState !== "running" || previous?.lifecycle?.state === "completed" || previous?.lifecycle?.state === "failed" || previous?.lifecycle?.state === "stopped" || previous?.lifecycle?.state === "rejected",
        startedAt,
        updatedAt,
        ...(effectiveCompletedAt ? { completedAt: effectiveCompletedAt } : {}),
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
      if (admitExtensionRunActivity(previous, activity) === previous) return "rejected";
      const terminalReceiptOwner = activity.status === "running"
        ? undefined
        : this.claimExtensionReceiptOwnership(activityKey);
      // A full Gateway work registry is temporary: the terminal receipt can be
      // claimed by a later pass, so this artifact is not delivered yet.
      if (activity.status !== "running" && !terminalReceiptOwner) return "transient";
      if (terminalReceiptOwner) claimedReceipt = { activityId: activityKey, owner: terminalReceiptOwner };
      // Ownership facts are written before this frame's projection publishes:
      // settled paused presentation, dashboard activity, and drain accounting
      // all read them from the same frame.
      const ownershipAccepted = this.bindExtensionRunOwnership(runId, {
        toolCallId,
        asyncDir: realAsyncDir,
        terminal: activity.status !== "running" || Boolean(ownership?.terminal),
        ...(pausedProcessSettledAt ? { pausedProcessQuiescentAt: pausedProcessSettledAt } : {}),
        detachedChildKeys: detachedWorkflowChildKeys(raw),
      });
      if (!ownershipAccepted) {
        this.releaseExtensionReceiptOwnership(activityKey, terminalReceiptOwner);
        claimedReceipt = undefined;
        if (diagnosticOwner) this.warnExtensionArtifact("ownership-mismatch", diagnosticOwner);
        return "transient";
      }
      if (existingEntry) this.extensionActivities.delete(existingEntry[0]);
      const syntheticToolCallId = matchingEntries.find(([id]) => id.startsWith("subagent:") && id !== toolCallId)?.[0];
      if (syntheticToolCallId) this.extensionActivities.delete(syntheticToolCallId);
      this.extensionActivities.delete(toolCallId);
      this.extensionActivities.set(toolCallId, activity);
      this.upsertExtensionActivity(activity);
      if (activity.status !== "running") {
        void this.appendExtensionActivityReceipt(activity).catch((error) => this.emit("session.extensionError", safeJson(error)));
        claimedReceipt = undefined;
      }
      if (this.extensionActivityWatchRequired(activity)) this.startExtensionActivityWatcher(toolCallId, realAsyncDir);
      else this.stopExtensionActivityWatcher(toolCallId);
      this.trimExtensionActivities();
      this.publishExtensionActivity(activity);
      return "accepted";
    } catch (error) {
      if (claimedReceipt) this.releaseExtensionReceiptOwnership(claimedReceipt.activityId, claimedReceipt.owner);
      if (error instanceof OversizedExtensionArtifactError && missingToolCallId) {
        this.observeMissingExtensionArtifact(missingToolCallId);
      }
      if (diagnosticOwner) this.warnExtensionArtifact(extensionArtifactReadFailureReason(error), diagnosticOwner);
      // An artifact that is too large or belongs to another session keeps that
      // verdict for these bytes; every other failure is retried by the caller.
      return error instanceof OversizedExtensionArtifactError || error instanceof ForeignExtensionArtifactSessionError
        ? "rejected"
        : "transient";
    }
  }

  /** The discovery lane's read of one owned artifact. A racing replacement is
   * retried here rather than warned (G-8a); the watcher lane keeps its own
   * per-directory retry budget, and the 60 s per-(owner, reason) dedup in
   * `warnExtensionArtifact` still collapses a genuine replacement. */
  private async readExtensionStatusArtifactWithReplacementRetry(
    asyncDir: string,
  ): Promise<Record<string, unknown> | undefined> {
    let value = await this.readExtensionStatusArtifact(asyncDir);
    for (let attempt = 0; value === undefined && attempt < EXTENSION_ARTIFACT_DISCOVERY_READ_RETRIES; attempt += 1) {
      value = await this.readExtensionStatusArtifact(asyncDir);
    }
    return value;
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
    for (const watcher of tracked.children.values()) watcher.close();
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

  /** Canonical JSONL facts are the only reacquisition evidence for an
   * artifact-created activity. Runtime maps are intentionally disposable. */
  private canonicalExtensionRunFacts(): Map<string, CanonicalExtensionRunFact> {
    const facts = new Map<string, CanonicalExtensionRunFact>();
    const recoveryReceipts: Array<{ sourceRunId: string; replacementRunId: string; toolCallId: string }> = [];
    const boundedRunId = (value: unknown): value is string => typeof value === "string"
      && value.length > 0 && Buffer.byteLength(value) <= 256 && !/[\\/\0]/u.test(value);
    for (const entry of this.runtime.session.sessionManager.getEntries()) {
      if (entry.type !== "message") continue;
      const message = entry.message as unknown as Record<string, unknown>;
      if (message.role !== "toolResult") continue;
      // Details.runId is untrusted presentation data. Require the canonical
      // tool identity and prove that its tool is currently extension-owned;
      // otherwise arbitrary tool results must not claim an artifact run.
      const toolCallId = typeof message.toolCallId === "string" ? message.toolCallId : undefined;
      const toolName = typeof message.toolName === "string" ? message.toolName : undefined;
      // Supervisor receipts reference the target run; they never launch or own
      // it. Counting a reply as a second owner blocks its terminal artifact.
      if (!toolCallId || !toolName || toolName === DELEGATED_SUPERVISOR_TOOL_NAME || !this.extensionToolOrigin(toolName)) continue;
      const details = message.details !== null && typeof message.details === "object" && !Array.isArray(message.details)
        ? message.details as Record<string, unknown>
        : undefined;
      // Auto-recovery returns a management receipt, not a second launcher
      // result. It can authorize only the exact provider-owned source run and
      // replacement pair; supervisor references never enter this path.
      const steering = details?.steering !== null && typeof details?.steering === "object" && !Array.isArray(details.steering)
        ? details.steering as Record<string, unknown>
        : undefined;
      const recoveryTargets = steering && Array.isArray(steering.targets) ? steering.targets : [];
      const recoveryTarget = recoveryTargets.find((value) => value !== null && typeof value === "object" && !Array.isArray(value)
        && (value as Record<string, unknown>).state === "recovered") as Record<string, unknown> | undefined;
      const sourceRunId = steering && boundedRunId(steering.sourceRunId) ? steering.sourceRunId : undefined;
      const replacementRunId = steering && boundedRunId(steering.replacementRunId) ? steering.replacementRunId : undefined;
      if (this.isForegroundSubagentTool(toolName, this.extensionToolOrigin(toolName)) && details?.mode === "management"
        && steering?.state === "recovered" && steering.deliveryStatus === "delivered"
        && sourceRunId && replacementRunId && sourceRunId !== replacementRunId
        && recoveryTarget && recoveryTarget.replacementRunId === replacementRunId) {
        recoveryReceipts.push({ sourceRunId, replacementRunId, toolCallId });
      }
      const runId = boundedRunId(details?.runId)
        ? details.runId
        : boundedRunId(details?.asyncId) ? details.asyncId : undefined;
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
    // Bind an auto-recovery receipt to the original canonical launch. The
    // replacement has no distinct toolResult, so its artifact receives a
    // stable synthetic owner derived from this exact handoff, never from its
    // name/path alone. Conflicting handoffs fail closed on both runs.
    for (const receipt of recoveryReceipts) {
      const source = facts.get(receipt.sourceRunId);
      if (!source || source.ambiguous || !source.toolCallId) continue;
      const syntheticToolCallId = `subagent:recovery:${createHash("sha256").update(`${receipt.toolCallId}\\0${receipt.sourceRunId}\\0${receipt.replacementRunId}`).digest("hex").slice(0, 48)}`;
      const replacement = facts.get(receipt.replacementRunId);
      if (replacement && (!replacement.toolCallId || replacement.toolCallId !== syntheticToolCallId || replacement.recoveredSourceRunId !== receipt.sourceRunId)) {
        replacement.ambiguous = true;
        delete replacement.toolCallId;
        continue;
      }
      if (source.recoveredReplacementRunId && source.recoveredReplacementRunId !== receipt.replacementRunId) {
        source.ambiguous = true;
        delete source.recoveredReplacementRunId;
        continue;
      }
      source.recoveredReplacementRunId = receipt.replacementRunId;
      facts.set(receipt.replacementRunId, {
        ...(replacement ?? {}),
        toolCallId: syntheticToolCallId,
        terminal: replacement?.terminal ?? false,
        ambiguous: replacement?.ambiguous ?? false,
        recoveredSourceRunId: receipt.sourceRunId,
      });
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
        if (tracked && tracked.asyncDir === realAsyncDir) {
          // A pending debounce or retry already owns this re-read, so a read that
          // lost a replacement race waits for it instead of warning: the timer
          // fires a few milliseconds later, inside the same replacement.
          if (tracked.timer === undefined && tracked.readRetries < 3) {
            tracked.readRetries += 1;
            tracked.timer = setTimeout(() => {
              tracked.timer = undefined;
              void this.refreshExtensionActivityFromArtifact(toolCallId, realAsyncDir);
            }, tracked.readRetries * 100);
            tracked.timer.unref();
          }
          if (tracked.timer !== undefined) return;
        }
        this.observeMissingExtensionArtifact(toolCallId);
        this.warnExtensionArtifact("artifact-replacement-in-progress", `${previous.runId ?? "run"}\0${toolCallId}`);
        return;
      }
      this.extensionArtifactMissingSince.delete(toolCallId);
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
      this.syncWorkflowChildArtifactWatchers(toolCallId, raw);
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
      const facts = this.canonicalExtensionRunFacts();
      const recoveryClaim = recoveredReplacementClaim(raw);
      const sourceFact = facts.get(runId);
      const pausedProcessSettledAt = observedPausedProcessTerminalAt(raw, runId);
      const processTerminal = pausedProcessSettledAt !== undefined;
      const rawLastUpdate = raw.lastUpdate;
      const rawEndedAt = raw.endedAt;
      const superseded = extensionLifecycleState(raw.state ?? raw.status) === "paused"
        && recoveryClaim !== undefined
        && sourceFact?.recoveredReplacementRunId === recoveryClaim.replacementRunId
        && sourceFact.ambiguous !== true
        && processTerminal
        && typeof rawLastUpdate === "number" && Number.isSafeInteger(rawLastUpdate)
        && rawLastUpdate <= recoveryClaim.recoveredAt
        && typeof rawEndedAt === "number" && Number.isSafeInteger(rawEndedAt)
        && rawEndedAt <= recoveryClaim.recoveredAt;
      const effectiveArtifactState = superseded ? "completed" : artifactState;
      const effectiveCompletedAt = superseded ? completedAt ?? updatedAt : completedAt;
      const terminalStates = ["completed", "failed", "stopped", "rejected"];
      if (ownership.terminal && artifactState === "running" && !superseded) return;
      // A latched terminal state is final: a re-read of a kept-open run may restate
      // it (its workflow children still report), never move it to another state.
      if (terminalStates.includes(previous.lifecycle?.state ?? "") && artifactState !== "running"
        && normalized.lifecycleState !== previous.lifecycle?.state) return;
      // A kept-open run restates its latched terminal lifecycle; only its children move.
      const latchedState = previous.lifecycle?.state !== undefined && terminalStates.includes(previous.lifecycle.state)
        ? previous.lifecycle.state : undefined;
      const artifactValue = ownership.terminal
        ? preserveEmbeddedLifecycleMarker(raw, { ...raw, state: latchedState ?? (previous.status === "failed" ? "failed" : "completed") })
        : superseded
          ? preserveEmbeddedLifecycleMarker(raw, { ...raw, state: "stopped", supersededByRunId: recoveryClaim!.replacementRunId })
          : raw;
      const activityKey = previous.activityId ?? extensionActivityId(this.runtime.session.sessionManager.getSessionId(), toolCallId);
      const sequence = (this.extensionActivitySequences.get(activityKey) ?? previous.lifecycle?.sequence ?? 0) + 1;
      this.extensionActivitySequences.set(activityKey, sequence);
      const observedAt = new Date().toISOString();
      const terminalAt = effectiveArtifactState === "running"
        ? previous.lifecycle?.terminalAt
        : previous.lifecycle?.terminalAt ?? observedAt;
      const recentUntil = terminalAt ? new Date(Date.parse(terminalAt) + 900_000).toISOString() : undefined;
      const activity = this.childSessionAdmission.attach(projectExtensionRunActivity(artifactValue, {
        id: previous.id,
        activityId: activityKey,
        toolCallId,
        source: previous.source,
        title: previous.title,
        mode: "asynchronous",
        status: effectiveArtifactState,
        authoritativeStatus: effectiveArtifactState !== "running" || previous.lifecycle?.state === "completed" || previous.lifecycle?.state === "failed" || previous.lifecycle?.state === "stopped" || previous.lifecycle?.state === "rejected",
        startedAt: previous.startedAt,
        updatedAt,
        ...(effectiveCompletedAt ? { completedAt: effectiveCompletedAt } : {}),
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
      // Ownership facts are written before this frame's projection publishes:
      // settled paused presentation, dashboard activity, and drain accounting
      // all read them from the same frame.
      this.bindExtensionRunOwnership(runId, {
        toolCallId,
        asyncDir: realAsyncDir,
        terminal: activity.status !== "running" || Boolean(ownership.terminal),
        ...(pausedProcessSettledAt ? { pausedProcessQuiescentAt: pausedProcessSettledAt } : {}),
        detachedChildKeys: detachedWorkflowChildKeys(raw),
      });
      this.extensionActivities.delete(toolCallId);
      this.extensionActivities.set(toolCallId, activity);
      this.upsertExtensionActivity(activity);
      const tool = this.toolExecutions.get(toolCallId);
      if (tool) this.toolExecutions.set(toolCallId, { ...tool, extensionActivity: activity });
      this.publishExtensionActivity(activity);
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
        claimedReceiptOwner = undefined;
        claimedReceiptActivityId = undefined;
        void this.appendExtensionActivityReceipt(activity).catch((error) => this.emit("session.extensionError", safeJson(error)));
      }
      if (!this.extensionActivityWatchRequired(activity)) this.stopExtensionActivityWatcher(toolCallId);
    } catch (error) {
      if (claimedReceiptActivityId) this.releaseExtensionReceiptOwnership(claimedReceiptActivityId, claimedReceiptOwner);
      // The next filesystem event or normal snapshot retries; warning is bounded.
      this.warnExtensionArtifact(
        extensionArtifactReadFailureReason(error),
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
      const onChange = (_eventType: string, filename: string | Buffer | null) => {
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
    const write = this.runPersistence.trackOwnershipWrite(() => this.lane.run(() => this.runPersistence.retryDurableWrite(
      `extension-receipt:${receipt.activityId}`,
      async () => {
          this.persistVerifiedCustomEntry({
            describe: "extension activity receipt",
            existing: () => extensionActivityReceipts(this.runtime.session.sessionManager.getEntries(), this.id)
              .some((record) => record.receipt.activityId === receipt.activityId) ? "matching" : "absent",
            append: () => {
              this.runtime.session.sessionManager.appendCustomEntry(EXTENSION_ACTIVITY_RECEIPT_TYPE, receipt);
              this.revision += 1;
              this.scheduleSnapshot();
            },
          });
      },
    )), owner);
    this.extensionReceiptWrites.set(receipt.activityId, write);
    void write.then(() => {
      if (this.extensionReceiptWrites.get(receipt.activityId) === write) this.extensionReceiptWrites.delete(receipt.activityId);
      this.releaseExtensionReceiptOwnership(receipt.activityId, owner);
    }, () => {
      // Retain and identify the exact failed owner; drain recovery is process replacement.
      owner.markSuspect();
    });
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
    persistReceipt = true,
  ): ExtensionRunActivity | undefined {
    // The native supervisor is ordinary control-tool activity, not a new
    // delegated execution, even when its receipt includes the target runId.
    if (!extensionOrigin || toolName === DELEGATED_SUPERVISOR_TOOL_NAME) return undefined;
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
      if (persistReceipt) void this.appendExtensionActivityReceipt(current).catch(() => {});
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
    const activity = this.childSessionAdmission.attach(projectExtensionRunActivity(value, {
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
    const terminalReceiptOwner = terminal && persistReceipt ? this.claimExtensionReceiptOwnership(activityKey) : undefined;
    if (terminal && persistReceipt && !terminalReceiptOwner) return current;
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
      const merged = this.childSessionAdmission.attach(projectExtensionRunActivity(value, {
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
      if (persistReceipt) void this.appendExtensionActivityReceipt(retainedActivity).catch((error) => this.emit("session.extensionError", safeJson(error)));
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
      this.emit("session.toolProgress", safeJson(activityProjection.toolProgressWire(this.activitySource(), state)));
      this.publishProcessesForToolCall(state.toolCallId);
      return;
    }
    if (pending) return;
    const timer = setTimeout(() => {
      this.toolProgressTimers.delete(state.toolCallId);
      const current = this.toolExecutions.get(state.toolCallId);
      if (!current) return;
      this.toolProgressPublishedAt.set(state.toolCallId, Date.now());
      this.emit("session.toolProgress", safeJson(activityProjection.toolProgressWire(this.activitySource(), current)));
      this.publishProcessesForToolCall(current.toolCallId);
    }, minimumIntervalMs - (now - last));
    timer.unref();
    this.toolProgressTimers.set(state.toolCallId, timer);
  }

  /** Lifecycle updates are compact presentation deltas, not transcript
   * changes. Avoid rebuilding and sending the canonical transcript for every
   * status artifact heartbeat. */
  private publishExtensionActivity(activity: ExtensionRunActivity): void {
    // The projection's `asOf` is refresh time, not execution recency. Artifact
    // reconciliation can publish an old terminal run during a cold open; use
    // the activity's own timestamp so observation alone cannot refresh history.
    this.noteDashboardActivity(activity.updatedAt);
    if (this.hasDetachedDashboardWork() && !this.activityHeartbeat) this.startActivityHeartbeat();
    this.emit("session.extensionActivity", safeJson({
      activity: activityProjection.extensionActivityWire(this.activitySource(), activity),
      liveActivityRevision: this.liveActivityRevision,
      extensionActivityAsOf: this.extensionActivityAsOf,
    }));
    this.publishProcessesForToolCall(activity.toolCallId);
    this.notifyDetachedWork();
    // Detached lifecycle updates do not rebuild the full transcript snapshot,
    // but they are authoritative live catalog activity and must reorder rows.
    this.publishSummary();
    if (!this.hasCurrentDashboardWork()) this.stopActivityHeartbeat();
  }

  public clearToolProgressTimers(): void {
    for (const timer of this.toolProgressTimers.values()) clearTimeout(timer);
    this.toolProgressTimers.clear();
    this.toolProgressPublishedAt.clear();
    this.toolStartedAtMonotonicMs.clear();
  }

  public startActivityHeartbeat(): void {
    this.stopActivityHeartbeat();
    this.activityHeartbeat = setInterval(() => this.publishActivityHeartbeat(), 10_000);
    this.activityHeartbeat.unref();
  }

  private publishActivityHeartbeat(): void {
    if (this.disposed || !this.hasCurrentDashboardWork()) {
      this.stopActivityHeartbeat();
      return;
    }
    // Heartbeats keep a legitimately active foreground or detached session's
    // catalog timestamp current without rebuilding its transcript snapshot.
    // They publish no session event: no client consumes one, and client pings
    // already prove the connection is live.
    this.noteDashboardActivity();
    this.publishSummary();
  }

  public stopActivityHeartbeat(): void {
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

  private extensionCommandContextOrigin(commandName: string): ExtensionToolOrigin | undefined {
    const owners = this.runtime?.session.resourceLoader.getExtensions().extensions
      .map(extension => attributedCommandOwner(extension.commands.get(commandName)))
      .filter((owner): owner is NonNullable<typeof owner> => owner !== undefined) ?? [];
    return owners.length === 1 ? { source: owners[0]!.source, owner: owners[0]! } : undefined;
  }

  public extensionCommandOrigin(commandName: string): ChatOrigin {
    const contextOrigin = this.extensionCommandContextOrigin(commandName);
    if (!contextOrigin?.owner) return { kind: "unknown", confidence: "unknown" };
    return {
      kind: trustedExtensionOriginKind(contextOrigin.owner),
      ownerId: contextOrigin.owner.id,
      title: contextOrigin.owner.title,
      confidence: "adapter",
    };
  }

  private extensionToolOrigin(toolName: string): ExtensionToolOrigin | undefined {
    const session = this.runtime?.session;
    if (!session) return undefined;
    const tool = session.getAllTools().find(candidate => candidate.name === toolName);
    if (!tool) return undefined;
    const extensions = session.resourceLoader.getExtensions().extensions
      .map(extension => ({ extension, owner: attributedToolOwner(extension.tools.get(toolName)) }))
      .filter(candidate => candidate.owner !== undefined);
    if (extensions.length !== 1) return undefined;
    const { extension, owner } = extensions[0]!;
    if (!owner || tool.sourceInfo.path !== extension.path && tool.sourceInfo.path !== extension.resolvedPath) return undefined;
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

  /**
   * Tron Home's memory follows the canonical log, not the slot's lane: the owner
   * re-reads what a commit appended and drains its pump under its own bounds, so
   * nothing here waits on it. Pi emits `message_end` immediately before the
   * canonical append, so the report is deferred one microtask; the read is
   * idempotent and the request path re-reads before it renders, so a report that
   * lands early costs one incremental read and nothing else.
   */
  private noteCanonicalEntriesCommitted(): void {
    if (!this.liveProfile().chapter) return;
    queueMicrotask(() => { this.dependencies.modules.policy("appendGuard")?.(this.canonicalAppendContext).committed(); });
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
      if (message.toolName === "display") this.reconcileCanonicalDisplayArtifacts();
      this.scheduleSnapshot();
    });
  }

  async reconcileDisplayArtifactOwnership(): Promise<void> {
    const manager = this.runtime.session.sessionManager;
    const references = new Set(this.dependencies.modules.policy("toolResultProjection")?.().references(manager.getEntries(), this.id).artifacts ?? []);
    await this.dependencies.displayArtifacts.reconcileSession(this.id, references);
  }

  private reconcileCanonicalDisplayArtifacts(): void {
    void this.reconcileDisplayArtifactOwnership().catch((error) => {
      this.emit("session.extensionError", safeJson({
        message: error instanceof Error
          ? error.message
          : "Display artifact reconciliation failed",
      }));
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
    // projection still needs the bounded enrichment map. Refresh a running
    // sample before retiring its row so even a snapshot that lands between
    // canonical handoff and a compatible late terminal callback cannot show
    // the stale near-zero start sample as the completed duration.
    const live = this.toolExecutions.get(toolCallId);
    if (live?.status === "running") {
      const now = new Date().toISOString();
      this.rememberToolMetadata(toolCallId, {
        ...live,
        durationMs: Math.max(
          live.durationMs ?? 0,
          this.measureToolDuration(toolCallId, live.startedAt, now, performance.now())
        ),
      });
    }
    this.toolExecutions.delete(toolCallId);
    // Do not clear the monotonic start here. A late terminal callback still
    // owns this exact call and must measure from its original start. Ordinary
    // terminal delivery and agent settlement both clear the bounded map.
  }

  private rememberToolMetadata(toolCallId: string, state: ToolExecutionState): void {
    const retained = this.toolMetadata.get(toolCallId);
    const completedAt = state.completedAt ?? retained?.completedAt;
    const durationMs = state.durationMs === undefined
      ? retained?.durationMs
      : Math.max(0, state.durationMs, retained?.durationMs ?? 0);
    const toolSegmentId = state.toolSegmentId ?? retained?.toolSegmentId;
    const groupId = state.groupId ?? retained?.groupId;
    const groupIndex = state.groupIndex ?? retained?.groupIndex;
    const groupCount = state.groupCount ?? retained?.groupCount;
    const groupFinalized = state.groupFinalized ?? retained?.groupFinalized;
    const extensionOrigin = state.extensionOrigin ?? retained?.extensionOrigin;
    const toolLabel = state.toolLabel ?? retained?.toolLabel;
    this.rememberProjectionMetadata(this.toolMetadata, toolCallId, {
      startedAt: retained?.startedAt ?? state.startedAt,
      ...(completedAt ? { completedAt } : {}),
      ...(durationMs === undefined ? {} : { durationMs }),
      lastProgressAt: state.lastProgressAt ?? retained?.lastProgressAt ?? state.updatedAt,
      progressSequence: Math.max(state.progressSequence ?? 0, retained?.progressSequence ?? 0),
      ...(toolSegmentId ? { toolSegmentId } : {}),
      ...(groupId ? { groupId } : {}),
      ...(groupIndex === undefined ? {} : { groupIndex }),
      ...(groupCount === undefined ? {} : { groupCount }),
      ...(groupFinalized === undefined ? {} : { groupFinalized }),
      ...(extensionOrigin ? { extensionOrigin } : {}),
      ...(toolLabel ? { toolLabel } : {}),
    });
  }

  protected rememberProjectionMetadata(
    store: Map<string, ToolProjectionMetadata>,
    id: string,
    metadata: ToolProjectionMetadata
  ): void {
    store.delete(id);
    store.set(id, metadata);
    while (store.size > 2_048) {
      const oldest = store.keys().next().value as string | undefined;
      if (!oldest) break;
      store.delete(oldest);
    }
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
      this.processOperationIDs.delete(processId);
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

  public scheduleSnapshot(): void {
    if (this.snapshotTimer) return;
    this.snapshotTimer = setTimeout(() => {
      this.snapshotTimer = undefined;
      this.publishSnapshot();
    }, 20);
  }

  public internalWakeSemantic(operationId: string): ChatSemanticMetadata | undefined {
    const invocation = this.runInvocations.invocationForOperation(operationId);
    return invocation?.source === "subagentWake" ? {
      version: 1, kind: "prompt", direction: "hiddenInternal", contextEffect: "modelInput",
      delivery: "stored", visibility: "hidden", origin: invocation.origin,
      invocationId: invocation.invocationId, operationId, sequence: invocation.sequence,
    } : undefined;
  }

  snapshot(sequence = this.eventSequence): SessionSnapshot {
    return stage("snapshot.build", () => this.buildSnapshot(sequence));
  }

  private readonly displayProjection: ToolDisplayProjection = (...args) => this.dependencies.modules.policy("toolResultProjection")?.().display(...args);
  private readonly snapshotProjection = new SnapshotProjection();

  private buildSnapshot(sequence: number): SessionSnapshot {
    const slot = this;
    return this.snapshotProjection.build({
      displayProjection: this.displayProjection,
      assertNoTrustReload: (...args) => slot.assertNoTrustReload(...args),
      get runtime() { return slot.runtime; },
      ensureAgentProjection: (...args) => slot.runAttention.ensureAgentProjection(...args),
      get revision() { return slot.revision; },
      latestCacheHitRate: (...args) => slot.latestCacheHitRate(...args),
      get contextPolicies() { return slot.contextPolicies; },
      get compactionPolicies() { return slot.compactionPolicies; },
      get streamPresentationId() { return slot.streamPresentationId; },
      get latestStreamingMessage() { return slot.latestStreamingMessage; },
      get canonicalizedStreamingMessages() { return slot.canonicalizedStreamingMessages; },
      captureStreamIdentity: (...args) => slot.captureStreamIdentity(...args),
      get streamAnchorId() { return slot.streamAnchorId; },
      get streamStartedAt() { return slot.streamStartedAt; },
      get dependencies() { return slot.dependencies; },
      get finalizedStreamPresentationId() { return slot.finalizedStreamPresentationId; },
      toolLabels: (...args) => slot.toolLabels(...args),
      activeToolSegmentId: (...args) => slot.activeToolSegmentId(...args),
      transcriptPage: (...args) => slot.transcriptPage(...args),
      get pendingExtensionCommand() { return slot.pendingExtensionCommand; },
      get id() { return slot.id; },
      get ui() { return slot.ui; },
      projectedQueue: (...args) => slot.runQueue.projectedQueue(...args),
      currentProcessProjection: () => activityProjection.currentProcessProjection(slot.activitySource()),
      get isAgentAdmissionSettling() { return slot.isAgentAdmissionSettling; },
      get phase() { return slot.phase; },
      get effectivePhase() { return slot.effectivePhase; },
      get runtimeGeneration() { return slot.runtimeGeneration; },
      configurationBlocker: (...args) => slot.configurationBlocker(...args),
      get isHomeChapter() { return slot.isHomeChapter; },
      get queueRevision() { return slot.runQueue.queueRevision; },
      get pendingPrompt() { return slot.pendingPrompt; },
      get pendingManualCompaction() { return slot.manualCompaction.pendingManualCompaction; },
      get operation() { return slot.operation; },
      get retry() { return slot.retry; },
      get toolExecutions() { return slot.toolExecutions; },
      toolProgressWire: state => activityProjection.toolProgressWire(slot.activitySource(), state),
      get extensionActivities() { return slot.extensionActivities; },
      extensionActivityVisibility: activity => activityProjection.extensionActivityVisibility(slot.activitySource(), activity),
      extensionActivityWire: activity => activityProjection.extensionActivityWire(slot.activitySource(), activity),
      get liveActivityRevision() { return slot.liveActivityRevision; },
      get extensionActivityAsOf() { return slot.extensionActivityAsOf; },
    }, sequence);
  }

  transcriptPageAfter(after: number, expectedPreviousEntryId?: string, expectedRuntimeGeneration?: string, expectedLeafEntryId?: string): TranscriptPage {
    return sessionPages.transcriptPageAfter(this.pageSource(), after, expectedPreviousEntryId, expectedRuntimeGeneration, expectedLeafEntryId);
  }

  transcriptPage(before?: number, expectedNextEntryId?: string, expectedRuntimeGeneration?: string, expectedLeafEntryId?: string, branchCut?: import("../kernel/pi/coding-agent.js").SessionEntry[]): TranscriptPage {
    return sessionPages.transcriptPage(this.pageSource(), before, expectedNextEntryId, expectedRuntimeGeneration, expectedLeafEntryId, branchCut);
  }

  extensionActivityHistory(cursor?: string, limit = 25, filter?: { ownerId?: string; runId?: string; state?: "completed" | "failed" | "stopped" | "rejected" }): ExtensionActivityHistoryPage {
    return sessionPages.extensionActivityHistory(this.pageSource(), cursor, limit, filter);
  }

  extensionActivityDetail(activityId: string, expectedHistoryRevision?: string): ExtensionRunActivity | undefined {
    return sessionPages.extensionActivityDetail(this.pageSource(), activityId, expectedHistoryRevision);
  }

  processHistory(cursor?: string, limit = 25, filter?: { kind?: "command" | "subagent"; state?: SessionProcessActivity["lifecycle"]["state"] }): SessionProcessHistoryPage {
    return sessionPages.processHistory(this.pageSource(), cursor, limit, filter);
  }

  processDetail(processId: string, expectedHistoryRevision?: string): SessionProcessActivity | undefined {
    return sessionPages.processDetail(this.pageSource(), processId, expectedHistoryRevision);
  }

  private pageSource(): sessionPages.PageSource {
    const slot = this;
    return {
      displayProjection: this.displayProjection,
      assertNoTrustReload: (...args) => slot.assertNoTrustReload(...args),
      get runtimeGeneration() { return slot.runtimeGeneration; },
      get runtime() { return slot.runtime; },
      get dependencies() { return slot.dependencies; },
      get toolMetadata() { return slot.toolMetadata; },
      get presentationIDs() { return slot.presentationIDs; },
      toolLabels: (...args) => slot.toolLabels(...args),
      get bashMetadata() { return slot.bashMetadata; },
      get forkBoundary() { return slot.forkBoundary; },
      internalWakeSemantic: (...args) => slot.internalWakeSemantic(...args),
      get id() { return slot.id; },
      get extensionActivities() { return slot.extensionActivities; },
    };
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

  processChildSessionPath(processId: string): { ref: string; producerId: string; path: string; runId?: string } | undefined {
    const binding = this.processChildSessionBinding(processId);
    const path = binding ? this.childSessionAdmission.path(binding.ref, binding.producerId) : undefined;
    return binding && path ? {
      ref: binding.ref,
      producerId: binding.producerId,
      path,
      ...(binding.runId ? { runId: binding.runId } : {}),
    } : undefined;
  }

  processSubagentAbortAuthority(
    processId: string,
    expectedRunId: string,
  ): { expectedOperationId?: string } | undefined {
    this.assertNoTrustReload();
    const tool = this.trustedSubagentController();
    const capturedOperationId = this.processOperationIDs.get(processId);
    const currentOperationId = capturedOperationId === this.operation?.id
      ? capturedOperationId
      : undefined;
    const route = subagentAbortRoute(
      this.processActivities.get(processId),
      this.processChildSessionBinding(processId),
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
    const capturedOperationId = this.processOperationIDs.get(processId);
    const currentOperationId = capturedOperationId === this.operation?.id
      ? capturedOperationId
      : undefined;
    const route = subagentAbortRoute(
      this.processActivities.get(processId),
      this.processChildSessionBinding(processId),
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
      await this.abort("agent", expectedOperationId);
      return;
    }

    if (!tool) throw new GatewayError("unsupported", "The installed subagent controller is unavailable");
    await this.controlSubagentRun(tool, { action: "stop", id: route.runId, childId: route.childId });
  }

  /** The provider's own control for one run, through the exact installed controller.
   * A rejection is an error: the caller must not assume the run was stopped. */
  private async controlSubagentRun(tool: ToolDefinition, input: Record<string, unknown>): Promise<void> {
    const toolCallId = `tron-control-${randomUUID()}`;
    const signal = new AbortController().signal;
    const result = await tool.execute(toolCallId, input, signal, undefined,
      this.runtime.session.extensionRunner.createToolContext(toolCallId, signal));
    if ((result as typeof result & { isError?: boolean }).isError === true) {
      const message = result.content.find(content => content.type === "text")?.text;
      throw new GatewayError("conflict", message?.slice(0, 512) || "The subagent controller rejected the request", true);
    }
  }

  /** Whether this session owns a run: one its canonical history launched (a launch or a resume
   * result), or a child run a workflow of this session names in its own provider status. Task
   * controls use it to refuse a control of any run the task did not start, including a foreign
   * workflow's child. Only this owner decides, so a control and a reply cannot disagree. */
  async ownsSubagentRun(runId: string): Promise<boolean> {
    const facts = this.canonicalExtensionRunFacts();
    if (facts.has(runId)) return true;
    for (const fact of facts.values()) {
      // The status reader opens only a canonical directory: a launch result's path may name a symlinked root.
      const directory = fact.asyncDir === undefined ? undefined : this.canonicalExtensionArtifactDirectory(fact.asyncDir);
      if (directory === undefined) continue;
      const status = await this.readExtensionStatusArtifact(directory, false).catch(() => undefined);
      if (status?.mode === "workflow" && Array.isArray(status.steps)
        && status.steps.some(step => (step as { runId?: unknown } | null)?.runId === runId)) return true;
    }
    return false;
  }

  /** Whether a supervisor request came from a run this session owns. The request is canonical
   * evidence: its `subagent_supervisor_request` message names the child's run. */
  async ownsSupervisorRequest(requestId: string): Promise<boolean> {
    const request = this.sessionManager.getBranch().findLast(entry => entry.type === "custom_message"
      && entry.customType === "subagent_supervisor_request" && (entry.details as { requestId?: unknown } | undefined)?.requestId === requestId);
    const runId = request?.type === "custom_message" ? (request.details as { runId?: unknown } | undefined)?.runId : undefined;
    return typeof runId === "string" && await this.ownsSubagentRun(runId);
  }

  /** Task-end settlement of this worker's async subagent runs. Every live async run is
   * stopped through the provider's own stop control, then the join waits until no run
   * is live, bounded by the operation deadline or the stop-join bound, whichever comes
   * first, and one disposal grace after it. The
   * fact is appended only when the task launched async runs, so an absent fact proves
   * zero Gateway stops. `stoppedAtEnd` is null unless every stop was accepted and the
   * join completed. Before the fact, the join also waits for each async run's completion
   * notice to be recorded, bounded the same way; `noticesUndelivered` counts those still
   * missing at the bound, which never changes the outcome (the run itself is terminal). */
  async settleTaskSubagents(operationId: string, deadline: AbortSignal): Promise<{ stoppedAtEnd: number | null; noticesUndelivered: number }> {
    if (this.taskWorker?.identity.operationId !== operationId) throw new GatewayError("conflict", "Task operation changed before settlement");
    const launched = homeTaskSubagentLaunches(this.canonicalSessionEntries());
    const targets = this.asyncStopTargets();
    if (targets.length === 0 && launched.every(launch => launch.asyncDir === undefined)) return { stoppedAtEnd: 0, noticesUndelivered: 0 };
    const tool = this.trustedSubagentController();
    const stops = await Promise.allSettled(targets.map(async runId => {
      if (!tool) throw new GatewayError("unsupported", "The installed subagent controller is unavailable");
      await this.controlSubagentRun(tool, { action: "stop", id: runId });
    }));
    // The join is also bounded once stops are requested: a run whose stop never lands
    // must not hold the sealed task open for the rest of its 24-hour deadline.
    const stopJoin = new AbortController();
    const stopJoinTimer = setTimeout(() => stopJoin.abort(), HOME_TASK_SUBAGENT_STOP_JOIN_MS);
    const bound = AbortSignal.any([deadline, stopJoin.signal]);
    let joined: boolean;
    let noticesUndelivered: number;
    try {
      joined = await this.joinDetachedWork(bound);
      // A run's completion notice is written after the run is terminal, so it can land after
      // the report. It is canonical evidence of the run, so settlement records it before the fact
      // and the evidence cut. A notice still missing at the bound is counted, not waited for.
      const runIds = launched.flatMap(launch => launch.asyncDir ? [basename(launch.asyncDir)] : []);
      const undelivered = (): string[] => undeliveredSubagentNotices(this.canonicalSessionEntries(), runIds);
      await this.joinUntil(() => undelivered().length === 0, this.canonicalDeliveryWaiters, bound);
      noticesUndelivered = undelivered().length;
    } finally {
      clearTimeout(stopJoinTimer);
    }
    const stoppedAtEnd = joined && stops.every(stop => stop.status === "fulfilled") ? stops.length : null;
    await this.persistCanonicalCustomEntry(HOME_TASK_SUBAGENTS,
      { receiptId: subagentsReceiptId(operationId), operationId, stoppedAtEnd }, subagentsReceiptId(operationId), this.runWork.get(operationId));
    return { stoppedAtEnd, noticesUndelivered };
  }

  /** The run ids settlement stops through the provider. A live run is stopped as itself,
   * and a workflow's stop reaches its children. A run that completed while runner-backed
   * children stay live cannot be stopped by its own state, so each live child is named by
   * its run id from the run's status. */
  private asyncStopTargets(): string[] {
    // Selection has no awaits: a refresh cannot reorder the map mid-selection,
    // and Stop cannot disagree with status by re-reading a different artifact.
    return this.liveExtensionActivities().flatMap(activity => {
      const binding = activity.runId === undefined ? undefined : this.extensionRunOwnership.get(activity.runId);
      return binding?.asyncDir === undefined ? [] : this.liveActivitySubagentRuns(activity).map(run => run.runId);
    });
  }

  /** Waits until no detached run is live. The wait is bounded by the operation's
   * deadline, then by one disposal grace after it fires. A run still live then is
   * not joined, and the caller keeps the detached outcome. */
  private async joinDetachedWork(deadline: AbortSignal): Promise<boolean> {
    return this.joinUntil(() => !this.hasDetachedDashboardWork(), this.detachedWorkWaiters, deadline);
  }

  /** Waits until `done` holds. Each wake from `waiters` re-checks it. The wait is bounded by
   * the deadline, then by one disposal grace after it fires; a condition still unmet then
   * returns false, and the caller keeps its unproven outcome. */
  private async joinUntil(done: () => boolean, waiters: Set<() => void>, deadline: AbortSignal): Promise<boolean> {
    let timer: ReturnType<typeof setTimeout> | undefined;
    let resolveBound!: (value: "bound") => void;
    const bound = new Promise<"bound">(resolve => { resolveBound = resolve; });
    const start = (): void => { timer = setTimeout(() => resolveBound("bound"), DEFAULT_RUNTIME_DISPOSAL_GRACE_MS); };
    if (deadline.aborted) start();
    else deadline.addEventListener("abort", start, { once: true });
    try {
      while (!done()) {
        let wake!: () => void;
        const changed = new Promise<"changed">(resolve => { wake = () => resolve("changed"); });
        waiters.add(wake);
        const outcome = await Promise.race([changed, bound]);
        waiters.delete(wake);
        if (outcome === "bound") break;
      }
    } finally {
      deadline.removeEventListener("abort", start);
      if (timer !== undefined) clearTimeout(timer);
    }
    return done();
  }

  /** Every extension-activity publication may end a join's wait. */
  private notifyDetachedWork(): void {
    const waiters = [...this.detachedWorkWaiters];
    this.detachedWorkWaiters.clear();
    for (const wake of waiters) wake();
  }

  /** A recorded completion notice may end a notice join's wait. */
  private notifyCanonicalDelivery(): void {
    const waiters = [...this.canonicalDeliveryWaiters];
    this.canonicalDeliveryWaiters.clear();
    for (const wake of waiters) wake();
  }

  publishSnapshot(): void {
    this.releaseSettleWaiters();
    if (this.disposed || this.trustReloadPending) return;
    // This publication already carries every change a pending coalesced frame
    // was scheduled for; letting that timer fire would rebroadcast the same
    // state. Later mutations schedule their own frame.
    if (this.snapshotTimer) {
      clearTimeout(this.snapshotTimer);
      this.snapshotTimer = undefined;
    }
    this.publishStateChange();
    // A coalesced streaming frame must not overtake the state transition this
    // snapshot publishes.
    this.flushPendingProgress();
    this.eventSequence += 1;
    // No audience, no projection: a snapshot is a canonical branch walk plus a
    // transcript page, so building one for a session nobody receives it for is
    // work for nobody. The subscriber record is the slot's whole audience fact,
    // and the transport is its only writer: it subscribes a client before
    // installing that client's synchronization barrier, so a pending barrier is
    // always a subscriber here, and a client that subscribes later receives a
    // fresh snapshot through the ordinary open and synchronization path. The
    // transport counts the recipients of every snapshot frame it is handed, so
    // a projection a ready socket cannot receive is still recorded and warns
    // (`UNAUDIENCED_SNAPSHOT_WARNING`) rather than passing as an ordinary build.
    //
    // `buildSnapshot` also settles this slot's agent projection. That settlement
    // belongs to every publication, not only to the ones with an audience, so it
    // runs here rather than inside the build.
    this.runAttention.ensureAgentProjection();
    if (this.dependencies.sessionAudience(this.id) > 0) {
      this.hooks.broadcast(this.id, "session.snapshot", this.snapshot(this.eventSequence) as unknown as JsonValue);
    }
    this.publishSummary();
  }

  private publishSummary(): void {
    const summary = this.summary();
    if (!this.lastPublishedSummary
      || summary.sessionId !== this.lastPublishedSummary.sessionId
      || summary.phase !== this.lastPublishedSummary.phase
      || summary.foregroundPhase !== this.lastPublishedSummary.foregroundPhase
      || summary.hasActiveSubagents !== this.lastPublishedSummary.hasActiveSubagents
      || summary.waitingForUser !== this.lastPublishedSummary.waitingForUser
      || summary.name !== this.lastPublishedSummary.name
      || summary.updatedAt !== this.lastPublishedSummary.updatedAt
      || summary.activeSince !== this.lastPublishedSummary.activeSince
      || summary.messageCount !== this.lastPublishedSummary.messageCount
      || summary.firstMessage !== this.lastPublishedSummary.firstMessage) {
      this.lastPublishedSummary = summary;
      this.hooks.summaryChanged(summary);
    }
  }

  async steerHomeTask(control: import("../modules/home/home-task-dispatcher.js").HomeTaskControlRequest, text: string) {
    return this.prompt(text, [], "steer", undefined, undefined, {
      operationId: randomUUID(), taskFence: structuredClone(control),
      origin: { kind: "gateway", ownerId: control.taskId, title: "Home steering", confidence: "boundary" }, onTerminal: () => {},
    });
  }

  async stopHomeTask(control: import("../modules/home/home-task-dispatcher.js").HomeTaskControlRequest): Promise<void> {
    if (!this.taskWorker || this.taskWorker.identity.taskId !== control.taskId
      || this.taskWorker.identity.operationId !== control.operationId) {
      throw new GatewayError("conflict", "Task operation changed before Stop");
    }
    await this.taskWorker.stop();
  }

  /** Interrupts only the task worker's in-flight tool calls (#1189): each ends with a result
   * naming `by`, and the worker's turn continues with the optional steering `text`. Returns the
   * interrupted tools' names. */
  async interruptHomeTask(control: import("../modules/home/home-task-dispatcher.js").HomeTaskControlRequest, by: string, text?: string): Promise<string[]> {
    if (!this.taskWorker || this.taskWorker.identity.taskId !== control.taskId
      || this.taskWorker.identity.operationId !== control.operationId) {
      throw new GatewayError("conflict", "Task operation changed before Interrupt");
    }
    // The steer is queued before the abort, so the worker reads it right after the interrupted results.
    return await interruptToolCalls(this.runtime.session, new ToolCallInterrupt(by),
      text === undefined ? undefined : async () => { await this.steerHomeTask(control, text); });
  }

  /** Task cancellation follows the root prompt owner, not its disposable
   * presentation primitive (automatic compaction/retry may have another ID). */
  cancelHomeTaskOperation(operationId: string, reason: string): Promise<void> {
    return this.runTerminal.cancelHomeTaskOperation(operationId, reason);
  }

  /** Starts one Home wake: the inbox's pending results start the run. */
  async admitHomeWake(): Promise<{ delivered: boolean }> {
    let delivered = false;
    await this.prompt("", [], undefined, undefined, undefined, {
      kind: "homeWake", operationId: randomUUID(), origin: { kind: "gateway", ownerId: "home", title: "Home", confidence: "boundary" },
      onDelivered: (value) => { delivered = value; },
    });
    return { delivered };
  }

  /** A wake starts only when nothing else owns this runtime. Pi's prompt() queues or
   * holds an input; a wake has no input, so it refuses and its results stay pending. */
  public async assertHomeWakeAdmissible(session: AgentSession): Promise<void> {
    if (this.phase !== "idle" || this.operation !== undefined || this.activeOperationId !== undefined
      || this.heldQueue.entries.length > 0 || this.manualCompaction.pendingManualCompaction !== undefined || this.compactionOperation !== undefined
      || this.isAgentAdmissionSettling || session.isStreaming) {
      throw new GatewayError("busy", "Tron Home is busy; finished results wait for its next idle moment", true);
    }
    // The model and credential checks prompt() runs before a provider call. Its idle-admission block
    // (settings flush, compaction budgets, context window) runs for a wake too, since admitPrompt owns it.
    const model = session.model;
    if (!model) throw new GatewayError("conflict", "Tron Home has no model to wake with", false, { reason: "model-unavailable" });
    if (!this.modelRuntime.hasConfiguredAuth(model.provider) && (await this.modelRuntime.checkAuth(model.provider)) === undefined) {
      throw new GatewayError("conflict", "Tron Home has no usable credential to wake with", false, { reason: "auth-unavailable" });
    }
  }

  /** Starts a wake's run with its trigger, or completes an operation with nothing to deliver. */
  public startHomeWake(session: AgentSession, operationId: string, trigger: InputTrigger | undefined,
    accept: (accepted: boolean) => void): Promise<void> {
    accept(true);
    return trigger ? this.sendHomeWake(session, operationId, trigger) : Promise.resolve();
  }

  /** Pi appends the trigger and runs the turn. Refuses to leave an inbox result admitted
   * when the trigger never reached the canonical session: it returns to pending first, so
   * a terminal receipt cannot settle it as outcome-unknown. */
  private async sendHomeWake(session: AgentSession, operationId: string, trigger: InputTrigger): Promise<void> {
    const eventId = trigger.message.details.eventId;
    this.inboxAttributedMessages.add(eventId);
    this.homeWakeTrigger = { eventId, taskId: trigger.taskId, operationId };
    try {
      await session.sendCustomMessage(trigger.message, { triggerTurn: true });
      if (!this.hasCanonicalCustomMessage(eventId)) throw new GatewayError("conflict", "Home wake trigger was not persisted");
    } catch (error) {
      if (!this.hasCanonicalCustomMessage(eventId)) await this.dependencies.modules.policy("inputAdmission")?.().release(trigger.taskId, operationId, eventId);
      throw error;
    } finally {
      this.inboxAttributedMessages.delete(eventId);
      this.homeWakeTrigger = undefined;
    }
  }

  private hasCanonicalCustomMessage(eventId: string): boolean {
    return this.sessionManager.getBranch().some(entry => entry.type === "custom_message"
      && (entry.details as { eventId?: unknown } | undefined)?.eventId === eventId);
  }

  /** Persists the wake's canonical binding (its invocation to the trigger result) and the
   * trigger's delivery receipt. Both are lane work, so they precede the reply's terminal receipt. */
  private bindHomeWakeTrigger(trigger: { eventId: string; taskId: string; operationId: string }): void {
    void this.lane.run(async () => {
      const candidate = this.sessionManager.getBranch().find(entry => entry.type === "custom_message"
        && (entry.details as { eventId?: unknown } | undefined)?.eventId === trigger.eventId);
      if (!candidate) throw new Error("canonical Home wake trigger is unavailable");
      const invocation = this.runInvocations.invocationForOperation(trigger.operationId);
      if (!invocation) throw new Error("canonical invocation start receipt is unavailable");
      await this.persistCanonicalCustomEntry(
        INVOCATION_RECEIPT_TYPE,
        receiptJSON(makeInvocationReceipt({
          version: 1,
          receiptId: `binding:${invocation.invocationId}`,
          receiptKind: "binding",
          invocationId: invocation.invocationId,
          operationId: trigger.operationId,
          sessionId: this.id,
          source: "homeWake",
          canonicalEntryId: candidate.id,
          sequence: this.revision + 1,
          createdAt: new Date().toISOString(),
        })),
        `binding:${invocation.invocationId}`,
        this.runWork.get(trigger.operationId),
      );
      await this.persistCanonicalCustomEntry(CONTEXT_DELIVERY_RECEIPT_TYPE,
        safeJson(makeContextDeliveryReceipt(candidate.id, "stored", { source: "gateway:home-task",
          owner: { id: trigger.taskId, title: "Home task", source: "gateway:home-task" } })), candidate.id);
    });
  }

  /** The Home session has no operation left: a user activation or a wake ended. */
  public noteHomeIdle(): void {
    if (!this.homeRequestPolicy || this.phase !== "idle" || this.operation !== undefined || this.activeOperationId !== undefined) return;
    this.dependencies.modules.policy("runSettled")?.().idle(this.id, this.operationWasHomeWake ? "wake" : "user");
  }

  /** The managed provider uses user input to run Pi's normal before-agent-start
   * lifecycle. Admit it through the prompt owner, never the SDK's unowned wake
   * path: queued consumption and canonical binding retain this exact invocation. */
  readonly admitSubagentWake: ManagedInternalWake = async (content, options, owner, messages) => {
    const operationId = randomUUID();
    for (const message of messages) message.wakeOperationId = operationId;
    try {
      const text = typeof content === "string" ? content : content.filter(part => part.type === "text").map(part => part.text).join("\n");
      const images = typeof content === "string" ? [] : content.filter((part): part is ImageContent => part.type === "image");
      await this.prompt(text, images, options?.deliverAs, undefined, undefined, {
        kind: "subagentWake", operationId, expandPromptTemplates: options?.expandPromptTemplates ?? false,
        origin: { kind: "subagent", ownerId: owner.id, title: owner.title, confidence: "boundary" },
      });
    } catch (error) {
      this.emit("session.extensionError", safeJson({ code: "subagent-wake-admission-failed",
        message: error instanceof Error ? error.message : String(error), owner }));
    }
  };

  public persistTaskMarker(operationId: string): Promise<void> {
    return this.persistCanonicalCustomEntry(HOME_TASK_MARKER,
      JSON.parse(JSON.stringify({ version: 1, receiptId: `task:${operationId}`, ...this.taskWorker!.identity, sessionId: this.id })), `task:${operationId}`);
  }

  public noteAcceptedSteering(operationId: string): void {
      if (this.taskWorker && operationId !== this.taskWorker.identity.operationId) {
        this.dependencies.homeTaskDiagnostic?.({ event: "home.task.control",
          taskHash: createHash("sha256").update(this.taskWorker.identity.taskId).digest("hex").slice(0, 16),
          operationHash: createHash("sha256").update(this.taskWorker.identity.operationId).digest("hex").slice(0, 16),
          action: "steer", disposition: "accepted" });
      }
  }

  /** Republish this snapshot because the Gateway-owned archive projection
   * changed. Archive commits happen outside the run-admission lane, so this
   * mirrors `refreshCompactionPolicy`: publication, not an idle check. */
  refreshArchiveProjection(): void {
    this.revision += 1;
    this.publishSnapshot();
  }

  /** Settings writes only refresh the bounded projection. Budget application
   * stays at idle admission, never inside an active turn or prepared summary. */
  refreshCompactionPolicy(): void {
    try { this.compactionPolicies.get(this.runtime.session)?.refresh(); } catch { /* Published warning is authoritative. */ }
    this.revision += 1;
    this.publishSnapshot();
  }

  public resourceExpansionCatalog(): ResourceExpansionCatalog {
    const session = this.runtime.session;
    return { skills: session.resourceLoader.getSkills().skills, promptTemplates: session.promptTemplates };
  }

  /** Every resource a message invokes names exactly one loaded, unshadowed command. */
  /** The settings receipt coordinator publishes Home's recipe and adopts it
   * without releasing this runtime's lane or recursively entering its setters.
   * The fence is this runtime still being Home's, not the snapshot revision: a
   * resource reload publishes a new revision without changing the runtime, and
   * the appliers validate the recipe against the live runtime (#1672). */
  homeSettingsChapter(initiatingWorkToken?: string): NonNullable<ChangeContext["homeChapter"]> {
    const session = this.runtime.session;
    return {
      ...this.settingsSource(), sessionId: this.id,
      mutate: operation => this.lane.run(async () => {
        try {
          this.assertConfigurationIdle(initiatingWorkToken);
          this.assertChapterWritable();
          if (!this.usesHomeSettings || this.runtime.session !== session) {
            throw new GatewayError("conflict", "Home runtime changed before settings publication");
          }
        } catch (error) {
          return operation({ error: error instanceof GatewayError ? error : new GatewayError("internal", String(error)) });
        }
        return operation({ appliers: {
          setModel: (ref, fixedAt) => this.applyModelConfiguration(ref.provider, ref.id, initiatingWorkToken, undefined, fixedAt),
          setThinking: (level, fixedAt) => this.applyThinkingConfiguration(level as ThinkingLevel, initiatingWorkToken, undefined, fixedAt),
          setTools: (tools, fixedAt) => this.applyToolsConfiguration(tools, initiatingWorkToken, fixedAt),
          setContextWindow: () => { throw new GatewayError("invalid_request", "Home has no context window override"); },
          // The saved change is already authorized: its Session-scope pin follows it.
          setSetting: (key, value, _allowFixedDirection, fixedAt) => this.persistChatRunSetting(key, value, true, fixedAt),
        } });
      }),
    };
  }

  /** Home's saved settings own its model, thinking and tools: a direct choice is
   * that change, adopted under this lane like any other. */
  protected async changeHomeRecipe(key: string, value: unknown, initiatingWorkToken?: string): Promise<number> {
    await this.dependencies.settings()!.changes.change({ kind: "home" }, [{ key, layer: "session", op: "set", value }],
      { actor: { kind: "ui", id: "tron-home" }, commandId: randomUUID(), homeChapter: this.homeSettingsChapter(initiatingWorkToken) });
    return this.revision;
  }

  async rename(name: string): Promise<void> {
    await this.lane.run(() => {
      this.assertUsable();
      this.assertChapterWritable();
      this.runtime.session.setSessionName(name);
      this.summaryContentDirty = true;
      this.revision += 1;
      this.publishSnapshot();
      this.hooks.changed(this.id);
    });
  }

  async setLabel(entryId: string, label?: string, initiatingWorkToken?: string): Promise<void> {
    await this.lane.run(() => {
      this.assertIdle(false, initiatingWorkToken);
      if (!this.sessionManager.getEntry(entryId)) throw new GatewayError("not_found", "Session entry was not found");
      this.sessionManager.appendLabelChange(entryId, label?.trim() || undefined);
      this.summaryContentDirty = true;
      this.revision += 1;
      this.emit("session.structureChanged", { branchChanged: false });
      this.publishSnapshot();
    });
  }

  async fork(entryId: string, position: "before" | "at" = "at", initiatingWorkToken?: string): Promise<{ sessionId: string; selectedText?: string }> {
    return this.lane.run(async () => {
      this.assertIdle(false, initiatingWorkToken);
      const result = await this.runAttention.withRebindAttentionDisposition("reset", () => this.runtime.fork(entryId, { position }));
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
    initiatingWorkToken?: string,
  ): Promise<{ editorText?: string }> {
    return this.lane.run(async () => {
      this.assertIdle(false, initiatingWorkToken);
      // Plain tree navigation is a read. Only the model-backed branch summary is
      // work, so only it clears retained archive state.
      if (options.summarize) await this.dependencies.beforeRunAdmission(this.id);
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
        // Navigation rewrites the branch the memory projects: entries the branch
        // no longer holds become omitted, and the view is folded again.
        this.noteCanonicalEntriesCommitted();
        this.forkBoundary = await this.dependencies.resolveForkBoundary?.(this.sessionManager);
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

  history(expectedRuntime: string, cursor?: HistoryCursor) {
    this.assertNoTrustReload();
    if (expectedRuntime !== this.runtimeGeneration) throw new GatewayError("conflict", "Session runtime changed. Reload history.", true);
    return historyPage(this.runtime.session.sessionManager, this.runtimeGeneration, cursor);
  }

  historyDetail(expectedRuntime: string, entryId: string, offset: number) {
    this.assertNoTrustReload();
    if (expectedRuntime !== this.runtimeGeneration) throw new GatewayError("conflict", "Session runtime changed. Reload history.", true);
    return historyEntry(this.runtime.session.sessionManager, this.runtimeGeneration, entryId, offset);
  }

  tree(): SessionTreeNode[] {
    this.assertNoTrustReload();
    return projectTree(this.displayProjection, this.runtime.session.sessionManager, this.dependencies.blobs);
  }

  commands(): CommandInfo[] {
    this.assertNoTrustReload();
    const session = this.runtime.session;
    const extension: CommandInfo[] = session.extensionRunner.getRegisteredCommands().map((command) => {
      const distribution = resourceDistribution(command.sourceInfo);
      return {
        name: command.invocationName,
        ...(command.description ? { description: command.description } : {}),
        source: "extension" as const,
        sourcePath: command.sourceInfo.path,
        resourceSource: command.sourceInfo.source,
        resourceScope: command.sourceInfo.scope,
        resourceOrigin: command.sourceInfo.origin,
        ...(distribution ? { distribution } : {}),
      };
    });
    const prompts: CommandInfo[] = session.promptTemplates.map((prompt) => {
      const distribution = resourceDistribution(prompt.sourceInfo);
      return {
        name: prompt.name,
        ...(prompt.description ? { description: prompt.description } : {}),
        ...(prompt.argumentHint ? { argumentHint: prompt.argumentHint } : {}),
        source: "prompt" as const,
        sourcePath: prompt.filePath,
        resourceSource: prompt.sourceInfo.source,
        resourceScope: prompt.sourceInfo.scope,
        resourceOrigin: prompt.sourceInfo.origin,
        ...(distribution ? { distribution } : {}),
      };
    });
    const skills: CommandInfo[] = session.resourceLoader.getSkills().skills.map((skill) => {
      const distribution = resourceDistribution(skill.sourceInfo);
      const title = skillTitle(skill.filePath);
      return {
        name: `skill:${skill.name}`,
        ...(title ? { title } : {}),
        ...(skill.description ? { description: skill.description } : {}),
        source: "skill" as const,
        sourcePath: skill.filePath,
        resourceSource: skill.sourceInfo.source,
        resourceScope: skill.sourceInfo.scope,
        resourceOrigin: skill.sourceInfo.origin,
        ...(distribution ? { distribution } : {}),
      };
    });
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

  async context(): Promise<JsonValue> {
    this.assertNoTrustReload();
    const workspace = await this.dependencies.workspace.describe();
    this.assertNoTrustReload();
    const session = this.runtime.session;
    return safeJson({
      // Older clients read Pi's base prompt; `instructions` is the complete
      // attributed prompt the model receives, including the per-turn context.
      systemPrompt: session.systemPrompt,
      instructions: this.agentInstructions(tronContext(workspace, this.cwd, session.getActiveToolNames())),
      contextUsage: session.getContextUsage(),
      stats: session.getSessionStats(),
      activeTools: session.getActiveToolNames(),
      availableTools: session.getAllTools().map((tool) => ({
        ...tool,
        ...(tool.namespace ? { namespace: tool.namespace } : {}),
        ...(tool.annotations ? { annotations: tool.annotations } : {}),
      })),
      commands: this.commands(),
      ...this.resourcesValue(),
      diagnostics: this.runtime.diagnostics,
    });
  }

  private agentInstructions(turnContext: string): AgentInstructions {
    const session = this.runtime.session;
    const loader = session.resourceLoader;
    const customPrompt = loader.getSystemPrompt();
    const appendTexts = loader.getAppendSystemPrompt();
    const appendPaths = loader.getAppendSystemPromptSources().map((source) => source.path);
    return projectAgentInstructions({
      prompt: session.systemPrompt,
      tronContext: turnContext,
      ...(customPrompt ? { customPrompt: { text: customPrompt, ...(loader.getSystemPromptSource() ? { path: loader.getSystemPromptSource()!.path } : {}) } } : {}),
      // Paths pair with texts only when every append source is a file.
      append: appendTexts.map((text, index) => ({ text, ...(appendPaths.length === appendTexts.length ? { path: appendPaths[index]! } : {}) })),
      contextFiles: loader.getAgentsFiles().agentsFiles,
      skills: loader.getSkills().skills,
      tools: session.getAllTools(),
    });
  }

  async resources(): Promise<JsonValue> {
    this.assertNoTrustReload();
    const subagents = await this.subagentCatalog();
    return safeJson({
      commands: this.commands(),
      ...this.resourcesValue(),
      subagents: subagents.subagents.map(availableSubagentRow),
      ...(subagents.diagnostic ? { subagentDiagnostics: subagents.diagnostic } : {}),
    });
  }

  async subagentDetail(name: string): Promise<SubagentDetail> { this.assertNoTrustReload(); return subagentDetail((await this.subagentCatalog()).subagents, name); }
  /** Failure-soft, uncached discovery for `resources()` and `subagentDetail`: unavailable is empty plus a diagnostic. */
  private async subagentCatalog(): Promise<SubagentCatalog> {
    if (!this.liveProfile().subagentCatalog) return { subagents: [] };
    return loadSubagentCatalog({
      agentDir: this.dependencies.agentDir,
      cwd: this.cwd,
      settingsManager: this.runtime.session.settingsManager,
      ...(this.dependencies.managedSubagents ? { managedSubagents: this.dependencies.managedSubagents } : {}),
    });
  }

  private resourcesValue(): Record<string, unknown> {
    const session = this.runtime.session;
    const loader = session.resourceLoader;
    const allExtensions = loader.getExtensions().extensions;
    const allLoadErrors = loader.getExtensions().errors;
    const allLoadWarnings = loader.getExtensions().warnings ?? [];
    const hookProjection = projectHookRegistrations(
      allExtensions.map((extension) => ({
        name: basename(extension.path),
        path: extension.path,
        resolvedPath: extension.resolvedPath,
        scope: extension.sourceInfo.scope,
        source: extension.sourceInfo.source,
        origin: extension.sourceInfo.origin,
        tools: extension.tools.keys(),
        commands: extension.commands.keys(),
        handlers: extension.handlers,
      })),
      allLoadErrors,
      allLoadWarnings,
    );
    const extensionValues = hookProjection.extensions;
    const loadErrorValues = hookProjection.extensionLoadErrors;
    const hookInventory = hookProjection.hookInventory;
    return {
      tools: session.getAllTools().map((tool) => {
        const distribution = resourceDistribution(tool.sourceInfo);
        return {
          name: tool.name,
          ...(this.toolLabel(tool.name) ? { label: this.toolLabel(tool.name)! } : {}),
          description: tool.description,
          exposure: tool.exposure,
          ...(tool.namespace ? { namespace: tool.namespace } : {}),
          ...(tool.annotations ? { annotations: tool.annotations } : {}),
          scope: tool.sourceInfo.scope,
          source: tool.sourceInfo.source,
          ...(distribution ? { distribution } : {}),
          parameters: tool.parameters,
          promptGuidelines: tool.promptGuidelines,
        };
      }),
      skills: {
        skills: loader.getSkills().skills.map((skill) => {
          const distribution = resourceDistribution(skill.sourceInfo);
          return {
            name: skill.name,
            description: skill.description,
            path: skill.filePath,
            scope: skill.sourceInfo.scope,
            source: skill.sourceInfo.source,
            ...(distribution ? { distribution } : {}),
            disableModelInvocation: skill.disableModelInvocation,
          };
        }),
        diagnostics: loader.getSkills().diagnostics,
      },
      prompts: {
        prompts: loader.getPrompts().prompts.map((prompt) => {
          const distribution = resourceDistribution(prompt.sourceInfo);
          return {
            name: prompt.name,
            description: prompt.description,
            argumentHint: prompt.argumentHint,
            path: prompt.filePath,
            scope: prompt.sourceInfo.scope,
            source: prompt.sourceInfo.source,
            ...(distribution ? { distribution } : {}),
          };
        }),
        diagnostics: loader.getPrompts().diagnostics,
      },
      extensions: extensionValues,
      extensionLoadErrors: loadErrorValues,
      hookInventory,
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

  async reload(projectTrusted?: boolean, publish = true, trustTransition = false, initiatingWorkToken?: string): Promise<void> {
    await this.lane.run(async () => {
      if (this.trustReloadWork) this.assertUsable(true);
      else this.assertIdle(trustTransition, initiatingWorkToken);
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

  async export(format: "html" | "jsonl"): Promise<{ blobId: string; name: string; mimeType: string; size: number }> {
    this.assertUsable();
    const work = this.dependencies.workRegistry.begin({
      kind: "compaction-export",
      sessionId: this.id,
      hostEpoch: this.ui.hostEpoch,
    });
    this.activeExports += 1;
    try {
      return await this.dependencies.exports.withFileProductionAdmission(async () => {
        const capture = await this.lane.run(async (): Promise<{
          file?: CanonicalSessionFileCut;
          projection?: { header: unknown; entries: readonly unknown[] };
          exportName: string;
        }> => {
          this.assertUsable();
          const manager = this.sessionManager;
          const exportName = basename(this.runtime.session.sessionName ?? this.id)
            .replace(/[^A-Za-z0-9._-]+/g, "-");
          if (format === "html") {
            return {
              projection: { header: manager.getHeader(), entries: manager.getBranch() },
              exportName,
            };
          }
          const source = this.runtime.session.sessionFile;
          if (source && existsSync(source)) {
            if (lstatSync(source).isSymbolicLink()) {
              throw new GatewayError("conflict", "Canonical session export source cannot be a symbolic link");
            }
            let handle: CanonicalSessionFileCut["handle"];
            try {
              handle = await open(source, constants.O_RDONLY | constants.O_NOFOLLOW);
            } catch (error) {
              if ((error as NodeJS.ErrnoException).code === "ELOOP") {
                throw new GatewayError("conflict", "Canonical session export source cannot be a symbolic link");
              }
              throw error;
            }
            try {
              const metadata = await handle.stat();
              if (!metadata.isFile() || metadata.size > SESSION_EXPORT_MAX_ITEM_BYTES) {
                throw new GatewayError("conflict", "Session export exceeds the 2 GiB export limit");
              }
              if (metadata.size === 0) {
                throw new GatewayError("conflict", "Canonical session file is empty; repair or remove it before exporting");
              }
              const terminator = Buffer.allocUnsafe(1);
              const { bytesRead } = await handle.read(terminator, 0, 1, metadata.size - 1);
              if (bytesRead !== 1 || terminator[0] !== 0x0a) {
                throw new GatewayError("busy", "Canonical session is between complete JSONL boundaries; retry export", true);
              }
              return { file: { handle, size: metadata.size }, exportName };
            } catch (error) {
              await handle.close().catch(() => {});
              throw error;
            }
          }
          return {
            projection: { header: manager.getHeader(), entries: manager.getEntries() },
            exportName,
          };
        });

        let directory: string | undefined;
        try {
          if (capture.file) {
            await requireSessionExportDiskCapacity(tmpdir(), capture.file.size * 2);
          }
          directory = await mkdtemp(join(tmpdir(), "tron-session-export-"));
          const snapshot = join(directory, "session.jsonl");
          if (capture.file) {
            await copyCanonicalSessionCut(capture.file, snapshot);
          } else if (capture.projection) {
            await writeSessionProjectionCut(capture.projection, snapshot);
          } else {
            throw new GatewayError("internal", "Session export snapshot was not captured");
          }

          const path = format === "html" ? join(directory, "session.html") : snapshot;
          if (format === "html") {
            // The child renderer is isolated; its parent-owned output stream
            // admits disk in bounded increments and enforces the item ceiling.
            await renderSessionCutToHtml(snapshot, path);
          }
          const metadata = await stat(path);
          if (!metadata.isFile() || metadata.size > SESSION_EXPORT_MAX_ITEM_BYTES) {
            throw new GatewayError("conflict", "Session export exceeds the 2 GiB export limit");
          }
          await requireSessionExportDiskCapacity(directory, metadata.size);
          const mimeType = format === "html" ? "text/html; charset=utf-8" : "application/x-ndjson";
          const name = `${capture.exportName || "session"}.${format}`;
          return {
            blobId: await this.dependencies.exports.registerFile(path, mimeType),
            name,
            mimeType,
            size: metadata.size,
          };
        } finally {
          await capture.file?.handle.close().catch(() => {});
          if (directory) await rm(directory, { recursive: true, force: true });
        }
      });
    } finally {
      this.activeExports = Math.max(0, this.activeExports - 1);
      work.settle();
    }
  }

  /** Queue a retirement barrier behind admitted lane work without disposing the
   * slot, then wait (bounded by the ownership grace) until the admitted operation
   * has settled. The lane alone releases while a run is still in flight, and the
   * Gateway settles its terminal after the SDK idles, so eligibility checked
   * earlier would refuse a runtime about to become idle. On timeout the caller's
   * own eligibility check still refuses retryably. The Registry remains the sole
   * owner of disposal and publication. Work running on this lane must never await
   * this barrier. */
  async retireAfterSettled(): Promise<void> {
    const deadline = performance.now() + DEFAULT_OWNERSHIP_WRITE_RETRY_WINDOW_MS;
    for (;;) {
      await this.lane.run(() => {});
      // The same predicate disposeIf enforces: canonical receipt writes gate
      // disposal as well as busy state.
      if (!this.isBusy && this.runPersistence.pendingReceiptWrites.size === 0) return;
      const remaining = deadline - performance.now();
      if (remaining <= 0) return;
      await new Promise<void>((resolve) => {
        const timer = setTimeout(() => wake(), remaining);
        const wake = () => {
          clearTimeout(timer);
          this.settleWaiters.delete(wake);
          resolve();
        };
        this.settleWaiters.add(wake);
      });
    }
  }

  /** Wakes `retireAfterSettled` waiters so each rechecks settled state. */
  public releaseSettleWaiters(): void {
    for (const wake of [...this.settleWaiters]) wake();
  }

  async dispose(exceptWorkToken?: string): Promise<void> {
    if (this.disposed) return;
    this.runPersistence.assertOwnershipPersistence();
    if ((this.isBusyExceptWorkToken(exceptWorkToken) && this.runPersistence.pendingReceiptWrites.size === 0) || this.trustReloadPending) throw new GatewayError("busy", "Cannot dispose a busy session runtime");
    await this.runPersistence.waitForReceiptWrites();
    await this.disposeIf(() => true, exceptWorkToken);
  }

  /**
   * Disposes an idle slot only if its registry reservation is still current
   * after any preceding lane work settles. This is the handoff point that lets
   * a newly acquired or subscribed session cancel idle eviction safely.
   */
  async disposeIf(shouldDispose: () => boolean, exceptWorkToken?: string): Promise<boolean> {
    if (this.disposed) return false;
    return this.lane.run(async () => {
      if (this.disposed) return false;
      this.runPersistence.assertOwnershipPersistence();
      // Automatic eviction never waits behind canonical receipt persistence.
      // Receipt work protects the existing slot; a later idle pass may retry
      // only after that authority settles. Explicit shutdown/delete continues
      // to join receipt writes through dispose()/performShutdown().
      if (this.isBusyExceptWorkToken(exceptWorkToken) || this.runPersistence.pendingReceiptWrites.size > 0 || this.trustReloadPending) {
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

  /** The registry publishes one newly live runtime. Until then the slot is a
   * start that may still be retired, so it is not yet a runtime the sample can
   * report a load or an eviction for. */
  markPublished(): void {
    this.published = true;
    this.publishConfiguration();
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
    const interruptedOperationId = this.operation?.kind === "command" ? undefined : this.activeOperationId ?? this.pendingPrompt?.id;
    const interruptedInvocation = this.runInvocations.invocationForOperation(interruptedOperationId);
    const interruptedSource = interruptedInvocation ? `terminal:${interruptedInvocation.invocationId}` : interruptedOperationId;
    if (interruptedSource) this.runTerminal.completionObserved(interruptedSource);
    this.shuttingDown = true;
    const cancellation = new GatewayError("cancelled", "Gateway shutdown cancelled queued compaction");
    this.manualCompaction.cancelPending(cancellation);

    // Abort every possible SDK owner before waiting on the lane it may hold.
    // These methods are idempotent no-ops when their owner is inactive.
    this.runtime.session.abortCompaction();
    this.runtime.session.abortRetry();
    this.runtime.session.abortBranchSummary();
    this.runtime.session.abortBash();
    await Promise.all([
      this.runtime.session.abort(),
      this.directBashProcesses?.abortAll() ?? Promise.resolve(),
    ]);
    await this.runPersistence.waitForReceiptWrites();
    // A command may hold the mutation lane while awaiting native UI. Cancel the
    // epoch's imperative interactions before joining that lane so shutdown cannot
    // deadlock behind a response that no client can deliver.
    this.ui.cancelAll("Gateway shutdown interrupted extension interaction");

    await this.lane.run(async () => {
      this.manualCompaction.finishShutdown(cancellation);
      if (interruptedSource) {
        await this.runInvocations.terminalizeInvocation(interruptedOperationId, "outcomeUnknown", "runtime-disposed");
        await this.runTerminal.notifyAgentTerminal(interruptedSource, "interrupted");
      }
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
    this.runTerminal.operationObservations.clear();
    // Borrowed Home views have no attachment to detach; the shared Gateway
    // installation outlives this slot and is retired by its own runtime owner.
    this.detachOpenAIEligibility?.();
    this.detachOpenAIEligibility = undefined;
    this.dependencies.modules.observers("sessionRetired").forEach(retire => { try { retire(this.id); } catch { /* Cleanup is best effort. */ } });
    this.unregisterExtensionExpiry();
    this.unregisterProcessExpiry();
    for (const activity of this.extensionActivities.values()) {
      this.dependencies.extensionActivityRecency.remove(activity.activityId ?? activity.id);
    }
    for (const processId of this.processActivities.keys()) {
      this.dependencies.processActivityRecency.remove(processId);
    }
    this.processActivities.clear();
    this.processOperationIDs.clear();
    this.processIDsByToolCall.clear();
    this.pendingProcessRemovalsByToolCall.clear();
    this.childSessionAdmission.clear();
    this.childSessionBindings.clear();
    if (this.snapshotTimer) clearTimeout(this.snapshotTimer);
    if (this.progressFlushTimer) clearTimeout(this.progressFlushTimer);
    this.progressFlushTimer = undefined;
    this.pendingProgressMessage = undefined;
    this.latestStreamingMessage = undefined;
    this.runTerminal.notificationRun = undefined;
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
    this.extensionArtifactMissingSince.clear();
    this.extensionRunOwnership.clear();
    this.unsubscribe?.();
    this.ui.cancelAll();
    // An admitted automation must never lose its terminal waiter when runtime
    // teardown wins a callback race. Persist uncertainty while the canonical
    // manager is still writable; recovery can then block instead of replaying.
    for (const operationId of [...this.runTerminal.ownedTerminalObservers.keys()]) {
      const invocation = this.runInvocations.invocationForOperation(operationId);
      if (invocation) {
        await this.runInvocations.terminalizeInvocation(operationId, "outcomeUnknown", "runtime-disposed");
      } else {
        await this.runTerminal.notifyOwnedTerminal({
          lifecycle: "outcomeUnknown",
          operationId,
          invocationId: operationId,
          errorCode: "runtime-disposed",
        });
      }
    }
    // Pi owns session_shutdown before its extension context is invalidated.
    // Keep semantic presentation live through that bounded callback; the
    // disposal grace still force-retires a blocking third-party cleanup.
    await this.disposeAgentRuntime();
    // session_shutdown can synchronously enqueue canonical notification/context
    // effects while this lane is held. Flush them here rather than leaving a
    // nested lane task behind the disposal that produced them.
    await this.flushPendingExtensionCanonicalEffects();
    await this.runPersistence.waitForReceiptWrites();
    this.extensionHost.retire("Session runtime disposed");
    // Waiting prompts are process-local like Pi's own queue.
    this.heldQueue.reset();
    this.runWork.settleAll();
    this.lifecycle.retire();
    this.ui.retire();
    this.unregisterConfigurationWork?.();
    this.unregisterConfigurationWork = undefined;
    this.disposed = true;
    // One live runtime is gone. This is the only place a slot stops existing, so
    // the resource sample counts the eviction where it happens and can see a
    // load and an eviction inside one window. A slot the registry never
    // published was never live, so its retirement is not an eviction.
    if (this.published) this.dependencies.resources?.recordRuntimeEvicted();
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

  public assertUsable(allowTrustReload = false): void {
    this.assertAvailable(allowTrustReload);
    this.runPersistence.assertOwnershipPersistence();
  }

  public assertAvailable(allowTrustReload = false): void {
    if (this.disposed) throw new GatewayError("conflict", "Session runtime was disposed", true);
    if (this.shuttingDown) throw new GatewayError("conflict", "Session runtime is shutting down", true);
    if (!allowTrustReload) this.assertNoTrustReload();
    this.touch();
  }


  public publishConfiguration(): void {
    if (!this.published || this.disposed) return;
    const configurationBlocker = this.configurationBlocker();
    if (configurationBlocker === this.publishedConfigurationBlocker) return;
    // Work admission/retirement is sequenced projection, not a canonical
    // configuration edit: changing revision here self-invalidates context CAS.
    this.emit("session.configuration", { configurationBlocker });
    this.publishedConfigurationBlocker = configurationBlocker;
  }



  protected assertChapterWritable(manager: SessionManager = this.sessionManager): void {
    this.dependencies.modules.policy("appendGuard")?.(this.canonicalAppendContext).assertWritable(manager);
  }

  public assertHomePromptAdmission(): void {
    this.dependencies.modules.policy("appendGuard")?.(this.canonicalAppendContext).admission();
  }

  /** The same idle predicate `assertIdle` applies, classified retryably because
   * a profile change is safe to retry once the run settles. */
  private assertProfileChangeIdle(): void {
    this.assertUsable();
    if (this.isRunningWork()) {
      throw new GatewayError("busy", "Tron Home's session is running; retry when it is idle", true);
    }
  }

}
