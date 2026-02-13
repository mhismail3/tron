//! # tron-server
//!
//! Axum HTTP + `WebSocket` server and event broadcasting.
//!
//! - HTTP endpoints: health check, static assets
//! - `WebSocket` gateway: connection management, heartbeat, message dispatch
//! - Event broadcasting via `tokio::sync::broadcast` (fan-out to all connected clients)
//! - Event envelope construction matching `BroadcastEventType`
//! - Graceful shutdown via `tokio::signal` + `CancellationToken`

#![deny(unsafe_code)]
