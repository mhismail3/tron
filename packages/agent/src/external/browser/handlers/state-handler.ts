/**
 * @fileoverview State Handler
 *
 * Handles browser state actions:
 * - wait: Wait for selector or timeout
 * - scroll: Scroll page or element
 *
 * Extracted from BrowserService for modularity.
 */

import type { BrowserSession, ActionResult, BrowserHandlerDeps } from './types.js';

// =============================================================================
// Types
// =============================================================================

/**
 * Dependencies for StateHandler
 */
export interface StateHandlerDeps extends BrowserHandlerDeps {}

// =============================================================================
// StateHandler
// =============================================================================

/**
 * Handles browser state actions.
 */
export class StateHandler {
  constructor(private deps: StateHandlerDeps) {}

  /**
   * Wait for element or timeout.
   */
  async wait(
    session: BrowserSession,
    params: Record<string, unknown>
  ): Promise<ActionResult> {
    try {
      const page = session.manager.getPage();

      if (params.selector) {
        const selector = this.deps.resolveSelector(session, params.selector as string);
        await page.waitForSelector(selector, {
          timeout: (params.timeout as number) ?? 10000,
        });
        return { success: true, data: { selector } };
      } else if (params.timeout) {
        await page.waitForTimeout(params.timeout as number);
        return { success: true, data: { timeout: params.timeout } };
      } else {
        return { success: false, error: 'Either selector or timeout is required' };
      }
    } catch (error) {
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Wait failed',
      };
    }
  }

  /**
   * Scroll page or element.
   */
  async scroll(
    session: BrowserSession,
    params: Record<string, unknown>
  ): Promise<ActionResult> {
    try {
      const page = session.manager.getPage();
      const direction = params.direction as 'up' | 'down' | 'left' | 'right';
      const amount = (params.amount as number) ?? 100;

      const scrollMap: Record<string, { x: number; y: number }> = {
        up: { x: 0, y: -amount },
        down: { x: 0, y: amount },
        left: { x: -amount, y: 0 },
        right: { x: amount, y: 0 },
      };

      const scroll = scrollMap[direction];
      if (!scroll) {
        return { success: false, error: 'Invalid scroll direction' };
      }

      if (params.selector) {
        const selector = this.deps.resolveSelector(session, params.selector as string);
        await page.evaluate(
          `document.querySelector('${selector}')?.scrollBy(${scroll.x}, ${scroll.y})`
        );
      } else {
        await page.evaluate(`window.scrollBy(${scroll.x}, ${scroll.y})`);
      }

      return { success: true, data: { direction, amount } };
    } catch (error) {
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Scroll failed',
      };
    }
  }
}

// =============================================================================
// Factory
// =============================================================================

/**
 * Create a StateHandler instance.
 */
export function createStateHandler(deps: StateHandlerDeps): StateHandler {
  return new StateHandler(deps);
}
