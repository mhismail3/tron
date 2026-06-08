//! Cross-owner foundation, protocol, server, storage, and observability code.
//!
//! | Module | Purpose |
//! |--------|---------|
//! | [`foundation`] | Constants, IDs, paths, profile specs, retry/text helpers, and shared errors |
//! | [`protocol`] | Public DTOs for content, events, messages, memory, and model capability data |
//! | [`server`] | Transport-neutral runtime context, validation, params, and capability errors |
//! | [`storage`] | SQLite storage helpers used by engine, session, logs, and runtime surfaces |
//! | [`observability`] | Tracing/log persistence transport and test capture helpers |
//!
//! Shared modules must be used by multiple owners. Single-owner helpers move
//! back to their app, transport, engine, or domain owner.

#![deny(unsafe_code)]

pub mod foundation;
pub mod observability;
pub mod protocol;
pub mod server;
pub mod storage;
