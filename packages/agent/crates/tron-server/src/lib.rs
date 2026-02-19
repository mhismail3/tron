//! # tron-server
//!
//! Axum HTTP + `WebSocket` server and event broadcasting.
//!
//! - HTTP endpoints: health check
//! - `WebSocket` gateway: connection management, heartbeat, message dispatch
//! - Event fan-out to connected clients via `BroadcastManager`
//! - Graceful shutdown via `CancellationToken` coordination

#![deny(unsafe_code)]

pub mod config;
pub mod health;
pub mod metrics;
pub mod platform;
pub mod rpc;
pub mod server;
pub mod shutdown;
pub mod websocket;
