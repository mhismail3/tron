//! # tron-events
//!
//! Event sourcing engine with `SQLite` backend for the Tron agent.
//!
//! This is the largest subsystem, responsible for:
//!
//! - **Session events**: 42-variant `SessionEvent` enum matching the `TypeScript` wire format exactly
//! - **Event store**: High-level API for session creation, event append, ancestor walk, fork, rewind
//! - **`SQLite` backend**: `rusqlite` facade with repository pattern (event, session, workspace, blob, search)
//! - **Event factory**: Scoped to session/workspace, auto-generates IDs and timestamps
//! - **Event chain builder**: Automates `parent_id` threading across sequential events
//! - **Message reconstructor**: Two-pass algorithm for rebuilding messages from event history
//! - **Migrations**: Version-tracked SQL schema evolution

#![deny(unsafe_code)]
