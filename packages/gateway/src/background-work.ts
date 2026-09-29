import { monitorEventLoopDelay, type IntervalHistogram } from "node:perf_hooks";

/** The event-loop delay p99 at or above which the scheduler starts no new
 * slice: the loop is already behind the interactive work the pause exists to
 * protect, and one more slice would extend the delay it would add to. */
export const BACKGROUND_PAUSE_P99_MS = 50;

/** How long a paused scheduler waits before it re-checks whether it may start a
 * slice. Re-checking with no delay would spin the loop the pause protects. */
export const BACKGROUND_PAUSE_RECHECK_MS = 100;

/** How late a due slice may be before the scheduler records
 * `background.backlog`. A slice this far past its due time is starved, not
 * merely scheduled behind another slice; one record per starved spell keeps a
 * long pause from filling the log one tick at a time. */
export const BACKGROUND_BACKLOG_WARNING_MS = 5 * 60_000;

/** The delay histogram's sampling period. The scheduler's own soundings only
 * have to tell a slow slice from a loop with headroom, and a finer period would
 * cost more timer wakeups than the answer is worth. */
const BACKGROUND_EVENT_LOOP_RESOLUTION_MS = 10;

/** One recurring background job. Its work is already bounded by its owner; the
 * scheduler owns when a slice of it may start. */
export interface BackgroundWorkJob {
  /** `area.noun`, the name its records carry. */
  name: string;
  /** How often one slice is due. */
  intervalMs: number;
  /** One bounded slice. The scheduler starts no other slice until this settles,
   * so a job that has a lot to do stays interactive by awaiting inside itself. */
  slice: () => Promise<void> | void;
}

/** What a background owner registers with: the process-wide scheduler, or a
 * test's own instance. */
export interface BackgroundWorkRegistration {
  register(job: BackgroundWorkJob): () => void;
  /** Hands the loop back between the bounded batches of one slice, and waits
   * while the scheduler is paused. A slice with more work than one batch stays
   * interactive by awaiting this between batches instead of holding the loop. */
  yieldToLoop(): Promise<void>;
}

/** Why a due slice did not start. */
export type BackgroundPauseReason = "requests-in-flight" | "event-loop-p99";

/** One started slice, for `background.slice`. */
export interface BackgroundSliceRecord {
  job: string;
  /** `failed` is a slice that rejected; the scheduler keeps running, so the
   * owner's next slice is what recovers it. */
  outcome: "completed" | "failed";
  durationMs: number;
  /** How long the slice was due before it started. */
  waitedMs: number;
  error?: unknown;
}

/** One job starved past `BACKGROUND_BACKLOG_WARNING_MS`, for
 * `background.backlog`. */
export interface BackgroundBacklogRecord {
  job: string;
  /** How long the job's slice has been due without starting. */
  waitedMs: number;
  reason: BackgroundPauseReason;
  /** Jobs registered, and jobs whose slice is due right now. */
  jobs: number;
  due: number;
}

export interface BackgroundWorkClock {
  now?: () => number;
  immediate?: (callback: () => void) => unknown;
  timer?: (callback: () => void, delayMs: number) => unknown;
  cancelImmediate?: (handle: unknown) => void;
  cancelTimer?: (handle: unknown) => void;
}

export interface BackgroundWorkStartOptions extends BackgroundWorkClock {
  /** True while a request is competing for the loop. The scheduler asks this at
   * every tick and starts nothing while it is true, so an interactive request
   * never shares the loop with a background slice. */
  requestsInFlight: () => boolean;
  /** The loop's p99 delay over the window since the previous sounding. Defaults
   * to the scheduler's own `monitorEventLoopDelay` histogram, read and reset per
   * sounding; a test supplies its own. */
  eventLoopP99Ms?: () => number;
  onSlice?: (record: BackgroundSliceRecord) => void;
  onBacklog?: (record: BackgroundBacklogRecord) => void;
}

interface RegisteredJob {
  job: BackgroundWorkJob;
  /** When the next slice of this job is due. */
  nextDueAt: number;
  /** The pause this job's pending slice was first reported under, so one starved
   * spell is one record. Cleared when the slice starts. */
  reportedPause: BackgroundPauseReason | undefined;
}

/**
 * The one owner of when background work runs. Registered jobs take turns one
 * slice at a time, each slice yields to the loop before the next is armed, and
 * a due slice waits while a request is in flight or the loop is behind. A
 * failing slice is reported and never stops the scheduler or the jobs after it.
 *
 * Records are diagnostics, not state: a slice that is late is visible as
 * `background.backlog`, and one that ran as `background.slice`.
 */
