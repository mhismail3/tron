//! High-level `EventStore` API.
//!
//! The [`EventStore`] provides a transactional, session-centric API built on
//! top of the repository layer. All write operations are atomic — they execute
//! within a single `SQLite` transaction, so callers never see partial state.

mod event_store;

pub use event_store::*;
