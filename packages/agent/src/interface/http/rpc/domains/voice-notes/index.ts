/**
 * @fileoverview Voice Notes domain - Voice note management
 *
 * Handles voice note saving, listing, and deletion.
 */

// Re-export handler factory
export { createVoiceNotesHandlers } from '@interface/rpc/handlers/voiceNotes.handler.js';

// Re-export types
export type {
  VoiceNotesSaveParams,
  VoiceNotesSaveResult,
  VoiceNotesListParams,
  VoiceNotesListResult,
  VoiceNotesDeleteParams,
  VoiceNotesDeleteResult,
} from '@interface/rpc/types/voice-notes.js';
