import type { FileEntry, SessionManager } from "../pi/coding-agent.js";

/** One session's place in a lineage: a profile that chains sessions (Home's
 * chapters) answers these facts; the kernel never names the profile. A session
 * outside every lineage has no `lineageId` and is not sealed. */
export interface SessionLineageState {
  sessionId: string;
  /** Canonical writes are refused (a sealed member or an in-progress successor). */
  sealed: boolean;
  /** A reserved successor whose runtime is being created. */
  materializing?: boolean;
  lineageId?: string;
  ordinal?: number;
  attemptId?: string;
  expectedPath?: string;
}

/** The `sessionLineage` policy hook (k0-kernel.md §2.1): chapter state,
 * reserved successors and publication gating, read at each call. */
export interface SessionLineagePolicy {
  state(sessionId: string): SessionLineageState;
  /** Read-only evidence for an SDK-open candidate; the kernel throws the exact
   * refusal, if any. No session construction or publication runs in this read. */
  openRefusal(sessionId: string, path: string): Promise<Error | undefined>;
  /** Throws the lineage owner's refusal when the session may not be written. */
  assertWritable(sessionId: string): void;
  /** Exact refusal for an identity the native frame has selected as lineage-bound.
   * Read-only construction; the native owner retains the physical replacement guard. */
  identityRefusal(sessionId: string): Error;
  /** Every lineage member is fenced while its owner reconciles an uncertain publication. */
  publicationUncertain(): boolean;
}

/** Runtime operations a lineage successor is built on. The session owner keeps
 * the slots map, its mutex, admission and publication; profile modules own the
 * successor procedure and interpret their opaque write authority. */
export interface LineageRuntimePort<Runtime> {
  /** One construction flight per session: a live runtime is returned as
   * `existing`; a running flight is joined; otherwise `construct` runs once. */
  materializeRuntime(sessionId: string, construct: () => Promise<Runtime>): Promise<{ slot: Runtime; existing: boolean }>;
  /** The live runtime now, without the registry mutex. */
  runtimeOf(sessionId: string): Runtime | undefined;
  /** The live runtime as the registry mutex orders it. */
  liveRuntime(sessionId: string): Promise<Runtime | undefined>;
  sessionDirectory(cwd: string): string;
  /** A session's canonical entries: from its live runtime, else the durable file. */
  canonicalEntries(sessionId: string): Promise<{ entries: readonly FileEntry[] | null; live: boolean }>;
  /** Builds and publishes a runtime over a caller-prepared manager inside one
   * slot admission. `failed` runs first when anything inside it throws. */
  createRuntimeOver(sessionId: string, build: {
    profile: string;
    prepare(): Promise<SessionManager>;
    authority(): object;
    admitted(slot: Runtime): void;
    published(slot: Runtime): Promise<void>;
    failed(): void;
  }): Promise<Runtime>;
}

