import { createHash, randomUUID } from "node:crypto";
import { mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { waitFor } from "../../test-support/wait-for.js";
import { GatewayLogger, type LogRecord } from "../transport/logger.js";
import { logAutomationDiagnostic } from "./automation-diagnostic.js";
import { AutomationScheduler } from "./automation-scheduler.js";
import { AutomationStore } from "./automation-store.js";
import { automationOccurrenceId } from "./schedule.js";

const fixtures: Array<{ root: string; scheduler: AutomationScheduler }> = [];

afterEach(async () => {
  for (const { root, scheduler } of fixtures.splice(0)) {
    await scheduler.dispose();
    await rm(root, { recursive: true, force: true });
  }
});

describe("automation failure attribution", () => {
  it("persists distinct bounded automation and run hashes when durable claims fail", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-automation-diagnostic-"));
    const logPath = join(root, "gateway.jsonl");
    const logger = new GatewayLogger(logPath);
    const store = new AutomationStore(root);
    let admissions = 0;
    const scheduler = new AutomationScheduler(store, {
      start: async () => { admissions += 1; throw new Error("claim must fail before execution"); },
    }, {
      hostEpoch: "diagnostic-fixture",
      onDiagnostic: (message, automationId, runId) => logAutomationDiagnostic(logger, message, automationId, runId),
    });
    fixtures.push({ root, scheduler });
    await store.initialize();
    const expected: Array<{ referenceHash: string; operationHash: string }> = [];
    const rawIds: string[] = [];
    for (let index = 0; index < 2; index += 1) {
      const future = new Date(Date.now() + 60_000).toISOString();
      const record = await store.create({
        name: `Private reminder ${index}`,
        activation: "enabled",
        target: { kind: "existingSession", sessionId: `fixture-session-${index}` },
        trigger: { kind: "once", at: future },
        action: { kind: "notification", message: "Private notification content" },
        provenance: { kind: "local" },
      });
      const runId = randomUUID();
      await store.mutateState(record.id, current => ({ ...current, currentRun: {
        runId, occurrenceId: automationOccurrenceId(record.id, record.revision, future), automationRevision: record.revision,
        scheduledFor: new Date().toISOString(), createdAt: new Date().toISOString(),
        triggerSnapshot: record.trigger, actionSnapshot: record.action, targetSnapshot: record.target,
        executionSessionId: `fixture-session-${index}`, state: "queued", preAdmissionAttemptCount: 0,
      } }));
      // A real filesystem failure at the durable claim boundary, not a mocked
      // diagnostic call: neither run may reach the executor without its claim.
      const recordPath = join(root, "gateway", "automations", `${record.id}.json`);
      await rm(recordPath);
      await mkdir(recordPath);
      expected.push({
        referenceHash: createHash("sha256").update(record.id).digest("hex").slice(0, 16),
        operationHash: createHash("sha256").update(runId).digest("hex").slice(0, 16),
      });
      rawIds.push(record.id, runId);
    }
    scheduler.start();
    const records = await waitFor(async () => {
      const rows = (await readFile(logPath, "utf8").catch(() => "")).trim().split("\n")
        .filter(Boolean).map(line => JSON.parse(line) as LogRecord)
        .filter(row => row.event === "automation.dispatch-failed");
      return rows.length >= 2 ? rows : undefined;
    }, "both durable claim failures reached the Gateway log");
    scheduler.beginDrain();
    expect(admissions).toBe(0);
    for (const identity of expected) expect(records).toContainEqual(expect.objectContaining({
      event: "automation.dispatch-failed", source: "automations", level: "warning", ...identity,
    }));
    for (const row of records) {
      expect(row.referenceHash).toMatch(/^[a-f0-9]{16}$/);
      expect(row.operationHash).toMatch(/^[a-f0-9]{16}$/);
      expect(rawIds).not.toContain(row.referenceHash);
      expect(rawIds).not.toContain(row.operationHash);
      expect(row).not.toHaveProperty("automationId");
      expect(row).not.toHaveProperty("runId");
    }
  });
});
