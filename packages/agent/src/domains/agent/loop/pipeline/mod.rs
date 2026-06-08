//! # agent/runner/pipeline -- turn-execution helpers
//!
//! Data transformations applied inside the agent turn loop, primarily
//! to reshape LLM stream output into persistable events. The module
//! exists so [`crate::domains::agent::r#loop::turn_runner`] stays focused on
//! orchestration rather than format plumbing.
//!
//! ## Submodules
//!
//! | Module          | Content |
//! |-----------------|---------|
//! | [`persistence`] | Accumulate `StreamEvent`s during a turn and emit the final persisted payload (assistant message, capability invocations) in the session event DTO shape |
//!
//! ## Module Position
//!
//! Depends on: `shared`, `domains::model`, and session event DTOs.
//! Depended on by: `domains::agent::r#loop::turn_runner`.

pub mod persistence;
