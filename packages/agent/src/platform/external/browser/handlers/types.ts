/**
 * @fileoverview Shared Types for Browser Handlers
 *
 * Defines common interfaces used by all browser action handlers.
 * Types are defined here to avoid circular imports with browser-service.ts.
 */

import { BrowserManager } from 'agent-browser/dist/browser.js';

// =============================================================================
// Core Browser Types
// =============================================================================

/**
 * Browser session state.
 */
export interface BrowserSession {
  manager: BrowserManager;
  isStreaming: boolean;
  elementRefs: Map<string, string>;
  lastSnapshot?: unknown;
}

/**
 * Result of a browser action.
 */
export interface ActionResult {
  success: boolean;
  data?: Record<string, unknown>;
  error?: string;
}

// =============================================================================
// Locator Interface
// =============================================================================

/**
 * Minimal locator interface matching Playwright's Locator.
 * Avoids direct playwright dependency while providing type safety.
 */
export interface BrowserLocator {
  click(options?: { timeout?: number }): Promise<void>;
  fill(value: string, options?: { timeout?: number }): Promise<void>;
  pressSequentially(text: string, options?: { timeout?: number }): Promise<void>;
  selectOption(values: string | string[], options?: { timeout?: number }): Promise<string[]>;
  hover(options?: { timeout?: number }): Promise<void>;
  innerText(options?: { timeout?: number }): Promise<string>;
  getAttribute(name: string, options?: { timeout?: number }): Promise<string | null>;
}

// =============================================================================
// Handler Dependencies
// =============================================================================

/**
 * Base dependencies shared by all browser handlers.
 */
export interface BrowserHandlerDeps {
  /** Get a Playwright locator for a selector or element ref */
  getLocator: (session: BrowserSession, selectorOrRef: string) => BrowserLocator;
  /** Resolve selector (convert jQuery-style :contains() to Playwright :has-text()) */
  resolveSelector: (session: BrowserSession, selector: string) => string;
}
