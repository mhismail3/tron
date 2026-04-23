//! # server
//!
//! Axum HTTP + `WebSocket` server and event broadcasting.
//!
//! - HTTP endpoints: health check
//! - `WebSocket` gateway: connection management, heartbeat, message dispatch
//! - Event fan-out to connected clients via `BroadcastManager`
//! - Graceful shutdown via `CancellationToken` coordination
//!
//! ## Module Position
//!
//! HTTP/WS surface. Depends on all other tron modules.
//!
//! ## Submodules
//!
//! | Module        | Purpose                                                                            |
//! |---------------|------------------------------------------------------------------------------------|
//! | `config`      | `ServerConfig` (host/port + heartbeat/buffer tuning)                               |
//! | `deploy`      | Deploy sentinel, atomic-swap binary lifecycle, rollback                            |
//! | `device`      | iOS push-device registry; APNs token storage                                       |
//! | `disk`        | Disk-space + write probes for deploy / log rotation                                |
//! | `health`      | `/health` JSON producer (DB ok, RPC count, version)                                |
//! | `metrics`     | Prometheus recorder install + `/metrics` exporter                                  |
//! | `onboarding`  | Per-server bearer-token lifecycle + first-run sentinel ([Phase 2])                 |
//! | `platform`    | OS-specific surfaces (APNs, launchd, codesign helpers)                             |
//! | `rpc`         | JSON-RPC method registry, handler tree, request/response types                     |
//! | `server`      | `TronServer::new` wiring (registry + context + bind)                               |
//! | `shutdown`    | Phased graceful shutdown coordinator (MCP → tasks → IO)                            |
//! | `websocket`   | WS upgrade, framing, heartbeat, bearer-auth middleware (when `auth.enforced=true`) |

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
pub mod onboarding;
pub mod platform;
pub mod rpc;
#[path = "app/server.rs"]
#[allow(clippy::module_inception)]
pub mod server;
#[path = "app/shutdown.rs"]
pub mod shutdown;
pub mod websocket;
