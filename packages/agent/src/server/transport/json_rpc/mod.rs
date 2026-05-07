//! # JSON-RPC Engine Transport
//!
//! JSON-RPC 2.0 protocol layer for the engine capability fabric.
//!
//! The public transport surface is intentionally tiny:
//! - `engine.discover`
//! - `engine.inspect`
//! - `engine.watch`
//! - `engine.invoke`
//! - `engine.promote`
//!
//! Domain behavior lives in canonical `namespace::function` capabilities.
//! Dotted domain method names are not registered public methods on this
//! branch. Clients and agents discover the live catalog, then invoke canonical
//! ids through `engine.invoke`.
//!
//! The context also owns the shared engine host handle. JSON-RPC is now a
//! transport layer only. The registry validates method existence/depth and
//! dispatches each `engine.*` method as a `json_rpc` trigger into the reserved
//! engine meta-capabilities. Mutating domain functions require explicit
//! idempotency keys supplied by the caller payload; JSON-RPC request ids are
//! correlation ids only.
//!
//! # INVARIANT: no per-client rate limiting (L7, trusted-local)
//!
//! The JSON-RPC transport does NOT rate-limit inbound calls per client,
//! per-method, or per-connection. Under the trusted-local threat
//! model that is intentional — the only callers are the user's own
//! devices, and the 1 MB body cap + JSON depth check
//! ([`validation`]) plus connection-level backpressure
//! ([`crate::server::websocket::broadcast`] drop detection) are
//! sufficient for accidental-runaway protection.
//!
//! Hardening path for a future threat-model shift: a
//! [tower::limit::RateLimit]-style layer in
//! `crate::server::websocket` keyed on `(connection_id, method)`,
//! with per-method quotas loaded from settings.

pub mod bindings;
pub mod engine_transport;
pub(crate) mod error_mapping;
pub mod errors;
pub(crate) mod params;
pub(crate) mod protocol;
pub mod registry;
pub mod types;
pub mod validation;
