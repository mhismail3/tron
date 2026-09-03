import type { ResourceInvocation } from "../protocol/types.js";

export const AUTOMATIONS_CAPABILITY = "automations.v2";
export const AUTOMATIONS_TIMELINE_CAPABILITY = "automations.timeline.v1";

export type AutomationActivation = "draft" | "enabled" | "paused" | "completed" | "blocked";
export type AutomationMisfirePolicy = "latest" | "skip";
export type AutomationOverlapPolicy = "skip" | "queueLatest";

export type AutomationTrigger =
  | { kind: "once"; at: string }
  | { kind: "interval"; everySeconds: number; anchorAt: string }
  | { kind: "calendar"; timezone: string; localTime: string; weekdays: readonly number[] };

export type AutomationTarget =
  | { kind: "existingSession"; sessionId: string }
  | { kind: "workspace"; cwd: string; sessionPolicy: "newPerRun" };

export type AutomationAction =
  | { kind: "sessionPrompt"; text: string; resourceInvocation?: ResourceInvocation }
  | { kind: "notification"; message: string };

export type AutomationProvenance =
  | { kind: "mobile" | "local" }
  | { kind: "assistant"; sessionId: string; sourceId: string };

export type AutomationRunState =
  | "queued"
  | "waiting"
  | "admitting"
  | "running"
  | "cancelling"
  | "succeeded"
  | "failed"
  | "cancelled"
  | "skipped"
  | "outcomeUnknown";

export const terminalAutomationRunStates = new Set<AutomationRunState>([
  "succeeded", "failed", "cancelled", "skipped", "outcomeUnknown",
]);

export interface AutomationRunResolution {
  outcome: "succeeded" | "failed" | "cancelled";
  resolvedAt: string;
  provenance: AutomationProvenance;
}

export interface AutomationRun {
  runId: string;
  occurrenceId: string;
  manual?: true;
  automationRevision: number;
  scheduledFor: string;
  triggerSnapshot: AutomationTrigger;
  actionSnapshot: AutomationAction;
  targetSnapshot: AutomationTarget;
  executionSessionId: string;
  state: AutomationRunState;
  createdAt: string;
  reason?: string;
  claimedAt?: string;
  startedAt?: string;
  terminalAt?: string;
  retryAt?: string;
  preAdmissionAttemptCount: number;
  hostEpoch?: string;
  claimId?: string;
  operationId?: string;
  invocationId?: string;
  assistantCompletionId?: string;
  notificationAdmissionStatus?: "queued" | "suppressed" | "rate_limited" | "unavailable";
  error?: { code: string; message: string; retryable: boolean };
  resolution?: AutomationRunResolution;
}

export interface AutomationRecord {
  schemaVersion: 2;
  id: string;
  /** User-visible definition revision used for optimistic mutation fencing. */
  revision: number;
  /** Every durable state transition advances this projection revision. */
  stateRevision: number;
  name: string;
  description?: string;
  activation: AutomationActivation;
  createdAt: string;
  updatedAt: string;
  provenance: AutomationProvenance;
  target: AutomationTarget;
  trigger: AutomationTrigger;
  misfirePolicy: AutomationMisfirePolicy;
  overlapPolicy: AutomationOverlapPolicy;
  executionDeadlineSeconds: number;
  action: AutomationAction;
  nextOccurrenceAt?: string;
  currentRun?: AutomationRun;
  queuedLatestOccurrence?: string;
  lastRun?: AutomationRun;
  consecutiveFailureCount: number;
  blockedReason?: string;
  history: AutomationRun[];
}

export type AutomationRunSummary = Pick<AutomationRun,
  "runId" | "state" | "scheduledFor" | "createdAt" | "startedAt" | "terminalAt" | "reason" | "preAdmissionAttemptCount" | "notificationAdmissionStatus"
>;

export interface AutomationSummary {
  id: string;
  revision: number;
  stateRevision: number;
  name: string;
  activation: AutomationActivation;
  actionKind: AutomationAction["kind"];
  target: AutomationTarget;
  trigger: AutomationTrigger;
  nextOccurrenceAt?: string;
  currentRun?: Pick<AutomationRun, "runId" | "state" | "scheduledFor" | "startedAt" | "reason">;
  lastRun?: Pick<AutomationRun, "runId" | "state" | "scheduledFor" | "terminalAt" | "reason">;
  consecutiveFailureCount: number;
  blockedReason?: string;
  createdAt: string;
  updatedAt: string;
}

export interface AutomationCreateInput {
  name: string;
  description?: string;
  activation?: "draft" | "enabled";
  target: AutomationTarget;
  trigger: AutomationTrigger;
  misfirePolicy?: AutomationMisfirePolicy;
  overlapPolicy?: AutomationOverlapPolicy;
  executionDeadlineSeconds?: number;
  action: AutomationAction;
  provenance: AutomationProvenance;
}

export interface AutomationUpdateInput {
  name: string;
  description?: string;
  target: AutomationTarget;
  trigger: AutomationTrigger;
  misfirePolicy: AutomationMisfirePolicy;
  overlapPolicy: AutomationOverlapPolicy;
  executionDeadlineSeconds: number;
  action: AutomationAction;
}

export function isTerminalAutomationRun(run: AutomationRun | undefined): boolean {
  return run !== undefined && terminalAutomationRunStates.has(run.state);
}
