//! # Transport
//!
//! Thin client-facing transports over the canonical engine tool fabric.
//!
//! Transports own protocol framing, method existence, depth limits, timeout
//! policy, metrics, subscription cursor state, and wire error sanitization.
//! They do not own domain behavior. Executable behavior lives in
//! `domains::*` and engine primitives.
//! Live stream subscriptions that omit a cursor start at the topic tail;
//! replay/catch-up and stateless stream polling require explicit stored
//! cursors. `/engine` keeps subscription ids and acknowledged cursors local to
//! the owning socket; it does not project transient connection state into the
//! durable engine database. The engine applies visibility before stream pagination so a
//! session-specific `/engine` subscriber cannot starve behind older events from
//! other sessions. Clients explicitly unsubscribe when a presentation or
//! processing lease ends; removal is idempotent, and each connection has a
//! fixed active-subscription ceiling so abandoned clients cannot create
//! unbounded polling work. No durable subscription-record plane exists.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | [`http`] | HTTP-adjacent auth gate for WebSocket upgrades |
//! | [`engine`] | Direct `/engine` invocation routing, socket sessions, and stream cursors |
//! | [`runtime`] | Runtime services, stream projection, and setup |
//!
//! ## Entry Points
//!
//! - [`engine::build_engine_transport_request`] validates a public `/engine`
//!   frame into the canonical transport-neutral request shape.
//! - [`engine::dispatch_engine_transport_request`] routes validated requests to
//!   [`crate::engine::EngineHostHandle`].
//! - [`engine::socket::run_engine_ws_session`] owns one live WebSocket session,
//!   subscriptions, request/response writes, and socket closure.
//! - [`runtime::setup::register_server_domains_for_runtime_context`] registers
//!   canonical domain functions during async app startup, then activates
//!   domain lifecycle tasks.
//! - [`runtime::setup::register_server_domains_for_context`] remains the
//!   single-threaded setup/test fixture entrypoint with the same ordering.
//!
//! ## Invariants
//!
//! - Transport owns framing, authentication gates, method existence, depth
//!   limits, timeout policy, metrics, cursor state, and sanitized wire errors.
//! - The runtime server configuration owns one inbound `/engine` frame budget.
//!   The WebSocket upgrade enforces it, the socket session advertises it during
//!   hello, and correlated validation errors retain the request id. Outbound
//!   queues and worker sends remain bounded by their owning loops.
//! - The same server configuration owns `/engine` heartbeat timing. Each socket
//!   is registered with graceful shutdown before upgrade completion, has one
//!   registry lease and one bounded child-task owner, and keeps stream state
//!   connection-local. Stale peers are reaped, and the active gauge cannot
//!   remain stranded after task cancellation.
//! - Transport must not implement domain behavior or call handler-shaped
//!   shortcuts; it dispatches canonical engine requests only.
//! - Worker webhooks are loopback-only and independently authenticated with
//!   rotatable per-trigger tokens. Persistent worker execution never enters a
//!   parallel transport-owned lifecycle.
//! - Live subscriptions without explicit cursors start at the topic tail; stored
//!   replay requires explicit cursors.
//! - Subscribe/unsubscribe state remains connection-local. Unsubscribe is
//!   idempotent, and one connection cannot exceed the fixed active-subscription
//!   ceiling.
//!
//! ## Test Ownership
//!
//! Socket/session behavior lives under `transport/engine/socket/tests.rs`.
//! Runtime stream behavior lives under the corresponding transport tests.
//! Protocol parity and architectural boundary assertions belong in the
//! integration targets under
//! `packages/agent/tests/`.

pub mod engine;
pub mod http;
pub mod runtime;
