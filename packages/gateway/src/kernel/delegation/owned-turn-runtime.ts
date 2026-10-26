import type { ExtensionRunActivity, ExtensionToolOrigin, SessionProcessActivity, ToolExecutionState, JsonValue } from "../../protocol/types.js";
import type { FileEntry, SessionManager, AgentSession } from "../pi/coding-agent.js";
import type { ChildSessionAdmission } from "./child-session-admission.js";
import type { WorkerSettlement } from "./worker-settlement.js";
import type { ActivitySource } from "../projection/activity.js";
import type { ExtensionActivityRecency } from "../../sessions/extension-activity-recency.js";
import type { ExtensionArtifactRejectionReason } from "../projection/extension-run-projection.js";

/** An existing native work handle, not another work registry or receipt owner. */
export interface ArtifactReceiptOwner {
  readonly token: string;
  readonly settled: Promise<void>;
  progress(): void;
  markSuspect(): void;
  settle(): void;
}

/** Same physical native frame, never a copied context or callback binding bag.
 * K5 owns run/artifact policy and mutable state; native lane, canonical I/O,
 * SDK, work registry and publication retain their original identity/lifetime. */
export interface OwnedTurnRuntime {
  readonly activeOperationId: string | undefined;
  readonly operation: { readonly id?: string } | undefined;
  readonly sessionManager: Pick<SessionManager, "getBranch">;
  readonly id: string;
  readonly cwd: string;
  readonly sessionFile: string | undefined;
  readonly disposed: boolean;
  readonly lane: { run<T>(operation: () => T | Promise<T>): Promise<T> };
  readonly runtime: { readonly session: AgentSession };
  readonly dependencies: {
    readonly workRegistry: {
      sessionWorkKinds(sessionId: string, exceptWorkToken?: string): readonly string[];
      begin(input: { kind: "administrative-provider-package-operation"; sessionId: string; hostEpoch: string }): { settle(): void };
      beginDerived(input: { kind: "terminal-receipt-persistence"; sessionId: string; hostEpoch: string }): ArtifactReceiptOwner;
    };
    sessionLineage(): { state(sessionId: string): { lineageId?: string | undefined } };
    readonly delegatedArtifactRoot?: string;
    readonly extensionActivityRecency: Pick<ExtensionActivityRecency, "upsert" | "remove" | "visibility">;
    readonly extensionArtifactWarning?: (warning: { reason: ExtensionArtifactRejectionReason; owner: string }) => void;
  };
  readonly runAttention: {
    readonly completionOwnershipQueue: readonly unknown[];
    readonly attentionBarrier: unknown;
    drainCompletionOwnership(): Promise<void>;
  };
  readonly runWork: { reconcileOrphanedForegroundWorkForDrain(): Promise<void> };
  readonly runPersistence: {
    trackOwnershipWrite(start: () => Promise<void>, owner?: ArtifactReceiptOwner): Promise<void>;
    retryDurableWrite(key: string, operation: () => Promise<void>): Promise<void>;
  };
  readonly ui: { readonly hostEpoch: string };
  readonly catalogHasActiveSubagents: boolean;
  readonly isAgentAdmissionSettling: boolean;
  readonly processOperationIDs: ReadonlyMap<string, string>;
  readonly processActivities: ReadonlyMap<string, SessionProcessActivity>;
  readonly childSessionAdmission: ChildSessionAdmission;
  readonly toolExecutions: ReadonlyMap<string, ToolExecutionState>;
  updateToolExtensionActivityProjection(toolCallId: string, activity: ExtensionRunActivity): void;
  readonly workerSettlement: WorkerSettlement;
  readonly activityHeartbeat: unknown;
  revision: number;
  assertUsable(): void;
  assertChapterWritable(): void;
  assertNoTrustReload(): void;
  administrativeDrainBlockers(): readonly { readonly category: string }[];
  liveProfile(): { readonly chapter: boolean };
  canonicalTaskEvidence(): FileEntry[];
  replaceRuntime(): Promise<void>;
  emit(topic: string, data: JsonValue): void;
  publishSnapshot(): void;
  hasDetachedDashboardWork(): boolean;
  abort(kind: "agent", operationId: string, reason?: string): Promise<void>;
  extensionToolOrigin(name: string): ExtensionToolOrigin | undefined;
  processChildSessionBinding(id: string): { ref: string; producerId: string; sessionOwnerId?: string; runId?: string } | undefined;
  syncSubagentProcesses(activity: ExtensionRunActivity): void;
  replaceProcessesForToolCall(id: string, processes: readonly SessionProcessActivity[]): void;
  activitySource(): ActivitySource;
  publishProcessesForToolCall(id: string): void;
  persistVerifiedCustomEntry(options: { describe: string; existing: () => "absent" | "matching" | "contradictory"; append: () => void }): void;
  scheduleSnapshot(): void;
  toolLabel(name: string): string | undefined;
  noteDashboardActivity(at?: string): void;
  startActivityHeartbeat(): void;
  publishSummary(): void;
  hasCurrentDashboardWork(): boolean;
  stopActivityHeartbeat(): void;
}
