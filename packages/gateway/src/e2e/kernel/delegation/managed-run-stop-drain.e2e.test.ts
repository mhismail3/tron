import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { dispatch, fixture } from "../../../../test-support/home-task-fixture.js";
import { waitFor } from "../../../../test-support/wait-for.js";
import { closeSubagentFixtures, bound, childModel, holdingAsyncLaunch, waitBetweenTurns } from "../../../../test-support/home-task-subagents-support.js";
import { GatewayLogger } from "../../../transport/logger.js";
import { RestartDrainProgress, waitForStopDrain } from "../../../sessions/restart-drain.js";

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

  it("a live Home task waiting on its async run holds the stop, is named on its worker session, and the stop completes after the task settles (#2259)", async () => {
    const f = await fixture(false, false, undefined, true);
    const child = await childModel(f);
    f.faux.setResponses([
      holdingAsyncLaunch("async-launch"),
      fauxAssistantMessage("Launched the background check."),
    ]);
    const run = await dispatch(f);
    const slot = await f.registry.acquire(run.sessionId);
    await waitFor(() => child.heldRequests() === 1, "async child live", bound);
    await waitBetweenTurns(slot);

    const root = await mkdtemp(join(tmpdir(), "tron-2259-stop-drain-"));
    roots.push(root);
    const logPath = join(root, "gateway.jsonl");
    let settled = false;
    let failure: unknown;
    const drain = waitForStopDrain(f.registry, new GatewayLogger(logPath), 200).finally(() => { settled = true; });
    drain.catch(error => { failure = error; });
    await waitFor(async () => {
      if (failure) throw failure;
      return (await records(logPath)).some(record => record.event === "gateway.stop-drain.waiting");
    }, "the stop names its blockers", bound);
    const [first] = (await records(logPath)).filter(record => record.event === "gateway.stop-drain.waiting");
    const named = JSON.parse(first!.message!.slice(first!.message!.indexOf("["))) as Array<Record<string, unknown>>;
    expect(named).toContainEqual(expect.objectContaining({ sessionId: run.sessionId, category: "foreground-agent-operation", state: "active" }));
    expect(named.filter(blocker => blocker.state === "suspect")).toEqual([]);
    expect(settled).toBe(false);

    child.releaseHeld();
    expect(await run.completion).toMatchObject({ lifecycle: "terminal", terminalEvidence: { outcome: "unknown", reason: "no-report", sessionId: run.sessionId } });
    const final = await drain;
    const waiting = (await records(logPath)).filter(record => record.event === "gateway.stop-drain.waiting");
    await mkdir("test-results/2259", { recursive: true });
    await writeFile("test-results/2259/home-task-stop-drain.json", JSON.stringify({ waiting, final }, null, 2));
    expect(final).toMatchObject({ phase: "complete", blockerCount: 0 });
  }, 60_000);

  it("a restart drain judges a held Home task by its live async run's progress, not by the task's last transition (#2363)", async () => {
    const f = await fixture(false, false, undefined, true);
    const child = await childModel(f);
    f.faux.setResponses([
      holdingAsyncLaunch("async-launch", "HOLD-CHILD CALL-TOOL HOLD-AFTER-TOOL background search"),
      fauxAssistantMessage("Launched the background check."),
    ]);
    const run = await dispatch(f);
    const slot = await f.registry.acquire(run.sessionId);
    await waitFor(() => child.heldRequests() === 1, "async child live", bound);
    await waitBetweenTurns(slot);
    const blocker = (category: string) => f.registry.administrativeDrainSnapshot().blockers
      .find(entry => entry.sessionId === run.sessionId && entry.category === category);
    const heldAt = blocker("foreground-agent-operation")!.progressAt!;
    await new Promise(resolve => setTimeout(resolve, 20));
    child.releaseHeld();
    await waitFor(() => child.heldRequests() === 2, "the run progressed and is live again", bound);
    await waitFor(() => (blocker("detached-extension-run")?.progressAt ?? "") > heldAt, "the run's progress reaches the drain", bound);
    const snapshot = f.registry.administrativeDrainSnapshot();
    const task = snapshot.blockers.find(entry => entry.sessionId === run.sessionId && entry.category === "foreground-agent-operation")!;
    const runProgress = snapshot.blockers.find(entry => entry.sessionId === run.sessionId && entry.category === "detached-extension-run")!.progressAt!;
    expect(task.progressAt).toBe(heldAt);
    const limit = 180_000;
    expect(new RestartDrainProgress().evaluate(snapshot, Date.parse(heldAt) + limit, limit)).toEqual({ outcome: "waiting" });
    expect(new RestartDrainProgress().evaluate(snapshot, Date.parse(runProgress) + limit, limit))
      .toMatchObject({ outcome: "stalled", blocker: { sessionId: run.sessionId }, ageMs: limit });
    child.releaseHeld();
    await run.completion.catch(() => {});
  }, 60_000);
});
