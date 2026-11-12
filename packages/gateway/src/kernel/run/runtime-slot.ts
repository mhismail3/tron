import { isEmbeddedLifecycleArtifact } from "../delegation/subagent-artifact-status.js";
import { updateNestedExtensionActivity, extensionActivityOwnsLiveWork, pausedProcessSettlementAt, hydrateCanonicalExtensionActivities, updateExtensionActivity, onExtensionActivityExpiry } from "../delegation/subagent-activity.js";
import { WorkerSettlement } from "../delegation/worker-settlement.js";

import type { TaskWorkerDiagnostic } from "../delegation/worker-contract.js";
import * as activityProjection from "../projection/activity.js";
import * as sessionPages from "../projection/session-pages.js";
import { SnapshotProjection } from "../projection/snapshot.js";
import { createSettingsManager } from "../settings/settings-sdk-manager.js";
import { applyModelAdmission, compactionAdmission } from "../settings/settings-admission.js";
import { managedProviderSettingsView, type ManagedSubagents } from "../delegation/managed-subagents.js";
import { createHash, randomUUID } from "node:crypto";
import type { SessionConfigurationBlocker } from "../../protocol/types.js";
import { boundedSummaryText } from "../../util/bounded-text.js";
import { catalogActivityTimestamp } from "../../sessions/catalog-metadata-index.js";
import { historyPage, historyEntry, type HistoryCursor } from "../projection/history.js";
import { delegatedProviderToolVersion } from "../delegation/delegated-provider.js";
import type { AgentMessage, ThinkingLevel } from "../pi/agent-core.js";
import { SESSION_SETTINGS_ENTRY, changeSessionSetting, readSessionSettings, readSessionRequestPins, readSessionFixedSettings, readSessionToolChoice } from "../../sessions/session-settings.js";
import { constants, existsSync, lstatSync, realpathSync, statSync } from "node:fs";
import { performance } from "node:perf_hooks";
import { mkdtemp, open, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { type ImageContent, type Model } from "../pi/ai.js";
import { bindRuntimeSession, guardCanonicalAppend } from "../pi/adapters.js";
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
} from "../pi/coding-agent.js";
import { GatewayError, asUncertainOutcome } from "../../errors.js";
import { CanonicalCustomEntryConflictError, DEFAULT_OWNERSHIP_WRITE_RETRY_WINDOW_MS } from "./run-persistence.js";
import { type CommandReplacement } from "./run-invocations.js";
import { RunOperations } from "./run-operations.js";
import { successfulAssistantCompletion, type CanonicalAssistantCompletion, type SessionAttentionRebindDisposition } from "./completion-facts.js";
import { RunRequestPipeline } from "./request-pipeline.js";
import type { RequestRecord } from "./request-record.js";
import { boundToolCancellation } from "./bounded-tool-cancellation.js";
import { CompactionOperationPolicy } from "./compaction-policy.js";
import type { RequestPolicy } from "../host/request-policy.js";
import type { SessionLineagePolicy } from "../host/session-lineage.js";
import type { CanonicalAppendContext } from "../host/canonical-append.js";
import { createHomeTaskWorkerExtension } from "../delegation/task-worker-extension.js";
import { workerFinishTurn } from "../delegation/worker-turn-boundary.js";

import { HOME_TASK_MARKER, HOME_TASK_REPORT, reportLiveRunsRefusal, type HomeTaskReportOwner } from "../delegation/task-report.js";
import { ORDINARY_SESSION_PROFILE, type SessionProfile } from "../host/session-profile.js";
import type { ChangeContext, SessionAppliers, SettingsChangePath, SettingsNotice } from "../settings/settings-change.js";
import { setPath, type SessionSettingsSource, type SettingsModel } from "../settings/settings-model.js";
import { SETTINGS_OUTCOME_MESSAGE, CONTEXT_DELIVERY_RECEIPT_TYPE } from "../receipts/delivery-tags.js";
import { type SettingsSignal, type SettingsToolAccess, type TaskWorkerSettingsState, type FixedSetting, type LayerId } from "../settings/tool-contract.js";
import type { Actor } from "../settings/settings-record.js";
import { piBuiltinExtensions } from "../host/pi-builtins.js";
import { currentMcpAuthOperationId, currentMcpAuthTarget } from "../host/extension-adapters.js";
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
} from "../../protocol/types.js";
import { AsyncMutex } from "../../util/async-mutex.js";
import { stage } from "../../util/request-span.js";
import type { ResourceRecorder } from "../../util/resource-recorder.js";
import type { TrustService } from "../resources/trust-service.js";
import type { BlobStore } from "../../sessions/blob-store.js";
import {
  SESSION_EXPORT_MAX_ITEM_BYTES,
  copyCanonicalSessionCut,
  renderSessionCutToHtml,
  requireSessionExportDiskCapacity,
  writeSessionProjectionCut,
  type CanonicalSessionFileCut,
} from "../../sessions/session-export.js";
import { SemanticUIBroker, type ExtensionNotificationInput } from "../host/semantic-ui-broker.js";
import { ExtensionPresentationStore } from "../host/presentation/extension-presentation-store.js";
import { ExtensionLifecycleCoordinator } from "../host/extension-lifecycle-coordinator.js";
import { RemotePiExtensionHost } from "../host/presentation/remote-pi-extension-host.js";
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
} from "../projection/projection.js";
import type { ForkBoundaryAnchor } from "../../sessions/fork-boundary.js";
import { type RunMarkerStore } from "./run-markers.js";
import { attributedCommandOwner, attributedToolOwner, isBuiltinMcpCommand } from "../host/extension-registration.js";
import { currentExtensionOwner, currentInvocationContext } from "../host/extension-execution-context.js";
import { capturedManagedMessage, isManagedProducerContent, type ManagedMessageCapture, type ManagedInternalWake } from "../delegation/managed-producer.js";
import { type ExtensionArtifactRejectionReason } from "../projection/extension-run-projection.js";
import { ChildSessionAdmission } from "../delegation/child-session-admission.js";
import { extensionActivityReceipts, extensionReceiptActivity } from "../receipts/extension-activity-history.js";
import { makeContextDeliveryReceipt } from "../receipts/context-delivery-receipts.js";
import { INVOCATION_RECEIPT_TYPE, makeInvocationReceipt, receiptJSON } from "../receipts/invocation-receipts.js";
import { inputMessageOrigin, type InputTrigger } from "../host/input-admission.js";
import { EXTENSION_NOTIFICATION_RECEIPT_TYPE, extensionNotificationJSON, makeExtensionNotificationReceipt } from "../receipts/extension-notification-receipts.js";
import { userFacingPromptPreview } from "../resources/resource-invocation.js";
import { type ResourceExpansionCatalog } from "../resources/resource-expansion.js";
import { ExtensionActivityRecency } from "../../sessions/extension-activity-recency.js";
import { ProcessActivityRecency, isActiveProcessLifecycle, type ProcessActivityExpiryFrame } from "../projection/process-activity-recency.js";
import { processHistoryDetail, subagentProcessId, subagentProcessesFromActivity } from "../projection/process-activity.js";
import type { GatewayWorkHandle, GatewayWorkRegistry } from "./gateway-work-registry.js";
import type { ResourceRoot } from "../resources/resource-root.js";
import { projectAgentInstructions, type AgentInstructions } from "../../sessions/agent-instructions.js";
import type { ToolDisplayProjection, ToolReferences } from "../projection/tool-result.js";
import { trustedExtensionOriginKind } from "../projection/extension-origin.js";
import { DirectBashProcessOwner } from "./direct-bash-process-owner.js";
import type { ContextPolicy, ModuleHost, SessionContext } from "../host/module-host.js";
import { projectHookRegistrations } from "../projection/hook-projection.js";
import { resourceDistribution } from "../../sessions/resource-distribution.js";
import { skillTitle } from "../../sessions/skill-title.js";
import { boundedUtf8Prefix } from "../../util/bounded-text.js";
import { availableSubagentRow, loadSubagentCatalog, subagentDetail, type SubagentCatalog, type SubagentDetail } from "../delegation/subagent-catalog.js";
import type { SessionStore } from "../settings/settings-types.js";
import { hasCompactionApplier, type SettingsSchema, type KeyDeclaration } from "../settings/settings-schema.js";

export type SessionBroadcast = (sessionId: string, topic: string, payload: JsonValue) => void;

