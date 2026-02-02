/**
 * @fileoverview Browser domain - Browser automation
 *
 * Handles browser streaming and status.
 *
 * @migration Re-exports from rpc/handlers during transition
 */

// Re-export handlers
export {
  handleBrowserStartStream,
  handleBrowserStopStream,
  handleBrowserGetStatus,
  createBrowserHandlers,
} from '../../../../rpc/handlers/browser.handler.js';

// Re-export types
export type {
  BrowserStartStreamParams,
  BrowserStartStreamResult,
  BrowserStopStreamParams,
  BrowserStopStreamResult,
  BrowserGetStatusParams,
  BrowserGetStatusResult,
} from '../../../../rpc/types/browser.js';
