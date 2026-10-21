import type { Agent, AgentMessage, PrepareRequest, StreamFn } from "../pi/agent-core.js";
import type { AgentSession } from "../pi/coding-agent.js";

/** The request stages and activation lifecycle one profile owns. Its evidence
 * remains module-owned; the kernel never interprets or persists that view. */
export interface RequestPolicy {
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

/** The module resolves the policy once per runtime and recognizes its own
 * refusal errors without exposing a concrete implementation to the kernel. */
export interface RequestPolicyHook {
  forSession(sessionId: string): RequestPolicy | undefined;
  isRefusal(error: unknown): error is Error;
}
