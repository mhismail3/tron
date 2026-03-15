//! # core
//!
//! Foundation types, errors, branded IDs, and utilities for the Tron agent.
//!
//! This module provides the shared vocabulary that all other Tron modules depend on:
//!
//! - **Branded IDs**: [`ids::EventId`], [`ids::SessionId`], [`ids::WorkspaceId`] as newtypes
//! - **Messages**: [`messages::Message`] enum with `User`, `Assistant`, `ToolResult` variants
//! - **Content blocks**: [`content::UserContent`], [`content::AssistantContent`], etc.
//! - **Tool results**: [`tools::TronToolResult`] with content, details, error/stop flags
//! - **Errors**: [`errors::TronError`] hierarchy via `thiserror`, RPC error codes
//! - **Events**: [`events::StreamEvent`] for LLM streaming, [`events::TronEvent`] for agent lifecycle
//! - **Retry**: [`retry::RetryConfig`] and backoff calculation
//! - **`AskUserQuestion`**: [`ask_user_question::AskUserQuestion`] interactive tool types
//! - **Memory**: [`memory::SessionMemory`]
//!
//! ## Module Position
//!
//! Foundation module. Depended on by all other tron modules.

#![deny(unsafe_code)]

#[path = "protocol/ask_user_question.rs"]
pub mod ask_user_question;
#[path = "foundation/constants.rs"]
pub mod constants;
#[path = "protocol/content.rs"]
pub mod content;
pub mod errors;
#[path = "protocol/events.rs"]
pub mod events;
#[path = "foundation/ids.rs"]
pub mod ids;
pub mod logging;
#[path = "protocol/memory.rs"]
pub mod memory;
#[path = "protocol/messages.rs"]
pub mod messages;
#[path = "foundation/retry.rs"]
pub mod retry;
#[path = "foundation/text.rs"]
pub mod text;
#[path = "protocol/tools.rs"]
pub mod tools;
