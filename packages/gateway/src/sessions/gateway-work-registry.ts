import { randomUUID } from "node:crypto";
import { performance } from "node:perf_hooks";
import { GatewayError } from "../errors.js";

export const gatewayWorkKinds = [
  "slot-admission",
  "prompt-preflight",
  "foreground-agent-operation",
  "queued-mutation",
  "compaction-export",
  "terminal-receipt-persistence",
  "extension-command-prompt-ui",
  "administrative-provider-package-operation",
  "automation-dispatch",
  "automation-terminal-persistence",
] as const;

export type GatewayWorkKind = typeof gatewayWorkKinds[number];

export interface GatewayWorkFact {
  token: string;
  kind: GatewayWorkKind;
  sessionId?: string;
  hostEpoch: string;
  admittedAt: string;
  admittedMonotonicMs: number;
  progressAt: string;
  progressMonotonicMs: number;
  cancellable: boolean;
}

interface GatewayWorkEntry extends GatewayWorkFact {
  pool: "normal" | "derived";
  settle: () => void;
  settled: Promise<void>;
  cancellation?: () => Promise<void> | void;
  cancellationStarted?: Promise<void>;
}

export interface GatewayWorkAdmission {
  kind: GatewayWorkKind;
  sessionId?: string;
  hostEpoch: string;
  cancellation?: () => Promise<void> | void;
}

export interface GatewayWorkHandle {
  readonly token: string;
  readonly settled: Promise<void>;
  transition(kind: GatewayWorkKind): void;
  progress(): void;
  settle(): void;
}

/**
 * Bounded process-local ownership for work accepted by this Gateway epoch.
 * Tokens are never persisted and never expire by age. An entry leaves only by
 * exact owner settlement or a cancellation callback followed by owner settlement.
 */
export class GatewayWorkRegistry {
  private readonly entries = new Map<string, GatewayWorkEntry>();
  private admissionsOpen = true;
  private derivedAdmissionsOpen = true;
  private cancellationRequested = false;
  private idleWaiters: Array<() => void> = [];
  private readonly normalAdmissionLimit: number;
  private readonly derivedAdmissionLimit: number;
  private normalEntryCount = 0;
  private derivedEntryCount = 0;

  constructor(
    readonly runtimeEpoch: string = randomUUID(),
    private readonly maximumEntries = 2_048,
    private readonly now: () => number = Date.now,
    private readonly monotonicNow: () => number = performance.now.bind(performance),
  ) {
    if (!Number.isSafeInteger(maximumEntries) || maximumEntries < 1) {
      throw new Error("Gateway work registry bound is invalid");
    }
    // Keep terminal settlement capacity independent from normal admission.
    // The production derived half covers 16 slots * 64 retained activities.
    const derivedReserve = maximumEntries > 1 ? Math.floor(maximumEntries / 2) : 0;
    this.normalAdmissionLimit = maximumEntries - derivedReserve;
    this.derivedAdmissionLimit = derivedReserve;
  }

  get size(): number { return this.entries.size; }
  get isAdmissionOpen(): boolean { return this.admissionsOpen; }
  hasSessionWork(sessionId: string): boolean {
    return [...this.entries.values()].some((entry) => entry.sessionId === sessionId);
  }

  begin(admission: GatewayWorkAdmission): GatewayWorkHandle {
    if (!this.admissionsOpen) {
      throw new GatewayError("busy", "Gateway restart is draining admitted work", true);
    }
    return this.admit(admission, false);
  }

  /** Admit settlement work derived from an exact token/artifact accepted before
   * the drain cutoff. Callers must already own that authority; this is not an
   * external admission surface. */
  beginDerived(admission: GatewayWorkAdmission): GatewayWorkHandle {
    if (!this.derivedAdmissionsOpen) {
      throw new GatewayError("busy", "Gateway drain has completed", true);
    }
    return this.admit(admission, true);
  }

