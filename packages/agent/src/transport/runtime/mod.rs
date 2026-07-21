//! Server runtime integration for engine registration and event projection.
//!
//! Client event delivery is handled directly by `/engine` subscriptions over
//! the stream store. Runtime stream projection writes retained agent,
//! auth/settings, session, and catalog changes into engine streams. Persistent
//! worker execution and supervision live in the worker kernel.

pub mod setup;
pub mod streams;
