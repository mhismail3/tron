/**
 * @fileoverview Tests for SessionStart built-in hook
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { createSessionStartHook } from '../../../src/hooks/builtin/session-start.js';
import type { SessionStartHookContext } from '../../../src/hooks/types.js';
import type { LedgerManager, Ledger } from '../../../src/memory/ledger-manager.js';
import type { HandoffManager, Handoff } from '../../../src/memory/handoff-manager.js';

describe('SessionStart Hook', () => {
  // Mock ledger manager
  const createMockLedgerManager = (ledger: Partial<Ledger> = {}): LedgerManager => ({
    load: vi.fn().mockResolvedValue({
      goal: '',
      constraints: [],
      done: [],
      now: '',
      next: [],
      decisions: [],
      workingFiles: [],
      ...ledger,
    }),
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
    clear: vi.fn().mockResolvedValue(undefined),
    formatForContext: vi.fn().mockResolvedValue(''),
  } as unknown as LedgerManager);

  // Mock handoff manager
  const createMockHandoffManager = (handoffs: Partial<Handoff>[] = []): HandoffManager => ({
    initialize: vi.fn().mockResolvedValue(undefined),
    getRecent: vi.fn().mockResolvedValue(
      handoffs.map(h => ({
        id: 'handoff-1',
        sessionId: 'session-1',
        timestamp: new Date(),
        summary: '',
        codeChanges: [],
        currentState: '',
        blockers: [],
        nextSteps: [],
        patterns: [],
        ...h,
      }))
    ),
    get: vi.fn().mockResolvedValue(null),
    create: vi.fn().mockResolvedValue('handoff-1'),
    close: vi.fn().mockResolvedValue(undefined),
  } as unknown as HandoffManager);

  const createContext = (overrides: Partial<SessionStartHookContext> = {}): SessionStartHookContext => ({
    hookType: 'SessionStart',
    sessionId: 'test-session',
    timestamp: new Date().toISOString(),
    workingDirectory: '/test/project',
    data: {},
    ...overrides,
  });

  describe('creation', () => {
    it('should create hook with correct properties', () => {
      const ledgerManager = createMockLedgerManager();
      const hook = createSessionStartHook({ ledgerManager });

      expect(hook.name).toBe('builtin:session-start');
      expect(hook.type).toBe('SessionStart');
      expect(hook.priority).toBe(100);
      expect(typeof hook.handler).toBe('function');
    });
  });

  describe('ledger loading', () => {
    it('should load ledger and return context when goal is set', async () => {
      const ledgerManager = createMockLedgerManager({
        goal: 'Build feature X',
        now: 'Implementing component A',
        next: ['Add tests', 'Update docs'],
      });

      const hook = createSessionStartHook({ ledgerManager });
      const context = createContext();
      const result = await hook.handler(context);

      expect(ledgerManager.load).toHaveBeenCalled();
      expect(result.action).toBe('modify');
      expect(result.message).toContain('Build feature X');
      expect(result.message).toContain('Implementing component A');
      expect(result.message).toContain('Add tests');
    });

    it('should return continue when ledger is empty', async () => {
      const ledgerManager = createMockLedgerManager();
      const hook = createSessionStartHook({ ledgerManager });
      const context = createContext();
      const result = await hook.handler(context);

      expect(result.action).toBe('continue');
      expect(result.message).toBeUndefined();
    });

    it('should include working files when enabled', async () => {
      const ledgerManager = createMockLedgerManager({
        goal: 'Test',
        workingFiles: ['src/index.ts', 'src/utils.ts'],
      });

      const hook = createSessionStartHook({
        ledgerManager,
        includeWorkingFiles: true,
      });
      const context = createContext();
      const result = await hook.handler(context);

      expect(result.message).toContain('src/index.ts');
      expect(result.message).toContain('src/utils.ts');
    });

    it('should handle ledger load errors gracefully', async () => {
      const ledgerManager = createMockLedgerManager();
      (ledgerManager.load as any).mockRejectedValue(new Error('Read error'));

      const hook = createSessionStartHook({ ledgerManager });
      const context = createContext();
      const result = await hook.handler(context);

      // Should not throw, return continue
      expect(result.action).toBe('continue');
    });
  });

  describe('handoff loading', () => {
    it('should load recent handoffs when manager provided', async () => {
      const ledgerManager = createMockLedgerManager();
      const handoffManager = createMockHandoffManager([
        {
          sessionId: 's1',
          summary: 'Previous session work',
          nextSteps: ['Continue feature'],
          patterns: ['TDD approach'],
        },
      ]);

      const hook = createSessionStartHook({
        ledgerManager,
        handoffManager,
      });
      const context = createContext();
      const result = await hook.handler(context);

      expect(handoffManager.getRecent).toHaveBeenCalledWith(3);
      expect(result.message).toContain('Previous Session Summaries');
      expect(result.message).toContain('Previous session work');
    });

    it('should respect handoff limit', async () => {
      const ledgerManager = createMockLedgerManager();
      const handoffManager = createMockHandoffManager([]);

      const hook = createSessionStartHook({
        ledgerManager,
        handoffManager,
        handoffLimit: 5,
      });
      const context = createContext();
      await hook.handler(context);

      expect(handoffManager.getRecent).toHaveBeenCalledWith(5);
    });

    it('should load parent handoff when specified', async () => {
      const ledgerManager = createMockLedgerManager();
      const handoffManager = createMockHandoffManager();
      (handoffManager.get as any).mockResolvedValue({
        id: 'parent-handoff',
        sessionId: 'parent-session',
        timestamp: new Date(),
        summary: 'Parent session',
        codeChanges: [],
        currentState: 'OAuth implemented',
        blockers: ['Need API key'],
        nextSteps: ['Test refresh flow'],
        patterns: [],
      });

      const hook = createSessionStartHook({
        ledgerManager,
        handoffManager,
      });
      const context = createContext({ parentHandoffId: 'parent-handoff' });
      const result = await hook.handler(context);

      expect(handoffManager.get).toHaveBeenCalledWith('parent-handoff');
      expect(result.message).toContain('Continuing from Previous Session');
      expect(result.message).toContain('OAuth implemented');
      expect(result.message).toContain('Need API key');
    });
  });

  describe('context result', () => {
    it('should include ledger context in result', async () => {
      const ledgerManager = createMockLedgerManager({
        goal: 'Build X',
        now: 'Testing',
        next: ['Deploy'],
        workingFiles: ['main.ts'],
      });

      const hook = createSessionStartHook({ ledgerManager });
      const context = createContext();
      const result = await hook.handler(context) as any;

      expect(result.context?.ledger).toBeDefined();
      expect(result.context.ledger.goal).toBe('Build X');
      expect(result.context.ledger.now).toBe('Testing');
    });

    it('should include handoff context in result', async () => {
      const ledgerManager = createMockLedgerManager();
      const handoffManager = createMockHandoffManager([
        { sessionId: 's1', summary: 'Work done' },
      ]);

      const hook = createSessionStartHook({
        ledgerManager,
        handoffManager,
      });
      const context = createContext();
      const result = await hook.handler(context) as any;

      expect(result.context?.recentHandoffs).toBeDefined();
      expect(result.context.recentHandoffs).toHaveLength(1);
      expect(result.context.recentHandoffs[0].sessionId).toBe('s1');
    });
  });
});
