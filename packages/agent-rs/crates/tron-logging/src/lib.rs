//! # tron-logging
//!
//! Structured logging with `tracing` and optional `SQLite` transport.
//!
//! Provides per-module spans, request/session ID propagation,
//! and batched async writes to the log database.

#![deny(unsafe_code)]
