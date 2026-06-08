use super::*;

#[test]
fn provider_key_is_openai_codex() {
    assert_eq!(PROVIDER_KEY, "openai-codex");
}

#[test]
fn infer_auth_path_prefers_active_credential() {
    let provider_auth = ProviderAuth {
        accounts: Some(vec![super::super::types::AccountEntry {
            label: "chatgpt".into(),
            oauth: OAuthTokens {
                access_token: "tok".into(),
                refresh_token: "ref".into(),
                expires_at: now_ms() + 3_600_000,
            },
        }]),
        api_keys: Some(vec![super::super::types::ApiKeyEntry {
            label: "platform".into(),
            key: "sk-test".into(),
        }]),
        active_credential: Some(ActiveCredential::ApiKey {
            label: "platform".into(),
        }),
    };

    assert_eq!(
        infer_auth_path_from_provider_auth(&provider_auth, None),
        Some(OpenAIAuthPath::PlatformApiKey)
    );
}

#[test]
fn infer_auth_path_default_prefers_oauth_before_api_key() {
    let provider_auth = ProviderAuth {
        accounts: Some(vec![super::super::types::AccountEntry {
            label: "chatgpt".into(),
            oauth: OAuthTokens {
                access_token: "tok".into(),
                refresh_token: "ref".into(),
                expires_at: now_ms() + 3_600_000,
            },
        }]),
        api_keys: Some(vec![super::super::types::ApiKeyEntry {
            label: "platform".into(),
            key: "sk-test".into(),
        }]),
        active_credential: None,
    };

    assert_eq!(
        infer_auth_path_from_provider_auth(&provider_auth, None),
        Some(OpenAIAuthPath::ChatGptCodex)
    );
}

// ─── default_config tests ───────────────────────────────────────────

#[test]
fn default_config_values() {
    let cfg = default_config();
    assert!(cfg.auth_url.contains("auth.openai.com"));
    assert!(cfg.token_url.contains("auth.openai.com"));
    assert_eq!(cfg.client_id, "app_EMoamEEZ73f0CkXaXp7hrann");
    assert!(cfg.client_secret.is_none());
    assert!(cfg.scopes.contains(&"openid".to_string()));
    assert!(cfg.scopes.contains(&"profile".to_string()));
    assert!(cfg.scopes.contains(&"email".to_string()));
    assert!(cfg.scopes.contains(&"offline_access".to_string()));
    assert_eq!(cfg.token_expiry_buffer_seconds, 300);
}

// ─── authorization URL tests ────────────────────────────────────────

#[test]
fn authorization_url_contains_required_params() {
    let cfg = default_config();
    let url = get_authorization_url(&cfg, "challenge123");
    assert!(url.contains("response_type=code"));
    assert!(url.contains(&cfg.client_id));
    assert!(url.contains("redirect_uri="));
    assert!(url.contains("scope="));
    assert!(url.contains("code_challenge=challenge123"));
    assert!(url.contains("code_challenge_method=S256"));
}

#[test]
fn authorization_url_with_state() {
    let cfg = default_config();
    let url = get_authorization_url_with_state(&cfg, "challenge", Some("my-state-123"));
    assert!(url.contains("state=my-state-123"));
}

#[test]
fn authorization_url_without_state() {
    let cfg = default_config();
    let url = get_authorization_url_with_state(&cfg, "challenge", None);
    assert!(!url.contains("state="));
}

#[test]
fn authorization_url_starts_with_auth_endpoint() {
    let cfg = default_config();
    let url = get_authorization_url(&cfg, "challenge");
    assert!(url.starts_with("https://auth.openai.com/oauth/authorize?"));
}

// ─── load_server_auth ────────────────────────────────────────────────

#[tokio::test]
async fn load_server_auth_oauth_from_file() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("auth.json");

    let tokens = OAuthTokens {
        access_token: "oauth-from-file".to_string(),
        refresh_token: "ref".to_string(),
        expires_at: now_ms() + 3_600_000,
    };
    crate::domains::auth::credentials::storage::save_account_oauth_tokens(
        &path,
        PROVIDER_KEY,
        "test",
        &tokens,
    )
    .unwrap();

    let result = load_server_auth(&path).await.unwrap();
    let auth = result.unwrap();
    assert!(auth.is_oauth());
    assert_eq!(auth.token(), "oauth-from-file");
}

