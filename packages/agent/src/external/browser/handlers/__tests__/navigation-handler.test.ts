/**
 * @fileoverview Tests for NavigationHandler
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  NavigationHandler,
  createNavigationHandler,
  type NavigationHandlerDeps,
} from '../navigation-handler.js';
import type { BrowserSession } from '../../browser-service.js';

// =============================================================================
// Test Helpers
// =============================================================================

function createMockPage() {
  return {
    goto: vi.fn(),
    goBack: vi.fn(),
    goForward: vi.fn(),
    reload: vi.fn(),
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

function createMockDeps(): NavigationHandlerDeps {
  return {
    getLocator: vi.fn(),
    resolveSelector: vi.fn((_, selector) => selector),
  };
}

// =============================================================================
// Tests
// =============================================================================

describe('NavigationHandler', () => {
  let deps: NavigationHandlerDeps;
  let handler: NavigationHandler;
  let mockPage: ReturnType<typeof createMockPage>;
  let session: BrowserSession;

  beforeEach(() => {
    deps = createMockDeps();
    handler = createNavigationHandler(deps);
    mockPage = createMockPage();
    session = createMockSession(mockPage);

    // Default successful responses
    mockPage.goto.mockResolvedValue(null);
    mockPage.goBack.mockResolvedValue(null);
    mockPage.goForward.mockResolvedValue(null);
    mockPage.reload.mockResolvedValue(null);
  });

  describe('navigate', () => {
    it('should navigate to URL successfully', async () => {
      const result = await handler.navigate(session, { url: 'https://example.com' });

      expect(result.success).toBe(true);
      expect(result.data?.url).toBe('https://example.com');
      expect(mockPage.goto).toHaveBeenCalledWith('https://example.com', {
        waitUntil: 'domcontentloaded',
        timeout: 30000,
      });
    });

    it('should return error when URL is missing', async () => {
      const result = await handler.navigate(session, {});

      expect(result.success).toBe(false);
      expect(result.error).toBe('URL is required');
      expect(mockPage.goto).not.toHaveBeenCalled();
    });

    it('should return error when navigation fails', async () => {
      mockPage.goto.mockRejectedValue(new Error('Network error'));

      const result = await handler.navigate(session, { url: 'https://example.com' });

      expect(result.success).toBe(false);
      expect(result.error).toBe('Network error');
    });

    it('should handle non-Error exceptions', async () => {
      mockPage.goto.mockRejectedValue('String error');

      const result = await handler.navigate(session, { url: 'https://example.com' });

      expect(result.success).toBe(false);
      expect(result.error).toBe('Navigation failed');
    });
  });

  describe('goBack', () => {
    it('should go back in history successfully', async () => {
      const result = await handler.goBack(session);

      expect(result.success).toBe(true);
      expect(result.data).toEqual({});
      expect(mockPage.goBack).toHaveBeenCalledWith({ timeout: 10000 });
    });

    it('should return error when goBack fails', async () => {
      mockPage.goBack.mockRejectedValue(new Error('No history'));

      const result = await handler.goBack(session);

      expect(result.success).toBe(false);
      expect(result.error).toBe('No history');
    });

    it('should handle non-Error exceptions', async () => {
      mockPage.goBack.mockRejectedValue('String error');

      const result = await handler.goBack(session);

      expect(result.success).toBe(false);
      expect(result.error).toBe('Go back failed');
    });
  });

  describe('goForward', () => {
    it('should go forward in history successfully', async () => {
      const result = await handler.goForward(session);

      expect(result.success).toBe(true);
      expect(result.data).toEqual({});
      expect(mockPage.goForward).toHaveBeenCalledWith({ timeout: 10000 });
    });

    it('should return error when goForward fails', async () => {
      mockPage.goForward.mockRejectedValue(new Error('No forward history'));

      const result = await handler.goForward(session);

      expect(result.success).toBe(false);
      expect(result.error).toBe('No forward history');
    });

    it('should handle non-Error exceptions', async () => {
      mockPage.goForward.mockRejectedValue('String error');

      const result = await handler.goForward(session);

      expect(result.success).toBe(false);
      expect(result.error).toBe('Go forward failed');
    });
  });

  describe('reload', () => {
    it('should reload page successfully', async () => {
      const result = await handler.reload(session);

      expect(result.success).toBe(true);
      expect(result.data).toEqual({});
      expect(mockPage.reload).toHaveBeenCalledWith({ timeout: 30000 });
    });

    it('should return error when reload fails', async () => {
      mockPage.reload.mockRejectedValue(new Error('Reload timeout'));

      const result = await handler.reload(session);

      expect(result.success).toBe(false);
      expect(result.error).toBe('Reload timeout');
    });

    it('should handle non-Error exceptions', async () => {
      mockPage.reload.mockRejectedValue('String error');

      const result = await handler.reload(session);

      expect(result.success).toBe(false);
      expect(result.error).toBe('Reload failed');
    });
  });

  describe('factory function', () => {
    it('should create NavigationHandler instance', () => {
      const handler = createNavigationHandler(deps);
      expect(handler).toBeInstanceOf(NavigationHandler);
    });
  });
});
