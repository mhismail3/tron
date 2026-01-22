/**
 * @fileoverview Transcribe RPC Handlers
 *
 * Handlers for transcribe.* RPC methods:
 * - transcribe.audio: Transcribe audio to text
 * - transcribe.listModels: List available transcription models
 */

import type {
  RpcRequest,
  RpcResponse,
  TranscribeAudioParams,
} from '../types.js';
import type { RpcContext } from '../handler.js';
import { MethodRegistry, type MethodRegistration, type MethodHandler } from '../registry.js';

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
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  const listModelsHandler: MethodHandler = async (request, context) => {
    const response = await handleTranscribeListModels(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
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
