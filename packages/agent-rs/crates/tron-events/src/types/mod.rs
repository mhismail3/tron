//! Event type definitions for the Tron event sourcing system.
//!
//! - [`EventType`]: 58-variant enum of all session event type discriminators.
//! - [`SessionEvent`]: Flat struct with base fields + opaque `payload` JSON.
//! - [`SessionEventPayload`]: Typed payload access via [`SessionEvent::typed_payload()`].
//! - [`payloads`]: Typed payload structs for each event type domain.
//! - [`type_guards`]: Convenience functions for filtering events by type.
//! - [`state`]: Session state, workspace, branch, search result types.

pub mod base;
pub mod event_type;
pub mod payloads;
pub mod state;
#[cfg(test)]
mod tests;
pub mod type_guards;

pub use base::{SessionEvent, SessionEventPayload};
pub use event_type::{EventType, ALL_EVENT_TYPES};
pub use payloads::{TokenRecord, TokenUsage};
pub use state::{
    Branch, BranchRef, ForkRef, Message, MessageWithEventId, SearchResult,
    SessionMetadata, SessionState, SessionSummary, Workspace,
};
