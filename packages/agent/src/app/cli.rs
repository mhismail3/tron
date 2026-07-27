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
    /// Verified profile backup and offline restoration.
    State {
        #[command(subcommand)]
        action: StateAction,
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
    }
}

fn notifications_auth_cli(action: &NotificationsAction) -> Result<()> {
    use crate::domains::auth::credentials::{
        NotificationRelayCredentials, NotificationTransportMode,
        clear_notification_relay_credentials, load_notification_push_config,
        save_notification_relay_credentials, set_notification_transport_mode,
    };

    let path = crate::app::lifecycle::onboarding::bearer_token_path();
    match action {
        NotificationsAction::ConfigureRelay { url, secret_file } => {
            let secret = std::fs::read_to_string(secret_file).with_context(|| {
                format!(
                    "Failed to read notification relay secret at {}",
                    secret_file.display()
                )
            })?;
            let config = save_notification_relay_credentials(
                &path,
                NotificationRelayCredentials {
                    url: url.trim().to_owned(),
                    secret: secret.trim().to_owned(),
                },
            )
            .context("Failed to save notification relay credentials")?;
            print_notification_transport_status(&path, Some(config))?;
            eprintln!("Notification relay configured and selected.");
            Ok(())
        }
        NotificationsAction::Status => {
            let config = load_notification_push_config(&path)
                .context("Failed to load notification transport configuration")?;
            print_notification_transport_status(&path, config)
        }
        NotificationsAction::Use { mode } => {
            let mode = match mode.as_str() {
                "relay" => NotificationTransportMode::Relay,
                "direct" => NotificationTransportMode::Direct,
                _ => bail!("Notification transport mode must be relay or direct"),
            };
            let config = set_notification_transport_mode(&path, mode)
                .context("Failed to select notification transport")?;
            print_notification_transport_status(&path, Some(config))?;
            eprintln!("Notification transport selected: {}.", mode.as_str());
            Ok(())
        }
        NotificationsAction::ClearRelay => {
            let changed = clear_notification_relay_credentials(&path)
                .context("Failed to clear notification relay credentials")?;
            let config = load_notification_push_config(&path)
                .context("Failed to reload notification transport configuration")?;
            print_notification_transport_status(&path, config)?;
            eprintln!(
                "Notification relay credentials {}.",
                if changed {
                    "cleared"
                } else {
                    "were not configured"
                }
            );
            Ok(())
        }
        NotificationsAction::ImportLegacyEnvironment => {
            if let Some(config) = load_notification_push_config(&path)
                .context("Failed to load notification transport configuration")?
            {
                print_notification_transport_status(&path, Some(config))?;
                return Ok(());
            }
            let url = std::env::var("TRON_RELAY_URL").unwrap_or_default();
            let secret = std::env::var("TRON_RELAY_SECRET").unwrap_or_default();
            ensure!(
                !url.is_empty() && !secret.is_empty(),
                "TRON_RELAY_URL and TRON_RELAY_SECRET must both be present for legacy import"
            );
            let config = save_notification_relay_credentials(
                &path,
                NotificationRelayCredentials { url, secret },
            )
            .context("Failed to import notification relay credentials")?;
            print_notification_transport_status(&path, Some(config))?;
            eprintln!("Legacy development notification relay configuration imported.");
            Ok(())
        }
    }
}

fn print_notification_transport_status(
    path: &Path,
    config: Option<crate::domains::auth::credentials::NotificationPushConfig>,
) -> Result<()> {
    use crate::domains::auth::credentials::{
        NotificationTransportMode, load_apple_push_credentials,
    };

    let direct_configured = load_apple_push_credentials(path)
        .context("Failed to load APNs credentials")?
        .is_some();
    let mode = config
        .as_ref()
        .map_or(NotificationTransportMode::Direct, |value| value.mode);
    println!(
        "{}",
        serde_json::to_string_pretty(&serde_json::json!({
            "mode":mode.as_str(),
            "relayConfigured":config.as_ref().and_then(|value| value.relay.as_ref()).is_some(),
            "directConfigured":direct_configured,
            "configured":match mode {
                NotificationTransportMode::Relay => config
                    .as_ref()
                    .and_then(|value| value.relay.as_ref())
                    .is_some(),
                NotificationTransportMode::Direct => direct_configured,
            },
        }))
        .context("Failed to encode notification transport status")?
    );
    Ok(())
}

