import type { SettingsManager, FileEntry, AgentSessionRuntime, AgentSession, SessionManager } from "../pi/coding-agent.js";
import { HOME_TASK_MARKER, HOME_TASK_REPORT } from "../delegation/task-report.js";
import type { ChatOrigin, ChatSemanticMetadata, CommandInfo, JsonValue } from "../../protocol/types.js";
import type { InputTrigger } from "../host/input-admission.js";
import type { TrustService } from "../resources/trust-service.js";
import type { ExtensionLifecycleCoordinator } from "../host/extension-lifecycle-coordinator.js";
import type { CanonicalAppendContext } from "../host/canonical-append.js";
import type { ResourceExpansionCatalog } from "../../sessions/resource-invocation.js";
import type { CanonicalAssistantCompletion } from "./completion-facts.js";
import type { CommandReplacement } from "./run-invocations.js";
import type { CompactionOperationPolicy } from "./compaction-policy.js";
import type { RequestPolicy } from "../host/request-policy.js";
import type { ContextPolicy, ModuleHost } from "../host/module-host.js";
import type { SessionProfile } from "../host/session-profile.js";
import type { GatewayWorkRegistry } from "./gateway-work-registry.js";
import type { DirectBashProcessOwner } from "./direct-bash-process-owner.js";
import type { ToolProjectionMetadata } from "../projection/projection.js";
import type { GatewayWorkHandle } from "./gateway-work-registry.js";
import type { RunMarkerStore } from "./run-markers.js";

import type { ToolReferences } from "../projection/tool-result.js";

/** Native frame and canonical readers, not copied runtime state. FixedAt is an opaque settings
 * provenance token: interpreted only by the concrete settings persistence owner. */
export abstract class RunRuntime<FixedAt> {
  abstract readonly cwd: string;
  abstract readonly sessionFile: string | undefined;
  abstract readonly canonicalEntryCount: number;
  abstract toolResultReferences(): ToolReferences;
  abstract readonly inboxAttributedMessages: Set<string>;
  abstract assertHomePromptAdmission(): void;
  abstract assertHomeWakeAdmissible(session: AgentSession): Promise<void>;
  abstract persistTaskMarker(id: string): Promise<void>;
  abstract noteAcceptedSteering(id: string): void;
  abstract applyLiveRunSettings(session: AgentSession): Promise<ReturnType<SettingsManager["getSettings"]> | undefined>;
  abstract extensionCommandOrigin(name: string): ChatOrigin;
  abstract startHomeWake(session: AgentSession, id: string, trigger: InputTrigger | undefined, accepted: (value: boolean) => void, inputCancellation: RequestPolicy["inputCancellation"], cancellationEpoch: number): Promise<void>;
  abstract maybePerformExtensionShutdown(): void;
  abstract enqueueMarkerOwnership(id: string): Promise<void>;
  abstract readonly lifecycle: ExtensionLifecycleCoordinator;
  abstract readonly canonicalAppendContext: CanonicalAppendContext;
  abstract readonly disposed: boolean;
  abstract readonly trustReloadPending: boolean;
  abstract drainBusyExcept(exceptWorkToken?: string): boolean;
  abstract assertAvailable(): void;
  abstract internalWakeSemantic(id: string): ChatSemanticMetadata | undefined;
  abstract commands(): CommandInfo[];
  abstract resourceExpansionCatalog(): ResourceExpansionCatalog;
  abstract waitForStateChange(): Promise<void>;
  abstract readonly hooks: {
    settled(id: string): void;
    assistantResponseCompleted(id: string, completion: CanonicalAssistantCompletion, recovery: boolean, observed: boolean): Promise<void>;
  };
  abstract readonly taskWorker?: {
    readonly identity: { readonly taskId: string; readonly operationId: string };
    readonly acceptsSteering: boolean;
    readonly reportSealed: boolean;
    readonly controlsActive: boolean;
    stop(): Promise<void>;
  } | undefined;
  abstract readonly commandReplacement: CommandReplacement | undefined;
  abstract readonly compactionPolicies: WeakMap<AgentSession, CompactionOperationPolicy>;
  abstract readonly homeRequestPolicy: RequestPolicy | undefined;
  abstract readonly shuttingDown: boolean;
  abstract readonly hasActiveAgentRun: boolean;
  abstract readonly activeExports: number;
  abstract readonly activeToolSegmentOwnerId: string | undefined;
  abstract assertUsable(allowTrustReload?: boolean): void;
  abstract assertSessionIdentityReplacement(): void;
  abstract ownToolSegment(id: string | undefined): void;
  abstract readonly toolSegmentAwaitsAssistantOwner: boolean;
  abstract prepareAssistantOwnedToolSegment(): void;
  abstract rememberPresentationID(canonicalID: string, presentationID: string): void;
  abstract clearToolProgressTimers(): void;
  abstract scheduleSnapshot(): void;
  abstract resetToolExecutionProjection(): void;
  abstract resetStreamingProjection(): void;
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

