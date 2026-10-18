import { createHash, randomUUID } from "node:crypto";
import { mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { waitFor } from "../../test-support/wait-for.js";
import { GatewayLogger, type LogRecord } from "../transport/logger.js";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider } from "@earendil-works/pi-ai";
import { initializeRegistry } from "../../test-support/runtime-registry-fixture.js";
import { TrustService } from "../admin/trust-service.js";
import { RuntimeRegistry } from "../sessions/runtime-registry.js";
import { GatewayAutomationExecutor } from "./automation-executor.js";
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

describe("automation cancellation ownership", () => {
  it("cancels a reserved queued run before its durable claim can admit a canonical prompt", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-automation-claim-cancel-"));
    const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
    let scheduler: AutomationScheduler | undefined;
    let registry: RuntimeRegistry | undefined;
    try {
      const agentDir = join(root, "agent");
      const cwd = join(root, "workspace");
      await mkdir(cwd, { recursive: true });
      process.env.PI_CODING_AGENT_DIR = agentDir;
      const faux = fauxProvider({ provider: "automation-cancel-fixture", tokensPerSecond: 100_000 });
      faux.setResponses([fauxAssistantMessage("baseline settled"), fauxAssistantMessage("next prompt settled")]);
      registry = new RuntimeRegistry({
        agentDir, tronHome: root, idleRuntimeMs: 60_000, trust: new TrustService(agentDir),
        modelRuntimeFactory: async () => {
          const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
          runtime.registerNativeProvider(faux.provider);
          return runtime;
        },
        broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
      });
      await initializeRegistry(registry);
      const slot = await registry.create(cwd);
      await slot.setModel(faux.models[0]!.provider, faux.models[0]!.id);
      await slot.prompt("baseline control");
      await waitFor(() => slot.catalogPhase === "idle", "the real baseline turn to settle");
      const sessionFile = slot.sessionFile!;
      const userMessages = async () => (await readFile(sessionFile, "utf8")).trim().split("\n")
        .map(line => JSON.parse(line) as { type: string; message?: { role: string; content: Array<{ text?: string }> } })
        .filter(entry => entry.type === "message" && entry.message?.role === "user")
        .map(entry => entry.message!.content.map(part => part.text ?? "").join(""));
      expect(await userMessages()).toEqual(["baseline control"]);

      const store = new AutomationStore(root);
      await store.initialize();
      const text = "cancelled automation must not enter canonical context";
      const definition = await store.create({
        name: "Claim cancellation", activation: "paused",
        target: { kind: "existingSession", sessionId: slot.id },
        trigger: { kind: "once", at: new Date(Date.now() + 86_400_000).toISOString() },
        action: { kind: "sessionPrompt", text }, provenance: { kind: "local" },
      });
      scheduler = new AutomationScheduler(store,
        new GatewayAutomationExecutor(registry, registry.administrativeWorkRegistry, undefined, undefined),
        { hostEpoch: registry.administrativeWorkRegistry.runtimeEpoch });
      scheduler.start();
      const run = await scheduler.runNow(definition.id, definition.revision);
      await scheduler.scan();
      // The public scan joins selection, not the asynchronous durable claim.
      // This is the owned-but-still-queued window, without a private delay hook.
      expect(scheduler.hasSessionRun(slot.id)).toBe(true);
      expect(store.get(definition.id).currentRun).toMatchObject({ runId: run.runId, state: "queued" });
      await expect(scheduler.cancel(definition.id, run.runId)).resolves.toMatchObject({ state: "cancelled", reason: "user-cancelled" });
      await scheduler.dispose();
      expect(await userMessages()).toEqual(["baseline control"]);
      expect(scheduler.hasSessionRun(slot.id)).toBe(false);
      expect(registry.administrativeWorkRegistry.size).toBe(0);
      expect(slot.isEvictionProtected).toBe(false);
      const reopened = new AutomationStore(root);
      await reopened.initialize();
      expect(reopened.get(definition.id).lastRun).toMatchObject({ runId: run.runId, state: "cancelled", reason: "user-cancelled" });
      expect(reopened.get(definition.id).currentRun).toBeUndefined();
      await slot.prompt("next explicit control");
      await waitFor(() => slot.catalogPhase === "idle", "the explicit successor turn to settle");
      expect(await userMessages()).toEqual(["baseline control", "next explicit control"]);
    } finally {
      await scheduler?.cancelActiveForShutdown();
      await scheduler?.dispose();
      await registry?.dispose();
      if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
      else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
      await rm(root, { recursive: true, force: true });
    }
  });
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
      expect(row).not.toHaveProperty("automationId");
      expect(row).not.toHaveProperty("runId");
    }
  });
});
