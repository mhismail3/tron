//! Agent execution modules.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `tron_agent` | Core agent struct — owns provider, capabilities, context manager |
//! | `turn_runner` | Single turn: resolve live engine capability surface → build context → LLM call → process stream → invocations |
//! | `stream_processor` | Consumes `Stream<StreamEvent>`, drives the select loop |
//! | `stream_state` | Accumulator struct + event handlers for stream processing |
//! | `capability_invocation_executor` | Execute capability invocations with policy/hooks/cancellation, derive stable engine idempotency from model-facing `execute.idempotencyKey` when supplied, then route actual execution through canonical engine functions; production fails closed if the live catalog target is unavailable |
//! | `event_emitter` | Broadcast channel wrapper for agent lifecycle events |
//! | `compaction_handler` | Pre-turn compaction trigger and subagent summarizer |
//!
//! ## Data Flow
//!
//! `turn_runner` → live catalog capability projection → LLM provider →
//! `stream_processor` → `capability_invocation_executor` → canonical engine invocation → loop

pub mod capability_invocation_executor;
pub mod compaction_handler;
pub mod event_emitter;
pub mod stream_processor;
mod stream_state;
pub mod tron_agent;
pub mod turn_runner;