  /** Read-only owner seam for bounded derived projections; callers never
   * mutate. Branch-sensitive consumers must use the SDK-selected branch, not
   * the file-wide entry set (which also contains sibling fork history). */
  canonicalSessionEntries(): FileEntry[] {
    const header = this.sessionManager.getHeader();
    return header ? [header, ...this.sessionManager.getBranch()] : [];
  }

  abstract publishConfiguration(): void;
  abstract releaseSettleWaiters(): void;
  abstract noteHomeIdle(): void;
  abstract pendingBackgroundProcesses(): string[];
  abstract notificationTitle(): string;
  abstract hasDetachedDashboardWork(): boolean;
  abstract persistCanonicalCustomEntry(type: string, data: JsonValue, identity: string, work?: GatewayWorkHandle): Promise<void>;
  abstract readonly id: string;
  abstract readonly usesHomeSettings: boolean;
  abstract readonly runtime: AgentSessionRuntime;
  abstract readonly sessionManager: SessionManager;
  protected abstract readonly runtimeGeneration: string;
  abstract readonly lane: { run<T>(operation: () => T | Promise<T>): Promise<T> };
  abstract readonly ui: { readonly hostEpoch: string };
  abstract readonly dependencies: {
    trust: Pick<TrustService, "requireResolved">;
    settings(): unknown;
    beforeRunAdmission(id: string): Promise<void>;
    workRegistry: GatewayWorkRegistry;
    markers: RunMarkerStore;
    modules: ModuleHost;
    isSessionPresented(id: string): boolean;
    compactionDiagnostic?: (diagnostic: { sessionId: string; operationId?: string; reason: "manual" | "threshold" | "overflow"; outcome: "success" | "failure" | "cancelled"; errorMessage?: string }) => void;
    persistenceDiagnostic?: (id: string, code: string) => void;
    stopSteeringDiagnostic?: (event: {
      sessionId: string;
      queuedSteerCount: number;
      outcome: "started" | "completed" | "failed" | "stopped" | "unknown";
    }) => void;
    manualCompactionAdopted?: (event: {
      sessionId: string;
      operationId: string;
      reason: "manual" | "threshold" | "overflow";
    }) => void;
  };
  abstract readonly contextPolicies: WeakMap<AgentSession, ContextPolicy>;
  abstract readonly directBashProcesses: DirectBashProcessOwner | undefined;
  abstract readonly activityHeartbeat: unknown;
  protected abstract readonly bashMetadata: Map<string, ToolProjectionMetadata>;
  protected abstract assertChapterWritable(): void;
  abstract liveProfile(): SessionProfile;
  protected abstract changeHomeRecipe(key: string, value: unknown, work?: string): Promise<number>;
  protected abstract recordFixedSetting(key: string, value: unknown, origin?: FixedAt): Promise<void>;
  abstract publishSnapshot(): void;
  abstract emit(topic: string, data: JsonValue): void;
  abstract noteDashboardActivity(at?: string): void;
  abstract startActivityHeartbeat(): void;
  abstract stopActivityHeartbeat(): void;
  abstract hasCurrentDashboardWork(): boolean;
  abstract clearMarkerOwnership(id?: string, work?: GatewayWorkHandle): Promise<void>;
  protected abstract rememberProjectionMetadata(store: Map<string, ToolProjectionMetadata>, id: string, metadata: ToolProjectionMetadata): void;
}
