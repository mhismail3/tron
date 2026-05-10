//! # Transport
//!
//! Thin client-facing transports over the canonical engine capability fabric.
//!
//! Transports own protocol framing, method existence, depth limits, timeout
//! policy, metrics, subscription cursor state, and wire error sanitization.
//! They do not own domain behavior. Executable behavior lives in
//! `domains::*` and engine primitives.
//! Filtered stream subscriptions still advance across scanned-but-undelivered
//! records so a session-specific `/engine` subscriber cannot starve behind
//! older events from other sessions.
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `auth` | Bearer-token auth gate for engine WebSocket transports |
//! | `contracts` | Public engine protocol message contracts and trigger bindings |
//! | `engine` | Engine protocol `EngineTransportRequest` builder/dispatcher |
//! | `engine_ws` | `/engine` WebSocket protocol, heartbeat, stream subscribe/poll/ack |
//! | `setup` | Startup hook that delegates domain worker registration |

pub mod auth;
pub mod contracts;
pub mod engine;
pub mod engine_ws;
pub mod runtime;
pub mod setup;
