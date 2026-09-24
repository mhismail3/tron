import { describe, expect, it } from "vitest";
import type { AdministrativeDrainBlockerSummary, AdministrativeDrainSnapshot } from "../protocol/types.js";
import { logUnresolvedDrainOwners, RestartDrainProgress } from "./restart-drain.js";

const start = "2026-01-01T00:00:00.000Z";
const baseMs = Date.parse(start);
const at = (offsetMs: number) => new Date(baseMs + offsetMs).toISOString();
const limitMs = 180_000;

function blocker(
  id: string,
  overrides: Partial<AdministrativeDrainBlockerSummary> = {},
): AdministrativeDrainBlockerSummary {
  return { id, category: "foreground-agent-operation", state: "active", admittedAt: start, progressAt: start, ...overrides };
}

function snapshot(blockers: AdministrativeDrainBlockerSummary[]): AdministrativeDrainSnapshot {
  return {
    drainId: "drain", revision: 1, phase: blockers.length ? "preparing" : "complete",
    blockerCount: blockers.length, blockerCounts: {}, blockers, omittedCount: 0, suspectProjectionCount: 0,
  };
}

describe("restart drain decisions", () => {
  it("stalls the unchanged oldest blocker at the limit despite unrelated blocker churn", () => {
    const progress = new RestartDrainProgress();
    expect(progress.evaluate(snapshot([blocker("oldest")]), baseMs, limitMs).outcome).toBe("waiting");
    expect(progress.evaluate(snapshot([
      blocker("oldest"),
      blocker("churn-1", { admittedAt: at(90_000), progressAt: at(90_000) }),
    ]), baseMs + 90_000, limitMs).outcome).toBe("waiting");
    const decision = progress.evaluate(snapshot([
      blocker("oldest"),
      blocker("churn-2", { admittedAt: at(179_000), progressAt: at(179_000) }),
    ]), baseMs + limitMs, limitMs);
    // The former global-fingerprint timer would have only 1 s since this unrelated update.
    expect(baseMs + limitMs - Date.parse(at(179_000))).toBe(1_000);
    expect(decision).toMatchObject({ outcome: "stalled", blocker: { id: "oldest", category: "foreground-agent-operation" }, ageMs: limitMs });
  });

  it("resets the bound when the oldest blocker itself reports progress", () => {
    const progress = new RestartDrainProgress();
    expect(progress.evaluate(snapshot([blocker("oldest")]), baseMs, limitMs).outcome).toBe("waiting");
    expect(progress.evaluate(snapshot([blocker("oldest", { progressAt: at(100_000) })]), baseMs + 100_000, limitMs).outcome).toBe("waiting");
    expect(progress.evaluate(snapshot([blocker("oldest", { progressAt: at(100_000) })]), baseMs + 279_999, limitMs).outcome).toBe("waiting");
    expect(progress.evaluate(snapshot([blocker("oldest", { progressAt: at(100_000) })]), baseMs + 280_000, limitMs))
      .toMatchObject({ outcome: "stalled", ageMs: limitMs });
  });

  it("proceeds immediately for only unresolved persistence owners and emits one content-free error per owner", () => {
    const owners = [
      blocker("canonical", { category: "terminal-receipt-persistence", state: "suspect", sessionId: "session-a", progressAt: undefined }),
      blocker("extension", { category: "terminal-receipt-persistence", state: "suspect", sessionId: "session-b", progressAt: undefined }),
    ];
    const decision = new RestartDrainProgress().evaluate(snapshot(owners), baseMs + 1_000, limitMs);
    expect(decision).toEqual({ outcome: "unresolved-owners", owners });
    const records: Array<{ sessionId: string; category: string }> = [];
    if (decision.outcome === "unresolved-owners") {
      logUnresolvedDrainOwners(decision.owners, (sessionId, category) => records.push({ sessionId, category }));
    }
    expect(records).toEqual([
      { sessionId: "session-a", category: "terminal-receipt-persistence" },
      { sessionId: "session-b", category: "terminal-receipt-persistence" },
    ]);
  });

  it("waits when unresolved owners coexist with active work", () => {
    const progress = new RestartDrainProgress();
    const owners = blocker("owner", {
      category: "terminal-receipt-persistence", state: "suspect", sessionId: "session-a",
      admittedAt: at(10_000), progressAt: undefined,
    });
    const live = blocker("live");
    expect(progress.evaluate(snapshot([owners, live]), baseMs, limitMs).outcome).toBe("waiting");
    expect(progress.evaluate(snapshot([owners, live]), baseMs + 179_999, limitMs).outcome).toBe("waiting");
    expect(progress.evaluate(snapshot([owners, live]), baseMs + limitMs, limitMs)).toMatchObject({ outcome: "stalled", blocker: { id: "live" } });
  });

  it("judges a detached extension blocker from admission despite unrelated churn", () => {
    const progress = new RestartDrainProgress();
    const detached = blocker("detached", {
      category: "detached-extension-run", progressAt: undefined, admittedAt: start,
    });
    expect(progress.evaluate(snapshot([detached]), baseMs, limitMs).outcome).toBe("waiting");
    expect(progress.evaluate(snapshot([
      detached,
      blocker("new", { admittedAt: at(150_000), progressAt: at(150_000) }),
    ]), baseMs + limitMs, limitMs)).toMatchObject({ outcome: "stalled", blocker: { id: "detached" }, ageMs: limitMs });
  });

  it("completes a healthy drain without changing the stall outcome", () => {
    expect(new RestartDrainProgress().evaluate(snapshot([]), baseMs + limitMs, limitMs)).toEqual({ outcome: "completed" });
  });
});
