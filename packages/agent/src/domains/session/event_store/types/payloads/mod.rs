//! Typed payload definitions for each [`EventType`](super::EventType) variant.
//!
//! Each submodule defines the payload struct(s) for one domain of events.
//! All payloads use `camelCase` field naming for DTO parity with
//! TypeScript and iOS.

pub mod capability_invocation;
pub mod compact;
pub mod context;
pub mod error;
pub mod message;
pub mod message_ops;
pub mod metadata;
pub mod session;
pub mod streaming;
pub mod token_usage;
pub mod turn;

pub use token_usage::{TokenRecord, TokenTotals, TokenUsage};
