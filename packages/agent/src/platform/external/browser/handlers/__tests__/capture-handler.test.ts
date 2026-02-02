/**
 * @fileoverview Tests for CaptureHandler
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  CaptureHandler,
  createCaptureHandler,
  type CaptureHandlerDeps,
} from '../capture-handler.js';
import type { BrowserSession } from '../../browser-service.js';

// =============================================================================
// Test Helpers
// =============================================================================

function createMockPage() {
  return {
    screenshot: vi.fn(),
    pdf: vi.fn(),
    waitForLoadState: vi.fn(),
    waitForTimeout: vi.fn(),
  };
}

function createMockManager(mockPage: ReturnType<typeof createMockPage>) {
  return {
    getPage: () => mockPage,
    getSnapshot: vi.fn(),
    getRefMap: vi.fn(),
  };
}

function createMockSession(
  mockManager: ReturnType<typeof createMockManager>
): BrowserSession {
  return {
    manager: mockManager as unknown as BrowserSession['manager'],
    isStreaming: false,
    elementRefs: new Map(),
    lastSnapshot: undefined,
  };
}

function createMockDeps(): CaptureHandlerDeps {
  return {
    getLocator: vi.fn(),
    resolveSelector: vi.fn((_, selector) => selector),
    viewport: { width: 1280, height: 800 },
  };
}

// =============================================================================
// Tests
// =============================================================================

describe('CaptureHandler', () => {
  let deps: CaptureHandlerDeps;
  let handler: CaptureHandler;
  let mockPage: ReturnType<typeof createMockPage>;
  let mockManager: ReturnType<typeof createMockManager>;
  let session: BrowserSession;

  beforeEach(() => {
    deps = createMockDeps();
    handler = createCaptureHandler(deps);
    mockPage = createMockPage();
    mockManager = createMockManager(mockPage);
    session = createMockSession(mockManager);

    // Default successful responses
    mockPage.screenshot.mockResolvedValue(Buffer.from('fake-image-data'));
    mockPage.pdf.mockResolvedValue(Buffer.from('fake-pdf-data'));
    mockPage.waitForLoadState.mockResolvedValue(undefined);
    mockPage.waitForTimeout.mockResolvedValue(undefined);
    mockManager.getSnapshot.mockResolvedValue({ tree: 'test-tree', refs: {} });
    mockManager.getRefMap.mockReturnValue({ e1: 'selector1', e2: 'selector2' });
  });

  describe('screenshot', () => {
    it('should take screenshot successfully', async () => {
      const result = await handler.screenshot(session);

      expect(result.success).toBe(true);
      expect(result.data?.screenshot).toBe(Buffer.from('fake-image-data').toString('base64'));
      expect(result.data?.format).toBe('png');
      expect(result.data?.width).toBe(1280);
      expect(result.data?.height).toBe(800);
    });

    it('should always use viewport-only (fullPage: false)', async () => {
      await handler.screenshot(session);

      expect(mockPage.screenshot).toHaveBeenCalledWith({
        type: 'png',
        fullPage: false,
      });
    });

    it('should return error when screenshot fails', async () => {
      mockPage.screenshot.mockRejectedValue(new Error('Screenshot timeout'));

      const result = await handler.screenshot(session);

      expect(result.success).toBe(false);
      expect(result.error).toBe('Screenshot timeout');
    });

    it('should handle non-Error exceptions', async () => {
      mockPage.screenshot.mockRejectedValue('String error');

      const result = await handler.screenshot(session);

      expect(result.success).toBe(false);
      expect(result.error).toBe('Screenshot failed');
    });
  });

  describe('snapshot', () => {
    it('should get accessibility snapshot successfully', async () => {
      const result = await handler.snapshot(session);

      expect(result.success).toBe(true);
      expect(result.data?.snapshot).toEqual({ tree: 'test-tree', refs: {} });
      expect(result.data?.elementRefs).toEqual([
        { ref: 'e1', selector: 'e1' },
        { ref: 'e2', selector: 'e2' },
      ]);
    });

    it('should wait for page to be ready', async () => {
      await handler.snapshot(session);

      expect(mockPage.waitForLoadState).toHaveBeenCalledWith('domcontentloaded', { timeout: 5000 });
      expect(mockPage.waitForTimeout).toHaveBeenCalledWith(100);
    });

    it('should call manager.getSnapshot with correct options', async () => {
      await handler.snapshot(session);

      expect(mockManager.getSnapshot).toHaveBeenCalledWith({
        interactive: false,
        compact: true,
      });
    });

    it('should update session elementRefs', async () => {
      await handler.snapshot(session);

      expect(session.elementRefs.has('e1')).toBe(true);
      expect(session.elementRefs.has('e2')).toBe(true);
    });

    it('should update session lastSnapshot', async () => {
      await handler.snapshot(session);

      expect(session.lastSnapshot).toEqual({ tree: 'test-tree', refs: {} });
    });

    it('should return error when snapshot fails', async () => {
      mockManager.getSnapshot.mockRejectedValue(new Error('Snapshot failed'));

      const result = await handler.snapshot(session);

      expect(result.success).toBe(false);
      expect(result.error).toBe('Snapshot failed');
    });

    it('should handle waitForLoadState timeout gracefully', async () => {
      mockPage.waitForLoadState.mockRejectedValue(new Error('Timeout'));

      const result = await handler.snapshot(session);

      // Should still succeed - waitForLoadState errors are caught
      expect(result.success).toBe(true);
    });
  });

  describe('pdf', () => {
    it('should generate PDF with path', async () => {
      const result = await handler.pdf(session, { path: '/tmp/output.pdf' });

      expect(result.success).toBe(true);
      expect(result.data?.path).toBe('/tmp/output.pdf');
      expect(mockPage.pdf).toHaveBeenCalledWith({ path: '/tmp/output.pdf' });
    });

    it('should generate PDF without path (return base64)', async () => {
      const result = await handler.pdf(session, {});

      expect(result.success).toBe(true);
      expect(result.data?.pdf).toBe(Buffer.from('fake-pdf-data').toString('base64'));
      expect(mockPage.pdf).toHaveBeenCalledWith();
    });

    it('should return error when PDF generation fails', async () => {
      mockPage.pdf.mockRejectedValue(new Error('PDF generation failed'));

      const result = await handler.pdf(session, {});

      expect(result.success).toBe(false);
      expect(result.error).toBe('PDF generation failed');
    });

    it('should handle non-Error exceptions', async () => {
      mockPage.pdf.mockRejectedValue('String error');

      const result = await handler.pdf(session, {});

      expect(result.success).toBe(false);
      expect(result.error).toBe('PDF generation failed');
    });
  });

  describe('factory function', () => {
    it('should create CaptureHandler instance', () => {
      const handler = createCaptureHandler(deps);
      expect(handler).toBeInstanceOf(CaptureHandler);
    });
  });
});
