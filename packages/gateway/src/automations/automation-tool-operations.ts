import { createHash } from "node:crypto";
import { GatewayError } from "../errors.js";
import type { JsonValue } from "../protocol/types.js";
import type { AutomationService } from "./automation-service.js";
import type { ScheduleToolOperations, ScheduleToolRequest, ScheduleToolResult } from "./tron-schedule-extension.js";
import type { AutomationAction, AutomationRecord, AutomationTrigger } from "./types.js";

/** The existing receipt operation required by assistant schedule mutations.
 * Composition supplies the canonical owner; this consumer owns no receipt state. */
interface ScheduleMutationReceipts {
  execute(identity: string, method: string, commandId: string, operation: () => Promise<JsonValue>): Promise<JsonValue>;
}

function commandId(sessionId: string, toolCallId: string, action: string): string {
  return createHash("sha256").update("schedule\0").update(sessionId).update("\0").update(toolCallId).update("\0").update(action).digest("base64url");
}

function requireField<T>(value: T | undefined, name: string): T {
  if (value === undefined) throw new GatewayError("invalid_request", `${name} is required for this schedule action`);
  return value;
}

function createTrigger(request: ScheduleToolRequest, now: number): AutomationTrigger {
  const kinds = [request.at !== undefined, request.everyMinutes !== undefined,
    request.timezone !== undefined || request.localTime !== undefined || request.weekdays !== undefined].filter(Boolean).length;
  if (kinds !== 1) throw new GatewayError("invalid_request", "Create requires exactly one trigger form");
  if (request.at !== undefined) return { kind: "once", at: request.at };
  if (request.everyMinutes !== undefined) {
    return { kind: "interval", everySeconds: request.everyMinutes * 60, anchorAt: new Date(now).toISOString() };
  }
  return {
    kind: "calendar",
    timezone: requireField(request.timezone, "timezone"),
    localTime: requireField(request.localTime, "localTime"),
    weekdays: requireField(request.weekdays, "weekdays"),
  };
}

function createAction(request: ScheduleToolRequest): AutomationAction {
  if ((request.prompt === undefined) === (request.notificationMessage === undefined)) {
    throw new GatewayError("invalid_request", "Create requires exactly one of prompt or notificationMessage");
  }
  return request.prompt !== undefined
    ? { kind: "sessionPrompt", text: request.prompt }
    : { kind: "notification", message: request.notificationMessage! };
}

function result(message: string, details: unknown): ScheduleToolResult {
  return { message, details: details as JsonValue };
}

export class GatewayScheduleToolOperations implements ScheduleToolOperations {
  constructor(
    private readonly service: AutomationService,
    private readonly receipts: ScheduleMutationReceipts,
    private readonly now: () => number = Date.now,
  ) {}

  /** Home can manage only its own finite message automations, never the
   * maintainer's definitions (even when those target this Home). */
  async monitor(sessionId: string, toolCallId: string, raw: unknown): Promise<unknown> {
    const route = this.service.homeRoute();
    if (route.sessionId !== sessionId) throw new GatewayError("not_found", "Monitor requires the current Home");
    const input = raw as Record<string, unknown>;
    const action = input?.action;
    const fields = action === "create" ? ["action", "name", "message", "everyMinutes", "expiresAt"]
      : action === "list" ? ["action"] : ["action", "automationId", "expectedRevision"];
    if (!input || !["create", "list", "pause", "resume", "delete"].includes(action as string)
      || Object.keys(input).some(key => !fields.includes(key))
      || fields.some(key => input[key] === undefined)) throw new GatewayError("invalid_request", "Invalid monitor fields for this action");
    const owns = (record: AutomationRecord) => record.provenance.kind === "home" && record.provenance.homeId === route.homeId;
    if (action === "list") return { monitors: this.service.store.snapshot().filter(owns) };
    return this.receipts.execute(
      `home:${route.homeId}`, `tool.monitor.${action}`, commandId(sessionId, toolCallId, `monitor.${action}`), async () => {
        if (action === "create") {
          if (!Number.isSafeInteger(input.everyMinutes) || (input.everyMinutes as number) < 5 || (input.everyMinutes as number) > 1440) {
            throw new GatewayError("invalid_request", "Monitor interval must be 5 to 1440 whole minutes");
          }
          const created = await this.service.create({
            name: input.name, activation: "enabled",
            target: { kind: "home", homeId: route.homeId, routeGeneration: route.routeGeneration },
            trigger: { kind: "interval", everySeconds: (input.everyMinutes as number) * 60, anchorAt: new Date(this.now() + (input.everyMinutes as number) * 60_000).toISOString() },
            misfirePolicy: "latest", overlapPolicy: "skip", action: { kind: "sessionPrompt", text: input.message },
          }, { kind: "home", homeId: route.homeId, expiresAt: input.expiresAt as string });
          return created as unknown as JsonValue;
        }
        if (typeof input.automationId !== "string" || !Number.isSafeInteger(input.expectedRevision)) throw new GatewayError("invalid_request", "Monitor requires automationId and expectedRevision");
        const current = this.service.get(input.automationId);
        if (!owns(current)) throw new GatewayError("not_found", "Monitor was not created by this Home");
        if (action === "delete") {
          await this.service.delete(current.id, input.expectedRevision as number);
          return { automationId: current.id, deleted: true };
        }
        return await (action === "resume" ? this.service.enable(current.id, input.expectedRevision as number)
          : this.service.pause(current.id, input.expectedRevision as number)) as unknown as JsonValue;
      });
  }

