//! # tron-tools
//!
//! Tool trait and all tool implementations for the Tron agent.
//!
//! This crate defines the [`TronTool`](traits::TronTool) trait that every tool
//! implements, plus the [`ToolRegistry`](registry::ToolRegistry) for managing
//! registered tools. Tools are grouped by category:
//!
//! - **Filesystem**: `Read`, `Write`, `Edit`, `Find`
//! - **System**: `Bash`, `Remember`
//! - **Search**: text/AST unified search
//! - **Web**: `WebFetch`, `WebSearch`
//! - **Browser**: `OpenURL`, `BrowseTheWeb`
//! - **UI**: `AskUserQuestion`, `NotifyApp`, `TaskManager`, `RenderAppUI`
//! - **Subagent**: `SpawnSubagent`, `QueryAgent`, `WaitForAgents`
//! - **Communication**: `send_message`, `receive_messages`

#![deny(unsafe_code)]
// The TronTool trait returns `&str` from `fn name()` — clippy's `unnecessary_literal_bound`
// fires on every impl but the trait signature dictates the return type.
#![allow(clippy::unnecessary_literal_bound)]

pub mod errors;
pub mod registry;
pub mod traits;
pub mod utils;

// Tool implementation modules
pub mod browser;
pub mod communication;
pub mod fs;
pub mod search;
pub mod subagent;
pub mod system;
pub mod ui;
pub mod web;
