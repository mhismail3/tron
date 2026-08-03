//! CLI parsing, credential, snapshot, and OAuth tests.

use std::io::Cursor;
use std::sync::{Arc, Barrier};

use serde_json::json;

use super::oauth::{
    complete_oauth_from_reader_at, read_oauth_completion, save_oauth_tokens_at,
    validate_oauth_completion,
};
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
    let input = read_oauth_completion(Cursor::new(oauth_completion_input("manual", ""))).unwrap();
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
