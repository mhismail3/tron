//! CLI parsing and side-effect-limited subcommand dispatch for the `tron` binary.
//!
//! Server startup stays in `main_runtime.rs`; this module owns only the terminal
//! surface that can short-circuit before database, logging, or network startup.

use std::path::PathBuf;

use anyhow::{Context, Result};
use clap::Parser;

/// Tron agent — server and CLI capabilities.
#[derive(Parser, Debug)]
#[command(name = "tron", about = "Tron agent server and capability runtime")]
pub(crate) struct Cli {
    #[command(subcommand)]
    pub(crate) command: Option<Command>,

    /// Host to bind (server mode).
    ///
    /// INVARIANT: defaults to `0.0.0.0` under the trusted-local threat
    /// model — the iOS app reaches the daemon over Tailscale from the
    /// user's own devices. If that assumption shifts (shared network,
    /// multi-user host), flip this default to `127.0.0.1` and gate
    /// remote access behind explicit opt-in. The startup log line built
    /// by `format_listening_log` names the bind address so the operator
    /// can always see what network the server is exposed to.
    #[arg(long, default_value = "0.0.0.0", global = true)]
    pub(crate) host: String,

    /// Port to bind (server mode, 0 for auto-assign).
    #[arg(long, default_value = "9847", global = true)]
    pub(crate) port: u16,

    /// Path to the `SQLite` database (events + tasks in one file).
    #[arg(long, global = true)]
    pub(crate) db_path: Option<PathBuf>,

    /// Override database log level (trace, debug, info, warn, error).
    #[arg(long, global = true)]
    pub(crate) log_level: Option<String>,

    /// Suppress stderr logging (logs still persist to database).
    #[arg(long, global = true)]
    pub(crate) quiet: bool,
}

#[derive(clap::Subcommand, Debug)]
pub(crate) enum Command {
    /// Bearer-token administration for the WebSocket auth gate.
    ///
    /// Currently exposes a single `rotate` subcommand. Future operator
    /// surface (status, revoke-device, etc.) will live here so we don't
    /// pollute the top-level `tron` namespace.
    Auth {
        #[command(subcommand)]
        action: AuthAction,
    },
}

#[derive(clap::Subcommand, Debug)]
pub(crate) enum AuthAction {
    /// Generate a fresh bearer token, persist it to
    /// `~/.tron/profiles/auth.json` as `bearerToken` (atomic, 0o600), and print it
    /// to stdout. After this completes, every paired iOS device must
    /// re-pair (their cached token is invalidated).
    ///
    /// Safe to run while the server is up — `BearerTokenStore`'s mtime
    /// cache picks the new value up within a few seconds and starts
    /// rejecting upgrade requests carrying the old token with HTTP 401.
    Rotate,
}

/// Dispatch a CLI subcommand without starting the server.
///
/// Kept separate from `main` so the dispatch + side-effect surface stays
/// small and unit-testable. Each branch is responsible for printing a
/// human-readable result on stdout (the user is at a terminal) and a
/// single-line summary on stderr (so `--quiet` redirection still leaves
/// the audit trail visible).
pub(crate) fn run_subcommand(cmd: &Command) -> Result<()> {
    match cmd {
        Command::Auth { action } => match action {
            AuthAction::Rotate => rotate_bearer_token_cli(),
        },
    }
}

fn rotate_bearer_token_cli() -> Result<()> {
    let path = tron::app::onboarding::bearer_token_path();
    let token = tron::app::onboarding::rotate_bearer_token(&path)
        .with_context(|| format!("Failed to rotate bearer token at {}", path.display()))?;
    eprintln!("Bearer token rotated. All paired iOS devices must re-pair with the new token.");
    println!("{token}");
    Ok(())
}
