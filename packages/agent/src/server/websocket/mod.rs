//! WebSocket connection management and stream delivery.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `auth` | Bearer-token verification for WS upgrades (`Authorization: Bearer <token>`); mtime-cached |
//! | `connection` | Per-connection state (session binding, send channel, liveness flags) |
//! | `handler` | `/ws` JSON-RPC message parsing, method dispatch, response framing |
//! | `stream_pump` | Orchestrator events → engine streams → WebSocket broadcast delivery |
//! | `broadcast` | Fan-out manager: subscribe/unsubscribe, per-session filtering |
//! | `session` | Full session lifecycle — heartbeat lives in the outbound forwarder |
//!
//! ## Data Flow
//!
//! `/ws`: `auth` → `connection` → `handler` (JSON-RPC dispatch) → response.
//! `/engine`: `auth` → `server::transport::engine_ws` → `EngineTransportRequest`.
//! `stream_pump` listens to orchestrator broadcast; migrated event classes
//! publish stream records first, then the stream pump broadcasts compatible
//! frames to clients.

pub mod auth;
pub mod broadcast;
pub mod connection;
pub mod handler;
pub mod session;
pub mod stream_pump;
