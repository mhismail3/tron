/**
 * @fileoverview Transcribe domain - Audio transcription
 *
 * Handles audio transcription and model listing.
 *
 * @migration Re-exports from rpc/handlers during transition
 */

// Re-export handlers
export {
  handleTranscribeAudio,
  handleTranscribeListModels,
  createTranscribeHandlers,
} from '../../../../rpc/handlers/transcribe.handler.js';

// Re-export types
export type {
  TranscribeAudioParams,
  TranscribeAudioResult,
  TranscribeListModelsParams,
  TranscribeListModelsResult,
} from '../../../../rpc/types/transcription.js';
