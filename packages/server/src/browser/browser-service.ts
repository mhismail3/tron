/**
 * @fileoverview Browser automation service using agent-browser library
 */

import { EventEmitter } from 'node:events';
import { BrowserManager, type ScreencastFrame } from 'agent-browser/dist/browser.js';

export interface BrowserConfig {
  headless?: boolean;
  viewport?: {
    width: number;
    height: number;
  };
}

export interface BrowserSession {
  manager: BrowserManager;
  isStreaming: boolean;
  elementRefs: Map<string, string>;
  lastSnapshot?: any;
}

export interface ActionResult {
  success: boolean;
  data?: Record<string, unknown>;
  error?: string;
}

export interface ScreencastOptions {
  format?: 'jpeg' | 'png';
  quality?: number;
  maxWidth?: number;
  maxHeight?: number;
  everyNthFrame?: number;
}

export interface BrowserFrame {
  sessionId: string;
  data: string; // base64 encoded
  frameId: number;
  timestamp: number;
  metadata?: {
    offsetTop?: number;
    pageScaleFactor?: number;
    deviceWidth?: number;
    deviceHeight?: number;
    scrollOffsetX?: number;
    scrollOffsetY?: number;
  };
}

/**
 * BrowserService manages browser sessions using agent-browser library
 */
export class BrowserService extends EventEmitter {
  private sessions = new Map<string, BrowserSession>();
  private config: Required<BrowserConfig>;

  constructor(config: BrowserConfig = {}) {
    super();
    this.config = {
      headless: config.headless ?? true,
      viewport: config.viewport ?? { width: 1280, height: 800 },
    };
  }

