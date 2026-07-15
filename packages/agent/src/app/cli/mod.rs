//! CLI parsing and side-effect-limited subcommand dispatch for the `tron` binary.
//!
//! Server startup stays in [`crate::app::bootstrap`]; this module owns only the
//! terminal surface that can short-circuit before database, logging, or network
//! startup.

use std::io::Read;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail, ensure};
use clap::Parser;

/// Tron agent — server and CLI capabilities.
#[derive(Parser, Debug)]
#[command(name = "tron", about = "Tron agent server and capability runtime")]
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
    /// The operator-visible surface exposes token rotation. A hidden
    /// stdin-only bridge lets the contributor OAuth flow persist through the
    /// same locked Rust storage owner without putting credentials in argv.
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
    /// Internal stdin bridge for the contributor shell OAuth callback.
    #[command(name = "store-oauth", hide = true)]
    StoreOauth,
}

#[derive(Debug)]
struct OAuthCredentialInput {
    provider: String,
    label: String,
    access_token: String,
    refresh_token: String,
    expires_at: i64,
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
            AuthAction::StoreOauth => store_oauth_cli(),
        },
    }
}

fn rotate_bearer_token_cli() -> Result<()> {
    let path = crate::app::lifecycle::onboarding::bearer_token_path();
    let token = crate::app::lifecycle::onboarding::rotate_bearer_token(&path)
        .with_context(|| format!("Failed to rotate bearer token at {}", path.display()))?;
    eprintln!("Bearer token rotated. All paired iOS devices must re-pair with the new token.");
    println!("{token}");
    Ok(())
}

fn store_oauth_cli() -> Result<()> {
    let stdin = std::io::stdin();
    store_oauth_from_reader_at(
        &crate::app::lifecycle::onboarding::bearer_token_path(),
        stdin.lock(),
    )
}

fn store_oauth_from_reader_at(path: &Path, mut reader: impl Read) -> Result<()> {
    let mut raw = Vec::new();
    reader
        .read_to_end(&mut raw)
        .context("Failed to read OAuth credentials from stdin")?;
    let input = (|| -> Result<OAuthCredentialInput> {
        let payload = raw
            .strip_suffix(&[0])
            .context("OAuth credential input must end with a NUL delimiter")?;
        let fields = payload.split(|byte| *byte == 0).collect::<Vec<_>>();
        let [provider, label, access_token, refresh_token, expires_at] = fields.as_slice() else {
            bail!("OAuth credential input must contain exactly five NUL-delimited fields");
        };
        let decode = |field: &[u8], name: &str| -> Result<String> {
            String::from_utf8(field.to_vec())
                .with_context(|| format!("OAuth {name} must be valid UTF-8"))
        };
        Ok(OAuthCredentialInput {
            provider: decode(provider, "provider")?,
            label: decode(label, "label")?,
            access_token: decode(access_token, "access token")?,
            refresh_token: decode(refresh_token, "refresh token")?,
            expires_at: decode(expires_at, "expiry")?
                .parse()
                .context("OAuth expiry must be a signed integer")?,
        })
    })();
    raw.fill(0);
    let input = input?;
    match input.provider.as_str() {
        "anthropic" | "openai-codex" => {}
        unsupported => bail!("Unsupported OAuth provider: {unsupported}"),
    }
    ensure!(
        !input.label.trim().is_empty(),
        "OAuth label must not be empty"
    );
    ensure!(
        !input.access_token.trim().is_empty(),
        "OAuth access token must not be empty"
    );
    ensure!(input.expires_at > 0, "OAuth expiry must be positive");

    let _lock = crate::domains::auth::credentials::acquire_auth_file_lock(path)
        .with_context(|| format!("Failed to lock auth storage at {}", path.display()))?;
    let initialized = crate::domains::auth::credentials::load_auth_storage(path)
        .with_context(|| format!("Failed to load auth storage at {}", path.display()))?
        .and_then(|storage| storage.bearer_token)
        .is_some_and(|token| !token.trim().is_empty());
    ensure!(
        initialized,
        "Auth storage is not initialized; start the Tron server once and retry login"
    );

    crate::domains::auth::credentials::storage::save_account_oauth_tokens(
        path,
        &input.provider,
        &input.label,
        &crate::domains::auth::credentials::OAuthTokens {
            access_token: input.access_token,
            refresh_token: input.refresh_token,
            expires_at: input.expires_at,
        },
    )
    .with_context(|| format!("Failed to persist OAuth credentials at {}", path.display()))
}

#[cfg(test)]
mod tests {
    use std::io::Cursor;
    use std::sync::{Arc, Barrier};

    use serde_json::json;

    use super::*;
    use crate::domains::auth::credentials::{AuthStorage, load_auth_storage, save_auth_storage};

    fn initialized_auth(path: &Path) {
        let mut storage = AuthStorage::new();
        storage.bearer_token = Some("existing-bearer".into());
        save_auth_storage(path, &mut storage).unwrap();
    }

    fn oauth_input() -> Vec<u8> {
        let mut input = Vec::new();
        for field in [
            "anthropic",
            "shell-login",
            "access-token",
            "refresh-token",
            "4102444800000",
        ] {
            input.extend_from_slice(field.as_bytes());
            input.push(0);
        }
        input
    }

    #[test]
    fn hidden_oauth_store_action_is_wired() {
        let cli = Cli::parse_from(["tron", "auth", "store-oauth"]);
        assert!(matches!(
            cli.command,
            Some(Command::Auth {
                action: AuthAction::StoreOauth
            })
        ));
    }

    #[test]
    fn oauth_store_rereads_after_canonical_auth_lock() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("profiles/auth.json");
        initialized_auth(&path);

        let lock = crate::domains::auth::credentials::acquire_auth_file_lock(&path).unwrap();
        let barrier = Arc::new(Barrier::new(2));
        let thread_path = path.clone();
        let thread_barrier = Arc::clone(&barrier);
        let writer = std::thread::spawn(move || {
            thread_barrier.wait();
            store_oauth_from_reader_at(&thread_path, Cursor::new(oauth_input())).unwrap();
        });
        barrier.wait();

        let mut concurrent = load_auth_storage(&path).unwrap().unwrap();
        concurrent
            .extra
            .insert("concurrentMarker".into(), json!("preserved"));
        save_auth_storage(&path, &mut concurrent).unwrap();
        drop(lock);
        writer.join().unwrap();

        let stored = load_auth_storage(&path).unwrap().unwrap();
        assert_eq!(stored.extra["concurrentMarker"], "preserved");
        assert_eq!(stored.bearer_token.as_deref(), Some("existing-bearer"));
        let provider = stored.get_provider_auth("anthropic").unwrap();
        assert_eq!(provider.accounts.unwrap()[0].label, "shell-login");
    }

    #[test]
    fn oauth_store_requires_server_initialized_auth() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("profiles/auth.json");
        let mut storage = AuthStorage::new();
        save_auth_storage(&path, &mut storage).unwrap();

        let error = store_oauth_from_reader_at(&path, Cursor::new(oauth_input())).unwrap_err();

        assert!(error.to_string().contains("not initialized"));
    }
}
