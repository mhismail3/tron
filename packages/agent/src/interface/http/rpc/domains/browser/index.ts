/**
 * @fileoverview Browser domain - Browser automation
 *
 * Handles browser streaming and status.
 */

// Re-export handler factory
export { createBrowserHandlers } from '@interface/rpc/handlers/browser.handler.js';

// Re-export types
export type {
  BrowserStartStreamParams,
  BrowserStartStreamResult,
  BrowserStopStreamParams,
  BrowserStopStreamResult,
  BrowserGetStatusParams,
  BrowserGetStatusResult,
} from '@interface/rpc/types/browser.js';
