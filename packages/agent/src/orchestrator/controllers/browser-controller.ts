/**
 * @fileoverview BrowserController
 *
 * Manages browser streaming operations for agent sessions. Handles starting/stopping
 * screencast streams and querying browser status.
 *
 * Part of Phase 2 of EventStoreOrchestrator refactoring.
 */

import type { BrowserService } from '../../external/browser/browser-service.js';

// =============================================================================
// Types
// =============================================================================

export interface BrowserControllerConfig {
  browserService: BrowserService;
}

export interface BrowserStreamResult {
  success: boolean;
  error?: string;
}

export interface BrowserStatus {
  hasBrowser: boolean;
  isStreaming: boolean;
  currentUrl?: string;
}

// =============================================================================
// BrowserController
// =============================================================================

/**
 * Controller for browser streaming operations.
 *
 * Provides a clean interface for:
 * - Starting browser frame streams (creates session if needed)
 * - Stopping browser frame streams
 * - Querying browser status (streaming state, current URL)
 */
export class BrowserController {
  private readonly browserService: BrowserService;

  constructor(config: BrowserControllerConfig) {
    this.browserService = config.browserService;
  }

  /**
   * Start browser frame streaming for a session.
   * Creates the browser session if it doesn't already exist.
   */
  async startStream(sessionId: string): Promise<BrowserStreamResult> {
    // Create browser session if it doesn't exist
    if (!this.browserService.hasSession(sessionId)) {
      const createResult = await this.browserService.createSession(sessionId);
      if (!createResult.success) {
        return { success: false, error: createResult.error || 'Failed to create browser session' };
      }
    }

    // Start screencast
    const result = await this.browserService.startScreencast(sessionId);
    if (!result.success) {
      return { success: false, error: result.error || 'Failed to start screencast' };
    }

    return { success: true };
  }

  /**
   * Stop browser frame streaming for a session.
   * Returns success if session doesn't exist (already not streaming).
   */
  async stopStream(sessionId: string): Promise<BrowserStreamResult> {
    if (!this.browserService.hasSession(sessionId)) {
      return { success: true }; // Already not streaming
    }

    // Stop screencast
    const result = await this.browserService.stopScreencast(sessionId);
    if (!result.success) {
      return { success: false, error: result.error || 'Failed to stop screencast' };
    }

    return { success: true };
  }

  /**
   * Get browser status for a session.
   * Returns streaming state and current URL if browser is active.
   */
  async getStatus(sessionId: string): Promise<BrowserStatus> {
    if (!this.browserService.hasSession(sessionId)) {
      return { hasBrowser: false, isStreaming: false };
    }

    const session = this.browserService.getSession(sessionId);
    let currentUrl: string | undefined;
    try {
      currentUrl = session?.manager?.isLaunched() ? session.manager.getPage().url() : undefined;
    } catch {
      // Browser not ready or page closed
    }

    return {
      hasBrowser: true,
      isStreaming: session?.isStreaming ?? false,
      currentUrl,
    };
  }
}

// =============================================================================
// Factory Function
// =============================================================================

/**
 * Create a BrowserController instance.
 */
export function createBrowserController(config: BrowserControllerConfig): BrowserController {
  return new BrowserController(config);
}
