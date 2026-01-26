/**
 * @fileoverview Query Handler
 *
 * Handles browser query actions:
 * - getText: Get text content from an element
 * - getAttribute: Get an attribute value from an element
 *
 * Extracted from BrowserService for modularity.
 */

import type { BrowserSession, ActionResult, BrowserHandlerDeps } from './types.js';
import { createLogger, categorizeError } from '../../../logging/index.js';

const logger = createLogger('browser:query');

// =============================================================================
// Types
// =============================================================================

/**
 * Dependencies for QueryHandler
 */
export interface QueryHandlerDeps extends BrowserHandlerDeps {}

// =============================================================================
// QueryHandler
// =============================================================================

/**
 * Handles browser query actions.
 */
export class QueryHandler {
  constructor(private deps: QueryHandlerDeps) {}

  /**
   * Get text content from an element.
   */
  async getText(
    session: BrowserSession,
    params: Record<string, unknown>
  ): Promise<ActionResult> {
    const selector = params.selector as string;
    if (!selector) {
      return { success: false, error: 'Selector is required' };
    }

    try {
      const locator = this.deps.getLocator(session, selector);
      const text = await locator.innerText({ timeout: 10000 });
      return { success: true, data: { selector, text } };
    } catch (error) {
      const structuredError = categorizeError(error, { action: 'getText', selector });
      logger.error('Get text failed', {
        selector,
        code: structuredError.code,
        category: structuredError.category,
        error: structuredError.message,
        retryable: structuredError.retryable,
      });
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Get text failed',
      };
    }
  }

  /**
   * Get an attribute value from an element.
   */
  async getAttribute(
    session: BrowserSession,
    params: Record<string, unknown>
  ): Promise<ActionResult> {
    const selector = params.selector as string;
    const attribute = params.attribute as string;

    if (!selector || !attribute) {
      return { success: false, error: 'Selector and attribute are required' };
    }

    try {
      const locator = this.deps.getLocator(session, selector);
      const value = await locator.getAttribute(attribute, { timeout: 10000 });
      return { success: true, data: { selector, attribute, value } };
    } catch (error) {
      const structuredError = categorizeError(error, { action: 'getAttribute', selector, attribute });
      logger.error('Get attribute failed', {
        selector,
        attribute,
        code: structuredError.code,
        category: structuredError.category,
        error: structuredError.message,
        retryable: structuredError.retryable,
      });
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Get attribute failed',
      };
    }
  }
}

// =============================================================================
// Factory
// =============================================================================

/**
 * Create a QueryHandler instance.
 */
export function createQueryHandler(deps: QueryHandlerDeps): QueryHandler {
  return new QueryHandler(deps);
}
