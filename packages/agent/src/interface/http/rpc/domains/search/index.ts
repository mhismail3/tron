/**
 * @fileoverview Search domain - Content and event search
 *
 * Handles content and event search operations.
 *
 * @migration Re-exports from rpc/handlers during transition
 */

// Re-export handlers
export {
  handleSearchContent,
  handleSearchEvents,
  createSearchHandlers,
} from '../../../../rpc/handlers/search.handler.js';

// Re-export types
export type {
  SearchContentParams,
  SearchContentResult,
  SearchEventsParams,
  SearchEventsResult,
} from '../../../../rpc/types/search.js';
