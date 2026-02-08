/**
 * @fileoverview Memory Ledger Built-in Hook
 *
 * Background Stop hook that fires after each response cycle
 * to write a structured ledger entry via MemoryManager.
 */

import type {
  HookDefinition,
  StopHookContext,
  HookResult,
} from '../types.js';
import { createLogger } from '@infrastructure/logging/index.js';
import type { CycleInfo } from '@capabilities/memory/index.js';

const logger = createLogger('hooks:memory-ledger');

// =============================================================================
// Types
// =============================================================================

export interface MemoryLedgerHookConfig {
  onCycleComplete: (info: CycleInfo) => Promise<void>;
  getModel: () => string;
  getWorkingDirectory: () => string;
  getTokenRatio: () => number;
  getRecentEventTypes: () => Promise<string[]>;
  getRecentToolCalls: () => Promise<string[]>;
}

// =============================================================================
// Hook Creator
// =============================================================================

export function createMemoryLedgerHook(config: MemoryLedgerHookConfig): HookDefinition {
  return {
    name: 'builtin:memory-ledger',
    type: 'Stop',
    description: 'Writes structured memory ledger entries after response cycles',
    mode: 'background',
    priority: 10,

    handler: async (ctx): Promise<HookResult> => {
      const context = ctx as StopHookContext;

      // Skip blocked prompts — nothing meaningful happened
      if (context.stopReason === 'blocked') {
        return { action: 'continue' };
      }

      try {
        const [recentEventTypes, recentToolCalls] = await Promise.all([
          config.getRecentEventTypes(),
          config.getRecentToolCalls(),
        ]);
        const info: CycleInfo = {
          model: config.getModel(),
          workingDirectory: config.getWorkingDirectory(),
          currentTokenRatio: config.getTokenRatio(),
          recentEventTypes,
          recentToolCalls,
        };

        await config.onCycleComplete(info);
      } catch (error) {
        // Fail-open — never block the response
        logger.error('Memory ledger hook failed', {
          sessionId: context.sessionId,
          error: (error as Error).message,
        });
      }

      return { action: 'continue' };
    },
  };
}

export default createMemoryLedgerHook;
