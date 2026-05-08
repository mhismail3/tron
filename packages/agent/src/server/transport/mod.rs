//! # Transport
//!
//! Thin client-facing transports over the canonical engine capability fabric.
//!
//! Transports own protocol framing, method existence, depth limits, timeout
//! policy, metrics, subscription cursor state, and wire error sanitization.
//! They do not own domain behavior. Executable behavior lives in
//! `server::capabilities` and engine primitives.
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `engine` | Protocol-neutral `EngineTransportRequest` builder/dispatcher |
//! | `engine_ws` | `/engine` WebSocket protocol, heartbeat, stream subscribe/poll/ack |
//! | `json_rpc` | Five-method JSON-RPC transport over `/ws` |
//! | `protocol` | Shared protocol constants |

pub mod engine;
pub mod engine_ws;
pub mod json_rpc;
pub mod protocol;