#[tokio::test]
async fn load_server_auth_api_key_from_file() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("auth.json");

    crate::domains::auth::credentials::storage::save_named_api_key(
        &path,
        PROVIDER_KEY,
        "(default)",
        "sk-file-key",
    )
    .unwrap();

    let result = load_server_auth(&path).await.unwrap();
    let auth = result.unwrap();
    assert_eq!(auth.token(), "sk-file-key");
}

#[tokio::test]
async fn load_server_auth_none_when_empty() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("auth.json");

    let result = load_server_auth(&path).await.unwrap();
    assert!(result.is_none());
}

#[tokio::test]
async fn load_server_auth_fresh_oauth() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("auth.json");

    let tokens = OAuthTokens {
        access_token: "fresh-openai-tok".to_string(),
        refresh_token: "ref".to_string(),
        expires_at: now_ms() + 3_600_000,
    };
    crate::domains::auth::credentials::storage::save_account_oauth_tokens(
        &path,
        PROVIDER_KEY,
        "test",
        &tokens,
    )
    .unwrap();

    let result = load_server_auth(&path).await.unwrap();
    let auth = result.unwrap();
    assert!(auth.is_oauth());
    assert_eq!(auth.token(), "fresh-openai-tok");
}

// ─── load_server_auth: accounts support ─────────────────────────────

#[tokio::test]
async fn load_server_auth_uses_first_account() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("auth.json");

    let tokens1 = OAuthTokens {
        access_token: "work-tok".to_string(),
        refresh_token: "ref1".to_string(),
        expires_at: now_ms() + 3_600_000,
    };
    let tokens2 = OAuthTokens {
        access_token: "personal-tok".to_string(),
        refresh_token: "ref2".to_string(),
        expires_at: now_ms() + 3_600_000,
    };
    crate::domains::auth::credentials::storage::save_account_oauth_tokens(
        &path,
        PROVIDER_KEY,
        "work",
        &tokens1,
    )
    .unwrap();
    crate::domains::auth::credentials::storage::save_account_oauth_tokens(
        &path,
        PROVIDER_KEY,
        "personal",
        &tokens2,
    )
    .unwrap();

    let result = load_server_auth(&path).await.unwrap();
    let auth = result.unwrap();
    assert!(auth.is_oauth());
    assert_eq!(auth.token(), "work-tok");
}

#[tokio::test]
async fn load_server_auth_single_account() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("auth.json");

    let tokens = OAuthTokens {
        access_token: "tok-alice".to_string(),
        refresh_token: "ref-alice".to_string(),
        expires_at: now_ms() + 3_600_000,
    };
    crate::domains::auth::credentials::storage::save_account_oauth_tokens(
        &path,
        PROVIDER_KEY,
        "alice",
        &tokens,
    )
    .unwrap();

    let result = load_server_auth(&path).await.unwrap();
    let auth = result.unwrap();
    assert!(auth.is_oauth());
    assert_eq!(auth.token(), "tok-alice");
}

#[tokio::test]
async fn load_server_auth_oauth_failure_does_not_use_api_key_default() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("auth.json");

    // Save expired OAuth account (will fail to refresh without network)
    let expired = OAuthTokens {
        access_token: "expired-tok".to_string(),
        refresh_token: "old-ref".to_string(),
        expires_at: 0, // long expired
    };
    crate::domains::auth::credentials::storage::save_account_oauth_tokens(
        &path,
        PROVIDER_KEY,
        "test",
        &expired,
    )
    .unwrap();
    // Also save an API key (should NOT be used as the default while OAuth is present).
    crate::domains::auth::credentials::storage::save_named_api_key(
        &path,
        PROVIDER_KEY,
        "(default)",
        "sk-should-not-use",
    )
    .unwrap();

    let result = load_server_auth(&path).await;

    // Should return Err (OAuth refresh failed), NOT Ok(Some(ApiKey))
    assert!(
        result.is_err(),
        "expected Err when OAuth refresh fails, got: {result:?}"
    );
}

// ─── read_tokens_from_disk ──────────────────────────────────────────

#[test]
fn read_tokens_from_disk_account() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("auth.json");

    let tokens = OAuthTokens {
        access_token: "disk-tok".to_string(),
        refresh_token: "disk-ref".to_string(),
        expires_at: now_ms() + 3_600_000,
    };
    crate::domains::auth::credentials::storage::save_account_oauth_tokens(
        &path,
        PROVIDER_KEY,
        "user@host",
        &tokens,
    )
    .unwrap();

    let loaded = read_tokens_from_disk(&path, "user@host").unwrap();
    assert_eq!(loaded.access_token, "disk-tok");

    assert!(read_tokens_from_disk(&path, "nonexistent").is_none());
}

