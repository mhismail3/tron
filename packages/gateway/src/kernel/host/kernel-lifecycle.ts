/** The `kernelLifecycle` observer hook (k0-kernel.md §2.1): a module whose
 * state every runtime reads joins the kernel's own start and shutdown, at the
 * kernel's existing call points and in composition order. */
export interface KernelLifecycleObserver {
  /** First in kernel start, before any durable store or runtime is read. */
  initialize(): Promise<void>;
  /** After the session catalog has started. */
  started(): void;
  /** Synchronously, when shutdown closes admission. */
  closing(): void;
  /** Before the kernel's shared stores (the workspace) are released; a failure is ignored. */
  dispose(): Promise<void>;
}

/** The `taskLedger` policy hook: the delegating module's task ledger as a task
 * worker's runtime reads it (k0-kernel.md §2.3, K5). */
export interface TaskLedgerPolicy {
  /** Refuses a task marker the ledger does not own. */
  validateMarker(sessionId: string, marker: unknown): Promise<void>;
  /** The worker session of one task, for the settings tool's `taskId`. */
  settingsTarget(sessionId: string, taskId: string, purpose: "resolve" | "change"): Promise<{
    taskId: string; sessionId: string; operationId: string | null; state: string; resolvedFrom?: string;
  }>;
}
