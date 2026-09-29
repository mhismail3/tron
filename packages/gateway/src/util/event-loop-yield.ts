/** Hand the event loop back for one turn. An owner that slices a long
 * synchronous stretch yields between slices so an in-flight request runs
 * instead of waiting for the whole reindex or warm-up pass. */
export function yieldToEventLoop(): Promise<void> {
  return new Promise<void>(resolve => setImmediate(resolve));
}
