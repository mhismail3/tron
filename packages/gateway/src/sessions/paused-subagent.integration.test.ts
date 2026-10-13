import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { afterAll, afterEach, expect, it, vi } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import type { ExtensionToolOrigin, SessionProcessActivity, SessionSummaryUpdate } from "../protocol/types.js";
import { RuntimeRegistry } from "./runtime-registry.js";
import type { RuntimeSlot } from "./runtime-slot.js";
import { waitFor } from "../../test-support/wait-for.js";

/** Retained, regenerable evidence for one run of this file. The path is stable
 * and gitignored, so an operator can inspect exactly which lifecycle facts the
 * real artifact projection published for a paused or rediscovered subagent. */
const REPORT_PATH = join(process.cwd(), "test-results", "paused-subagent.integration.json");
const report: {
  generatedAt: string;
  stages: Array<{ stage: string; facts: Record<string, unknown> }>;
} = { generatedAt: new Date().toISOString(), stages: [] };

function record(stage: string, facts: Record<string, unknown>): void {
  report.stages.push({ stage, facts });
}

afterAll(async () => {
  await mkdir(dirname(REPORT_PATH), { recursive: true });
  await writeFile(REPORT_PATH, `${JSON.stringify(report, null, 2)}\n`, "utf8");
});

const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
const registries: RuntimeRegistry[] = [];
const roots: string[] = [];

afterEach(async () => {
  vi.restoreAllMocks();
  await Promise.allSettled(registries.splice(0).map((registry) => registry.dispose()));
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
  if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
  else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
});

const PROVIDER_ORIGIN: ExtensionToolOrigin = {
  source: "pi-subagents",
  owner: { id: "installed-provider", title: "Subagents", source: "npm:pi-subagents" },
};

interface Fixture {
  cwd: string;
  slot: RuntimeSlot;
  manager: SessionManager;
  summaries: SessionSummaryUpdate[];
  latestSummary(): SessionSummaryUpdate | undefined;
}

async function pausedFixture(label: string): Promise<Fixture> {
  const root = await mkdtemp(join(tmpdir(), `tron-paused-subagent-${label}-`));
  roots.push(root);
  const agentDir = join(root, "agent");
  const cwd = join(root, "workspace");
  const sessionDirectory = join(agentDir, "sessions", "workspace");
  await Promise.all([mkdir(sessionDirectory, { recursive: true }), mkdir(cwd, { recursive: true })]);
  process.env.PI_CODING_AGENT_DIR = agentDir;
  const manager = SessionManager.create(cwd, sessionDirectory);
  manager.appendMessage(fauxAssistantMessage(`paused subagent ${label}`));
  const summaries: SessionSummaryUpdate[] = [];
  const registry = new RuntimeRegistry({
    agentDir,
    tronHome: join(root, "tron"),
    idleRuntimeMs: 60_000,
    modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
    trust: new TrustService(agentDir),
    broadcast: () => {},
    sessionSummaryChanged: (summary) => summaries.push(summary),
    sessionListChanged: () => {},
  });
  registries.push(registry);
  await registry.initialize();
  await registry.recoverCanonicalAttention();
  const slot = await registry.acquire(manager.getSessionId());
  return {
    cwd,
    slot,
    manager,
    summaries,
    latestSummary: () => [...summaries].reverse().find((summary) => summary.sessionId === manager.getSessionId()),
  };
}

function processRows(slot: RuntimeSlot): SessionProcessActivity[] {
  return slot.snapshot().processActivities ?? [];
}

/** The exact producer shape of one paused async workflow: a launcher tool
 * result proves ownership, and `status.json` plus the `process-terminal.json`
 * sidecar carry the lifecycle the Gateway projects. */
