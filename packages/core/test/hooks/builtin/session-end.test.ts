/**
 * @fileoverview Tests for SessionEnd built-in hook
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  createSessionEndHook,
  type SessionEndContext,
} from '../../../src/hooks/builtin/session-end.js';
import type { LedgerManager, Ledger } from '../../../src/memory/ledger-manager.js';
import type { HandoffManager } from '../../../src/memory/handoff-manager.js';

describe('SessionEnd Hook', () => {
  // Mock ledger manager
  const createMockLedgerManager = (ledger: Partial<Ledger> = {}): LedgerManager => ({
    get: vi.fn().mockResolvedValue({
      goal: '',
      constraints: [],
      done: [],
      now: '',
      next: [],
      decisions: [],
      workingFiles: [],
      ...ledger,
    }),
    clear: vi.fn().mockResolvedValue(undefined),
    load: vi.fn().mockResolvedValue(undefined),
    save: vi.fn().mockResolvedValue(undefined),
    update: vi.fn().mockResolvedValue(undefined),
    initialize: vi.fn().mockResolvedValue(undefined),
    getPath: vi.fn().mockReturnValue('/test/ledger.md'),
    setGoal: vi.fn().mockResolvedValue(undefined),
    setNow: vi.fn().mockResolvedValue(undefined),
    addDone: vi.fn().mockResolvedValue(undefined),
    addNext: vi.fn().mockResolvedValue(undefined),
    popNext: vi.fn().mockResolvedValue({ item: null, ledger: {} }),
    completeNow: vi.fn().mockResolvedValue(undefined),
    addDecision: vi.fn().mockResolvedValue(undefined),
    addWorkingFile: vi.fn().mockResolvedValue(undefined),
    removeWorkingFile: vi.fn().mockResolvedValue(undefined),
    addConstraint: vi.fn().mockResolvedValue(undefined),
    formatForContext: vi.fn().mockResolvedValue(''),
  } as unknown as LedgerManager);

  // Mock handoff manager
  const createMockHandoffManager = (): HandoffManager => ({
    initialize: vi.fn().mockResolvedValue(undefined),
    create: vi.fn().mockResolvedValue('handoff-123'),
    get: vi.fn().mockResolvedValue(null),
    getRecent: vi.fn().mockResolvedValue([]),
    close: vi.fn().mockResolvedValue(undefined),
  } as unknown as HandoffManager);

  const createContext = (overrides: Partial<SessionEndContext> = {}): SessionEndContext => ({
    hookType: 'SessionEnd',
    sessionId: 'test-session',
    timestamp: new Date().toISOString(),
    messageCount: 10,
    toolCallCount: 5,
    data: {},
    ...overrides,
  });

  describe('creation', () => {
    it('should create hook with correct properties', () => {
      const handoffManager = createMockHandoffManager();
      const hook = createSessionEndHook({ handoffManager });

      expect(hook.name).toBe('builtin:session-end');
      expect(hook.type).toBe('SessionEnd');
      expect(hook.priority).toBe(100);
    });
  });

  describe('handoff creation', () => {
    it('should create handoff for session with enough messages', async () => {
      const handoffManager = createMockHandoffManager();
      const hook = createSessionEndHook({ handoffManager });
      const context = createContext({ messageCount: 5 });

      const result = await hook.handler(context);

      expect(handoffManager.create).toHaveBeenCalled();
      expect(result.action).toBe('continue');
      expect(result.message).toContain('handoff-123');
    });

    it('should skip handoff for very short sessions', async () => {
      const handoffManager = createMockHandoffManager();
      const hook = createSessionEndHook({
        handoffManager,
        minMessagesForHandoff: 5,
      });
      const context = createContext({ messageCount: 2 });

      const result = await hook.handler(context);

      expect(handoffManager.create).not.toHaveBeenCalled();
      expect(result.action).toBe('continue');
    });

    it('should respect custom minMessagesForHandoff', async () => {
      const handoffManager = createMockHandoffManager();
      const hook = createSessionEndHook({
        handoffManager,
        minMessagesForHandoff: 10,
      });
      const context = createContext({ messageCount: 8 });

      const result = await hook.handler(context);

      expect(handoffManager.create).not.toHaveBeenCalled();
    });

    it('should include ledger state in handoff', async () => {
      const handoffManager = createMockHandoffManager();
      const ledgerManager = createMockLedgerManager({
        goal: 'Build feature',
        now: 'Testing',
        done: ['Setup', 'Implementation'],
        next: ['Deploy'],
        decisions: [{ choice: 'Use TypeScript', reason: 'Type safety' }],
      });

      const hook = createSessionEndHook({ handoffManager, ledgerManager });
      const context = createContext();

      await hook.handler(context);

      const createCall = (handoffManager.create as any).mock.calls[0][0];
      expect(createCall.summary).toContain('Build feature');
      expect(createCall.nextSteps).toContain('Deploy');
      expect(createCall.patterns).toHaveLength(1);
    });

    it('should include file modifications in handoff', async () => {
      const handoffManager = createMockHandoffManager();
      const hook = createSessionEndHook({ handoffManager });
      const context = createContext({
        filesModified: [
          { path: 'src/index.ts', operation: 'modify' },
          { path: 'src/new.ts', operation: 'create' },
        ],
      });

      await hook.handler(context);

      const createCall = (handoffManager.create as any).mock.calls[0][0];
      expect(createCall.codeChanges).toHaveLength(2);
      expect(createCall.codeChanges[0].file).toBe('src/index.ts');
    });

    it('should handle error outcome', async () => {
      const handoffManager = createMockHandoffManager();
      const hook = createSessionEndHook({ handoffManager });
      const context = createContext({
        outcome: 'error',
        error: 'Network timeout',
      });

      await hook.handler(context);

      const createCall = (handoffManager.create as any).mock.calls[0][0];
      expect(createCall.currentState).toContain('error');
      expect(createCall.blockers).toContain('Error encountered: Network timeout');
    });
  });

  describe('ledger clearing', () => {
    it('should not clear ledger by default', async () => {
      const handoffManager = createMockHandoffManager();
      const ledgerManager = createMockLedgerManager();
      const hook = createSessionEndHook({
        handoffManager,
        ledgerManager,
      });
      const context = createContext();

      await hook.handler(context);

      expect(ledgerManager.clear).not.toHaveBeenCalled();
    });

    it('should clear ledger when configured', async () => {
      const handoffManager = createMockHandoffManager();
      const ledgerManager = createMockLedgerManager({ goal: 'Test' });
      const hook = createSessionEndHook({
        handoffManager,
        ledgerManager,
        clearLedgerOnEnd: true,
      });
      const context = createContext();

      await hook.handler(context);

      expect(ledgerManager.clear).toHaveBeenCalledWith(true);
    });
  });

  describe('error handling', () => {
    it('should continue on handoff creation failure', async () => {
      const handoffManager = createMockHandoffManager();
      (handoffManager.create as any).mockRejectedValue(new Error('DB error'));

      const hook = createSessionEndHook({ handoffManager });
      const context = createContext();

      const result = await hook.handler(context);

      // Should not throw, return continue
      expect(result.action).toBe('continue');
      expect(result.reason).toContain('Handoff creation failed');
    });
  });

  describe('custom summary generator', () => {
    it('should use custom summary generator when provided', async () => {
      const handoffManager = createMockHandoffManager();
      const customSummary = vi.fn().mockResolvedValue('Custom summary text');

      const hook = createSessionEndHook({
        handoffManager,
        summaryGenerator: customSummary,
      });
      const context = createContext();

      await hook.handler(context);

      expect(customSummary).toHaveBeenCalledWith(context);
      const createCall = (handoffManager.create as any).mock.calls[0][0];
      expect(createCall.summary).toBe('Custom summary text');
    });
  });
});
