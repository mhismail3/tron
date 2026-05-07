//! WebSocket connection management, message dispatch, and broadcasting.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `auth` | Bearer-token verification for WS upgrades (`Authorization: Bearer <token>`); mtime-cached |
//! | `connection` | Per-connection state (session binding, send channel, liveness flags) |
//! | `handler` | JSON-RPC message parsing, method dispatch, response framing |
//! | `stream_pump` | Orchestrator events → engine streams → WebSocket broadcast delivery |
//! | `broadcast` | Fan-out manager: subscribe/unsubscribe, per-session filtering |
//! | `session` | Full session lifecycle — heartbeat lives in the outbound forwarder |
//!
//! ## Data Flow
//!
//! `auth` → `connection` → `handler` (RPC dispatch) → response.
//! `stream_pump` listens to orchestrator broadcast; migrated event classes
//! publish stream records first, then the stream pump broadcasts compatible
//! frames to clients.

pub mod auth;
pub mod broadcast;
pub mod connection;
pub mod handler;
pub mod session;
pub mod stream_pump;
