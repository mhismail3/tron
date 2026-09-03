import { describe, expect, it, vi } from "vitest";
import { GatewayScheduleToolOperations } from "./automation-tool-operations.js";

function fixture() {
  const created = {
    schemaVersion: 2,
    id: "10000000-0000-4000-8000-000000000001",
    revision: 1,
    stateRevision: 1,
    name: "Workspace review",
    activation: "draft",
    createdAt: "2026-01-01T00:00:00.000Z",
    updatedAt: "2026-01-01T00:00:00.000Z",
    provenance: { kind: "assistant", sessionId: "session-one", sourceId: "tool-one" },
    target: { kind: "workspace", cwd: "/workspace", sessionPolicy: "newPerRun" },
    trigger: { kind: "once", at: "2026-01-02T00:00:00.000Z" },
    misfirePolicy: "latest",
    overlapPolicy: "skip",
    executionDeadlineSeconds: 3_600,
    action: { kind: "sessionPrompt", text: "Review" },
    consecutiveFailureCount: 0,
    history: [],
  };
  const service = {
    workspaceForSession: vi.fn(async () => "/workspace"),
    create: vi.fn(async (definition: any, provenance: any) => ({ ...created, ...definition, provenance })),
    list: vi.fn(() => ({ catalogRevision: 1, items: [{
      id: created.id,
      revision: 1,
      stateRevision: 1,
      name: created.name,
      activation: created.activation,
      actionKind: "sessionPrompt",
      target: created.target,
      trigger: created.trigger,
      consecutiveFailureCount: 0,
      createdAt: created.createdAt,
      updatedAt: created.updatedAt,
    }] })),
    get: vi.fn(() => created),
  };
  const receipts = {
    execute: vi.fn(async (_identity: string, _method: string, _command: string, operation: () => Promise<unknown>) => operation()),
  };
  return {
    service,
    operations: new GatewayScheduleToolOperations(service as any, receipts as any, () => Date.parse("2026-01-01T00:00:00.000Z")),
  };
}

describe("GatewayScheduleToolOperations workspace targets", () => {
  it("creates a new-session target only from the current session workspace", async () => {
    const { service, operations } = fixture();
    await operations.execute("session-one", "tool-one", {
      action: "create",
      name: "Workspace review",
      prompt: "Review",
      target: "newSessionInWorkspace",
      at: "2026-01-02T00:00:00.000Z",
    });

    expect(service.workspaceForSession).toHaveBeenCalledWith("session-one");
    expect(service.create).toHaveBeenCalledWith(expect.objectContaining({
      target: { kind: "workspace", cwd: "/workspace", sessionPolicy: "newPerRun" },
      action: { kind: "sessionPrompt", text: "Review" },
    }), { kind: "assistant", sessionId: "session-one", sourceId: "tool-one" });
  });

  it("keeps assistant-owned workspace definitions visible to their source session", async () => {
    const { operations } = fixture();
    const listed = await operations.execute("session-one", "tool-list", { action: "list" });
    expect(listed.message).toContain("Workspace review");
    await expect(operations.execute("other-session", "tool-show", {
      action: "show",
      automationId: "10000000-0000-4000-8000-000000000001",
    })).rejects.toMatchObject({ code: "not_found" });
  });
});
