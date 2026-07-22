//! CLI parsing and side-effect-limited subcommand dispatch for the `tron` binary.
//!
//! Server startup stays in [`crate::app::bootstrap`]; this module owns only the
//! terminal surface that can short-circuit before database, logging, or network
//! startup.

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
    /// Internal provider-policy bridge for the contributor OAuth shell.
    #[command(name = "begin-oauth", hide = true)]
    BeginOauth { provider: String },
    /// Internal stdin-only exchange bridge for the contributor OAuth shell.
    #[command(name = "complete-oauth", hide = true)]
    CompleteOauth,
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
            AuthAction::BeginOauth { provider } => begin_oauth_cli(provider),
            AuthAction::CompleteOauth => complete_oauth_cli().await,
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

fn begin_oauth_cli(provider: &str) -> Result<()> {
    ensure!(
        matches!(provider, "anthropic" | "openai-codex"),
        "Contributor OAuth supports anthropic and openai-codex"
    );
    let path = crate::app::lifecycle::onboarding::bearer_token_path();
    let flow = crate::domains::auth::oauth::flows::prepare_oauth_flow_with_state(provider, &path)
        .context("Failed to prepare contributor OAuth")?
        .context("Contributor OAuth supports anthropic and openai-codex")?;
    let state = flow
        .state
        .context("Contributor OAuth flow did not include callback state")?;
    println!(
        "{}\t{}\t{}\t{}",
        flow.verifier, state, flow.auth_url, flow.redirect_uri
    );
    Ok(())
}

async fn complete_oauth_cli() -> Result<()> {
    let stdin = std::io::stdin();
    complete_oauth_from_reader_at(
        &crate::app::lifecycle::onboarding::bearer_token_path(),
        stdin.lock(),
    )
    .await
}

fn read_nul_fields<const N: usize>(
    mut reader: impl Read,
    description: &str,
) -> Result<[String; N]> {
    let mut raw = Vec::new();
    reader
        .read_to_end(&mut raw)
        .with_context(|| format!("Failed to read {description} from stdin"))?;
    let fields = (|| -> Result<[String; N]> {
        let payload = raw
            .strip_suffix(&[0])
            .with_context(|| format!("{description} input must end with a NUL delimiter"))?;
        let decoded = payload
            .split(|byte| *byte == 0)
            .map(|field| {
                String::from_utf8(field.to_vec())
                    .with_context(|| format!("{description} fields must be valid UTF-8"))
            })
            .collect::<Result<Vec<_>>>()?;
        decoded.try_into().map_err(|values: Vec<String>| {
            anyhow::anyhow!(
                "{description} input must contain exactly {N} NUL-delimited fields; got {}",
                values.len()
            )
        })
    })();
    raw.fill(0);
    fields
}

fn read_oauth_completion(reader: impl Read) -> Result<OAuthCompletionInput> {
    let [
        provider,
        label,
        code,
        verifier,
        expected_state,
        completion_kind,
        returned_state,
    ] = read_nul_fields(reader, "OAuth completion")?;
    Ok(OAuthCompletionInput {
        provider,
        label,
        code,
        verifier,
        expected_state,
        completion_kind,
        returned_state,
    })
}

fn auth_storage_is_initialized(path: &Path) -> Result<bool> {
    let initialized = crate::domains::auth::oauth::contributor_auth_storage_is_initialized(path)
        .with_context(|| format!("Failed to load auth storage at {}", path.display()))?;
    Ok(initialized)
}

fn save_oauth_tokens_at(
    path: &Path,
    provider: &str,
    label: &str,
    tokens: &crate::domains::auth::credentials::OAuthTokens,
) -> Result<()> {
    ensure!(
        crate::domains::auth::oauth::save_contributor_oauth_tokens(path, provider, label, tokens,)
            .with_context(|| format!(
                "Failed to persist OAuth credentials at {}",
                path.display()
            ))?,
        "Auth storage is not initialized; start the Tron server once and retry login"
    );
    Ok(())
}

async fn complete_oauth_from_reader_at(path: &Path, reader: impl Read) -> Result<()> {
    let input = read_oauth_completion(reader)?;
    validate_oauth_completion(&input)?;
    ensure!(
        auth_storage_is_initialized(path)?,
        "Auth storage is not initialized; start the Tron server once and retry login"
    );

    let tokens = crate::domains::auth::oauth::flows::exchange_oauth_code(
        &input.provider,
        path,
        &input.code,
        &input.verifier,
        Some(&input.expected_state),
    )
    .await
    .context("OAuth authorization code exchange failed")?
    .context("Contributor OAuth supports anthropic and openai-codex")?;
    let expires_at = tokens.expires_at;
    save_oauth_tokens_at(path, &input.provider, &input.label, &tokens)?;
    println!("{expires_at}");
    Ok(())
}

