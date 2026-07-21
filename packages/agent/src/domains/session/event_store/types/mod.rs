//! Event type definitions for the Tron event sourcing system.
//!
//! - [`EventType`]: durable primitive-loop event discriminators.
//! - [`SessionEvent`]: Flat struct with base fields + opaque `payload` JSON.
//! - [`payloads`]: Token totals and the two payload validators used before
//!   capability-invocation persistence.
//! - [`state`]: reconstructed messages and runtime session state.

pub mod base;
mod generated;
pub mod payloads;
pub mod state;
#[cfg(test)]
mod state_tests;

pub use base::SessionEvent;
pub use generated::EventType;
pub use payloads::{TokenTotals, TokenUsage};
pub use state::{Message, MessageWithEventId, SessionState};
