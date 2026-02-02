/**
 * @fileoverview Handlers Module Exports
 *
 * Exports all handler modules for the orchestrator.
 * Handlers encapsulate specific behaviors that were previously spread
 * across the monolithic event-store-orchestrator.ts.
 *
 * ## Available Handlers
 *
 * - **InterruptHandler**: Builds events for interrupted sessions
 * - **CompactionHandler**: Builds events for context compaction
 * - **ContextClearHandler**: Builds events for context clearing
 *
 * ## Usage Pattern
 *
 * Each handler is stateless and builds events that the caller persists
 * via EventPersister:
 *
 * ```typescript
 * const interruptHandler = createInterruptHandler();
 * const events = interruptHandler.buildInterruptEvents(context);
 *
 * for (const event of events) {
 *   await persister.appendAsync(event.type, event.payload);
 * }
 * ```
 */

// Interrupt Handler
export {
  InterruptHandler,
  createInterruptHandler,
  type InterruptContext,
  type InterruptResult,
  type TokenUsage as InterruptTokenUsage,
  type TextContentBlock as InterruptTextContentBlock,
  type ToolUseContentBlock as InterruptToolUseContentBlock,
  type AssistantContentBlock as InterruptAssistantContentBlock,
  type ToolResultContentBlock as InterruptToolResultContentBlock,
  type EventToAppend as InterruptEventToAppend,
} from './interrupt.js';

// Compaction Handler
export {
  CompactionHandler,
  createCompactionHandler,
  type CompactionContext,
  type EventToAppend as CompactionEventToAppend,
} from './compaction.js';

// Context Clear Handler
export {
  ContextClearHandler,
  createContextClearHandler,
  type ContextClearContext,
  type ClearReason,
  type EventToAppend as ContextClearEventToAppend,
} from './context-clear.js';
