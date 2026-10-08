/** A frozen writer cannot publish any later state. The fresh owner sees only
 * the completed durable writes, just as after abandonment at a crash cut.
 * The caller owns restoring its interception; this harness creates no timer,
 * process, alternate journal or production hook. */
export function freezeHomeLedgerWriter<Args extends unknown[], Result>(
  write: (...args: Args) => Promise<Result>,
  cut: (result: Result) => boolean,
): (...args: Args) => Promise<Result> {
  let frozen = false;
  return async (...args) => {
    if (frozen) throw new Error("frozen Home ledger owner");
    const result = await write(...args);
    if (cut(result)) { frozen = true; throw new Error("frozen Home ledger owner"); }
    return result;
  };
}
