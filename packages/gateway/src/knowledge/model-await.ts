/**
 * A bounded caller wait paired with the underlying operation's settlement.
 * Abort rejects `wait`, not the provider; `settled` lets owners retain lifecycle
 * state until the underlying operation really finishes.
 */
export interface AbortableOperation<T> {
  wait: Promise<T>;
  settled: Promise<void>;
}

export function awaitAbortableWithSettlement<T>(promise: Promise<T>, signal: AbortSignal, failure: () => Error): AbortableOperation<T> {
  const settled = promise.then(() => undefined, () => undefined);
  if (signal.aborted) {
    return { wait: Promise.reject(failure()), settled };
  }
  const wait = new Promise<T>((resolve, reject) => {
    const onAbort = () => reject(failure());
    signal.addEventListener("abort", onAbort, { once: true });
    promise.then(
      (value) => { signal.removeEventListener("abort", onAbort); resolve(value); },
      (error) => { signal.removeEventListener("abort", onAbort); reject(error); },
    );
  });
  return { wait, settled };
}
