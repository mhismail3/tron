import { expect, it } from "vitest";
import { StallTolerantDeadline } from "./stall-tolerant-deadline.js";

function stallEventLoop(ms: number): void {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

it("still expires work that remains unsettled after a stall", async () => {
  let expire!: () => void;
  const expired = new Promise<void>((resolve) => { expire = resolve; });
  const deadline = new StallTolerantDeadline(200, expire);
  stallEventLoop(1_000);
  await new Promise<void>((resolve) => setImmediate(resolve));
  expect(deadline.expired).toBe(false);
  await expired;
  expect(deadline.expired).toBe(true);
});
