//! # tron-core
//!
//! Foundation types, errors, branded IDs, and utilities for the Tron agent.
//!
//! This crate provides the shared vocabulary that all other Tron crates depend on:
//!
//! - **Branded IDs**: [`ids::EventId`], [`ids::SessionId`], [`ids::WorkspaceId`] as newtypes
//! - **Messages**: [`messages::Message`] enum with `User`, `Assistant`, `ToolResult` variants
//! - **Content blocks**: [`content::UserContent`], [`content::AssistantContent`], etc.
//! - **Tool results**: [`tools::TronToolResult`] with content, details, error/stop flags
//! - **Errors**: [`errors::TronError`] hierarchy via `thiserror`, RPC error codes
//! - **Events**: [`events::StreamEvent`] for LLM streaming, [`events::TronEvent`] for agent lifecycle
//! - **Retry**: [`retry::RetryConfig`] and backoff calculation
//! - **`AskUserQuestion`**: [`ask_user_question::AskUserQuestion`] interactive tool types
//! - **Memory**: [`memory::SessionMemory`] and [`memory::HandoffRecord`]
//!
//! ## Crate Position
//!
//! Foundation crate. Depended on by all other tron crates.

#![deny(unsafe_code)]

pub mod ask_user_question;
pub mod constants;
pub mod content;
pub mod errors;
pub mod events;
pub mod ids;
pub mod logging;
pub mod memory;
pub mod messages;
pub mod retry;
pub mod text;
pub mod tools;
