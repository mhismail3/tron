/**
 * A bounded caller wait paired with the underlying operation's settlement.
 * Abort only rejects `wait`; `settled` remains owned by the adapter boundary so
 * callers can retire lifecycle tokens after the provider really finishes.
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

/**
 * Bounds the caller's wait without claiming that an uncooperative model has
 * stopped. Use `awaitAbortableWithSettlement` when the caller owns lifecycle
 * state that must remain active until the adapter promise settles.
 */
export function awaitAbortable<T>(promise: Promise<T>, signal: AbortSignal, failure: () => Error): Promise<T> {
  return awaitAbortableWithSettlement(promise, signal, failure).wait;
}
