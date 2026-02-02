/**
 * @fileoverview Search domain - Content and event search
 *
 * Handles content and event search operations.
 */

// Re-export handler factory
export { createSearchHandlers } from '@interface/rpc/handlers/search.handler.js';

// Re-export types
export type {
  SearchContentParams,
  SearchContentResult,
  SearchEventsParams,
  SearchEventsResult,
} from '@interface/rpc/types/search.js';
