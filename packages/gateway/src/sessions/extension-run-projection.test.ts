import { describe, expect, it } from "vitest";
import { projectExtensionRunActivity } from "./extension-run-projection.js";

const base = {
  id: "tool-call",
  toolCallId: "tool-call",
  source: { source: "pi-subagents" },
  title: "subagent",
  status: "running" as const,
  startedAt: "2026-01-01T00:00:00.000Z",
  updatedAt: "2026-01-01T00:00:02.000Z",
};

describe("projectExtensionRunActivity", () => {
  it("projects structured child progress without exposing runner paths", () => {
    const activity = projectExtensionRunActivity({
      details: {
        mode: "single",
        runId: "run-1",
        results: [{
          agent: "reviewer",
          progress: {
            status: "running",
            lastActivityAt: 1_700_000_000_000,
            currentTool: "read",
            currentToolStartedAt: 1_700_000_001_000,
            currentPath: "/private/project/file.swift",
            toolCount: 4,
            turnCount: 2,
            durationMs: 12_500,
            recentOutput: ["first", "latest"],
          },
          sessionFile: "/private/project/session.jsonl",
        }],
      },
    }, base);

    expect(activity).toMatchObject({
      runId: "run-1",
      mode: "single",
      toolCount: 4,
      turnCount: 2,
      durationMs: 12_500,
      currentTool: "read",
      currentPath: "file.swift",
      children: [{ label: "reviewer", status: "running", toolCount: 4, currentPath: "file.swift" }],
    });
    expect(JSON.stringify(activity)).not.toContain("sessionFile");
  });

  it("keeps detached async work live after the launching tool returns", () => {
    const activity = projectExtensionRunActivity({
      details: { mode: "single", asyncId: "async-1", results: [] },
    }, {
      ...base,
      status: "completed",
      completedAt: "2026-01-01T00:00:03.000Z",
    });
    expect(activity.status).toBe("running");
    expect(activity.completedAt).toBeUndefined();
    expect(activity.runId).toBe("async-1");
  });

  it("does not resurrect a terminal activity from a late async acknowledgement", () => {
    const activity = projectExtensionRunActivity({
      details: { mode: "single", asyncId: "async-1", results: [] },
    }, {
      ...base,
      status: "running",
      completedAt: "2026-01-01T00:00:03.000Z",
      previous: {
        ...base,
        status: "completed",
        completedAt: "2026-01-01T00:00:03.000Z",
      },
    });
    expect(activity).toMatchObject({ status: "completed", completedAt: "2026-01-01T00:00:03.000Z" });
  });

  it("keeps the real tool-call identity when a runId arrives in a terminal result", () => {
    const activity = projectExtensionRunActivity({
      details: { runId: "run-1", state: "completed", results: [] },
    }, {
      ...base,
      id: "pi-tool-call-1",
      toolCallId: "pi-tool-call-1",
      status: "completed",
      completedAt: "2026-01-01T00:00:03.000Z",
    });
    expect(activity).toMatchObject({
      id: "pi-tool-call-1",
      toolCallId: "pi-tool-call-1",
      runId: "run-1",
      status: "completed",
      completedAt: "2026-01-01T00:00:03.000Z",
    });
  });

  it("drops unsafe numeric fields instead of breaking native integer decoding", () => {
    const activity = projectExtensionRunActivity({
      details: {
        progress: [{ toolCount: 1e100, durationMs: 1e100, lastActivityAt: 1e100 }],
      },
    }, base);
    expect(activity.toolCount).toBeUndefined();
    expect(activity.durationMs).toBeUndefined();
    expect(activity.lastActivityAt).toBeUndefined();
  });

  it("projects async workflow steps from the lifecycle artifact shape", () => {
    const activity = projectExtensionRunActivity({
      runId: "workflow-1",
      mode: "workflow",
      state: "running",
      steps: [
        { agent: "reviewer", status: "running", description: "Inspect the projection", recentOutput: ["read complete"], currentTool: "read", toolCount: 3, turnCount: 2 },
        { agent: "scout", status: "completed", durationMs: 1_200 },
      ],
    }, base);
    expect(activity).toMatchObject({
      runId: "workflow-1",
      mode: "workflow",
      children: [
        { label: "reviewer", status: "running", task: "Inspect the projection", output: "read complete", currentTool: "read", toolCount: 3 },
        { label: "scout", status: "completed", durationMs: 1_200 },
      ],
    });
  });

  it("keeps a generic extension activity when details are not structured", () => {
    const activity = projectExtensionRunActivity(undefined, base);
    expect(activity).toMatchObject({
      id: "tool-call",
      toolCallId: "tool-call",
      source: { source: "pi-subagents" },
      status: "running",
      children: [],
    });
  });

  it("retains the last structured values when a terminal result omits progress", () => {
    const running = projectExtensionRunActivity({
      details: {
        mode: "single",
        runId: "run-1",
        results: [{ agent: "worker", progress: { toolCount: 3, durationMs: 900 } }],
      },
    }, base);
    const completed = projectExtensionRunActivity({ details: { runId: "run-1" } }, {
      ...base,
      status: "completed",
      updatedAt: "2026-01-01T00:00:03.000Z",
      completedAt: "2026-01-01T00:00:03.000Z",
      durationMs: 1_200,
      previous: running,
    });

    expect(completed.status).toBe("completed");
    expect(completed.runId).toBe("run-1");
    expect(completed.children[0]?.toolCount).toBe(3);
    expect(completed.durationMs).toBe(1_200);
  });
});
