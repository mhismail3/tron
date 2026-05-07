//! # server
//!
//! Axum HTTP + `WebSocket` server and event broadcasting.
//!
//! - HTTP endpoints: health check, metrics, WebSocket upgrade
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
//! | `capabilities` | Canonical domain function handlers and capability runtime dependencies           |
//! | `config`      | `ServerConfig` (host/port + heartbeat/buffer tuning)                               |
//! | `codex_app`   | Server-owned `codex app-server` child lifecycle + iOS discovery status             |
//! | `cron_adapters` | Server transport adapters for cron WebSocket/APNS callbacks                      |
//! | `device`      | iOS push-device registry; APNs token storage                                       |
//! | `disk`        | Disk-space probes for health diagnostics                                           |
//! | `engine_runtime` | Queue drainers and stream pump for engine primitives                           |
//! | `external_workers` | Loopback-only engine worker WebSocket endpoint                              |
//! | `health`      | `/health` JSON producer (DB ok, transport count, version)                          |
//! | `metrics`     | Prometheus recorder install + `/metrics` exporter                                  |
//! | `onboarding`  | Per-server bearer-token lifecycle + first-run sentinel                             |
//! | `platform`    | OS-specific surfaces (APNs, launchd, codesign helpers)                             |
//! | `server`      | `TronServer::new` wiring (registry + context + bind)                               |
//! | `services`    | Server-local services used by canonical engine capabilities                        |
//! | `shutdown`    | Phased graceful shutdown coordinator (MCP → tasks → IO)                            |
//! | `transport`   | Thin client transports over canonical engine capabilities                          |
//! | `updater`     | User-mode GitHub Releases checks/downloads — channel + action + state           |
//! | `websocket`   | WS upgrade, framing, heartbeat, mandatory bearer-auth middleware                   |

#![deny(unsafe_code)]

/// Canonical server-owned engine capability modules and public engine transport catalog.
pub mod capabilities;
pub mod codex_app;
#[path = "app/config.rs"]
pub mod config;
pub mod cron_adapters;
pub mod device;
#[path = "ops/disk.rs"]
pub mod disk;
pub mod engine_runtime;
pub mod external_workers;
#[path = "ops/health.rs"]
pub mod health;
#[path = "app/metrics.rs"]
pub mod metrics;
pub mod onboarding;
pub mod platform;
#[path = "app/server.rs"]
#[allow(clippy::module_inception)]
pub mod server;
pub mod services;
#[path = "app/shutdown.rs"]
pub mod shutdown;
pub mod transport;
pub mod updater;
pub mod websocket;
