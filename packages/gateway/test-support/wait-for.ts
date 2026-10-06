import { vi } from "vitest";

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
 * only "Test timed out" and no condition. It is above Vitest's 10 s
 * `hookTimeout`, so a wait inside `beforeEach`/`afterEach` passes a smaller
 * `boundMs` of its own.
 */
export const WAIT_HANG_BOUND_MS = 12_000;

export interface WaitForOptions {
  /** Poll cadence in ms. */
  readonly intervalMs?: number;
  /**
   * Replaces the shared hang bound. Only for the rare case where elapsed time
   * is itself the contract; say why at that call site.
   */
  readonly boundMs?: number;
}

/**
 * Awaits an event or promise the code already exposes, under the same hang
 * bound and with the same labeled failure as {@link waitFor}. A promise whose
 * latency is not the contract under test must not be raced against a budget
 * tuned to host speed either.
 */
export async function awaitsWithin<T>(promise: Promise<T>, label: string, boundMs = WAIT_HANG_BOUND_MS): Promise<T> {
  let timer!: NodeJS.Timeout;
  try {
    return await Promise.race([promise, new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error(`Waited ${boundMs}ms for ${label} and it never settled`)), boundMs);
    })]);
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Waits for `condition` to report a value, failing with `label` when it never
 * does. A condition that throws fails immediately and unchanged, so a real bug
 * in the awaited path is never mistaken for a slow host.
 *
 * Built on `vi.waitUntil`, which polls on timers that stay real under
 * `vi.useFakeTimers()` and advances the test's fake clock between polls. Tests
 * that own a fake clock (for example knowledge observation) therefore keep
 * making progress on their real I/O while their simulated timers stay theirs.
 */
export async function waitFor<T>(
  condition: () => T | undefined | false | Promise<T | undefined | false>,
  label: string,
  options: WaitForOptions = {},
): Promise<T> {
  const boundMs = options.boundMs ?? WAIT_HANG_BOUND_MS;
  const intervalMs = options.intervalMs ?? 10;
  const deadline = Date.now() + boundMs;
  return vi.waitUntil(async () => {
    const value = await condition();
    if (value !== undefined && value !== false) return value as T;
    if (Date.now() >= deadline) {
      throw new Error(`Waited ${boundMs}ms for ${label} and the condition was never met`);
    }
    return undefined;
  }, { timeout: boundMs + intervalMs, interval: intervalMs });
}
