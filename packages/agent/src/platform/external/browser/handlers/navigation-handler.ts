/**
 * @fileoverview Navigation Handler
 *
 * Handles browser navigation actions:
 * - navigate: Go to a URL
 * - goBack: Navigate back in history
 * - goForward: Navigate forward in history
 * - reload: Reload the current page
 *
 * Extracted from BrowserService for modularity.
 */

import type { BrowserSession, ActionResult, BrowserHandlerDeps } from './types.js';
import { createLogger, categorizeError } from '@infrastructure/logging/index.js';

const logger = createLogger('browser:navigation');

// =============================================================================
// Types
// =============================================================================

/**
 * Dependencies for NavigationHandler.
 * Navigation doesn't use deps but accepts them for interface consistency.
 */
export type NavigationHandlerDeps = BrowserHandlerDeps;

// =============================================================================
// NavigationHandler
// =============================================================================

/**
 * Handles browser navigation actions.
 */
export class NavigationHandler {
  constructor(_deps: NavigationHandlerDeps) {
    // Navigation doesn't use deps but accepts for interface consistency
  }

  /**
   * Navigate to a URL.
   */
  async navigate(
    session: BrowserSession,
    params: Record<string, unknown>
  ): Promise<ActionResult> {
    const url = params.url as string;
    if (!url) {
      return { success: false, error: 'URL is required' };
    }

    try {
      const page = session.manager.getPage();
      await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });
      return { success: true, data: { url } };
    } catch (error) {
      const structuredError = categorizeError(error, { action: 'navigate', url });
      logger.error('Navigation failed', {
        url,
        code: structuredError.code,
        category: structuredError.category,
        error: structuredError.message,
        retryable: structuredError.retryable,
      });
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Navigation failed',
      };
    }
  }

  /**
   * Navigate back in browser history.
   */
  async goBack(session: BrowserSession): Promise<ActionResult> {
    try {
      const page = session.manager.getPage();
      await page.goBack({ timeout: 10000 });
      return { success: true, data: {} };
    } catch (error) {
      const structuredError = categorizeError(error, { action: 'goBack' });
      logger.error('Go back failed', {
        code: structuredError.code,
        category: structuredError.category,
        error: structuredError.message,
        retryable: structuredError.retryable,
      });
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Go back failed',
      };
    }
  }

  /**
   * Navigate forward in browser history.
   */
  async goForward(session: BrowserSession): Promise<ActionResult> {
    try {
      const page = session.manager.getPage();
      await page.goForward({ timeout: 10000 });
      return { success: true, data: {} };
    } catch (error) {
      const structuredError = categorizeError(error, { action: 'goForward' });
      logger.error('Go forward failed', {
        code: structuredError.code,
        category: structuredError.category,
        error: structuredError.message,
        retryable: structuredError.retryable,
      });
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Go forward failed',
      };
    }
  }

  /**
   * Reload the current page.
   */
  async reload(session: BrowserSession): Promise<ActionResult> {
    try {
      const page = session.manager.getPage();
      await page.reload({ timeout: 30000 });
      return { success: true, data: {} };
    } catch (error) {
      const structuredError = categorizeError(error, { action: 'reload' });
      logger.error('Reload failed', {
        code: structuredError.code,
        category: structuredError.category,
        error: structuredError.message,
        retryable: structuredError.retryable,
      });
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Reload failed',
      };
    }
  }
}

// =============================================================================
// Factory
// =============================================================================

/**
 * Create a NavigationHandler instance.
 */
export function createNavigationHandler(
  deps: NavigationHandlerDeps
): NavigationHandler {
  return new NavigationHandler(deps);
}
