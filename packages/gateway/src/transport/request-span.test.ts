import { describe, expect, it } from "vitest";
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
 */

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Milliseconds as the breakdown reports them. */
function reportedMs(stages: string, name: string): number {
  const entry = stages.split(";").find((part) => part.startsWith(`${name}=`));
  expect(entry, `missing ${name} in ${stages}`).toBeDefined();
  const value = /^[^=]+=(\d+)ms/u.exec(entry!);
  expect(value, `missing duration for ${name}`).toBeTruthy();
  return Number(value![1]);
}

describe("request span", () => {
  it("attributes a slow stage and leaves only the unwrapped remainder unaccounted", async () => {
    const span = new RequestSpan();
    const startedAt = performance.now();
    await runInRequestSpan(span, () => span.stage("catalog.walk", () => sleep(30)));
    const durationMs = performance.now() - startedAt;

    const breakdown = span.breakdown(durationMs);
    expect(breakdown).toBeDefined();
    expect(reportedMs(breakdown!.stages, "catalog.walk")).toBeGreaterThanOrEqual(20);
    // The stage is the request; only the trivial wrapping code is left over.
    expect(reportedMs(breakdown!.stages, "catalog.walk")).toBeLessThanOrEqual(Math.round(durationMs));
    expect(breakdown!.unaccountedMs).toBeLessThan(10);
  });

  it("subtracts a nested stage from its parent instead of counting it twice", async () => {
    const span = new RequestSpan();
    const duration = await runInRequestSpan(span, async () => {
      const startedAt = performance.now();
      await span.stage("session.open.runtime", async () => {
        await sleep(15);
        await span.stage("snapshot.build", () => sleep(25));
      });
      return performance.now() - startedAt;
    });

    const breakdown = span.breakdown(duration)!;
    const parent = reportedMs(breakdown.stages, "session.open.runtime");
    const child = reportedMs(breakdown.stages, "snapshot.build");
    expect(child).toBeGreaterThanOrEqual(parent);
    // The parent keeps only its own work; the nested stage owns its 25 ms.
    expect(parent + child).toBeLessThanOrEqual(Math.round(duration));
    expect(parent).toBeLessThan(child);
  });

  it("records a lock wait as the wait, not as the work it admits", async () => {
    const span = new RequestSpan();
    const duration = await runInRequestSpan(span, async () => {
      const startedAt = performance.now();
      await span.wait("registry.mutex", async (acquired) => {
        await sleep(20);
        acquired();
        // The admitted work is not measured here: it belongs to whoever wraps it.
        await sleep(30);
      });
      return performance.now() - startedAt;
    });

    const breakdown = span.breakdown(duration)!;
    const waitMs = reportedMs(breakdown.stages, "registry.mutex");
    expect(waitMs).toBeGreaterThanOrEqual(10);
    expect(waitMs).toBeLessThan(Math.round(duration) - 10);
    expect(breakdown.unaccountedMs).toBeGreaterThan(15);
  });

  it("ignores records that arrive after the breakdown is published", async () => {
    const span = new RequestSpan();
    await runInRequestSpan(span, () => span.stage("session.open.catalog", () => sleep(5)));
    const published = span.breakdown(10)!;

    count("catalog.walk.files", 2);
    bytes("frame.serialize", 4_096);
    stage("late.stage", () => sleep(5));
    await sleep(5);

    expect(span.breakdown(100)!.stages).toBe(published.stages);
    expect(published.stages).not.toContain("late.stage");
  });

  it("keeps independent request spans apart", async () => {
    const first = new RequestSpan();
    const second = new RequestSpan();
    await Promise.all([
      runInRequestSpan(first, async () => { await stage("first.stage", () => sleep(10)); }),
      runInRequestSpan(second, async () => {
        await stage("second.stage", () => sleep(20));
        count("second.count", 3);
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
    const span = new RequestSpan();
    await runInRequestSpan(span, async () => {
      await stage("catalog.walk", () => sleep(5));
      count("catalog.walk.files", 2_995);
      await stage("frame.serialize", () => sleep(3));
      await stage("frame.serialize", () => sleep(3));
      bytes("frame.serialize", 610 * 1_024);
      bytes("frame.serialize", 24);
    });

    const breakdown = span.breakdown(50)!;
    expect(breakdown.stages).toContain("catalog.walk.files=×2995");
    expect(breakdown.stages).toContain("/610KB");
    // Two frames were serialized into the one entry.
    expect(breakdown.stages).toMatch(/frame\.serialize=\d+ms×2\/610KB/u);
  });

  it("measures a synchronous owner without making it asynchronous", () => {
    const span = new RequestSpan();
    const measured = runInRequestSpan(span, () => span.stage("snapshot.build", () => ({ revision: 7 })));

    expect(measured).toEqual({ revision: 7 });
    expect(measured).not.toBeInstanceOf(Promise);
    expect(reportedMs(span.breakdown(1)!.stages, "snapshot.build")).toBe(0);
  });

  it("leaves code outside any request unwrapped", async () => {
    expect(currentRequestSpan()).toBeUndefined();
    const value = stage("unowned.stage", () => "value");
    expect(value).toBe("value");
    await expect(wait("unowned.mutex", () => sleep(1))).resolves.toBeUndefined();
    expect(count("unowned.count", 1)).toBeUndefined();
    expect(bytes("unowned.bytes", 1)).toBeUndefined();
  });
});
