/** Abandon a disposable wait, not the underlying resource's ownership. Use
 * only with a producer that independently bounds active work (a cancellable
 * mutex queue or an admitted reader lease). This cannot make unbounded I/O
 * safe. Late acquired resources are returned to their original owner. */
export function abortableRead<T>(
  signal: AbortSignal | undefined,
  acquire: () => Promise<T>,
  releaseAbandoned?: (value: T) => Promise<void>,
): Promise<T> {
  if (!signal) return acquire();
  if (signal.aborted) return Promise.reject(signal.reason);
  return new Promise<T>((resolve, reject) => {
    let settled = false;
    const abort = (): void => {
      if (settled) return;
      settled = true;
      signal.removeEventListener("abort", abort);
      reject(signal.reason);
    };
    signal.addEventListener("abort", abort, { once: true });
    void Promise.resolve().then(() => {
      signal.throwIfAborted();
      return acquire();
    }).then(value => {
      if (settled) {
        // Cleanup errors cannot resurrect an abandoned request. The resource
        // owner retains its quota until its physical release completes.
        if (releaseAbandoned) void Promise.resolve().then(() => releaseAbandoned(value)).catch(() => {});
        return;
      }
      settled = true;
      signal.removeEventListener("abort", abort);
      resolve(value);
    }, error => {
      if (settled) return;
      settled = true;
      signal.removeEventListener("abort", abort);
      reject(error);
    });
  });
}
