/**
 * @fileoverview Background hook execution tracker
 *
 * Tracks pending background hook executions and provides drain functionality.
 * Extracted from HookEngine to reduce god class responsibilities.
 */

import { createLogger } from '@infrastructure/logging/index.js';

const logger = createLogger('hooks:background-tracker');

/**
 * Tracks pending background hook executions
 */
export class BackgroundTracker {
  private pending = new Map<string, Promise<void>>();
  private counter = 0;

  /**
   * Track a background hook execution
   */
  track(executionId: string, promise: Promise<void>): void {
    this.pending.set(executionId, promise);
    promise.finally(() => this.pending.delete(executionId));
  }

  /**
   * Generate a unique execution ID
   */
  generateExecutionId(): string {
    return `bg_${++this.counter}_${Date.now()}`;
  }

  /**
   * Get the number of pending background hook executions
   */
  getPendingCount(): number {
    return this.pending.size;
  }

  /**
   * Wait for all pending background hooks to complete.
   * Call this before session end to ensure all hooks have finished.
   *
   * @param timeoutMs - Maximum time to wait
   */
  async waitForAll(timeoutMs: number): Promise<void> {
    const pending = Array.from(this.pending.values());
    if (pending.length === 0) {
      return;
    }

    logger.debug('Waiting for background hooks', { count: pending.length, timeoutMs });

    await Promise.race([
      Promise.allSettled(pending),
      new Promise<void>(resolve => setTimeout(resolve, timeoutMs)),
    ]);

    logger.debug('Background hooks drain complete', {
      remaining: this.pending.size,
    });
  }
}
