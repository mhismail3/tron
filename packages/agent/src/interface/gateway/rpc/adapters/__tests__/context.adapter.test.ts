/**
 * @fileoverview Tests for Context Adapter
 *
 * The context adapter handles context management operations including
 * snapshots, compaction, and context clearing.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { createContextAdapter } from '../context.adapter.js';
import type { EventStoreOrchestrator } from '../../../../orchestrator/persistence/event-store-orchestrator.js';

describe('ContextAdapter', () => {
  let mockOrchestrator: Partial<EventStoreOrchestrator>;

  beforeEach(() => {
    mockOrchestrator = {
      context: {
        getContextSnapshot: vi.fn(),
        getDetailedContextSnapshot: vi.fn(),
        shouldCompact: vi.fn(),
        previewCompaction: vi.fn(),
        confirmCompaction: vi.fn(),
        canAcceptTurn: vi.fn(),
        clearContext: vi.fn(),
      },
      getActiveSession: vi.fn(),
    } as any;
  });

  describe('getContextSnapshot', () => {
    it('should return context snapshot from orchestrator', () => {
      const mockSnapshot = {
        currentTokens: 50000,
        contextLimit: 200000,
        usagePercent: 25,
        thresholdLevel: 'normal' as const,
        breakdown: {
          systemPrompt: 5000,
          tools: 10000,
          rules: 2000,
          messages: 33000,
        },
      };
      vi.mocked((mockOrchestrator as any).context.getContextSnapshot).mockReturnValue(mockSnapshot);

      const adapter = createContextAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = adapter.getContextSnapshot('sess-123');

      expect((mockOrchestrator as any).context.getContextSnapshot).toHaveBeenCalledWith('sess-123');
      expect(result).toEqual(mockSnapshot);
    });
  });

  describe('getDetailedContextSnapshot', () => {
    it('should pass through detailed snapshot from context-ops', () => {
      const mockSnapshot = {
        currentTokens: 50000,
        contextLimit: 200000,
        usagePercent: 25,
        thresholdLevel: 'normal' as const,
        breakdown: {
          systemPrompt: 5000,
          tools: 10000,
          rules: 2000,
          messages: 33000,
        },
        messages: [
          { index: 0, role: 'user', tokens: 100, summary: 'Hello', content: 'Hello' },
        ],
        addedSkills: [
          { name: 'test-skill', source: 'project', addedVia: 'explicit', eventId: 'evt-1', tokens: 150 },
        ],
        rules: {
          files: [{ path: '/path/to/CLAUDE.md', relativePath: 'CLAUDE.md', level: 'project', depth: 0 }],
          totalFiles: 1,
          tokens: 500,
        },
      };
      vi.mocked((mockOrchestrator as any).context.getDetailedContextSnapshot).mockReturnValue(mockSnapshot);

      const adapter = createContextAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = adapter.getDetailedContextSnapshot('sess-123');

      expect((mockOrchestrator as any).context.getDetailedContextSnapshot).toHaveBeenCalledWith('sess-123');
      expect(result).toBe(mockSnapshot);
    });
  });

  describe('shouldCompact', () => {
    it('should return true when context is high', () => {
      vi.mocked((mockOrchestrator as any).context.shouldCompact).mockReturnValue(true);

      const adapter = createContextAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = adapter.shouldCompact('sess-123');

      expect((mockOrchestrator as any).context.shouldCompact).toHaveBeenCalledWith('sess-123');
      expect(result).toBe(true);
    });

    it('should return false when context is low', () => {
      vi.mocked((mockOrchestrator as any).context.shouldCompact).mockReturnValue(false);

      const adapter = createContextAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = adapter.shouldCompact('sess-123');

      expect(result).toBe(false);
    });
  });

  describe('previewCompaction', () => {
    it('should return compaction preview', async () => {
      const mockPreview = {
        summary: 'This is a summary of the conversation...',
        tokensBefore: 150000,
        tokensAfter: 50000,
        messagesRemoved: 45,
        messagesKept: 5,
      };
      vi.mocked((mockOrchestrator as any).context.previewCompaction).mockResolvedValue(mockPreview);

      const adapter = createContextAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.previewCompaction('sess-123');

      expect((mockOrchestrator as any).context.previewCompaction).toHaveBeenCalledWith('sess-123');
      expect(result).toEqual(mockPreview);
    });
  });

  describe('confirmCompaction', () => {
    it('should execute compaction with default summary', async () => {
      const mockResult = {
        success: true,
        tokensBefore: 150000,
        tokensAfter: 50000,
      };
      vi.mocked((mockOrchestrator as any).context.confirmCompaction).mockResolvedValue(mockResult);

      const adapter = createContextAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.confirmCompaction('sess-123');

      expect((mockOrchestrator as any).context.confirmCompaction).toHaveBeenCalledWith('sess-123', undefined);
      expect(result).toEqual(mockResult);
    });

    it('should pass edited summary to orchestrator', async () => {
      const mockResult = { success: true, tokensBefore: 150000, tokensAfter: 50000 };
      vi.mocked((mockOrchestrator as any).context.confirmCompaction).mockResolvedValue(mockResult);

      const adapter = createContextAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      await adapter.confirmCompaction('sess-123', { editedSummary: 'Custom summary' });

      expect((mockOrchestrator as any).context.confirmCompaction).toHaveBeenCalledWith(
        'sess-123',
        { editedSummary: 'Custom summary' }
      );
    });
  });

  describe('canAcceptTurn', () => {
    it('should return validation result', () => {
      const mockResult = {
        canProceed: true,
        needsCompaction: false,
        estimatedTokens: 55000,
        contextLimit: 200000,
      };
      vi.mocked((mockOrchestrator as any).context.canAcceptTurn).mockReturnValue(mockResult);

      const adapter = createContextAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = adapter.canAcceptTurn('sess-123', { estimatedResponseTokens: 5000 });

      expect((mockOrchestrator as any).context.canAcceptTurn).toHaveBeenCalledWith(
        'sess-123',
        { estimatedResponseTokens: 5000 }
      );
      expect(result).toEqual(mockResult);
    });

    it('should return canProceed false when context would exceed limit', () => {
      const mockResult = {
        canProceed: false,
        needsCompaction: true,
        estimatedTokens: 250000,
        contextLimit: 200000,
      };
      vi.mocked((mockOrchestrator as any).context.canAcceptTurn).mockReturnValue(mockResult);

      const adapter = createContextAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = adapter.canAcceptTurn('sess-123', { estimatedResponseTokens: 50000 });

      expect(result.canProceed).toBe(false);
      expect(result.needsCompaction).toBe(true);
    });
  });

  describe('clearContext', () => {
    it('should clear context and return token counts', async () => {
      const mockResult = {
        success: true,
        tokensBefore: 150000,
        tokensAfter: 5000,
      };
      vi.mocked((mockOrchestrator as any).context.clearContext).mockResolvedValue(mockResult);

      const adapter = createContextAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.clearContext('sess-123');

      expect((mockOrchestrator as any).context.clearContext).toHaveBeenCalledWith('sess-123');
      expect(result).toEqual(mockResult);
    });
  });
});
