/**
 * @fileoverview Transcribe RPC Handlers
 *
 * Handlers for transcribe.* RPC methods:
 * - transcribe.audio: Transcribe audio to text
 * - transcribe.listModels: List available transcription models
 */

import { createLogger, categorizeError, LogErrorCategory } from '@infrastructure/logging/index.js';
import { RpcHandlerError } from '@core/utils/index.js';
import type {
  RpcRequest,
  RpcResponse,
  TranscribeAudioParams,
} from '../types.js';
import type { RpcContext } from '../context-types.js';
import { MethodRegistry, type MethodRegistration, type MethodHandler } from '../registry.js';

const logger = createLogger('rpc:transcribe');

// =============================================================================
// Handler Implementations
// =============================================================================

/**
 * Handle transcribe.audio request
 *
 * Transcribes audio data to text using the configured transcription service.
 */
export async function handleTranscribeAudio(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  const params = request.params as TranscribeAudioParams | undefined;

  if (!params?.audioBase64) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'audioBase64 is required');
  }

  if (!context.transcriptionManager) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'Transcription is not available');
  }

  try {
    const result = await context.transcriptionManager.transcribeAudio(params);
    return MethodRegistry.successResponse(request.id, result);
  } catch (error) {
    const structured = categorizeError(error, { operation: 'transcribeAudio' });
    logger.error('Failed to transcribe audio', {
      code: structured.code,
      category: LogErrorCategory.PROVIDER_API,
      error: structured.message,
      retryable: structured.retryable,
    });
    const message = error instanceof Error ? error.message : 'Transcription failed';
    return MethodRegistry.errorResponse(request.id, 'TRANSCRIPTION_FAILED', message);
  }
}

/**
 * Handle transcribe.listModels request
 *
 * Returns a list of available transcription models.
 */
export async function handleTranscribeListModels(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.transcriptionManager) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'Transcription is not available');
  }

  try {
    const result = await context.transcriptionManager.listModels();
    return MethodRegistry.successResponse(request.id, result);
  } catch (error) {
    const structured = categorizeError(error, { operation: 'listModels' });
    logger.error('Failed to list transcription models', {
      code: structured.code,
      category: LogErrorCategory.PROVIDER_API,
      error: structured.message,
      retryable: structured.retryable,
    });
    const message = error instanceof Error ? error.message : 'Failed to list transcription models';
    return MethodRegistry.errorResponse(request.id, 'TRANSCRIPTION_FAILED', message);
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
  const audioHandler: MethodHandler = async (request, context) => {
    const response = await handleTranscribeAudio(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    throw RpcHandlerError.fromResponse(response);
  };

  const listModelsHandler: MethodHandler = async (request, context) => {
    const response = await handleTranscribeListModels(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    throw RpcHandlerError.fromResponse(response);
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
