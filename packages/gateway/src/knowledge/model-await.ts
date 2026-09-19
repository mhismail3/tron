/**
 * Bounds one Gateway-owned await against an abort signal at the knowledge model
 * boundary.
 *
 * Model adapters are not required to honor `AbortSignal`, so an uncooperative
 * implementation must not hold a caller, an RPC, or a work token open after its
 * deadline. The returned promise rejects as soon as the signal aborts; the
 * caller's own fence (an aborted-attempt check plus a revision/scope
 * revalidation before publication) keeps the late result from becoming durable
 * evidence. This bounds the *wait*, never the underlying operation's ownership.
 */
export function awaitAbortable<T>(promise: Promise<T>, signal: AbortSignal, failure: () => Error): Promise<T> {
  if (signal.aborted) {
    // The abandoned operation still owns its own settlement; observe it so it
    // cannot surface as an unhandled rejection without admitting its result.
    void promise.catch(() => {});
    return Promise.reject(failure());
  }
  return new Promise<T>((resolve, reject) => {
    const onAbort = () => reject(failure());
    signal.addEventListener("abort", onAbort, { once: true });
    promise.then(
      (value) => { signal.removeEventListener("abort", onAbort); resolve(value); },
      (error) => { signal.removeEventListener("abort", onAbort); reject(error); },
    );
  });
}
