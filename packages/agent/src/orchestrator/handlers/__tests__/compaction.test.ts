/**
 * @fileoverview CompactionHandler Unit Tests
 *
 * Tests for the CompactionHandler which builds compaction events.
 *
 * Contract:
 * 1. Build compact.boundary event with token stats
 * 2. Build compact.summary event with summary text
 * 3. Return structured events array for persistence
 */
import { describe, it, expect, beforeEach } from 'vitest';
import {
  CompactionHandler,
  createCompactionHandler,
  type CompactionContext,
} from '../compaction.js';

describe('CompactionHandler', () => {
  let handler: CompactionHandler;

  beforeEach(() => {
    handler = createCompactionHandler();
  });

  describe('buildCompactionEvents()', () => {
    it('should create boundary and summary events', () => {
      const context: CompactionContext = {
        sessionId: 'session_1',
        tokensBefore: 100000,
        tokensAfter: 20000,
        compressionRatio: 0.8,
        summary: 'The user asked to implement a feature...',
      };

      const events = handler.buildCompactionEvents(context);

      expect(events.length).toBe(2);
      expect(events[0].type).toBe('compact.boundary');
      expect(events[1].type).toBe('compact.summary');
    });

    it('should include token stats in boundary event', () => {
      const context: CompactionContext = {
        sessionId: 'session_1',
        tokensBefore: 150000,
        tokensAfter: 30000,
        compressionRatio: 0.8,
        summary: 'Summary text',
      };

      const events = handler.buildCompactionEvents(context);

      expect(events[0].payload).toMatchObject({
        originalTokens: 150000,
        compactedTokens: 30000,
        compressionRatio: 0.8,
      });
    });

    it('should include summary text in summary event', () => {
      const context: CompactionContext = {
        sessionId: 'session_1',
        tokensBefore: 100000,
        tokensAfter: 20000,
        compressionRatio: 0.8,
        summary: 'The conversation covered implementing a REST API...',
      };

      const events = handler.buildCompactionEvents(context);

      expect(events[1].payload).toMatchObject({
        summary: 'The conversation covered implementing a REST API...',
      });
    });

    it('should include key decisions if provided', () => {
      const context: CompactionContext = {
        sessionId: 'session_1',
        tokensBefore: 100000,
        tokensAfter: 20000,
        compressionRatio: 0.8,
        summary: 'Summary',
        keyDecisions: [
          'Use TypeScript for the project',
          'Implement REST API with Express',
        ],
      };

      const events = handler.buildCompactionEvents(context);

      expect(events[1].payload.keyDecisions).toEqual([
        'Use TypeScript for the project',
        'Implement REST API with Express',
      ]);
    });

    it('should include files modified if provided', () => {
      const context: CompactionContext = {
        sessionId: 'session_1',
        tokensBefore: 100000,
        tokensAfter: 20000,
        compressionRatio: 0.8,
        summary: 'Summary',
        filesModified: ['src/index.ts', 'src/api/routes.ts'],
      };

      const events = handler.buildCompactionEvents(context);

      expect(events[1].payload.filesModified).toEqual([
        'src/index.ts',
        'src/api/routes.ts',
      ]);
    });

    it('should handle empty summary', () => {
      const context: CompactionContext = {
        sessionId: 'session_1',
        tokensBefore: 100000,
        tokensAfter: 20000,
        compressionRatio: 0.8,
        summary: '',
      };

      const events = handler.buildCompactionEvents(context);

      expect(events[1].payload.summary).toBe('');
    });

    it('should handle zero compression ratio', () => {
      const context: CompactionContext = {
        sessionId: 'session_1',
        tokensBefore: 50000,
        tokensAfter: 50000,
        compressionRatio: 0,
        summary: 'No compression needed',
      };

      const events = handler.buildCompactionEvents(context);

      expect(events[0].payload.compressionRatio).toBe(0);
    });
  });

  describe('Edge cases', () => {
    it('should handle very large token counts', () => {
      const context: CompactionContext = {
        sessionId: 'session_1',
        tokensBefore: 1_000_000,
        tokensAfter: 100_000,
        compressionRatio: 0.9,
        summary: 'Large context compacted',
      };

      const events = handler.buildCompactionEvents(context);

      expect(events[0].payload.originalTokens).toBe(1_000_000);
      expect(events[0].payload.compactedTokens).toBe(100_000);
    });

    it('should handle undefined optional fields', () => {
      const context: CompactionContext = {
        sessionId: 'session_1',
        tokensBefore: 100000,
        tokensAfter: 20000,
        compressionRatio: 0.8,
        summary: 'Summary',
        // keyDecisions and filesModified not provided
      };

      const events = handler.buildCompactionEvents(context);

      // Should not throw, and optional fields should be undefined
      expect(events[1].payload.keyDecisions).toBeUndefined();
      expect(events[1].payload.filesModified).toBeUndefined();
    });

    it('should handle empty arrays for optional fields', () => {
      const context: CompactionContext = {
        sessionId: 'session_1',
        tokensBefore: 100000,
        tokensAfter: 20000,
        compressionRatio: 0.8,
        summary: 'Summary',
        keyDecisions: [],
        filesModified: [],
      };

      const events = handler.buildCompactionEvents(context);

      expect(events[1].payload.keyDecisions).toEqual([]);
      expect(events[1].payload.filesModified).toEqual([]);
    });
  });
});
