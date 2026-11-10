import type { SessionManager } from "../pi/coding-agent.js";

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

export interface CanonicalAppendPolicy {
  append(manager: SessionManager, append: () => void): void;
  assertWritable(manager: SessionManager): void;
  admission(): void;
  committed(): void;
  isPreAppendRefusal(error: unknown): boolean;
}