  private belongsToSession(automation: AutomationRecord, sessionId: string): boolean {
    if (automation.target.kind === "home") {
      try { const route = this.service.homeRoute(); if (route.sessionId === sessionId && route.homeId === automation.target.homeId && route.routeGeneration === automation.target.routeGeneration) return true; }
      catch { /* An unavailable Home does not widen this session's inventory. */ }
    }
    return (automation.target.kind === "existingSession" && automation.target.sessionId === sessionId)
      || (automation.provenance.kind === "assistant" && automation.provenance.sessionId === sessionId);
  }

  async execute(sessionId: string, toolCallId: string, request: ScheduleToolRequest): Promise<ScheduleToolResult> {
    if (request.action === "list") {
      const all = this.service.list().items.filter((automation) =>
        this.belongsToSession(this.service.get(automation.id), sessionId));
      const shown = all.slice(0, 50);
      const lines = shown.map((automation) => `${automation.name} (${automation.id}) — ${automation.activation}, revision ${automation.revision}`);
      return result(lines.length > 0 ? lines.join("\n") : "No automations target this session.", {
        automations: shown,
        omittedCount: Math.max(0, all.length - shown.length),
      });
    }
    if (request.action === "show") {
      const automation = this.service.get(requireField(request.automationId, "automationId"));
      if (!this.belongsToSession(automation, sessionId)) throw new GatewayError("not_found", "Automation does not belong to this session");
      return result(`Automation “${automation.name}” is ${automation.activation}.`, automation);
    }

    const receiptResult = await this.receipts.execute(
      `assistant:${sessionId}`,
      `tool.schedule.${request.action}`,
      commandId(sessionId, toolCallId, request.action),
      async () => this.mutate(sessionId, toolCallId, request),
    );
    const object = receiptResult && typeof receiptResult === "object" && !Array.isArray(receiptResult)
      ? receiptResult as Record<string, JsonValue> : {};
    const message = typeof object.message === "string" ? object.message : "Automation updated.";
    return { message, details: object.details ?? null };
  }

  private async mutate(sessionId: string, toolCallId: string, request: ScheduleToolRequest): Promise<JsonValue> {
    if (request.action === "create") {
      const route = request.target === "home" ? this.service.homeRoute() : undefined;
      const created = await this.service.create({
        name: requireField(request.name, "name"),
        activation: request.activate === true ? "enabled" : "draft",
        target: route ? { kind: "home", homeId: route.homeId, routeGeneration: route.routeGeneration }
          : request.target === "newSessionInWorkspace"
            ? { kind: "workspace", cwd: await this.service.workspaceForSession(sessionId), sessionPolicy: "newPerRun" }
            : { kind: "existingSession", sessionId },
        trigger: createTrigger(request, this.now()),
        misfirePolicy: "latest",
        overlapPolicy: "skip",
        action: createAction(request),
      }, { kind: "assistant", sessionId, sourceId: toolCallId });
      return { message: `Created ${created.activation} automation “${created.name}”.`, details: created as unknown as JsonValue };
    }

    const id = requireField(request.automationId, "automationId");
    const current = this.service.get(id);
    if (!this.belongsToSession(current, sessionId)) throw new GatewayError("not_found", "Automation does not belong to this session");
    if (request.action === "enable" || request.action === "pause" || request.action === "delete") {
      const revision = requireField(request.expectedRevision, "expectedRevision");
      if (request.action === "delete") {
        await this.service.delete(id, revision);
        return { message: `Deleted automation “${current.name}”.`, details: { automationId: id, deleted: true } };
      }
      const updated = request.action === "enable"
        ? await this.service.enable(id, revision)
        : await this.service.pause(id, revision);
      return { message: `${request.action === "enable" ? "Enabled" : "Paused"} automation “${updated.name}”.`, details: updated as unknown as JsonValue };
    }
    if (request.action === "runNow") {
      const run = await this.service.runNow(id, requireField(request.expectedRevision, "expectedRevision"));
      return { message: `Queued automation “${current.name}” to run now.`, details: run as unknown as JsonValue };
    }
    if (request.action === "cancel") {
      const run = await this.service.cancel(id, requireField(request.runId, "runId"));
      return { message: `Cancellation settled for automation “${current.name}”.`, details: run as unknown as JsonValue };
    }
    const resolved = await this.service.resolve(
      id,
      requireField(request.runId, "runId"),
      requireField(request.expectedRevision, "expectedRevision"),
      requireField(request.outcome, "outcome"),
      { kind: "assistant", sessionId, sourceId: toolCallId },
    );
    return { message: `Resolved the uncertain run as ${request.outcome}.`, details: resolved as unknown as JsonValue };
  }
}
