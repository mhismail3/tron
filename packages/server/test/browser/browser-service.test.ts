/**
 * @fileoverview BrowserService unit tests (mocked Playwright, fast)
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { BrowserService } from '../../src/browser/browser-service.js';

// Mock playwright-core
vi.mock('playwright-core', () => ({
  chromium: {
    launch: vi.fn(),
  },
}));

describe('BrowserService', () => {
  let service: BrowserService;
  let mockBrowser: any;
  let mockPage: any;
  let mockCDPSession: any;

  beforeEach(async () => {
    // Setup mocks
    mockCDPSession = {
      on: vi.fn(),
      send: vi.fn(),
    };

    mockPage = {
      goto: vi.fn(),
      click: vi.fn(),
      fill: vi.fn(),
      type: vi.fn(),
      selectOption: vi.fn(),
      screenshot: vi.fn(),
      accessibility: {
        snapshot: vi.fn(),
      },
      waitForSelector: vi.fn(),
      waitForTimeout: vi.fn(),
      waitForLoadState: vi.fn(() => Promise.resolve()),
      evaluate: vi.fn(),
      context: vi.fn(() => ({
        newCDPSession: vi.fn(() => Promise.resolve(mockCDPSession)),
      })),
    };

    mockBrowser = {
      newPage: vi.fn(() => Promise.resolve(mockPage)),
      close: vi.fn(),
    };

    const { chromium } = await import('playwright-core');
    vi.mocked(chromium.launch).mockResolvedValue(mockBrowser as any);

    service = new BrowserService({ headless: true });
  });

  afterEach(async () => {
    await service.cleanup();
    vi.clearAllMocks();
  });

  describe('session management', () => {
    it('should create a new session', async () => {
      const result = await service.createSession('test-session');

      expect(result.success).toBe(true);
      expect(service.hasSession('test-session')).toBe(true);
    });

    it('should return success if session already exists', async () => {
      await service.createSession('test-session');
      const result = await service.createSession('test-session');

      expect(result.success).toBe(true);
      expect(result.data?.message).toContain('already exists');
    });

    it('should close a session', async () => {
      await service.createSession('test-session');
      const result = await service.closeSession('test-session');

      expect(result.success).toBe(true);
      expect(service.hasSession('test-session')).toBe(false);
      expect(mockBrowser.close).toHaveBeenCalled();
    });

    it('should return error when closing non-existent session', async () => {
      const result = await service.closeSession('non-existent');

      expect(result.success).toBe(false);
      expect(result.error).toContain('not found');
    });

    it('should get existing session', async () => {
      await service.createSession('test-session');
      const session = service.getSession('test-session');

      expect(session).toBeDefined();
      expect(session?.isStreaming).toBe(false);
    });

    it('should return undefined for non-existent session', () => {
      const session = service.getSession('non-existent');
      expect(session).toBeUndefined();
    });
  });

  describe('navigate action', () => {
    it('should navigate to URL', async () => {
      await service.createSession('test-session');
      vi.mocked(mockPage.goto).mockResolvedValue(null);

      const result = await service.execute('test-session', 'navigate', { url: 'https://example.com' });

      expect(result.success).toBe(true);
      expect(mockPage.goto).toHaveBeenCalledWith('https://example.com', expect.any(Object));
    });

    it('should return error when URL is missing', async () => {
      await service.createSession('test-session');

      const result = await service.execute('test-session', 'navigate', {});

      expect(result.success).toBe(false);
      expect(result.error).toContain('URL is required');
    });

    it('should return error for non-existent session', async () => {
      const result = await service.execute('non-existent', 'navigate', { url: 'https://example.com' });

      expect(result.success).toBe(false);
      expect(result.error).toContain('not found');
    });
  });

  describe('click action', () => {
    it('should click element', async () => {
      await service.createSession('test-session');
      vi.mocked(mockPage.click).mockResolvedValue(undefined);

      const result = await service.execute('test-session', 'click', { selector: 'button' });

      expect(result.success).toBe(true);
      expect(mockPage.click).toHaveBeenCalledWith('button', expect.any(Object));
    });

    it('should return error when selector is missing', async () => {
      await service.createSession('test-session');

      const result = await service.execute('test-session', 'click', {});

      expect(result.success).toBe(false);
      expect(result.error).toContain('Selector is required');
    });

    it('should convert :contains() selector', async () => {
      await service.createSession('test-session');
      vi.mocked(mockPage.click).mockResolvedValue(undefined);

      await service.execute('test-session', 'click', { selector: 'button:contains("Submit")' });

      expect(mockPage.click).toHaveBeenCalledWith('button:has-text("Submit")', expect.any(Object));
    });
  });

  describe('fill action', () => {
    it('should fill input field', async () => {
      await service.createSession('test-session');
      vi.mocked(mockPage.fill).mockResolvedValue(undefined);

      const result = await service.execute('test-session', 'fill', {
        selector: '#email',
        value: 'test@example.com'
      });

      expect(result.success).toBe(true);
      expect(mockPage.fill).toHaveBeenCalledWith('#email', 'test@example.com', expect.any(Object));
    });
  });

  describe('screenshot action', () => {
    it('should take screenshot', async () => {
      await service.createSession('test-session');
      vi.mocked(mockPage.screenshot).mockResolvedValue(Buffer.from('fake-image-data'));

      const result = await service.execute('test-session', 'screenshot', {});

      expect(result.success).toBe(true);
      expect(result.data?.screenshot).toBeDefined();
      expect(mockPage.screenshot).toHaveBeenCalled();
    });

    it('should always use viewport-only (fullPage: false) for consistent dimensions', async () => {
      await service.createSession('test-session');
      vi.mocked(mockPage.screenshot).mockResolvedValue(Buffer.from('fake-image-data'));

      // Even if fullPage: true is passed, it should be ignored
      await service.execute('test-session', 'screenshot', { fullPage: true });

      expect(mockPage.screenshot).toHaveBeenCalledWith(expect.objectContaining({ fullPage: false }));
    });
  });

  describe('snapshot action', () => {
    it('should get accessibility snapshot', async () => {
      await service.createSession('test-session');
      vi.mocked(mockPage.accessibility.snapshot).mockResolvedValue({
        role: 'document',
        name: 'Test Page',
        children: [{ role: 'button', name: 'Submit' }]
      });

      const result = await service.execute('test-session', 'snapshot', {});

      expect(result.success).toBe(true);
      expect(result.data?.snapshot).toBeDefined();
      expect(result.data?.elementRefs).toBeDefined();
      expect(mockPage.accessibility.snapshot).toHaveBeenCalled();
    });
  });

  describe('scroll action', () => {
    it('should scroll page', async () => {
      await service.createSession('test-session');
      vi.mocked(mockPage.evaluate).mockResolvedValue(undefined);

      const result = await service.execute('test-session', 'scroll', {
        direction: 'down',
        amount: 500
      });

      expect(result.success).toBe(true);
      expect(mockPage.evaluate).toHaveBeenCalled();
    });

    it('should return error for invalid direction', async () => {
      await service.createSession('test-session');

      const result = await service.execute('test-session', 'scroll', {
        direction: 'invalid',
        amount: 100
      });

      expect(result.success).toBe(false);
      expect(result.error).toContain('Invalid scroll direction');
    });
  });

  describe('screencast', () => {
    it('should start screencast', async () => {
      await service.createSession('test-session');
      vi.mocked(mockCDPSession.send).mockResolvedValue(undefined);

      const result = await service.startScreencast('test-session', {
        format: 'jpeg',
        quality: 60,
        everyNthFrame: 6
      });

      expect(result.success).toBe(true);
      expect(mockCDPSession.on).toHaveBeenCalledWith('Page.screencastFrame', expect.any(Function));
      expect(mockCDPSession.send).toHaveBeenCalledWith('Page.startScreencast', expect.objectContaining({
        format: 'jpeg',
        quality: 60,
        everyNthFrame: 6
      }));
    });

    it('should return success if already streaming', async () => {
      await service.createSession('test-session');
      await service.startScreencast('test-session');
      const result = await service.startScreencast('test-session');

      expect(result.success).toBe(true);
      expect(result.data?.message).toContain('Already streaming');
    });

    it('should stop screencast', async () => {
      await service.createSession('test-session');
      await service.startScreencast('test-session');
      vi.mocked(mockCDPSession.send).mockResolvedValue(undefined);

      const result = await service.stopScreencast('test-session');

      expect(result.success).toBe(true);
      expect(mockCDPSession.send).toHaveBeenCalledWith('Page.stopScreencast');
    });

    it('should emit browser.frame event', async () => {
      await service.createSession('test-session');

      const frameHandler = vi.fn();
      service.on('browser.frame', frameHandler);

      // Mock the CDP send to return a proper promise
      vi.mocked(mockCDPSession.send).mockImplementation((method: string) => {
        if (method === 'Page.screencastFrameAck') {
          return Promise.resolve();
        }
        return Promise.resolve(undefined);
      });

      await service.startScreencast('test-session');

      // Simulate CDP frame event
      const frameCallback = vi.mocked(mockCDPSession.on).mock.calls.find(
        call => call[0] === 'Page.screencastFrame'
      )?.[1];

      if (frameCallback) {
        await frameCallback({
          data: 'base64-frame-data',
          sessionId: 123,
          metadata: { deviceWidth: 1280, deviceHeight: 800 }
        });

        expect(frameHandler).toHaveBeenCalledWith(expect.objectContaining({
          sessionId: 'test-session',
          data: 'base64-frame-data',
          frameId: 123
        }));
      }
    });
  });

  describe('unknown action', () => {
    it('should return error for unknown action', async () => {
      await service.createSession('test-session');

      const result = await service.execute('test-session', 'unknown-action', {});

      expect(result.success).toBe(false);
      expect(result.error).toContain('Unknown action');
    });
  });

  describe('cleanup', () => {
    it('should close all sessions on cleanup', async () => {
      await service.createSession('session-1');
      await service.createSession('session-2');

      await service.cleanup();

      expect(service.hasSession('session-1')).toBe(false);
      expect(service.hasSession('session-2')).toBe(false);
    });
  });

  describe('selector conversion', () => {
    it('should convert :contains() with double quotes', async () => {
      await service.createSession('test-session');
      vi.mocked(mockPage.click).mockResolvedValue(undefined);

      await service.execute('test-session', 'click', { selector: 'button:contains("Submit")' });

      expect(mockPage.click).toHaveBeenCalledWith('button:has-text("Submit")', expect.any(Object));
    });

    it('should convert :contains() with single quotes', async () => {
      await service.createSession('test-session');
      vi.mocked(mockPage.click).mockResolvedValue(undefined);

      await service.execute('test-session', 'click', { selector: "button:contains('Submit')" });

      expect(mockPage.click).toHaveBeenCalledWith('button:has-text("Submit")', expect.any(Object));
    });

    it('should handle multiple :contains() conversions', async () => {
      await service.createSession('test-session');
      vi.mocked(mockPage.click).mockResolvedValue(undefined);

      await service.execute('test-session', 'click', {
        selector: 'div:contains("Projects") button:contains("New")'
      });

      expect(mockPage.click).toHaveBeenCalledWith(
        'div:has-text("Projects") button:has-text("New")',
        expect.any(Object)
      );
    });
  });
});
