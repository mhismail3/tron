import { AsyncLocalStorage } from "node:async_hooks";

export class AsyncMutex {
  private locked = false;
  private readonly waiting = new Set<() => void>();

  run<T>(operation: () => Promise<T> | T, signal?: AbortSignal): Promise<T> {
    const context = AsyncLocalStorage.snapshot();
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
        void Promise.resolve().then(() => {
          signal?.throwIfAborted();
          return context(operation);
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
