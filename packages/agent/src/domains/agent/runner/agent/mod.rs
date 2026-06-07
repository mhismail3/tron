//! Agent execution modules.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `tron_agent` | Core agent struct — owns provider, primitive surface, and context manager |
//! | `turn_runner` | Single turn: resolve `execute` → build context → LLM call → process stream → primitive invocations |
//! | `stream_processor` | Consumes `Stream<StreamEvent>`, drives the select loop |
//! | `stream_state` | Accumulator struct + event handlers for stream processing |
//! | `capability_invocation_executor` | Execute model-emitted primitive calls through the engine host with cancellation and session event projection |
//! | `event_emitter` | Broadcast channel wrapper for agent lifecycle events |
//! | `compaction_handler` | Pre-turn compaction trigger, deterministic summarizer, committed boundary events, and terminal no-op live progress |
//!
//! ## Data Flow
//!
//! `turn_runner` → primitive `execute` projection → LLM provider →
//! `stream_processor` → `capability_invocation_executor` → engine invocation → loop
//!
//! `TronAgent` receives the persisted session turn count when resumed. Runtime
//! events and token records use `persisted_turn_count + run_turn`, while
//! `RunResult.turns_executed` stays scoped to the current prompt run.
//! Hosted and local providers both receive the live `execute` primitive. PET-6
//! owns removal of the remaining startup/server-context registries and managers
//! outside this prompt loop.

pub mod capability_invocation_executor;
pub mod compaction_handler;
pub mod event_emitter;
pub mod stream_processor;
mod stream_state;
pub mod tron_agent;
pub mod turn_runner;
