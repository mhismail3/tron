/**
 * @fileoverview Logs RPC Handlers
 *
 * Handlers for logs.* RPC methods:
 * - logs.export: Receive logs from iOS client and save to $HOME/.tron/artifacts/ios-logs/
 */

import { homedir } from 'os';
import { join } from 'path';
import { mkdir, writeFile } from 'fs/promises';
import type { MethodRegistration, MethodHandler } from '../registry.js';
import { createLogger } from '@infrastructure/logging/index.js';

const logger = createLogger('rpc:logs');

// =============================================================================
// Types
// =============================================================================

interface LogsExportParams {
  content: string;
  filename?: string;
}

interface LogsExportResult {
  success: boolean;
  path: string;
  bytesWritten: number;
}

// =============================================================================
// Handler Factory
// =============================================================================

/**
 * Create logs handler registrations
 *
 * @returns Array of method registrations for bulk registration
 */
export function createLogsHandlers(): MethodRegistration[] {
  const exportHandler: MethodHandler<LogsExportParams, LogsExportResult> = async (request) => {
    const { content, filename } = request.params ?? {};

    if (!content) {
      throw new Error('content is required');
    }

    // Create directory path: $HOME/.tron/artifacts/ios-logs/
    const artifactsDir = join(homedir(), '.tron', 'artifacts', 'ios-logs');

    // Ensure directory exists
    await mkdir(artifactsDir, { recursive: true });

    // Generate filename if not provided
    const now = new Date();
    const dateStr = now.toISOString().replace(/[:.]/g, '-').slice(0, 19);
    const finalFilename = filename || `logs_${dateStr}.txt`;
    const filePath = join(artifactsDir, finalFilename);

    // Write file
    await writeFile(filePath, content, 'utf-8');
    const bytesWritten = Buffer.byteLength(content, 'utf-8');

    logger.info('iOS logs exported', {
      path: filePath,
      bytesWritten,
      lines: content.split('\n').length,
    });

    return {
      success: true,
      path: filePath,
      bytesWritten,
    };
  };

  return [
    {
      method: 'logs.export',
      handler: exportHandler,
      options: {
        requiredParams: ['content'],
        description: 'Export iOS logs to server filesystem',
      },
    },
  ];
}