  /**
   * Create a new browser session
   */
  async createSession(sessionId: string): Promise<ActionResult> {
    if (this.sessions.has(sessionId)) {
      return { success: true, data: { message: 'Session already exists' } };
    }

    try {
      const manager = new BrowserManager();
      await manager.launch({
        action: 'launch',
        id: `launch-${sessionId}`,
        headless: this.config.headless,
      });
      await manager.setViewport(this.config.viewport.width, this.config.viewport.height);

      this.sessions.set(sessionId, {
        manager,
        isStreaming: false,
        elementRefs: new Map(),
      });

      return { success: true, data: { sessionId } };
    } catch (error) {
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Failed to create session',
      };
    }
  }

  /**
   * Check if a session exists
   */
  hasSession(sessionId: string): boolean {
    return this.sessions.has(sessionId);
  }

  /**
   * Get a session
   */
  getSession(sessionId: string): BrowserSession | undefined {
    return this.sessions.get(sessionId);
  }

  /**
   * Close a browser session
   */
  async closeSession(sessionId: string): Promise<ActionResult> {
    const session = this.sessions.get(sessionId);
    if (!session) {
      return { success: false, error: 'Session not found' };
    }

    try {
      if (session.isStreaming) {
        await session.manager.stopScreencast().catch(() => {});
      }

      await session.manager.close();
      this.sessions.delete(sessionId);
      this.emit('browser.closed', sessionId);

      return { success: true };
    } catch (error) {
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Failed to close session',
      };
    }
  }

  /**
   * Execute a browser action
   */
  async execute(
    sessionId: string,
    action: string,
    params: Record<string, unknown>
  ): Promise<ActionResult> {
    const session = this.sessions.get(sessionId);
    if (!session) {
      return { success: false, error: 'Session not found' };
    }

    try {
      switch (action) {
        case 'navigate':
          return await this.navigate(session, params);
        case 'click':
          return await this.click(session, params);
        case 'fill':
          return await this.fill(session, params);
        case 'type':
          return await this.type(session, params);
        case 'select':
          return await this.select(session, params);
        case 'screenshot':
          return await this.screenshot(session);
        case 'snapshot':
          return await this.snapshot(session);
        case 'wait':
          return await this.wait(session, params);
        case 'scroll':
          return await this.scroll(session, params);
        case 'goBack':
          return await this.goBack(session);
        case 'goForward':
          return await this.goForward(session);
        case 'reload':
          return await this.reload(session);
        case 'hover':
          return await this.hover(session, params);
        case 'pressKey':
          return await this.pressKey(session, params);
        case 'getText':
          return await this.getText(session, params);
        case 'getAttribute':
          return await this.getAttribute(session, params);
        case 'pdf':
          return await this.pdf(session, params);
        case 'close':
          return await this.closeSession(sessionId);
        default:
          return { success: false, error: `Unknown action: ${action}` };
      }
    } catch (error) {
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Action failed',
      };
    }
  }

  /**
   * Navigate to a URL
   */
  private async navigate(session: BrowserSession, params: Record<string, unknown>): Promise<ActionResult> {
    const url = params.url as string;
    if (!url) {
      return { success: false, error: 'URL is required' };
    }

    try {
      const page = session.manager.getPage();
      await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });
      return { success: true, data: { url } };
    } catch (error) {
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Navigation failed',
      };
    }
  }

  /**
   * Click an element
   */
  private async click(session: BrowserSession, params: Record<string, unknown>): Promise<ActionResult> {
    const selector = params.selector as string;
    if (!selector) {
      return { success: false, error: 'Selector is required' };
    }

    try {
      const locator = this.getLocator(session, selector);
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
   * Fill an input field
   */
  private async fill(session: BrowserSession, params: Record<string, unknown>): Promise<ActionResult> {
    const selector = params.selector as string;
    const value = params.value as string;

    if (!selector || value === undefined) {
      return { success: false, error: 'Selector and value are required' };
    }

    try {
      const locator = this.getLocator(session, selector);
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
   * Type text (character by character, triggers JS events)
   */
  private async type(session: BrowserSession, params: Record<string, unknown>): Promise<ActionResult> {
    const selector = params.selector as string;
    const text = params.text as string;

    if (!selector || !text) {
      return { success: false, error: 'Selector and text are required' };
    }

    try {
      const locator = this.getLocator(session, selector);
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
   * Select a dropdown option
   */
  private async select(session: BrowserSession, params: Record<string, unknown>): Promise<ActionResult> {
    const selector = params.selector as string;
    const value = params.value as string | string[];

    if (!selector || !value) {
      return { success: false, error: 'Selector and value are required' };
    }

    try {
      const locator = this.getLocator(session, selector);
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
   * Take a screenshot
   * Always captures viewport-only to ensure consistent dimensions for iOS display
   */
  private async screenshot(session: BrowserSession): Promise<ActionResult> {
    try {
      const page = session.manager.getPage();
      const screenshot = await page.screenshot({
        type: 'png',
        fullPage: false,
      });

      return {
        success: true,
        data: {
          screenshot: screenshot.toString('base64'),
          format: 'png',
          width: this.config.viewport.width,
          height: this.config.viewport.height,
        },
      };
    } catch (error) {
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Screenshot failed',
      };
    }
  }

  /**
   * Get accessibility snapshot with element references using agent-browser
   */
  private async snapshot(session: BrowserSession): Promise<ActionResult> {
    try {
      const page = session.manager.getPage();

      // Wait for page to be ready
      await page.waitForLoadState('domcontentloaded', { timeout: 5000 }).catch(() => {});
      await page.waitForTimeout(100);

      // Use agent-browser's getSnapshot method which provides enhanced snapshot with refs
      const enhancedSnapshot = await session.manager.getSnapshot({
        interactive: false,
        compact: true,
      });

      // Get the ref map from agent-browser
      const refMap = session.manager.getRefMap();

      // Update our session's element refs from agent-browser's ref map
      session.elementRefs.clear();
      for (const ref of Object.keys(refMap)) {
        // Store the ref with its selector for later use
        session.elementRefs.set(ref, ref);
      }

      session.lastSnapshot = enhancedSnapshot;

      return {
        success: true,
        data: {
          snapshot: enhancedSnapshot,
          elementRefs: Array.from(session.elementRefs.entries()).map(([ref]) => ({
            ref,
            selector: ref, // agent-browser refs are used directly
          })),
        },
      };
    } catch (error) {
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Snapshot failed',
      };
    }
  }

  /**
   * Wait for element, selector, or timeout
   */
  private async wait(session: BrowserSession, params: Record<string, unknown>): Promise<ActionResult> {
    try {
      const page = session.manager.getPage();

      if (params.selector) {
        const selector = this.resolveSelector(session, params.selector as string);
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
   * Scroll page or element
   */
  private async scroll(session: BrowserSession, params: Record<string, unknown>): Promise<ActionResult> {
    try {
      const page = session.manager.getPage();
      const direction = params.direction as 'up' | 'down' | 'left' | 'right';
      const amount = (params.amount as number) ?? 100;

      const scrollMap = {
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
        const selector = this.resolveSelector(session, params.selector as string);
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

  /**
   * Navigate back in browser history
   */
  private async goBack(session: BrowserSession): Promise<ActionResult> {
    try {
      const page = session.manager.getPage();
      await page.goBack({ timeout: 10000 });
      return { success: true, data: {} };
    } catch (error) {
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Go back failed',
      };
    }
  }

  /**
   * Navigate forward in browser history
   */
  private async goForward(session: BrowserSession): Promise<ActionResult> {
    try {
      const page = session.manager.getPage();
      await page.goForward({ timeout: 10000 });
      return { success: true, data: {} };
    } catch (error) {
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Go forward failed',
      };
    }
  }

  /**
   * Reload the current page
   */
  private async reload(session: BrowserSession): Promise<ActionResult> {
    try {
      const page = session.manager.getPage();
      await page.reload({ timeout: 30000 });
      return { success: true, data: {} };
    } catch (error) {
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Reload failed',
      };
    }
  }

  /**
   * Hover over an element
   */
  private async hover(session: BrowserSession, params: Record<string, unknown>): Promise<ActionResult> {
    const selector = params.selector as string;
    if (!selector) {
      return { success: false, error: 'Selector is required' };
    }

    try {
      const locator = this.getLocator(session, selector);
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
   * Press a keyboard key
   */
  private async pressKey(session: BrowserSession, params: Record<string, unknown>): Promise<ActionResult> {
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

  /**
   * Get text content from an element
   */
  private async getText(session: BrowserSession, params: Record<string, unknown>): Promise<ActionResult> {
    const selector = params.selector as string;
    if (!selector) {
      return { success: false, error: 'Selector is required' };
    }

    try {
      const locator = this.getLocator(session, selector);
      const text = await locator.innerText({ timeout: 10000 });
      return { success: true, data: { selector, text } };
    } catch (error) {
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Get text failed',
      };
    }
  }

  /**
   * Get an attribute value from an element
   */
  private async getAttribute(session: BrowserSession, params: Record<string, unknown>): Promise<ActionResult> {
    const selector = params.selector as string;
    const attribute = params.attribute as string;

    if (!selector || !attribute) {
      return { success: false, error: 'Selector and attribute are required' };
    }

    try {
      const locator = this.getLocator(session, selector);
      const value = await locator.getAttribute(attribute, { timeout: 10000 });
      return { success: true, data: { selector, attribute, value } };
    } catch (error) {
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Get attribute failed',
      };
    }
  }

  /**
   * Generate a PDF of the current page
   */
  private async pdf(session: BrowserSession, params: Record<string, unknown>): Promise<ActionResult> {
    try {
      const page = session.manager.getPage();
      const path = params.path as string | undefined;

      if (path) {
        await page.pdf({ path });
        return { success: true, data: { path } };
      } else {
        const pdfBuffer = await page.pdf();
        return { success: true, data: { pdf: pdfBuffer.toString('base64') } };
      }
    } catch (error) {
      return {
        success: false,
        error: error instanceof Error ? error.message : 'PDF generation failed',
      };
    }
  }

  /**
   * Start screencast using agent-browser's CDP screencast
   * If already streaming, restarts with a fresh callback to handle reconnection
   */
  async startScreencast(sessionId: string, options: ScreencastOptions = {}): Promise<ActionResult> {
    const session = this.sessions.get(sessionId);
    if (!session) {
      return { success: false, error: 'Session not found' };
    }

    // If already streaming, stop first to ensure clean restart with fresh callback
    // This handles the case where iOS closes/reopens the sheet
    if (session.isStreaming) {
      try {
        await session.manager.stopScreencast();
      } catch {
        // Ignore errors when stopping - may already be stopped
      }
      session.isStreaming = false;
    }

    try {
      // Use agent-browser's startScreencast which handles CDP internally
      await session.manager.startScreencast(
        (frame: ScreencastFrame) => {
          // Transform agent-browser frame to Tron frame format
          const browserFrame: BrowserFrame = {
            sessionId,                    // Tron session ID (string)
            data: frame.data,             // base64 JPEG
            frameId: frame.sessionId,     // CDP session ID (number)
            timestamp: frame.metadata?.timestamp ?? Date.now(),
            metadata: {
              offsetTop: frame.metadata?.offsetTop,
              pageScaleFactor: frame.metadata?.pageScaleFactor,
              deviceWidth: frame.metadata?.deviceWidth,
              deviceHeight: frame.metadata?.deviceHeight,
              scrollOffsetX: frame.metadata?.scrollOffsetX,
              scrollOffsetY: frame.metadata?.scrollOffsetY,
            },
          };

          this.emit('browser.frame', browserFrame);
        },
        {
          format: options.format ?? 'jpeg',
          quality: options.quality ?? 60,
          maxWidth: options.maxWidth ?? this.config.viewport.width,
          maxHeight: options.maxHeight ?? this.config.viewport.height,
          everyNthFrame: options.everyNthFrame ?? 1,
        }
      );

      session.isStreaming = true;

      return { success: true, data: { streaming: true } };
    } catch (error) {
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Failed to start screencast',
      };
    }
  }

  /**
   * Stop screencast
   */
  async stopScreencast(sessionId: string): Promise<ActionResult> {
    const session = this.sessions.get(sessionId);
    if (!session) {
      return { success: false, error: 'Session not found' };
    }

    if (!session.isStreaming) {
      return { success: true, data: { message: 'Not streaming' } };
    }

    try {
      await session.manager.stopScreencast();
      session.isStreaming = false;

      return { success: true, data: { streaming: false } };
    } catch (error) {
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Failed to stop screencast',
      };
    }
  }

  /**
   * Get a locator for a selector, supporting both refs and CSS selectors
   */
  private getLocator(session: BrowserSession, selectorOrRef: string) {
    // Check if it's a ref (e1, e2, etc.)
    if (session.manager.isRef(selectorOrRef)) {
      const locator = session.manager.getLocatorFromRef(selectorOrRef);
      if (locator) {
        return locator;
      }
    }

    // Otherwise use as CSS selector
    const page = session.manager.getPage();
    const resolved = this.resolveSelector(session, selectorOrRef);
    return page.locator(resolved);
  }

  /**
   * Convert jQuery-style selectors to Playwright equivalents
   */
  private resolveSelector(session: BrowserSession, selector: string): string {
    if (!selector) return '';

    // Check if it's an element reference from our own tracking (legacy support)
    if (/^e\d+$/.test(selector) && session.elementRefs.has(selector)) {
      return session.elementRefs.get(selector)!;
    }

    // Convert jQuery-style :contains() to Playwright :has-text()
    let converted = selector.replace(/:contains\(["']([^"']+)["']\)/g, ':has-text("$1")');
    converted = converted.replace(/:contains\(([^)]+)\)/g, ':has-text("$1")');

    return converted;
  }

  /**
   * Close all sessions and cleanup
   */
  async cleanup(): Promise<void> {
    const sessionIds = Array.from(this.sessions.keys());
    await Promise.all(sessionIds.map((id) => this.closeSession(id)));
  }
}