fn apns_auth_cli(action: &ApnsAction) -> Result<()> {
    use crate::domains::auth::credentials::{
        ApplePushCredentials, clear_apple_push_credentials, load_apple_push_credentials,
        save_apple_push_credentials,
    };

    let path = crate::app::lifecycle::onboarding::bearer_token_path();
    match action {
        ApnsAction::Configure {
            team_id,
            key_id,
            private_key_file,
        } => {
            let private_key = std::fs::read_to_string(private_key_file).with_context(|| {
                format!(
                    "Failed to read APNs private key at {}",
                    private_key_file.display()
                )
            })?;
            let credentials = ApplePushCredentials {
                team_id: team_id.trim().to_owned(),
                key_id: key_id.trim().to_owned(),
                private_key,
            };
            credentials.validate().map_err(anyhow::Error::msg)?;
            crate::domains::worker_kernel::validate_apns_private_key(&credentials.private_key)
                .map_err(anyhow::Error::msg)?;
            save_apple_push_credentials(&path, &credentials)
                .context("Failed to save APNs credentials")?;
            println!(
                "{}",
                serde_json::to_string_pretty(&serde_json::json!({
                    "configured":true,
                    "teamId":credentials.team_id,
                    "keyId":credentials.key_id,
                }))
                .context("Failed to encode APNs status")?
            );
            eprintln!("APNs provider-token credentials configured.");
            Ok(())
        }
        ApnsAction::Status => {
            let credentials =
                load_apple_push_credentials(&path).context("Failed to load APNs credentials")?;
            println!(
                "{}",
                serde_json::to_string_pretty(&match credentials {
                    Some(credentials) => serde_json::json!({
                        "configured":true,
                        "teamId":credentials.team_id,
                        "keyId":credentials.key_id,
                    }),
                    None => serde_json::json!({"configured":false}),
                })
                .context("Failed to encode APNs status")?
            );
            Ok(())
        }
        ApnsAction::Clear => {
            let changed =
                clear_apple_push_credentials(&path).context("Failed to clear APNs credentials")?;
            println!(
                "{}",
                serde_json::to_string_pretty(
                    &serde_json::json!({"configured":false,"changed":changed})
                )
                .context("Failed to encode APNs clear status")?
            );
            eprintln!("APNs provider-token credentials cleared.");
            Ok(())
        }
    }
}

fn create_profile_snapshot_cli(for_worker_schema: Option<u32>) -> Result<()> {
    let snapshot = if let Some(target) = for_worker_schema {
        crate::domains::worker_kernel::prepare_worker_schema_snapshot(target)
            .map_err(anyhow::Error::msg)?
            .context("Worker-schema snapshot marker exists but no verified snapshot is available")?
    } else {
        crate::domains::worker_kernel::create_profile_snapshot().map_err(anyhow::Error::msg)?
    };
    println!(
        "{}",
        serde_json::to_string_pretty(&snapshot).context("Failed to encode snapshot report")?
    );
    eprintln!("Profile snapshot verified at {}.", snapshot.path.display());
    Ok(())
}

fn list_profile_snapshots_cli() -> Result<()> {
    for snapshot in
        crate::domains::worker_kernel::list_profile_snapshots().map_err(anyhow::Error::msg)?
    {
        println!("{}", snapshot.display());
    }
    Ok(())
}

fn verify_profile_snapshot_cli(snapshot: &Path) -> Result<()> {
    let report = crate::domains::worker_kernel::verify_profile_snapshot(snapshot)
        .map_err(anyhow::Error::msg)?;
    println!(
        "{}",
        serde_json::to_string_pretty(&report).context("Failed to encode snapshot report")?
    );
    eprintln!("Profile snapshot is valid.");
    Ok(())
}

fn restore_profile_snapshot_cli(snapshot: &Path) -> Result<()> {
    let database = crate::shared::foundation::paths::db_dir().join("tron.sqlite");
    let _offline_lock = crate::domains::session::event_store::acquire_database_lock(&database)
        .map_err(|error| anyhow::anyhow!("Tron must be stopped before profile restore: {error}"))?;
    let recovery = crate::domains::worker_kernel::restore_profile_snapshot(snapshot)
        .map_err(anyhow::Error::msg)?;
    println!("{}", recovery.display());
    eprintln!(
        "Profile restored. Replaced state is recoverable at {}.",
        recovery.display()
    );
    Ok(())
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
    fn apns_auth_actions_are_wired() {
        let cli = Cli::parse_from([
            "tron",
            "auth",
            "apns",
            "configure",
            "--team-id",
            "TEAM123456",
            "--key-id",
            "KEY1234567",
            "--private-key-file",
            "AuthKey.p8",
        ]);
        assert!(matches!(
            cli.command,
            Some(Command::Auth {
                action: AuthAction::Apns {
                    action: ApnsAction::Configure { .. }
                }
            })
        ));
    }

    #[test]
    fn notification_transport_auth_actions_are_wired() {
        let configure = Cli::parse_from([
            "tron",
            "auth",
            "notifications",
            "configure-relay",
            "--url",
            "https://relay.example.test",
            "--secret-file",
            "relay-secret",
        ]);
        assert!(matches!(
            configure.command,
            Some(Command::Auth {
                action: AuthAction::Notifications {
                    action: NotificationsAction::ConfigureRelay { .. }
                }
            })
        ));
        for mode in ["relay", "direct"] {
            let select = Cli::parse_from(["tron", "auth", "notifications", "use", mode]);
            assert!(matches!(
                select.command,
                Some(Command::Auth {
                    action: AuthAction::Notifications {
                        action: NotificationsAction::Use { mode: parsed }
                    }
                }) if parsed == mode
            ));
        }
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
