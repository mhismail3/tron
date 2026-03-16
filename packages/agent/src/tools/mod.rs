//! # tools
//!
//! Tool trait and all tool implementations for the Tron agent.
//!
//! This module defines the [`TronTool`](traits::TronTool) trait that every tool
//! implements, plus the [`ToolRegistry`](registry::ToolRegistry) for managing
//! registered tools. Tools are grouped by category:
//!
//! - **Filesystem**: `Read`, `Write`, `Edit`, `Find`
//! - **System**: `Bash`, `Remember`
//! - **Search**: text/AST unified search
//! - **Web**: `WebFetch`, `WebSearch`
//! - **Browser**: `OpenURL`, `BrowseTheWeb`
//! - **UI**: `AskUserQuestion`, `NotifyApp`, `TaskManager`, `RenderAppUI`
//! - **Automations**: Managed via `manage-automations` skill (Read/Write/Edit on `~/.tron/workspace/automations.json`)
//! - **Subagent**: `SpawnSubagent`, `WaitForAgents`
//! - **Communication**: `send_message`, `receive_messages`
//!
//! ## Module Position
//!
//! Depends on: core.
//! Depended on by: runtime, server.

#![deny(unsafe_code)]
// The TronTool trait returns `&str` from `fn name()` — clippy's `unnecessary_literal_bound`
// fires on every impl but the trait signature dictates the return type.
#![allow(clippy::unnecessary_literal_bound)]

#[cfg(test)]
#[path = "testing/testutil.rs"]
pub(crate) mod testutil;

pub mod backends;
pub mod cdp;
pub mod errors;
pub mod registry;
pub mod traits;
pub(crate) mod utils;

// Tool implementation modules
pub mod browser;
pub mod communication;
pub mod fs;
pub mod search;
pub mod subagent;
pub mod system;
pub mod ui;
pub mod web;
