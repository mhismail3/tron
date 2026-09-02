import { createHash } from "node:crypto";
import { GatewayError } from "../errors.js";
import type { JsonValue } from "../protocol/types.js";
import type { CommandReceiptStore } from "../transport/command-receipts.js";
import type { AutomationService } from "./automation-service.js";
import type { ScheduleToolOperations, ScheduleToolRequest, ScheduleToolResult } from "./tron-schedule-extension.js";
import type { AutomationAction, AutomationTrigger } from "./types.js";

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
    private readonly receipts: CommandReceiptStore,
    private readonly now: () => number = Date.now,
  ) {}

  async execute(sessionId: string, toolCallId: string, request: ScheduleToolRequest): Promise<ScheduleToolResult> {
    if (request.action === "list") {
      const all = this.service.list().items.filter((automation) => automation.targetSessionId === sessionId);
      const shown = all.slice(0, 50);
      const lines = shown.map((automation) => `${automation.name} (${automation.id}) — ${automation.activation}, revision ${automation.revision}`);
      return result(lines.length > 0 ? lines.join("\n") : "No automations target this session.", {
        automations: shown,
        omittedCount: Math.max(0, all.length - shown.length),
      });
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
      const created = await this.service.create({
        name: requireField(request.name, "name"),
        activation: request.activate === true ? "enabled" : "draft",
        targetSessionId: sessionId,
        trigger: createTrigger(request, this.now()),
        misfirePolicy: "latest",
        overlapPolicy: "skip",
        action: createAction(request),
      }, { kind: "assistant", sessionId, sourceId: toolCallId });
      return { message: `Created ${created.activation} automation “${created.name}”.`, details: created as unknown as JsonValue };
    }

    const id = requireField(request.automationId, "automationId");
    const current = this.service.get(id);
    if (current.targetSessionId !== sessionId) throw new GatewayError("not_found", "Automation does not belong to this session");
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
      const run = await this.service.runNow(id);
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
