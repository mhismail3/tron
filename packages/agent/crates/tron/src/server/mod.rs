//! # tron-server
//!
//! Axum HTTP + `WebSocket` server and event broadcasting.
//!
//! - HTTP endpoints: health check
//! - `WebSocket` gateway: connection management, heartbeat, message dispatch
//! - Event fan-out to connected clients via `BroadcastManager`
//! - Graceful shutdown via `CancellationToken` coordination
//!
//! ## Crate Position
//!
//! HTTP/WS surface. Depends on all other tron crates.

#![deny(unsafe_code)]

#[path = "app/config.rs"]
pub mod config;
#[path = "ops/deploy.rs"]
pub mod deploy;
pub mod device;
#[path = "ops/disk.rs"]
pub mod disk;
#[path = "ops/health.rs"]
pub mod health;
#[path = "app/metrics.rs"]
pub mod metrics;
pub mod platform;
pub mod rpc;
#[path = "app/server.rs"]
pub mod server;
#[path = "app/shutdown.rs"]
pub mod shutdown;
pub mod websocket;
