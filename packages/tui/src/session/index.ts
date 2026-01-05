/**
 * @fileoverview Session module exports
 *
 * Uses EventStore-based TUI session for all persistence.
 */
export * from './eventstore-tui-session.js';

// Re-export with simpler alias for convenience
export { EventStoreTuiSession as TuiSession } from './eventstore-tui-session.js';