type PendingContextMessage = {
  kind: "context";
  targetEntryId?: string;
  delivery: "stored" | "triggeredTurn";
  origin?: ExtensionToolOrigin;
  managedMessage?: ManagedMessageCapture;
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

const STREAMING_PROGRESS_FLUSH_MS = 150;
const DEFAULT_RUNTIME_DISPOSAL_GRACE_MS = 5_000;
const MAX_PRESENTATION_IDENTITY_BINDINGS = 512;

interface RuntimeSlotHooks {
  broadcast: SessionBroadcast;
  summaryChanged: (summary: SessionSummaryUpdate) => void;
  changed: (sessionId: string) => void;
  settled: (sessionId: string) => void;
  idle?: (slot: RuntimeSlot) => void;
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
  homeTaskSettings: (sessionId: string, taskId: string, purpose: "resolve" | "change") => Promise<{
    taskId: string; sessionId: string; operationId: string | null; state: string; resolvedFrom?: string; slot: RuntimeSlot;
  }>;
  validateTaskMarker: (sessionId: string, marker: unknown) => Promise<void>;
  homeTaskDiagnostic?: (record: TaskWorkerDiagnostic) => void;
  managedSubagents?: ManagedSubagents;
  delegatedArtifactRoot?: string;
  mcpAuth?: { openUrl(operationId: string, url: string, sessionId: string, server: string): void };
  createModelRuntime: () => Promise<ModelRuntime>;
  trust: TrustService;
  blobs: BlobStore;
  exports: BlobStore;
  modules: ModuleHost;
  readonly settingsSchema: SettingsSchema;
  settings: () => { model: SettingsModel; changes: SettingsChangePath } | undefined;
  workspace: ResourceRoot;
  markers: RunMarkerStore;
  extensionActivityRecency: ExtensionActivityRecency;
  processActivityRecency: ProcessActivityRecency;
  workRegistry: GatewayWorkRegistry;
  isSessionPresented: (sessionId: string) => boolean;
  sessionAudience: (sessionId: string) => number;
  resources?: ResourceRecorder;
  machineId?: string;
  extensionArtifactWarning?: (warning: { reason: ExtensionArtifactRejectionReason; owner: string }) => void;
  runtimeDisposalTimedOut?: (graceMs: number) => void;
  persistenceDiagnostic?: (sessionId: string, code: string) => void;
  compactionDiagnostic?: (diagnostic: { sessionId: string; operationId?: string; reason: "manual" | "threshold" | "overflow"; outcome: "success" | "failure" | "cancelled"; errorMessage?: string }) => void;
  stopSteeringDiagnostic?: (diagnostic: { sessionId: string; queuedSteerCount: number; outcome: "started" | "completed" | "stopped" | "failed" | "unknown" }) => void;
  manualCompactionAdopted?: NonNullable<RunOperations<FixedSetting>["dependencies"]["manualCompactionAdopted"]>;
  requestRecord?: (record: RequestRecord) => void;
  capabilityDiagnostic?: (aggregate: { name: string; count: 1; status: "ok" | "error" | "refused" | "unknown"; latencyBucket: "lt100ms" | "lt1s" | "lt10s" | "gte10s" | "unknown" }) => void;
  codemodeDiagnostic?: (diagnostic: { sessionId: string; outcome: "completed" | "failed" | "aborted" | "timeout"; durationMs: number; nestedCallCount: number; complete: boolean }) => void;
  resolveForkBoundary?: (manager: SessionManager) => Promise<ForkBoundaryAnchor | undefined>;
  beforeRunAdmission: (sessionId: string) => Promise<void>;
  archivedAt: (sessionId: string) => string | undefined;
  sessionLineage: () => SessionLineagePolicy;
}

interface RuntimeDrainBlockerFact {
  key: string;
  category: AdministrativeDrainBlockerCategory;
  state: "active" | "settling" | "suspect";
  admittedAt?: string;
  progressAt?: string;
}

export class RuntimeSlot extends RunOperations<FixedSetting> {
  public readonly contextPolicies = new WeakMap<AgentSession, ContextPolicy>();
  private readonly newSettingsSessions = new WeakSet<AgentSession>();
  public readonly compactionPolicies = new WeakMap<AgentSession, CompactionOperationPolicy>();
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
  private readonly createdAt = new Date().toISOString();
  private forkBoundary: ForkBoundaryAnchor | undefined;
  private toolReferenceCut: { key: string; value: ToolReferences } | undefined;
  private eventSequence = 0;
  public disposed = false;
  private published = false;
  private readonly stateChangeWaiters = new Set<() => void>();
  private retainedLeaseCount = 0;
  private snapshotTimer: NodeJS.Timeout | undefined;
  private progressFlushTimer: NodeJS.Timeout | undefined;
  private pendingProgressMessage: AgentMessage | undefined;
  private latestStreamingMessage: AgentMessage | undefined;
  private streamIdentityMessage: AgentMessage | undefined;
  private streamAnchorId: string | null | undefined;
  private streamPresentationId: string | undefined;
  private streamStartedAt: string | undefined;
  private finalizedStreamPresentationId: string | undefined;
  private readonly canonicalizedStreamingMessages = new WeakSet<object>();
  public commandReplacement: CommandReplacement | undefined;
  private readonly presentationIDs = new Map<string, string>();
  private readonly presentationIDOrder: string[] = [];
  public activityHeartbeat: NodeJS.Timeout | undefined;
  private readonly toolProgressTimers = new Map<string, NodeJS.Timeout>();
  private readonly toolProgressPublishedAt = new Map<string, number>();
  private readonly toolStartedAtMonotonicMs = new Map<string, number>();
  private readonly nestedToolRoots = new Map<string, string>();
  private readonly nestedToolStartedAt = new Map<string, number>();
  public activeToolSegmentOwnerId: string | undefined;
  public toolSegmentAwaitsAssistantOwner = false;
  public activeExports = 0;
  private resourceReloadOptions: { resolveProjectTrust: () => Promise<boolean> } | undefined;
  private projectTrustReloadOverride: boolean | undefined;
  public trustReloadPending = false;
  private trustReloadWork: GatewayWorkHandle | undefined;
  public readonly toolExecutions = new Map<string, ToolExecutionState>();
  private readonly canonicalToolResultHandoffs = new Set<string>();
  private readonly toolInvocationGroups = new Map<string, Pick<
    ToolProjectionMetadata,
    "toolSegmentId" | "groupId" | "groupIndex" | "groupCount" | "groupFinalized"
  >>();
  readonly workerSettlement = new WorkerSettlement(DEFAULT_RUNTIME_DISPOSAL_GRACE_MS);
  private extensionShutdownWork: GatewayWorkHandle | undefined;
  private extensionShutdownInFlight = false;
  private extensionShutdownRetryTimer: NodeJS.Timeout | undefined;
  private readonly unregisterExtensionExpiry: () => void;
  private readonly unregisterProcessExpiry: () => void;
  public readonly processActivities = new Map<string, SessionProcessActivity>();
  public readonly processOperationIDs = new Map<string, string>();
  private readonly processIDsByToolCall = new Map<string, Set<string>>();
  private readonly pendingProcessRemovalsByToolCall = new Map<string, Set<string>>();
  public readonly childSessionAdmission = new ChildSessionAdmission({
    parentSessionFile: () => this.sessionManager.getSessionFile(),
    parentSessionId: () => this.id,
    isEmbeddedLifecycleArtifact,
  });
  private readonly childSessionBindings = new Map<string, { ref: string; producerId: string; sessionOwnerId?: string }>();
  private processRevision = 0;
  private processAsOf = new Date().toISOString();
  private readonly toolMetadata = new Map<string, ToolProjectionMetadata>();
  protected readonly bashMetadata = new Map<string, ToolProjectionMetadata>();
  private nextToolOrder = 0;
  private lastPublishedSummary: SessionSummaryUpdate | undefined;
  private latestDashboardActivityAt: string | undefined;
  private dashboardActiveSince: string | undefined;
  private summaryContentDirty = true;
  private cachedSummaryContent: {
    name?: string;
    updatedAt: string;
    messageCount: number;
    firstMessage: string;
  } | undefined;
  private summaryContentFold: {
    messageCount: number;
    firstMessage: string;
    updatedAt: string | undefined;
    entryCount: number;
    lastEntryId: string | undefined;
  } | undefined;
  private lastTouchedAt = Date.now();
  private readonly pendingInvocationUserMessages = new WeakMap<AgentMessage, {
    operationId: string;
    invocationId: string;
  }>();
  private pendingExtensionNotificationWrites = 0;
  private extensionCanonicalEffectFlushScheduled = false;
  private readonly pendingExtensionCanonicalEffects: PendingExtensionCanonicalEffect[] = [];
  private readonly pendingContextMessages: PendingContextMessage[] = [];
  public readonly inboxAttributedMessages = new Set<string>();
  private unregisterConfigurationWork: (() => void) | undefined;
  private publishedConfigurationBlocker: SessionConfigurationBlocker | null | undefined;
  public shuttingDown = false;
  private shutdownPromise: Promise<void> | undefined;
  private readonly settleWaiters = new Set<() => void>();
  public directBashProcesses: DirectBashProcessOwner | undefined;
  private explicitProfile: { sessionId: string; profile: SessionProfile } | undefined;
  public readonly canonicalAppendContext: CanonicalAppendContext;
  private homeWakeTrigger: { input: InputTrigger; operationId: string; appended?: () => void; binding?: Promise<void> } | undefined;
  private readonly runtimeProfiles = new WeakMap<AgentSession, SessionProfile>();

  private constructor(
    public sessionManager: SessionManager,
    public readonly dependencies: RuntimeSlotDependencies,
    public readonly hooks: RuntimeSlotHooks,
    interrupted: boolean,
    creationProfile: SessionProfile = ORDINARY_SESSION_PROFILE,
    homeMaterializationAuthority?: object,
    taskWorker?: HomeTaskReportOwner,
  ) {
    super();
    this.ownedTurns.worker = taskWorker;
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
    this.extensionHost = new RemotePiExtensionHost(this.ui);
    this.lifecycle = new ExtensionLifecycleCoordinator(this.ui.presentation, () => this.hasRuntimeWork());
    this.unregisterExtensionExpiry = dependencies.extensionActivityRecency.registerExpiryCallback((frame) => onExtensionActivityExpiry(this.ownedTurns, frame));
    this.unregisterProcessExpiry = dependencies.processActivityRecency.registerExpiryCallback((frame) => this.onProcessActivityExpiry(frame));
  }

  private installCanonicalWriteGuard(sessionManager: SessionManager): void {
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
        this.workerSettlement.publish("delivery");
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
    homeMaterializationAuthority?: object,
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

  async inspectTaskSettlement<T>(operationId: string, inspect: (settled: boolean) => Promise<T>): Promise<T> {
    return this.lane.run(() => {
      this.assertUsable();
      if (this.ownedTurns.worker?.identity.operationId !== operationId) throw new GatewayError("conflict", "Task operation changed before settlement");
      return inspect(!this.hasActiveAgentRun && !this.isAgentAdmissionSettling && this.operation === undefined);
    });
  }

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

  get projectDir(): string {
    return this.runtime.session.projectDir;
  }

  get modelRuntime(): ModelRuntime {
    this.assertNoTrustReload();
    return this.runtime.session.modelRuntime;
  }

  get isHomeChapter(): boolean {
    return this.liveProfile().chapter || this.dependencies.sessionLineage().state(this.id).lineageId !== undefined;
  }

  get usesHomeSettings(): boolean {
    return this.liveProfile().chapter;
  }

  private settingsToolSource() {
    const busy = (): never => { throw new GatewayError("busy", "This chat's own Session-scope settings change between runs, not during one"); };
    const read = () => this.settingsSessionLayer();
    return {
      ...this.settingsSource(),
      get session() { return read(); },
      appliers: {
        setModel: busy, setThinking: busy, setContextWindow: busy, setTools: busy,
        admit: (key: KeyDeclaration, layer: LayerId) => {
          if (layer === "session" && key.layers.session?.store === "session") {
            throw new GatewayError("busy", `${key.id} changes only between runs; this turn cannot request its own SDK configuration change`);
          }
        },
        setSetting: (key: string, value: unknown, allowFixedDirection: boolean, fixedAt?: FixedSetting) => this.persistChatRunSetting(key, value, allowFixedDirection, fixedAt),
      },
    };
  }

  private settingsToolAccess(): SettingsToolAccess | undefined {
    const owners = this.dependencies.settings();
    if (!owners) return undefined;
    const target = { kind: "session" as const, sessionId: this.id };
    const source = () => this.settingsToolSource();
    const chapter = (): NonNullable<ChangeContext["homeChapter"]> => ({ ...this.settingsSource(),
      get session() { return source().session; }, sessionId: this.id,
      mutate: operation => operation({ appliers: source().appliers }) });
    const actor = (toolCallId: string): Actor => {
      const profileActor = this.liveProfile().settingsActor;
      const kind = profileActor === "agent" && this.ownedTurns.worker ? "worker" : profileActor;
      return { kind, id: this.id, sessionId: this.id, toolCallId, ...(this.ownedTurns.worker ? { taskId: this.ownedTurns.worker.identity.taskId } : {}) };
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
            actor: actor(input.toolCallId), reason: input.reason, session: source(), ...(input.confirm ? { confirm: input.confirm } : {}),
            ...(this.usesHomeSettings ? { homeChapter: chapter() } : {}),
            ...(input.dryRun ? { dryRun: true } : {}),
          });
        }
        const { task, slot, target: workerTarget } = await worker(input.taskId, "change");
        const result = await owners.changes.change(workerTarget, changes, {
          actor: { kind: "home", id: this.id, sessionId: this.id, toolCallId: input.toolCallId, taskId: task.taskId },
          reason: input.reason, session: slot.taskWorkerSettingsSession(), ...(input.confirm ? { confirm: input.confirm } : {}),
          ...(input.dryRun ? { dryRun: true } : {}),
        });
        return { ...result, worker: { ...task, ...slot.taskWorkerSettingsState() } };
      },
    };
  }

  taskWorkerSettingsSession(): SessionSettingsSource & { appliers: SessionAppliers } {
    const read = () => {
      if (this.disposed) throw new GatewayError("not_found", "The worker runtime that owned this settings review has retired");
      return this.settingsSessionLayer();
    };
    return {
      ...this.settingsSource(),
      get session() { return read(); },
      appliers: {
        admit: (key, layer) => { if (layer === "session" && key.id === "tools.active") this.assertNoLiveTaskConfiguration("active tools"); },
        setModel: (ref, fixedAt) => this.setModel(ref.provider, ref.id, undefined, undefined, fixedAt),
        setThinking: (level, fixedAt) => this.setThinking(level as ThinkingLevel, undefined, undefined, fixedAt),
        setContextWindow: (model, value, fixedAt) => this.setContextWindow(model.provider, model.id, value, this.revision, this.runtimeGeneration, undefined, fixedAt),
        setTools: (tools, fixedAt) => this.setTools(tools, undefined, fixedAt),
        setSetting: (key, value, allowFixedDirection, fixedAt) => this.setChatRunSetting(key, value, undefined, undefined, allowFixedDirection, fixedAt),
        announce: (notice) => this.announceSettingsChange(notice),
      },
    };
  }

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

  async announceSettingsChange(notice: SettingsNotice): Promise<SettingsSignal | undefined> {
    const worker = this.ownedTurns.worker;
    if (!worker) return undefined;
    const taskId = worker.identity.taskId;
    if (!this.liveTaskConfiguration()) return { status: "not-running", taskId, appliesFrom: "next-run" };
    const by = notice.actor.kind === "home" ? "Tron Home" : notice.actor.kind === "ui" ? "The maintainer" : notice.actor.kind === "worker" ? "This worker" : "An agent";
    const when = (effect: string) => effect === "next-turn" || effect === "next-request" ? "from your next model request"
      : effect === "next-compaction" ? "at the next compaction" : `at its effect point (${effect})`;
    const text = [
      `[Tron settings] ${by} changed this session's settings while you work on task ${taskId}${notice.reason ? `. Reason: ${notice.reason}` : ""}.`,
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

  settingsSource(session: SessionStore = this.settingsSessionLayer()): SessionSettingsSource {
    return { cwd: this.cwd, home: this.usesHomeSettings, session, modelRuntime: this.runtime.session.modelRuntime };
  }

  settingsSessionLayer(): SessionStore {
    this.assertNoTrustReload();
    return this.readSettingsSessionLayer();
  }

  private readSettingsSessionLayer(): SessionStore {
    const session = this.runtime.session;
    const policy = this.contextPolicies.get(session)?.snapshot();
    const branch = session.sessionManager.getBranch();
    const fixed = readSessionFixedSettings(branch);
    const modelChoice = fixed["model.ref[role=chat]"];
    const choiceIndex = modelChoice ? branch.findIndex(entry => entry.type === "custom" && entry.customType === SESSION_SETTINGS_ENTRY
      && (entry.data as { fixed?: Record<string, { ref: string }> } | null)?.fixed?.["model.ref[role=chat]"]?.ref === modelChoice.ref) : -1;
    const choice = (key: string, runtime: unknown) => !fixed[key] ? runtime : fixed[key].from === "session" || fixed[key].from === "delegate" ? fixed[key].value : undefined;
    const model = this.dependencies.modules.policy("modelRuntimeInstalled")?.().modelChoice(branch, choiceIndex) ?? choice("model.ref[role=chat]",
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
    await applyModelAdmission(session, admission, Boolean(this.ownedTurns.worker) || this.liveProfile().modelSelection?.physicalOnly === true,
      owners.model.owner.admitModelChoice);
    if (this.runtime.session !== session) throw new GatewayError("conflict", "Runtime changed during model admission");
    this.applyHomeToolRecipe(session, this.liveProfile(), admission);
    session.settingsManager.applyOverrides(settings);
    session.agent.steeringMode = session.settingsManager.getSteeringMode();
    session.agent.followUpMode = session.settingsManager.getFollowUpMode();
    session.agent.transport = session.settingsManager.getTransport();
    session.agent.maxRetryDelayMs = session.settingsManager.getProviderRetrySettings().maxRetryDelayMs;
    return settings;
  }

  private applyHomeToolRecipe(session: AgentSession, profile: SessionProfile, rows: readonly { key: string; value: unknown }[]): void {
    if (profile.launchDefaults !== "settings-home-recipe") return;
    const tools = rows.find(row => row.key === "tools.active")?.value;
    if (Array.isArray(tools)) session.setActiveToolsByName(tools.filter((name): name is string => typeof name === "string" && profile.tools?.includes(name) === true));
  }

  private async persistChatRunSetting(key: string, value: unknown, allowFixedDirection: boolean, fixedAt?: FixedSetting): Promise<number> {
    this.assertChapterWritable();
    const branch = this.sessionManager.getBranch();
    const settings = changeSessionSetting(this.dependencies.settingsSchema, readSessionSettings(branch), key, value);
    const fixed = readSessionFixedSettings(branch);
    if (this.dependencies.settingsSchema.schemaKey(key).timing === "fixed") {
      fixed[key] = { ...(fixedAt ?? { from: "session", at: new Date().toISOString(), ref: randomUUID() }), value };
    }
    const requestPins = readSessionRequestPins(branch);
    if (typeof this.dependencies.settingsSchema.schemaKey(key).timing !== "string" && allowFixedDirection) {
      const owners = this.dependencies.settings();
      if (!owners) throw new GatewayError("conflict", "Settings owner is unavailable");
      const { requestPins: _pins, ...chat } = this.settingsSessionLayer();
      const resolved = await owners.model.resolve({ kind: "session", sessionId: this.id }, this.settingsSource({ ...chat, settings }), [key]);
      const row = resolved.keys[0];
      if (!row) throw new GatewayError("conflict", "Settings default is unavailable");
      requestPins[key] = { value: row.value, from: row.layer, at: new Date().toISOString(), ref: randomUUID(), ...(row.qualifiers ? { qualifiers: row.qualifiers } : {}) };
    }
    await this.persistSessionSettings({ settings, requestPins, fixed });
    if (hasCompactionApplier(this.dependencies.settingsSchema.schemaKey(key))) {
      try { this.compactionPolicies.get(this.runtime.session)?.refresh(); } catch { }
    }
    this.revision += 1;
    this.publishSnapshot();
    return this.revision;
  }

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
  async commitArchiveWhileIdle<T>(exceptWorkToken: string | undefined, commit: () => Promise<T>): Promise<T> {
    return this.lane.run(async () => {
      this.assertUsable();
      this.assertChapterWritable();
      this.assertArchivable(exceptWorkToken);
      return commit();
    });
  }

  assertArchivable(exceptWorkToken?: string): void {
    const blocker = this.archiveBlocker(exceptWorkToken);
    if (blocker === "transient") throw new GatewayError("busy", "Another request is using this session", true);
    if (blocker === "active") {
      throw new GatewayError("busy", "Stop the session before archiving it", false, undefined, "session_operation_busy");
    }
  }

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
    for (const activity of this.ownedTurns.extensionActivities.values()) {
      if (extensionActivityOwnsLiveWork(this.ownedTurns, activity)) {
        facts.push({
          category: "detached-extension-run",
          key: activity.activityId ?? activity.toolCallId,
          admittedAt: activity.startedAt,
          ...(activity.lastActivityAt ? { progressAt: activity.lastActivityAt } : {}),
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

  beginAdministrativeDrainCutoff(): void {
    this.lifecycle.beginDrain();
  }

  async prepareForAdministrativeDrain(): Promise<void> {
    this.beginAdministrativeDrainCutoff();
  }



  administrativeSuspectForegroundWorkTokens(): ReadonlySet<string> {
    return this.runWork.administrativeSuspectForegroundWorkTokens();
  }

  private hasRuntimeWork(exceptWorkToken?: string): boolean {
    return this.dependencies.workRegistry.hasSessionWork(this.id, exceptWorkToken)
      || this.hasDetachedDashboardWork();
  }

  public hasDetachedDashboardWork(): boolean {
    return this.ownedTurns.liveExtensionActivities().length > 0;
  }

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

  get catalogPhase(): SessionPhase {
    return this.dashboardPhase;
  }

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

  get catalogCreatedAt(): string {
    return this.createdAt;
  }

  get sessionFile(): string | undefined {
    return this.runtime.session.sessionFile;
  }

  get displayName(): string | undefined {
    return this.isHomeChapter ? "Home" : this.runtime.session.sessionName || undefined;
  }

  get canonicalEntryCount(): number {
    return this.runtime.session.sessionManager.getEntries().length;
  }

  get persistedSessionFile(): string | undefined {
    const path = this.runtime.session.sessionFile;
    return path && existsSync(path) ? path : undefined;
  }

  toolResultReferences(): ToolReferences {
    const manager = this.runtime.session.sessionManager;
    const leafID = manager.getLeafId();
    const key = `${manager.getSessionId()}\0${leafID ?? "root"}`;
    if (this.toolReferenceCut?.key !== key) {
      const branch = leafID ? manager.getBranch(leafID) : [];
      const value = this.dependencies.modules.policy("toolResultProjection")?.().references(branch, manager.getSessionId())
        ?? { artifacts: [], liveViews: new Set<string>() };
      this.toolReferenceCut = { key, value };
    }
    return this.toolReferenceCut.value;
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

  private profileFor(sessionManager: SessionManager): SessionProfile {
    const sessionId = sessionManager.getSessionId();
    const decision = this.dependencies.modules.policy("profileDecision")?.(sessionId, sessionManager.getCwd()) ?? "unrecorded";
    return decision === "unrecorded"
      ? this.explicitProfile?.sessionId === sessionId ? this.explicitProfile.profile : ORDINARY_SESSION_PROFILE
      : this.dependencies.modules.profile(decision);
  }

  public liveProfile(): SessionProfile {
    return this.runtimeProfiles.get(this.runtime.session) ?? ORDINARY_SESSION_PROFILE;
  }

  private runtimeFactory(): CreateAgentSessionRuntimeFactory {
    return async ({ cwd, sessionManager, sessionStartEvent }) => {
      this.installCanonicalWriteGuard(sessionManager);
      const trust = await this.dependencies.trust.requireResolved(cwd);
      const profile = this.profileFor(sessionManager);
      const binding = profile.modelRuntime === "gateway"
        ? await profile.acquireModelRuntime()
        : { runtime: await this.dependencies.createModelRuntime(), ownership: "owned" as const };
      const modelRuntime = binding.runtime;
      const requestPipeline = new RunRequestPipeline(modelRuntime);
      const modelRuntimePolicy = this.dependencies.modules.policy("modelRuntimeInstalled")?.();
      const detachOpenAIEligibility = binding.ownership === "owned"
        ? modelRuntimePolicy?.attach(modelRuntime)
        : undefined;
      this.detachOpenAIEligibility?.();
      this.detachOpenAIEligibility = detachOpenAIEligibility;
      let contextPolicy: ContextPolicy | undefined;
      let compactionPolicy: CompactionOperationPolicy | undefined;
      this.resourceReloadOptions = {
        resolveProjectTrust: profile.projectTrust === "never"
          ? async () => false
          : async () => (await this.dependencies.trust.inspect(trust.cwd)).effectiveDecision === true,
      };
      this.explicitProfile = undefined;
      const sessionContext: SessionContext = {
        sessionId: () => this.id,
        cwd: () => this.cwd,
        modelRuntime, profile: () => this.liveProfile(),
        fixedSettings: () => readSessionFixedSettings(this.sessionManager.getBranch()),
        delegatedWorker: () => Boolean(this.ownedTurns.worker),
        ...(profile.managedSubagents && this.dependencies.managedSubagents ? {
          requireChildExtensions: this.dependencies.managedSubagents.requireChildExtensions.bind(this.dependencies.managedSubagents),
        } : {}),
        title: () => this.notificationTitle(),
        presented: () => this.dependencies.isSessionPresented(this.id),
        contextPolicy: () => contextPolicy,
        compaction: {
          policy: () => compactionPolicy,
          stopped: (event) => (this.operation?.id !== undefined && this.runAbort.abortedOperations.has(this.operation.id))
            || (event.reason !== "manual" && this.activeOperationId !== undefined && this.runAbort.abortedOperations.has(this.activeOperationId)),
          changed: () => { this.revision += 1; this.publishSnapshot(); },
        },
        joinTerminalReceiptWrites: () => this.runInvocations.joinTerminalReceiptWrites(),
        settings: () => this.settingsToolAccess(),
        requestChange: input => this.requestChange(input),
      };
      const managedSubagents = profile.managedSubagents ? this.dependencies.managedSubagents : undefined;
      const settingsManager = await createSettingsManager(this.dependencies.settingsSchema, trust.projectDir, this.dependencies.agentDir, profile.projectSettings && trust.trusted,
        async manager => { if (this.runtime?.session.settingsManager === manager) await this.applyReloadSettings(manager); });
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
            ...this.dependencies.modules.registrations(this.dependencies.modules.runtimeOrder, sessionContext),
            ...(modelRuntimePolicy?.extensions(sessionContext,
              managedSubagents?.requireChildExtensions.bind(managedSubagents)) ?? []),
            ...(this.ownedTurns.worker ? [{ name: "tron-home-task-worker", factory: createHomeTaskWorkerExtension({
              providerVersion: toolName => delegatedProviderToolVersion(this.runtime?.session.resourceLoader.getExtensions().extensions ?? [], toolName),
              refused: reason => this.dependencies.homeTaskDiagnostic?.({ event: "home.task.producer-refused",
                taskHash: createHash("sha256").update(this.ownedTurns.worker!.identity.taskId).digest("hex").slice(0, 16), reason }),
              reportSealed: () => this.ownedTurns.worker!.reportSealed,
              ownsSubagentRun: runId => this.ownedTurns.ownsSubagentRun(runId),
              ownsSupervisorRequest: requestId => this.ownedTurns.ownsSupervisorRequest(requestId),
            }) }] : []),
          ];
      const services = await createAgentSessionServices({
        settingsManager: managedLoaderOptions?.settingsManager ?? managedProviderSettingsView(settingsManager),
        cwd: trust.cwd,
        projectDir: trust.projectDir,
        agentDir: this.dependencies.agentDir,
        modelRuntime,
        resourceLoaderOptions: {
          ...(managedLoaderOptions ?? {}),
          ...profile.resources,
          extensionFactories,
          extensionsOverride: (base) => this.dependencies.modules.policy("extensionAdmission")!(base,
            this.dependencies.modules.policy("toolResultProjection")?.().beginBrowserLoad(sessionManager.getSessionId(), this.runtimeGeneration),
            managedSubagents),
        },
        resourceLoaderReloadOptions: this.resourceReloadOptions,
      });
      services.settingsManager = settingsManager;
      await managedSubagents?.completeLoad(settingsManager, this.cwd, this.dependencies.agentDir, services.resourceLoader.getExtensions().extensions);
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
      const recordedThinking = sessionManager.getBranch().some(entry => entry.type === "thinking_level_change");
      const settingsOwner = this.dependencies.settings();
      const launchDefaults = settingsOwner && (startsNewChat || profile.launchDefaults === "settings-home-recipe") ? await settingsOwner.model.resolve(
        { kind: "session", sessionId: sessionManager.getSessionId() },
        { cwd: trust.cwd, home: profile.launchDefaults === "settings-home-recipe", session: { settings: {} }, modelRuntime },
        ["model.ref[role=chat]", "model.thinking[role=chat]", "tools.active"], { storeState: false },
      ) : undefined;
      const profileModel = launchDefaults?.keys.find(row => row.key === "model.ref[role=chat]" && (profile.launchDefaults === "settings-home-recipe" || row.layer === "session"))?.value as { provider: string; id: string } | undefined;
      const selectedProfileModel = profile.launchDefaults === "settings-home-recipe" && profileModel
        ? modelRuntime.getPhysicalModel(profileModel.provider, profileModel.id) : undefined;
      if (profileModel && profile.launchDefaults === "settings-home-recipe" && !selectedProfileModel) throw new GatewayError("conflict", "Home's configured profile model is unavailable or virtual");
      const launchThinking = launchDefaults?.keys.find(row => row.key === "model.thinking[role=chat]")?.value as ThinkingLevel | undefined;
      const created = await createAgentSessionFromServices({
        services,
        sessionManager,
        ...(initialModel ? { model: initialModel } : {}),
        ...(sessionStartEvent ? { sessionStartEvent } : {}),
        ...(selectedProfileModel ? { model: selectedProfileModel } : {}),
        ...(profile.launchDefaults === "settings-home-recipe" && launchThinking ? { thinkingLevel: launchThinking }
          : recordedThinking ? { thinkingLevel: sessionManager.buildSessionContext().thinkingLevel as ThinkingLevel }
          : launchThinking ? { thinkingLevel: launchThinking } : {}),
        ...(profile.tools ? { tools: [...profile.tools] } : {}),
        ...(directBashProcesses ? { customTools: [
          directBashProcesses.toolDefinition(trust.cwd) as unknown as ToolDefinition,
          ...(this.ownedTurns.worker ? [this.ownedTurns.worker.checkinTool(() => this.id, () => this.activeOperationId && !this.runAbort.abortedOperations.has(this.activeOperationId) ? this.ownedTurns.taskTurnOperationId(this.activeOperationId) : undefined), this.ownedTurns.worker.tool(() => this.id, () => this.activeOperationId && !this.runAbort.abortedOperations.has(this.activeOperationId) ? this.ownedTurns.taskTurnOperationId(this.activeOperationId) : undefined,
            async report => {
              await this.ownedTurns.reconcileLiveExtensionArtifacts();
              const live = this.ownedTurns.liveSubagentRuns().length;
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
      if (profile.launchDefaults === "settings-home-recipe") {
        this.applyHomeToolRecipe(created.session, profile, launchDefaults?.keys ?? []);
      } else {
        const toolChoice = readSessionToolChoice(sessionManager.getBranch());
        if (toolChoice && toolChoice.fixed?.from !== "project") created.session.setActiveToolsByName(toolChoice.tools);
      }
      this.runtimeProfiles.set(created.session, profile);
      this.homeRequestPolicy = profile.requestPolicy
        ? this.dependencies.modules.policy("requestPolicy")?.().forSession(sessionManager.getSessionId())
        : undefined;
      const homeRequestPolicy = this.homeRequestPolicy;
      const compactionSession = created.session;
      compactionPolicy = new CompactionOperationPolicy(compactionSession, this.dependencies.agentDir, compactionAdmission.bind(undefined, this.dependencies.settingsSchema),
        profile.compaction === "disabled" ? { disabled: true } : { session: () => readSessionSettings(compactionSession.sessionManager.getBranch()) });
      const taskWorker = this.ownedTurns.worker;
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
        ...(this.dependencies.requestRecord ? { record: outcome => this.dependencies.requestRecord?.({ sessionId: this.id, kind: taskWorker ? "worker" : profile.name, ...outcome }) } : {}),
        ...(homeRequestPolicy ? {
          policyStream: baseStream => homeRequestPolicy.wrapStreamFunction(baseStream),
          outer: {
            transformContext: (transformContext, convertToLlm) => homeRequestPolicy.wrapTransformContext(transformContext, convertToLlm),
            prepareRequest: (prepareRequest) => {
              const prepare = homeRequestPolicy.wrapPrepareRequest(created.session, prepareRequest);
              return async (request, signal) => {
                await this.homeWakeTrigger?.binding;
                return (await prepare(request, signal)) ?? undefined;
              };
            },
          },
        } : {}),
        ...(taskWorker ? {
          policyStream: baseStream => (model, context, options) => baseStream(model, context,
            model.provider === "anthropic" ? { ...options, cacheRetention: "long" } : options),
          finishTurn: workerFinishTurn(this, created, taskWorker),
        } : {}),
      });
      this.compactionPolicies.set(created.session, compactionPolicy);
      contextPolicy = modelRuntimePolicy?.contextPolicy(created.session);
      if (contextPolicy) this.contextPolicies.set(created.session, contextPolicy);
      return { ...created, services, diagnostics: services.diagnostics };
    };
  }

  private async initialize(): Promise<void> {
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

  async reloadSettingInputs(): Promise<Array<[string, unknown]>> {
    const owners = this.dependencies.settings();
    if (!owners) return [];
    const keys = this.dependencies.settingsSchema.KEYS.filter(key => key.effect === "reload").map(key => key.id);
    const source = this.reloadSettingsSource();
    const resolved = await owners.model.resolve({ kind: "session", sessionId: this.id }, source, keys, { storeState: false });
    return resolved.keys.map(row => [row.key, row.value]);
  }

  private async applyReloadSettings(manager: SettingsManager): Promise<void> {
    const overrides: Record<string, unknown> = {};
    for (const [id, value] of await this.reloadSettingInputs()) {
      const key = this.dependencies.settingsSchema.schemaKey(id);
      const binding = key.layers.global;
      if (binding?.store === "pi" && value !== undefined) setPath(overrides, binding.path, value);
    }
    manager.applyOverrides(overrides);
  }

  private reloadSettingsSource(): SessionSettingsSource {
    const session = this.readSettingsSessionLayer();
    const fixed = Object.fromEntries(Object.entries(session.fixed ?? {}).filter(([key, value]) =>
      this.dependencies.settingsSchema.schemaKey(key).effect !== "reload" || value.from === "session" || value.from === "delegate"));
    return this.settingsSource({ ...session, fixed });
  }

  private async refreshReloadDefaults(): Promise<void> {
    const owners = this.dependencies.settings();
    if (!owners) return;
    const fixed = readSessionFixedSettings(this.sessionManager.getBranch());
    const keys = Object.keys(fixed).filter(key => this.dependencies.settingsSchema.schemaKey(key).effect === "reload"
      && fixed[key]!.from !== "session" && fixed[key]!.from !== "delegate");
    if (!keys.length) return;
    const resolved = await owners.model.resolve({ kind: "session", sessionId: this.id }, this.reloadSettingsSource(), keys, { storeState: false });
    let changed = false;
    for (const row of resolved.keys) {
      if (JSON.stringify(fixed[row.key]!.value) === JSON.stringify(row.value) && fixed[row.key]!.from === row.layer) continue;
      fixed[row.key] = { value: row.value, from: row.layer, at: new Date().toISOString(), ref: randomUUID(), ...(row.qualifiers ? { qualifiers: row.qualifiers } : {}) };
      changed = true;
    }
    if (changed) await this.persistSessionSettings({ fixed });
  }

  private async captureFixedDefaults(): Promise<void> {
    const owners = this.dependencies.settings();
    if (!owners) return;
    const session = this.runtime.session;
    const keys = this.dependencies.settingsSchema.KEYS.filter(key => key.timing === "fixed" && (key.layers.session?.store === "session" || key.layers.session?.store === "session-settings"));
    const defaults = await owners.model.resolve({ kind: "session", sessionId: this.id }, this.settingsSource({ settings: {} }), keys.map(key => key.id));
    const actual = this.settingsSessionLayer();
    const policy = this.contextPolicies.get(session);
    const context = policy?.snapshot();
    const fixed: Record<string, FixedSetting> = {};
    for (const row of defaults.keys) {
      const binding = this.dependencies.settingsSchema.schemaKey(row.key).layers.session;
      if (binding?.store !== "session" && binding?.store !== "session-settings") continue;
      const value = binding.store === "session-settings" ? row.value
        : binding.field === "contextWindow" ? context?.effective : actual[binding.field];
      if (value === undefined) continue;
      const from = binding.store === "session" && binding.field === "model" && row.value !== undefined && JSON.stringify(value) !== JSON.stringify(row.value)
        ? "session" : row.layer;
      fixed[row.key] = { value, from, at: new Date().toISOString(), ref: randomUUID(), ...(row.qualifiers ? { qualifiers: row.qualifiers } : {}) };
    }
    if (context && session.model) policy!.set({ provider: session.model.provider, id: session.model.id }, context.effective);
    await this.persistSessionSettings({ fixed });
  }

  private async persistSessionSettings(entry: { settings?: Record<string, unknown>; requestPins?: Record<string, FixedSetting>; fixed?: Record<string, FixedSetting> }): Promise<void> {
    const branch = this.sessionManager.getBranch(), receiptId = randomUUID();
    await this.persistCanonicalCustomEntry(SESSION_SETTINGS_ENTRY, safeJson({ receiptId, settings: entry.settings ?? readSessionSettings(branch),
      requestPins: entry.requestPins ?? readSessionRequestPins(branch), fixed: entry.fixed ?? readSessionFixedSettings(branch) }), receiptId);
  }

  async setHomeTaskModelQueues(queues: import("../settings/tool-contract.js").TaskModelQueues): Promise<void> {
    return this.lane.run(async () => {
      this.assertConfigurationIdle();
      if (!this.ownedTurns.worker) throw new GatewayError("invalid_request", "Only an admitted Home task owns task queue launch inputs");
      const fixed = readSessionFixedSettings(this.sessionManager.getBranch());
      for (const role of ["worker", "subagent"] as const) {
        const key = `model.queue[role=${role}]`;
        const value = await this.dependencies.settingsSchema.schemaKey(key).type.validate(queues[role], key);
        fixed[key] = { value, from: "delegate", at: new Date().toISOString(), ref: randomUUID(),
          via: "home-profile", reason: "Resolved at task launch; later Home profile changes do not retarget this worker" };
      }
      await this.persistSessionSettings({ fixed });
    });
  }

  protected async recordFixedSetting(key: string, value: unknown, origin?: FixedSetting): Promise<void> {
    const fixed = readSessionFixedSettings(this.sessionManager.getBranch());
    fixed[key] = { ...(origin ?? { from: "session", at: new Date().toISOString(), ref: randomUUID() }), value };
    await this.persistSessionSettings({ fixed });
  }

  resourceProjectTrusted(): Promise<boolean> { return this.effectiveResourceReloadOptions()!.resolveProjectTrust(); }

  private effectiveResourceReloadOptions(): { resolveProjectTrust: () => Promise<boolean> } | undefined {
    const override = this.projectTrustReloadOverride;
    return override === undefined || this.liveProfile().projectTrust === "never"
      ? this.resourceReloadOptions
      : { resolveProjectTrust: async () => override };
  }

  private assertAutomationMayNotReplaceSession(): void {
    if (this.ownedTurns.worker || currentInvocationContext()?.operationId?.startsWith("automation:")) {
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
        const result = await this.navigateTreeWithSettings(targetId, options);
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
    this.extensionHost.retire();
    this.ui.retire(reason);
    this.ui = this.createSemanticBroker();
    this.extensionHost = new RemotePiExtensionHost(this.ui);
    this.lifecycle.replaceActivity(this.ui.presentation);
    this.runtime.session.extensionRunner.setUIContext(this.extensionHost.context(), "rpc");
  }

  private async reloadBoundSession(): Promise<void> {
    const session = this.runtime.session;
    await this.refreshReloadDefaults();
    await session.resourceLoader.reload(this.effectiveResourceReloadOptions());
    if (this.liveProfile().managedSubagents) {
      await this.dependencies.managedSubagents?.completeLoad(session.settingsManager, this.cwd, this.dependencies.agentDir, session.resourceLoader.getExtensions().extensions);
    }
    await session.reload({ beforeSessionStart: () => this.rotateSemanticHost() });
  }

  private installRuntimeHooks(): void {
    bindRuntimeSession(this.runtime, {
      beforeInvalidate: () => {
        this.runInvocations.handOffReplacedCommand();
        this.dependencies.modules.observers("sessionRetired").forEach(retire => { try { retire(this.id); } catch { } });
      },
      rebind: async () => this.bindSession(),
    });
  }

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
    if (this.ownedTurns.worker || this.canonicalTaskEvidence().some(entry => entry.type === "custom" && entry.customType === HOME_TASK_MARKER)) {
      throw new GatewayError("conflict", "Task worker session identity cannot be replaced");
    }
    const lineage = this.dependencies.sessionLineage();
    if (lineage.state(this.id).lineageId || this.liveProfile().chapter) {
      throw lineage.identityRefusal(this.id);
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
            this.ownedTurns.resetArtifactBranch();
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
    hydrateCanonicalExtensionActivities(this.ownedTurns);
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

  async replaceRuntime(sessionManager: SessionManager = this.sessionManager): Promise<void> {
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

  public replaceProcessesForToolCall(toolCallId: string, projected: readonly SessionProcessActivity[]): void {
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

  public syncSubagentProcesses(activity: ExtensionRunActivity): void {
    const pausedSettledAt = pausedProcessSettlementAt(this.ownedTurns, activity);
    const candidates = subagentProcessesFromActivity(
      this.id,
      activity,
      pausedSettledAt === undefined ? {} : { pausedSettledAt },
    );
    const bindings = new Map(candidates.flatMap(process => {
      const binding = this.childSessionBindingFromActivity(process.processId, activity);
      return binding ? [[process.processId, binding] as const] : [];
    }));
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

  public activitySource(): activityProjection.ActivitySource {
    const slot = this;
    return {
      get processActivities() { return slot.processActivities; },
      get dependencies() { return slot.dependencies; },
      get extensionActivities() { return slot.ownedTurns.extensionActivities; },
      get processRevision() { return slot.processRevision; },
      get processAsOf() { return slot.processAsOf; },
      measureToolDuration: (...args) => slot.measureToolDuration(...args),
      get liveActivityRevision() { return slot.ownedTurns.liveActivityRevision; },
      get extensionActivityAsOf() { return slot.ownedTurns.extensionActivityAsOf; },
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

  public publishProcessesForToolCall(toolCallId: string): void {
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

  private armProgressFlushTimer(): void {
    this.progressFlushTimer = setTimeout(() => {
      this.progressFlushTimer = undefined;
      if (this.flushPendingProgress()) this.armProgressFlushTimer();
    }, STREAMING_PROGRESS_FLUSH_MS);
    this.progressFlushTimer.unref();
  }

  private flushPendingProgress(): boolean {
    const message = this.pendingProgressMessage;
    this.pendingProgressMessage = undefined;
    if (!message || message.role !== "assistant") return false;
    this.captureStreamIdentity(message);
    if (!this.streamPresentationId || !this.streamStartedAt) return false;
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
    if (projected && message.content.some(part => part.type === "text" && part.text.length > 0)) {
      this.homeRequestPolicy?.responseTiming.visible(this.activeOperationId);
    }
    return true;
  }

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
    if (this.dependencies.sessionAudience(this.id) > 0) {
      this.emit("session.progress", safeJson({ message: boundStreamingProgressItem(projected) }));
      if (message.content.some(part => part.type === "text" && part.text.length > 0)) {
        this.homeRequestPolicy?.responseTiming.visible(this.activeOperationId);
      }
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

  public pendingBackgroundProcesses(): string[] {
    return [...this.ownedTurns.extensionActivities.values()]
      .filter((activity) => extensionActivityOwnsLiveWork(this.ownedTurns, activity)
        && ["asynchronous", "workflow"].includes(activity.mode?.toLowerCase() ?? ""))
      .map((activity) => `${activity.toolCallId}:${activity.runId ?? activity.activityId ?? activity.id}`)
      .sort();
  }

  public notificationTitle(): string {
    if (this.isHomeChapter) return "Home";
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

  private isInboxAttributed(message: AgentMessage): boolean {
    const eventId = (message as { details?: { eventId?: unknown } }).details?.eventId;
    return typeof eventId === "string" && this.inboxAttributedMessages.has(eventId);
  }

  public persistVerifiedCustomEntry(options: {
    manager: SessionManager;
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
    const before = sessionFileLength(options.manager.getSessionFile());
    try {
      options.append();
    } catch (error) {
      if (this.dependencies.modules.policy("appendGuard")?.(this.canonicalAppendContext).isPreAppendRefusal(error)) throw error;
      if (options.existing() !== "matching" && before !== undefined
        && before === sessionFileLength(options.manager.getSessionFile())) throw error;
      throw asUncertainOutcome(error, `The ${options.describe} could not be proven persisted; refresh session state before retrying`);
    }
  }

  public persistCanonicalCustomEntry(
    customType: string,
    data: JsonValue,
    identity: string,
    owner?: GatewayWorkHandle,
  ): Promise<void> {
    const manager = this.sessionManager;
    return this.runPersistence.trackOwnershipWrite(
      () => this.runPersistence.retryDurableWrite(`canonical:${customType}:${identity}`, async () => {
        this.persistVerifiedCustomEntry({
          manager,
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
    return this.runPersistence.trackOwnershipWrite(
      () => this.runPersistence.retryDurableWrite(`marker:mark:${operationId}`, () => this.dependencies.markers.mark(this.id, operationId)),
      this.runWork.get(operationId),
    );
  }

  public async clearMarkerOwnership(operationId?: string, existingOwner?: GatewayWorkHandle): Promise<void> {
    const key = operationId ?? "all";
    if (operationId) await this.runPersistence.durableWrites.get(`marker:mark:${operationId}`)?.waiter;
    const sessionId = this.id;
    return this.runPersistence.trackOwnershipWrite(
      () => this.runPersistence.retryDurableWrite(`marker:clear:${key}`, () => this.dependencies.markers.clear(sessionId, operationId)),
      existingOwner ?? (operationId ? this.runWork.get(operationId) : undefined),
    );
  }


  public resetToolExecutionProjection(): void {
    for (const state of this.toolExecutions.values()) {
      if (state.status === "running") this.recordCapabilityUsage(state.toolName, "unknown", undefined);
    }
    this.toolExecutions.clear();
    this.toolInvocationGroups.clear();
    this.toolStartedAtMonotonicMs.clear();
    this.nextToolOrder = 0;
  }

  private recordCapabilityUsage(name: string, status: "ok" | "error" | "refused" | "unknown", duration: number | undefined): void {
    const registered = this.runtime.session.getAllTools().some(tool => tool.name === name);
    this.dependencies.capabilityDiagnostic?.({
      name: registered && /^[A-Za-z][A-Za-z0-9_]{0,127}$/.test(name) ? name : "unknown", count: 1,
      status: registered ? status : "unknown",
      latencyBucket: duration === undefined || !Number.isFinite(duration) ? "unknown"
        : duration < 100 ? "lt100ms" : duration < 1_000 ? "lt1s" : duration < 10_000 ? "lt10s" : "gte10s",
    });
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
            this.publishSnapshot();
          }
        } else if (event.message.role === "user") {
          this.flushPendingProgress();
          const precedingToolSegmentId = this.activeToolSegmentId();
          this.ownToolSegment(this.activeOperationId);
          if (this.pendingPrompt && this.pendingPromptMessage === undefined) {
            this.pendingPromptMessage = event.message;
            this.runAbort.consumeStopSteeringRecoveryOwner(this.pendingPrompt.id);
          } else {
            const dequeuedSteeringOperationID = this.runQueue.dequeuedSteeringOwners.shift();
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
            this.publishSnapshot();
          }
        } else if (event.message.role === "custom" && this.isInboxAttributed(event.message)) {
          this.flushPendingProgress();
        } else if (event.message.role === "custom") {
          this.flushPendingProgress();
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
        this.homeRequestPolicy?.responseTiming.tool(this.activeOperationId, event.toolCallId, true);
        if ("parentToolCallId" in event && event.parentToolCallId) {
          updateNestedExtensionActivity(this.ownedTurns, event, "running");
          this.projectNestedToolExecution(event, "running");
          break;
        }
        if (this.canonicalToolResultHandoffs.has(event.toolCallId)) break;
        this.runAttention.ensureAgentProjection();
        const now = new Date().toISOString();
        const existing = this.toolExecutions.get(event.toolCallId);
        if (!existing) {
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
        const extensionActivity = updateExtensionActivity(this.ownedTurns,
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
          updateNestedExtensionActivity(this.ownedTurns, event, "running", event.partialResult);
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
        const extensionActivity = updateExtensionActivity(this.ownedTurns,
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
        this.homeRequestPolicy?.responseTiming.tool(this.activeOperationId, event.toolCallId, false);
        const duration = event.durationMs;
        this.recordCapabilityUsage(event.toolName, duration === undefined ? "refused" : event.isError ? "error" : "ok", duration);
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
          updateNestedExtensionActivity(this.ownedTurns, event, event.isError ? "failed" : "completed", event.result);
          this.projectNestedToolExecution(event, event.isError ? "failed" : "completed");
          break;
        }
        this.runAttention.ensureAgentProjection();
        const now = new Date().toISOString();
        const existing = this.toolExecutions.get(event.toolCallId);
        const retained = this.toolMetadata.get(event.toolCallId);
        const startedAt = existing?.startedAt ?? retained?.startedAt ?? now;
        const canonicalOwned = this.isCanonicalToolResultOwned(event.toolCallId);
        const hasMonotonicStart = this.toolStartedAtMonotonicMs.has(event.toolCallId);
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
        const extensionActivity = updateExtensionActivity(this.ownedTurns,
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
        this.noteCanonicalEntriesCommitted();
        if (event.entry.type === "message" && event.entry.message.role === "toolResult") {
          this.markCanonicalToolResultHandoff(event.entry.message.toolCallId);
          if (event.entry.message.toolName === "display") this.reconcileCanonicalDisplayArtifacts();
        }
        this.emit("session.structureChanged", { branchChanged: false });
        this.scheduleSnapshot();
        break;
      case "message_end":
        this.summaryContentDirty = true;
        this.scheduleSnapshot();
        this.noteCanonicalEntriesCommitted();
        if (event.message.role === "toolResult") {
          this.observeCanonicalToolResultHandoff(event.message);
        } else if (event.message.role === "assistant") {
          this.finalizeToolInvocationGroups(event.message);
          this.bindCanonicalPresentation(event.message);
        } else if (event.message.role === "custom" && this.isInboxAttributed(event.message)) {
          const trigger = this.homeWakeTrigger;
          if (trigger && (event.message.details as { eventId?: unknown } | undefined)?.eventId === trigger.input.message.details.eventId) {
            trigger.appended?.();
            const binding = this.bindHomeWakeTrigger(trigger.input, trigger.operationId);
            if (trigger.input.message.details.trigger) {
              trigger.binding = binding;
              void binding.catch(error => this.emit("session.diagnostic", safeJson({ code: "home-trigger-binding-failed", message: error instanceof Error ? error.message : String(error) })));
            }
          }
        } else if (event.message.role === "custom") {
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
          void this.lane.run(async () => {
            const candidate = this.sessionManager.getBranch().find((entry) =>
              entry.type === "message" && entry.message.role === "user" && entry.message === message);
            if (!candidate || candidate.type !== "message") return;
            this.rememberPresentationID(candidate.id, operationID);
            const isConsumedSteering = this.runQueue.consumedSteeringOperationIDs.has(operationID);
            const observationOwnerId = isConsumedSteering ? this.activeOperationId ?? operationID : operationID;
            if (isConsumedSteering || !this.runTerminal.operationObservations.get(observationOwnerId)?.cursor) {
              const canonical = this.canonicalSessionEntries();
              const entryIndex = canonical.findIndex(entry => entry.id === candidate.id);
              if (entryIndex >= 0) this.runTerminal.observationFor(observationOwnerId).cursor = { entryIndex };
            }
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
      case "turn_start":
      case "turn_end":
      case "bash_execution_update":
        break;
      default: {
        event satisfies never;
        break;
      }
    }
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
    this.noteDashboardActivity();
    this.publishSummary();
  }

  public stopActivityHeartbeat(): void {
    if (this.activityHeartbeat) clearInterval(this.activityHeartbeat);
    this.activityHeartbeat = undefined;
  }

  public toolLabel(toolName: string): string | undefined {
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

  public extensionToolOrigin(toolName: string): ExtensionToolOrigin | undefined {
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
    return canonicalToolResultCallIDs(this.runtime.session.sessionManager).has(toolCallId);
  }

  private noteCanonicalEntriesCommitted(): void {
    if (!this.liveProfile().chapter) return;
    queueMicrotask(() => { this.dependencies.modules.policy("appendGuard")?.(this.canonicalAppendContext).committed(); });
  }

  private observeCanonicalToolResultHandoff(
    message: Extract<AgentMessage, { role: "toolResult" }>,
  ): void {
    queueMicrotask(() => {
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

  async reconcileToolResultOwnership(): Promise<void> {
    const manager = this.runtime.session.sessionManager;
    await this.dependencies.modules.policy("toolResultProjection")?.().reconcile(manager.getEntries(), this.id);
  }

  private reconcileCanonicalDisplayArtifacts(): void {
    void this.reconcileToolResultOwnership().catch((error) => {
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
      get extensionActivities() { return slot.ownedTurns.extensionActivities; },
      extensionActivityVisibility: activity => activityProjection.extensionActivityVisibility(slot.activitySource(), activity),
      extensionActivityWire: activity => activityProjection.extensionActivityWire(slot.activitySource(), activity),
      get liveActivityRevision() { return slot.ownedTurns.liveActivityRevision; },
      get extensionActivityAsOf() { return slot.ownedTurns.extensionActivityAsOf; },
    }, sequence);
  }

  transcriptPageAfter(after: number, expectedPreviousEntryId?: string, expectedRuntimeGeneration?: string, expectedLeafEntryId?: string): TranscriptPage {
    return sessionPages.transcriptPageAfter(this.pageSource(), after, expectedPreviousEntryId, expectedRuntimeGeneration, expectedLeafEntryId);
  }

  transcriptPage(before?: number, expectedNextEntryId?: string, expectedRuntimeGeneration?: string, expectedLeafEntryId?: string, branchCut?: import("../pi/coding-agent.js").SessionEntry[]): TranscriptPage {
    return sessionPages.transcriptPage(this.pageSource(), before, expectedNextEntryId, expectedRuntimeGeneration, expectedLeafEntryId, branchCut);
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
    };
  }

  updateToolExtensionActivityProjection(toolCallId: string, activity: ExtensionRunActivity): void {
    const tool = this.toolExecutions.get(toolCallId);
    if (tool) this.toolExecutions.set(toolCallId, { ...tool, extensionActivity: activity });
  }

  private processForViewer(processId: string): SessionProcessActivity | undefined {
    return this.processActivities.get(processId)
      ?? processHistoryDetail(this.runtime.session.sessionManager, processId);
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

  publishSnapshot(): void {
    this.releaseSettleWaiters();
    if (this.disposed || this.trustReloadPending) return;
    if (this.snapshotTimer) {
      clearTimeout(this.snapshotTimer);
      this.snapshotTimer = undefined;
    }
    this.publishStateChange();
    this.flushPendingProgress();
    this.eventSequence += 1;
    this.runAttention.ensureAgentProjection();
    if (this.dependencies.sessionAudience(this.id) > 0) {
      this.hooks.broadcast(this.id, "session.snapshot", this.snapshot(this.eventSequence) as unknown as JsonValue);
    }
    this.publishSummary();
  }

  public publishSummary(): void {
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

  async admitHomeWake(inputCancellation: RequestPolicy["inputCancellation"], cancellationEpoch: number): Promise<{ delivered: boolean }> {
    let delivered = false;
    await this.prompt("", [], undefined, undefined, undefined, {
      kind: "homeWake", inputCancellation, cancellationEpoch, operationId: randomUUID(), origin: { kind: "gateway", ownerId: "home", title: "Home", confidence: "boundary" },
      onDelivered: (value) => { delivered = value; },
    });
    return { delivered };
  }

  public async assertHomeWakeAdmissible(session: AgentSession): Promise<void> {
    if ((this.phase !== "idle" && this.phase !== "interrupted") || this.operation !== undefined || this.activeOperationId !== undefined
      || this.heldQueue.entries.length > 0 || this.manualCompaction.pendingManualCompaction !== undefined || this.compactionOperation !== undefined
      || this.isAgentAdmissionSettling || session.isStreaming) {
      throw new GatewayError("busy", "Tron Home is busy; finished results wait for its next idle moment", true);
    }
    const model = session.model;
    if (!model) throw new GatewayError("conflict", "Tron Home has no model to wake with", false, { reason: "model-unavailable" });
    if (!this.modelRuntime.hasConfiguredAuth(model.provider) && (await this.modelRuntime.checkAuth(model.provider)) === undefined) {
      throw new GatewayError("conflict", "Tron Home has no usable credential to wake with", false, { reason: "auth-unavailable" });
    }
  }

  public startHomeWake(session: AgentSession, operationId: string, trigger: InputTrigger | undefined,
    accept: (accepted: boolean) => void, inputCancellation: RequestPolicy["inputCancellation"], cancellationEpoch: number, delivered?: (value: boolean) => void): Promise<void> {
    const appended = trigger ? () => { delivered?.(true); accept(true); } : undefined;
    if (!appended) accept(true);
    return trigger ? this.sendHomeWake(session, operationId, trigger, inputCancellation, cancellationEpoch, appended) : Promise.resolve();
  }

  private async sendHomeWake(session: AgentSession, operationId: string, trigger: InputTrigger, inputCancellation: RequestPolicy["inputCancellation"], cancellationEpoch: number, appended?: () => void): Promise<void> {
    const eventId = trigger.message.details.eventId;
    this.inboxAttributedMessages.add(eventId);
    this.homeWakeTrigger = { input: trigger, operationId, ...(appended ? { appended } : {}) };
    try {
      if (this.runAbort.inputCancellation !== inputCancellation || inputCancellation.epoch !== cancellationEpoch) {
        throw new GatewayError("cancelled", "Home wake stopped before delivery");
      }
      await session.sendCustomMessage(trigger.message, { triggerTurn: true });
      if (!this.hasCanonicalCustomMessage(eventId)) throw new GatewayError("conflict", "Home wake trigger was not persisted");
    } catch (error) {
      if (!this.hasCanonicalCustomMessage(eventId)) await this.dependencies.modules.policy("inputAdmission")?.().release(trigger.taskId ?? trigger.message.details.trigger!.eventId, operationId, eventId);
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

  private bindHomeWakeTrigger(trigger: InputTrigger, operationId: string): Promise<void> {
    return this.lane.run(async () => {
      const candidate = this.sessionManager.getBranch().find(entry => entry.type === "custom_message"
        && (entry.details as { eventId?: unknown } | undefined)?.eventId === trigger.message.details.eventId);
      if (!candidate) throw new Error("canonical Home wake trigger is unavailable");
      const invocation = this.runInvocations.invocationForOperation(operationId);
      if (!invocation) throw new Error("canonical invocation start receipt is unavailable");
      await this.persistCanonicalCustomEntry(
        INVOCATION_RECEIPT_TYPE,
        receiptJSON(makeInvocationReceipt({
          version: 1,
          receiptId: `binding:${invocation.invocationId}`,
          receiptKind: "binding",
          invocationId: invocation.invocationId,
          operationId,
          sessionId: this.id,
          source: "homeWake",
          canonicalEntryId: candidate.id,
          sequence: this.revision + 1,
          createdAt: new Date().toISOString(),
        })),
        `binding:${invocation.invocationId}`,
        this.runWork.get(operationId),
      );
      const settings = candidate.type === "custom_message" && candidate.customType === SETTINGS_OUTCOME_MESSAGE;
      const source = settings ? "gateway:settings" : "gateway:home-task";
      await this.persistCanonicalCustomEntry(CONTEXT_DELIVERY_RECEIPT_TYPE,
        safeJson(makeContextDeliveryReceipt(candidate.id, "stored", inputMessageOrigin(trigger.message) ?? { source,
          owner: { id: trigger.taskId!, title: settings ? "Settings" : "Home task", source } })), candidate.id);
      if (trigger.deliveryMessage) {
        const input = this.sessionManager.getBranch().find(entry => entry.type === "custom_message"
          && (entry.details as { eventId?: unknown } | undefined)?.eventId === trigger.deliveryMessage!.details.eventId);
        if (!input) throw new Error("canonical resumed Home input is unavailable");
        await this.persistCanonicalCustomEntry(CONTEXT_DELIVERY_RECEIPT_TYPE,
          safeJson(makeContextDeliveryReceipt(input.id, "stored", inputMessageOrigin(trigger.deliveryMessage)!)), input.id);
      }
      await this.dependencies.modules.policy("inputAdmission")?.().committed?.(this.id, operationId);
    });
  }

  public noteHomeIdle(): void {
    if (this.phase !== "idle" || this.operation !== undefined || this.activeOperationId !== undefined) return;
    this.hooks.idle?.(this);
    if (this.homeRequestPolicy) this.dependencies.modules.policy("runSettled")?.().idle(this.id, this.operationWasHomeWake ? "wake" : "user");
  }

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
      if (this.lifecycle.isDraining) await this.ownedTurns.releaseWaitingTaskForDrain();
    }
  };

  public persistTaskMarker(operationId: string): Promise<void> {
    return this.persistCanonicalCustomEntry(HOME_TASK_MARKER,
      JSON.parse(JSON.stringify({ version: 1, receiptId: `task:${operationId}`, ...this.ownedTurns.worker!.identity, sessionId: this.id })), `task:${operationId}`);
  }

  public noteAcceptedSteering(operationId: string): void {
      if (this.ownedTurns.worker && operationId !== this.ownedTurns.worker.identity.operationId) {
        this.dependencies.homeTaskDiagnostic?.({ event: "home.task.control",
          taskHash: createHash("sha256").update(this.ownedTurns.worker.identity.taskId).digest("hex").slice(0, 16),
          operationHash: createHash("sha256").update(this.ownedTurns.worker.identity.operationId).digest("hex").slice(0, 16),
          action: "steer", disposition: "accepted" });
      }
  }

  refreshArchiveProjection(): void {
    this.revision += 1;
    this.publishSnapshot();
  }

  refreshCompactionPolicy(): void {
    try { this.compactionPolicies.get(this.runtime.session)?.refresh(); } catch { }
    this.revision += 1;
    this.publishSnapshot();
  }

  public resourceExpansionCatalog(): ResourceExpansionCatalog {
    const session = this.runtime.session;
    return { skills: session.resourceLoader.getSkills().skills, promptTemplates: session.promptTemplates };
  }

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
          setSetting: (key, value, _allowFixedDirection, fixedAt) => this.persistChatRunSetting(key, value, true, fixedAt),
        } });
      }),
    };
  }

  protected async changeHomeRecipe(key: string, value: unknown, initiatingWorkToken?: string): Promise<number> {
    const result = await this.dependencies.settings()!.changes.change({ kind: "home" }, [{ key, layer: "session", op: "set", value }],
      { actor: { kind: "ui", id: "tron-home" }, commandId: randomUUID(), homeChapter: this.homeSettingsChapter(initiatingWorkToken) });
    if (result.status !== "applied") throw new GatewayError("invalid_request", "This Home choice requires the exact native change card; nothing changed");
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

  private async navigateTreeWithSettings(targetId: string, options: Parameters<AgentSession["navigateTree"]>[1]) {
    const session = this.runtime.session;
    const inputCancellation = this.runAbort.inputCancellation;
    const cancellationEpoch = inputCancellation.epoch;
    const owners = this.dependencies.settings();
    if (options?.summarize && owners) {
      const resolved = await owners.model.resolve({ kind: "session", sessionId: this.id }, this.settingsSource(), ["context.branchSummary.reserveTokens"], { storeState: false });
      if (this.runtime.session !== session) throw new GatewayError("conflict", "Runtime changed during branch-summary settings resolution");
      if (this.runAbort.inputCancellation !== inputCancellation || inputCancellation.epoch !== cancellationEpoch) throw new GatewayError("cancelled", "Branch summarization was stopped during settings resolution");
      const reserveTokens = resolved.keys[0]?.value;
      if (typeof reserveTokens !== "number") throw new GatewayError("conflict", "Branch-summary reserve is unavailable");
      session.settingsManager.applyOverrides({ branchSummary: { reserveTokens } });
    }
    return session.navigateTree(targetId, options);
  }

  async navigate(
    targetId: string,
    options: { summarize: boolean; instructions?: string; replaceInstructions?: boolean; label?: string },
    initiatingWorkToken?: string,
  ): Promise<{ editorText?: string }> {
    return this.lane.run(async () => {
      this.assertIdle(false, initiatingWorkToken);
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
        const result = await this.navigateTreeWithSettings(targetId, {
          summarize: options.summarize,
          ...(options.instructions ? { customInstructions: options.instructions } : {}),
          ...(options.replaceInstructions === undefined ? {} : { replaceInstructions: options.replaceInstructions }),
          ...(options.label ? { label: options.label } : {}),
        });
        if (result.cancelled) throw new GatewayError("cancelled", "Tree navigation was cancelled by an extension");
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
      systemPrompt: session.systemPrompt,
      instructions: this.agentInstructions(this.dependencies.modules.policy("operatingContext")!(workspace, this.cwd, session.getActiveToolNames())),
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
      preview: session.isIdle,
      prompt: session.systemPrompt,
      tronContext: turnContext,
      ...(customPrompt ? { customPrompt: { text: customPrompt, ...(loader.getSystemPromptSource() ? { path: loader.getSystemPromptSource()!.path } : {}) } } : {}),
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

  readonly requestChange: import("../host/native-change.js").NativeChangeRequest = input => {
    this.assertNoTrustReload();
    return this.ui.requestChange(input);
  };

  respondToInteraction(id: string, hostEpoch: string, presentationRevision: number, value: unknown, cancelled: boolean, acceptance?: import("../../protocol/types.js").NativeChangeAcceptance): void | Promise<void> {
    this.assertNoTrustReload();
    return this.ui.respond(id, hostEpoch, presentationRevision, value, cancelled, acceptance);
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

  async abortTrustReload(): Promise<void> {
    this.shuttingDown = true;
    await this.lane.run(async () => {
      this.trustReloadWork?.settle();
      this.trustReloadWork = undefined;
      this.projectTrustReloadOverride = undefined;
      this.trustReloadPending = false;
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

  async retireAfterSettled(): Promise<void> {
    const deadline = performance.now() + DEFAULT_OWNERSHIP_WRITE_RETRY_WINDOW_MS;
    for (;;) {
      await this.lane.run(() => {});
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

  async disposeIf(shouldDispose: () => boolean, exceptWorkToken?: string): Promise<boolean> {
    if (this.disposed) return false;
    return this.lane.run(async () => {
      if (this.disposed) return false;
      this.runPersistence.assertOwnershipPersistence();
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

    this.runtime.session.abortCompaction();
    this.runtime.session.abortRetry();
    this.runtime.session.abortBranchSummary();
    this.runtime.session.abortBash();
    await Promise.all([
      this.runtime.session.abort(),
      this.directBashProcesses?.abortAll() ?? Promise.resolve(),
    ]);
    await this.runPersistence.waitForReceiptWrites();
    this.ui.cancelAll("Gateway shutdown interrupted extension interaction");

    await this.lane.run(async () => {
      this.manualCompaction.finishShutdown(cancellation);
      if (interruptedSource) {
        await this.runInvocations.terminalizeInvocation(interruptedOperationId, "outcomeUnknown", "runtime-disposed");
        await this.runTerminal.notifyAgentTerminal(interruptedSource, "interrupted");
      }
      await this.disposeRuntime();
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
    this.shuttingDown = true;
    this.resetToolExecutionProjection();
    this.homeRequestPolicy?.responseTiming.retire();
    this.runAbort.cancelPreparations();
    this.runTerminal.operationObservations.clear();
    this.detachOpenAIEligibility?.();
    this.detachOpenAIEligibility = undefined;
    this.dependencies.modules.observers("sessionRetired").forEach(retire => { try { retire(this.id); } catch { } });
    this.unregisterExtensionExpiry();
    this.unregisterProcessExpiry();
    for (const activity of this.ownedTurns.extensionActivities.values()) {
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
    this.ownedTurns.retireArtifactWatches();
    this.unsubscribe?.();
    this.ui.cancelAll();
    for (const operationId of [...this.ownedTurns.observers.keys()]) {
      const invocation = this.runInvocations.invocationForOperation(operationId);
      if (invocation) {
        await this.runInvocations.terminalizeInvocation(operationId, "outcomeUnknown", "runtime-disposed");
      } else {
        await this.ownedTurns.notifyOwnedTerminal({
          lifecycle: "outcomeUnknown",
          operationId,
          invocationId: operationId,
          errorCode: "runtime-disposed",
        });
      }
    }
    await this.disposeAgentRuntime();
    await this.flushPendingExtensionCanonicalEffects();
    await this.runPersistence.waitForReceiptWrites();
    this.extensionHost.retire();
    this.heldQueue.reset();
    this.runWork.settleAll();
    this.lifecycle.retire();
    this.ui.retire();
    this.unregisterConfigurationWork?.();
    this.unregisterConfigurationWork = undefined;
    this.disposed = true;
    if (this.published) this.dependencies.resources?.recordRuntimeEvicted();
    this.publishStateChange();
  }

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

    try { this.dependencies.runtimeDisposalTimedOut?.(graceMs); } catch { }
    this.runtime.session.dispose();
    void disposal.catch(() => {});
  }

  public assertNoTrustReload(): void {
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
    this.emit("session.configuration", { configurationBlocker });
    this.publishedConfigurationBlocker = configurationBlocker;
  }



  assertChapterWritable(manager: SessionManager = this.sessionManager): void {
    this.dependencies.modules.policy("appendGuard")?.(this.canonicalAppendContext).assertWritable(manager);
  }

  public assertHomePromptAdmission(): void {
    this.dependencies.modules.policy("appendGuard")?.(this.canonicalAppendContext).admission();
  }

  private assertProfileChangeIdle(): void {
    this.assertUsable();
    if (this.isRunningWork()) {
      throw new GatewayError("busy", "Tron Home's session is running; retry when it is idle", true);
    }
  }

}

function sessionFileLength(path: string | undefined): number | "absent" | undefined {
  if (!path) return "absent";
  try {
    const stats = statSync(path);
    return stats.isFile() ? stats.size : undefined;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "ENOENT" ? "absent" : undefined;
  }
}