// ─── stale token detection ──────────────────────────────────────────

#[test]
fn stale_token_error_detected() {
    let err = AuthError::OAuth {
        status: 400,
        message: r#"{"error":"invalid_grant"}"#.to_string(),
    };
    assert!(is_stale_token_error(&err));
}

#[test]
fn non_stale_errors_not_detected() {
    assert!(!is_stale_token_error(&AuthError::OAuth {
        status: 400,
        message: "bad_request".to_string(),
    }));
    assert!(!is_stale_token_error(&AuthError::OAuth {
        status: 401,
        message: "invalid_grant".to_string(),
    }));
    assert!(!is_stale_token_error(&AuthError::OAuth {
        status: 503,
        message: "server_error".to_string(),
    }));
    assert!(!is_stale_token_error(&AuthError::Io(
        std::io::Error::other("test",)
    )));
}

// ─── maybe_refresh_tokens with disk re-read ─────────────────────────

#[tokio::test]
async fn maybe_refresh_uses_disk_tokens_after_lock() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("auth.json");

    // Write expired tokens initially
    let expired = OAuthTokens {
        access_token: "expired-tok".to_string(),
        refresh_token: "old-ref".to_string(),
        expires_at: 0,
    };
    crate::domains::auth::credentials::storage::save_account_oauth_tokens(
        &path,
        PROVIDER_KEY,
        "user@host",
        &expired,
    )
    .unwrap();

    // Simulate another process having refreshed: write fresh tokens to disk
    let fresh = OAuthTokens {
        access_token: "fresh-tok".to_string(),
        refresh_token: "new-ref".to_string(),
        expires_at: now_ms() + 3_600_000,
    };
    crate::domains::auth::credentials::storage::save_account_oauth_tokens(
        &path,
        PROVIDER_KEY,
        "user@host",
        &fresh,
    )
    .unwrap();

    let client = reqwest::Client::new();
    let (tokens, refreshed) = maybe_refresh_tokens(&path, "user@host", &expired, &client)
        .await
        .unwrap();

    // Should return the fresh tokens from disk without making HTTP call
    assert!(refreshed);
    assert_eq!(tokens.access_token, "fresh-tok");
}

// ─── active_credential selection ────────────────────────────────────

#[tokio::test]
async fn load_server_auth_active_credential_selects_specific_account() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("auth.json");

    let tokens1 = OAuthTokens {
        access_token: "first-tok".to_string(),
        refresh_token: "ref1".to_string(),
        expires_at: now_ms() + 3_600_000,
    };
    let tokens2 = OAuthTokens {
        access_token: "second-tok".to_string(),
        refresh_token: "ref2".to_string(),
        expires_at: now_ms() + 3_600_000,
    };
    crate::domains::auth::credentials::storage::save_account_oauth_tokens(
        &path,
        PROVIDER_KEY,
        "first",
        &tokens1,
    )
    .unwrap();
    crate::domains::auth::credentials::storage::save_account_oauth_tokens(
        &path,
        PROVIDER_KEY,
        "second",
        &tokens2,
    )
    .unwrap();
    crate::domains::auth::credentials::storage::set_active_credential(
        &path,
        PROVIDER_KEY,
        &ActiveCredential::OAuth {
            label: "second".to_string(),
        },
    )
    .unwrap();

    let result = load_server_auth(&path).await.unwrap();
    let auth = result.unwrap();
    assert_eq!(auth.token(), "second-tok");
}

#[tokio::test]
async fn load_server_auth_active_credential_selects_api_key() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("auth.json");

    let tokens = OAuthTokens {
        access_token: "oauth-tok".to_string(),
        refresh_token: "ref".to_string(),
        expires_at: now_ms() + 3_600_000,
    };
    crate::domains::auth::credentials::storage::save_account_oauth_tokens(
        &path,
        PROVIDER_KEY,
        "main",
        &tokens,
    )
    .unwrap();
    crate::domains::auth::credentials::storage::save_named_api_key(
        &path,
        PROVIDER_KEY,
        "work",
        "sk-work-key",
    )
    .unwrap();
    crate::domains::auth::credentials::storage::set_active_credential(
        &path,
        PROVIDER_KEY,
        &ActiveCredential::ApiKey {
            label: "work".to_string(),
        },
    )
    .unwrap();

    let result = load_server_auth(&path).await.unwrap();
    let auth = result.unwrap();
    assert!(!auth.is_oauth());
    assert_eq!(auth.token(), "sk-work-key");
}

