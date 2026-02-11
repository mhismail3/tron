/**
 * @fileoverview Tests for LedgerWriter
 *
 * Tests the memory ledger writer that uses a Haiku subagent
 * to create structured summaries of response cycles.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';

vi.mock('@infrastructure/logging/index.js', () => ({
  createLogger: vi.fn().mockReturnValue({
    info: vi.fn(),
    debug: vi.fn(),
    trace: vi.fn(),
    warn: vi.fn(),
    error: vi.fn(),
  }),
}));

import { LedgerWriter, type LedgerWriterDeps } from '../ledger-writer.js';
import type { SessionEvent } from '@infrastructure/events/types/index.js';

// =============================================================================
// Helpers
// =============================================================================

function createMockEvent(overrides: Partial<SessionEvent> = {}): SessionEvent {
  return {
    id: 'evt-1' as any,
    parentId: null,
    sessionId: 'sess-1' as any,
    workspaceId: 'ws-1' as any,
    timestamp: '2026-02-06T00:00:00.000Z',
    type: 'message.user',
    sequence: 1,
    payload: { content: 'Hello' },
    ...overrides,
  } as SessionEvent;
}

function createDeps(overrides: Partial<LedgerWriterDeps> = {}): LedgerWriterDeps {
  return {
    spawnSubsession: vi.fn().mockResolvedValue({
      sessionId: 'sub-1',
      success: true,
      output: JSON.stringify({
        title: 'Implemented feature X',
        entryType: 'feature',
        status: 'completed',
        tags: ['typescript'],
        input: 'User asked for feature X',
        actions: ['Created module', 'Added tests'],
        files: [{ path: 'src/foo.ts', op: 'C', why: 'New module' }],
        decisions: [{ choice: 'Used factory pattern', reason: 'Consistency' }],
        lessons: ['Factory pattern works well here'],
        thinkingInsights: ['Considered builder pattern but factory was simpler'],
      }),
    }),
    appendEvent: vi.fn().mockResolvedValue({ id: 'evt-ledger-1' }),
    getEventsBySession: vi.fn().mockResolvedValue([
      createMockEvent({ id: 'evt-1' as any, type: 'message.user', sequence: 1, payload: { content: 'Add feature X' } }),
      createMockEvent({ id: 'evt-2' as any, type: 'stream.turn_start', sequence: 2, payload: { turn: 1 } }),
      createMockEvent({ id: 'evt-3' as any, type: 'tool.call', sequence: 3, payload: { name: 'Write', arguments: { file_path: 'src/foo.ts' } } }),
      createMockEvent({ id: 'evt-4' as any, type: 'tool.result', sequence: 4, payload: { content: 'File written' } }),
      createMockEvent({ id: 'evt-5' as any, type: 'message.assistant', sequence: 5, payload: { content: [{ type: 'text', text: 'Done!' }] } }),
    ]),
    sessionId: 'sess-1',
    workspaceId: 'ws-1',
    ...overrides,
  };
}

// =============================================================================
// Tests
// =============================================================================

describe('LedgerWriter', () => {
  let deps: LedgerWriterDeps;

  beforeEach(() => {
    deps = createDeps();
  });

  describe('writeLedgerEntry', () => {
    it('should write a ledger entry when Haiku returns structured JSON', async () => {
      const writer = new LedgerWriter(deps);
      const result = await writer.writeLedgerEntry({
        model: 'claude-sonnet-4-5-20250929',
        workingDirectory: '/project',
      });

      expect(result.written).toBe(true);
      expect(deps.appendEvent).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'memory.ledger',
          payload: expect.objectContaining({
            title: 'Implemented feature X',
            entryType: 'feature',
            status: 'completed',
            model: 'claude-sonnet-4-5-20250929',
            workingDirectory: '/project',
          }),
        })
      );
    });

    it('should skip when Haiku returns skip response', async () => {
      deps.spawnSubsession = vi.fn().mockResolvedValue({
        sessionId: 'sub-1',
        success: true,
        output: JSON.stringify({ skip: true }),
      });

      const writer = new LedgerWriter(deps);
      const result = await writer.writeLedgerEntry({
        model: 'claude-sonnet-4-5-20250929',
        workingDirectory: '/project',
      });

      expect(result.written).toBe(false);
      expect(result.reason).toBe('skipped');
      expect(deps.appendEvent).not.toHaveBeenCalled();
    });

    it('should handle subagent spawn failure gracefully', async () => {
      deps.spawnSubsession = vi.fn().mockRejectedValue(new Error('Spawn failed'));

      const writer = new LedgerWriter(deps);
      const result = await writer.writeLedgerEntry({
        model: 'claude-sonnet-4-5-20250929',
        workingDirectory: '/project',
      });

      expect(result.written).toBe(false);
      expect(result.reason).toContain('Spawn failed');
      expect(deps.appendEvent).not.toHaveBeenCalled();
    });

    it('should handle subagent returning non-JSON gracefully', async () => {
      deps.spawnSubsession = vi.fn().mockResolvedValue({
        sessionId: 'sub-1',
        success: true,
        output: 'This is not valid JSON at all',
      });

      const writer = new LedgerWriter(deps);
      const result = await writer.writeLedgerEntry({
        model: 'claude-sonnet-4-5-20250929',
        workingDirectory: '/project',
      });

      expect(result.written).toBe(false);
      expect(result.reason).toContain('parse');
    });

    it('should handle subagent returning unsuccessful result', async () => {
      deps.spawnSubsession = vi.fn().mockResolvedValue({
        sessionId: 'sub-1',
        success: false,
        error: 'Rate limited',
      });

      const writer = new LedgerWriter(deps);
      const result = await writer.writeLedgerEntry({
        model: 'claude-sonnet-4-5-20250929',
        workingDirectory: '/project',
      });

      expect(result.written).toBe(false);
      expect(result.reason).toContain('Rate limited');
    });

    it('should extract relevant events for the subagent prompt', async () => {
      const writer = new LedgerWriter(deps);
      await writer.writeLedgerEntry({
        model: 'claude-sonnet-4-5-20250929',
        workingDirectory: '/project',
      });

      // Verify spawnSubsession was called with a task that includes event context
      expect(deps.spawnSubsession).toHaveBeenCalledWith(
        expect.objectContaining({
          task: expect.stringContaining('[USER]'),
          model: 'claude-haiku-4-5-20251001',
          toolDenials: { denyAll: true },
          blocking: true,
        })
      );
    });

    it('should include thinking blocks in event extraction', async () => {
      deps.getEventsBySession = vi.fn().mockResolvedValue([
        createMockEvent({ type: 'message.user', sequence: 1, payload: { content: 'Do X' } }),
        createMockEvent({
          type: 'message.assistant',
          sequence: 2,
          payload: {
            content: [
              { type: 'thinking', thinking: 'I should consider approach A vs B...' },
              { type: 'text', text: 'I will use approach A' },
            ],
          },
        }),
      ]);

      const writer = new LedgerWriter(deps);
      await writer.writeLedgerEntry({
        model: 'claude-sonnet-4-5-20250929',
        workingDirectory: '/project',
      });

      const call = (deps.spawnSubsession as any).mock.calls[0][0];
      expect(call.task).toContain('approach A vs B');
    });

    it('should derive event range and turn range from persisted events', async () => {
      // Set up events with stream.turn_start events for turn tracking
      deps.getEventsBySession = vi.fn().mockResolvedValue([
        createMockEvent({ id: 'evt-10' as any, type: 'message.user', sequence: 1, payload: { content: 'Do X' } }),
        createMockEvent({ id: 'evt-11' as any, type: 'stream.turn_start', sequence: 2, payload: { turn: 3 } }),
        createMockEvent({ id: 'evt-12' as any, type: 'message.assistant', sequence: 3, payload: { content: [{ type: 'text', text: 'Turn 3' }] } }),
        createMockEvent({ id: 'evt-13' as any, type: 'stream.turn_start', sequence: 4, payload: { turn: 5 } }),
        createMockEvent({ id: 'evt-20' as any, type: 'message.assistant', sequence: 5, payload: { content: [{ type: 'text', text: 'Turn 5' }] } }),
      ]);

      const writer = new LedgerWriter(deps);
      await writer.writeLedgerEntry({
        model: 'claude-sonnet-4-5-20250929',
        workingDirectory: '/project',
      });

      expect(deps.appendEvent).toHaveBeenCalledWith(
        expect.objectContaining({
          payload: expect.objectContaining({
            eventRange: { firstEventId: 'evt-10', lastEventId: 'evt-20' },
            turnRange: { firstTurn: 3, lastTurn: 5 },
          }),
        })
      );
    });

    it('should only include events after last memory.ledger boundary', async () => {
      deps.getEventsBySession = vi.fn().mockResolvedValue([
        createMockEvent({ id: 'evt-old' as any, type: 'message.user', sequence: 1, payload: { content: 'Old' } }),
        createMockEvent({ id: 'evt-boundary' as any, type: 'memory.ledger', sequence: 2, payload: {} }),
        createMockEvent({ id: 'evt-new-1' as any, type: 'message.user', sequence: 3, payload: { content: 'New' } }),
        createMockEvent({ id: 'evt-new-2' as any, type: 'stream.turn_start', sequence: 4, payload: { turn: 2 } }),
        createMockEvent({ id: 'evt-new-3' as any, type: 'message.assistant', sequence: 5, payload: { content: [{ type: 'text', text: 'Response' }] } }),
      ]);

      const writer = new LedgerWriter(deps);
      await writer.writeLedgerEntry({
        model: 'claude-sonnet-4-5-20250929',
        workingDirectory: '/project',
      });

      expect(deps.appendEvent).toHaveBeenCalledWith(
        expect.objectContaining({
          payload: expect.objectContaining({
            eventRange: { firstEventId: 'evt-new-1', lastEventId: 'evt-new-3' },
            turnRange: { firstTurn: 2, lastTurn: 2 },
          }),
        })
      );
    });

    it('should include events across compact.boundary (compaction is not a cycle boundary)', async () => {
      // compact.boundary can appear mid-cycle when compaction runs in the same Stop hook.
      // It should NOT split the cycle — only memory.ledger marks cycle boundaries.
      deps.getEventsBySession = vi.fn().mockResolvedValue([
        createMockEvent({ id: 'evt-1' as any, type: 'message.user', sequence: 1, payload: { content: 'Do X' } }),
        createMockEvent({ id: 'evt-2' as any, type: 'stream.turn_start', sequence: 2, payload: { turn: 1 } }),
        createMockEvent({ id: 'evt-3' as any, type: 'message.assistant', sequence: 3, payload: { content: [{ type: 'text', text: 'Done' }] } }),
        createMockEvent({ id: 'evt-4' as any, type: 'compact.boundary', sequence: 4, payload: { range: { from: 'x', to: 'y' }, originalTokens: 1000, compactedTokens: 500 } }),
        createMockEvent({ id: 'evt-5' as any, type: 'compact.summary', sequence: 5, payload: { summary: 'Summarized' } }),
      ]);

      const writer = new LedgerWriter(deps);
      await writer.writeLedgerEntry({
        model: 'claude-sonnet-4-5-20250929',
        workingDirectory: '/project',
      });

      // All events should be in the range, including compact events
      expect(deps.appendEvent).toHaveBeenCalledWith(
        expect.objectContaining({
          payload: expect.objectContaining({
            eventRange: { firstEventId: 'evt-1', lastEventId: 'evt-5' },
            turnRange: { firstTurn: 1, lastTurn: 1 },
          }),
        })
      );
    });

    it('should parse JSON wrapped in code fences with trailing content', async () => {
      deps.spawnSubsession = vi.fn().mockResolvedValue({
        sessionId: 'sub-1',
        success: true,
        output: '```json\n{"title":"Test","entryType":"research","status":"completed","tags":[],"input":"q","actions":["a"],"files":[],"decisions":[],"lessons":[],"thinkingInsights":[]}\n```\n\n🫎',
        tokenUsage: { inputTokens: 100, outputTokens: 50 },
      });

      const writer = new LedgerWriter(deps);
      const result = await writer.writeLedgerEntry({
        model: 'claude-sonnet-4-5-20250929',
        workingDirectory: '/project',
      });

      expect(result.written).toBe(true);
      expect(result.title).toBe('Test');
      expect(result.entryType).toBe('research');
    });

    it('should parse JSON wrapped in code fences without language tag', async () => {
      deps.spawnSubsession = vi.fn().mockResolvedValue({
        sessionId: 'sub-1',
        success: true,
        output: '```\n{"title":"Test","entryType":"feature","status":"completed"}\n```',
      });

      const writer = new LedgerWriter(deps);
      const result = await writer.writeLedgerEntry({
        model: 'claude-sonnet-4-5-20250929',
        workingDirectory: '/project',
      });

      expect(result.written).toBe(true);
      expect(result.title).toBe('Test');
    });

    it('should handle empty output from subagent', async () => {
      deps.spawnSubsession = vi.fn().mockResolvedValue({
        sessionId: 'sub-1',
        success: true,
        output: undefined,
      });

      const writer = new LedgerWriter(deps);
      const result = await writer.writeLedgerEntry({
        model: 'claude-sonnet-4-5-20250929',
        workingDirectory: '/project',
      });

      expect(result.written).toBe(false);
      expect(result.reason).toContain('empty');
    });
  });
});
