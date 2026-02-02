/**
 * @fileoverview Agent domain - Agent lifecycle and execution
 *
 * Handles agent prompts, abort, and state queries.
 */

// Re-export handler factory
export { createAgentHandlers } from '@interface/rpc/handlers/agent.handler.js';

// Re-export types
export type {
  AgentPromptParams,
  AgentPromptResult,
  AgentAbortParams,
  AgentAbortResult,
  AgentGetStateParams,
  AgentGetStateResult,
} from '@interface/rpc/types/agent.js';
