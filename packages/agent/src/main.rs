//! # tron
//!
//! Tron agent server binary — wires together all modules and starts the
//! HTTP/WebSocket server.
//!
//! ## Module Architecture
//!
//! ```text
//! tron::app           Bootstrap, HTTP shell, health, metrics, onboarding, shutdown
//! tron::transport     /engine and /engine/workers protocol surfaces
//! tron::engine        Live capability fabric, host lifecycle, engine ledger
//! tron::domains       Worker-owned contracts, handlers, operations, services
//! tron::platform      OS/vendor integrations retained by the primitive loop
//! tron::shared        Foundation types, protocol DTOs, neutral helpers
//! ```
//!
//! ## Data Path
//!
//! 1. Client connects to `/engine` and sends engine protocol messages
//! 2. `transport` translates each message into the engine transport envelope
//! 3. Canonical `namespace::function` capabilities call domain services
//! 4. Engine streams publish live events and `/engine` subscriptions deliver them
//!
//! ## Core Invariants
//!
//! 1. Canonical internal model per concept; iOS adaptation is boundary-only
//! 2. Unknown model/provider → fail-fast typed error (no implicit substitution)
//! 3. Event reconstruction is deterministic from persisted events
//! 4. Session writes are serialized per-session via in-process locks
//! 5. `agent.filesystem_ready` is emitted AFTER `agent.complete` (iOS send button)
//! 6. Compaction always runs before ledger writing (deterministic DB ordering)
//! 7. DB target is strictly `<resolved-tron-home>/internal/database/tron.sqlite`
//! 8. Server shutdown is signal-owned (`SIGINT`/`SIGTERM` on Unix) so managed
//!    children are stopped before Tron exits.

#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

use anyhow::Result;
use clap::Parser;

#[tokio::main]
async fn main() -> Result<()> {
    tron::app::bootstrap::run(tron::app::cli::Cli::parse()).await
}
