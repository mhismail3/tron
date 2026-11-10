export class QueuedWorkGate {
  private active = 0;
  private readonly waiters: Array<() => void> = [];

  constructor(private readonly maximum: number) {
    if (!Number.isSafeInteger(maximum) || maximum < 1) throw new Error("Queued work gate bound is invalid");
  }

  async run<T>(signal: AbortSignal | undefined, work: () => Promise<T>): Promise<T> {
    if (this.active >= this.maximum) {
      await this.waitForTurn(signal);
    } else {
      this.active += 1;
    }
    try {
      return await work();
    } finally {
      const next = this.waiters.shift();
      if (next === undefined) this.active -= 1;
      else next();
    }
  }

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
