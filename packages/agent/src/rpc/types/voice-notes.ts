/**
 * @fileoverview Voice Notes RPC Types
 *
 * Types for voice notes methods.
 */

// =============================================================================
// Voice Notes Methods
// =============================================================================

/** Save a voice note with transcription */
export interface VoiceNotesSaveParams {
  /** Base64-encoded audio bytes */
  audioBase64: string;
  /** MIME type for the audio (e.g., audio/m4a) */
  mimeType?: string;
  /** Original filename (optional) */
  fileName?: string;
  /** Preferred transcription model ID */
  transcriptionModelId?: string;
}

export interface VoiceNotesSaveResult {
  success: boolean;
  /** Generated filename */
  filename: string;
  /** Full path to saved file */
  filepath: string;
  /** Transcription details */
  transcription: {
    text: string;
    language: string;
    durationSeconds: number;
  };
}

/** List saved voice notes */
export interface VoiceNotesListParams {
  /** Maximum number of notes to return */
  limit?: number;
  /** Offset for pagination */
  offset?: number;
}

export interface VoiceNoteMetadata {
  /** Filename (e.g., "2025-01-09-143022-voice-note.md") */
  filename: string;
  /** Full path to file */
  filepath: string;
  /** ISO timestamp when created */
  createdAt: string;
  /** Duration in seconds */
  durationSeconds?: number;
  /** Detected language */
  language?: string;
  /** First line or summary of transcription (truncated to 100 chars) */
  preview: string;
  /** Full transcription text */
  transcript: string;
}

export interface VoiceNotesListResult {
  notes: VoiceNoteMetadata[];
  totalCount: number;
  hasMore: boolean;
}

/** Delete a voice note file */
export interface VoiceNotesDeleteParams {
  /** Filename of the note to delete (e.g., "voice-note-2024-01-15-143022.md") */
  filename: string;
}

export interface VoiceNotesDeleteResult {
  /** Whether the deletion was successful */
  success: boolean;
  /** The filename that was deleted */
  filename: string;
}
