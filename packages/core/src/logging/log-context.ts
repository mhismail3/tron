/**
 * @fileoverview Logging Context - AsyncLocalStorage for automatic context propagation
 *
 * Provides transparent propagation of session, workspace, event, and turn context
 * through async call chains without threading it through every function.
 */

import { AsyncLocalStorage } from 'async_hooks';

// =============================================================================
// Types
// =============================================================================

export interface LoggingContext {
  sessionId?: string;
  workspaceId?: string;
  eventId?: string;
  turn?: number;
  traceId?: string;
}

// =============================================================================
// AsyncLocalStorage Instance
// =============================================================================

const loggingContext = new AsyncLocalStorage<LoggingContext>();

// =============================================================================
// Public API
// =============================================================================

/**
 * Run a function with the specified logging context.
 * All logs within the function (including async operations) will inherit this context.
 *
 * @example
 * withLoggingContext({ sessionId: 'sess_123' }, () => {
 *   logger.info('This log will have sessionId attached');
 * });
 */
export function withLoggingContext<T>(context: LoggingContext, fn: () => T): T {
  // Merge with parent context if exists
  const parentContext = loggingContext.getStore() ?? {};
  const mergedContext = { ...parentContext, ...context };
  return loggingContext.run(mergedContext, fn);
}

/**
 * Get the current logging context.
 * Returns an empty object if called outside of a withLoggingContext block.
 */
export function getLoggingContext(): LoggingContext {
  return loggingContext.getStore() ?? {};
}

/**
 * Update the current logging context in place.
 * Only works inside a withLoggingContext block.
 * Use this to update context (e.g., eventId) without starting a new block.
 *
 * Note: This modifies the context object in place, which is generally safe
 * for single-threaded async operations but should be used carefully.
 */
export function updateLoggingContext(updates: Partial<LoggingContext>): void {
  const store = loggingContext.getStore();
  if (store) {
    Object.assign(store, updates);
  }
}

/**
 * Set the logging context directly (for testing).
 * In production, prefer withLoggingContext for proper scoping.
 */
export function setLoggingContext(context: LoggingContext): void {
  // This is a hack for testing - runs the context indefinitely
  loggingContext.enterWith(context);
}

/**
 * Clear the logging context (for testing).
 */
export function clearLoggingContext(): void {
  loggingContext.disable();
  // Re-enable for future use
  // Note: AsyncLocalStorage doesn't have an enable method, it auto-enables on next enterWith/run
}
