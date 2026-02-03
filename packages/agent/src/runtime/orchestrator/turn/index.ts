/**
 * @fileoverview Turn Execution Module
 *
 * Components for managing turn lifecycle, content tracking, and token usage.
 *
 * - TurnManager: Turn lifecycle management
 * - TurnContentTracker: Content accumulation for streaming and persistence
 * - ContentBlockBuilder: Pure functions for building API content blocks
 * - AgentEventHandler: Event forwarding and processing
 *
 * Token tracking is now handled by the unified @infrastructure/tokens module.
 */

// Turn lifecycle management
export {
  TurnManager,
  createTurnManager,
  type TokenUsage,
  type TextContentBlock,
  type ThinkingContentBlock,
  type ToolUseContentBlock,
  type AssistantContentBlock,
  type ToolResultBlock,
  type EndTurnResult,
  type TokenRecord,
} from './turn-manager.js';

// Turn content tracking
export {
  TurnContentTracker,
  type AccumulatedContent,
  type TurnContent,
  type InterruptedContent,
  type ContentSequenceItem,
  type ToolCallData,
  type ToolUseMeta,
  type ToolResultMeta,
} from './turn-content-tracker.js';

// Token tracking is now in @infrastructure/tokens - re-export for convenience
export type {
  TokenRecord as TokenRecordType,
  TokenSource,
  ComputedTokens,
  TokenMeta,
  TokenState,
  AccumulatedTokens,
} from '@infrastructure/tokens/index.js';

// Content block building utilities (extracted from TurnContentTracker)
export {
  buildPreToolContentBlocks,
  buildInterruptedContentBlocks,
  buildThinkingBlock,
  buildToolUseBlock,
  buildToolResultBlock,
  type PreToolContentBlock,
  type InterruptedContentBlocks,
  type ThinkingBlock,
  type ToolUseBlock,
  // Note: ToolResultBlock not exported to avoid conflict with turn-manager.ts
  // Use the builder function return type or InterruptedContentBlocks['toolResultContent'][0]
} from './content-block-builder.js';

// Agent event handling (Phase 2 extraction)
export {
  AgentEventHandler,
  createAgentEventHandler,
  type AgentEventHandlerConfig,
} from './agent-event-handler.js';
