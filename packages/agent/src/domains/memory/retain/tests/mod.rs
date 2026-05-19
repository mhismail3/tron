//! Concern-owned tests for memory retain behavior.
//!
//! Keep this root declaration-only; shared fixtures belong in `support`,
//! and behavior tests live in the concern module that owns them.

mod support;

mod formatting;
mod handler_events;
mod interactive_ids;
mod interactive_serialization;
mod parsing;
mod writers;
