//! # tron-memory
//!
//! Memory manager and ledger writer.
//!
//! Runs compaction -> ledger sequentially for deterministic DB ordering
//! (`compact.boundary` always precedes `memory.ledger` in event sequence).
//!
//! Fail-silent error handling: memory operations never crash a session.

#![deny(unsafe_code)]