  private admit(admission: GatewayWorkAdmission, derived: boolean): GatewayWorkHandle {
    const poolCount = derived ? this.derivedEntryCount : this.normalEntryCount;
    const poolLimit = derived ? this.derivedAdmissionLimit : this.normalAdmissionLimit;
    if (this.entries.size >= this.maximumEntries || poolCount >= poolLimit) {
      throw new GatewayError("busy", "Gateway work registry reached its bounded capacity", true);
    }
    if (!gatewayWorkKinds.includes(admission.kind)) throw new Error("Gateway work kind is invalid");
    const token = randomUUID();
    const wall = new Date(this.now()).toISOString();
    const monotonic = this.monotonicNow();
    let resolveSettled!: () => void;
    const settled = new Promise<void>((resolve) => { resolveSettled = resolve; });
    const entry: GatewayWorkEntry = {
      token,
      kind: admission.kind,
      pool: derived ? "derived" : "normal",
      ...(admission.sessionId ? { sessionId: admission.sessionId } : {}),
      hostEpoch: admission.hostEpoch,
      admittedAt: wall,
      admittedMonotonicMs: monotonic,
      progressAt: wall,
      progressMonotonicMs: monotonic,
      cancellable: admission.cancellation !== undefined,
      ...(admission.cancellation ? { cancellation: admission.cancellation } : {}),
      settle: resolveSettled,
      settled,
    };
    this.entries.set(token, entry);
    if (derived) this.derivedEntryCount += 1;
    else this.normalEntryCount += 1;
    const owned = (): GatewayWorkEntry | undefined => this.entries.get(token) === entry ? entry : undefined;
    const handle: GatewayWorkHandle = {
      token,
      settled,
      transition: (kind) => {
        const current = owned();
        if (!current) return;
        if (!gatewayWorkKinds.includes(kind)) throw new Error("Gateway work kind is invalid");
        current.kind = kind;
        this.markProgress(current);
      },
      progress: () => {
        const current = owned();
        if (current) this.markProgress(current);
      },
      settle: () => this.settle(token, entry),
    };
    if (this.cancellationRequested && entry.cancellation) void this.cancelEntry(entry);
    return handle;
  }

  private markProgress(entry: GatewayWorkEntry): void {
    entry.progressAt = new Date(this.now()).toISOString();
    entry.progressMonotonicMs = this.monotonicNow();
  }

  private settle(token: string, entry: GatewayWorkEntry): void {
    if (this.entries.get(token) !== entry) return;
    this.entries.delete(token);
    if (entry.pool === "derived") this.derivedEntryCount -= 1;
    else this.normalEntryCount -= 1;
    entry.settle();
    if (this.entries.size === 0) {
      const waiters = this.idleWaiters.splice(0);
      for (const waiter of waiters) waiter();
    }
  }

  beginDrain(): void { this.admissionsOpen = false; }
  completeDrain(): void { this.derivedAdmissionsOpen = false; }

  /** Cancellation is fenced by the exact callback installed at admission.
   * Cancellation acknowledgement does not itself classify work as successful;
   * the owner still removes the token through settle(). */
  async requestCancellation(): Promise<void> {
    this.cancellationRequested = true;
    await Promise.allSettled([...this.entries.values()].map((entry) => this.cancelEntry(entry)));
  }

  private cancelEntry(entry: GatewayWorkEntry): Promise<void> {
    if (!entry.cancellation) return Promise.resolve();
    if (entry.cancellationStarted) return entry.cancellationStarted;
    entry.cancellationStarted = Promise.resolve().then(entry.cancellation);
    return entry.cancellationStarted;
  }

  facts(): GatewayWorkFact[] {
    return [...this.entries.values()].map(({ pool: _pool, settle: _settle, settled: _settled, cancellation: _cancellation, cancellationStarted: _cancellationStarted, ...fact }) => ({ ...fact }));
  }

  waitUntilSettled(): Promise<void> {
    if (this.entries.size === 0) return Promise.resolve();
    return new Promise((resolve) => this.idleWaiters.push(resolve));
  }
}
