import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, expect, it } from "vitest";
import { disposeFixtures, fixture } from "../../../test-support/home-task-fixture.js";
import { startScriptedChild, type ChildModelServer } from "../../../test-support/home-task-subagent-child.js";
import { waitFor } from "../../../test-support/wait-for.js";
import { ProcessTranscriptLeaseStore } from "../../transport/process-transcript-leases.js";

const servers: ChildModelServer[] = [];
afterEach(async () => {
  for (const server of servers.splice(0)) await server.close();
  await disposeFixtures();
});

/** Real Registry/Pi, managed producer, child process, canonical child admission
 * and Transport lease store. The child model holds its HTTP connection until
 * the real producer stops it; no controller/runtime/store replacement. */
it("stops only the exact connection-owned child transcript through the K5 run owner", async () => {
  const f = await fixture(false, false, undefined, true);
  const server = await startScriptedChild(f);
  servers.push(server);
  f.faux.setResponses([
    fauxAssistantMessage([fauxToolCall("subagent", {
      agent: "task-child", task: "HOLD-CHILD transcript lease stop", async: true,
    }, { id: "transcript-child" })], { stopReason: "toolUse" }),
    fauxAssistantMessage("The child is running."),
    fauxAssistantMessage("The child stopped."),
  ]);
  const slot = await f.registry.create(f.cwd);
  const leases = new ProcessTranscriptLeaseStore(f.registry);
  try {
    await slot.prompt("Start the child for transcript viewing.");
    await waitFor(() => server.heldRequests() > 0
      && slot.snapshot().processActivities?.some(row => row.kind === "subagent" && row.childSessionRef !== undefined) === true,
    "a live child with canonical transcript ownership", { boundMs: 30_000 });
    const process = slot.snapshot().processActivities!.find(row => row.kind === "subagent" && row.childSessionRef !== undefined)!;
    const binding = slot.processChildSessionPath(process.processId)!;
    const authority = slot.ownedTurns.processSubagentAbortAuthority(process.processId, process.runId!);
    expect(authority).toBeDefined();
    const lease = await leases.open("viewer-client", slot.id, process.processId,
      process.childSessionRef!, process.runId!, binding.path, () => {}, authority,
      { viewerId: "child-viewer", parentSubscriptionToken: "parent-presentation" });
    expect(lease.canAbort).toBe(true);
    await expect(leases.abortOwned("foreign-client", lease.leaseId)).rejects.toMatchObject({ code: "not_found" });
    expect(server.abortedRequests()).toBe(0);
    await leases.abortOwned("viewer-client", lease.leaseId);
    await waitFor(() => server.abortedRequests() > 0 && !slot.catalogHasActiveSubagents,
      "the owned child model connection to close and its process to settle", { boundMs: 30_000 });
    expect(slot.ownedTurns.liveSubagentRuns()).toEqual([]);
    const artifacts = join(globalThis.process.cwd(), "test-results");
    await mkdir(artifacts, { recursive: true });
    await writeFile(join(artifacts, "process-transcript-stop.json"), JSON.stringify({
      boundary: "ProcessTranscriptLeaseStore -> existing K5 OwnedTurnOwner -> real managed child",
      heldRequests: server.heldRequests(), abortedRequests: server.abortedRequests(),
      foreignConnectionRejected: true, liveRunsAfterStop: slot.ownedTurns.liveSubagentRuns().length,
    }, null, 2) + "\n");
  } finally {
    leases.releaseClient("viewer-client");
  }
});
