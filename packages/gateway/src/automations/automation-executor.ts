import { GatewayError } from "../errors.js";
import type { NotificationService } from "../notifications/notification-service.js";
import type { ResourceInvocation } from "../protocol/types.js";
import type { GatewayWorkHandle, GatewayWorkRegistry } from "../sessions/gateway-work-registry.js";
import { canonicalResourceName } from "../sessions/resource-invocation.js";
import type { RuntimeRegistry } from "../sessions/runtime-registry.js";
import type { AutomationOperationTerminal } from "../sessions/runtime-slot.js";
import {
  AutomationAdmissionError,
  type AutomationExecutionHandle,
  type AutomationExecutionResult,
  type AutomationExecutor,
  type AutomationRecoveryResult,
} from "./automation-scheduler.js";
import type { AutomationRecord, AutomationRun } from "./types.js";

function terminalResult(terminal: AutomationOperationTerminal): AutomationExecutionResult {
  if (terminal.lifecycle === "completed") {
    return {
      state: "succeeded",
      invocationId: terminal.invocationId,
      ...(terminal.assistantCompletionId === undefined ? {} : { assistantCompletionId: terminal.assistantCompletionId }),
    };
  }
  if (terminal.lifecycle === "interrupted") {
    return { state: "cancelled", reason: terminal.errorCode ?? "interrupted", invocationId: terminal.invocationId };
  }
  if (terminal.lifecycle === "failed") {
    return {
      state: "failed",
      reason: terminal.errorCode ?? "agent-failed",
      invocationId: terminal.invocationId,
      error: { code: terminal.errorCode ?? "agent-failed", message: "The scheduled agent operation failed", retryable: false },
    };
  }
  return { state: "outcomeUnknown", reason: terminal.errorCode ?? "terminal-outcome-unknown", invocationId: terminal.invocationId };
}

function promptText(text: string, resource: ResourceInvocation | undefined): string {
  if (!resource) return text;
  return `/${canonicalResourceName(resource.source, resource.name)}${text ? ` ${text}` : ""}`;
}

export class GatewayAutomationExecutor implements AutomationExecutor {
  constructor(
    private readonly sessions: RuntimeRegistry,
    private readonly workRegistry: GatewayWorkRegistry,
    private readonly notifications: NotificationService | undefined,
    private readonly machineId: string | undefined,
  ) {}

  async start(record: AutomationRecord, run: AutomationRun): Promise<AutomationExecutionHandle> {
    const operationId = run.operationId;
    if (!operationId) throw new AutomationAdmissionError("Automation operation identity is missing", false, "invalid-operation");
    const target = run.targetSnapshot;
    const sessionId = run.executionSessionId;
    let work: GatewayWorkHandle;
    try {
      work = this.workRegistry.begin({
        kind: "automation-dispatch",
        sessionId,
        hostEpoch: this.workRegistry.runtimeEpoch,
      });
    } catch (error) {
      throw new AutomationAdmissionError(error instanceof Error ? error.message : "Gateway is draining", true, "gateway-busy", true);
    }

    let releaseLease: (() => void) | undefined;
    try {
      let slot;
      if (target.kind === "workspace") {
        const leased = await this.sessions.createAutomationSession(target.cwd, sessionId, operationId);
        slot = leased.slot;
        releaseLease = leased.release;
      } else {
        const leased = await this.sessions.acquireAutomationLease(sessionId);
        slot = leased.slot;
        releaseLease = leased.release;
      }
      if (run.actionSnapshot.kind === "notification") {
        if (target.kind !== "existingSession") throw new AutomationAdmissionError("Workspace automations support session prompts only", false, "invalid-action");
        if (!this.notifications) throw new AutomationAdmissionError("Notifications are unavailable", false, "notifications-unavailable");
        const status = await this.notifications.enqueue({
          sessionId,
          sourceId: run.runId,
          kind: "explicit",
          title: record.name,
          message: run.actionSnapshot.message,
          ...(this.machineId ? { route: { sessionId, machineId: this.machineId } } : {}),
        });
        work.transition("automation-terminal-persistence");
        const result: AutomationExecutionResult = status === "queued" || status === "suppressed"
          ? { state: "succeeded", notificationAdmissionStatus: status }
          : {
              state: "failed",
              reason: `notification-${status}`,
              notificationAdmissionStatus: status,
              error: { code: `notification-${status}`, message: `Notification admission was ${status.replaceAll("_", " ")}`, retryable: false },
            };
        return {
          operationId,
          completion: Promise.resolve(result),
          cancel: async () => {},
          acknowledgeTerminal: async () => {
            releaseLease?.();
            work.settle();
          },
        };
      }

      const resource = run.actionSnapshot.resourceInvocation;
      if (resource) {
        const catalogName = canonicalResourceName(resource.source, resource.name);
        const commands = slot.commands();
        const matches = commands.filter((command) => command.source === resource.source && command.name === catalogName);
        const shadowed = resource.source !== "extension"
          && commands.some((command) => command.source === "extension" && command.name === catalogName);
        if (resource.source === "extension" || matches.length !== 1 || shadowed) {
          throw new AutomationAdmissionError("Selected automation resource is no longer unambiguous", false, "resource-unavailable");
        }
      }

      let resolveTerminal!: (result: AutomationExecutionResult) => void;
      const completion = new Promise<AutomationExecutionResult>((resolve) => {
        resolveTerminal = resolve;
      });
      let terminalObserved = false;
      let observedResult: AutomationExecutionResult | undefined;
      const onTerminal = async (terminal: AutomationOperationTerminal): Promise<void> => {
        if (terminalObserved) return;
        terminalObserved = true;
        work.transition("automation-terminal-persistence");
        observedResult = terminalResult(terminal);
        resolveTerminal(observedResult);
      };
      let admittedInvocationId: string | undefined;
      let admission: { operationId: string };
      try {
        admission = await slot.prompt(
          promptText(run.actionSnapshot.text, resource),
          [],
          undefined,
          {
            text: run.actionSnapshot.text,
            ...(resource === undefined ? {} : { resourceInvocation: resource }),
            attachmentEnvelope: "",
            attachmentCount: 0,
          },
          undefined,
          {
            operationId,
            origin: { kind: "gateway", ownerId: record.id, title: "Automation", confidence: "boundary" },
            onAdmitted: (invocationId) => { admittedInvocationId = invocationId; },
            onTerminal,
          },
        );
      } catch (error) {
        if (terminalObserved && observedResult) {
          return {
            operationId,
            completion: Promise.resolve(observedResult),
            cancel: async () => {},
            acknowledgeTerminal: async () => {
              await this.sessions.clearAutomationMarker(sessionId, operationId);
              releaseLease?.();
              work.settle();
            },
          };
        }
        releaseLease();
        work.settle();
        throw error instanceof AutomationAdmissionError
          ? error
          : new AutomationAdmissionError(error instanceof Error ? error.message : "Agent admission failed", false, "agent-admission-rejected");
      }

      return {
        operationId: admission.operationId,
        ...(admittedInvocationId === undefined ? {} : { invocationId: admittedInvocationId }),
        completion,
        cancel: async (reason) => {
          try {
            await slot.abort("agent", operationId);
          } catch (error) {
            if (reason !== "gateway-shutdown") throw error;
          }
        },
        acknowledgeTerminal: async () => {
          await this.sessions.clearAutomationMarker(sessionId, operationId);
          releaseLease?.();
          work.settle();
        },
      };
    } catch (error) {
      releaseLease?.();
      work.settle();
      if (error instanceof AutomationAdmissionError) throw error;
      if (error instanceof GatewayError) {
        throw new AutomationAdmissionError(
          error.message,
          error.retryable,
          `target-${error.code}`,
          error.code === "busy",
        );
      }
      throw new AutomationAdmissionError(
        error instanceof Error ? error.message : "Automation target is unavailable",
        false,
        "target-unavailable",
      );
    }
  }

