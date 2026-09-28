import { AsyncLocalStorage } from "node:async_hooks";

/**
 * One request's stage accounting. `rpc.completed` publishes the compact form so
 * a slow or failed request explains its own wall time without a log record per
 * stage (plan O-3).
 *
 * The span is ambient for the code it covers: `stage`, `wait`, `count` and
 * `bytes` record on the span the caller runs under, and are no-ops outside one.
 * Measurements are exclusive: a stage nested inside another is subtracted from
 * its parent, so the sum of every named entry is never larger than the time the
 * request actually spent.
 */
export class RequestSpan {
  private readonly entries = new Map<string, SpanEntry>();
  private readonly openStages: OpenStage[] = [];
  private sequence = 0;
  private finished = false;

  /**
   * Measures `operation` as one named stage. Returns what the operation
   * returned, so a synchronous owner can be measured without changing its
   * signature.
   */
  stage<T>(name: string, operation: () => Promise<T>): Promise<T>;
  stage<T>(name: string, operation: () => T): T;
  stage<T>(name: string, operation: () => T | Promise<T>): T | Promise<T> {
    if (this.finished) return operation();
    const stage: OpenStage = { entry: this.entry(name), startedAt: performance.now(), childMs: 0 };
    this.openStages.push(stage);
    let result: T | Promise<T>;
    try {
      result = operation();
    } catch (error) {
      this.closeStage(stage);
      throw error;
    }
    if (!isPromiseLike(result)) {
      this.closeStage(stage);
      return result;
    }
    return result.then(
      (value) => { this.closeStage(stage); return value as T; },
      (error) => { this.closeStage(stage); throw error; },
    );
  }

  /**
   * Measures the time an operation spends waiting for a lock or a queue slot as
   * one named wait. The operation reports the handover by calling `acquired`;
   * without it the wait ends when the operation settles. The time the wait
   * admits is ordinary work and is attributed to whatever measures it.
   */
  wait<T>(name: string, operation: (acquired: () => void) => Promise<T>): Promise<T>;
  wait<T>(name: string, operation: (acquired: () => void) => T): T;
  wait<T>(name: string, operation: (acquired: () => void) => T | Promise<T>): T | Promise<T> {
    if (this.finished) return operation(() => {});
    const entry = this.entry(name);
    const startedAt = performance.now();
    let acquired = false;
    const handover = (): void => {
      if (acquired) return;
      acquired = true;
      const waitMs = elapsedSince(startedAt);
      entry.ms += waitMs;
      entry.timed = true;
      entry.count += 1;
      const parent = this.openStages[this.openStages.length - 1];
      if (parent) parent.childMs += waitMs;
    };
    let result: T | Promise<T>;
    try {
      result = operation(handover);
    } catch (error) {
      handover();
      throw error;
    }
    if (!isPromiseLike(result)) {
      handover();
      return result;
    }
    return result.then(
      (value) => { handover(); return value as T; },
      (error) => { handover(); throw error; },
    );
  }

  /** Counts repeated work that carries no duration of its own (walked files,
   * reconciled rows). A stage or wait already counts its own occurrences. */
  count(name: string, n = 1): void {
    if (this.finished) return;
    this.entry(name).count += n;
  }

  bytes(name: string, n: number): void {
    if (this.finished || !Number.isFinite(n) || n < 0) return;
    this.entry(name).bytes += n;
  }

  /**
   * Ends the span and describes it, most expensive entry first. `requestMs` is
   * the same duration the caller reports, so `unaccountedMs` is the part of
   * that duration no named entry covered. Undefined when nothing was recorded:
   * a fast request keeps its record unchanged. Later records are ignored so a
   * published breakdown cannot move.
   */
  breakdown(requestMs: number): RequestSpanBreakdown | undefined {
    this.finished = true;
    if (this.entries.size === 0) return undefined;
    const recorded = [...this.entries.values()].sort((left, right) => right.ms - left.ms || left.order - right.order);
    const coveredMs = recorded.reduce((total, entry) => total + entry.ms, 0);
    return {
      stages: recorded.map(formatEntry).join(";"),
      unaccountedMs: Math.max(0, Math.round(requestMs) - coveredMs),
    };
  }

