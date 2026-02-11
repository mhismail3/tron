/**
 * @fileoverview Tests for MemoryManager
 *
 * Tests the coordinator that ties together ledger writing
 * and smart compaction triggering.
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

import { MemoryManager, type MemoryManagerDeps, type CycleInfo } from '../memory-manager.js';

// =============================================================================
// Helpers
// =============================================================================

function createDeps(overrides: Partial<MemoryManagerDeps> = {}): MemoryManagerDeps {
  return {
    writeLedgerEntry: vi.fn().mockResolvedValue({ written: true }),
    shouldCompact: vi.fn().mockReturnValue({ compact: false, reason: 'no trigger' }),
    resetCompactionTrigger: vi.fn(),
    executeCompaction: vi.fn().mockResolvedValue({ success: true }),
    emitMemoryUpdated: vi.fn(),
    isLedgerEnabled: vi.fn().mockReturnValue(true),
    sessionId: 'sess-1',
    ...overrides,
  };
}

function createCycleInfo(overrides: Partial<CycleInfo> = {}): CycleInfo {
  return {
    model: 'claude-sonnet-4-5-20250929',
    workingDirectory: '/project',
    currentTokenRatio: 0.30,
    recentEventTypes: [],
    recentToolCalls: [],
    ...overrides,
  };
}

// =============================================================================
// Tests
// =============================================================================

describe('MemoryManager', () => {
  let deps: MemoryManagerDeps;

  beforeEach(() => {
    deps = createDeps();
  });

  describe('onCycleComplete', () => {
    it('should write ledger entry on cycle complete', async () => {
      const manager = new MemoryManager(deps);
      await manager.onCycleComplete(createCycleInfo());

      expect(deps.writeLedgerEntry).toHaveBeenCalledWith({
        model: 'claude-sonnet-4-5-20250929',
        workingDirectory: '/project',
      });
    });

    it('should check compaction trigger', async () => {
      const manager = new MemoryManager(deps);
      const info = createCycleInfo({ currentTokenRatio: 0.55 });
      await manager.onCycleComplete(info);

      expect(deps.shouldCompact).toHaveBeenCalledWith({
        currentTokenRatio: 0.55,
        recentEventTypes: [],
        recentToolCalls: [],
      });
    });

    it('should execute compaction when triggered', async () => {
      deps.shouldCompact = vi.fn().mockReturnValue({ compact: true, reason: 'commit' });

      const manager = new MemoryManager(deps);
      await manager.onCycleComplete(createCycleInfo());

      expect(deps.executeCompaction).toHaveBeenCalled();
      expect(deps.resetCompactionTrigger).toHaveBeenCalled();
    });

    it('should not execute compaction when not triggered', async () => {
      const manager = new MemoryManager(deps);
      await manager.onCycleComplete(createCycleInfo());

      expect(deps.executeCompaction).not.toHaveBeenCalled();
    });

    it('should emit memory updated event when ledger written', async () => {
      const manager = new MemoryManager(deps);
      await manager.onCycleComplete(createCycleInfo());

      expect(deps.emitMemoryUpdated).toHaveBeenCalled();
    });

    it('should not emit memory updated when ledger skipped', async () => {
      deps.writeLedgerEntry = vi.fn().mockResolvedValue({ written: false, reason: 'skipped' });

      const manager = new MemoryManager(deps);
      await manager.onCycleComplete(createCycleInfo());

      expect(deps.emitMemoryUpdated).not.toHaveBeenCalled();
    });

    it('should still write ledger even if compaction fails', async () => {
      deps.shouldCompact = vi.fn().mockReturnValue({ compact: true, reason: 'commit' });
      deps.executeCompaction = vi.fn().mockRejectedValue(new Error('Compaction failed'));

      const manager = new MemoryManager(deps);
      await manager.onCycleComplete(createCycleInfo());

      // Ledger still attempted despite compaction failure
      expect(deps.writeLedgerEntry).toHaveBeenCalled();
    });

    it('should still check compaction even if ledger write fails', async () => {
      deps.writeLedgerEntry = vi.fn().mockRejectedValue(new Error('Ledger failed'));
      deps.shouldCompact = vi.fn().mockReturnValue({ compact: true, reason: 'turns' });

      const manager = new MemoryManager(deps);
      await manager.onCycleComplete(createCycleInfo());

      expect(deps.shouldCompact).toHaveBeenCalled();
      expect(deps.executeCompaction).toHaveBeenCalled();
    });

    it('should run compaction before ledger (sequential for deterministic DB ordering)', async () => {
      const order: string[] = [];

      deps.shouldCompact = vi.fn().mockReturnValue({ compact: true, reason: 'commit' });
      deps.executeCompaction = vi.fn().mockImplementation(async () => {
        order.push('compaction-start');
        await new Promise(r => setTimeout(r, 10));
        order.push('compaction-end');
        return { success: true };
      });
      deps.writeLedgerEntry = vi.fn().mockImplementation(async () => {
        order.push('ledger-start');
        await new Promise(r => setTimeout(r, 10));
        order.push('ledger-end');
        return { written: true };
      });

      const manager = new MemoryManager(deps);
      await manager.onCycleComplete(createCycleInfo());

      // Compaction must fully complete before ledger starts
      expect(order).toEqual([
        'compaction-start',
        'compaction-end',
        'ledger-start',
        'ledger-end',
      ]);
    });
  });

  describe('embedMemory', () => {
    it('should call embedMemory after successful ledger write', async () => {
      const embedMemory = vi.fn().mockResolvedValue(undefined);
      deps = createDeps({
        writeLedgerEntry: vi.fn().mockResolvedValue({
          written: true,
          eventId: 'evt-ledger-1',
          payload: { title: 'Test', lessons: ['lesson1'] },
        }),
        embedMemory,
        workspaceId: 'ws-1',
      });

      const manager = new MemoryManager(deps);
      await manager.onCycleComplete(createCycleInfo());

      expect(embedMemory).toHaveBeenCalledWith(
        'evt-ledger-1',
        'ws-1',
        { title: 'Test', lessons: ['lesson1'] }
      );
    });

    it('should not call embedMemory when ledger write is skipped', async () => {
      const embedMemory = vi.fn().mockResolvedValue(undefined);
      deps = createDeps({
        writeLedgerEntry: vi.fn().mockResolvedValue({ written: false, reason: 'skipped' }),
        embedMemory,
        workspaceId: 'ws-1',
      });

      const manager = new MemoryManager(deps);
      await manager.onCycleComplete(createCycleInfo());

      expect(embedMemory).not.toHaveBeenCalled();
    });

    it('should not call embedMemory when eventId is missing from result', async () => {
      const embedMemory = vi.fn().mockResolvedValue(undefined);
      deps = createDeps({
        writeLedgerEntry: vi.fn().mockResolvedValue({ written: true }),
        embedMemory,
        workspaceId: 'ws-1',
      });

      const manager = new MemoryManager(deps);
      await manager.onCycleComplete(createCycleInfo());

      expect(embedMemory).not.toHaveBeenCalled();
    });

    it('should not block ledger completion if embedMemory fails', async () => {
      const embedMemory = vi.fn().mockRejectedValue(new Error('Embedding failed'));
      deps = createDeps({
        writeLedgerEntry: vi.fn().mockResolvedValue({
          written: true,
          eventId: 'evt-ledger-1',
          payload: { title: 'Test' },
        }),
        embedMemory,
        workspaceId: 'ws-1',
      });

      const manager = new MemoryManager(deps);
      // Should not throw despite embedding failure
      await manager.onCycleComplete(createCycleInfo());

      expect(embedMemory).toHaveBeenCalled();
      expect(deps.emitMemoryUpdated).toHaveBeenCalled();
    });

    it('should use empty string for workspaceId when not provided', async () => {
      const embedMemory = vi.fn().mockResolvedValue(undefined);
      deps = createDeps({
        writeLedgerEntry: vi.fn().mockResolvedValue({
          written: true,
          eventId: 'evt-ledger-1',
          payload: { title: 'Test' },
        }),
        embedMemory,
        // No workspaceId
      });

      const manager = new MemoryManager(deps);
      await manager.onCycleComplete(createCycleInfo());

      expect(embedMemory).toHaveBeenCalledWith('evt-ledger-1', '', { title: 'Test' });
    });

    it('should work when embedMemory callback is not provided', async () => {
      deps = createDeps({
        writeLedgerEntry: vi.fn().mockResolvedValue({
          written: true,
          eventId: 'evt-ledger-1',
          payload: { title: 'Test' },
        }),
        // No embedMemory callback
      });

      const manager = new MemoryManager(deps);
      // Should complete without error
      await manager.onCycleComplete(createCycleInfo());

      expect(deps.emitMemoryUpdated).toHaveBeenCalled();
    });
  });

  describe('isLedgerEnabled', () => {
    it('should skip ledger write when disabled', async () => {
      deps = createDeps({
        isLedgerEnabled: vi.fn().mockReturnValue(false),
      });

      const manager = new MemoryManager(deps);
      await manager.onCycleComplete(createCycleInfo());

      expect(deps.writeLedgerEntry).not.toHaveBeenCalled();
      expect(deps.emitMemoryUpdated).not.toHaveBeenCalled();
    });

    it('should still run compaction when ledger is disabled', async () => {
      deps = createDeps({
        isLedgerEnabled: vi.fn().mockReturnValue(false),
        shouldCompact: vi.fn().mockReturnValue({ compact: true, reason: 'turns' }),
      });

      const manager = new MemoryManager(deps);
      await manager.onCycleComplete(createCycleInfo());

      expect(deps.executeCompaction).toHaveBeenCalled();
      expect(deps.resetCompactionTrigger).toHaveBeenCalled();
      expect(deps.writeLedgerEntry).not.toHaveBeenCalled();
    });

    it('should write ledger when enabled', async () => {
      deps = createDeps({
        isLedgerEnabled: vi.fn().mockReturnValue(true),
      });

      const manager = new MemoryManager(deps);
      await manager.onCycleComplete(createCycleInfo());

      expect(deps.writeLedgerEntry).toHaveBeenCalled();
    });
  });
});
