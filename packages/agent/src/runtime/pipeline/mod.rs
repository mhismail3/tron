//! # runtime/pipeline — turn-execution helpers
//!
//! Data transformations applied inside the agent turn loop, primarily
//! to reshape LLM stream output into persistable events. The module
//! exists so [`crate::runtime::agent::turn_runner`] stays focused on
//! orchestration rather than format plumbing.
//!
//! ## Submodules
//!
//! | Module          | Content |
//! |-----------------|---------|
//! | [`persistence`] | Accumulate `StreamEvent`s during a turn and emit the final persisted payload (assistant message, tool calls) in the shape [`crate::events`] expects |
//!
//! ## Module Position
//!
//! Depends on: `core`, `events`, `llm`.
//! Depended on by: `runtime::agent::turn_runner`.

pub mod persistence;
