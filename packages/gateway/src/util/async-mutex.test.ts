import { describe, expect, it } from "vitest";
import { AsyncMutex } from "./async-mutex.js";
import { abortableRead } from "./abortable-read.js";

function gate() {
  let release!: () => void;
  const promise = new Promise<void>(resolve => { release = resolve; });
  return { promise, release };
}

describe("AsyncMutex ownership", () => {
  it("serializes accepted work across success and failure", async () => {
    const mutex = new AsyncMutex();
    const entered = gate(), finish = gate();
    const events: string[] = [];
    const first = mutex.run(async () => { events.push("first"); entered.release(); await finish.promise; events.push("first-done"); });
    const failure = mutex.run(() => { events.push("failure"); throw new Error("fixture"); }).catch(error => error.message);
    const last = mutex.run(() => events.push("last"));
    try {
      await entered.promise;
      expect(events).toEqual(["first"]);
    } finally { finish.release(); }
    await Promise.all([first, last]);
    expect(await failure).toBe("fixture");
    expect(events).toEqual(["first", "first-done", "failure", "last"]);
  });

  it("removes cancelled queued reads without releasing an active owner", async () => {
    const mutex = new AsyncMutex();
    const entered = gate(), finish = gate();
    const controller = new AbortController();
    let underlying!: Promise<number>;
    let writeStarted = false;
    let cancelledReadsExecuted = 0;
    const read = abortableRead(controller.signal, () => underlying = mutex.run(async () => {
      entered.release(); await finish.promise; return 1;
    }, controller.signal));
    void read.catch(() => {});
    await entered.promise;
    try {
      const cancellations = Array.from({ length: 100 }, () => {
        const signal = new AbortController();
        const result = mutex.run(() => { cancelledReadsExecuted++; }, signal.signal).catch(error => error.name);
        signal.abort();
        return result;
      });
      expect(await Promise.all(cancellations)).toEqual(Array(100).fill("AbortError"));
      // A cancelled queued read is otherwise invisible (it never runs and its
      // rejection is already delivered), so the retaining set is the only
      // witness that cancellation releases its memory.
      expect((mutex as unknown as { waiting: Set<unknown> }).waiting.size).toBe(0);
      controller.abort();
      await expect(read).rejects.toMatchObject({ name: "AbortError" });
      const write = mutex.run(() => { writeStarted = true; });
      expect(writeStarted).toBe(false);
      finish.release();
      await underlying;
      await write;
      expect(writeStarted).toBe(true);
      expect(cancelledReadsExecuted).toBe(0);
    } finally { finish.release(); await underlying; }
  });
});
