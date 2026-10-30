import type { ResponseTiming } from "../../kernel/host/request-policy.js";

export interface HomeResponseSample {
  event: "response-timing";
  count: 1;
  outcome: "completed" | "failed" | "interrupted" | "outcomeUnknown";
  firstVisibleMs: number | null;
  terminalMs: number;
  queueMs: number | null;
  modelMs: number;
  toolMs: number;
  complete: boolean;
}

interface Sample {
  accepted: number;
  started?: number;
  visible?: number;
  modelMs: number;
  models: Set<number>;
  toolMs: number;
  tools: Set<string>;
  toolsStarted?: number;
}

/** Volatile input correlation only. Completion exports scalars, never identities
 * or content; the canonical invocation receipt owns terminal truth. */
export class HomeResponseTiming implements ResponseTiming {
  private readonly samples = new Map<string, Sample>();
  constructor(private readonly emit: (sample: HomeResponseSample) => void) {}

  accepted(operation: string): void {
    if (!this.samples.has(operation)) this.samples.set(operation, {
      accepted: performance.now(), modelMs: 0, models: new Set(), toolMs: 0, tools: new Set(),
    });
  }

  transfer(from: string, to: string): void {
    const sample = this.samples.get(from);
    // A separately accepted target keeps its own admission clock. Native
    // receipts still terminalize the predecessor; never blend two inputs.
    if (!sample || this.samples.has(to)) return;
    this.samples.delete(from);
    this.samples.set(to, sample);
  }

  retire(): void {
    for (const operation of this.samples.keys()) this.terminal(operation, "outcomeUnknown");
  }

  started(operation: string | undefined): void {
    const sample = operation ? this.samples.get(operation) : undefined;
    if (sample && sample.started === undefined) sample.started = performance.now();
  }

  visible(operation: string | undefined): void {
    const sample = operation ? this.samples.get(operation) : undefined;
    if (sample && sample.visible === undefined) sample.visible = performance.now();
  }

  model(operation: string): () => void {
    const sample = this.samples.get(operation);
    const start = performance.now();
    sample?.models.add(start);
    return () => {
      if (sample?.models.delete(start)) sample.modelMs += performance.now() - start;
    };
  }

  tool(operation: string | undefined, id: string, started: boolean): void {
    const sample = operation ? this.samples.get(operation) : undefined;
    if (!sample) return;
    if (started) {
      if (!sample.tools.size) sample.toolsStarted = performance.now();
      sample.tools.add(id);
    } else if (sample.tools.delete(id) && !sample.tools.size && sample.toolsStarted !== undefined) {
      sample.toolMs += performance.now() - sample.toolsStarted;
      delete sample.toolsStarted;
    }
  }

  terminal(operation: string, outcome: HomeResponseSample["outcome"]): void {
    const sample = this.samples.get(operation);
    if (!sample) return;
    this.samples.delete(operation);
    const now = performance.now();
    const elapsed = (start: number | undefined) => start === undefined ? null : Math.max(0, Math.round(start - sample.accepted));
    this.emit({ event: "response-timing", count: 1, outcome,
      firstVisibleMs: elapsed(sample.visible), terminalMs: Math.round(now - sample.accepted),
      queueMs: elapsed(sample.started),
      modelMs: Math.round(sample.modelMs + [...sample.models].reduce((sum, start) => sum + now - start, 0)),
      toolMs: Math.round(sample.toolMs + (sample.toolsStarted === undefined ? 0 : now - sample.toolsStarted)),
      complete: outcome !== "outcomeUnknown" && sample.started !== undefined && sample.visible !== undefined && !sample.models.size && !sample.tools.size,
    });
  }
}
