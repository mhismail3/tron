/**
 * @fileoverview BrowserService unit tests (mocked agent-browser, fast)
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { BrowserService } from '../browser-service.js';

// Create mock objects
const mockLocator = {
  click: vi.fn(),
  fill: vi.fn(),
  pressSequentially: vi.fn(),
  selectOption: vi.fn(),
  hover: vi.fn(),
  innerText: vi.fn(),
  getAttribute: vi.fn(),
};

const mockPage = {
  goto: vi.fn(),
  screenshot: vi.fn(),
  waitForSelector: vi.fn(),
  waitForTimeout: vi.fn(),
  waitForLoadState: vi.fn(() => Promise.resolve()),
  evaluate: vi.fn(),
  goBack: vi.fn(),
  goForward: vi.fn(),
  reload: vi.fn(),
  keyboard: { press: vi.fn() },
  pdf: vi.fn(),
  url: vi.fn(() => 'https://example.com'),
  locator: vi.fn(() => mockLocator),
};

const mockBrowserManager = {
  launch: vi.fn(),
  setViewport: vi.fn(),
  close: vi.fn(),
  getPage: vi.fn(() => mockPage),
  isLaunched: vi.fn(() => true),
  getSnapshot: vi.fn(() => Promise.resolve({ tree: 'test', refs: {} })),
  getRefMap: vi.fn(() => ({})),
  isRef: vi.fn(() => false),
  getLocatorFromRef: vi.fn((): typeof mockLocator | null => null),
  startScreencast: vi.fn(),
  stopScreencast: vi.fn(),
};

// Mock agent-browser
vi.mock('agent-browser/dist/browser.js', () => ({
  BrowserManager: vi.fn(() => mockBrowserManager),
}));

describe('BrowserService', () => {
  let service: BrowserService;

  beforeEach(async () => {
    // Reset all mocks
    vi.clearAllMocks();

    // Reset mock implementations
    mockBrowserManager.launch.mockResolvedValue(undefined);
    mockBrowserManager.setViewport.mockResolvedValue(undefined);
    mockBrowserManager.close.mockResolvedValue(undefined);
    mockBrowserManager.startScreencast.mockResolvedValue(undefined);
    mockBrowserManager.stopScreencast.mockResolvedValue(undefined);
    mockBrowserManager.getSnapshot.mockResolvedValue({ tree: 'test', refs: {} });
    mockBrowserManager.getRefMap.mockReturnValue({});
    mockBrowserManager.isLaunched.mockReturnValue(true);
    mockBrowserManager.isRef.mockReturnValue(false);
    mockBrowserManager.getLocatorFromRef.mockReturnValue(null);

    mockPage.goto.mockResolvedValue(null);
    mockPage.screenshot.mockResolvedValue(Buffer.from('fake-image-data'));
    mockPage.waitForLoadState.mockResolvedValue(undefined);
    mockPage.evaluate.mockResolvedValue(undefined);
    mockPage.goBack.mockResolvedValue(null);
    mockPage.goForward.mockResolvedValue(null);
    mockPage.reload.mockResolvedValue(null);
    mockPage.keyboard.press.mockResolvedValue(undefined);
    mockPage.pdf.mockResolvedValue(Buffer.from('fake-pdf'));

    mockLocator.click.mockResolvedValue(undefined);
    mockLocator.fill.mockResolvedValue(undefined);
    mockLocator.pressSequentially.mockResolvedValue(undefined);
    mockLocator.selectOption.mockResolvedValue(undefined);
    mockLocator.hover.mockResolvedValue(undefined);
    mockLocator.innerText.mockResolvedValue('text content');
    mockLocator.getAttribute.mockResolvedValue('href-value');

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
      expect(mockBrowserManager.launch).toHaveBeenCalled();
      expect(mockBrowserManager.setViewport).toHaveBeenCalledWith(1280, 800);
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
      expect(mockBrowserManager.close).toHaveBeenCalled();
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

      const result = await service.execute('test-session', 'click', { selector: 'button' });

      expect(result.success).toBe(true);
      expect(mockLocator.click).toHaveBeenCalledWith(expect.any(Object));
    });

    it('should return error when selector is missing', async () => {
      await service.createSession('test-session');

      const result = await service.execute('test-session', 'click', {});

      expect(result.success).toBe(false);
      expect(result.error).toContain('Selector is required');
    });
  });

  describe('fill action', () => {
    it('should fill input field', async () => {
      await service.createSession('test-session');

      const result = await service.execute('test-session', 'fill', {
        selector: '#email',
        value: 'test@example.com'
      });

      expect(result.success).toBe(true);
      expect(mockLocator.fill).toHaveBeenCalledWith('test@example.com', expect.any(Object));
    });
  });

  describe('screenshot action', () => {
    it('should take screenshot', async () => {
      await service.createSession('test-session');

      const result = await service.execute('test-session', 'screenshot', {});

      expect(result.success).toBe(true);
      expect(result.data?.screenshot).toBeDefined();
      expect(mockPage.screenshot).toHaveBeenCalled();
    });

    it('should always use viewport-only (fullPage: false) for consistent dimensions', async () => {
      await service.createSession('test-session');

      await service.execute('test-session', 'screenshot', { fullPage: true });

      expect(mockPage.screenshot).toHaveBeenCalledWith(expect.objectContaining({ fullPage: false }));
    });
  });

  describe('snapshot action', () => {
    it('should get accessibility snapshot', async () => {
      await service.createSession('test-session');

      const result = await service.execute('test-session', 'snapshot', {});

      expect(result.success).toBe(true);
      expect(result.data?.snapshot).toBeDefined();
      expect(result.data?.elementRefs).toBeDefined();
      expect(mockBrowserManager.getSnapshot).toHaveBeenCalled();
    });
  });

  describe('scroll action', () => {
    it('should scroll page', async () => {
      await service.createSession('test-session');

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

  describe('new actions', () => {
    it('should go back', async () => {
      await service.createSession('test-session');

      const result = await service.execute('test-session', 'goBack', {});

      expect(result.success).toBe(true);
      expect(mockPage.goBack).toHaveBeenCalled();
    });

    it('should go forward', async () => {
      await service.createSession('test-session');

      const result = await service.execute('test-session', 'goForward', {});

      expect(result.success).toBe(true);
      expect(mockPage.goForward).toHaveBeenCalled();
    });

    it('should reload', async () => {
      await service.createSession('test-session');

      const result = await service.execute('test-session', 'reload', {});

      expect(result.success).toBe(true);
      expect(mockPage.reload).toHaveBeenCalled();
    });

    it('should hover', async () => {
      await service.createSession('test-session');

      const result = await service.execute('test-session', 'hover', { selector: 'button' });

      expect(result.success).toBe(true);
      expect(mockLocator.hover).toHaveBeenCalled();
    });

    it('should press key', async () => {
      await service.createSession('test-session');

      const result = await service.execute('test-session', 'pressKey', { key: 'Enter' });

      expect(result.success).toBe(true);
      expect(mockPage.keyboard.press).toHaveBeenCalledWith('Enter');
    });

    it('should get text', async () => {
      await service.createSession('test-session');

      const result = await service.execute('test-session', 'getText', { selector: '.content' });

      expect(result.success).toBe(true);
      expect(result.data?.text).toBe('text content');
      expect(mockLocator.innerText).toHaveBeenCalled();
    });

    it('should get attribute', async () => {
      await service.createSession('test-session');

      const result = await service.execute('test-session', 'getAttribute', {
        selector: 'a',
        attribute: 'href'
      });

      expect(result.success).toBe(true);
      expect(result.data?.value).toBe('href-value');
      expect(mockLocator.getAttribute).toHaveBeenCalledWith('href', expect.any(Object));
    });

    it('should generate pdf', async () => {
      await service.createSession('test-session');

      const result = await service.execute('test-session', 'pdf', { path: '/tmp/page.pdf' });

      expect(result.success).toBe(true);
      expect(mockPage.pdf).toHaveBeenCalledWith({ path: '/tmp/page.pdf' });
    });
  });

  describe('screencast', () => {
    it('should start screencast', async () => {
      await service.createSession('test-session');

      const result = await service.startScreencast('test-session', {
        format: 'jpeg',
        quality: 60,
        everyNthFrame: 6
      });

      expect(result.success).toBe(true);
      expect(mockBrowserManager.startScreencast).toHaveBeenCalled();
    });

    it('should restart streaming when called while already streaming', async () => {
      await service.createSession('test-session');
      await service.startScreencast('test-session');

      // Set isStreaming manually since mock doesn't track state
      const session = service.getSession('test-session');
      if (session) session.isStreaming = true;

      // Clear mock calls to track the restart behavior
      mockBrowserManager.stopScreencast.mockClear();
      mockBrowserManager.startScreencast.mockClear();

      const result = await service.startScreencast('test-session');

      expect(result.success).toBe(true);
      // Should have stopped first, then restarted
      expect(mockBrowserManager.stopScreencast).toHaveBeenCalled();
      expect(mockBrowserManager.startScreencast).toHaveBeenCalled();
    });

    it('should stop screencast', async () => {
      await service.createSession('test-session');
      await service.startScreencast('test-session');

      // Set isStreaming manually
      const session = service.getSession('test-session');
      if (session) session.isStreaming = true;

      const result = await service.stopScreencast('test-session');

      expect(result.success).toBe(true);
      expect(mockBrowserManager.stopScreencast).toHaveBeenCalled();
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
    it('should convert :contains() with double quotes via resolveSelector', async () => {
      await service.createSession('test-session');

      await service.execute('test-session', 'click', { selector: 'button:contains("Submit")' });

      // The locator should be created with the converted selector
      expect(mockPage.locator).toHaveBeenCalledWith('button:has-text("Submit")');
    });

    it('should convert :contains() with single quotes', async () => {
      await service.createSession('test-session');

      await service.execute('test-session', 'click', { selector: "button:contains('Submit')" });

      expect(mockPage.locator).toHaveBeenCalledWith('button:has-text("Submit")');
    });

    it('should handle multiple :contains() conversions', async () => {
      await service.createSession('test-session');

      await service.execute('test-session', 'click', {
        selector: 'div:contains("Projects") button:contains("New")'
      });

      expect(mockPage.locator).toHaveBeenCalledWith(
        'div:has-text("Projects") button:has-text("New")'
      );
    });

    it('should use ref locator when selector is a ref', async () => {
      mockBrowserManager.isRef.mockReturnValue(true);
      mockBrowserManager.getLocatorFromRef.mockReturnValue(mockLocator);

      await service.createSession('test-session');

      await service.execute('test-session', 'click', { selector: 'e1' });

      expect(mockBrowserManager.isRef).toHaveBeenCalledWith('e1');
      expect(mockBrowserManager.getLocatorFromRef).toHaveBeenCalledWith('e1');
      expect(mockLocator.click).toHaveBeenCalled();
    });
  });
});
