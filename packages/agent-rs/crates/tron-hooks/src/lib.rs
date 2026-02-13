//! # tron-hooks
//!
//! Async lifecycle hook engine for the Tron agent.
//!
//! Hooks fire at defined points in the agent's execution lifecycle:
//! [`PreToolUse`](types::HookType::PreToolUse) (before tool execution),
//! [`PostToolUse`](types::HookType::PostToolUse) (after),
//! [`Stop`](types::HookType::Stop) (agent stopping),
//! [`SessionStart`](types::HookType::SessionStart) /
//! [`SessionEnd`](types::HookType::SessionEnd), and more.
//!
//! ## Execution Model
//!
//! Two execution modes:
//! - **Blocking**: Sequential, priority-ordered. Can block or modify the operation.
//! - **Background**: Fire-and-forget with tracking for eventual draining.
//!
//! Three hook types are *forced-blocking* — [`PreToolUse`](types::HookType::PreToolUse),
//! [`UserPromptSubmit`](types::HookType::UserPromptSubmit), and
//! [`PreCompact`](types::HookType::PreCompact) — because they can affect agent flow.
//!
//! ## Fail-Open
//!
//! Hook errors never crash sessions. They are logged and treated as `Continue`.
//!
//! ## Example
//!
//! ```rust
//! use tron_hooks::registry::HookRegistry;
//! use tron_hooks::engine::HookEngine;
//!
//! let registry = HookRegistry::new();
//! let engine = HookEngine::new(registry);
//! // Register hooks, then call engine.execute() at lifecycle points.
//! ```

#![deny(unsafe_code)]

pub mod background;
pub mod context;
pub mod discovery;
pub mod engine;
pub mod errors;
pub mod handler;
pub mod registry;
pub mod types;
