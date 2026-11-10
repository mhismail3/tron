import type { Agent, AgentMessage, PrepareRequest, StreamFn } from "../pi/agent-core.js";
import type { AgentSession } from "../pi/coding-agent.js";

export interface ResponseTiming {
  accepted(operation: string): void;
  transfer(from: string, to: string): void;
  retire(): void;
  started(operation: string | undefined): void;
  visible(operation: string | undefined): void;
  tool(operation: string | undefined, id: string, started: boolean): void;
  terminal(operation: string, outcome: "completed" | "failed" | "interrupted" | "outcomeUnknown"): void;
}

export interface RequestPolicy {
  readonly inputCancellation: { epoch: number };
  readonly responseTiming: ResponseTiming;
  admit(operationId: string, boundaryEntryId: string | null, systemBase: string, kind: "user" | "wake"): void;
  settle(operationId: string | undefined): void;
  cancel(operationId: string | undefined): void;
  transferOperation(from: string | undefined, to: string): void;
  contextEvidence(): unknown;
  deliveryHeadroom(session: AgentSession, input: AgentMessage, systemPrompt: string, signal?: AbortSignal): Promise<{
    tokens: number; freshTokens: number; signal: AbortSignal;
  }>;
  wrapPrepareRequest(session: AgentSession, inner: PrepareRequest | undefined): PrepareRequest;
  wrapTransformContext(inner: Agent["transformContext"], convertMessages: Agent["convertToLlm"]): NonNullable<Agent["transformContext"]>;
  wrapStreamFunction(stream: StreamFn): StreamFn;
}

export interface RequestPolicyHook {
  forSession(sessionId: string): RequestPolicy | undefined;
  isRefusal(error: unknown): error is Error;
}
