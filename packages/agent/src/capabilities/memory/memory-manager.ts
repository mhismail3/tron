/**
 * @fileoverview Memory Manager
 *
 * Coordinates ledger writing and smart compaction triggering
 * as a unified memory subsystem.
 */

import { createLogger } from '@infrastructure/logging/index.js';
import type { LedgerWriteOpts, LedgerWriteResult } from './ledger-writer.js';
import type { CompactionTriggerInput, CompactionTriggerResult } from './compaction-trigger.js';

const logger = createLogger('memory:manager');

// =============================================================================
// Types
// =============================================================================

export interface CycleInfo {
  firstEventId: string;
  lastEventId: string;
  firstTurn: number;
  lastTurn: number;
  model: string;
  workingDirectory: string;
  currentTokenRatio: number;
  recentEventTypes: string[];
  recentToolCalls: string[];
}

export interface MemoryManagerDeps {
  writeLedgerEntry: (opts: LedgerWriteOpts) => Promise<LedgerWriteResult>;
  shouldCompact: (input: CompactionTriggerInput) => CompactionTriggerResult;
  resetCompactionTrigger: () => void;
  executeCompaction: () => Promise<{ success: boolean }>;
  emitMemoryUpdated: (data: { sessionId: string; title?: string; entryType?: string }) => void;
  /** Fire-and-forget embedding callback. Called after successful ledger write. */
  embedMemory?: (eventId: string, workspaceId: string, payload: Record<string, unknown>) => Promise<void>;
  sessionId: string;
  workspaceId?: string;
}

// =============================================================================
// MemoryManager
// =============================================================================

export class MemoryManager {
  private deps: MemoryManagerDeps;

  constructor(deps: MemoryManagerDeps) {
    this.deps = deps;
  }

  async onCycleComplete(info: CycleInfo): Promise<void> {
    const compactionResult = this.deps.shouldCompact({
      currentTokenRatio: info.currentTokenRatio,
      recentEventTypes: info.recentEventTypes,
      recentToolCalls: info.recentToolCalls,
    });

    // Run compaction first, then ledger — sequential to guarantee deterministic
    // event ordering in the DB (compact.boundary always before memory.ledger).
    if (compactionResult.compact) {
      try {
        logger.info('Compaction triggered by memory manager', {
          reason: compactionResult.reason,
          sessionId: this.deps.sessionId,
        });
        await this.deps.executeCompaction();
        this.deps.resetCompactionTrigger();
      } catch (error) {
        logger.error('Memory-triggered compaction failed', {
          error: (error as Error).message,
          sessionId: this.deps.sessionId,
        });
      }
    }

    try {
      const ledgerResult = await this.deps.writeLedgerEntry({
        firstEventId: info.firstEventId,
        lastEventId: info.lastEventId,
        firstTurn: info.firstTurn,
        lastTurn: info.lastTurn,
        model: info.model,
        workingDirectory: info.workingDirectory,
      });

      if (ledgerResult.written) {
        this.deps.emitMemoryUpdated({
          sessionId: this.deps.sessionId,
          title: ledgerResult.title,
          entryType: ledgerResult.entryType,
        });

        // Fire-and-forget embedding for semantic search
        if (this.deps.embedMemory && ledgerResult.eventId && ledgerResult.payload) {
          this.deps.embedMemory(
            ledgerResult.eventId,
            this.deps.workspaceId ?? '',
            ledgerResult.payload
          ).catch(err => {
            logger.warn('Failed to embed memory', { error: (err as Error).message });
          });
        }
      }
    } catch (error) {
      logger.error('Ledger write failed', {
        error: (error as Error).message,
        sessionId: this.deps.sessionId,
      });
    }
  }
}

// =============================================================================
// Factory
// =============================================================================

export function createMemoryManager(deps: MemoryManagerDeps): MemoryManager {
  return new MemoryManager(deps);
}
