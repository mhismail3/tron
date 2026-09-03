import { describe, expect, it } from "vitest";
import { AutomationService } from "./automation-service.js";
import { admitAutomationCreateInput } from "./automation-contract.js";

function service(): AutomationService {
  return new AutomationService(
    {} as any,
    {} as any,
    {} as any,
  );
}

describe("Automation target contract", () => {
  const base = {
    name: "Workspace review",
    activation: "draft",
    target: { kind: "workspace", cwd: "/workspace", sessionPolicy: "newPerRun" },
    trigger: { kind: "once", at: "2026-01-02T00:00:00.000Z" },
    action: { kind: "sessionPrompt", text: "Review" },
  };

  it("admits one canonical workspace target shape", () => {
    expect(admitAutomationCreateInput(base, { kind: "mobile" })).toMatchObject({
      target: { kind: "workspace", cwd: "/workspace", sessionPolicy: "newPerRun" },
    });
    expect(() => admitAutomationCreateInput({ ...base, targetSessionId: "legacy" }, { kind: "mobile" }))
      .toThrow(/unknown fields/);
    expect(() => admitAutomationCreateInput({
      ...base,
      target: { kind: "workspace", cwd: "relative", sessionPolicy: "newPerRun" },
    }, { kind: "mobile" })).toThrow(/target or action/);
  });

  it("limits workspace targets to prompts and daily-or-slower intervals", () => {
    expect(() => admitAutomationCreateInput({
      ...base,
      action: { kind: "notification", message: "Done" },
    }, { kind: "mobile" })).toThrow(/target or action/);
    expect(() => admitAutomationCreateInput({
      ...base,
      trigger: { kind: "interval", everySeconds: 3_600, anchorAt: "2026-01-01T00:00:00.000Z" },
    }, { kind: "mobile" })).toThrow(/target or action/);
    expect(admitAutomationCreateInput({
      ...base,
      trigger: { kind: "interval", everySeconds: 86_400, anchorAt: "2026-01-01T00:00:00.000Z" },
    }, { kind: "mobile" }).trigger).toMatchObject({ everySeconds: 86_400 });
  });
});

describe("AutomationService target ownership", () => {
  it("canonicalizes workspace definitions and revalidates them before manual runs", async () => {
    const record = {
      id: "10000000-0000-4000-8000-000000000001",
      revision: 1,
      target: { kind: "workspace", cwd: "/canonical/workspace", sessionPolicy: "newPerRun" },
    };
    const store = {
      create: async (input: any) => ({ ...record, ...input }),
      get: () => record,
    };
    const scheduler = { wake() {}, runNow: async () => ({ runId: "run-one" }) };
    const targets = {
      requirePersistedUserSession: async () => {},
      requireResolvedAutomationWorkspace: async () => "/canonical/workspace",
      workspaceForSession: async () => "/canonical/workspace",
    };
    const service = new AutomationService(store as any, scheduler as any, targets);
    const created = await service.create({
      name: "Workspace review",
      activation: "draft",
      target: { kind: "workspace", cwd: "/alias", sessionPolicy: "newPerRun" },
      trigger: { kind: "once", at: "2026-01-02T00:00:00.000Z" },
      action: { kind: "sessionPrompt", text: "Review" },
    }, { kind: "mobile" });
    expect(created.target).toEqual({ kind: "workspace", cwd: "/canonical/workspace", sessionPolicy: "newPerRun" });
    await expect(service.runNow(record.id, 1)).resolves.toEqual({ runId: "run-one" });
  });
});

describe("AutomationService schedule preview", () => {
  it("returns canonical bounded future occurrences", () => {
    expect(service().schedulePreview({
      kind: "interval", everySeconds: 60, anchorAt: "2026-01-01T00:00:00.000Z",
    }, "2026-01-01T00:01:00.000Z", 3)).toEqual({ occurrences: [
      "2026-01-01T00:02:00.000Z",
      "2026-01-01T00:03:00.000Z",
      "2026-01-01T00:04:00.000Z",
    ] });
  });

  it("applies the strict trigger, timestamp, and limit contracts", () => {
    expect(() => service().schedulePreview({ kind: "shell" }, "2026-01-01T00:00:00.000Z", 5))
      .toThrow(/trigger is invalid/);
    expect(() => service().schedulePreview({ kind: "once", at: "2026-01-02T00:00:00.000Z" }, "tomorrow", 5))
      .toThrow(/Gateway timestamp/);
    expect(() => service().schedulePreview({ kind: "once", at: "2026-01-02T00:00:00.000Z" }, "2026-01-01T00:00:00.000Z", 21))
      .toThrow(/between 1 and 20/);
  });

  it("resolves calendar preview through the canonical DST schedule engine", () => {
    expect(service().schedulePreview({
      kind: "calendar", timezone: "America/New_York", localTime: "09:00", weekdays: [7],
    }, "2026-03-07T00:00:00.000Z", 1)).toEqual({ occurrences: ["2026-03-08T13:00:00.000Z"] });
  });
});
