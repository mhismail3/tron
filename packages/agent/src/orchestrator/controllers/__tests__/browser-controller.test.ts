/**
 * @fileoverview BrowserController Tests
 *
 * Tests for the BrowserController which manages browser streaming operations.
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';
import {
  BrowserController,
  createBrowserController,
  type BrowserControllerConfig,
} from '../browser-controller.js';

describe('BrowserController', () => {
  let mockBrowserService: any;
  let controller: BrowserController;

  beforeEach(() => {
    mockBrowserService = {
      hasSession: vi.fn(),
      createSession: vi.fn(),
      startScreencast: vi.fn(),
      stopScreencast: vi.fn(),
      getSession: vi.fn(),
    };

    controller = createBrowserController({
      browserService: mockBrowserService,
    });
  });

  // ===========================================================================
  // startStream
  // ===========================================================================

  describe('startStream', () => {
    it('creates session if needed and starts screencast', async () => {
      mockBrowserService.hasSession.mockReturnValue(false);
      mockBrowserService.createSession.mockResolvedValue({ success: true });
      mockBrowserService.startScreencast.mockResolvedValue({ success: true });

      const result = await controller.startStream('sess-123');

      expect(result.success).toBe(true);
      expect(mockBrowserService.hasSession).toHaveBeenCalledWith('sess-123');
      expect(mockBrowserService.createSession).toHaveBeenCalledWith('sess-123');
      expect(mockBrowserService.startScreencast).toHaveBeenCalledWith('sess-123');
    });

    it('starts screencast directly if session already exists', async () => {
      mockBrowserService.hasSession.mockReturnValue(true);
      mockBrowserService.startScreencast.mockResolvedValue({ success: true });

      const result = await controller.startStream('sess-123');

      expect(result.success).toBe(true);
      expect(mockBrowserService.createSession).not.toHaveBeenCalled();
      expect(mockBrowserService.startScreencast).toHaveBeenCalledWith('sess-123');
    });

    it('returns error when session creation fails', async () => {
      mockBrowserService.hasSession.mockReturnValue(false);
      mockBrowserService.createSession.mockResolvedValue({
        success: false,
        error: 'Failed to launch browser',
      });

      const result = await controller.startStream('sess-123');

      expect(result.success).toBe(false);
      expect(result.error).toBe('Failed to launch browser');
      expect(mockBrowserService.startScreencast).not.toHaveBeenCalled();
    });

    it('returns error when screencast fails', async () => {
      mockBrowserService.hasSession.mockReturnValue(true);
      mockBrowserService.startScreencast.mockResolvedValue({
        success: false,
        error: 'Screencast already running',
      });

      const result = await controller.startStream('sess-123');

      expect(result.success).toBe(false);
      expect(result.error).toBe('Screencast already running');
    });

    it('provides default error message when none provided', async () => {
      mockBrowserService.hasSession.mockReturnValue(false);
      mockBrowserService.createSession.mockResolvedValue({ success: false });

      const result = await controller.startStream('sess-123');

      expect(result.success).toBe(false);
      expect(result.error).toBe('Failed to create browser session');
    });
  });

  // ===========================================================================
  // stopStream
  // ===========================================================================

  describe('stopStream', () => {
    it('stops screencast for existing session', async () => {
      mockBrowserService.hasSession.mockReturnValue(true);
      mockBrowserService.stopScreencast.mockResolvedValue({ success: true });

      const result = await controller.stopStream('sess-123');

      expect(result.success).toBe(true);
      expect(mockBrowserService.stopScreencast).toHaveBeenCalledWith('sess-123');
    });

    it('returns success if session does not exist', async () => {
      mockBrowserService.hasSession.mockReturnValue(false);

      const result = await controller.stopStream('sess-123');

      expect(result.success).toBe(true);
      expect(mockBrowserService.stopScreencast).not.toHaveBeenCalled();
    });

    it('returns error when stop fails', async () => {
      mockBrowserService.hasSession.mockReturnValue(true);
      mockBrowserService.stopScreencast.mockResolvedValue({
        success: false,
        error: 'Connection lost',
      });

      const result = await controller.stopStream('sess-123');

      expect(result.success).toBe(false);
      expect(result.error).toBe('Connection lost');
    });

    it('provides default error message when none provided', async () => {
      mockBrowserService.hasSession.mockReturnValue(true);
      mockBrowserService.stopScreencast.mockResolvedValue({ success: false });

      const result = await controller.stopStream('sess-123');

      expect(result.success).toBe(false);
      expect(result.error).toBe('Failed to stop screencast');
    });
  });

  // ===========================================================================
  // getStatus
  // ===========================================================================

  describe('getStatus', () => {
    it('returns hasBrowser false when no session exists', async () => {
      mockBrowserService.hasSession.mockReturnValue(false);

      const result = await controller.getStatus('sess-123');

      expect(result).toEqual({ hasBrowser: false, isStreaming: false });
    });

    it('returns streaming status from session', async () => {
      mockBrowserService.hasSession.mockReturnValue(true);
      mockBrowserService.getSession.mockReturnValue({
        isStreaming: true,
        manager: {
          isLaunched: () => true,
          getPage: () => ({ url: () => 'https://example.com' }),
        },
      });

      const result = await controller.getStatus('sess-123');

      expect(result.hasBrowser).toBe(true);
      expect(result.isStreaming).toBe(true);
      expect(result.currentUrl).toBe('https://example.com');
    });

    it('handles session with no manager', async () => {
      mockBrowserService.hasSession.mockReturnValue(true);
      mockBrowserService.getSession.mockReturnValue({
        isStreaming: false,
        manager: null,
      });

      const result = await controller.getStatus('sess-123');

      expect(result.hasBrowser).toBe(true);
      expect(result.isStreaming).toBe(false);
      expect(result.currentUrl).toBeUndefined();
    });

    it('handles browser not launched', async () => {
      mockBrowserService.hasSession.mockReturnValue(true);
      mockBrowserService.getSession.mockReturnValue({
        isStreaming: false,
        manager: {
          isLaunched: () => false,
        },
      });

      const result = await controller.getStatus('sess-123');

      expect(result.hasBrowser).toBe(true);
      expect(result.isStreaming).toBe(false);
      expect(result.currentUrl).toBeUndefined();
    });

    it('handles errors when getting URL', async () => {
      mockBrowserService.hasSession.mockReturnValue(true);
      mockBrowserService.getSession.mockReturnValue({
        isStreaming: true,
        manager: {
          isLaunched: () => true,
          getPage: () => {
            throw new Error('Page closed');
          },
        },
      });

      const result = await controller.getStatus('sess-123');

      expect(result.hasBrowser).toBe(true);
      expect(result.isStreaming).toBe(true);
      expect(result.currentUrl).toBeUndefined();
    });
  });

  // ===========================================================================
  // Factory Function
  // ===========================================================================

  describe('createBrowserController', () => {
    it('creates a BrowserController instance', () => {
      const ctrl = createBrowserController({
        browserService: mockBrowserService,
      });

      expect(ctrl).toBeInstanceOf(BrowserController);
    });
  });
});
