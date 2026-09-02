import { describe, expect, it, vi } from "vitest";
import { GatewayService, type ClientContext } from "../transport/gateway-service.js";

const client = (): ClientContext => ({
  id: "connection-one", identity: "device-one", isLocal: false,
  beginSynchronization: () => "sync", establishSynchronization() {}, completeSynchronization() {},
  setPresentationVisibility: () => ({ visible: true, revision: 1 }), unsubscribe: () => true,
  attachTerminal() {}, detachTerminal() {}, ownsTerminal: () => false,
});

function fixture() {
  const record = {
    schemaVersion: 1, id: "10000000-0000-4000-8000-000000000001", revision: 1, stateRevision: 1,
    name: "Review", activation: "draft", createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z",
    provenance: { kind: "mobile" }, targetSessionId: "session-one", trigger: { kind: "once", at: "2026-01-02T00:00:00.000Z" },
    misfirePolicy: "latest", overlapPolicy: "skip", executionDeadlineSeconds: 3_600,
    action: { kind: "sessionPrompt", text: "Review" }, consecutiveFailureCount: 0, history: [],
  };
  const automations = {
    status: vi.fn(() => ({ ready: true, degraded: false, automationCount: 1, aggregateBytes: 1, malformedRecordCount: 0, catalogRevision: 2 })),
    list: vi.fn(() => ({ catalogRevision: 2, items: [{ id: record.id, revision: 1, stateRevision: 1, name: "Review", activation: "draft", actionKind: "sessionPrompt", targetSessionId: "session-one", trigger: record.trigger, consecutiveFailureCount: 0, createdAt: record.createdAt, updatedAt: record.updatedAt }] })),
    get: vi.fn(() => record),
    runList: vi.fn(() => []),
    runGet: vi.fn(),
    create: vi.fn(async () => record),
    update: vi.fn(async () => ({ ...record, revision: 2 })),
    enable: vi.fn(async () => ({ ...record, revision: 2, activation: "enabled" })),
    pause: vi.fn(async () => ({ ...record, revision: 2, activation: "paused" })),
    delete: vi.fn(async () => {}),
    runNow: vi.fn(async () => ({ runId: "run-one", state: "queued" })),
    cancel: vi.fn(async () => ({ runId: "run-one", state: "cancelled" })),
    resolve: vi.fn(async () => ({ ...record, revision: 2, activation: "enabled" })),
    beginDrain: vi.fn(),
  };
  const service = new GatewayService({
    config: { tronHome: "/tmp" }, automations,
    receipts: { execute: async (_identity: string, _method: string, _command: string, operation: () => Promise<unknown>) => operation() },
  } as any);
  return { service, automations, record };
}

describe("Gateway automation RPC", () => {
  it("projects bounded reads and keeps action content out of list summaries", async () => {
    const { service, record } = fixture();
    await expect(service.invoke(client(), "automation.status", {})).resolves.toMatchObject({ ready: true, automationCount: 1 });
    const page = await service.invoke(client(), "automation.list", { limit: 10 }) as any;
    expect(page.items).toHaveLength(1);
    expect(JSON.stringify(page.items)).not.toContain("\"text\"");
    await expect(service.invoke(client(), "automation.get", { automationId: record.id })).resolves.toMatchObject({ action: { text: "Review" } });
  });

  it("requires command and definition revisions for mutations", async () => {
    const { service, automations, record } = fixture();
    await service.invoke(client(), "automation.enable", {
      commandId: "command-enable-01", automationId: record.id, expectedRevision: 1,
    });
    expect(automations.enable).toHaveBeenCalledWith(record.id, 1);
    await expect(service.invoke(client(), "automation.enable", {
      commandId: "command-enable-02", automationId: record.id,
    })).rejects.toMatchObject({ code: "invalid_request" });
  });

  it("passes authenticated provenance into creation and resolution", async () => {
    const { service, automations, record } = fixture();
    await service.invoke(client(), "automation.create", {
      commandId: "command-create-01",
      definition: { name: "Review" },
    });
    expect(automations.create).toHaveBeenCalledWith({ name: "Review" }, { kind: "mobile" });
    await service.invoke(client(), "automation.run.resolve", {
      commandId: "command-resolve-01", automationId: record.id, runId: "run-one", expectedRevision: 1, outcome: "failed",
    });
    expect(automations.resolve).toHaveBeenCalledWith(record.id, "run-one", 1, "failed", { kind: "mobile" });
  });
});
