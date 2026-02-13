//! Typed payload definitions for each [`EventType`](super::EventType) variant.
//!
//! Each submodule defines the payload struct(s) for one domain of events.
//! All payloads use `camelCase` field naming for wire compatibility with
//! TypeScript and iOS.

pub mod compact;
pub mod config;
pub mod context;
pub mod error;
pub mod file;
pub mod hook;
pub mod memory;
pub mod message;
pub mod message_ops;
pub mod metadata;
pub mod notification;
pub mod rules;
pub mod session;
pub mod skill;
pub mod streaming;
pub mod subagent;
pub mod task;
pub mod todo;
pub mod token_usage;
pub mod tool;
pub mod turn;
pub mod worktree;

pub use token_usage::{TokenRecord, TokenUsage};
