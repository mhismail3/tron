import { afterEach, describe, expect, it, vi } from "vitest";
import { bytes, count, currentRequestSpan, RequestSpan, runInRequestSpan, stage, wait } from "./request-span.js";

/**
 * Isolated checks for the request span's own accounting. Failure modes written
 * before the code (plan O-3):
 *
 * 1. A wrapped stage never records: the slow stage is missing from `stages`
 *    and `unaccountedMs` stays as large as the stage.
 * 2. Nested stages are counted twice: the entries claim more time than the
 *    request took, so `unaccountedMs` reads 0 while the request was unmeasured.
 * 3. A lock or queue wait is charged the work it admits: `registry.mutex`
 *    inflates and hides the stage that actually held the request.
 * 4. Records arriving after `breakdown` move a published breakdown.
 * 5. Counts and bytes are dropped from the compact string.
 * 6. Two requests share one span (AsyncLocalStorage leakage): stages land on
 *    the wrong request.
 * 7. Wrapping a synchronous owner makes it asynchronous.
 * 8. Two stages started concurrently are nested into each other, because
 *    nesting reads a stack shared by the whole span instead of each stage's own
 *    async context: the later-started stage is charged the earlier one's time
 *    and the earlier one loses it.
 */

/** The span reads the clock twice per measurement; pin it so a loaded host
 * cannot change what the accounting saw. Tests move it with `advance` and hold
 * a stage open across explicit gates instead of sleeping. */
function pinnedClock(): { advance: (ms: number) => void } {
  let now = 0;
  vi.spyOn(performance, "now").mockImplementation(() => now);
  return { advance: (ms: number) => { now += ms; } };
}

function gate(): { promise: Promise<void>; release: () => void } {
  let release!: () => void;
  const promise = new Promise<void>((resolve) => { release = resolve; });
  return { promise, release };
}

/** Milliseconds as the breakdown reports them. */
function reportedMs(stages: string, name: string): number {
  const entry = stages.split(";").find((part) => part.startsWith(`${name}=`));
  expect(entry, `missing ${name} in ${stages}`).toBeDefined();
  const value = /^[^=]+=(\d+)ms/u.exec(entry!);
  expect(value, `missing duration for ${name}`).toBeTruthy();
  return Number(value![1]);
}

afterEach(() => { vi.restoreAllMocks(); });

