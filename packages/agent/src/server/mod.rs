//! # server
//!
//! Axum HTTP + engine WebSocket server.
//!
//! - HTTP endpoints: health check, metrics, `/engine`, and `/engine/workers`
//! - WebSocket transports: engine client protocol and loopback local workers
//! - Event delivery via engine streams
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
//! | `domains`     | Domain-owned workers, canonical functions, schemas, services, and tests             |
//! | `config`      | `ServerConfig` (host/port + heartbeat/buffer tuning)                               |
//! | `disk`        | Disk-space probes for health diagnostics                                           |
//! | `health`      | `/health` JSON producer (DB ok, transport count, version)                          |
//! | `metrics`     | Prometheus recorder install + `/metrics` exporter                                  |
//! | `onboarding`  | Per-server bearer-token lifecycle + first-run sentinel                             |
//! | `platform`    | OS-specific surfaces (APNs, launchd, codesign helpers)                             |
//! | `runtime`     | Queue drainers, stream projection, and runtime engine services                     |
//! | `server`      | `TronServer::new` wiring (engine context + bind)                                   |
//! | `shared`      | Cross-domain context, neutral events, validation, and test support                  |
//! | `shutdown`    | Phased graceful shutdown coordinator (MCP → tasks → IO)                            |
//! | `transport`   | Thin client transports over canonical engine capabilities                          |
//! | `updater`     | User-mode GitHub Releases checks/downloads — channel + action + state           |

#![deny(unsafe_code)]

#[path = "app/config.rs"]
pub mod config;
#[path = "ops/disk.rs"]
pub mod disk;
/// Domain-owned engine worker modules and public engine transport catalog.
pub mod domains;
#[path = "ops/health.rs"]
pub mod health;
#[path = "app/metrics.rs"]
pub mod metrics;
pub mod onboarding;
pub mod platform;
pub mod runtime;
#[path = "app/server.rs"]
#[allow(clippy::module_inception)]
pub mod server;
pub mod shared;
#[path = "app/shutdown.rs"]
pub mod shutdown;
pub mod transport;
pub mod updater;
