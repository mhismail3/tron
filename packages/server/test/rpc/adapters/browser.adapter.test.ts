/**
 * @fileoverview Tests for Browser Adapter
 *
 * The browser adapter delegates browser automation operations
 * to the EventStoreOrchestrator.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { createBrowserAdapter } from '../../../src/rpc/adapters/browser.adapter.js';
import type { EventStoreOrchestrator } from '../../../src/event-store-orchestrator.js';

describe('BrowserAdapter', () => {
  let mockOrchestrator: Partial<EventStoreOrchestrator>;

  beforeEach(() => {
    mockOrchestrator = {
      startBrowserStream: vi.fn(),
      stopBrowserStream: vi.fn(),
      getBrowserStatus: vi.fn(),
    };
  });

  describe('startStream', () => {
    it('should delegate to orchestrator.startBrowserStream', async () => {
      const mockResult = { success: true, streamId: 'stream-123' };
      vi.mocked(mockOrchestrator.startBrowserStream!).mockResolvedValue(mockResult);

      const adapter = createBrowserAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.startStream({ sessionId: 'sess-123' });

      expect(mockOrchestrator.startBrowserStream).toHaveBeenCalledWith('sess-123');
      expect(result).toEqual(mockResult);
    });
  });

  describe('stopStream', () => {
    it('should delegate to orchestrator.stopBrowserStream', async () => {
      const mockResult = { success: true };
      vi.mocked(mockOrchestrator.stopBrowserStream!).mockResolvedValue(mockResult);

      const adapter = createBrowserAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.stopStream({ sessionId: 'sess-123' });

      expect(mockOrchestrator.stopBrowserStream).toHaveBeenCalledWith('sess-123');
      expect(result).toEqual(mockResult);
    });
  });

  describe('getStatus', () => {
    it('should delegate to orchestrator.getBrowserStatus', async () => {
      const mockResult = {
        isStreaming: true,
        streamId: 'stream-123',
        frameCount: 42,
      };
      vi.mocked(mockOrchestrator.getBrowserStatus!).mockResolvedValue(mockResult);

      const adapter = createBrowserAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.getStatus({ sessionId: 'sess-123' });

      expect(mockOrchestrator.getBrowserStatus).toHaveBeenCalledWith('sess-123');
      expect(result).toEqual(mockResult);
    });
  });
});
