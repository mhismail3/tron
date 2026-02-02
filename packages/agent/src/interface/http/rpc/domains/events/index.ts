/**
 * @fileoverview Events domain - Event store operations
 *
 * Handles event history queries and appending.
 */

// Re-export handler factory
export { createEventsHandlers } from '@interface/rpc/handlers/events.handler.js';

// Re-export types
export type {
  EventsGetHistoryParams,
  EventsGetHistoryResult,
  EventsGetSinceParams,
  EventsGetSinceResult,
  EventsAppendParams,
  EventsAppendResult,
} from '@interface/rpc/types/events.js';
