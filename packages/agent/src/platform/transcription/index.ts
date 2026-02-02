/**
 * @fileoverview Transcription Module Exports
 *
 * Provides transcription functionality via local sidecar process.
 */

// Client API
export { transcribeAudio, listTranscriptionModels, getDefaultTranscriptionSettings } from './client.js';

// Sidecar management
export { ensureTranscriptionSidecar, stopTranscriptionSidecar } from './sidecar.js';
