import { AsyncLocalStorage } from "node:async_hooks";
import { AsyncMutex } from "./async-mutex.js";

export class RequestSpanLane extends AsyncMutex {
  constructor(private readonly spanLabel: string) {
    super();
  }

  override run<T>(operation: () => Promise<T> | T, signal?: AbortSignal): Promise<T> {
    const span = currentRequestSpan();
    if (span === undefined) return super.run(operation, signal);
    return span.wait(
      this.spanLabel,
      (acquired) => super.run(() => {
        acquired();
        return operation();
      }, signal),
    );
  }
}


let activeSpans = 0;

let parkedSpans = 0;

export function requestsCompetingForLoop(): boolean {
  return activeSpans - parkedSpans > 0;
}

export class RequestSpan {
  private readonly entries = new Map<string, SpanEntry>();
  private readonly open = new Set<OpenMeasurement>();
  private offLoopDepth = 0;
  private parked = false;
  private sequence = 0;
  private finished = false;

  constructor() {
    activeSpans += 1;
  }

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
    const measurement = this.beginMeasurement(name);
    try {
      result = context === undefined
        ? operation()
        : storage.run({ span: this, openStage: stage }, operation);
    } catch (error) {
      this.closeStage(stage, measurement);
      throw error;
    }
    if (!isPromiseLike(result)) {
      this.closeStage(stage, measurement);
      return result;
    }
    return result.then(
      (value) => { this.closeStage(stage, measurement); return value as T; },
      (error) => { this.closeStage(stage, measurement); throw error; },
    );
  }

  wait<T>(name: string, operation: (acquired: () => void) => Promise<T>): Promise<T>;
  wait<T>(name: string, operation: (acquired: () => void) => T): T;
  wait<T>(name: string, operation: (acquired: () => void) => T | Promise<T>): T | Promise<T> {
    if (this.finished) return operation(() => {});
    const parent = this.context()?.openStage;
    const entry = this.entry(name);
    const startedAt = performance.now();
    const measurement = this.beginMeasurement(name);
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
      this.closeMeasurement(measurement);
      throw error;
    }
    if (!isPromiseLike(result)) {
      handover();
      this.closeMeasurement(measurement);
      return result;
    }
    return result.then(
      (value) => { handover(); this.closeMeasurement(measurement); return value as T; },
      (error) => { handover(); this.closeMeasurement(measurement); throw error; },
    );
  }

  enterStage(name: string): () => void {
    const measurement = this.beginMeasurement(name);
    return () => this.closeMeasurement(measurement);
  }

  currentStage(): string | undefined {
    let current: OpenMeasurement | undefined;
    for (const measurement of this.open) current = measurement;
    return current?.name;
  }

  count(name: string, n = 1): void {
    if (this.finished) return;
    this.entry(name).count += n;
  }

  bytes(name: string, n: number): void {
    if (this.finished || !Number.isFinite(n) || n < 0) return;
    this.entry(name).bytes += n;
  }

  offLoop<T>(operation: () => Promise<T>): Promise<T> {
    if (this.finished) return operation();
    if (this.offLoopDepth === 0) this.setParked(true);
    this.offLoopDepth += 1;
    const resume = (): void => {
      this.offLoopDepth -= 1;
      if (this.offLoopDepth === 0) this.setParked(false);
    };
    let result: Promise<T>;
    try {
      result = operation();
    } catch (error) {
      resume();
      throw error;
    }
    return result.then(
      (value) => { resume(); return value; },
      (error) => { resume(); throw error; },
    );
  }

  breakdown(requestMs: number, failed = false): RequestSpanBreakdown | undefined {
    if (!this.finished) {
      this.finished = true;
      activeSpans -= 1;
      this.setParked(false);
    }
    const recorded = [...this.entries.values()].filter((entry) => worthNaming(entry) || (failed && entry.timed))
      .sort((left, right) => right.ms - left.ms || left.order - right.order);
    if (recorded.length === 0) return undefined;
    const coveredMs = recorded.reduce((total, entry) => total + entry.ms, 0);
    return {
      stages: recorded.map(formatEntry).join(";"),
      unaccountedMs: Math.max(0, Math.round(requestMs - coveredMs)),
    };
  }

  private setParked(parked: boolean): void {
    if (this.parked === parked) return;
    this.parked = parked;
    parkedSpans += parked ? 1 : -1;
  }

  private beginMeasurement(name: string): OpenMeasurement {
    const measurement: OpenMeasurement = { name };
    this.open.add(measurement);
    return measurement;
  }

  private closeMeasurement(measurement: OpenMeasurement): void {
    this.open.delete(measurement);
  }

  private closeStage(stage: OpenStage, measurement?: OpenMeasurement): void {
    if (measurement) this.open.delete(measurement);
    if (stage.closed) return;
    stage.closed = true;
    const exclusiveMs = Math.max(0, elapsedSince(stage.startedAt) - stage.childMs);
    stage.entry.ms += exclusiveMs;
    stage.entry.timed = true;
    stage.entry.count += 1;
    if (stage.parent) stage.parent.childMs += exclusiveMs;
  }

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

