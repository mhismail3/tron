//! WebSocket connection management, message dispatch, and broadcasting.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `connection` | Per-connection state (session binding, send channel, liveness flags) |
//! | `handler` | JSON-RPC message parsing, method dispatch, response framing |
//! | `event_bridge` | Orchestrator events → WebSocket broadcast |
//! | `broadcast` | Fan-out manager: subscribe/unsubscribe, per-session filtering |
//! | `session` | Full session lifecycle — heartbeat lives in the outbound forwarder |
//!
//! ## Data Flow
//!
//! `connection` → `handler` (RPC dispatch) → response.
//! `event_bridge` listens to orchestrator broadcast → `broadcast` → clients.

pub mod broadcast;
pub mod connection;
pub mod event_bridge;
pub mod handler;
pub mod session;