fn validate_oauth_completion(input: &OAuthCompletionInput) -> Result<()> {
    ensure!(
        matches!(input.provider.as_str(), "anthropic" | "openai-codex"),
        "Contributor OAuth supports anthropic and openai-codex"
    );
    ensure!(
        !input.label.trim().is_empty(),
        "OAuth label must not be empty"
    );
    ensure!(
        !input.code.trim().is_empty(),
        "OAuth authorization code must not be empty"
    );
    ensure!(
        !input.verifier.trim().is_empty(),
        "OAuth verifier must not be empty"
    );
    ensure!(
        !input.expected_state.trim().is_empty(),
        "OAuth expected state must not be empty"
    );
    match input.completion_kind.as_str() {
        "callback" => ensure!(
            input.returned_state == input.expected_state,
            "OAuth state parameter mismatch; refusing authorization code exchange"
        ),
        "manual" => {
            ensure!(
                input.provider == "anthropic",
                "Manual OAuth completion is supported only for Anthropic"
            );
            ensure!(
                input.returned_state.is_empty(),
                "Manual OAuth completion must not synthesize callback state"
            );
        }
        _ => bail!("OAuth completion kind must be callback or manual"),
    }
    Ok(())
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

    fn oauth_completion_input(completion_kind: &str, returned_state: &str) -> Vec<u8> {
        let mut input = Vec::new();
        for field in [
            "anthropic",
            "shell-login",
            "authorization-code",
            "pkce-verifier",
            "csrf-state",
            completion_kind,
            returned_state,
        ] {
            input.extend_from_slice(field.as_bytes());
            input.push(0);
        }
        input
    }

    #[test]
    fn hidden_oauth_actions_are_wired() {
        let cli = Cli::parse_from(["tron", "auth", "begin-oauth", "anthropic"]);
        assert!(matches!(
            cli.command,
            Some(Command::Auth {
                action: AuthAction::BeginOauth { provider }
            }) if provider == "anthropic"
        ));
        let cli = Cli::parse_from(["tron", "auth", "complete-oauth"]);
        assert!(matches!(
            cli.command,
            Some(Command::Auth {
                action: AuthAction::CompleteOauth
            })
        ));
    }

    #[test]
    fn oauth_save_rereads_after_canonical_auth_lock() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("auth.json");
        initialized_auth(&path);

        let lock = crate::domains::auth::credentials::acquire_auth_file_lock(&path).unwrap();
        let barrier = Arc::new(Barrier::new(2));
        let thread_path = path.clone();
        let thread_barrier = Arc::clone(&barrier);
        let writer = std::thread::spawn(move || {
            thread_barrier.wait();
            save_oauth_tokens_at(
                &thread_path,
                "anthropic",
                "shell-login",
                &crate::domains::auth::credentials::OAuthTokens {
                    access_token: "access-token".into(),
                    refresh_token: "refresh-token".into(),
                    expires_at: 4_102_444_800_000,
                },
            )
            .unwrap();
        });
        barrier.wait();

        let mut concurrent = load_auth_storage(&path).unwrap().unwrap();
        concurrent
            .providers
            .insert("concurrent-test".into(), json!({"marker":"preserved"}));
        save_auth_storage(&path, &mut concurrent).unwrap();
        drop(lock);
        writer.join().unwrap();

        let stored = load_auth_storage(&path).unwrap().unwrap();
        assert_eq!(stored.providers["concurrent-test"]["marker"], "preserved");
        assert_eq!(stored.bearer_token.as_deref(), Some("existing-bearer"));
        let provider = stored.get_provider_auth("anthropic").unwrap();
        assert_eq!(provider.accounts.unwrap()[0].label, "shell-login");
    }

    #[tokio::test]
    async fn oauth_completion_requires_matching_state_before_exchange() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("auth.json");
        initialized_auth(&path);

        let error = complete_oauth_from_reader_at(
            &path,
            Cursor::new(oauth_completion_input("callback", "wrong-state")),
        )
        .await
        .unwrap_err();

        assert!(error.to_string().contains("state parameter mismatch"));
        assert!(
            load_auth_storage(&path)
                .unwrap()
                .unwrap()
                .get_provider_auth("anthropic")
                .is_none()
        );
    }

    #[test]
    fn manual_oauth_completion_is_explicit_and_has_no_callback_state() {
        let input =
            read_oauth_completion(Cursor::new(oauth_completion_input("manual", ""))).unwrap();
        validate_oauth_completion(&input).unwrap();

        let error = read_oauth_completion(Cursor::new(oauth_completion_input(
            "manual",
            "synthesized-state",
        )))
        .and_then(|input| validate_oauth_completion(&input))
        .unwrap_err();
        assert!(error.to_string().contains("must not synthesize"));

        let mut openai =
            read_oauth_completion(Cursor::new(oauth_completion_input("manual", ""))).unwrap();
        openai.provider = "openai-codex".into();
        let error = validate_oauth_completion(&openai).unwrap_err();
        assert!(error.to_string().contains("only for Anthropic"));
    }

    #[test]
    fn oauth_save_requires_server_initialized_auth() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("auth.json");
        let mut storage = AuthStorage::new();
        save_auth_storage(&path, &mut storage).unwrap();

        let error = save_oauth_tokens_at(
            &path,
            "anthropic",
            "shell-login",
            &crate::domains::auth::credentials::OAuthTokens {
                access_token: "access-token".into(),
                refresh_token: "refresh-token".into(),
                expires_at: 4_102_444_800_000,
            },
        )
        .unwrap_err();

        assert!(error.to_string().contains("not initialized"));
    }
}
