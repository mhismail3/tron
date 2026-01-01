/**
 * @fileoverview Productivity Module Exports
 *
 * Exports all productivity features:
 * - Transcript export
 * - Task tracking
 * - Inbox monitoring
 * - Notes integration
 */
export * from './export.js';
export * from './tasks.js';
export * from './inbox/index.js';
export {
  NotesManager,
  createNotesManager,
  type NotesManagerConfig,
  type Note,
  type NoteSearchResult,
  type NoteStats,
} from './notes.js';
