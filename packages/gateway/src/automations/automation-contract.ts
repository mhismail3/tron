import { GatewayError } from "../errors.js";
import { admitPromptText, admitResourceInvocation } from "../sessions/resource-invocation.js";
import { isGatewayTimestamp } from "../util/timestamp.js";
import type {
  AutomationAction,
  AutomationCreateInput,
  AutomationProvenance,
  AutomationRecord,
  AutomationRun,
  AutomationTrigger,
  AutomationUpdateInput,
} from "./types.js";

export const MAXIMUM_AUTOMATIONS = 1_024;
export const MAXIMUM_AUTOMATION_RECORD_BYTES = 512 * 1_024;
export const MAXIMUM_AUTOMATION_AGGREGATE_BYTES = 128 * 1_048_576;
export const MAXIMUM_AUTOMATION_HISTORY = 64;
export const MINIMUM_AUTOMATION_INTERVAL_SECONDS = 60;
export const MINIMUM_AUTOMATION_DEADLINE_SECONDS = 5 * 60;
export const MAXIMUM_AUTOMATION_DEADLINE_SECONDS = 24 * 60 * 60;
export const DEFAULT_AUTOMATION_DEADLINE_SECONDS = 60 * 60;
export const AUTOMATION_FAILURE_CIRCUIT_LIMIT = 3;

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;
const automationOperation = /^automation:([0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})$/iu;
const occurrenceId = /^[A-Za-z0-9_-]{43}$/u;

function exactKeys(value: Record<string, unknown>, expected: readonly string[]): boolean {
  const keys = Object.keys(value);
  return keys.length === expected.length && keys.every((key) => expected.includes(key));
}

function record(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown> : undefined;
}

function bounded(value: unknown, maximumBytes: number, allowEmpty = false): value is string {
  return typeof value === "string" && (allowEmpty || value.length > 0)
    && Buffer.byteLength(value) <= maximumBytes && !/[\u0000]/u.test(value);
}

function timestamp(value: unknown): value is string {
  return typeof value === "string" && isGatewayTimestamp(value);
}

export function automationOperationId(runId: string): string {
  if (!uuid.test(runId)) throw new Error("Automation run identity is invalid");
  return `automation:${runId}`;
}

export function runIdFromAutomationOperationId(value: string): string | undefined {
  return automationOperation.exec(value)?.[1];
}

export function validateAutomationTimezone(value: string): boolean {
  if (!bounded(value, 128)) return false;
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: value }).format(0);
    return true;
  } catch {
    return false;
  }
}

export function admitsAutomationTrigger(value: unknown): value is AutomationTrigger {
  const input = record(value);
  if (!input || typeof input.kind !== "string") return false;
  if (input.kind === "once") {
    return exactKeys(input, ["kind", "at"]) && timestamp(input.at);
  }
  if (input.kind === "interval") {
    return exactKeys(input, ["kind", "everySeconds", "anchorAt"])
      && Number.isSafeInteger(input.everySeconds)
      && (input.everySeconds as number) >= MINIMUM_AUTOMATION_INTERVAL_SECONDS
      && (input.everySeconds as number) <= 365 * 24 * 60 * 60
      && timestamp(input.anchorAt);
  }
  if (input.kind === "calendar") {
    return exactKeys(input, ["kind", "timezone", "localTime", "weekdays"])
      && typeof input.timezone === "string" && validateAutomationTimezone(input.timezone)
      && typeof input.localTime === "string" && /^(?:[01]\d|2[0-3]):[0-5]\d$/u.test(input.localTime)
      && Array.isArray(input.weekdays) && input.weekdays.length > 0 && input.weekdays.length <= 7
      && input.weekdays.every((day) => Number.isSafeInteger(day) && day >= 1 && day <= 7)
      && new Set(input.weekdays).size === input.weekdays.length;
  }
  return false;
}

export function admitsAutomationAction(value: unknown): value is AutomationAction {
  const input = record(value);
  if (!input || typeof input.kind !== "string") return false;
  if (input.kind === "sessionPrompt") {
    const expected = input.resourceInvocation === undefined
      ? ["kind", "text"] : ["kind", "text", "resourceInvocation"];
    if (!exactKeys(input, expected) || !bounded(input.text, 64 * 1_024)) return false;
    try {
      admitPromptText(input.text);
      if (input.resourceInvocation !== undefined) {
        const invocation = admitResourceInvocation(input.resourceInvocation);
        if (invocation.source === "extension" || invocation.arguments !== input.text) return false;
      }
      return true;
    } catch {
      return false;
    }
  }
  return input.kind === "notification" && exactKeys(input, ["kind", "message"])
    && bounded(input.message, 512);
}

export function admitsAutomationProvenance(value: unknown): value is AutomationProvenance {
  const input = record(value);
  if (!input || typeof input.kind !== "string") return false;
  if (input.kind === "mobile" || input.kind === "local") return exactKeys(input, ["kind"]);
  return input.kind === "assistant" && exactKeys(input, ["kind", "sessionId", "sourceId"])
    && bounded(input.sessionId, 200) && bounded(input.sourceId, 256);
}

