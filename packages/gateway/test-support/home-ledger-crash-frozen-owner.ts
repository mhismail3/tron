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
