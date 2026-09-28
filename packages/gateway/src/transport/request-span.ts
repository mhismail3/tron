import { AsyncLocalStorage } from "node:async_hooks";

/**
 * One request's stage accounting. `rpc.completed` publishes the compact form so
 * a slow or failed request explains its own wall time without a log record per
 * stage.
 *
 * The span is ambient for the code it covers: `stage`, `wait`, `count` and
 * `bytes` record on the span the caller runs under, and are no-ops outside one.
 * A measurement nests inside the measurement its own async context is running
 * under, not the last one the span happened to see, so two stages started
 * concurrently are siblings: each keeps its own time. Measurements are
 * exclusive against the measurement they nest under, so a request whose stages
 * are sequential has named entries that never add up to more than the wall time
 * it spent. Two stages that genuinely overlap do add up to more than that, and
 * `unaccountedMs` then reads its floor of zero rather than a negative number.
 */
/** Requests this process has admitted and not yet answered. One live span is one
 * request the transport is serving, so background work can yield to it; span
 * construction and `breakdown` are the request's own boundaries
 * (`transport/server.ts` admits, the response or its failure closes). */
let activeSpans = 0;

export function activeRequestSpans(): number {
  return activeSpans;
}

export class RequestSpan {
  private readonly entries = new Map<string, SpanEntry>();
  private sequence = 0;
  private finished = false;

  constructor() {
    activeSpans += 1;
  }

  /**
   * Measures `operation` as one named stage. Returns what the operation
   * returned, so a synchronous owner can be measured without changing its
   * signature.
   */
  stage<T>(name: string, operation: () => Promise<T>): Promise<T>;
  stage<T>(name: string, operation: () => T): T;
  stage<T>(name: string, operation: () => T | Promise<T>): T | Promise<T> {
    if (this.finished) return operation();
    const context = this.context();
    const stage: OpenStage = {
      entry: this.entry(name),
      startedAt: performance.now(),
      parent: context?.openStage,
      childMs: 0,
      closed: false,
    };
    let result: T | Promise<T>;
    try {
      result = context === undefined
        ? operation()
        : storage.run({ span: this, openStage: stage }, operation);
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
    const parent = this.context()?.openStage;
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
   * that duration no named entry covered. Undefined when nothing worth naming
   * was recorded: a fast request keeps its record unchanged. Later records are
   * ignored so a published breakdown cannot move.
   */
  breakdown(requestMs: number): RequestSpanBreakdown | undefined {
    if (!this.finished) {
      this.finished = true;
      activeSpans -= 1;
    }
    const recorded = [...this.entries.values()].filter(worthNaming)
      .sort((left, right) => right.ms - left.ms || left.order - right.order);
    if (recorded.length === 0) return undefined;
    const coveredMs = recorded.reduce((total, entry) => total + entry.ms, 0);
    return {
      stages: recorded.map(formatEntry).join(";"),
      unaccountedMs: Math.max(0, Math.round(requestMs - coveredMs)),
    };
  }

  private closeStage(stage: OpenStage): void {
    if (stage.closed) return;
    stage.closed = true;
    const exclusiveMs = Math.max(0, elapsedSince(stage.startedAt) - stage.childMs);
    stage.entry.ms += exclusiveMs;
    stage.entry.timed = true;
    stage.entry.count += 1;
    if (stage.parent) stage.parent.childMs += exclusiveMs;
  }

  /** The ambient context, when this span owns it. A span that is not the
   * ambient one (a test driving `stage` directly) records without re-entering a
   * context, so it cannot adopt another span's children. */
  private context(): RequestSpanContext | undefined {
    const ambient = storage.getStore();
    return ambient?.span === this ? ambient : undefined;
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
  /** The stage this one's async context was running inside, if any. */
  readonly parent: OpenStage | undefined;
  /** Time already credited to measurements recorded inside this one, so a
   * nested measurement is never counted twice. */
  childMs: number;
  closed: boolean;
}

interface RequestSpanContext {
  readonly span: RequestSpan;
  /** The stage this async context is running inside; concurrent stages each
   * carry their own, so neither is mistaken for the other's parent. */
  readonly openStage: OpenStage | undefined;
}

const storage = new AsyncLocalStorage<RequestSpanContext>();

/** Runs `operation` as the current span, including its asynchronous work. */
export function runInRequestSpan<T>(span: RequestSpan, operation: () => T): T {
  return storage.run({ span, openStage: undefined }, operation);
}

export function currentRequestSpan(): RequestSpan | undefined {
  return storage.getStore()?.span;
}

/** Measures `operation` as a stage on the current request, or runs it
 * unwrapped when no request owns this code. */
export function stage<T>(name: string, operation: () => Promise<T>): Promise<T>;
export function stage<T>(name: string, operation: () => T): T;
export function stage<T>(name: string, operation: () => T | Promise<T>): T | Promise<T> {
  const span = storage.getStore()?.span;
  return span === undefined ? operation() : span.stage(name, operation);
}

/** Measures a lock or queue wait on the current request. See
 * `RequestSpan.wait` for the acquisition callback. */
export function wait<T>(name: string, operation: (acquired: () => void) => Promise<T>): Promise<T>;
export function wait<T>(name: string, operation: (acquired: () => void) => T): T;
export function wait<T>(name: string, operation: (acquired: () => void) => T | Promise<T>): T | Promise<T> {
  const span = storage.getStore()?.span;
  return span === undefined ? operation(() => {}) : span.wait(name, operation);
}

export function count(name: string, n = 1): void {
  storage.getStore()?.span.count(name, n);
}

export function bytes(name: string, n: number): void {
  storage.getStore()?.span.bytes(name, n);
}

/** Milliseconds as the breakdown reports them: totals stay fractional while
 * measurements accumulate and are rounded once, when the entry is formatted. */
function elapsedSince(startedAt: number): number {
  return Math.max(0, performance.now() - startedAt);
}

function isPromiseLike(value: unknown): value is PromiseLike<unknown> {
  return typeof (value as { then?: unknown } | null)?.then === "function";
}

/** Whole milliseconds keep the one-line breakdown readable; it names the
 * dominant stage, it does not measure below it. An entry that would render as
 * `0ms` and carries nothing else is dropped rather than paid for on every
 * record. */
function worthNaming(entry: SpanEntry): boolean {
  return entry.bytes > 0 || (entry.timed ? Math.round(entry.ms) > 0 : entry.count > 0);
}

function formatEntry(entry: SpanEntry): string {
  let detail = entry.timed ? `${Math.round(entry.ms)}ms` : "";
  if (entry.count > 1 || detail.length === 0) detail += `×${entry.count}`;
  if (entry.bytes > 0) detail += `/${entry.bytes >= 1_024 ? `${Math.round(entry.bytes / 1_024)}KB` : `${Math.round(entry.bytes)}B`}`;
  return `${entry.name}=${detail}`;
}
