/**
 * @fileoverview Agent type definitions
 *
 * Types for the agent loop configuration and execution.
 */

import type {
  Message,
  AssistantMessage,
  TronTool,
  TronEvent,
  TokenUsage,
} from '../types/index.js';
import type { ProviderType, UnifiedAuth } from '../providers/index.js';

// =============================================================================
// Agent Configuration
// =============================================================================

/**
 * Provider configuration for agent
 */
export interface AgentProviderConfig {
  type?: ProviderType;
  model: string;
  auth: UnifiedAuth;
  baseURL?: string;
  // Anthropic-specific
  thinkingBudget?: number;
  // OpenAI-specific
  organization?: string;
}

/**
 * Agent configuration
 */
export interface AgentConfig {
  provider: AgentProviderConfig;
  tools: TronTool[];
  systemPrompt?: string;
  maxTokens?: number;
  temperature?: number;
  maxTurns?: number;
  enableThinking?: boolean;
  thinkingBudget?: number;
  stopSequences?: string[];
}

/**
 * Runtime options for agent execution
 */
export interface AgentOptions {
  sessionId?: string;
  workingDirectory?: string;
  context?: Record<string, unknown>;
  onEvent?: (event: TronEvent) => void;
  signal?: AbortSignal;
}

// =============================================================================
// Execution Results
// =============================================================================

/**
 * Result of a single agent turn
 */
export interface TurnResult {
  success: boolean;
  message?: AssistantMessage;
  error?: string;
  toolCallsExecuted?: number;
  tokenUsage?: TokenUsage;
  stopReason?: string;
  /** True if the turn was interrupted by abort */
  interrupted?: boolean;
  /** Partial streaming content captured before interruption */
  partialContent?: string;
}

/**
 * Result of a complete agent run
 */
export interface RunResult {
  success: boolean;
  messages: Message[];
  turns: number;
  totalTokenUsage: TokenUsage;
  error?: string;
  stoppedReason?: string;
  /** True if the run was interrupted by abort */
  interrupted?: boolean;
  /** Partial streaming content captured before interruption */
  partialContent?: string;
}

// =============================================================================
// Agent State
// =============================================================================

/**
 * Current agent state
 */
export interface AgentState {
  sessionId: string;
  messages: Message[];
  currentTurn: number;
  tokenUsage: TokenUsage;
  isRunning: boolean;
  lastError?: string;
}

/**
 * Tool execution request
 */
export interface ToolExecutionRequest {
  toolCallId: string;
  toolName: string;
  arguments: Record<string, unknown>;
}

/**
 * Tool execution response
 */
export interface ToolExecutionResponse {
  toolCallId: string;
  result: {
    content: string;
    isError: boolean;
    details?: Record<string, unknown>;
  };
  duration: number;
}