interface RequestSpanBreakdown {
  stages: string;
  unaccountedMs: number;
}

interface OpenMeasurement {
  readonly name: string;
}

interface SpanEntry {
  readonly name: string;
  readonly order: number;
  ms: number;
  count: number;
  bytes: number;
  timed: boolean;
}

interface OpenStage {
  readonly entry: SpanEntry;
  readonly startedAt: number;
  readonly parent: OpenStage | undefined;
  childMs: number;
  closed: boolean;
}

interface RequestSpanContext {
  readonly span: RequestSpan;
  readonly openStage: OpenStage | undefined;
}

const storage = new AsyncLocalStorage<RequestSpanContext>();

export function runInRequestSpan<T>(span: RequestSpan, operation: () => T): T {
  return storage.run({ span, openStage: undefined }, operation);
}

export function currentRequestSpan(): RequestSpan | undefined {
  return storage.getStore()?.span;
}

export function stage<T>(name: string, operation: () => Promise<T>): Promise<T>;
export function stage<T>(name: string, operation: () => T): T;
export function stage<T>(name: string, operation: () => T | Promise<T>): T | Promise<T> {
  const span = storage.getStore()?.span;
  return span === undefined ? operation() : span.stage(name, operation);
}

export function wait<T>(name: string, operation: (acquired: () => void) => Promise<T>): Promise<T>;
export function wait<T>(name: string, operation: (acquired: () => void) => T): T;
export function wait<T>(name: string, operation: (acquired: () => void) => T | Promise<T>): T | Promise<T> {
  const span = storage.getStore()?.span;
  return span === undefined ? operation(() => {}) : span.wait(name, operation);
}

export function count(name: string, n = 1): void {
  storage.getStore()?.span.count(name, n);
}

export function offLoop<T>(operation: () => Promise<T>): Promise<T> {
  const span = storage.getStore()?.span;
  return span === undefined ? operation() : span.offLoop(operation);
}

export function bytes(name: string, n: number): void {
  storage.getStore()?.span.bytes(name, n);
}

function elapsedSince(startedAt: number): number {
  return Math.max(0, performance.now() - startedAt);
}

function isPromiseLike(value: unknown): value is PromiseLike<unknown> {
  return typeof (value as { then?: unknown } | null)?.then === "function";
}

function worthNaming(entry: SpanEntry): boolean {
  return entry.bytes > 0 || (entry.timed ? Math.round(entry.ms) > 0 : entry.count > 0);
}

function formatEntry(entry: SpanEntry): string {
  let detail = entry.timed ? `${Math.round(entry.ms)}ms` : "";
  if (entry.count > 1 || detail.length === 0) detail += `×${entry.count}`;
  if (entry.bytes > 0) detail += `/${entry.bytes >= 1_024 ? `${Math.round(entry.bytes / 1_024)}KB` : `${Math.round(entry.bytes)}B`}`;
  return `${entry.name}=${detail}`;
}
