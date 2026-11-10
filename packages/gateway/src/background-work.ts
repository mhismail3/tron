import { monitorEventLoopDelay } from "node:perf_hooks";

type EventLoopDelayHistogram = ReturnType<typeof monitorEventLoopDelay>;

const BACKGROUND_PAUSE_P99_MS = 50;

const BACKGROUND_PAUSE_RECHECK_MS = 100;

const BACKGROUND_BACKLOG_WARNING_MS = 5 * 60_000;

const BACKGROUND_EVENT_LOOP_RESOLUTION_MS = 10;

export interface BackgroundWorkJob {
  name: string;
  intervalMs: number;
  slice: () => Promise<void> | void;
}

export interface BackgroundWorkRegistration {
  register(job: BackgroundWorkJob): () => void;
  yieldToLoop(): Promise<void>;
}

type BackgroundPauseReason = "requests-in-flight" | "event-loop-p99";

interface BackgroundSliceRecord {
  job: string;
  outcome: "completed" | "failed";
  durationMs: number;
  waitedMs: number;
  error?: unknown;
}

interface BackgroundBacklogRecord {
  job: string;
  waitedMs: number;
  reason: BackgroundPauseReason;
  jobs: number;
  due: number;
}

interface BackgroundWorkStartOptions {
  requestsInFlight: () => boolean;
  onSlice?: (record: BackgroundSliceRecord) => void;
  onBacklog?: (record: BackgroundBacklogRecord) => void;
}

interface RegisteredJob {
  job: BackgroundWorkJob;
  nextDueAt: number;
  reportedPause: BackgroundPauseReason | undefined;
}

class BackgroundWorkScheduler implements BackgroundWorkRegistration {
  private readonly jobs = new Map<string, RegisteredJob>();
  private started = false;
  private running = false;
  private pending: { handle: unknown; immediate: boolean } | undefined;
  private readonly now: () => number = Date.now;
  private readonly immediate: (callback: () => void) => unknown = (callback) => setImmediate(callback);
  private readonly timer: (callback: () => void, delayMs: number) => unknown = (callback, delayMs) => {
    const handle = setTimeout(callback, delayMs);
    handle.unref();
    return handle;
  };
  private readonly cancelImmediate: (handle: unknown) => void = (handle) => clearImmediate(handle as NodeJS.Immediate);
  private readonly cancelTimer: (handle: unknown) => void = (handle) => clearTimeout(handle as NodeJS.Timeout);
  private requestsInFlight: () => boolean = () => false;
  private histogram: EventLoopDelayHistogram | undefined;
  private onSlice: ((record: BackgroundSliceRecord) => void) | undefined;
  private onBacklog: ((record: BackgroundBacklogRecord) => void) | undefined;

  register(job: BackgroundWorkJob): () => void {
    if (!(job.intervalMs > 0) || !Number.isFinite(job.intervalMs)) {
      throw new Error(`Background job ${job.name} has no interval`);
    }
    const registered: RegisteredJob = { job, nextDueAt: this.now() + job.intervalMs, reportedPause: undefined };
    this.jobs.set(job.name, registered);
    if (this.started) {
      this.cancelPending();
      this.wake();
    }
    return () => this.unregister(registered);
  }

  yieldToLoop(): Promise<void> {
    return new Promise((resolve) => {
      if (!this.started) {
        this.immediate(resolve);
        return;
      }
      const step = (): void => {
        if (!this.started) { resolve(); return; }
        if (this.pauseReason() !== undefined) { this.timer(step, BACKGROUND_PAUSE_RECHECK_MS); return; }
        this.immediate(resolve);
      };
      step();
    });
  }

  start(options: BackgroundWorkStartOptions): void {
    if (this.started) return;
    this.started = true;
    this.requestsInFlight = options.requestsInFlight;
    this.onSlice = options.onSlice;
    this.onBacklog = options.onBacklog;
    for (const registered of this.jobs.values()) registered.nextDueAt = this.now() + registered.job.intervalMs;
    this.wake();
  }

  stop(): void {
    this.started = false;
    this.cancelPending();
    this.histogram?.disable();
    this.histogram = undefined;
  }

  private unregister(registered: RegisteredJob): void {
    if (this.jobs.get(registered.job.name) === registered) this.jobs.delete(registered.job.name);
  }

