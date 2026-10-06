import { clearTimeout as realClearTimeout, setTimeout as realSetTimeout } from "node:timers";

/**
 * How long a Gateway test waits for a condition whose timing is not the contract
 * under test.
 *
 * These waits are hang bounds, not speed budgets. The events tests await — a
 * turn settling, a frame arriving, a record landing — are correct at any speed,
 * so the bound only has to turn a genuine hang into a named failure. A budget
 * tuned to host speed turns CPU contention into a false failure instead
 * (epic #400: full-suite runs failed a different unrelated test each time).
 *
 * The bound stays below the 15 s `testTimeout` in `vitest.config.ts` so the wait
 * reports its own label; a wait that outlived the test would be cut off with
 * only "Test timed out" and no condition.
 */
export const WAIT_HANG_BOUND_MS = 12_000;

/**
 * The bound for a wait a hook body runs (`beforeEach`/`afterEach`/`afterAll`, and
 * the cleanup callbacks they await). Vitest's `hookTimeout` is 10 s
 * independently of the 15 s test timeout, so a hook wait under the default bound
 * would be cut off with "Hook timed out" and no label.
 */
export const HOOK_HANG_BOUND_MS = 5_000;

/**
 * Real time, captured at module load. `vi.useFakeTimers()` replaces
 * `globalThis.Date` and the global timer functions for the rest of the test, and
 * a poll must never move a clock the test owns: that would fire the timers under
 * test (epic #400). `node:timers` is not a target of the global replacement, so
 * both references stay real even while a test's clock is fake.
 */
const realDateNow = Date.now;

export interface WaitForOptions {
  /** Poll cadence in ms. */
  readonly intervalMs?: number;
  /**
   * Replaces the shared hang bound. Only for a case where elapsed time is
   * itself the contract, or where the surrounding hook has its own smaller
   * timeout (then pass `HOOK_HANG_BOUND_MS` or less); say why at that call site.
   */
  readonly boundMs?: number;
}

/**
 * Waits for `condition` to report a result, failing with `label` when it never
 * does. A result of `undefined` or `false` means "not yet"; any other result —
 * including `0`, `""` and `null` — is the awaited value, so a condition can
 * observe a value as well as assert one.
 *
 * Two properties matter:
 * - A condition that throws fails immediately and unchanged, so a real bug in
 *   the awaited path is never mistaken for a slow host.
 * - The hang bound is enforced here, not by the test runner, so even a condition
 *   whose evaluation never settles fails with its own label at the bound.
 *
 * Polling happens on real timers and real time only. A test that owns a fake
 * clock advances it itself, as the file that fakes it decides.
 */
export async function waitFor<T>(
  condition: () => T | undefined | false | Promise<T | undefined | false>,
  label: string,
  options: WaitForOptions = {},
): Promise<T> {
  const boundMs = options.boundMs ?? WAIT_HANG_BOUND_MS;
  const intervalMs = options.intervalMs ?? 10;
  const deadline = realDateNow() + boundMs;
  for (;;) {
    const remaining = deadline - realDateNow();
    if (remaining <= 0) throw unmetCondition(label, boundMs);
    const value = await evaluateWithin(condition, remaining, () => unmetCondition(label, boundMs));
    if (value !== undefined && value !== false) return value as T;
    const pause = Math.min(intervalMs, deadline - realDateNow());
    if (pause > 0) await realDelay(pause);
  }
}

/**
 * Awaits an event or promise the code already exposes, under the same hang bound
 * and with the same labeled failure as {@link waitFor}. A promise whose latency
 * is not the contract under test must not be raced against a budget tuned to
 * host speed either.
 */
export async function awaitsWithin<T>(promise: Promise<T>, label: string, boundMs: number = WAIT_HANG_BOUND_MS): Promise<T> {
  let timer!: NodeJS.Timeout;
  const expiry = new Promise<never>((_, reject) => {
    timer = realSetTimeout(() => reject(unmetSettlement(label, boundMs)), boundMs);
  });
  try {
    return await Promise.race([promise, expiry]);
  } finally {
    realClearTimeout(timer);
  }
}

/** One evaluation, abandoned when it outlives what is left of the bound. */
async function evaluateWithin<T>(
  condition: () => T | undefined | false | Promise<T | undefined | false>,
  remainingMs: number,
  onExpiry: () => Error,
): Promise<T | undefined | false> {
  let timer: NodeJS.Timeout | undefined;
  const expiry = new Promise<never>((_, reject) => {
    timer = realSetTimeout(() => reject(onExpiry()), remainingMs);
  });
  const evaluation = (async () => condition())();
  // The abandoned evaluation may still reject after the bound fired; it is no
  // longer awaited, and an unhandled rejection would fail an unrelated test.
  evaluation.catch(() => {});
  try {
    return await Promise.race([evaluation, expiry]);
  } finally {
    realClearTimeout(timer);
  }
}

function realDelay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => { realSetTimeout(resolve, milliseconds); });
}

function unmetCondition(label: string, boundMs: number): Error {
  return new Error(`Waited ${boundMs}ms for ${label} and the condition was never met`);
}

function unmetSettlement(label: string, boundMs: number): Error {
  return new Error(`Waited ${boundMs}ms for ${label} and it never settled`);
}
