import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { expect, it } from "vitest";
import { HomeTaskReportOwner } from "./home-task-report.js";

// Isolated failure modes: same stable ID overwrites evidence, conflicting ID is
// admitted after sealing, invalid/oversized payload appends canonical evidence.
it("accepts one immutable canonical report, reuses an exact duplicate and refuses conflicting or oversized reports", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-task-report-"));
  try {
    const manager = SessionManager.create(root, root);
    const owner = new HomeTaskReportOwner({ taskId: "task", intentRevision: 1, homeId: "home", generation: 1, operationId: "operation" });
    const request = { resultId: "result", outcome: "final" as const, text: "verified", evidence: ["acceptance proof"] };
    const append = async (data: any) => manager.appendCustomEntry("tron-home-task-report", data);
    const entryId = await owner.accept(manager.getSessionId(), "operation", request, append);
    expect(await owner.accept(manager.getSessionId(), "operation", request, append)).toBe(entryId);
    for (const change of [{ text: "changed" }, { resultId: "other" }]) {
      await expect(owner.accept(manager.getSessionId(), "operation", { ...request, ...change }, append)).rejects.toThrow();
    }
    await expect(owner.accept(manager.getSessionId(), "stale-operation", request, append)).rejects.toThrow();
    expect(manager.getBranch().filter(entry => entry.type === "custom")).toHaveLength(1);
  } finally { await rm(root, { recursive: true, force: true }); }
});

it("rejects oversized UTF-8 and malformed reports before any canonical append", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-task-report-invalid-"));
  try {
    const manager = SessionManager.create(root, root);
    const owner = new HomeTaskReportOwner({ taskId: "task", intentRevision: 1, homeId: "home", generation: 1, operationId: "operation" });
    const request = { resultId: "result", outcome: "final", text: "verified", evidence: [] };
    for (const change of [{ text: "é".repeat(32769) }, { evidence: ["x".repeat(4097)] }, { outcome: "succeeded" }, { unexpected: true }]) {
      await expect(owner.accept(manager.getSessionId(), "operation", { ...request, ...change }, async report => manager.appendCustomEntry("tron-home-task-report", report))).rejects.toThrow();
      expect(manager.getBranch().filter(entry => entry.type === "custom")).toHaveLength(0);
    }
  } finally { await rm(root, { recursive: true, force: true }); }
});
