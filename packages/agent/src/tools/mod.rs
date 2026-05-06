//! # tools
//!
//! Tool trait and all tool implementations for the Tron agent.
//!
//! This module defines the [`TronTool`](traits::TronTool) trait that every tool
//! implements, plus the [`ToolRegistry`](registry::ToolRegistry) for managing
//! registered tools. Tools are grouped by category:
//!
//! - **Filesystem**: `Read`, `Write`, `Edit`, `Find`
//! - **System**: `Bash`
//! - **Search**: text/AST unified search
//! - **Web**: `WebFetch`, `WebSearch`
//! - **UI**: `AskUserQuestion`, `NotifyApp`
//! - **Engine**: live capability discovery, inspection, watch, and invocation
//! - **Subagent**: `SpawnSubagent`
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
pub mod engine;
pub mod errors;
pub mod registry;
pub mod traits;
pub(crate) mod utils;

// Tool implementation modules
pub mod fs;
pub mod search;
pub mod subagent;
pub mod system;
pub mod ui;
pub mod web;
