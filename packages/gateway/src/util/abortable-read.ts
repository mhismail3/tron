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
