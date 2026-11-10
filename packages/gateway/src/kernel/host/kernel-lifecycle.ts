export interface KernelLifecycleObserver {
  initialize(): Promise<void>;
  started(): void;
  closing(): void;
  dispose(): Promise<void>;
}

export interface TaskLedgerPolicy {
  validateMarker(sessionId: string, marker: unknown): Promise<void>;
  settingsTarget(sessionId: string, taskId: string, purpose: "resolve" | "change"): Promise<{
    taskId: string; sessionId: string; operationId: string | null; state: string; resolvedFrom?: string;
  }>;
}
