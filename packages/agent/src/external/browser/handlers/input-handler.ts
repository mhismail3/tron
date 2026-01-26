/**
 * @fileoverview Input Handler
 *
 * Handles browser input actions:
 * - click: Click an element
 * - fill: Fill an input field (replaces content)
 * - type: Type text character by character
 * - select: Select dropdown option(s)
 * - hover: Hover over an element
 * - pressKey: Press a keyboard key
 *
 * Extracted from BrowserService for modularity.
 */

import type { BrowserSession, ActionResult, BrowserHandlerDeps } from './types.js';

// =============================================================================
// Types
// =============================================================================

/**
 * Dependencies for InputHandler
 */
export interface InputHandlerDeps extends BrowserHandlerDeps {}

// =============================================================================
// InputHandler
// =============================================================================

/**
 * Handles browser input actions.
 */
export class InputHandler {
  constructor(private deps: InputHandlerDeps) {}

  /**
   * Click an element.
   */
  async click(
    session: BrowserSession,
    params: Record<string, unknown>
  ): Promise<ActionResult> {
    const selector = params.selector as string;
    if (!selector) {
      return { success: false, error: 'Selector is required' };
    }

    try {
      const locator = this.deps.getLocator(session, selector);
      await locator.click({ timeout: 10000 });
      return { success: true, data: { selector } };
    } catch (error) {
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Click failed',
      };
    }
  }

  /**
   * Fill an input field (replaces existing content).
   */
  async fill(
    session: BrowserSession,
    params: Record<string, unknown>
  ): Promise<ActionResult> {
    const selector = params.selector as string;
    const value = params.value as string;

    if (!selector || value === undefined) {
      return { success: false, error: 'Selector and value are required' };
    }

    try {
      const locator = this.deps.getLocator(session, selector);
      await locator.fill(value, { timeout: 10000 });
      return { success: true, data: { selector, value } };
    } catch (error) {
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Fill failed',
      };
    }
  }

  /**
   * Type text character by character (triggers JS key events).
   */
  async type(
    session: BrowserSession,
    params: Record<string, unknown>
  ): Promise<ActionResult> {
    const selector = params.selector as string;
    const text = params.text as string;

    if (!selector || !text) {
      return { success: false, error: 'Selector and text are required' };
    }

    try {
      const locator = this.deps.getLocator(session, selector);
      await locator.pressSequentially(text, { timeout: 10000 });
      return { success: true, data: { selector, text } };
    } catch (error) {
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Type failed',
      };
    }
  }

  /**
   * Select dropdown option(s).
   */
  async select(
    session: BrowserSession,
    params: Record<string, unknown>
  ): Promise<ActionResult> {
    const selector = params.selector as string;
    const value = params.value as string | string[];

    if (!selector || !value) {
      return { success: false, error: 'Selector and value are required' };
    }

    try {
      const locator = this.deps.getLocator(session, selector);
      const values = Array.isArray(value) ? value : [value];
      await locator.selectOption(values, { timeout: 10000 });
      return { success: true, data: { selector, value } };
    } catch (error) {
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Select failed',
      };
    }
  }

  /**
   * Hover over an element.
   */
  async hover(
    session: BrowserSession,
    params: Record<string, unknown>
  ): Promise<ActionResult> {
    const selector = params.selector as string;
    if (!selector) {
      return { success: false, error: 'Selector is required' };
    }

    try {
      const locator = this.deps.getLocator(session, selector);
      await locator.hover({ timeout: 10000 });
      return { success: true, data: { selector } };
    } catch (error) {
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Hover failed',
      };
    }
  }

  /**
   * Press a keyboard key.
   */
  async pressKey(
    session: BrowserSession,
    params: Record<string, unknown>
  ): Promise<ActionResult> {
    const key = params.key as string;
    if (!key) {
      return { success: false, error: 'Key is required' };
    }

    try {
      const page = session.manager.getPage();
      await page.keyboard.press(key);
      return { success: true, data: { key } };
    } catch (error) {
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Press key failed',
      };
    }
  }
}

// =============================================================================
// Factory
// =============================================================================

/**
 * Create an InputHandler instance.
 */
export function createInputHandler(deps: InputHandlerDeps): InputHandler {
  return new InputHandler(deps);
}
