//! # shared
//!
//! Foundation types, errors, branded IDs, and utilities for the Tron agent.
//!
//! This module provides the shared vocabulary that all other Tron modules depend on:
//!
//! - **Branded IDs**: [`ids::EventId`], [`ids::SessionId`], [`ids::WorkspaceId`] as newtypes
//! - **Messages**: [`messages::Message`] enum with `User`, `Assistant`, `CapabilityResult` variants.
//!   Wire-format coverage lives beside the implementation in `protocol/messages/tests.rs`.
//! - **Content blocks**: [`content::UserContent`], [`content::AssistantContent`], etc.
//! - **Capability results**: [`model_capabilities::CapabilityResult`] with content, details, error/stop flags
//! - **Errors**: [`errors::TronError`] hierarchy via `thiserror`, capability error codes
//! - **Events**: [`events::StreamEvent`] for LLM streaming, [`events::TronEvent`] for agent lifecycle
//! - **Retry**: [`retry::RetryConfig`] and backoff calculation
//! - **Profile Home**: [`constitution`] home migration/recovery and [`profile`] execution specs
//! - **`agent::ask_user`**: [`user_interaction`] payload types for native interaction
//! - **Memory**: [`memory::SessionMemory`]
//!
//! ## Module Position
//!
//! Shared module. Depended on by all other tron modules.

#![deny(unsafe_code)]

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
#[path = "protocol/model_capabilities.rs"]
pub mod model_capabilities;
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
#[path = "protocol/user_interaction.rs"]
pub mod user_interaction;
