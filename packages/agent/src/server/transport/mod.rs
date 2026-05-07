//! # Transport
//!
//! Thin client-facing transports over the canonical engine capability fabric.
//!
//! Transports own protocol framing, method existence, depth limits, timeout
//! policy, metrics, and wire error sanitization. They do not own domain
//! behavior. Executable behavior lives in `server::capabilities` and engine
//! primitives.

pub mod engine;
pub mod json_rpc;
pub mod protocol;
