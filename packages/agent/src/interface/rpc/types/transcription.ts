/**
 * @fileoverview Transcription RPC Types
 *
 * Types for transcription methods.
 */

// =============================================================================
// Transcription Methods
// =============================================================================

export interface TranscribeAudioParams {
  /** Optional session ID for attribution */
  sessionId?: string;
  /** Base64-encoded audio bytes */
  audioBase64: string;
  /** MIME type for the audio (e.g., audio/m4a) */
  mimeType?: string;
  /** Original filename (optional) */
  fileName?: string;
  /** Preferred transcription model ID (server-defined) */
  transcriptionModelId?: string;
  /** Client-selected transcription quality profile */
  transcriptionQuality?: 'faster' | 'better';
  /** Cleanup mode override */
  cleanupMode?: 'none' | 'basic' | 'llm';
  /** Language hint (optional, e.g., "en") */
  language?: string;
  /** Initial prompt for transcription (optional) */
  prompt?: string;
  /** Task type (transcribe/translate) */
  task?: 'transcribe' | 'translate';
}

export interface TranscribeAudioResult {
  text: string;
  rawText: string;
  language: string;
  durationSeconds: number;
  processingTimeMs: number;
  model: string;
  device: string;
  computeType: string;
  cleanupMode: string;
}

export interface TranscriptionModelInfo {
  id: string;
  label: string;
  description?: string;
}

export interface TranscribeListModelsParams {}

export interface TranscribeListModelsResult {
  models: TranscriptionModelInfo[];
  defaultModelId?: string;
}
