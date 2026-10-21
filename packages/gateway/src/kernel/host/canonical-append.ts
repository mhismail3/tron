import type { SessionManager } from "../pi/coding-agent.js";

/** Live run facts, not a copy of its state. The module-issued write authority is
 * opaque here; only the module that issued it interprets it. */
export interface CanonicalAppendContext {
  readonly owner: object;
  readonly writeAuthority: unknown;
  manager(): SessionManager;
  sessionId(): string;
  sessionFile(): string | undefined;
  activeOperationId(): string | undefined;
  entryCount(): number;
  guardedProfile(manager: SessionManager): boolean;
  abort(operationId: string, reason: "chapter-limit"): Promise<void>;
  diagnostic(record: { code: string; message: string }): void;
}

/** Sync refusal surrounds the canonical append. Admission remains sync at each
 * existing revalidation cut; committed is dispatched in the run's microtask. */
export interface CanonicalAppendPolicy {
  append(manager: SessionManager, append: () => void): void;
  assertWritable(manager: SessionManager): void;
  admission(): void;
  committed(): void;
  isPreAppendRefusal(error: unknown): boolean;
}
