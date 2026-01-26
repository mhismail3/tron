/**
 * @fileoverview Browser automation service using agent-browser library
 *
 * This service coordinates browser sessions and delegates actions to specialized handlers:
 * - NavigationHandler: navigate, goBack, goForward, reload
 * - InputHandler: click, fill, type, select, hover, pressKey
 * - CaptureHandler: screenshot, snapshot, pdf
 * - QueryHandler: getText, getAttribute
 * - StateHandler: wait, scroll
 */

import { EventEmitter } from 'node:events';
import { BrowserManager, type ScreencastFrame } from 'agent-browser/dist/browser.js';

import { createLogger, categorizeError } from '../../logging/index.js';
import {
  type BrowserSession,
  type ActionResult,
  type BrowserHandlerDeps,
  type BrowserLocator,
  createNavigationHandler,
  createInputHandler,
  createCaptureHandler,
  createQueryHandler,
  createStateHandler,
  type NavigationHandler,
  type InputHandler,
  type CaptureHandler,
  type QueryHandler,
  type StateHandler,
} from './handlers/index.js';

export type { BrowserSession, ActionResult, BrowserLocator };

const logger = createLogger('browser:service');

export interface BrowserConfig {
  headless?: boolean;
  viewport?: {
    width: number;
    height: number;
  };
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

  // Handlers for different action categories
  private navigationHandler: NavigationHandler;
  private inputHandler: InputHandler;
  private captureHandler: CaptureHandler;
  private queryHandler: QueryHandler;
  private stateHandler: StateHandler;

  constructor(config: BrowserConfig = {}) {
    super();
    this.config = {
      headless: config.headless ?? true,
      viewport: config.viewport ?? { width: 1280, height: 800 },
    };

    // Create handler dependencies
    const deps: BrowserHandlerDeps = {
      getLocator: this.getLocator.bind(this),
      resolveSelector: this.resolveSelector.bind(this),
    };

    // Initialize handlers
    this.navigationHandler = createNavigationHandler(deps);
    this.inputHandler = createInputHandler(deps);
    this.captureHandler = createCaptureHandler({ ...deps, viewport: this.config.viewport });
    this.queryHandler = createQueryHandler(deps);
    this.stateHandler = createStateHandler(deps);
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
      const structuredError = categorizeError(error, { operation: 'createSession', sessionId });
      logger.error('Failed to create browser session', {
        sessionId,
        code: structuredError.code,
        category: structuredError.category,
        error: structuredError.message,
        retryable: structuredError.retryable,
      });
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
      const structuredError = categorizeError(error, { operation: 'closeSession', sessionId });
      logger.error('Failed to close browser session', {
        sessionId,
        code: structuredError.code,
        category: structuredError.category,
        error: structuredError.message,
        retryable: structuredError.retryable,
      });
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
        // Navigation actions
        case 'navigate':
          return await this.navigationHandler.navigate(session, params);
        case 'goBack':
          return await this.navigationHandler.goBack(session);
        case 'goForward':
          return await this.navigationHandler.goForward(session);
        case 'reload':
          return await this.navigationHandler.reload(session);

        // Input actions
        case 'click':
          return await this.inputHandler.click(session, params);
        case 'fill':
          return await this.inputHandler.fill(session, params);
        case 'type':
          return await this.inputHandler.type(session, params);
        case 'select':
          return await this.inputHandler.select(session, params);
        case 'hover':
          return await this.inputHandler.hover(session, params);
        case 'pressKey':
          return await this.inputHandler.pressKey(session, params);

        // Capture actions
        case 'screenshot':
          return await this.captureHandler.screenshot(session);
        case 'snapshot':
          return await this.captureHandler.snapshot(session);
        case 'pdf':
          return await this.captureHandler.pdf(session, params);

        // Query actions
        case 'getText':
          return await this.queryHandler.getText(session, params);
        case 'getAttribute':
          return await this.queryHandler.getAttribute(session, params);

        // State actions
        case 'wait':
          return await this.stateHandler.wait(session, params);
        case 'scroll':
          return await this.stateHandler.scroll(session, params);

        // Session actions
        case 'close':
          return await this.closeSession(sessionId);

        default:
          return { success: false, error: `Unknown action: ${action}` };
      }
    } catch (error) {
      const structuredError = categorizeError(error, { operation: 'execute', sessionId, action });
      logger.error('Browser action failed', {
        sessionId,
        action,
        code: structuredError.code,
        category: structuredError.category,
        error: structuredError.message,
        retryable: structuredError.retryable,
      });
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Action failed',
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
      const structuredError = categorizeError(error, { operation: 'startScreencast', sessionId });
      logger.error('Failed to start screencast', {
        sessionId,
        code: structuredError.code,
        category: structuredError.category,
        error: structuredError.message,
        retryable: structuredError.retryable,
      });
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
      const structuredError = categorizeError(error, { operation: 'stopScreencast', sessionId });
      logger.error('Failed to stop screencast', {
        sessionId,
        code: structuredError.code,
        category: structuredError.category,
        error: structuredError.message,
        retryable: structuredError.retryable,
      });
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
