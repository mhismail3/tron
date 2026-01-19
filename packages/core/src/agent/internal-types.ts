/**
 * @fileoverview Internal types for TronAgent module decomposition
 *
 * These types define the interfaces between internal agent modules.
 * They are not exported publicly - external code should use types.ts.
 */

import type {
  TronEvent,
  TronTool,
  AssistantMessage,
  ToolCall,
  Context,
  StreamEvent,
  TokenUsage,
} from '../types/index.js';
import type { HookEngine } from '../hooks/engine.js';
import type { ContextManager } from '../context/context-manager.js';
import type { Summarizer } from '../context/summarizer.js';
import type { Provider } from '../providers/index.js';
import type { GuardrailEngine } from '../guardrails/engine.js';
import type { SessionState } from '../guardrails/types.js';
import type { TurnResult, ToolExecutionRequest, ToolExecutionResponse } from './types.js';

// =============================================================================
// Event Emitter Types
// =============================================================================

/**
 * Interface for emitting events during agent execution
 */
export interface EventEmitter {
  /**
   * Add an event listener
   */
  addListener(listener: (event: TronEvent) => void): void;

  /**
   * Remove an event listener
   */
  removeListener(listener: (event: TronEvent) => void): void;

  /**
   * Emit an event to all listeners
   */
  emit(event: TronEvent): void;
}

// =============================================================================
// Tool Executor Types
// =============================================================================

/**
 * Dependencies needed by ToolExecutor
 */
export interface ToolExecutorDependencies {
  tools: Map<string, TronTool>;
  hookEngine: HookEngine;
  contextManager: ContextManager;
  eventEmitter: EventEmitter;
  sessionId: string;
  getAbortSignal: () => AbortSignal | undefined;
  /** Optional guardrail engine for safety checks */
  guardrailEngine?: GuardrailEngine;
  /** Optional callback to get current session state for guardrails */
  getSessionState?: () => SessionState | undefined;
}

/**
 * Interface for executing tools with hook support
 */
export interface ToolExecutor {
  /**
   * Execute a tool with pre/post hooks
   */
  execute(request: ToolExecutionRequest): Promise<ToolExecutionResponse>;

  /**
   * Get the currently executing tool name (for interrupt reporting)
   */
  getActiveTool(): string | null;

  /**
   * Clear the active tool tracking
   */
  clearActiveTool(): void;
}

// =============================================================================
// Stream Processor Types
// =============================================================================

/**
 * Result of processing a complete stream
 */
export interface StreamResult {
  message: AssistantMessage;
  toolCalls: ToolCall[];
  accumulatedText: string;
  stopReason?: string;
}

/**
 * Callbacks for stream processing events
 */
export interface StreamProcessorCallbacks {
  onTextDelta?: (delta: string) => void;
  onToolCallEnd?: (toolCall: ToolCall) => void;
  onRetry?: (event: StreamEvent & { type: 'retry' }) => void;
}

/**
 * Dependencies needed by StreamProcessor
 */
export interface StreamProcessorDependencies {
  eventEmitter: EventEmitter;
  sessionId: string;
  getAbortSignal: () => AbortSignal | undefined;
}

/**
 * Interface for processing provider streams
 */
export interface StreamProcessor {
  /**
   * Process a stream from the provider and accumulate the response
   */
  process(
    stream: AsyncGenerator<StreamEvent>,
    callbacks?: StreamProcessorCallbacks
  ): Promise<StreamResult>;

  /**
   * Get the accumulated streaming content (for interrupt recovery)
   */
  getStreamingContent(): string;

  /**
   * Reset the streaming content accumulator
   */
  resetStreamingContent(): void;
}

// =============================================================================
// Compaction Handler Types
// =============================================================================

/**
 * Dependencies needed by CompactionHandler
 */
export interface CompactionHandlerDependencies {
  contextManager: ContextManager;
  eventEmitter: EventEmitter;
  sessionId: string;
}

/**
 * Result of attempting compaction
 */
export interface CompactionAttemptResult {
  success: boolean;
  error?: string;
  tokensBefore?: number;
  tokensAfter?: number;
  compressionRatio?: number;
}

/**
 * Interface for handling context compaction
 */
export interface CompactionHandler {
  /**
   * Set the summarizer for compaction
   */
  setSummarizer(summarizer: Summarizer): void;

  /**
   * Check if auto-compaction is available
   */
  canAutoCompact(): boolean;

  /**
   * Enable/disable auto-compaction
   */
  setAutoCompaction(enabled: boolean): void;

  /**
   * Attempt compaction if needed
   * @param reason - The reason for compaction (for logging/events)
   */
  attemptCompaction(reason: string): Promise<CompactionAttemptResult>;
}

// =============================================================================
// Turn Runner Types
// =============================================================================

/**
 * Dependencies needed by TurnRunner
 */
export interface TurnRunnerDependencies {
  provider: Provider;
  contextManager: ContextManager;
  eventEmitter: EventEmitter;
  toolExecutor: ToolExecutor;
  streamProcessor: StreamProcessor;
  compactionHandler: CompactionHandler;
  sessionId: string;
  config: TurnConfig;
  getAbortSignal: () => AbortSignal | undefined;
}

/**
 * Configuration for turn execution
 */
export interface TurnConfig {
  maxTokens?: number;
  temperature?: number;
  enableThinking?: boolean;
  thinkingBudget?: number;
  stopSequences?: string[];
}

/**
 * Options passed to turn execution
 */
export interface TurnOptions {
  turn: number;
  reasoningLevel?: 'low' | 'medium' | 'high' | 'xhigh';
  skillContext?: string;
  /** Context about completed sub-agents and their results */
  subagentResultsContext?: string;
}

/**
 * Interface for running a single agent turn
 */
export interface TurnRunner {
  /**
   * Execute a single turn
   */
  execute(options: TurnOptions): Promise<TurnResult>;
}

// =============================================================================
// Agent Runtime State
// =============================================================================

/**
 * Runtime state managed by TronAgent
 */
export interface AgentRuntimeState {
  sessionId: string;
  currentTurn: number;
  tokenUsage: TokenUsage;
  isRunning: boolean;
  abortController: AbortController | null;
}

// =============================================================================
// Context Building Types
// =============================================================================

/**
 * Options for building the context to send to the provider
 */
export interface ContextBuildOptions {
  workingDirectory: string;
  tools: Map<string, TronTool>;
  skillContext?: string;
}

/**
 * Build a context object from the current state
 */
export type ContextBuilder = (
  contextManager: ContextManager,
  options: ContextBuildOptions
) => Context;