function admitsRunError(value: unknown): boolean {
  const input = record(value);
  return !!input && exactKeys(input, ["code", "message", "retryable"])
    && bounded(input.code, 128) && bounded(input.message, 1_024)
    && typeof input.retryable === "boolean";
}

export function admitsAutomationRun(value: unknown): value is AutomationRun {
  const input = record(value);
  if (!input) return false;
  const optional = ["reason", "claimedAt", "startedAt", "terminalAt", "retryAt", "hostEpoch", "claimId",
    "operationId", "invocationId", "assistantCompletionId", "notificationAdmissionStatus", "error", "resolution"];
  const required = ["runId", "occurrenceId", "automationRevision", "scheduledFor", "triggerSnapshot",
    "actionSnapshot", "state", "createdAt", "preAdmissionAttemptCount"];
  const keys = Object.keys(input);
  if (keys.length < required.length || !keys.every((key) => required.includes(key) || optional.includes(key))
    || !required.every((key) => keys.includes(key))) return false;
  if (!bounded(input.runId, 64) || !uuid.test(input.runId)
    || !bounded(input.occurrenceId, 64) || !occurrenceId.test(input.occurrenceId)
    || !Number.isSafeInteger(input.automationRevision) || (input.automationRevision as number) < 1
    || !timestamp(input.scheduledFor) || !timestamp(input.createdAt)
    || !admitsAutomationTrigger(input.triggerSnapshot) || !admitsAutomationAction(input.actionSnapshot)
    || !["queued", "waiting", "admitting", "running", "cancelling", "succeeded", "failed", "cancelled", "skipped", "outcomeUnknown"].includes(input.state as string)
    || !Number.isSafeInteger(input.preAdmissionAttemptCount) || (input.preAdmissionAttemptCount as number) < 0
    || (input.reason !== undefined && !bounded(input.reason, 256))) return false;
  for (const key of ["claimedAt", "startedAt", "terminalAt", "retryAt"] as const) {
    if (input[key] !== undefined && !timestamp(input[key])) return false;
  }
  if (input.hostEpoch !== undefined && !bounded(input.hostEpoch, 256)) return false;
  if (input.claimId !== undefined && (!bounded(input.claimId, 64) || !uuid.test(input.claimId))) return false;
  if (input.operationId !== undefined && (!bounded(input.operationId, 128) || automationOperation.exec(input.operationId) === null)) return false;
  if (input.invocationId !== undefined && !bounded(input.invocationId, 256)) return false;
  if (input.assistantCompletionId !== undefined && !bounded(input.assistantCompletionId, 256)) return false;
  if (input.notificationAdmissionStatus !== undefined
    && !["queued", "suppressed", "rate_limited", "unavailable"].includes(input.notificationAdmissionStatus as string)) return false;
  if (input.error !== undefined && !admitsRunError(input.error)) return false;
  if (input.resolution !== undefined) {
    const resolution = record(input.resolution);
    if (!resolution || !exactKeys(resolution, ["outcome", "resolvedAt", "provenance"])
      || !["succeeded", "failed", "cancelled"].includes(resolution.outcome as string)
      || !timestamp(resolution.resolvedAt) || !admitsAutomationProvenance(resolution.provenance)) return false;
  }
  return true;
}

export function admitsAutomationRecord(value: unknown): value is AutomationRecord {
  const input = record(value);
  if (!input) return false;
  const optional = ["description", "nextOccurrenceAt", "currentRun", "queuedLatestOccurrence", "lastRun", "blockedReason"];
  const required = ["schemaVersion", "id", "revision", "stateRevision", "name", "activation", "createdAt", "updatedAt", "provenance",
    "targetSessionId", "trigger", "misfirePolicy", "overlapPolicy", "executionDeadlineSeconds", "action",
    "consecutiveFailureCount", "history"];
  const keys = Object.keys(input);
  if (keys.length < required.length || !keys.every((key) => required.includes(key) || optional.includes(key))
    || !required.every((key) => keys.includes(key))) return false;
  return input.schemaVersion === 1
    && bounded(input.id, 64) && uuid.test(input.id)
    && Number.isSafeInteger(input.revision) && (input.revision as number) >= 1
    && Number.isSafeInteger(input.stateRevision) && (input.stateRevision as number) >= 1
    && bounded(input.name, 256)
    && (input.description === undefined || bounded(input.description, 2_048, true))
    && ["draft", "enabled", "paused", "completed", "blocked"].includes(input.activation as string)
    && timestamp(input.createdAt) && timestamp(input.updatedAt)
    && admitsAutomationProvenance(input.provenance)
    && bounded(input.targetSessionId, 200)
    && admitsAutomationTrigger(input.trigger)
    && (input.misfirePolicy === "latest" || input.misfirePolicy === "skip")
    && (input.overlapPolicy === "skip" || input.overlapPolicy === "queueLatest")
    && Number.isSafeInteger(input.executionDeadlineSeconds)
    && (input.executionDeadlineSeconds as number) >= MINIMUM_AUTOMATION_DEADLINE_SECONDS
    && (input.executionDeadlineSeconds as number) <= MAXIMUM_AUTOMATION_DEADLINE_SECONDS
    && admitsAutomationAction(input.action)
    && (input.nextOccurrenceAt === undefined || timestamp(input.nextOccurrenceAt))
    && (input.currentRun === undefined || admitsAutomationRun(input.currentRun))
    && (input.queuedLatestOccurrence === undefined || timestamp(input.queuedLatestOccurrence))
    && (input.lastRun === undefined || admitsAutomationRun(input.lastRun))
    && Number.isSafeInteger(input.consecutiveFailureCount) && (input.consecutiveFailureCount as number) >= 0
    && (input.blockedReason === undefined || bounded(input.blockedReason, 256))
    && Array.isArray(input.history) && input.history.length <= MAXIMUM_AUTOMATION_HISTORY
    && input.history.every(admitsAutomationRun);
}

