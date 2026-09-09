export class AsyncMutex {
  private locked = false;
  private readonly waiting = new Set<() => void>();

  /** Cancellation removes a queued read. An already running operation still
   * owns the lock and its result until it actually settles; a disposable caller
   * may separately abandon that wait with abortableRead and release late values.
   * Accepted mutations never inherit a transport signal. */
  run<T>(operation: () => Promise<T> | T, signal?: AbortSignal): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      if (signal?.aborted) { reject(signal.reason); return; }
      let started = false;
      let delivered = false;
      const deliver = (completion: () => void): void => {
        if (delivered) return;
        delivered = true;
        signal?.removeEventListener("abort", abort);
        completion();
      };
      const abort = (): void => {
        if (started) return;
        this.waiting.delete(start);
        deliver(() => reject(signal!.reason));
      };
      const release = (): void => {
        this.locked = false;
        this.startNext();
      };
      const start = (): void => {
        started = true;
        // Preserve asynchronous admission even when the mutex was idle.
        void Promise.resolve().then(() => {
          signal?.throwIfAborted();
          return operation();
        }).then(value => {
          release();
          deliver(() => resolve(value));
        }, error => {
          release();
          deliver(() => reject(error));
        });
      };
      this.waiting.add(start);
      signal?.addEventListener("abort", abort, { once: true });
      this.startNext();
    });
  }

  private startNext(): void {
    if (this.locked) return;
    const next = this.waiting.values().next().value;
    if (!next) return;
    this.waiting.delete(next);
    this.locked = true;
    next();
  }
}
