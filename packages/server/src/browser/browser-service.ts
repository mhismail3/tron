/**
 * @fileoverview Browser automation service using Playwright
 */

import { EventEmitter } from 'node:events';
import { chromium, type Browser, type Page, type CDPSession } from 'playwright-core';

export interface BrowserConfig {
  headless?: boolean;
  viewport?: {
    width: number;
    height: number;
  };
}

export interface BrowserSession {
  browser: Browser;
  page: Page;
  cdpSession?: CDPSession;
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
 * BrowserService manages browser sessions with Playwright and CDP screencast
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
      const browser = await chromium.launch({
        headless: this.config.headless,
      });

      const page = await browser.newPage({
        viewport: this.config.viewport,
      });

      this.sessions.set(sessionId, {
        browser,
        page,
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
      if (session.isStreaming && session.cdpSession) {
        await session.cdpSession.send('Page.stopScreencast').catch(() => {});
      }

      await session.browser.close();
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
          return await this.screenshot(session, params);
        case 'snapshot':
          return await this.snapshot(session);
        case 'wait':
          return await this.wait(session, params);
        case 'scroll':
          return await this.scroll(session, params);
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
      await session.page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });
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
    const selector = this.resolveSelector(session, params.selector as string);
    if (!selector) {
      return { success: false, error: 'Selector is required' };
    }

    try {
      await session.page.click(selector, { timeout: 10000 });
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
    const selector = this.resolveSelector(session, params.selector as string);
    const value = params.value as string;

    if (!selector || value === undefined) {
      return { success: false, error: 'Selector and value are required' };
    }

    try {
      await session.page.fill(selector, value, { timeout: 10000 });
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
    const selector = this.resolveSelector(session, params.selector as string);
    const text = params.text as string;

    if (!selector || !text) {
      return { success: false, error: 'Selector and text are required' };
    }

    try {
      await session.page.type(selector, text, { timeout: 10000 });
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
    const selector = this.resolveSelector(session, params.selector as string);
    const value = params.value as string | string[];

    if (!selector || !value) {
      return { success: false, error: 'Selector and value are required' };
    }

    try {
      const values = Array.isArray(value) ? value : [value];
      await session.page.selectOption(selector, values, { timeout: 10000 });
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
  private async screenshot(session: BrowserSession, params: Record<string, unknown>): Promise<ActionResult> {
    try {
      // Always capture viewport only (not full page) to ensure consistent dimensions
      // The viewport is fixed at 1280x800, so all screenshots will be the same size
      const screenshot = await session.page.screenshot({
        type: 'png',
        fullPage: false, // Always viewport-only for consistent sizing
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
   * Get accessibility snapshot with element references
   */
  private async snapshot(session: BrowserSession): Promise<ActionResult> {
    try {
      // Wait for page to be ready - accessibility API may not be available immediately
      await session.page.waitForLoadState('domcontentloaded', { timeout: 5000 }).catch(() => {});

      // Small delay to ensure accessibility tree is populated
      await session.page.waitForTimeout(100);

      const accessibility = (session.page as any).accessibility;
      if (!accessibility) {
        return {
          success: false,
          error: 'Accessibility API not available on this page',
        };
      }

      const snapshot = await accessibility.snapshot();
      if (!snapshot) {
        return {
          success: false,
          error: 'Failed to capture accessibility snapshot - page may not be fully loaded',
        };
      }

      // Generate element references
      session.elementRefs.clear();
      let refIndex = 1;

      const processNode = (node: any): any => {
        if (!node) return null;

        const ref = `e${refIndex++}`;
        if (node.role) {
          session.elementRefs.set(ref, node.name || node.role);
        }

        return {
          ...node,
          ref,
          children: node.children?.map(processNode).filter(Boolean),
        };
      };

      const processedSnapshot = processNode(snapshot);
      session.lastSnapshot = processedSnapshot;

      return {
        success: true,
        data: {
          snapshot: processedSnapshot,
          elementRefs: Array.from(session.elementRefs.entries()).map(([ref, selector]) => ({
            ref,
            selector,
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
      if (params.selector) {
        const selector = this.resolveSelector(session, params.selector as string);
        await session.page.waitForSelector(selector, {
          timeout: (params.timeout as number) ?? 10000,
        });
        return { success: true, data: { selector } };
      } else if (params.timeout) {
        await session.page.waitForTimeout(params.timeout as number);
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
        await session.page.evaluate(
          `document.querySelector('${selector}')?.scrollBy(${scroll.x}, ${scroll.y})`
        );
      } else {
        await session.page.evaluate(`window.scrollBy(${scroll.x}, ${scroll.y})`);
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
   * Start CDP screencast
   */
  async startScreencast(sessionId: string, options: ScreencastOptions = {}): Promise<ActionResult> {
    const session = this.sessions.get(sessionId);
    if (!session) {
      return { success: false, error: 'Session not found' };
    }

    if (session.isStreaming) {
      return { success: true, data: { message: 'Already streaming' } };
    }

    try {
      if (!session.cdpSession) {
        session.cdpSession = await session.page.context().newCDPSession(session.page);
      }

      const cdp = session.cdpSession;

      cdp.on('Page.screencastFrame', async (frame: any) => {
        const browserFrame: BrowserFrame = {
          sessionId,
          data: frame.data,
          frameId: frame.sessionId,
          timestamp: Date.now(),
          metadata: frame.metadata,
        };

        this.emit('browser.frame', browserFrame);

        // Acknowledge frame to CDP
        await cdp.send('Page.screencastFrameAck', { sessionId: frame.sessionId }).catch(() => {});
      });

      await cdp.send('Page.startScreencast', {
        format: options.format ?? 'jpeg',
        quality: options.quality ?? 60,
        maxWidth: options.maxWidth ?? this.config.viewport.width,
        maxHeight: options.maxHeight ?? this.config.viewport.height,
        everyNthFrame: options.everyNthFrame ?? 1,
      });

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
   * Stop CDP screencast
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
      if (session.cdpSession) {
        await session.cdpSession.send('Page.stopScreencast');
      }

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
   * Convert jQuery-style selectors to Playwright equivalents
   */
  private resolveSelector(session: BrowserSession, selector: string): string {
    if (!selector) return '';

    // Check if it's an element reference (e1, e2, etc.)
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
