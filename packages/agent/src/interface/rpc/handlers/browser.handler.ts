/**
 * @fileoverview Browser RPC Handlers
 *
 * Handlers for browser.* RPC methods:
 * - browser.startStream: Start browser streaming for a session
 * - browser.stopStream: Stop browser streaming
 * - browser.getStatus: Get browser streaming status
 *
 * Validation is handled by the registry via requiredParams/requiredManagers options.
 */

import { createLogger, categorizeError, LogErrorCategory } from '@infrastructure/logging/index.js';
import type {
  BrowserStartStreamParams,
  BrowserStopStreamParams,
  BrowserGetStatusParams,
} from '../types.js';
import type { MethodRegistration, MethodHandler } from '../registry.js';
import { BrowserError } from './base.js';

const logger = createLogger('rpc:browser');

/**
 * Wrap browser operations with consistent error handling
 */
async function withBrowserErrorHandling<T>(
  sessionId: string,
  operation: string,
  fn: () => Promise<T>
): Promise<T> {
  try {
    return await fn();
  } catch (error) {
    const structured = categorizeError(error, { sessionId, operation });
    logger.error(`Failed to ${operation}`, {
      sessionId,
      code: structured.code,
      category: LogErrorCategory.TOOL_EXECUTION,
      error: structured.message,
      retryable: structured.retryable,
    });
    const message = error instanceof Error ? error.message : `Failed to ${operation}`;
    throw new BrowserError(message);
  }
}

// =============================================================================
// Handler Factory
// =============================================================================

/**
 * Create browser handler registrations
 *
 * @returns Array of method registrations for bulk registration
 */
export function createBrowserHandlers(): MethodRegistration[] {
  const startStreamHandler: MethodHandler<BrowserStartStreamParams> = async (request, context) => {
    const params = request.params!;
    return withBrowserErrorHandling(params.sessionId, 'start browser stream', () =>
      context.browserManager!.startStream(params)
    );
  };

  const stopStreamHandler: MethodHandler<BrowserStopStreamParams> = async (request, context) => {
    const params = request.params!;
    return withBrowserErrorHandling(params.sessionId, 'stop browser stream', () =>
      context.browserManager!.stopStream(params)
    );
  };

  const getStatusHandler: MethodHandler<BrowserGetStatusParams> = async (request, context) => {
    const params = request.params!;
    return withBrowserErrorHandling(params.sessionId, 'get browser status', () =>
      context.browserManager!.getStatus(params)
    );
  };

  return [
    {
      method: 'browser.startStream',
      handler: startStreamHandler,
      options: {
        requiredParams: ['sessionId'],
        requiredManagers: ['browserManager'],
        description: 'Start browser streaming for a session',
      },
    },
    {
      method: 'browser.stopStream',
      handler: stopStreamHandler,
      options: {
        requiredParams: ['sessionId'],
        requiredManagers: ['browserManager'],
        description: 'Stop browser streaming',
      },
    },
    {
      method: 'browser.getStatus',
      handler: getStatusHandler,
      options: {
        requiredParams: ['sessionId'],
        requiredManagers: ['browserManager'],
        description: 'Get browser streaming status',
      },
    },
  ];
}
