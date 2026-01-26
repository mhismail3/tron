/**
 * @fileoverview Tests for InputHandler
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  InputHandler,
  createInputHandler,
  type InputHandlerDeps,
} from '../input-handler.js';
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

function createMockPage() {
  return {
    keyboard: {
      press: vi.fn(),
    },
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

function createMockDeps(mockLocator: BrowserLocator): InputHandlerDeps {
  return {
    getLocator: vi.fn(() => mockLocator),
    resolveSelector: vi.fn((_, selector) => selector),
  };
}

// =============================================================================
// Tests
// =============================================================================

describe('InputHandler', () => {
  let mockLocator: ReturnType<typeof createMockLocator>;
  let deps: InputHandlerDeps;
  let handler: InputHandler;
  let mockPage: ReturnType<typeof createMockPage>;
  let session: BrowserSession;

  beforeEach(() => {
    mockLocator = createMockLocator();
    deps = createMockDeps(mockLocator);
    handler = createInputHandler(deps);
    mockPage = createMockPage();
    session = createMockSession(mockPage);

    // Default successful responses
    mockLocator.click.mockResolvedValue(undefined);
    mockLocator.fill.mockResolvedValue(undefined);
    mockLocator.pressSequentially.mockResolvedValue(undefined);
    mockLocator.selectOption.mockResolvedValue(['value']);
    mockLocator.hover.mockResolvedValue(undefined);
    mockPage.keyboard.press.mockResolvedValue(undefined);
  });

  describe('click', () => {
    it('should click element successfully', async () => {
      const result = await handler.click(session, { selector: 'button.submit' });

      expect(result.success).toBe(true);
      expect(result.data?.selector).toBe('button.submit');
      expect(deps.getLocator).toHaveBeenCalledWith(session, 'button.submit');
      expect(mockLocator.click).toHaveBeenCalledWith({ timeout: 10000 });
    });

    it('should return error when selector is missing', async () => {
      const result = await handler.click(session, {});

      expect(result.success).toBe(false);
      expect(result.error).toBe('Selector is required');
      expect(mockLocator.click).not.toHaveBeenCalled();
    });

    it('should return error when click fails', async () => {
      mockLocator.click.mockRejectedValue(new Error('Element not found'));

      const result = await handler.click(session, { selector: 'button' });

      expect(result.success).toBe(false);
      expect(result.error).toBe('Element not found');
    });

    it('should handle non-Error exceptions', async () => {
      mockLocator.click.mockRejectedValue('String error');

      const result = await handler.click(session, { selector: 'button' });

      expect(result.success).toBe(false);
      expect(result.error).toBe('Click failed');
    });
  });

  describe('fill', () => {
    it('should fill input field successfully', async () => {
      const result = await handler.fill(session, {
        selector: '#email',
        value: 'test@example.com',
      });

      expect(result.success).toBe(true);
      expect(result.data?.selector).toBe('#email');
      expect(result.data?.value).toBe('test@example.com');
      expect(deps.getLocator).toHaveBeenCalledWith(session, '#email');
      expect(mockLocator.fill).toHaveBeenCalledWith('test@example.com', { timeout: 10000 });
    });

    it('should return error when selector is missing', async () => {
      const result = await handler.fill(session, { value: 'test' });

      expect(result.success).toBe(false);
      expect(result.error).toBe('Selector and value are required');
    });

    it('should return error when value is missing', async () => {
      const result = await handler.fill(session, { selector: '#email' });

      expect(result.success).toBe(false);
      expect(result.error).toBe('Selector and value are required');
    });

    it('should allow empty string as value', async () => {
      const result = await handler.fill(session, { selector: '#email', value: '' });

      expect(result.success).toBe(true);
      expect(mockLocator.fill).toHaveBeenCalledWith('', { timeout: 10000 });
    });

    it('should return error when fill fails', async () => {
      mockLocator.fill.mockRejectedValue(new Error('Input disabled'));

      const result = await handler.fill(session, { selector: '#email', value: 'test' });

      expect(result.success).toBe(false);
      expect(result.error).toBe('Input disabled');
    });
  });

  describe('type', () => {
    it('should type text successfully', async () => {
      const result = await handler.type(session, {
        selector: '#search',
        text: 'hello world',
      });

      expect(result.success).toBe(true);
      expect(result.data?.selector).toBe('#search');
      expect(result.data?.text).toBe('hello world');
      expect(mockLocator.pressSequentially).toHaveBeenCalledWith('hello world', { timeout: 10000 });
    });

    it('should return error when selector is missing', async () => {
      const result = await handler.type(session, { text: 'hello' });

      expect(result.success).toBe(false);
      expect(result.error).toBe('Selector and text are required');
    });

    it('should return error when text is missing', async () => {
      const result = await handler.type(session, { selector: '#search' });

      expect(result.success).toBe(false);
      expect(result.error).toBe('Selector and text are required');
    });

    it('should return error when type fails', async () => {
      mockLocator.pressSequentially.mockRejectedValue(new Error('Element not editable'));

      const result = await handler.type(session, { selector: '#search', text: 'hello' });

      expect(result.success).toBe(false);
      expect(result.error).toBe('Element not editable');
    });
  });

  describe('select', () => {
    it('should select single option successfully', async () => {
      const result = await handler.select(session, {
        selector: '#country',
        value: 'US',
      });

      expect(result.success).toBe(true);
      expect(result.data?.selector).toBe('#country');
      expect(result.data?.value).toBe('US');
      expect(mockLocator.selectOption).toHaveBeenCalledWith(['US'], { timeout: 10000 });
    });

    it('should select multiple options successfully', async () => {
      const result = await handler.select(session, {
        selector: '#colors',
        value: ['red', 'blue'],
      });

      expect(result.success).toBe(true);
      expect(result.data?.value).toEqual(['red', 'blue']);
      expect(mockLocator.selectOption).toHaveBeenCalledWith(['red', 'blue'], { timeout: 10000 });
    });

    it('should return error when selector is missing', async () => {
      const result = await handler.select(session, { value: 'option' });

      expect(result.success).toBe(false);
      expect(result.error).toBe('Selector and value are required');
    });

    it('should return error when value is missing', async () => {
      const result = await handler.select(session, { selector: '#dropdown' });

      expect(result.success).toBe(false);
      expect(result.error).toBe('Selector and value are required');
    });

    it('should return error when select fails', async () => {
      mockLocator.selectOption.mockRejectedValue(new Error('Option not found'));

      const result = await handler.select(session, { selector: '#country', value: 'XX' });

      expect(result.success).toBe(false);
      expect(result.error).toBe('Option not found');
    });
  });

  describe('hover', () => {
    it('should hover over element successfully', async () => {
      const result = await handler.hover(session, { selector: '.menu-item' });

      expect(result.success).toBe(true);
      expect(result.data?.selector).toBe('.menu-item');
      expect(mockLocator.hover).toHaveBeenCalledWith({ timeout: 10000 });
    });

    it('should return error when selector is missing', async () => {
      const result = await handler.hover(session, {});

      expect(result.success).toBe(false);
      expect(result.error).toBe('Selector is required');
    });

    it('should return error when hover fails', async () => {
      mockLocator.hover.mockRejectedValue(new Error('Element hidden'));

      const result = await handler.hover(session, { selector: '.menu-item' });

      expect(result.success).toBe(false);
      expect(result.error).toBe('Element hidden');
    });
  });

  describe('pressKey', () => {
    it('should press key successfully', async () => {
      const result = await handler.pressKey(session, { key: 'Enter' });

      expect(result.success).toBe(true);
      expect(result.data?.key).toBe('Enter');
      expect(mockPage.keyboard.press).toHaveBeenCalledWith('Enter');
    });

    it('should return error when key is missing', async () => {
      const result = await handler.pressKey(session, {});

      expect(result.success).toBe(false);
      expect(result.error).toBe('Key is required');
    });

    it('should return error when pressKey fails', async () => {
      mockPage.keyboard.press.mockRejectedValue(new Error('Invalid key'));

      const result = await handler.pressKey(session, { key: 'InvalidKey' });

      expect(result.success).toBe(false);
      expect(result.error).toBe('Invalid key');
    });

    it('should handle non-Error exceptions', async () => {
      mockPage.keyboard.press.mockRejectedValue('String error');

      const result = await handler.pressKey(session, { key: 'Enter' });

      expect(result.success).toBe(false);
      expect(result.error).toBe('Press key failed');
    });
  });

  describe('factory function', () => {
    it('should create InputHandler instance', () => {
      const handler = createInputHandler(deps);
      expect(handler).toBeInstanceOf(InputHandler);
    });
  });
});
