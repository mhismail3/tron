import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { fixture } from "../../../../test-support/home-task-fixture.js";
import { waitFor } from "../../../../test-support/wait-for.js";
import { closeSubagentFixtures, bound, childModel, holdingAsyncLaunch } from "../../../../test-support/home-task-subagents-support.js";
import { GatewayLogger } from "../../../transport/logger.js";
import { waitForStopDrain } from "../../../sessions/restart-drain.js";

// #2256: liveness comes from the installed delegated provider, not result shape. A
// real managed async run must still hold the intentional stop until it settles, and
// the stop must name it in gateway.jsonl while it waits.

const roots: string[] = [];
afterEach(async () => {
  await closeSubagentFixtures();
  for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true });
});

type LogRecord = { event?: string; message?: string; timestamp: string };
async function records(path: string): Promise<LogRecord[]> {
  const text = await readFile(path, "utf8").catch(() => "");
  return text.split("\n").filter(Boolean).map(line => JSON.parse(line) as LogRecord);
}

describe("Managed subagents: intentional stop drain", () => {
  it("a live managed async run blocks the stop, is named in gateway.jsonl within one interval, and the stop completes after it settles", async () => {
    const f = await fixture(false, false, undefined, true);
    const child = await childModel(f);
    // An ordinary session's own managed async run, so the run is the only accepted work.
    f.faux.setResponses([
      holdingAsyncLaunch("async-launch"),
      fauxAssistantMessage("Launched the background check."),
      fauxAssistantMessage("The background check finished."),
    ]);
    const slot = await f.registry.create(f.cwd);
    await slot.prompt("Run the background check.");
    await waitFor(() => child.heldRequests() === 1, "async child live", bound);
    await waitFor(() => slot.administrativeDrainBlockers().length === 1, "the run is the only blocker", bound);
    expect(slot.administrativeDrainBlockers()).toEqual([expect.objectContaining({ category: "detached-extension-run", state: "active" })]);

    const root = await mkdtemp(join(tmpdir(), "tron-2256-stop-drain-"));
    roots.push(root);
    const logPath = join(root, "gateway.jsonl");
    const intervalMs = 200;
    const startedAt = Date.now();
    let settled = false;
    const drain = waitForStopDrain(f.registry, new GatewayLogger(logPath), intervalMs).finally(() => { settled = true; });
    await waitFor(async () => (await records(logPath)).some(record => record.event === "gateway.stop-drain.waiting"), "the stop names its blockers", bound);
    const [first] = (await records(logPath)).filter(record => record.event === "gateway.stop-drain.waiting");
    expect(Date.parse(first!.timestamp) - startedAt).toBeLessThan(intervalMs + 1_000);
    const named = JSON.parse(first!.message!.slice(first!.message!.indexOf("["))) as Array<Record<string, unknown>>;
    expect(named).toContainEqual(expect.objectContaining({ sessionId: slot.id, category: "detached-extension-run", state: "active", ageMs: expect.any(Number) }));
    // Accepted work that is still progressing is never cut: the stop keeps waiting.
    await waitFor(async () => (await records(logPath)).filter(record => record.event === "gateway.stop-drain.waiting").length >= 2, "a second waiting record on the cadence", bound);
    expect(settled).toBe(false);

    child.releaseHeld();
    const final = await drain;
    const waiting = (await records(logPath)).filter(record => record.event === "gateway.stop-drain.waiting");
    await mkdir("test-results/2256", { recursive: true });
    await writeFile("test-results/2256/managed-run-stop-drain.json", JSON.stringify({ waiting, final }, null, 2));
    expect(final).toMatchObject({ phase: "complete", blockerCount: 0 });
    expect(slot.administrativeDrainBlockers()).toEqual([]);
  }, 60_000);
});
