import { clearTimeout as realClearTimeout, setTimeout as realSetTimeout } from "node:timers";

export const WAIT_HANG_BOUND_MS = waitHangBoundMs();

function waitHangBoundMs(): number {
  const declared = Number(process.env.TRON_TEST_WAIT_HANG_BOUND_MS);
  return Number.isInteger(declared) && declared > 0 ? declared : 12_000;
}

export const HOOK_HANG_BOUND_MS = 5_000;

const realHrtime = process.hrtime.bigint.bind(process.hrtime);

function realNowMs(): number {
  return Number(realHrtime() / 1_000_000n);
}

export interface WaitForOptions {
  readonly intervalMs?: number;
  readonly boundMs?: number;
}

export async function waitFor<T>(
  condition: () => T | undefined | false | Promise<T | undefined | false>,
  label: string,
  options: WaitForOptions = {},
): Promise<T> {
  const boundMs = options.boundMs ?? WAIT_HANG_BOUND_MS;
  const intervalMs = options.intervalMs ?? 10;
  const deadline = realNowMs() + boundMs;
  for (;;) {
    const remaining = deadline - realNowMs();
    if (remaining <= 0) throw unmetCondition(label, boundMs);
    const value = await evaluateWithin(condition, remaining, () => unmetCondition(label, boundMs));
    if (value !== undefined && value !== false) return value as T;
    const pause = Math.min(intervalMs, deadline - realNowMs());
    if (pause > 0) await realDelay(pause);
  }
}

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
