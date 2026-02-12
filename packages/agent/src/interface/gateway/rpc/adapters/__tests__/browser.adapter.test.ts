/**
 * @fileoverview Tests for Browser Adapter
 *
 * The browser adapter delegates browser automation operations
 * to the EventStoreOrchestrator's BrowserService.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { createBrowserAdapter } from '../browser.adapter.js';
import type { EventStoreOrchestrator } from '../../../../orchestrator/persistence/event-store-orchestrator.js';

describe('BrowserAdapter', () => {
  let mockOrchestrator: Partial<EventStoreOrchestrator>;

  beforeEach(() => {
    mockOrchestrator = {
      browser: {
        startStream: vi.fn(),
        stopStream: vi.fn(),
        getStreamStatus: vi.fn(),
      },
    } as any;
  });

  describe('startStream', () => {
    it('should delegate to orchestrator.browser.startStream', async () => {
      const mockResult = { success: true, streamId: 'stream-123' };
      vi.mocked(mockOrchestrator.browser!.startStream).mockResolvedValue(mockResult as any);

      const adapter = createBrowserAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.startStream({ sessionId: 'sess-123' });

      expect(mockOrchestrator.browser!.startStream).toHaveBeenCalledWith('sess-123');
      expect(result).toEqual(mockResult);
    });
  });

  describe('stopStream', () => {
    it('should delegate to orchestrator.browser.stopStream', async () => {
      const mockResult = { success: true };
      vi.mocked(mockOrchestrator.browser!.stopStream).mockResolvedValue(mockResult);

      const adapter = createBrowserAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.stopStream({ sessionId: 'sess-123' });

      expect(mockOrchestrator.browser!.stopStream).toHaveBeenCalledWith('sess-123');
      expect(result).toEqual(mockResult);
    });
  });

  describe('getStatus', () => {
    it('should delegate to orchestrator.browser.getStreamStatus', async () => {
      const mockResult = {
        hasBrowser: true,
        isStreaming: true,
        currentUrl: 'https://example.com',
      };
      vi.mocked((mockOrchestrator.browser as any).getStreamStatus).mockReturnValue(mockResult);

      const adapter = createBrowserAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.getStatus({ sessionId: 'sess-123' });

      expect((mockOrchestrator.browser as any).getStreamStatus).toHaveBeenCalledWith('sess-123');
      expect(result).toEqual(mockResult);
    });
  });
});