function requiredText(value: unknown, name: string, maximumBytes: number): string {
  if (!bounded(value, maximumBytes)) throw new GatewayError("invalid_request", `${name} is invalid or exceeds its bound`);
  return value;
}

export function admitAutomationCreateInput(value: unknown, provenance: AutomationProvenance): AutomationCreateInput {
  const input = record(value);
  if (!input) throw new GatewayError("invalid_request", "Automation definition must be an object");
  const allowed = ["name", "description", "activation", "targetSessionId", "trigger", "misfirePolicy", "overlapPolicy", "executionDeadlineSeconds", "action"];
  if (Object.keys(input).some((key) => !allowed.includes(key))) throw new GatewayError("invalid_request", "Automation definition contains unknown fields");
  if (!admitsAutomationTrigger(input.trigger)) throw new GatewayError("invalid_request", "Automation trigger is invalid");
  if (!admitsAutomationAction(input.action)) throw new GatewayError("invalid_request", "Automation action is invalid");
  const description = input.description === undefined ? undefined : requiredText(input.description, "description", 2_048);
  const activation = input.activation === undefined ? "draft" : input.activation;
  if (activation !== "draft" && activation !== "enabled") throw new GatewayError("invalid_request", "Automation activation must be draft or enabled");
  const misfirePolicy = input.misfirePolicy === undefined ? "latest" : input.misfirePolicy;
  const overlapPolicy = input.overlapPolicy === undefined ? "skip" : input.overlapPolicy;
  if (misfirePolicy !== "latest" && misfirePolicy !== "skip") throw new GatewayError("invalid_request", "Automation misfire policy is invalid");
  if (overlapPolicy !== "skip" && overlapPolicy !== "queueLatest") throw new GatewayError("invalid_request", "Automation overlap policy is invalid");
  const deadline = input.executionDeadlineSeconds === undefined ? DEFAULT_AUTOMATION_DEADLINE_SECONDS : input.executionDeadlineSeconds;
  if (!Number.isSafeInteger(deadline) || (deadline as number) < MINIMUM_AUTOMATION_DEADLINE_SECONDS
    || (deadline as number) > MAXIMUM_AUTOMATION_DEADLINE_SECONDS) throw new GatewayError("invalid_request", "Automation execution deadline is invalid");
  return {
    name: requiredText(input.name, "name", 256),
    ...(description === undefined ? {} : { description }),
    activation,
    targetSessionId: requiredText(input.targetSessionId, "targetSessionId", 200),
    trigger: input.trigger,
    misfirePolicy,
    overlapPolicy,
    executionDeadlineSeconds: deadline as number,
    action: input.action,
    provenance,
  };
}

export function admitAutomationUpdateInput(value: unknown): AutomationUpdateInput {
  const input = record(value);
  const allowed = ["name", "description", "targetSessionId", "trigger", "misfirePolicy", "overlapPolicy", "executionDeadlineSeconds", "action"];
  const required = allowed.filter((key) => key !== "description");
  if (!input || Object.keys(input).some((key) => !allowed.includes(key))
    || !required.every((key) => Object.hasOwn(input, key))) {
    throw new GatewayError("invalid_request", "Automation update must contain one complete definition without unknown fields");
  }
  const created = admitAutomationCreateInput(value, { kind: "local" });
  return {
    name: created.name,
    ...(created.description === undefined ? {} : { description: created.description }),
    targetSessionId: created.targetSessionId,
    trigger: created.trigger,
    misfirePolicy: created.misfirePolicy ?? "latest",
    overlapPolicy: created.overlapPolicy ?? "skip",
    executionDeadlineSeconds: created.executionDeadlineSeconds ?? DEFAULT_AUTOMATION_DEADLINE_SECONDS,
    action: created.action,
  };
}
