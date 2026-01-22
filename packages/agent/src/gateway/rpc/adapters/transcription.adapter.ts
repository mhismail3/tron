/**
 * @fileoverview Transcription Adapter
 *
 * Adapts transcription client functions to the TranscriptionManager interface
 * expected by RpcContext.
 *
 * This is a simple passthrough adapter since the transcription client
 * already matches the expected interface.
 */

import { transcribeAudio, listTranscriptionModels } from '../../../transcription/client.js';
import type { TranscriptionManagerAdapter } from '../types.js';

/**
 * Creates a TranscriptionManager adapter
 *
 * Note: This adapter doesn't need the orchestrator since transcription
 * is a stateless service that doesn't depend on session state.
 */
export function createTranscriptionAdapter(): TranscriptionManagerAdapter {
  return {
    async transcribeAudio(params) {
      return transcribeAudio(params);
    },
    async listModels() {
      return listTranscriptionModels();
    },
  };
}
