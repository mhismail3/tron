/**
 * @fileoverview OperationLogger - Multi-level operation logging with trace correlation
 *
 * Provides structured logging for operations with:
 * - Automatic traceId generation for correlation
 * - Parent/child relationship tracking for sub-agents
 * - Depth tracking for nested operations
 * - Elapsed time measurement
 * - Context propagation through AsyncLocalStorage
 */

import { randomUUID } from 'crypto';
import type { TronLogger } from './logger.js';
import { getLoggingContext, updateLoggingContext } from './log-context.js';

// =============================================================================
// Types
// =============================================================================

export interface OperationLoggerOptions {
  /** Additional context to include in all log calls */
  context?: Record<string, unknown>;
  /** Whether to automatically update AsyncLocalStorage context (default: true) */
  autoTrace?: boolean;
  /** Explicit parent trace ID (overrides context lookup) */
  parentTraceId?: string;
  /** Explicit depth (overrides context lookup) */
  depth?: number;
}

// =============================================================================
// OperationLogger
// =============================================================================

/**
 * Operation logger that provides structured, correlated logging for operations.
 *
 * @example
 * ```typescript
 * const op = createOperationLogger(logger, 'tool.execute', { toolName: 'Bash' });
 * op.trace('Starting execution');
 * op.debug('Intermediate value', { result: value });
 * op.complete('Execution finished', { exitCode: 0 });
 * ```
 */
export class OperationLogger {
  private logger: TronLogger;
  private operation: string;
  private context: Record<string, unknown>;
  private startTime: number;

  /** Unique trace ID for this operation */
  readonly traceId: string;
  /** Parent trace ID if this is a nested operation */
  readonly parentTraceId: string | null;
  /** Nesting depth (0 = root, 1 = first sub-agent, etc.) */
  readonly depth: number;

  constructor(logger: TronLogger, operation: string, options: OperationLoggerOptions = {}) {
    this.logger = logger;
    this.operation = operation;
    this.context = options.context ?? {};
    this.startTime = performance.now();
    this.traceId = randomUUID();

    // Determine parent trace ID from options or context
    const existingContext = getLoggingContext();
    this.parentTraceId = options.parentTraceId ?? existingContext.traceId ?? null;

    // Determine depth from options or context
    if (options.depth !== undefined) {
      this.depth = options.depth;
    } else if (this.parentTraceId) {
      this.depth = (existingContext.depth ?? 0) + 1;
    } else {
      this.depth = 0;
    }

    // Update AsyncLocalStorage context if autoTrace is enabled (default: true)
    if (options.autoTrace !== false) {
      updateLoggingContext({
        traceId: this.traceId,
        parentTraceId: this.parentTraceId,
        depth: this.depth,
      });
    }
  }

  /**
   * Get the base data object that's included in all log calls
   */
  private getBaseData(): Record<string, unknown> {
    return {
      operation: this.operation,
      traceId: this.traceId,
      ...(this.parentTraceId && { parentTraceId: this.parentTraceId }),
      ...(this.depth > 0 && { depth: this.depth }),
      ...this.context,
    };
  }

  /**
   * Merge base data with per-call data
   */
  private mergeData(data?: Record<string, unknown>): Record<string, unknown> {
    return {
      ...this.getBaseData(),
      ...data,
    };
  }

  /**
   * Log at trace level (entry/exit points, detailed flow)
   */
  trace(msg: string, data?: Record<string, unknown>): void {
    this.logger.trace(this.mergeData(data), msg);
  }

  /**
   * Log at debug level (intermediate values, decisions)
   */
  debug(msg: string, data?: Record<string, unknown>): void {
    this.logger.debug(this.mergeData(data), msg);
  }

  /**
   * Log at info level (outcomes, summaries)
   */
  info(msg: string, data?: Record<string, unknown>): void {
    this.logger.info(this.mergeData(data), msg);
  }

  /**
   * Log at warn level (non-fatal issues)
   */
  warn(msg: string, data?: Record<string, unknown>): void {
    this.logger.warn(this.mergeData(data), msg);
  }

  /**
   * Log at error level
   */
  error(msg: string, errorOrData?: Error | Record<string, unknown>): void {
    if (errorOrData instanceof Error) {
      this.logger.error(msg, {
        ...this.mergeData(),
        err: errorOrData,
      });
    } else {
      this.logger.error(this.mergeData(errorOrData), msg);
    }
  }

  /**
   * Get elapsed time since operation started (in milliseconds)
   */
  elapsed(): number {
    return performance.now() - this.startTime;
  }

  /**
   * Log operation completion with elapsed time
   */
  complete(msg: string, data?: Record<string, unknown>): void {
    const elapsedMs = this.elapsed();
    this.info(msg, {
      ...data,
      elapsedMs: Number(elapsedMs.toFixed(2)),
    });
  }

  /**
   * Create a child operation logger for nested operations (e.g., sub-agents)
   *
   * The child inherits the parent's context and links via parentTraceId.
   */
  child(operation: string, context?: Record<string, unknown>): OperationLogger {
    return new OperationLogger(this.logger, operation, {
      context: {
        ...this.context,
        ...context,
      },
      parentTraceId: this.traceId,
      depth: this.depth + 1,
    });
  }
}

// =============================================================================
// Factory Function
// =============================================================================

/**
 * Create an OperationLogger instance
 *
 * @example
 * ```typescript
 * const op = createOperationLogger(logger, 'worktree.create', {
 *   context: { worktreePath, branchName },
 * });
 *
 * op.trace('Starting worktree creation');
 * // ... do work
 * op.complete('Worktree created successfully');
 * ```
 */
export function createOperationLogger(
  logger: TronLogger,
  operation: string,
  options?: OperationLoggerOptions
): OperationLogger {
  return new OperationLogger(logger, operation, options);
}