it("settles a paused subagent row as recent only after the observed process-terminal proof", async () => {
  const fixture = await pausedFixture("settlement");
  const { slot, manager } = fixture;
  const runId = "paused-run";
  const toolCallId = "paused-tool";
  const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", "run-1");
  await mkdir(asyncDir, { recursive: true });
  const internal = slot as unknown as {
    subagentExtensionOrigin: () => ExtensionToolOrigin;
    extensionToolOrigin: (toolName: string) => ExtensionToolOrigin | undefined;
  };
  vi.spyOn(internal, "subagentExtensionOrigin").mockReturnValue(PROVIDER_ORIGIN);
  vi.spyOn(internal, "extensionToolOrigin").mockReturnValue(PROVIDER_ORIGIN);

  const started = Date.now() - 60_000;
  const childEndedAt = started + 30_000;
  const proofObservedAt = started + 35_000;
  // Canonical launch evidence lives in the slot's own session manager, the
  // owner of the JSONL the projection reads.
  const slotManager = (slot as unknown as { runtime: { session: { sessionManager: SessionManager } } })
    .runtime.session.sessionManager;
  const launch = (toolCall: string, run: string, directory: string) => slotManager.appendMessage({
    role: "toolResult",
    toolCallId: toolCall,
    toolName: "subagent",
    content: [{ type: "text", text: "launched" }],
    details: { runId: run, asyncId: run, asyncDir: directory, mode: "single", results: [] },
    isError: false,
    timestamp: Date.now(),
  });
  launch(toolCallId, runId, asyncDir);

  const writeStatus = (state: "running" | "paused", lastUpdate: number, stepState: "running" | "paused") => writeFile(
    join(asyncDir, "status.json"),
    JSON.stringify({
      lifecycleArtifactVersion: 3,
      runId,
      mode: "async",
      state,
      startedAt: started,
      lastUpdate,
      ...(state === "paused" ? { endedAt: childEndedAt } : {}),
      // The producer keeps counting its own elapsed time while a run is paused.
      durationMs: lastUpdate - started,
      steps: [{
        index: 0,
        agent: "worker",
        workflowKey: "worker-1",
        runId: "worker-run-1",
        status: stepState,
        startedAt: started,
        endedAt: childEndedAt,
        durationMs: childEndedAt - started,
      }],
    }),
  );
  const writeProof = (state: "observed" | "pending") => writeFile(
    join(asyncDir, "process-terminal.json"),
    JSON.stringify({
      version: 1,
      state,
      runId,
      runnerProcessInstanceId: "runner-instance",
      ...(state === "observed" ? {
        observedAt: proofObservedAt,
        instances: [
          { kind: "runner", processInstanceId: "runner-instance", closeObservedAt: proofObservedAt, exitCode: 0, signal: null },
          {
            kind: "pi-writer",
            processInstanceId: "writer-instance",
            closeObservedAt: proofObservedAt,
            exitCode: 0,
            signal: null,
            attempt: 0,
            processTree: { state: "observed", mechanism: "posix-process-group", processGroupId: 4_242, verifiedAt: proofObservedAt },
          },
        ],
      } : {}),
    }),
  );

  await writeStatus("running", started + 5_000, "running");
  await slot.discoverExtensionArtifact(asyncDir);
  const liveRow = processRows(slot).find((row) => row.title === "worker");
  expect(liveRow).toBeDefined();
  expect(liveRow!.lifecycle).toMatchObject({ state: "running" });
  expect(liveRow!.visibility).toBe("active");
  record("running", { row: liveRow!, overview: slot.snapshot().processOverview });

  // Winding down: paused without the proof owns no settlement fact yet.
  await writeStatus("paused", childEndedAt + 1_000, "paused");
  await writeProof("pending");
  await slot.discoverExtensionArtifact(asyncDir);
  const windingDown = processRows(slot).find((row) => row.processId === liveRow!.processId)!;
  expect(windingDown.lifecycle.state).toBe("paused");
  expect(windingDown.lifecycle.terminalAt).toBeUndefined();
  expect(windingDown.visibility).toBe("active");
  expect(slot.snapshot().processOverview).toMatchObject({ activeCount: 1, recentCount: 0 });
  await waitFor(() => fixture.latestSummary()?.hasActiveSubagents === true, "active subagent summary");
  record("paused-without-proof", {
    row: windingDown,
    overview: slot.snapshot().processOverview,
    drainBlockers: slot.administrativeDrainBlockers(),
    hasActiveSubagents: fixture.latestSummary()?.hasActiveSubagents,
  });

  // Settled: the exact-owned proof has observed every paused process exit.
  await writeProof("observed");
  await slot.discoverExtensionArtifact(asyncDir);
  const settled = processRows(slot).find((row) => row.processId === liveRow!.processId)!;
  const terminalAt = new Date(proofObservedAt).toISOString();
  expect(settled.lifecycle.state).toBe("paused");
  expect(settled.lifecycle.terminalAt).toBe(terminalAt);
  expect(settled.lifecycle.recentUntil).toBe(new Date(proofObservedAt + 5 * 60_000).toISOString());
  expect(settled.visibility).toBe("recent");
  // Frozen at the Gateway-observed settlement instant, never the producer's
  // still-counting elapsed counter.
  expect(settled.durationMs).toBe(proofObservedAt - started);
  expect(slot.snapshot().processOverview).toMatchObject({ activeCount: 0, recentCount: 1 });
  expect(slot.administrativeDrainBlockers().some((fact) => fact.category === "detached-extension-run")).toBe(false);
  await waitFor(() => fixture.latestSummary()?.hasActiveSubagents === false, "settled subagent summary");
  record("settled-paused", {
    row: settled,
    overview: slot.snapshot().processOverview,
    drainBlockers: slot.administrativeDrainBlockers(),
    hasActiveSubagents: fixture.latestSummary()?.hasActiveSubagents,
  });

  // A resume is a new run id: it appears as its own active row and the settled
  // paused row keeps the exact facts it already published.
  const replacementRunId = "resumed-run";
  const replacementToolCallId = "resumed-tool";
  const replacementDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", "run-2");
  await mkdir(replacementDir, { recursive: true });
  launch(replacementToolCallId, replacementRunId, replacementDir);
  await writeFile(join(replacementDir, "status.json"), JSON.stringify({
    lifecycleArtifactVersion: 3,
    runId: replacementRunId,
    mode: "async",
    state: "running",
    startedAt: proofObservedAt + 1_000,
    lastUpdate: proofObservedAt + 2_000,
    durationMs: 1_000,
    steps: [{
      index: 0,
      agent: "worker",
      workflowKey: "worker-1",
      runId: "worker-run-2",
      status: "running",
      startedAt: proofObservedAt + 1_000,
    }],
  }));
  await slot.discoverExtensionArtifact(replacementDir);
  const resumed = processRows(slot).find((row) => row.runId === replacementRunId);
  const unchanged = processRows(slot).find((row) => row.processId === settled.processId)!;
  expect(resumed).toBeDefined();
  expect(resumed!.processId).not.toBe(settled.processId);
  expect(resumed!.visibility).toBe("active");
  expect(unchanged.lifecycle).toMatchObject({ state: "paused", terminalAt });
  expect(unchanged.durationMs).toBe(settled.durationMs);
  expect(slot.snapshot().processOverview).toMatchObject({ activeCount: 1, recentCount: 1 });
  record("resumed-run", {
    resumedRow: resumed!,
    settledRow: unchanged,
    overview: slot.snapshot().processOverview,
  });
});

