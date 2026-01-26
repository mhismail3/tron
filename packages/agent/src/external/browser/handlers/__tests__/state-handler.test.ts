/**
 * @fileoverview Tests for StateHandler
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  StateHandler,
  createStateHandler,
  type StateHandlerDeps,
} from '../state-handler.js';
import type { BrowserSession } from '../../browser-service.js';

// =============================================================================
// Test Helpers
// =============================================================================

function createMockPage() {
  return {
    waitForSelector: vi.fn(),
    waitForTimeout: vi.fn(),
    evaluate: vi.fn(),
  };
}

function createMockSession(mockPage: ReturnType<typeof createMockPage>): BrowserSession {
  return {
    manager: {
      getPage: () => mockPage,
    } as BrowserSession['manager'],
    isStreaming: false,
    elementRefs: new Map(),
  };
}

function createMockDeps(): StateHandlerDeps {
  return {
    getLocator: vi.fn(),
    resolveSelector: vi.fn((_, selector) => selector),
  };
}

// =============================================================================
// Tests
// =============================================================================

describe('StateHandler', () => {
  let deps: StateHandlerDeps;
  let handler: StateHandler;
  let mockPage: ReturnType<typeof createMockPage>;
  let session: BrowserSession;

  beforeEach(() => {
    deps = createMockDeps();
    handler = createStateHandler(deps);
    mockPage = createMockPage();
    session = createMockSession(mockPage);

    // Default successful responses
    mockPage.waitForSelector.mockResolvedValue(null);
    mockPage.waitForTimeout.mockResolvedValue(undefined);
    mockPage.evaluate.mockResolvedValue(undefined);
  });

  describe('wait', () => {
    it('should wait for selector successfully', async () => {
      const result = await handler.wait(session, { selector: '.loaded' });

      expect(result.success).toBe(true);
      expect(result.data?.selector).toBe('.loaded');
      expect(mockPage.waitForSelector).toHaveBeenCalledWith('.loaded', { timeout: 10000 });
    });

    it('should wait for selector with custom timeout', async () => {
      const result = await handler.wait(session, { selector: '.loaded', timeout: 5000 });

      expect(result.success).toBe(true);
      expect(mockPage.waitForSelector).toHaveBeenCalledWith('.loaded', { timeout: 5000 });
    });

    it('should wait for timeout successfully', async () => {
      const result = await handler.wait(session, { timeout: 2000 });

      expect(result.success).toBe(true);
      expect(result.data?.timeout).toBe(2000);
      expect(mockPage.waitForTimeout).toHaveBeenCalledWith(2000);
    });

    it('should return error when neither selector nor timeout is provided', async () => {
      const result = await handler.wait(session, {});

      expect(result.success).toBe(false);
      expect(result.error).toBe('Either selector or timeout is required');
    });

    it('should return error when waitForSelector fails', async () => {
      mockPage.waitForSelector.mockRejectedValue(new Error('Selector timeout'));

      const result = await handler.wait(session, { selector: '.missing' });

      expect(result.success).toBe(false);
      expect(result.error).toBe('Selector timeout');
    });

    it('should handle non-Error exceptions', async () => {
      mockPage.waitForSelector.mockRejectedValue('String error');

      const result = await handler.wait(session, { selector: '.missing' });

      expect(result.success).toBe(false);
      expect(result.error).toBe('Wait failed');
    });

    it('should use resolveSelector for selector conversion', async () => {
      await handler.wait(session, { selector: 'button:contains("Submit")' });

      expect(deps.resolveSelector).toHaveBeenCalledWith(session, 'button:contains("Submit")');
    });
  });

  describe('scroll', () => {
    it('should scroll down successfully', async () => {
      const result = await handler.scroll(session, { direction: 'down', amount: 500 });

      expect(result.success).toBe(true);
      expect(result.data?.direction).toBe('down');
      expect(result.data?.amount).toBe(500);
      expect(mockPage.evaluate).toHaveBeenCalledWith('window.scrollBy(0, 500)');
    });

    it('should scroll up successfully', async () => {
      const result = await handler.scroll(session, { direction: 'up', amount: 300 });

      expect(result.success).toBe(true);
      expect(mockPage.evaluate).toHaveBeenCalledWith('window.scrollBy(0, -300)');
    });

    it('should scroll left successfully', async () => {
      const result = await handler.scroll(session, { direction: 'left', amount: 200 });

      expect(result.success).toBe(true);
      expect(mockPage.evaluate).toHaveBeenCalledWith('window.scrollBy(-200, 0)');
    });

    it('should scroll right successfully', async () => {
      const result = await handler.scroll(session, { direction: 'right', amount: 200 });

      expect(result.success).toBe(true);
      expect(mockPage.evaluate).toHaveBeenCalledWith('window.scrollBy(200, 0)');
    });

    it('should use default amount of 100', async () => {
      const result = await handler.scroll(session, { direction: 'down' });

      expect(result.success).toBe(true);
      expect(result.data?.amount).toBe(100);
      expect(mockPage.evaluate).toHaveBeenCalledWith('window.scrollBy(0, 100)');
    });

    it('should scroll within element when selector is provided', async () => {
      const result = await handler.scroll(session, {
        direction: 'down',
        amount: 100,
        selector: '.scrollable',
      });

      expect(result.success).toBe(true);
      expect(mockPage.evaluate).toHaveBeenCalledWith(
        "document.querySelector('.scrollable')?.scrollBy(0, 100)"
      );
    });

    it('should return error for invalid direction', async () => {
      const result = await handler.scroll(session, { direction: 'diagonal', amount: 100 });

      expect(result.success).toBe(false);
      expect(result.error).toBe('Invalid scroll direction');
      expect(mockPage.evaluate).not.toHaveBeenCalled();
    });

    it('should return error when scroll fails', async () => {
      mockPage.evaluate.mockRejectedValue(new Error('Scroll error'));

      const result = await handler.scroll(session, { direction: 'down' });

      expect(result.success).toBe(false);
      expect(result.error).toBe('Scroll error');
    });

    it('should handle non-Error exceptions', async () => {
      mockPage.evaluate.mockRejectedValue('String error');

      const result = await handler.scroll(session, { direction: 'down' });

      expect(result.success).toBe(false);
      expect(result.error).toBe('Scroll failed');
    });
  });

  describe('factory function', () => {
    it('should create StateHandler instance', () => {
      const handler = createStateHandler(deps);
      expect(handler).toBeInstanceOf(StateHandler);
    });
  });
});
