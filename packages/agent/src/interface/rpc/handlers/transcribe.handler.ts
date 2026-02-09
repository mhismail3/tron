/**
 * @fileoverview Transcribe RPC Handlers
 *
 * Handlers for transcribe.* RPC methods:
 * - transcribe.audio: Transcribe audio to text
 * - transcribe.listModels: List available transcription models
 *
 * Validation is handled by the registry via requiredParams/requiredManagers options.
 */

import { createLogger, categorizeError, LogErrorCategory } from '@infrastructure/logging/index.js';
import type { TranscribeAudioParams } from '../types.js';
import type { MethodRegistration, MethodHandler } from '../registry.js';
import { RpcError, RpcErrorCode } from './base.js';

const logger = createLogger('rpc:transcribe');

/**
 * Wrap transcription operations with consistent error handling
 */
async function withTranscriptionErrorHandling<T>(
  operation: string,
  fn: () => Promise<T>
): Promise<T> {
  try {
    return await fn();
  } catch (error) {
    const structured = categorizeError(error, { operation });
    logger.error(`Failed to ${operation}`, {
      code: structured.code,
      category: LogErrorCategory.PROVIDER_API,
      error: structured.message,
      retryable: structured.retryable,
    });
    const message = error instanceof Error ? error.message : `${operation} failed`;
    throw new RpcError(RpcErrorCode.TRANSCRIPTION_ERROR, message);
  }
}

// =============================================================================
// Handler Factory
// =============================================================================

/**
 * Create transcribe handler registrations
 *
 * @returns Array of method registrations for bulk registration
 */
export function createTranscribeHandlers(): MethodRegistration[] {
  const audioHandler: MethodHandler<TranscribeAudioParams> = async (request, context) => {
    const params = request.params!;
    return withTranscriptionErrorHandling('transcribe audio', () =>
      context.transcriptionManager!.transcribeAudio(params)
    );
  };

  const listModelsHandler: MethodHandler = async (_request, context) => {
    return withTranscriptionErrorHandling('list transcription models', () =>
      context.transcriptionManager!.listModels()
    );
  };

  return [
    {
      method: 'transcribe.audio',
      handler: audioHandler,
      options: {
        requiredParams: ['audioBase64'],
        requiredManagers: ['transcriptionManager'],
        description: 'Transcribe audio to text',
      },
    },
    {
      method: 'transcribe.listModels',
      handler: listModelsHandler,
      options: {
        requiredManagers: ['transcriptionManager'],
        description: 'List available transcription models',
      },
    },
  ];
}
