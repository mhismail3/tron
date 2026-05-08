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
//! | `auth` | Bearer-token auth gate for engine WebSocket transports |
//! | `engine` | Engine protocol `EngineTransportRequest` builder/dispatcher |
//! | `engine_ws` | `/engine` WebSocket protocol, heartbeat, stream subscribe/poll/ack |
//! | `protocol` | Shared protocol constants |
//! | `setup` | Canonical capability and engine trigger registration |

pub mod auth;
pub mod engine;
pub mod engine_ws;
pub mod protocol;
pub mod setup;
