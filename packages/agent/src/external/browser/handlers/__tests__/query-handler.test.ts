/**
 * @fileoverview Tests for QueryHandler
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  QueryHandler,
  createQueryHandler,
  type QueryHandlerDeps,
} from '../query-handler.js';
import type { BrowserSession } from '../../browser-service.js';
import type { BrowserLocator } from '../types.js';

// =============================================================================
// Test Helpers
// =============================================================================

function createMockLocator(): BrowserLocator & { [key: string]: ReturnType<typeof vi.fn> } {
  return {
    click: vi.fn(),
    fill: vi.fn(),
    pressSequentially: vi.fn(),
    selectOption: vi.fn(),
    hover: vi.fn(),
    innerText: vi.fn(),
    getAttribute: vi.fn(),
  };
}

function createMockSession(): BrowserSession {
  return {
    manager: {} as BrowserSession['manager'],
    isStreaming: false,
    elementRefs: new Map(),
  };
}

function createMockDeps(mockLocator: BrowserLocator): QueryHandlerDeps {
  return {
    getLocator: vi.fn(() => mockLocator),
    resolveSelector: vi.fn((_, selector) => selector),
  };
}

// =============================================================================
// Tests
// =============================================================================

describe('QueryHandler', () => {
  let mockLocator: ReturnType<typeof createMockLocator>;
  let deps: QueryHandlerDeps;
  let handler: QueryHandler;
  let session: BrowserSession;

  beforeEach(() => {
    mockLocator = createMockLocator();
    deps = createMockDeps(mockLocator);
    handler = createQueryHandler(deps);
    session = createMockSession();

    // Default successful responses
    mockLocator.innerText.mockResolvedValue('Sample text content');
    mockLocator.getAttribute.mockResolvedValue('attribute-value');
  });

  describe('getText', () => {
    it('should get text content successfully', async () => {
      const result = await handler.getText(session, { selector: '.content' });

      expect(result.success).toBe(true);
      expect(result.data?.selector).toBe('.content');
      expect(result.data?.text).toBe('Sample text content');
      expect(deps.getLocator).toHaveBeenCalledWith(session, '.content');
      expect(mockLocator.innerText).toHaveBeenCalledWith({ timeout: 10000 });
    });

    it('should return error when selector is missing', async () => {
      const result = await handler.getText(session, {});

      expect(result.success).toBe(false);
      expect(result.error).toBe('Selector is required');
      expect(mockLocator.innerText).not.toHaveBeenCalled();
    });

    it('should return error when getText fails', async () => {
      mockLocator.innerText.mockRejectedValue(new Error('Element not found'));

      const result = await handler.getText(session, { selector: '.missing' });

      expect(result.success).toBe(false);
      expect(result.error).toBe('Element not found');
    });

    it('should handle non-Error exceptions', async () => {
      mockLocator.innerText.mockRejectedValue('String error');

      const result = await handler.getText(session, { selector: '.content' });

      expect(result.success).toBe(false);
      expect(result.error).toBe('Get text failed');
    });

    it('should handle empty text content', async () => {
      mockLocator.innerText.mockResolvedValue('');

      const result = await handler.getText(session, { selector: '.empty' });

      expect(result.success).toBe(true);
      expect(result.data?.text).toBe('');
    });
  });

  describe('getAttribute', () => {
    it('should get attribute value successfully', async () => {
      const result = await handler.getAttribute(session, {
        selector: 'a.link',
        attribute: 'href',
      });

      expect(result.success).toBe(true);
      expect(result.data?.selector).toBe('a.link');
      expect(result.data?.attribute).toBe('href');
      expect(result.data?.value).toBe('attribute-value');
      expect(deps.getLocator).toHaveBeenCalledWith(session, 'a.link');
      expect(mockLocator.getAttribute).toHaveBeenCalledWith('href', { timeout: 10000 });
    });

    it('should return error when selector is missing', async () => {
      const result = await handler.getAttribute(session, { attribute: 'href' });

      expect(result.success).toBe(false);
      expect(result.error).toBe('Selector and attribute are required');
      expect(mockLocator.getAttribute).not.toHaveBeenCalled();
    });

    it('should return error when attribute is missing', async () => {
      const result = await handler.getAttribute(session, { selector: 'a.link' });

      expect(result.success).toBe(false);
      expect(result.error).toBe('Selector and attribute are required');
      expect(mockLocator.getAttribute).not.toHaveBeenCalled();
    });

    it('should return error when getAttribute fails', async () => {
      mockLocator.getAttribute.mockRejectedValue(new Error('Element not found'));

      const result = await handler.getAttribute(session, {
        selector: '.missing',
        attribute: 'id',
      });

      expect(result.success).toBe(false);
      expect(result.error).toBe('Element not found');
    });

    it('should handle non-Error exceptions', async () => {
      mockLocator.getAttribute.mockRejectedValue('String error');

      const result = await handler.getAttribute(session, {
        selector: 'a.link',
        attribute: 'href',
      });

      expect(result.success).toBe(false);
      expect(result.error).toBe('Get attribute failed');
    });

    it('should handle null attribute value', async () => {
      mockLocator.getAttribute.mockResolvedValue(null);

      const result = await handler.getAttribute(session, {
        selector: 'div',
        attribute: 'data-missing',
      });

      expect(result.success).toBe(true);
      expect(result.data?.value).toBeNull();
    });
  });

  describe('factory function', () => {
    it('should create QueryHandler instance', () => {
      const handler = createQueryHandler(deps);
      expect(handler).toBeInstanceOf(QueryHandler);
    });
  });
});
