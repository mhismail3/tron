import { describe, expect, it } from "vitest";
import {
  BACKGROUND_BACKLOG_WARNING_MS,
  BACKGROUND_PAUSE_P99_MS,
  BACKGROUND_PAUSE_RECHECK_MS,
  BackgroundWorkScheduler,
  type BackgroundBacklogRecord,
  type BackgroundSliceRecord,
} from "./background-work.js";
import { waitFor } from "../test-support/wait-for.js";

// Failure modes this file covers, written before the scheduler existed:
// 1. A slice starts while a request is in flight: the request shares the loop
//    with background work instead of getting it first.
// 2. A slice starts while the event-loop delay p99 is at or above
//    `BACKGROUND_PAUSE_P99_MS`.
// 3. The next slice starts before the previous one settles, either from another
//    job or from a re-registration, so two slices run in one loop turn.
// 4. A slice that rejects stops the scheduler or the jobs registered after it,
//    or fails with no record at all.
// 5. A job starved past `BACKGROUND_BACKLOG_WARNING_MS` is silent, or reports
//    once per re-check instead of once per starved spell.
// 6. `stop()` leaves a wake armed, or an armed wake that fires after it still
//    starts a slice.
// 7. A slice with more than one bounded batch holds the loop between batches,
//    instead of yielding to the same pause the next slice waits for.
// 8. A registration's dispose stops the job a later owner registered under the
//    same name.

interface Armed {
  callback: () => void;
  delayMs?: number;
  consumed: boolean;
}

function harness() {
  const immediates: Armed[] = [];
  const timers: Armed[] = [];
  const slices: BackgroundSliceRecord[] = [];
  const backlogs: BackgroundBacklogRecord[] = [];
  const state = { now: 0, requests: false, p99: 0 };
  const scheduler = new BackgroundWorkScheduler();
  const pending = (armed: readonly Armed[]): number => armed.filter((entry) => !entry.consumed).length;
  const run = (armed: Armed[]): void => {
    // A snapshot: a wake runs one tick, and a tick may arm the next wake. The
    // next wake is what the following pass drives, never this one.
    for (const entry of [...armed]) {
      if (entry.consumed) continue;
      entry.consumed = true;
      entry.callback();
    }
  };
  scheduler.start({
    now: () => state.now,
    immediate: (callback) => { immediates.push({ callback, consumed: false }); return immediates.length - 1; },
    timer: (callback, delayMs) => { timers.push({ callback, delayMs, consumed: false }); return timers.length - 1; },
    cancelImmediate: (handle) => { immediates[handle as number]!.consumed = true; },
    cancelTimer: (handle) => { timers[handle as number]!.consumed = true; },
    requestsInFlight: () => state.requests,
    eventLoopP99Ms: () => state.p99,
    onSlice: (record) => slices.push(record),
    onBacklog: (record) => backlogs.push(record),
  });
  /** Lets the slices the wakes started settle. */
  const settle = (): Promise<void> => new Promise<void>((resolve) => setImmediate(resolve));
  return {
    scheduler,
    slices,
    backlogs,
    state,
    settle,
    runImmediates: () => run(immediates),
    runTimers: () => run(timers),
    pendingImmediates: () => pending(immediates),
    pendingTimers: () => pending(timers),
    /** Arms and runs every wake: what the scheduler does with nothing else
     * driving it. */
    async drive(rounds = 4): Promise<void> {
      for (let round = 0; round < rounds; round += 1) {
        run(immediates);
        run(timers);
        await settle();
        if (pending(immediates) === 0 && pending(timers) === 0) return;
      }
    },
  };
}

