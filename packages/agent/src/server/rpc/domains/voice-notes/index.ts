/**
 * @fileoverview Voice Notes domain - Voice note management
 *
 * Handles voice note saving, listing, and deletion.
 *
 * @migration Re-exports from rpc/handlers during transition
 */

// Re-export handlers
export {
  handleVoiceNotesSave,
  handleVoiceNotesList,
  handleVoiceNotesDelete,
  createVoiceNotesHandlers,
} from '../../../../rpc/handlers/voiceNotes.handler.js';

// Re-export types
export type {
  VoiceNotesSaveParams,
  VoiceNotesSaveResult,
  VoiceNotesListParams,
  VoiceNotesListResult,
  VoiceNotesDeleteParams,
  VoiceNotesDeleteResult,
} from '../../../../rpc/types/voice-notes.js';