  private closeStage(stage: OpenStage): void {
    const index = this.openStages.lastIndexOf(stage);
    if (index === -1) return;
    this.openStages.splice(index, 1);
    const exclusiveMs = Math.max(0, elapsedSince(stage.startedAt) - stage.childMs);
    stage.entry.ms += exclusiveMs;
    stage.entry.timed = true;
    stage.entry.count += 1;
    const parent = index === 0 ? undefined : this.openStages[index - 1];
    if (parent) parent.childMs += exclusiveMs;
  }

  private entry(name: string): SpanEntry {
    const existing = this.entries.get(name);
    if (existing) return existing;
    const created: SpanEntry = { name, order: this.sequence++, ms: 0, count: 0, bytes: 0, timed: false };
    this.entries.set(name, created);
    return created;
  }
}

export interface RequestSpanBreakdown {
  /** `name=12ms×2/610KB;name=5ms` — every named entry, most expensive first. */
  stages: string;
  /** Time in the request that no named entry covered. */
  unaccountedMs: number;
}

interface SpanEntry {
  readonly name: string;
  readonly order: number;
  ms: number;
  count: number;
  bytes: number;
  /** A stage or wait entry reports its duration even when it rounds to 0 ms. */
  timed: boolean;
}

interface OpenStage {
  readonly entry: SpanEntry;
  readonly startedAt: number;
  /** Time already credited to stages and waits recorded while this one was
   * open, so a nested measurement is never counted twice. */
  childMs: number;
}

const storage = new AsyncLocalStorage<RequestSpan>();

/** Runs `operation` as the current span, including its asynchronous work. */
export function runInRequestSpan<T>(span: RequestSpan, operation: () => T): T {
  return storage.run(span, operation);
}

export function currentRequestSpan(): RequestSpan | undefined {
  return storage.getStore();
}

/** Measures `operation` as a stage on the current request, or runs it
 * unwrapped when no request owns this code. */
export function stage<T>(name: string, operation: () => Promise<T>): Promise<T>;
export function stage<T>(name: string, operation: () => T): T;
export function stage<T>(name: string, operation: () => T | Promise<T>): T | Promise<T> {
  const span = storage.getStore();
  return span === undefined ? operation() : span.stage(name, operation);
}

/** Measures a lock or queue wait on the current request. See
 * `RequestSpan.wait` for the acquisition callback. */
export function wait<T>(name: string, operation: (acquired: () => void) => Promise<T>): Promise<T>;
export function wait<T>(name: string, operation: (acquired: () => void) => T): T;
export function wait<T>(name: string, operation: (acquired: () => void) => T | Promise<T>): T | Promise<T> {
  const span = storage.getStore();
  return span === undefined ? operation(() => {}) : span.wait(name, operation);
}

export function count(name: string, n = 1): void {
  storage.getStore()?.count(name, n);
}

export function bytes(name: string, n: number): void {
  storage.getStore()?.bytes(name, n);
}

/** Whole milliseconds keep the one-line breakdown readable; it names the
 * dominant stage, it does not measure below it. */
function elapsedSince(startedAt: number): number {
  return Math.max(0, Math.round(performance.now() - startedAt));
}

function isPromiseLike(value: unknown): value is PromiseLike<unknown> {
  return typeof (value as { then?: unknown } | null)?.then === "function";
}

function formatEntry(entry: SpanEntry): string {
  let detail = entry.timed ? `${entry.ms}ms` : "";
  if (entry.count > 1 || detail.length === 0) detail += `×${entry.count}`;
  if (entry.bytes > 0) detail += `/${entry.bytes >= 1_024 ? `${Math.round(entry.bytes / 1_024)}KB` : `${Math.round(entry.bytes)}B`}`;
  return `${entry.name}=${detail}`;
}
