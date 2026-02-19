//! Shared library modules for `tron-agent` tests and binary wiring.
//!
//! The `tron-agent` binary (`main.rs`) wires together all crates and starts
//! the HTTP/WebSocket server. This `lib.rs` exposes modules shared between
//! `main.rs` and integration tests.

#![deny(unsafe_code)]

pub mod db_path_policy;
