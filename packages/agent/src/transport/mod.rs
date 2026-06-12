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
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | [`http`] | HTTP-adjacent auth gate for WebSocket upgrades |
//! | [`engine`] | `/engine` contracts, request routing, socket sessions, and stream cursors |
//! | [`runtime`] | Runtime services, external-worker transport, stream projection, and setup |
//!
//! ## Entry Points
//!
//! - [`engine::build_engine_transport_request`] validates a public `/engine`
//!   frame into the canonical transport-neutral request shape.
//! - [`engine::dispatch_engine_transport_request`] routes validated requests to
//!   [`crate::engine::EngineHostHandle`].
//! - [`engine::socket::run_engine_ws_session`] owns one live WebSocket session,
//!   subscriptions, request/response writes, and socket closure.
//! - [`runtime::setup::register_server_domains_for_context`] registers retained
//!   domain workers during app startup.
//! - [`runtime::EngineRuntimeServices::start`] launches retained runtime pumps.
//!
//! ## Invariants
//!
//! - Transport owns framing, authentication gates, method existence, depth
//!   limits, timeout policy, metrics, cursor state, and sanitized wire errors.
//! - Inbound WebSocket JSON frames are capped before parsing at the socket
//!   owner boundary; outbound queues and worker sends remain bounded by their
//!   owning socket/session loops.
//! - Transport must not implement domain behavior or call handler-shaped
//!   shortcuts; it dispatches canonical engine requests only.
//! - `/engine/workers` is loopback/local external-worker transport; registration
//!   and invocation authority still live in the engine runtime.
//! - Live subscriptions without explicit cursors start at the topic tail; stored
//!   replay requires explicit cursors.
//!
//! ## Test Ownership
//!
//! Socket/session behavior lives under `transport/engine/socket/tests.rs`.
//! Runtime stream/external-worker behavior lives under the corresponding
//! `transport/runtime/*/tests` module. Protocol parity and removed-surface
//! assertions belong in the static integration targets under
//! `packages/agent/tests/`.

pub mod engine;
pub mod http;
pub mod runtime;
