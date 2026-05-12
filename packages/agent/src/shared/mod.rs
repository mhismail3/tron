//! # shared
//!
//! Foundation types, errors, branded IDs, and utilities for the Tron agent.
//!
//! This module provides the shared vocabulary that all other Tron modules depend on:
//!
//! - **Branded IDs**: [`ids::EventId`], [`ids::SessionId`], [`ids::WorkspaceId`] as newtypes
//! - **Messages**: [`messages::Message`] enum with `User`, `Assistant`, `ToolResult` variants
//! - **Content blocks**: [`content::UserContent`], [`content::AssistantContent`], etc.
//! - **Tool results**: [`tools::CapabilityResult`] with content, details, error/stop flags
//! - **Errors**: [`errors::TronError`] hierarchy via `thiserror`, capability error codes
//! - **Events**: [`events::StreamEvent`] for LLM streaming, [`events::TronEvent`] for agent lifecycle
//! - **Retry**: [`retry::RetryConfig`] and backoff calculation
//! - **Profile Home**: [`constitution`] home migration/recovery and [`profile`] execution specs
//! - **`agent::ask_user`**: [`ask_user_question::agent::ask_user`] interactive tool types
//! - **Memory**: [`memory::SessionMemory`]
//!
//! ## Module Position
//!
//! Shared module. Depended on by all other tron modules.

#![deny(unsafe_code)]

#[path = "protocol/ask_user_question.rs"]
pub mod ask_user_question;
#[path = "foundation/constants.rs"]
pub mod constants;
#[path = "foundation/constitution.rs"]
pub mod constitution;
#[path = "protocol/content.rs"]
pub mod content;
#[path = "protocol/document_extractor.rs"]
pub mod document_extractor;
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
#[path = "foundation/paths.rs"]
pub mod paths;
#[path = "foundation/profile.rs"]
pub mod profile;
#[path = "foundation/retry.rs"]
pub mod retry;
pub mod server;
pub mod storage;
#[path = "foundation/text.rs"]
pub mod text;
#[path = "protocol/tools.rs"]
pub mod tools;
