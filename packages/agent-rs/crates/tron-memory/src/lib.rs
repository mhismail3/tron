//! # tron-memory
//!
//! Memory manager and ledger writer for the Tron agent.
//!
//! Orchestrates the compaction → ledger pipeline with **sequential ordering**:
//! compaction always runs before ledger writing, ensuring `compact.boundary`
//! events always precede `memory.ledger` events in the event log.
//!
//! ## Fail-Silent
//!
//! All memory operations are fail-silent — errors are logged but never
//! propagated. Memory is observability, not functionality. A failed ledger
//! write or compaction trigger never affects the agent's ability to process
//! the next user message.
//!
//! ## Architecture
//!
//! - [`CompactionTrigger`] — Multi-signal decision engine (token ratio,
//!   progress signals, turn-count fallback).
//! - [`MemoryManager`] — Orchestrates trigger → compact → ledger pipeline.
//! - [`MemoryManagerDeps`] — Trait for runtime dependency injection.

#![deny(unsafe_code)]

pub mod errors;
pub mod manager;
pub mod trigger;
pub mod types;

pub use errors::MemoryError;
pub use manager::{MemoryManager, MemoryManagerDeps};
pub use trigger::CompactionTrigger;
pub use types::{
    CompactionTriggerConfig, CompactionTriggerInput, CompactionTriggerResult, CycleInfo,
    LedgerWriteOpts, LedgerWriteResult,
};
