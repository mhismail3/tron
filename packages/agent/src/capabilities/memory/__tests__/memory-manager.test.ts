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
    sessionId: 'sess-1',
    ...overrides,
  };
}

function createCycleInfo(overrides: Partial<CycleInfo> = {}): CycleInfo {
  return {
    firstEventId: 'evt-1',
    lastEventId: 'evt-4',
    firstTurn: 1,
    lastTurn: 1,
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
        firstEventId: 'evt-1',
        lastEventId: 'evt-4',
        firstTurn: 1,
        lastTurn: 1,
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
  });
});