  async recover(record: AutomationRecord, run: AutomationRun): Promise<AutomationRecoveryResult> {
    if (!run.operationId) return { state: "outcomeUnknown", reason: "operation-identity-missing" };
    const evidence = await this.sessions.automationRecoveryEvidence(run.executionSessionId, run.operationId);
    const invocation = evidence.invocation;
    const marker = evidence.marker;
    if (marker?.assistantCompletionId) {
      if (invocation && ["failed", "interrupted", "outcomeUnknown"].includes(invocation.lifecycle)) {
        return { state: "outcomeUnknown", reason: "conflicting-terminal-evidence" };
      }
      return {
        state: "succeeded",
        ...(invocation ? { invocationId: invocation.invocationId } : {}),
        assistantCompletionId: marker.assistantCompletionId,
      };
    }
    if (invocation?.lifecycle === "completed") return { state: "succeeded", invocationId: invocation.invocationId };
    if (invocation?.lifecycle === "failed") {
      return { state: "failed", reason: "recovered-agent-failure", invocationId: invocation.invocationId,
        error: { code: "recovered-agent-failure", message: "The scheduled operation failed before Gateway restart", retryable: false } };
    }
    if (invocation?.lifecycle === "interrupted") return { state: "cancelled", reason: "recovered-interruption", invocationId: invocation.invocationId };
    if (invocation?.lifecycle === "outcomeUnknown") return { state: "outcomeUnknown", reason: "recovered-outcome-unknown", invocationId: invocation.invocationId };
    if (!invocation && !marker) {
      if (run.state === "cancelling") return { state: "cancelled", reason: "cancelled-before-admission" };
      // Pi does not currently expose an owner-safe eager flush for a brand-new
      // session. Once workspace provisioning entered the durable admitting
      // state, a missing file cannot prove that provider admission never
      // happened. Fail closed instead of creating a second user session.
      return run.targetSnapshot.kind === "workspace"
        ? { state: "outcomeUnknown", reason: "workspace-session-outcome-unknown" }
        : { state: "requeue", reason: "no-admission-evidence" };
    }
    return { state: "outcomeUnknown", reason: run.state === "cancelling"
      ? "cancellation-outcome-unknown" : "accepted-without-terminal-evidence",
      ...(invocation ? { invocationId: invocation.invocationId } : {}) };
  }

  async reconcileStoredTerminals(records: readonly AutomationRecord[]): Promise<void> {
    const terminalOperations = new Map<string, Set<string>>();
    for (const record of records) {
      for (const run of record.history) {
        if (!run.operationId) continue;
        const operations = terminalOperations.get(run.executionSessionId) ?? new Set<string>();
        operations.add(run.operationId);
        terminalOperations.set(run.executionSessionId, operations);
      }
    }
    await this.sessions.reconcileStoredAutomationMarkers(terminalOperations);
  }

  async acknowledgeRecovery(record: AutomationRecord, run: AutomationRun): Promise<void> {
    if (run.operationId) await this.sessions.clearAutomationMarker(run.executionSessionId, run.operationId);
  }
}
