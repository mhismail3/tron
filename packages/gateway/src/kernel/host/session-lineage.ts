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
  /** Throws the lineage owner's refusal when the session may not be written. */
  assertWritable(sessionId: string): void;
  /** Every lineage member is fenced while its owner reconciles an uncertain publication. */
  publicationUncertain(): boolean;
}

