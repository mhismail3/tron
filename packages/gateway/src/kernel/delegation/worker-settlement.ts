/** One worker runtime's settlement waiters. Publications wake the same sets
 * joined by task settlement; no projection or second liveness state is retained. */
export class WorkerSettlement {
  private readonly waiters = {
    detached: new Set<() => void>(),
    delivery: new Set<() => void>(),
  };
  constructor(private readonly graceMs: number) {}

  /** The operation deadline bounds each wait, then one native disposal grace.
   * A wake is a reason to re-read the live predicate, never proof of completion. */
  async until(kind: "detached" | "delivery", done: () => boolean, deadline: AbortSignal): Promise<boolean> {
    const waiters = this.waiters[kind];
    let timer: ReturnType<typeof setTimeout> | undefined;
    let resolveBound!: (value: "bound") => void;
    const bound = new Promise<"bound">(resolve => { resolveBound = resolve; });
    const start = (): void => { timer = setTimeout(() => resolveBound("bound"), this.graceMs); };
    if (deadline.aborted) start();
    else deadline.addEventListener("abort", start, { once: true });
    try {
      while (!done()) {
        let wake!: () => void;
        const changed = new Promise<"changed">(resolve => { wake = () => resolve("changed"); });
        waiters.add(wake);
        const outcome = await Promise.race([changed, bound]);
        waiters.delete(wake);
        if (outcome === "bound") break;
      }
    } finally {
      deadline.removeEventListener("abort", start);
      if (timer !== undefined) clearTimeout(timer);
    }
    return done();
  }

  publish(kind: "detached" | "delivery"): void {
    const set = this.waiters[kind];
    const waiters = [...set];
    set.clear();
    for (const wake of waiters) wake();
  }
}
