//! CLI parsing and side-effect-limited subcommand dispatch for the `tron` binary.
//!
//! Server startup stays in [`crate::app::bootstrap`]; this module owns only the
//! terminal surface that can short-circuit before database, logging, or network
//! startup.
//! `notifications` owns relay/direct APNs configuration, `oauth` owns bearer
//! rotation and contributor OAuth completion, and `snapshots` owns offline
//! profile snapshot operations. All three route through this single parser and
//! dispatcher; none starts the server or maintains another command registry.

use std::io::Read;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail, ensure};
use clap::Parser;

/// Tron agent — server and offline operator commands.
#[derive(Parser, Debug)]
#[command(name = "tron", about = "Tron agent server and worker runtime")]
pub struct Cli {
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

    /// Suppress stderr logging (logs still persist to database).
    #[arg(long, global = true)]
    pub(crate) quiet: bool,
}

#[derive(clap::Subcommand, Debug)]
pub(crate) enum Command {
    /// Local authentication administration.
    ///
    /// The operator-visible surface exposes token rotation. Hidden actions let
    /// the contributor shell retain terminal/browser UX while Rust owns OAuth
    /// provider policy, exchange, and locked persistence.
    Auth {
        #[command(subcommand)]
        action: AuthAction,
    },
    /// Verified profile backup and offline restoration.
    State {
        #[command(subcommand)]
        action: StateAction,
    },
    /// Chrome-owned closed Native Messaging host for the Browser Operator.
    #[command(name = "browser-native-host", hide = true)]
    BrowserNativeHost {
        /// Owner-only Unix socket used by the ordinary Browser Operator worker.
        #[arg(long)]
        socket: PathBuf,
    },
}

#[derive(clap::Subcommand, Debug)]
pub(crate) enum StateAction {
    /// Create and verify an owner-only compressed profile snapshot.
    Snapshot {
        /// Also mark this as the required backup before a worker schema opens.
        #[arg(long, hide = true)]
        for_worker_schema: Option<u32>,
    },
    /// List available profile snapshot archives.
    Snapshots,
    /// Verify one snapshot without changing active state.
    Verify { snapshot: PathBuf },
    /// Restore one verified snapshot. Tron must be stopped.
    Restore { snapshot: PathBuf },
}

#[derive(clap::Subcommand, Debug)]
pub(crate) enum AuthAction {
    /// Generate a fresh bearer token, persist it to
    /// `~/.tron/auth.json` as `bearerToken` (atomic, 0o600), and print it
    /// to stdout. After this completes, every paired iOS device must
    /// re-pair (their cached token is invalidated).
    ///
    /// Safe to run while the server is up — `BearerTokenStore`'s mtime
    /// cache picks the new value up within a few seconds and starts
    /// rejecting upgrade requests carrying the old token with HTTP 401.
    Rotate,
    /// Configure, inspect, or clear Apple Push provider-token credentials.
    Apns {
        #[command(subcommand)]
        action: ApnsAction,
    },
    /// Configure, inspect, or select native-notification transport.
    Notifications {
        #[command(subcommand)]
        action: NotificationsAction,
    },
    /// Internal provider-policy bridge for the contributor OAuth shell.
    #[command(name = "begin-oauth", hide = true)]
    BeginOauth { provider: String },
    /// Internal stdin-only exchange bridge for the contributor OAuth shell.
    #[command(name = "complete-oauth", hide = true)]
    CompleteOauth,
}

#[derive(clap::Subcommand, Debug)]
pub(crate) enum ApnsAction {
    /// Store an Apple team ID, key ID, and PKCS#8 `.p8` private key.
    Configure {
        #[arg(long)]
        team_id: String,
        #[arg(long)]
        key_id: String,
        #[arg(long)]
        private_key_file: PathBuf,
    },
    /// Print a redacted APNs configuration status.
    Status,
    /// Remove APNs provider-token credentials.
    Clear,
}

#[derive(clap::Subcommand, Debug)]
pub(crate) enum NotificationsAction {
    /// Store Cloudflare notification-relay credentials and select relay mode.
    ConfigureRelay {
        #[arg(long)]
        url: String,
        #[arg(long)]
        secret_file: PathBuf,
    },
    /// Print redacted relay/direct transport readiness.
    Status,
    /// Select relay or direct transport without copying credentials.
    Use { mode: String },
    /// Remove relay credentials and select direct transport.
    ClearRelay,
    /// Import the contributor development relay environment once.
    #[command(name = "import-legacy-environment", hide = true)]
    ImportLegacyEnvironment,
}

#[derive(Debug)]
struct OAuthCompletionInput {
    provider: String,
    label: String,
    code: String,
    verifier: String,
    expected_state: String,
    completion_kind: String,
    returned_state: String,
}

/// Dispatch a CLI subcommand without starting the server.
///
/// Kept separate from `main` so the dispatch + side-effect surface stays
/// small and unit-testable. Each branch is responsible for printing a
/// human-readable result on stdout (the user is at a terminal) and a
/// single-line summary on stderr (so `--quiet` redirection still leaves
/// the audit trail visible).
pub(crate) async fn run_subcommand(cmd: &Command) -> Result<()> {
    match cmd {
        Command::Auth { action } => match action {
            AuthAction::Rotate => rotate_bearer_token_cli(),
            AuthAction::Apns { action } => apns_auth_cli(action),
            AuthAction::Notifications { action } => notifications_auth_cli(action),
            AuthAction::BeginOauth { provider } => begin_oauth_cli(provider),
            AuthAction::CompleteOauth => complete_oauth_cli().await,
        },
        Command::State { action } => match action {
            StateAction::Snapshot { for_worker_schema } => {
                create_profile_snapshot_cli(*for_worker_schema)
            }
            StateAction::Snapshots => list_profile_snapshots_cli(),
            StateAction::Verify { snapshot } => verify_profile_snapshot_cli(snapshot),
            StateAction::Restore { snapshot } => restore_profile_snapshot_cli(snapshot),
        },
        Command::BrowserNativeHost { socket } => {
            crate::app::browser_operator::run_native_host(socket).await
        }
    }
}

mod notifications;
mod oauth;
mod snapshots;

use notifications::{apns_auth_cli, notifications_auth_cli};
use oauth::{begin_oauth_cli, complete_oauth_cli, rotate_bearer_token_cli};
use snapshots::{
    create_profile_snapshot_cli, list_profile_snapshots_cli, restore_profile_snapshot_cli,
    verify_profile_snapshot_cli,
};

#[cfg(test)]
mod tests;