export class BackgroundWorkScheduler implements BackgroundWorkRegistration {
  private readonly jobs = new Map<string, RegisteredJob>();
  private started = false;
  private running = false;
  /** The one armed wake. A second one would let two ticks run two slices. */
  private pending: { handle: unknown; immediate: boolean } | undefined;
  private now: () => number = Date.now;
  private immediate: (callback: () => void) => unknown = (callback) => setImmediate(callback);
  private timer: (callback: () => void, delayMs: number) => unknown = (callback, delayMs) => {
    const handle = setTimeout(callback, delayMs);
    handle.unref();
    return handle;
  };
  private cancelImmediate: (handle: unknown) => void = (handle) => clearImmediate(handle as NodeJS.Immediate);
  private cancelTimer: (handle: unknown) => void = (handle) => clearTimeout(handle as NodeJS.Timeout);
  private requestsInFlight: () => boolean = () => false;
  private readP99: (() => number) | undefined;
  private histogram: IntervalHistogram | undefined;
  private onSlice: ((record: BackgroundSliceRecord) => void) | undefined;
  private onBacklog: ((record: BackgroundBacklogRecord) => void) | undefined;

  register(job: BackgroundWorkJob): () => void {
    if (!(job.intervalMs > 0) || !Number.isFinite(job.intervalMs)) {
      throw new Error(`Background job ${job.name} has no interval`);
    }
    // One job per name: a second registration would schedule the same work
    // twice under one record.
    const registered: RegisteredJob = { job, nextDueAt: this.now() + job.intervalMs, reportedPause: undefined };
    this.jobs.set(job.name, registered);
    if (this.started) {
      // The armed wake may be waiting for a job that is now the later one.
      this.cancelPending();
      this.wake();
    }
    return () => this.unregister(registered);
  }

  /**
   * One turn of the loop, or a re-check interval while the scheduler is paused:
   * a slice that has more to do than one bounded batch awaits this between
   * batches, so a request that arrives mid-slice is served before the next batch
   * and the slice's own records stay one per slice. The re-check timer is this
   * promise's own, not the scheduler's armed wake, so it cannot start a second
   * slice. Resolves on the next turn when the scheduler was never started, and
   * when it is stopped: nothing is being paced then.
   */
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
    if (options.now) this.now = options.now;
    if (options.immediate) this.immediate = options.immediate;
    if (options.timer) this.timer = options.timer;
    if (options.cancelImmediate) this.cancelImmediate = options.cancelImmediate;
    if (options.cancelTimer) this.cancelTimer = options.cancelTimer;
    this.requestsInFlight = options.requestsInFlight;
    this.readP99 = options.eventLoopP99Ms;
    this.onSlice = options.onSlice;
    this.onBacklog = options.onBacklog;
    for (const registered of this.jobs.values()) registered.nextDueAt = this.now() + registered.job.intervalMs;
    this.wake();
  }

  stop(): void {
    this.started = false;
    this.cancelPending();
    // A slice already in flight is its owner's work and settles on its own; the
    // scheduler only stops arming the next one.
    this.histogram?.disable();
    this.histogram = undefined;
  }

  /** Removes this exact registration: a later registration under the same name
   * owns that name now, so this one's dispose must not delete the replacement. */
  private unregister(registered: RegisteredJob): void {
    if (this.jobs.get(registered.job.name) === registered) this.jobs.delete(registered.job.name);
  }

  private wake(): void {
    if (!this.started || this.running || this.pending) return;
    // Claimed before the handle exists: a clock that runs the callback inline
    // (a test's) must not see an unarmed wake and arm a second one.
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
      // Nothing registered is nothing to wait for: the next registration wakes
      // the scheduler.
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

  /** Why no slice may start right now, or none. The loop's own delay is read
   * only when no request is in flight: the pause the requests already impose is
   * the stronger one, and its sounding must not be spent on a tick that cannot
   * start a slice anyway. */
  private pauseReason(): BackgroundPauseReason | undefined {
    if (this.requestsInFlight()) return "requests-in-flight";
    return this.eventLoopP99Ms() >= BACKGROUND_PAUSE_P99_MS ? "event-loop-p99" : undefined;
  }

  /** One slice, then one yield: the next wake is an immediate, which runs in the
   * loop's check phase after the poll phase's timers and I/O, so a slice is
   * never two sides of one loop iteration. */
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

  /** One record per starved spell, so a pause that lasts an hour reports its
   * cause rather than repeating it every `BACKGROUND_PAUSE_RECHECK_MS`. */
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
    if (this.readP99) return this.readP99();
    this.histogram ??= this.beginHistogram();
    const p99 = this.histogram.percentile(99);
    // Read and reset: a percentile over the process's whole life would let one
    // past stall pause every later slice, and the soundings must describe the
    // window since the previous one.
    this.histogram.reset();
    if (!Number.isFinite(p99)) return 0;
    return Math.max(0, p99 / 1e6 - BACKGROUND_EVENT_LOOP_RESOLUTION_MS);
  }

  private beginHistogram(): IntervalHistogram {
    const histogram = monitorEventLoopDelay({ resolution: BACKGROUND_EVENT_LOOP_RESOLUTION_MS });
    histogram.enable();
    return histogram;
  }
}

/**
 * The Gateway's one scheduler. It is process-wide because the owners that
 * register jobs (the session catalog, session search) are constructed behind the
 * session registry, which `gateway-main.ts` does not build; `gateway-main.ts`
 * still owns starting it, so a scheduler no one started runs nothing, and the
 * owners take it as an injectable dependency so a test drives its own instance.
 */
export const backgroundWork = new BackgroundWorkScheduler();
