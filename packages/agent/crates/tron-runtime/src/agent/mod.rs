//! Agent execution modules.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `tron_agent` | Core agent struct — owns provider, tools, context manager |
//! | `turn_runner` | Single turn: build context → LLM call → process stream → tools |
//! | `stream_processor` | Consumes `Stream<StreamEvent>`, accumulates content blocks |
//! | `tool_executor` | Execute tool calls with pre/post hooks, guardrails, cancellation |
//! | `event_emitter` | Broadcast channel wrapper for agent lifecycle events |
//! | `compaction_handler` | Post-turn compaction trigger and subagent summarizer |
//!
//! ## Data Flow
//!
//! `turn_runner` → LLM provider → `stream_processor` → `tool_executor` → loop

pub mod compaction_handler;
pub mod event_emitter;
pub mod stream_processor;
pub mod tool_executor;
pub mod tron_agent;
pub mod turn_runner;