#[tokio::test]
async fn load_server_auth_deleted_active_falls_back_to_first() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("auth.json");

    let tokens = OAuthTokens {
        access_token: "remaining-tok".to_string(),
        refresh_token: "ref".to_string(),
        expires_at: now_ms() + 3_600_000,
    };
    crate::domains::auth::credentials::storage::save_account_oauth_tokens(
        &path,
        PROVIDER_KEY,
        "remaining",
        &tokens,
    )
    .unwrap();

    // Set active to a non-existent account (simulates deletion without clearing active)
    // Manually write the active_credential since set_active_credential validates
    let mut storage = crate::domains::auth::credentials::storage::load_auth_storage(&path)
        .unwrap()
        .expect("auth storage written in test setup");
    let mut pa = storage.get_provider_auth(PROVIDER_KEY).unwrap();
    pa.active_credential = Some(ActiveCredential::OAuth {
        label: "deleted".to_string(),
    });
    storage.set_provider_auth(PROVIDER_KEY, &pa);
    crate::domains::auth::credentials::storage::save_auth_storage(&path, &mut storage).unwrap();

    let result = load_server_auth(&path).await.unwrap();
    let auth = result.unwrap();
    assert_eq!(auth.token(), "remaining-tok");
}

// ─── credential_override (session pinning) ──────────────────────────

#[tokio::test]
async fn load_server_auth_override_beats_active() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("auth.json");

    let tokens1 = OAuthTokens {
        access_token: "active-tok".to_string(),
        refresh_token: "ref1".to_string(),
        expires_at: now_ms() + 3_600_000,
    };
    let tokens2 = OAuthTokens {
        access_token: "pinned-tok".to_string(),
        refresh_token: "ref2".to_string(),
        expires_at: now_ms() + 3_600_000,
    };
    crate::domains::auth::credentials::storage::save_account_oauth_tokens(
        &path,
        PROVIDER_KEY,
        "active-acct",
        &tokens1,
    )
    .unwrap();
    crate::domains::auth::credentials::storage::save_account_oauth_tokens(
        &path,
        PROVIDER_KEY,
        "pinned-acct",
        &tokens2,
    )
    .unwrap();
    crate::domains::auth::credentials::storage::set_active_credential(
        &path,
        PROVIDER_KEY,
        &ActiveCredential::OAuth {
            label: "active-acct".to_string(),
        },
    )
    .unwrap();

    // Override should beat the active credential
    let override_cred = ActiveCredential::OAuth {
        label: "pinned-acct".to_string(),
    };
    let result = load_server_auth_with_credential(&path, Some(&override_cred))
        .await
        .unwrap();
    let auth = result.unwrap();
    assert_eq!(auth.token(), "pinned-tok");
}

#[tokio::test]
async fn load_server_auth_override_deleted_falls_to_active() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("auth.json");

    let tokens = OAuthTokens {
        access_token: "active-tok".to_string(),
        refresh_token: "ref".to_string(),
        expires_at: now_ms() + 3_600_000,
    };
    crate::domains::auth::credentials::storage::save_account_oauth_tokens(
        &path,
        PROVIDER_KEY,
        "active-acct",
        &tokens,
    )
    .unwrap();
    crate::domains::auth::credentials::storage::set_active_credential(
        &path,
        PROVIDER_KEY,
        &ActiveCredential::OAuth {
            label: "active-acct".to_string(),
        },
    )
    .unwrap();

    // Override points to a deleted credential
    let override_cred = ActiveCredential::OAuth {
        label: "deleted".to_string(),
    };
    let result = load_server_auth_with_credential(&path, Some(&override_cred))
        .await
        .unwrap();
    let auth = result.unwrap();
    assert_eq!(auth.token(), "active-tok");
}

#[tokio::test]
async fn load_server_auth_no_active_no_override_uses_first() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("auth.json");

    crate::domains::auth::credentials::storage::save_named_api_key(
        &path,
        PROVIDER_KEY,
        "key1",
        "sk-first",
    )
    .unwrap();
    crate::domains::auth::credentials::storage::save_named_api_key(
        &path,
        PROVIDER_KEY,
        "key2",
        "sk-second",
    )
    .unwrap();

    let result = load_server_auth(&path).await.unwrap();
    let auth = result.unwrap();
    assert_eq!(auth.token(), "sk-first");
}
