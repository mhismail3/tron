//! WebSocket connection management, heartbeat, message dispatch, and broadcasting.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `connection` | WebSocket upgrade, per-connection read/write loops |
//! | `handler` | JSON-RPC message parsing, method dispatch, response framing |
//! | `event_bridge` | Orchestrator events → WebSocket broadcast (+ iOS adaptation) |
//! | `broadcast` | Fan-out manager: subscribe/unsubscribe, per-session filtering |
//! | `heartbeat` | Periodic ping/pong for connection liveness detection |
//! | `session` | Per-connection session state (subscriptions, auth) |
//!
//! ## Data Flow
//!
//! `connection` → `handler` (RPC dispatch) → response.
//! `event_bridge` listens to orchestrator broadcast → `broadcast` → clients.

pub mod broadcast;
pub mod connection;
pub mod event_bridge;
pub mod handler;
pub mod heartbeat;
pub mod session;