describe("BackgroundWorkScheduler", () => {
  it("starts no slice while a request is in flight", async () => {
    const h = harness();
    const runs: number[] = [];
    h.scheduler.register({ name: "job.one", intervalMs: 10, slice: () => { runs.push(h.state.now); } });
    h.state.requests = true;
    h.state.now = 10;
    await h.drive();

    expect(runs).toEqual([]);
    // The pause re-checks instead of giving up on the job.
    expect(h.pendingTimers()).toBe(1);
    h.state.requests = false;
    await h.drive();
    expect(runs).toEqual([10]);
  });

  it("starts no slice at or above the event-loop p99 pause bound", async () => {
    const h = harness();
    const runs: string[] = [];
    h.scheduler.register({ name: "job.one", intervalMs: 10, slice: () => { runs.push("ran"); } });
    h.state.now = 10;
    h.state.p99 = BACKGROUND_PAUSE_P99_MS;
    await h.drive();
    expect(runs).toEqual([]);

    // One millisecond of headroom is enough: the bound pauses at or above itself.
    h.state.p99 = BACKGROUND_PAUSE_P99_MS - 1;
    await h.drive();
    expect(runs).toEqual(["ran"]);
  });

  it("runs one slice at a time and yields with an immediate between them", async () => {
    const h = harness();
    const runs: string[] = [];
    let release!: () => void;
    const held = new Promise<void>((resolve) => { release = resolve; });
    h.scheduler.register({
      name: "job.held",
      intervalMs: 1,
      slice: async () => { runs.push("held"); await held; },
    });
    h.scheduler.register({ name: "job.next", intervalMs: 1, slice: () => { runs.push("next"); } });
    h.state.now = 1;
    await h.drive(1);

    // The held slice is in flight: nothing else has run, and no wake is armed.
    expect(runs).toEqual(["held"]);
    expect(h.pendingImmediates()).toBe(0);
    expect(h.pendingTimers()).toBe(0);
    release();
    await h.settle();
    // The next wake is a loop yield (an immediate), not a synchronous re-entry.
    expect(h.pendingImmediates()).toBe(1);
    await h.drive();
    expect(runs).toEqual(["held", "next"]);
  });

  it("reports a rejecting slice and keeps the jobs after it running", async () => {
    const h = harness();
    const runs: string[] = [];
    h.scheduler.register({
      name: "job.failing",
      intervalMs: 10,
      slice: () => { throw new Error("slice failed"); },
    });
    h.scheduler.register({ name: "job.after", intervalMs: 10, slice: () => { runs.push("after"); } });
    const first = h.slices.length;
    h.state.now = 10;
    await h.drive();

    expect(runs).toEqual(["after"]);
    expect(h.slices.slice(first)).toHaveLength(2);
    expect(h.slices[first]).toMatchObject({ job: "job.failing", outcome: "failed", waitedMs: 0 });
    expect(h.slices[first]!.error).toBeInstanceOf(Error);
    expect(h.slices[first + 1]).toMatchObject({ job: "job.after", outcome: "completed" });
  });

  it("records one backlog warning per starved spell, not one per re-check", async () => {
    const h = harness();
    h.scheduler.register({ name: "job.one", intervalMs: 10, slice: () => {} });
    h.state.requests = true;
    h.state.now = 10;
    await h.drive();
    // Due, not yet starving.
    expect(h.backlogs).toEqual([]);

    h.state.now = 10 + BACKGROUND_BACKLOG_WARNING_MS;
    h.runTimers();
    await h.settle();
    expect(h.backlogs).toHaveLength(1);
    expect(h.backlogs[0]).toMatchObject({ job: "job.one", reason: "requests-in-flight", jobs: 1, due: 1 });
    expect(h.backlogs[0]!.waitedMs).toBeGreaterThanOrEqual(BACKGROUND_BACKLOG_WARNING_MS);

    // The next re-checks stay silent for the same spell.
    h.state.now += BACKGROUND_PAUSE_RECHECK_MS;
    h.runTimers();
    await h.settle();
    expect(h.backlogs).toHaveLength(1);

    // The slice runs, and a later starved spell reports again.
    h.state.requests = false;
    h.state.now += 1;
    await h.drive();
    expect(h.slices).toHaveLength(1);
    h.state.requests = true;
    // Past the warning age measured from the slice's own next due time, which the
    // slice above set one interval ahead of the tick that ran it.
    h.state.now += BACKGROUND_BACKLOG_WARNING_MS + 100;
    await h.drive();
    expect(h.backlogs).toHaveLength(2);
  });

  it("runs a slice with its own event-loop reading when no provider is given", async () => {
    // The production wiring: no `eventLoopP99Ms`, so the scheduler reads its own
    // `monitorEventLoopDelay` histogram. An idle loop must not pause it.
    const slices: BackgroundSliceRecord[] = [];
    const scheduler = new BackgroundWorkScheduler();
    scheduler.start({ requestsInFlight: () => false, onSlice: (record) => slices.push(record) });
    scheduler.register({ name: "job.one", intervalMs: 1, slice: () => {} });
    await new Promise<void>((resolve) => setTimeout(resolve, 20));
    scheduler.stop();
    // Every slice due in the window ran: an idle loop is never paused by the
    // scheduler's own reading.
    expect(slices.length).toBeGreaterThan(1);
    expect(slices.every((record) => record.job === "job.one" && record.outcome === "completed")).toBe(true);
  });

  it("holds a yielding slice until the pause clears, then resumes it", async () => {
    // A slice with more than one bounded batch yields between batches; the pause
    // has to hold it there, not only between slices.
    const scheduler = new BackgroundWorkScheduler();
    const state = { requests: false };
    const batches: number[] = [];
    let finished = false;
    let proceed!: () => void;
    const allowed = new Promise<void>((resolve) => { proceed = resolve; });
    scheduler.register({
      name: "job.batched",
      intervalMs: 1,
      slice: async () => {
        batches.push(1);
        // The test decides when the second batch begins.
        await allowed;
        await scheduler.yieldToLoop();
        batches.push(2);
        finished = true;
      },
    });
    scheduler.start({ requestsInFlight: () => state.requests, eventLoopP99Ms: () => 0 });
    try {
      await waitFor(() => batches.length >= 1, "the first background batch");

      // The request arrives while the slice is between batches: the yield waits
      // for the same pause the next slice would.
      state.requests = true;
      proceed();
      await new Promise((resolve) => setTimeout(resolve, 2 * BACKGROUND_PAUSE_RECHECK_MS));
      expect(batches).toEqual([1]);
      expect(finished).toBe(false);

      state.requests = false;
      await waitFor(() => finished, "the scheduler run to finish");
      // Later runs repeat the same two batches; the case is the first run's.
      expect(batches.slice(0, 2)).toEqual([1, 2]);
    } finally {
      scheduler.stop();
    }
  });

  it("leaves a later registration under one name running when the replaced owner unregisters", async () => {
    const h = harness();
    const runs: string[] = [];
    const removeReplaced = h.scheduler.register({
      name: "catalog.reconcile",
      intervalMs: 10,
      slice: () => { runs.push("replaced"); },
    });
    h.scheduler.register({
      name: "catalog.reconcile",
      intervalMs: 10,
      slice: () => { runs.push("current"); },
    });
    // The replaced owner's dispose runs after the replacement registered: the
    // name belongs to the replacement, and the job must keep running.
    removeReplaced();
    h.state.now = 10;
    await h.drive();
    expect(runs).toEqual(["current"]);
  });

  it("arms nothing after stop, and a wake that fires later starts nothing", async () => {
    const h = harness();
    const runs: number[] = [];
    h.scheduler.register({ name: "job.one", intervalMs: 10, slice: () => { runs.push(h.state.now); } });
    h.state.now = 10;
    await h.drive(1);
    expect(runs).toEqual([10]);
    expect(h.pendingImmediates()).toBe(1);

    h.scheduler.stop();
    expect(h.pendingImmediates()).toBe(0);
    expect(h.pendingTimers()).toBe(0);
    h.runImmediates();
    h.runTimers();
    await h.settle();
    expect(runs).toEqual([10]);
  });
});