describe("request span", () => {
  it("attributes a slow stage and leaves only the unwrapped remainder unaccounted", async () => {
    const clock = pinnedClock();
    const span = new RequestSpan();
    const working = gate();
    let durationMs = 0;
    await runInRequestSpan(span, async () => {
      const startedAt = performance.now();
      const walk = span.stage("catalog.walk", () => {
        clock.advance(30);
        return working.promise;
      });
      // Real asynchronous work the span does not name: the request's remainder.
      working.release();
      await Promise.resolve();
      clock.advance(5);
      await walk;
      durationMs = performance.now() - startedAt;
    });

    const breakdown = span.breakdown(durationMs);
    expect(breakdown).toBeDefined();
    expect(reportedMs(breakdown!.stages, "catalog.walk")).toBe(30);
    expect(durationMs).toBe(35);
    expect(breakdown!.unaccountedMs).toBe(5);
  });

  it("subtracts a nested stage from its parent instead of counting it twice", async () => {
    const clock = pinnedClock();
    const span = new RequestSpan();
    const building = gate();
    let durationMs = 0;
    await runInRequestSpan(span, async () => {
      const startedAt = performance.now();
      await span.stage("session.open.runtime", async () => {
        clock.advance(10);
        // Nested: started inside the parent's own async context.
        const build = stage("snapshot.build", () => {
          clock.advance(25);
          return building.promise;
        });
        await Promise.resolve();
        building.release();
        await build;
      });
      durationMs = performance.now() - startedAt;
    });

    const breakdown = span.breakdown(durationMs)!;
    expect(durationMs).toBe(35);
    expect(reportedMs(breakdown.stages, "session.open.runtime")).toBe(10);
    expect(reportedMs(breakdown.stages, "snapshot.build")).toBe(25);
    expect(breakdown.unaccountedMs).toBe(0);
  });

  it("keeps concurrently started stages as siblings instead of nesting them", async () => {
    for (const order of [["a", "b"], ["b", "a"]] as const) {
      const clock = pinnedClock();
      const span = new RequestSpan();
      const first = gate();
      const second = gate();
      let durationMs = 0;
      await runInRequestSpan(span, async () => {
        const startedAt = performance.now();
        const gates = { a: first.promise, b: second.promise };
        const started = order.map((name) => stage(name, () => gates[name]));
        await Promise.resolve();
        clock.advance(100);
        first.release();
        await Promise.resolve();
        clock.advance(50);
        second.release();
        await Promise.all(started);
        durationMs = performance.now() - startedAt;
      });

      const breakdown = span.breakdown(durationMs)!;
      expect(durationMs).toBe(150);
      // Each stage keeps its own time in either order, and the overlap cannot
      // push the remainder below zero.
      expect(reportedMs(breakdown.stages, "a")).toBe(100);
      expect(reportedMs(breakdown.stages, "b")).toBe(150);
      expect(breakdown.unaccountedMs).toBe(0);
    }
  });

  it("records a lock wait as the wait, not as the work it admits", async () => {
    const clock = pinnedClock();
    const span = new RequestSpan();
    let durationMs = 0;
    await runInRequestSpan(span, async () => {
      const startedAt = performance.now();
      await span.wait("registry.mutex", (acquired) => {
        clock.advance(20);
        acquired();
        // The admitted work is not measured here: it belongs to whoever wraps it.
        clock.advance(30);
        return Promise.resolve();
      });
      durationMs = performance.now() - startedAt;
    });

    const breakdown = span.breakdown(durationMs)!;
    expect(durationMs).toBe(50);
    expect(reportedMs(breakdown.stages, "registry.mutex")).toBe(20);
    expect(breakdown.unaccountedMs).toBe(30);
  });

  it("ignores records that arrive after the breakdown is published", async () => {
    const clock = pinnedClock();
    const span = new RequestSpan();
    await runInRequestSpan(span, () => span.stage("session.open.catalog", () => {
      clock.advance(5);
      return Promise.resolve();
    }));
    const published = span.breakdown(10)!;

    count("catalog.walk.files", 2);
    bytes("frame.serialize", 4_096);
    stage("late.stage", () => Promise.resolve());
    await Promise.resolve();

    expect(span.breakdown(100)!.stages).toBe(published.stages);
    expect(published.stages).not.toContain("late.stage");
  });

  it("keeps independent request spans apart", async () => {
    const clock = pinnedClock();
    const first = new RequestSpan();
    const second = new RequestSpan();
    const held = gate();
    await Promise.all([
      runInRequestSpan(first, async () => {
        const work = stage("first.stage", () => {
          clock.advance(10);
          return held.promise;
        });
        await Promise.resolve();
        held.release();
        await work;
      }),
      runInRequestSpan(second, async () => {
        const work = stage("second.stage", () => {
          clock.advance(20);
          return held.promise;
        });
        count("second.count", 3);
        await Promise.resolve();
        held.release();
        await work;
      }),
    ]);

    const firstBreakdown = first.breakdown(30)!;
    const secondBreakdown = second.breakdown(30)!;
    expect(firstBreakdown.stages).toContain("first.stage=");
    expect(firstBreakdown.stages).not.toContain("second.");
    expect(secondBreakdown.stages).toContain("second.stage=");
    expect(secondBreakdown.stages).toContain("second.count=×3");
    expect(secondBreakdown.stages).not.toContain("first.");
  });

  it("reports counts and byte sizes in the compact string", async () => {
    const clock = pinnedClock();
    const span = new RequestSpan();
    await runInRequestSpan(span, async () => {
      await stage("catalog.walk", () => { clock.advance(5); return Promise.resolve(); });
      count("catalog.walk.files", 2_995);
      // A lane that handed over immediately: 0 ms and nothing else, so it costs
      // no bytes on the record.
      await wait("registry.mutex", (acquired) => { acquired(); return Promise.resolve(); });
      await stage("frame.serialize", () => { clock.advance(3); return Promise.resolve(); });
      await stage("frame.serialize", () => { clock.advance(3); return Promise.resolve(); });
      bytes("frame.serialize", 610 * 1_024);
      bytes("frame.serialize", 24);
    });

    const breakdown = span.breakdown(50)!;
    expect(breakdown.stages).toContain("catalog.walk.files=×2995");
    expect(breakdown.stages).not.toContain("registry.mutex");
    // Two frames were serialized into the one entry.
    expect(breakdown.stages).toMatch(/frame\.serialize=6ms×2\/610KB/u);
  });

  it("measures a synchronous owner without making it asynchronous", () => {
    const clock = pinnedClock();
    const span = new RequestSpan();
    const measured = runInRequestSpan(span, () => span.stage("snapshot.build", () => {
      clock.advance(2);
      return { revision: 7 };
    }));

    expect(measured).toEqual({ revision: 7 });
    expect(measured).not.toBeInstanceOf(Promise);
    expect(reportedMs(span.breakdown(2)!.stages, "snapshot.build")).toBe(2);
  });

  it("leaves code outside any request unwrapped", async () => {
    expect(currentRequestSpan()).toBeUndefined();
    const value = stage("unowned.stage", () => "value");
    expect(value).toBe("value");
    await expect(wait("unowned.mutex", () => Promise.resolve())).resolves.toBeUndefined();
    expect(count("unowned.count", 1)).toBeUndefined();
    expect(bytes("unowned.bytes", 1)).toBeUndefined();
  });
});
