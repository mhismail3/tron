/**
 * @fileoverview Transcribe domain - Audio transcription
 *
 * Handles audio transcription and model listing.
 */

// Re-export handler factory
export { createTranscribeHandlers } from '@interface/rpc/handlers/transcribe.handler.js';

// Re-export types
export type {
  TranscribeAudioParams,
  TranscribeAudioResult,
  TranscribeListModelsParams,
  TranscribeListModelsResult,
} from '@interface/rpc/types/transcription.js';
