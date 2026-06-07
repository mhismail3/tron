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

mod main_cli;
mod main_runtime;

use anyhow::Result;
use clap::Parser;

pub(crate) use main_cli::*;
pub(crate) use main_runtime::*;

#[tokio::main]
async fn main() -> Result<()> {
    let args = Cli::parse();
    if let Some(ref cmd) = args.command {
        return run_subcommand(cmd);
    }
    run_server(args).await
}

#[cfg(test)]
#[path = "main_tests.rs"]
mod tests;
