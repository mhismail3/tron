import { chmod, mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { AutomationStore, settleAutomationRun } from "./automation-store.js";
import type { AutomationCreateInput, AutomationRun } from "./types.js";
import { automationOccurrenceId } from "./schedule.js";

function input(activation: "draft" | "enabled" = "enabled"): AutomationCreateInput {
  return {
    name: "Daily review",
    activation,
    target: { kind: "existingSession", sessionId: "session-one" },
    trigger: { kind: "interval", everySeconds: 300, anchorAt: "2026-01-01T00:00:00.000Z" },
    misfirePolicy: "latest",
    overlapPolicy: "skip",
    executionDeadlineSeconds: 3_600,
    action: { kind: "sessionPrompt", text: "Review the workspace" },
    provenance: { kind: "local" },
  };
}

describe("AutomationStore", () => {
  it("persists exact owner-only records and enforces definition revisions", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-automation-store-"));
    const changed = vi.fn();
    const store = new AutomationStore(root, { now: () => Date.parse("2026-01-01T00:00:01Z"), changed });
    await store.initialize();

    const created = await store.create(input());
    expect(created.revision).toBe(1);
    expect(created.stateRevision).toBe(1);
    expect(created.nextOccurrenceAt).toBe("2026-01-01T00:05:00.000Z");
    await expect(store.setActivation(created.id, 0, "paused")).rejects.toMatchObject({ code: "conflict" });

    const paused = await store.setActivation(created.id, 1, "paused");
    expect(paused).toMatchObject({ revision: 2, stateRevision: 2, activation: "paused" });
    expect(paused.nextOccurrenceAt).toBeUndefined();
    expect(changed).toHaveBeenCalled();

    const stored = JSON.parse(await readFile(join(root, "gateway", "automations", `${created.id}.json`), "utf8"));
    expect(stored).toMatchObject({ id: created.id, revision: 2, activation: "paused" });
  });

  it("keeps run state changes independent from the definition revision", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-automation-state-"));
    const store = new AutomationStore(root, { now: () => Date.parse("2026-01-01T00:00:01Z") });
    await store.initialize();
    const created = await store.create(input());
    const scheduledFor = created.nextOccurrenceAt!;
    const run: AutomationRun = {
      runId: "10000000-0000-4000-8000-000000000001",
      occurrenceId: automationOccurrenceId(created.id, created.revision, scheduledFor),
      automationRevision: created.revision,
      scheduledFor,
      triggerSnapshot: created.trigger,
      actionSnapshot: created.action, targetSnapshot: created.target, executionSessionId: "session-one",
      state: "queued",
      createdAt: "2026-01-01T00:00:01.000Z",
      preAdmissionAttemptCount: 0,
    };

    const updated = await store.mutateState(created.id, (current) => ({ ...current, currentRun: run }));
    expect(updated.revision).toBe(1);
    expect(updated.stateRevision).toBe(2);
    await expect(store.setActivation(created.id, 1, "paused")).resolves.toMatchObject({ revision: 2 });
  });

  it("pauses future admission by terminalizing a queued occurrence", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-automation-pause-"));
    const store = new AutomationStore(root, { now: () => Date.parse("2026-01-01T00:00:01Z") });
    await store.initialize();
    const created = await store.create(input());
    const run: AutomationRun = {
      runId: "10000000-0000-4000-8000-000000000008",
      occurrenceId: automationOccurrenceId(created.id, created.revision, created.nextOccurrenceAt!),
      automationRevision: created.revision, scheduledFor: created.nextOccurrenceAt!,
      triggerSnapshot: created.trigger, actionSnapshot: created.action, targetSnapshot: created.target, executionSessionId: "session-one", state: "queued",
      createdAt: "2026-01-01T00:00:01.000Z", preAdmissionAttemptCount: 0,
      operationId: "automation:10000000-0000-4000-8000-000000000008",
    };
    await store.mutateState(created.id, (current) => ({ ...current, currentRun: run }));

    const paused = await store.setActivation(created.id, created.revision, "paused");

    expect(paused.currentRun).toBeUndefined();
    expect(paused.lastRun).toMatchObject({ runId: run.runId, state: "cancelled", reason: "automation-paused" });
  });

  it("terminalizes queued target work before blocking a deleted session", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-automation-target-delete-"));
    const store = new AutomationStore(root, { now: () => Date.parse("2026-01-01T00:00:01Z") });
    await store.initialize();
    const created = await store.create(input());
    const scheduledFor = created.nextOccurrenceAt!;
    const run: AutomationRun = {
      runId: "10000000-0000-4000-8000-000000000009",
      occurrenceId: automationOccurrenceId(created.id, created.revision, scheduledFor),
      automationRevision: created.revision, scheduledFor, triggerSnapshot: created.trigger, actionSnapshot: created.action, targetSnapshot: created.target, executionSessionId: "session-one",
      state: "queued", createdAt: "2026-01-01T00:00:01.000Z", preAdmissionAttemptCount: 0,
      operationId: "automation:10000000-0000-4000-8000-000000000009",
    };
    await store.mutateState(created.id, (current) => ({ ...current, currentRun: run }));

    await store.blockTarget("session-one");

    const blocked = store.get(created.id);
    expect(blocked).toMatchObject({ activation: "blocked", blockedReason: "target-session-deleted" });
    expect(blocked.currentRun).toBeUndefined();
    expect(blocked.lastRun).toMatchObject({ runId: run.runId, state: "cancelled" });
  });

  it("does not bind workspace definitions to generated session deletion", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-automation-workspace-delete-"));
    const store = new AutomationStore(root, { now: () => Date.parse("2026-01-01T00:00:01Z") });
    await store.initialize();
    const created = await store.create({
      ...input(),
      target: { kind: "workspace", cwd: "/workspace", sessionPolicy: "newPerRun" },
      trigger: { kind: "interval", everySeconds: 86_400, anchorAt: "2026-01-01T00:00:00.000Z" },
    });

    await expect(store.blockTarget("20000000-0000-4000-8000-000000000001")).resolves.toEqual([]);
    expect(store.get(created.id)).toMatchObject({
      activation: "enabled",
      target: { kind: "workspace", cwd: "/workspace", sessionPolicy: "newPerRun" },
    });
  });

  it("prunes large run snapshots by serialized bytes before terminal persistence", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-automation-history-bytes-"));
    let now = Date.parse("2026-01-01T00:00:01Z");
    const store = new AutomationStore(root, { now: () => now });
    await store.initialize();
    const created = await store.create({ ...input(), action: { kind: "sessionPrompt", text: "x".repeat(64 * 1_024) } });
    for (let index = 1; index <= 12; index += 1) {
      const suffix = String(index).padStart(12, "0");
      const run: AutomationRun = {
        runId: `10000000-0000-4000-8000-${suffix}`,
        occurrenceId: automationOccurrenceId(created.id, created.revision, new Date(now).toISOString()),
        automationRevision: created.revision, scheduledFor: new Date(now).toISOString(),
        triggerSnapshot: created.trigger, actionSnapshot: created.action, targetSnapshot: created.target, executionSessionId: "session-one", state: "queued",
        createdAt: new Date(now).toISOString(), preAdmissionAttemptCount: 0,
        operationId: `automation:10000000-0000-4000-8000-${suffix}`,
      };
      await store.mutateState(created.id, (current) => ({ ...current, currentRun: run }));
      const terminal = { ...run, state: "succeeded" as const, terminalAt: new Date(now).toISOString() };
      await store.mutateState(created.id, (current) => settleAutomationRun(current, terminal, terminal.terminalAt));
      now += 60_000;
    }
    const retained = store.get(created.id);
    const bytes = Buffer.byteLength(await readFile(join(root, "gateway", "automations", `${created.id}.json`), "utf8"));
    expect(bytes).toBeLessThanOrEqual(512 * 1_024);
    expect(retained.history.length).toBeLessThan(12);
    expect(retained.lastRun?.runId).toBe("10000000-0000-4000-8000-000000000012");
  });

  it("rejects schema-v1 records without a legacy parser or rewrite", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-automation-old-schema-"));
    const directory = join(root, "gateway", "automations");
    await mkdir(directory, { recursive: true, mode: 0o700 });
    const id = "10000000-0000-4000-8000-000000000020";
    const path = join(directory, `${id}.json`);
    await writeFile(path, `${JSON.stringify({ schemaVersion: 1, id, targetSessionId: "session-one" })}\n`, { mode: 0o600 });

    const store = new AutomationStore(root);
    await store.initialize();

    expect(store.status()).toMatchObject({ degraded: true, malformedRecordCount: 1, automationCount: 0 });
    expect(JSON.parse(await readFile(path, "utf8"))).toMatchObject({ schemaVersion: 1, targetSessionId: "session-one" });
  });

  it("fails closed on malformed owner state without replacing it", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-automation-malformed-"));
    const directory = join(root, "gateway", "automations");
    await mkdir(directory, { recursive: true, mode: 0o700 });
    const id = "10000000-0000-4000-8000-000000000002";
    const path = join(directory, `${id}.json`);
    await writeFile(path, "not-json\n", { mode: 0o600 });

    const store = new AutomationStore(root);
    await store.initialize();

    expect(store.status()).toMatchObject({ degraded: true, malformedRecordCount: 1, automationCount: 0 });
    expect(await readFile(path, "utf8")).toBe("not-json\n");
  });

  it("rejects permissive canonical records", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-automation-mode-"));
    const directory = join(root, "gateway", "automations");
    await mkdir(directory, { recursive: true, mode: 0o700 });
    const id = "10000000-0000-4000-8000-000000000003";
    const path = join(directory, `${id}.json`);
    await writeFile(path, "{}\n", { mode: 0o600 });
    await chmod(path, 0o644);

    const store = new AutomationStore(root);
    await store.initialize();

    expect(store.status()).toMatchObject({ degraded: true, malformedRecordCount: 1 });
  });
});
