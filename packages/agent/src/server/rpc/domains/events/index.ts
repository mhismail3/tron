/**
 * @fileoverview Events domain - Event store operations
 *
 * Handles event history queries and appending.
 *
 * @migration Re-exports from rpc/handlers during transition
 */

// Re-export handlers
export {
  handleEventsGetHistory,
  handleEventsGetSince,
  handleEventsAppend,
  createEventsHandlers,
} from '../../../../rpc/handlers/events.handler.js';

// Re-export types
export type {
  EventsGetHistoryParams,
  EventsGetHistoryResult,
  EventsGetSinceParams,
  EventsGetSinceResult,
  EventsAppendParams,
  EventsAppendResult,
} from '../../../../rpc/types/events.js';
