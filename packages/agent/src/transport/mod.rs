//! # Transport
//!
//! Thin client-facing transports over the canonical engine capability fabric.
//!
//! Transports own protocol framing, method existence, depth limits, timeout
//! policy, metrics, subscription cursor state, and wire error sanitization.
//! They do not own domain behavior. Executable behavior lives in
//! `domains::*` and engine primitives.
//! Live stream subscriptions that omit a cursor start at the topic tail;
//! replay/catch-up and stateless stream polling require explicit stored
//! cursors. The engine applies visibility before stream pagination so a
//! session-specific `/engine` subscriber cannot starve behind older events from
//! other sessions.
//!
//! | Module | Purpose |
//! |--------|---------|
//! | [`http`] | HTTP-adjacent auth gate for WebSocket upgrades |
//! | [`engine`] | `/engine` contracts, request routing, socket sessions, and stream cursors |
//! | [`runtime`] | Runtime services, external-worker transport, stream projection, and setup |

pub mod engine;
pub mod http;
pub mod runtime;