  private wake(): void {
    if (!this.started || this.running || this.pending) return;
    const pending: { handle: unknown; immediate: boolean } = { handle: undefined, immediate: true };
    this.pending = pending;
    pending.handle = this.immediate(() => this.tick());
  }

  private wait(delayMs: number): void {
    if (!this.started || this.running || this.pending) return;
    const pending: { handle: unknown; immediate: boolean } = { handle: undefined, immediate: false };
    this.pending = pending;
    pending.handle = this.timer(() => this.tick(), delayMs);
  }

  private cancelPending(): void {
    const pending = this.pending;
    this.pending = undefined;
    if (!pending) return;
    if (pending.immediate) this.cancelImmediate(pending.handle);
    else this.cancelTimer(pending.handle);
  }

  private tick(): void {
    this.pending = undefined;
    if (!this.started) return;
    const now = this.now();
    const due = this.earliestDue(now);
    if (!due) {
      const nextDueAt = this.nextDueAt();
      if (nextDueAt !== undefined) this.wait(Math.max(1, nextDueAt - now));
      return;
    }
    const pause = this.pauseReason();
    if (pause) {
      this.reportBacklog(due, pause, now);
      this.wait(BACKGROUND_PAUSE_RECHECK_MS);
      return;
    }
    this.runSlice(due, now);
  }

  private pauseReason(): BackgroundPauseReason | undefined {
    if (this.requestsInFlight()) return "requests-in-flight";
    return this.eventLoopP99Ms() >= BACKGROUND_PAUSE_P99_MS ? "event-loop-p99" : undefined;
  }

  private runSlice(due: RegisteredJob, now: number): void {
    const waitedMs = Math.max(0, now - due.nextDueAt);
    due.reportedPause = undefined;
    due.nextDueAt = now + due.job.intervalMs;
    const startedAt = this.now();
    this.running = true;
    void Promise.resolve()
      .then(() => due.job.slice())
      .then(
        () => this.reportSlice(due, waitedMs, startedAt, "completed"),
        (error: unknown) => this.reportSlice(due, waitedMs, startedAt, "failed", error),
      )
      .then(() => {
        this.running = false;
        this.wake();
      });
  }

  private reportSlice(
    due: RegisteredJob,
    waitedMs: number,
    startedAt: number,
    outcome: BackgroundSliceRecord["outcome"],
    error?: unknown,
  ): void {
    this.onSlice?.({
      job: due.job.name,
      outcome,
      durationMs: Math.max(0, this.now() - startedAt),
      waitedMs,
      ...(error === undefined ? {} : { error }),
    });
  }

  private reportBacklog(due: RegisteredJob, reason: BackgroundPauseReason, now: number): void {
    if (due.reportedPause !== undefined) return;
    const waitedMs = Math.max(0, now - due.nextDueAt);
    if (waitedMs < BACKGROUND_BACKLOG_WARNING_MS) return;
    due.reportedPause = reason;
    this.onBacklog?.({
      job: due.job.name,
      waitedMs,
      reason,
      jobs: this.jobs.size,
      due: [...this.jobs.values()].filter((registered) => registered.nextDueAt <= now).length,
    });
  }

  private earliestDue(now: number): RegisteredJob | undefined {
    let earliest: RegisteredJob | undefined;
    for (const registered of this.jobs.values()) {
      if (registered.nextDueAt > now) continue;
      if (!earliest || registered.nextDueAt < earliest.nextDueAt) earliest = registered;
    }
    return earliest;
  }

  private nextDueAt(): number | undefined {
    let earliest: number | undefined;
    for (const registered of this.jobs.values()) {
      if (earliest === undefined || registered.nextDueAt < earliest) earliest = registered.nextDueAt;
    }
    return earliest;
  }

  private eventLoopP99Ms(): number {
    this.histogram ??= this.beginHistogram();
    const p99 = this.histogram.percentile(99);
    this.histogram.reset();
    if (!Number.isFinite(p99)) return 0;
    return Math.max(0, p99 / 1e6 - BACKGROUND_EVENT_LOOP_RESOLUTION_MS);
  }

  private beginHistogram(): EventLoopDelayHistogram {
    const histogram = monitorEventLoopDelay({ resolution: BACKGROUND_EVENT_LOOP_RESOLUTION_MS });
    histogram.enable();
    return histogram;
  }
}

export const backgroundWork = new BackgroundWorkScheduler();
