/**
 * One bounded concurrency gate with FIFO queueing (`G-12`): the cap bounds work
 * in flight, not the requests admitted to it, so the third caller waits its turn
 * instead of running beside two others. A waiter whose requester left is dropped
 * — the work it queued for would have no audience — while work already running
 * keeps the owner that admitted it. Each gate's bound and its reason live next
 * to that gate's only user.
 */
export class QueuedWorkGate {
  private active = 0;
  private readonly waiters: Array<() => void> = [];

  constructor(private readonly maximum: number) {
    if (!Number.isSafeInteger(maximum) || maximum < 1) throw new Error("Queued work gate bound is invalid");
  }

  async run<T>(signal: AbortSignal | undefined, work: () => Promise<T>): Promise<T> {
    while (this.active >= this.maximum) await this.waitForTurn(signal);
    this.active += 1;
    try {
      return await work();
    } finally {
      this.active -= 1;
      this.waiters.shift()?.();
    }
  }

  /** One FIFO place in the queue. An abort removes the waiter, so a place that
   * is released next is never handed to a requester that already left. */
  private waitForTurn(signal: AbortSignal | undefined): Promise<void> {
    if (signal?.aborted) return Promise.reject(signal.reason);
    return new Promise<void>((resolve, reject) => {
      const waiter = (): void => {
        signal?.removeEventListener("abort", abort);
        resolve();
      };
      const abort = (): void => {
        const index = this.waiters.indexOf(waiter);
        if (index >= 0) this.waiters.splice(index, 1);
        reject(signal?.reason);
      };
      this.waiters.push(waiter);
      signal?.addEventListener("abort", abort, { once: true });
    });
  }
}
