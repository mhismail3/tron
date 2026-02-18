//! Event type definitions for the Tron event sourcing system.
//!
//! - [`EventType`]: 60-variant enum of all session event type discriminators.
//! - [`SessionEvent`]: Flat struct with base fields + opaque `payload` JSON.
//! - [`SessionEventPayload`]: Typed payload access via [`SessionEvent::typed_payload()`].
//! - [`payloads`]: Typed payload structs for each event type domain.
//! - [`state`]: Session state, workspace, branch, search result types.

// `macros` must come first so the `define_events!` macro is available to
// subsequent modules.
#[macro_use]
mod macros;

pub mod base;
mod generated;
pub mod payloads;
pub mod state;
#[cfg(test)]
mod tests;

pub use base::SessionEvent;
pub use generated::{ALL_EVENT_TYPES, EventType, SessionEventPayload};
pub use payloads::{TokenRecord, TokenTotals, TokenUsage};
pub use state::{
    Branch, BranchRef, ForkRef, Message, MessageWithEventId, SearchResult, SessionMetadata,
    SessionState, SessionSummary, Workspace,
};