/** A Gateway restart or a slot reload rediscovers runs that finished long ago.
 * Their terminal instant is the producer's recorded end, never the moment the
 * Gateway happened to read the artifact: otherwise every old run returns as
 * "recent" with a duration that counts from its start to now. */
it("keeps a rediscovered terminal run's own end instant, so an old run does not return as recent", async () => {
  const fixture = await pausedFixture("rediscovery");
  const { slot } = fixture;
  const internal = slot as unknown as {
    subagentExtensionOrigin: () => ExtensionToolOrigin;
    extensionToolOrigin: (toolName: string) => ExtensionToolOrigin | undefined;
  };
  vi.spyOn(internal, "subagentExtensionOrigin").mockReturnValue(PROVIDER_ORIGIN);
  vi.spyOn(internal, "extensionToolOrigin").mockReturnValue(PROVIDER_ORIGIN);
  const slotManager = (slot as unknown as { runtime: { session: { sessionManager: SessionManager } } })
    .runtime.session.sessionManager;

  const cases = [
    { label: "old", runId: "old-failed-run", startedAt: Date.now() - 3 * 24 * 60 * 60_000 },
    { label: "recent", runId: "recent-failed-run", startedAt: Date.now() - 60_000 },
  ];
  for (const { label, runId, startedAt } of cases) {
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", label);
    await mkdir(asyncDir, { recursive: true });
    slotManager.appendMessage({
      role: "toolResult",
      toolCallId: `${label}-tool`,
      toolName: "subagent",
      content: [{ type: "text", text: "launched" }],
      details: { runId, asyncId: runId, asyncDir, mode: "single", results: [] },
      isError: false,
      timestamp: startedAt,
    });
    // The producer's shape for a workflow that failed 28 ms after launch.
    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3,
      runId,
      mode: "async",
      state: "failed",
      startedAt,
      lastUpdate: startedAt + 29,
      endedAt: startedAt + 28,
      error: "SyntaxError: Unexpected token",
      steps: [{ index: 0, agent: "worker", workflowKey: "worker-1", runId: `${runId}-child`, status: "failed",
        startedAt, endedAt: startedAt + 28, durationMs: 28 }],
    }));
    await slot.discoverExtensionArtifact(asyncDir);
  }

  const activities = slot.snapshot().extensionActivities ?? [];
  const rows = processRows(slot);
  for (const { runId, startedAt } of cases) {
    const endedAt = new Date(startedAt + 28).toISOString();
    const activity = activities.find((item) => item.runId === runId);
    if (activity) expect(activity.lifecycle?.terminalAt).toBe(endedAt);
    const row = rows.find((item) => item.runId === runId);
    if (row) {
      expect(row.lifecycle.terminalAt).toBe(endedAt);
      expect(row.durationMs).toBe(28);
    }
  }
  const old = rows.find((row) => row.runId === "old-failed-run");
  const recent = rows.find((row) => row.runId === "recent-failed-run");
  // The run that ended a minute ago is still recent; the three-day-old one is not.
  expect(recent?.visibility).toBe("recent");
  expect(old === undefined || old.visibility !== "recent").toBe(true);
  expect(activities.find((item) => item.runId === "old-failed-run")?.visibility === "current").toBe(false);
  record("rediscovered-terminal", {
    rows: rows.filter((row) => row.runId === "old-failed-run" || row.runId === "recent-failed-run"),
    activities: activities.filter((item) => item.runId === "old-failed-run" || item.runId === "recent-failed-run"),
  });
});
