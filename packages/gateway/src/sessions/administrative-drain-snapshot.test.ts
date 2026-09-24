import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it } from "vitest";
import { GatewayWorkRegistry } from "./gateway-work-registry.js";
import { RuntimeRegistry } from "./runtime-registry.js";
import { TrustService } from "../admin/trust-service.js";

let root: string | undefined;
afterEach(async () => {
  if (root) await rm(root, { recursive: true, force: true });
  root = undefined;
});

// Regression: a restart drain once waited on eight "completion receipts" that
// were in fact whole receipt-backed RPCs (for example a compaction). The drain
// must name an executing request and its method.
it("names an executing receipt-backed request and its method as a drain blocker", async () => {
  root = await mkdtemp(join(tmpdir(), "tron-drain-snapshot-"));
  const agentDir = join(root, "agent");
  const workRegistry = new GatewayWorkRegistry("epoch", 8);
  const registry = new RuntimeRegistry({
    agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, workRegistry,
    trust: new TrustService(agentDir), broadcast: () => {},
    sessionSummaryChanged: () => {}, sessionListChanged: () => {},
  });
  const request = workRegistry.begin({ kind: "rpc-mutation", method: "session.compact", sessionId: "session-1", hostEpoch: "epoch" });
  const receipt = workRegistry.beginDerived({ kind: "terminal-receipt-persistence", sessionId: "session-1", hostEpoch: "epoch" });

  const snapshot = registry.beginAdministrativeDrain();
  expect(snapshot.blockerCounts).toEqual({ "rpc-mutation": 1, "terminal-receipt-persistence": 1 });
  expect(snapshot.blockers).toEqual(expect.arrayContaining([
    expect.objectContaining({ category: "rpc-mutation", method: "session.compact", sessionId: "session-1", state: "active" }),
    expect.objectContaining({ category: "terminal-receipt-persistence", sessionId: "session-1", state: "settling" }),
  ]));
  expect(snapshot.blockers.find((blocker) => blocker.category === "terminal-receipt-persistence")).not.toHaveProperty("method");
  request.settle();
  receipt.settle();
  expect(registry.administrativeDrainSnapshot().blockerCount).toBe(0);
});
