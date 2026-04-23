use super::*;
use crate::llm::auth::storage::save_google_provider_auth;
use crate::llm::auth::types::{AuthStorage, GoogleProviderAuth};
use crate::server::rpc::handlers::test_helpers::make_test_context;
use tempfile::TempDir;

fn make_ctx_with_temp_auth() -> (RpcContext, TempDir) {
    let mut ctx = make_test_context();
    let dir = TempDir::new().unwrap();
    ctx.auth_path = dir.path().join("auth.json");
    (ctx, dir)
}

// ── mask_key ──

#[test]
fn mask_key_short() {
    assert_eq!(mask_key("abc"), "***");
    assert_eq!(mask_key("12345678"), "***");
}

#[test]
fn mask_key_standard_anthropic() {
    let masked = mask_key("sk-ant-api03-abcdefghijklmnop");
    assert!(masked.starts_with("sk-ant-"));
    assert!(masked.ends_with("mnop"));
    assert!(masked.contains("..."));
}

#[test]
fn mask_key_standard_openai() {
    let masked = mask_key("sk-proj-abcdefghijklmnop");
    assert!(masked.starts_with("sk-"));
    assert!(masked.ends_with("mnop"));
}

#[test]
fn mask_key_empty() {
    assert_eq!(mask_key(""), "***");
}

// ── auth.get ──

#[tokio::test]
async fn auth_get_empty_returns_all_providers_unconfigured() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let result = GetAuthHandler.handle(None, &ctx).await.unwrap();

    let providers = result["providers"].as_object().unwrap();
    assert_eq!(providers.len(), 5);
    for &name in KNOWN_PROVIDERS {
        let p = &providers[name];
        assert_eq!(p["hasApiKey"], false);
        assert_eq!(p["hasOAuth"], false);
    }

    let services = result["services"].as_object().unwrap();
    assert_eq!(services.len(), 2);
    for &name in KNOWN_SERVICES {
        assert_eq!(services[name]["hasApiKey"], false);
    }
}

#[tokio::test]
async fn auth_get_with_api_key_returns_masked_hint() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    save_named_api_key(&ctx.auth_path, "anthropic", "(test)", "sk-ant-api03-abcdefghijklmnop")
        .unwrap();

    let result = GetAuthHandler.handle(None, &ctx).await.unwrap();
    let anthropic = &result["providers"]["anthropic"];
    assert_eq!(anthropic["hasApiKey"], true);
    let hint = anthropic["apiKeyHint"].as_str().unwrap();
    assert!(hint.contains("..."));
    assert!(!hint.contains("abcdefghijklmnop"));
}

#[tokio::test]
async fn auth_get_masks_key_correctly_short_key() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    save_named_api_key(&ctx.auth_path, "minimax", "(test)", "short").unwrap();

    let result = GetAuthHandler.handle(None, &ctx).await.unwrap();
    assert_eq!(result["providers"]["minimax"]["apiKeyHint"], "***");
}

#[tokio::test]
async fn auth_get_masks_key_correctly_long_key() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    save_named_api_key(&ctx.auth_path, "anthropic", "(test)", "sk-ant-api03-verylongkeyvalue1234")
        .unwrap();

    let result = GetAuthHandler.handle(None, &ctx).await.unwrap();
    let hint = result["providers"]["anthropic"]["apiKeyHint"].as_str().unwrap();
    assert!(hint.starts_with("sk-ant-"));
    assert!(hint.ends_with("1234"));
}

#[tokio::test]
async fn auth_get_shows_oauth_expiry_status() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let future_ms = crate::llm::auth::types::now_ms() + 3_600_000;
    let tokens = OAuthTokens {
        access_token: "at".into(),
        refresh_token: "rt".into(),
        expires_at: future_ms,
    };
    crate::llm::auth::storage::save_account_oauth_tokens(&ctx.auth_path, "anthropic", "(test)", &tokens).unwrap();

    let result = GetAuthHandler.handle(None, &ctx).await.unwrap();
    let anthropic = &result["providers"]["anthropic"];
    assert_eq!(anthropic["hasOAuth"], true);
    assert_eq!(anthropic["isOAuthExpired"], false);
}

#[tokio::test]
async fn auth_get_shows_expired_oauth() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let tokens = OAuthTokens {
        access_token: "at".into(),
        refresh_token: "rt".into(),
        expires_at: 0, // already expired
    };
    crate::llm::auth::storage::save_account_oauth_tokens(&ctx.auth_path, "anthropic", "(test)", &tokens).unwrap();

    let result = GetAuthHandler.handle(None, &ctx).await.unwrap();
    assert_eq!(result["providers"]["anthropic"]["isOAuthExpired"], true);
}

#[tokio::test]
async fn auth_get_shows_accounts_list() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let tokens = OAuthTokens {
        access_token: "at".into(),
        refresh_token: "rt".into(),
        expires_at: 1_700_000_000_000,
    };
    crate::llm::auth::storage::save_account_oauth_tokens(
        &ctx.auth_path,
        "anthropic",
        "moose@macbook",
        &tokens,
    )
    .unwrap();

    let result = GetAuthHandler.handle(None, &ctx).await.unwrap();
    let accounts = result["providers"]["anthropic"]["accounts"].as_array().unwrap();
    assert_eq!(accounts.len(), 1);
    assert_eq!(accounts[0]["label"], "moose@macbook");
    assert_eq!(accounts[0]["expiresAt"], 1_700_000_000_000_i64);
}

#[tokio::test]
async fn auth_get_google_returns_project() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let gpa = GoogleProviderAuth {
        project_id: Some("my-project".into()),
        client_id: Some("cid".into()),
        client_secret: Some("csec".into()),
        ..Default::default()
    };
    save_google_provider_auth(&ctx.auth_path, &gpa).unwrap();

    let result = GetAuthHandler.handle(None, &ctx).await.unwrap();
    let google = &result["providers"]["google"];
    assert!(google.get("endpoint").is_none() || google["endpoint"].is_null());
    assert_eq!(google["projectId"], "my-project");
    assert_eq!(google["hasClientId"], true);
    assert_eq!(google["hasClientSecret"], true);
}

#[tokio::test]
async fn auth_get_services_returns_brave_key() {
    let (ctx, _dir) = make_ctx_with_temp_auth();

    let mut storage = AuthStorage::new();
    let mut services = HashMap::new();
    let _ = services.insert(
        "brave".to_string(),
        ServiceAuth::from_single("BSA-abcdefghijklmnop"),
    );
    storage.services = Some(services);
    save_auth_storage(&ctx.auth_path, &mut storage).unwrap();

    let result = GetAuthHandler.handle(None, &ctx).await.unwrap();
    let brave = &result["services"]["brave"];
    assert_eq!(brave["hasApiKey"], true);
    let hint = brave["apiKeyHint"].as_str().unwrap();
    assert!(hint.contains("..."));
}

#[tokio::test]
async fn auth_get_missing_file_returns_defaults() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    // Don't create any auth file
    let result = GetAuthHandler.handle(None, &ctx).await.unwrap();
    assert_eq!(result["providers"]["anthropic"]["hasApiKey"], false);
    assert_eq!(result["services"]["brave"]["hasApiKey"], false);
}

// ── auth.update ──

#[tokio::test]
async fn auth_update_sets_api_key() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let result = UpdateAuthHandler
        .handle(
            Some(json!({"provider": "anthropic", "apiKey": "sk-ant-api03-newkey123456789"})),
            &ctx,
        )
        .await
        .unwrap();

    assert_eq!(result["providers"]["anthropic"]["hasApiKey"], true);
    let hint = result["providers"]["anthropic"]["apiKeyHint"].as_str().unwrap();
    assert!(hint.contains("..."));

    // Verify on disk
    let pa = crate::llm::auth::storage::get_provider_auth(&ctx.auth_path, "anthropic")
        .unwrap()
        .expect("provider auth written by test setup");
    let api_keys = pa.api_keys.unwrap();
    assert_eq!(api_keys[0].key, "sk-ant-api03-newkey123456789");
}

#[tokio::test]
async fn auth_update_sets_oauth_tokens() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let result = UpdateAuthHandler
        .handle(
            Some(json!({
                "provider": "anthropic",
                "oauth": {
                    "accessToken": "at-123",
                    "refreshToken": "rt-456",
                    "expiresAt": 9_999_999_999_999_i64
                }
            })),
            &ctx,
        )
        .await
        .unwrap();

    assert_eq!(result["providers"]["anthropic"]["hasOAuth"], true);
    assert_eq!(result["providers"]["anthropic"]["isOAuthExpired"], false);
}

#[tokio::test]
async fn auth_update_sets_google_with_all_fields() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let result = UpdateAuthHandler
        .handle(
            Some(json!({
                "provider": "google",
                "apiKey": "ya29.abcdefghijklmnop",
                "clientId": "client-id-123",
                "clientSecret": "client-secret-456",
                "projectId": "my-gcp-project"
            })),
            &ctx,
        )
        .await
        .unwrap();

    let google = &result["providers"]["google"];
    assert_eq!(google["hasApiKey"], true);
    assert_eq!(google["hasClientId"], true);
    assert_eq!(google["hasClientSecret"], true);
    assert_eq!(google["projectId"], "my-gcp-project");
}

#[tokio::test]
async fn auth_update_preserves_existing_fields() {
    let (ctx, _dir) = make_ctx_with_temp_auth();

    // Set API key first
    let _ = UpdateAuthHandler
        .handle(
            Some(json!({"provider": "anthropic", "apiKey": "sk-ant-api03-firstkey12345678"})),
            &ctx,
        )
        .await
        .unwrap();

    // Then set OAuth without touching API key
    let result = UpdateAuthHandler
        .handle(
            Some(json!({
                "provider": "anthropic",
                "oauth": {
                    "accessToken": "at",
                    "refreshToken": "rt",
                    "expiresAt": 9_999_999_999_999_i64
                }
            })),
            &ctx,
        )
        .await
        .unwrap();

    // Both should be present
    assert_eq!(result["providers"]["anthropic"]["hasApiKey"], true);
    assert_eq!(result["providers"]["anthropic"]["hasOAuth"], true);
}

#[tokio::test]
async fn auth_update_null_api_key_clears_it() {
    let (ctx, _dir) = make_ctx_with_temp_auth();

    // Set key first
    let _ = UpdateAuthHandler
        .handle(
            Some(json!({"provider": "anthropic", "apiKey": "sk-ant-api03-clearme123456789"})),
            &ctx,
        )
        .await
        .unwrap();

    // Clear with null
    let result = UpdateAuthHandler
        .handle(
            Some(json!({"provider": "anthropic", "apiKey": null})),
            &ctx,
        )
        .await
        .unwrap();

    assert_eq!(result["providers"]["anthropic"]["hasApiKey"], false);
}

#[tokio::test]
async fn auth_update_service_api_key() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let result = UpdateAuthHandler
        .handle(
            Some(json!({"service": "brave", "apiKey": "BSA-abcdefghijklmnop"})),
            &ctx,
        )
        .await
        .unwrap();

    assert_eq!(result["services"]["brave"]["hasApiKey"], true);
}

#[tokio::test]
async fn auth_update_invalid_provider_returns_error() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let err = UpdateAuthHandler
        .handle(
            Some(json!({"provider": "nonexistent", "apiKey": "key"})),
            &ctx,
        )
        .await
        .unwrap_err();

    assert_eq!(err.code(), "INVALID_PARAMS");
    assert!(err.to_string().contains("Unknown provider"));
}

#[tokio::test]
async fn auth_update_missing_provider_returns_error() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let err = UpdateAuthHandler
        .handle(Some(json!({"apiKey": "key"})), &ctx)
        .await
        .unwrap_err();

    assert_eq!(err.code(), "INVALID_PARAMS");
}

#[tokio::test]
async fn auth_update_returns_updated_masked_state() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let result = UpdateAuthHandler
        .handle(
            Some(json!({"provider": "openai-codex", "apiKey": "sk-proj-abcdefghijklmnop"})),
            &ctx,
        )
        .await
        .unwrap();

    // Should contain all providers, not just the updated one
    assert_eq!(result["providers"].as_object().unwrap().len(), 5);
    assert_eq!(result["providers"]["openai-codex"]["hasApiKey"], true);
}

#[tokio::test]
async fn auth_update_creates_file_if_missing() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    assert!(!ctx.auth_path.exists());

    let _ = UpdateAuthHandler
        .handle(
            Some(json!({"provider": "kimi", "apiKey": "kimi-key-abcdefghijklmnop"})),
            &ctx,
        )
        .await
        .unwrap();

    assert!(ctx.auth_path.exists());
}

// ── auth.clear ──

#[tokio::test]
async fn auth_clear_removes_provider() {
    let (ctx, _dir) = make_ctx_with_temp_auth();

    // Set up
    save_named_api_key(&ctx.auth_path, "anthropic", "(test)", "sk-ant-api03-clearme123456789").unwrap();

    let result = ClearAuthHandler
        .handle(Some(json!({"provider": "anthropic"})), &ctx)
        .await
        .unwrap();

    assert_eq!(result["providers"]["anthropic"]["hasApiKey"], false);
}

#[tokio::test]
async fn auth_clear_preserves_other_providers() {
    let (ctx, _dir) = make_ctx_with_temp_auth();

    save_named_api_key(&ctx.auth_path, "anthropic", "(test)", "sk-ant-api03-keep12345678901").unwrap();
    save_named_api_key(&ctx.auth_path, "openai-codex", "(test)", "sk-proj-remove12345678901").unwrap();

    let result = ClearAuthHandler
        .handle(Some(json!({"provider": "openai-codex"})), &ctx)
        .await
        .unwrap();

    assert_eq!(result["providers"]["anthropic"]["hasApiKey"], true);
    assert_eq!(result["providers"]["openai-codex"]["hasApiKey"], false);
}

#[tokio::test]
async fn auth_clear_nonexistent_provider_is_ok() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let result = ClearAuthHandler
        .handle(Some(json!({"provider": "minimax"})), &ctx)
        .await
        .unwrap();

    assert_eq!(result["providers"]["minimax"]["hasApiKey"], false);
}

#[tokio::test]
async fn auth_clear_service() {
    let (ctx, _dir) = make_ctx_with_temp_auth();

    // Set up
    let mut storage = AuthStorage::new();
    let mut services = HashMap::new();
    let _ = services.insert(
        "brave".to_string(),
        ServiceAuth::from_single("BSA-key123456789012"),
    );
    storage.services = Some(services);
    save_auth_storage(&ctx.auth_path, &mut storage).unwrap();

    let result = ClearAuthHandler
        .handle(Some(json!({"service": "brave"})), &ctx)
        .await
        .unwrap();

    assert_eq!(result["services"]["brave"]["hasApiKey"], false);
}

#[tokio::test]
async fn auth_clear_missing_file_is_ok() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    assert!(!ctx.auth_path.exists());

    let result = ClearAuthHandler
        .handle(Some(json!({"provider": "anthropic"})), &ctx)
        .await
        .unwrap();

    assert_eq!(result["providers"]["anthropic"]["hasApiKey"], false);
}

// ── auth.oauthBegin ──

#[tokio::test]
async fn oauth_begin_returns_flow_id_and_auth_url() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let result = OAuthBeginHandler
        .handle(Some(json!({"provider": "anthropic"})), &ctx)
        .await
        .unwrap();

    assert!(result["flowId"].as_str().is_some());
    assert!(!result["flowId"].as_str().unwrap().is_empty());
    assert!(result["authUrl"].as_str().is_some());
    assert!(!result["authUrl"].as_str().unwrap().is_empty());
}

#[tokio::test]
async fn oauth_begin_auth_url_contains_pkce_challenge() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let result = OAuthBeginHandler
        .handle(Some(json!({"provider": "anthropic"})), &ctx)
        .await
        .unwrap();

    let url = result["authUrl"].as_str().unwrap();
    assert!(url.contains("code_challenge="));
    assert!(url.contains("code_challenge_method=S256"));
}

#[tokio::test]
async fn oauth_begin_auth_url_contains_client_id() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let result = OAuthBeginHandler
        .handle(Some(json!({"provider": "anthropic"})), &ctx)
        .await
        .unwrap();

    let url = result["authUrl"].as_str().unwrap();
    assert!(url.contains("client_id="));
}

#[tokio::test]
async fn oauth_begin_auth_url_contains_redirect_uri() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let result = OAuthBeginHandler
        .handle(Some(json!({"provider": "anthropic"})), &ctx)
        .await
        .unwrap();

    let url = result["authUrl"].as_str().unwrap();
    assert!(url.contains("redirect_uri="));
}

#[tokio::test]
async fn oauth_begin_auth_url_contains_scopes() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let result = OAuthBeginHandler
        .handle(Some(json!({"provider": "anthropic"})), &ctx)
        .await
        .unwrap();

    let url = result["authUrl"].as_str().unwrap();
    assert!(url.contains("scope="));
}

#[tokio::test]
async fn oauth_begin_invalid_provider_returns_error() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let err = OAuthBeginHandler
        .handle(Some(json!({"provider": "unknown-provider"})), &ctx)
        .await
        .unwrap_err();

    assert_eq!(err.code(), "INVALID_PARAMS");
    assert!(err.to_string().contains("OAuth login supported for"));
}

#[tokio::test]
async fn oauth_begin_missing_provider_returns_error() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let err = OAuthBeginHandler
        .handle(Some(json!({})), &ctx)
        .await
        .unwrap_err();

    assert_eq!(err.code(), "INVALID_PARAMS");
}

#[tokio::test]
async fn oauth_begin_auth_url_contains_state() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let result = OAuthBeginHandler
        .handle(Some(json!({"provider": "anthropic"})), &ctx)
        .await
        .unwrap();

    let url = result["authUrl"].as_str().unwrap();
    assert!(url.contains("state="), "auth URL must contain state parameter");
}

#[tokio::test]
async fn oauth_begin_stores_flow_in_context() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let result = OAuthBeginHandler
        .handle(Some(json!({"provider": "anthropic"})), &ctx)
        .await
        .unwrap();

    let flow_id = result["flowId"].as_str().unwrap();
    let flows = ctx.oauth_flows.lock().await;
    assert!(flows.contains_key(flow_id));
    assert_eq!(flows[flow_id].provider, "anthropic");
}

#[tokio::test]
async fn oauth_begin_each_call_generates_unique_flow_id() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let r1 = OAuthBeginHandler
        .handle(Some(json!({"provider": "anthropic"})), &ctx)
        .await
        .unwrap();
    let r2 = OAuthBeginHandler
        .handle(Some(json!({"provider": "anthropic"})), &ctx)
        .await
        .unwrap();

    assert_ne!(r1["flowId"].as_str().unwrap(), r2["flowId"].as_str().unwrap());
}

#[tokio::test]
async fn oauth_begin_cleans_up_expired_flows() {
    let (ctx, _dir) = make_ctx_with_temp_auth();

    // Insert an expired flow manually
    {
        let mut flows = ctx.oauth_flows.lock().await;
        let _ = flows.insert(
            "expired-flow".to_string(),
            PendingOAuthFlow {
                verifier: "v".to_string(),
                provider: "anthropic".to_string(),
                created_at: std::time::Instant::now().checked_sub(std::time::Duration::from_secs(700)).unwrap(),
            },
        );
    }

    // Begin a new flow — should clean up expired
    let _ = OAuthBeginHandler
        .handle(Some(json!({"provider": "anthropic"})), &ctx)
        .await
        .unwrap();

    let flows = ctx.oauth_flows.lock().await;
    assert!(!flows.contains_key("expired-flow"));
}

// ── auth.oauthComplete ──

#[tokio::test]
async fn oauth_complete_invalid_flow_id_returns_error() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let err = OAuthCompleteHandler
        .handle(
            Some(json!({"flowId": "nonexistent", "code": "abc", "label": "test"})),
            &ctx,
        )
        .await
        .unwrap_err();

    assert_eq!(err.code(), "INVALID_PARAMS");
    assert!(err.to_string().contains("not found or expired"));
}

#[tokio::test]
async fn oauth_complete_missing_flow_id_returns_error() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let err = OAuthCompleteHandler
        .handle(Some(json!({"code": "abc", "label": "test"})), &ctx)
        .await
        .unwrap_err();

    assert_eq!(err.code(), "INVALID_PARAMS");
}

#[tokio::test]
async fn oauth_complete_missing_code_returns_error() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let err = OAuthCompleteHandler
        .handle(Some(json!({"flowId": "abc", "label": "test"})), &ctx)
        .await
        .unwrap_err();

    assert_eq!(err.code(), "INVALID_PARAMS");
}

#[tokio::test]
async fn oauth_complete_missing_label_returns_error() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let err = OAuthCompleteHandler
        .handle(Some(json!({"flowId": "abc", "code": "test"})), &ctx)
        .await
        .unwrap_err();

    assert_eq!(err.code(), "INVALID_PARAMS");
}

#[tokio::test]
async fn oauth_complete_flow_id_is_single_use() {
    let (ctx, _dir) = make_ctx_with_temp_auth();

    // Insert a flow manually
    let flow_id = "single-use-flow";
    {
        let mut flows = ctx.oauth_flows.lock().await;
        let _ = flows.insert(
            flow_id.to_string(),
            PendingOAuthFlow {
                verifier: "v".to_string(),
                provider: "anthropic".to_string(),
                created_at: std::time::Instant::now(),
            },
        );
    }

    // First attempt removes the flow (will fail at token exchange since code is fake,
    // but the flow is already removed)
    let _ = OAuthCompleteHandler
        .handle(
            Some(json!({"flowId": flow_id, "code": "fake", "label": "test"})),
            &ctx,
        )
        .await;

    // Second attempt should fail with "not found"
    let err = OAuthCompleteHandler
        .handle(
            Some(json!({"flowId": flow_id, "code": "fake", "label": "test"})),
            &ctx,
        )
        .await
        .unwrap_err();

    assert_eq!(err.code(), "INVALID_PARAMS");
    assert!(err.to_string().contains("not found or expired"));
}

#[tokio::test]
async fn oauth_complete_expired_flow_returns_error() {
    let (ctx, _dir) = make_ctx_with_temp_auth();

    let flow_id = "expired-flow";
    {
        let mut flows = ctx.oauth_flows.lock().await;
        let _ = flows.insert(
            flow_id.to_string(),
            PendingOAuthFlow {
                verifier: "v".to_string(),
                provider: "anthropic".to_string(),
                created_at: std::time::Instant::now().checked_sub(std::time::Duration::from_secs(700)).unwrap(),
            },
        );
    }

    let err = OAuthCompleteHandler
        .handle(
            Some(json!({"flowId": flow_id, "code": "fake", "label": "test"})),
            &ctx,
        )
        .await
        .unwrap_err();

    assert_eq!(err.code(), "INVALID_PARAMS");
    assert!(err.to_string().contains("expired"));
}

#[tokio::test]
async fn oauth_complete_removes_flow_from_map() {
    let (ctx, _dir) = make_ctx_with_temp_auth();

    let flow_id = "will-be-removed";
    {
        let mut flows = ctx.oauth_flows.lock().await;
        let _ = flows.insert(
            flow_id.to_string(),
            PendingOAuthFlow {
                verifier: "v".to_string(),
                provider: "anthropic".to_string(),
                created_at: std::time::Instant::now(),
            },
        );
    }

    // This will fail at token exchange (fake code) but flow should be removed
    let _ = OAuthCompleteHandler
        .handle(
            Some(json!({"flowId": flow_id, "code": "fake", "label": "test"})),
            &ctx,
        )
        .await;

    let flows = ctx.oauth_flows.lock().await;
    assert!(!flows.contains_key(flow_id));
}

// ── auth.oauthBegin (OpenAI) ──

#[tokio::test]
async fn oauth_begin_openai_returns_flow_id_and_auth_url() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let result = OAuthBeginHandler
        .handle(Some(json!({"provider": "openai-codex"})), &ctx)
        .await
        .unwrap();

    assert!(result["flowId"].as_str().is_some());
    assert!(!result["flowId"].as_str().unwrap().is_empty());
    assert!(result["authUrl"].as_str().is_some());
    assert!(!result["authUrl"].as_str().unwrap().is_empty());
}

#[tokio::test]
async fn oauth_begin_openai_auth_url_contains_openai_endpoint() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let result = OAuthBeginHandler
        .handle(Some(json!({"provider": "openai-codex"})), &ctx)
        .await
        .unwrap();

    let url = result["authUrl"].as_str().unwrap();
    assert!(url.contains("auth.openai.com"), "URL should use OpenAI auth endpoint");
}

#[tokio::test]
async fn oauth_begin_openai_auth_url_has_pkce() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let result = OAuthBeginHandler
        .handle(Some(json!({"provider": "openai-codex"})), &ctx)
        .await
        .unwrap();

    let url = result["authUrl"].as_str().unwrap();
    assert!(url.contains("code_challenge="), "OpenAI should use PKCE code_challenge");
    assert!(url.contains("code_challenge_method=S256"), "OpenAI should use S256");
}

#[tokio::test]
async fn oauth_begin_openai_auth_url_contains_state() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let result = OAuthBeginHandler
        .handle(Some(json!({"provider": "openai-codex"})), &ctx)
        .await
        .unwrap();

    let url = result["authUrl"].as_str().unwrap();
    assert!(url.contains("state="), "OpenAI auth URL must contain state parameter");
}

#[tokio::test]
async fn oauth_begin_openai_auth_url_contains_required_params() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let result = OAuthBeginHandler
        .handle(Some(json!({"provider": "openai-codex"})), &ctx)
        .await
        .unwrap();

    let url = result["authUrl"].as_str().unwrap();
    assert!(url.contains("response_type=code"));
    assert!(url.contains("client_id="));
    assert!(url.contains("redirect_uri="));
    assert!(url.contains("scope="));
}

#[tokio::test]
async fn oauth_begin_openai_stores_correct_provider_in_flow() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let result = OAuthBeginHandler
        .handle(Some(json!({"provider": "openai-codex"})), &ctx)
        .await
        .unwrap();

    let flow_id = result["flowId"].as_str().unwrap();
    let flows = ctx.oauth_flows.lock().await;
    assert!(flows.contains_key(flow_id));
    assert_eq!(flows[flow_id].provider, "openai-codex");
}

#[tokio::test]
async fn oauth_begin_anthropic_still_returns_pkce() {
    // Regression: ensure Anthropic flows still use PKCE after multi-provider change
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let result = OAuthBeginHandler
        .handle(Some(json!({"provider": "anthropic"})), &ctx)
        .await
        .unwrap();

    let url = result["authUrl"].as_str().unwrap();
    assert!(url.contains("claude.ai"), "Anthropic URL should use claude.ai");
    assert!(url.contains("code_challenge="), "Anthropic should use PKCE");
    assert!(url.contains("code_challenge_method=S256"), "Anthropic should use S256");
}

// ── auth.oauthBegin (Google) ──

#[tokio::test]
async fn oauth_begin_google_requires_client_id() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    // No Google credentials saved
    let err = OAuthBeginHandler
        .handle(Some(json!({"provider": "google"})), &ctx)
        .await
        .unwrap_err();

    assert_eq!(err.code(), "INVALID_PARAMS");
    assert!(err.to_string().contains("client_id"), "error should mention client_id: {}", err);
}

#[tokio::test]
async fn oauth_begin_google_error_message_mentions_settings() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let err = OAuthBeginHandler
        .handle(Some(json!({"provider": "google"})), &ctx)
        .await
        .unwrap_err();

    assert!(err.to_string().contains("Settings"), "error should guide user to Settings: {}", err);
}

#[tokio::test]
async fn oauth_begin_google_returns_flow_id_and_auth_url() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let gpa = GoogleProviderAuth {
        client_id: Some("test-client-id".into()),
        ..Default::default()
    };
    save_google_provider_auth(&ctx.auth_path, &gpa).unwrap();

    let result = OAuthBeginHandler
        .handle(Some(json!({"provider": "google"})), &ctx)
        .await
        .unwrap();

    assert!(result["flowId"].as_str().is_some());
    assert!(!result["flowId"].as_str().unwrap().is_empty());
    assert!(result["authUrl"].as_str().is_some());
    assert!(!result["authUrl"].as_str().unwrap().is_empty());
}

#[tokio::test]
async fn oauth_begin_google_auth_url_contains_google_endpoint() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let gpa = GoogleProviderAuth {
        client_id: Some("test-client-id".into()),
        ..Default::default()
    };
    save_google_provider_auth(&ctx.auth_path, &gpa).unwrap();

    let result = OAuthBeginHandler
        .handle(Some(json!({"provider": "google"})), &ctx)
        .await
        .unwrap();

    let url = result["authUrl"].as_str().unwrap();
    assert!(url.contains("accounts.google.com"), "URL should use Google auth endpoint");
}

#[tokio::test]
async fn oauth_begin_google_auth_url_has_pkce() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let gpa = GoogleProviderAuth {
        client_id: Some("test-client-id".into()),
        ..Default::default()
    };
    save_google_provider_auth(&ctx.auth_path, &gpa).unwrap();

    let result = OAuthBeginHandler
        .handle(Some(json!({"provider": "google"})), &ctx)
        .await
        .unwrap();

    let url = result["authUrl"].as_str().unwrap();
    assert!(url.contains("code_challenge="), "Google should use PKCE code_challenge");
    assert!(url.contains("code_challenge_method=S256"), "Google should use S256");
}

#[tokio::test]
async fn oauth_begin_google_auth_url_contains_client_id() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let gpa = GoogleProviderAuth {
        client_id: Some("test-client-id".into()),
        ..Default::default()
    };
    save_google_provider_auth(&ctx.auth_path, &gpa).unwrap();

    let result = OAuthBeginHandler
        .handle(Some(json!({"provider": "google"})), &ctx)
        .await
        .unwrap();

    let url = result["authUrl"].as_str().unwrap();
    assert!(url.contains("client_id=test-client-id"), "URL should contain user's client_id");
}

#[tokio::test]
async fn oauth_begin_google_auth_url_contains_required_params() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let gpa = GoogleProviderAuth {
        client_id: Some("test-client-id".into()),
        ..Default::default()
    };
    save_google_provider_auth(&ctx.auth_path, &gpa).unwrap();

    let result = OAuthBeginHandler
        .handle(Some(json!({"provider": "google"})), &ctx)
        .await
        .unwrap();

    let url = result["authUrl"].as_str().unwrap();
    assert!(url.contains("response_type=code"));
    assert!(url.contains("redirect_uri="));
    assert!(url.contains("scope="));
    assert!(url.contains("access_type=offline"), "Google should request offline access");
    assert!(url.contains("prompt=consent"), "Google should force consent for refresh token");
}

#[tokio::test]
async fn oauth_begin_google_auth_url_has_no_state_param() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let gpa = GoogleProviderAuth {
        client_id: Some("test-client-id".into()),
        ..Default::default()
    };
    save_google_provider_auth(&ctx.auth_path, &gpa).unwrap();

    let result = OAuthBeginHandler
        .handle(Some(json!({"provider": "google"})), &ctx)
        .await
        .unwrap();

    let url = result["authUrl"].as_str().unwrap();
    assert!(!url.contains("state="), "Google OAuth should not include state parameter (PKCE-only)");
}

#[tokio::test]
async fn oauth_begin_google_stores_correct_provider_in_flow() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let gpa = GoogleProviderAuth {
        client_id: Some("test-client-id".into()),
        ..Default::default()
    };
    save_google_provider_auth(&ctx.auth_path, &gpa).unwrap();

    let result = OAuthBeginHandler
        .handle(Some(json!({"provider": "google"})), &ctx)
        .await
        .unwrap();

    let flow_id = result["flowId"].as_str().unwrap();
    let flows = ctx.oauth_flows.lock().await;
    assert!(flows.contains_key(flow_id));
    assert_eq!(flows[flow_id].provider, "google");
}

#[tokio::test]
async fn oauth_begin_google_with_client_secret_succeeds() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let gpa = GoogleProviderAuth {
        client_id: Some("cid".into()),
        client_secret: Some("csec".into()),
        ..Default::default()
    };
    save_google_provider_auth(&ctx.auth_path, &gpa).unwrap();

    let result = OAuthBeginHandler
        .handle(Some(json!({"provider": "google"})), &ctx)
        .await
        .unwrap();

    let url = result["authUrl"].as_str().unwrap();
    assert!(!url.is_empty());
    // Client secret should NOT appear in the auth URL (used at token exchange time only)
    assert!(!url.contains("csec"), "client_secret must not leak into auth URL");
}

#[tokio::test]
async fn oauth_begin_google_with_only_client_id_succeeds() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let gpa = GoogleProviderAuth {
        client_id: Some("cid-only".into()),
        client_secret: None,
        ..Default::default()
    };
    save_google_provider_auth(&ctx.auth_path, &gpa).unwrap();

    let result = OAuthBeginHandler
        .handle(Some(json!({"provider": "google"})), &ctx)
        .await
        .unwrap();

    assert!(result["authUrl"].as_str().is_some());
}

#[tokio::test]
async fn oauth_complete_google_requires_client_id() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    // No Google credentials on disk, but inject a pending flow
    let flow_id = "test-flow-google";
    {
        let mut flows = ctx.oauth_flows.lock().await;
        let _ = flows.insert(
            flow_id.to_string(),
            PendingOAuthFlow {
                verifier: "test-verifier".to_string(),
                provider: "google".to_string(),
                created_at: std::time::Instant::now(),
            },
        );
    }

    let err = OAuthCompleteHandler
        .handle(
            Some(json!({"flowId": flow_id, "code": "test-code", "label": "test"})),
            &ctx,
        )
        .await
        .unwrap_err();

    assert!(err.to_string().contains("client_id"), "error should mention client_id: {}", err);
}

// ── auth.setActive ──

#[tokio::test]
async fn auth_set_active_oauth() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let tokens = OAuthTokens {
        access_token: "at".into(),
        refresh_token: "rt".into(),
        expires_at: crate::llm::auth::types::now_ms() + 3_600_000,
    };
    crate::llm::auth::storage::save_account_oauth_tokens(
        &ctx.auth_path, "anthropic", "main", &tokens,
    )
    .unwrap();

    let result = SetActiveCredentialHandler
        .handle(
            Some(json!({"provider": "anthropic", "credential": {"type": "oauth", "label": "main"}})),
            &ctx,
        )
        .await
        .unwrap();

    assert_eq!(
        result["providers"]["anthropic"]["activeCredential"]["type"],
        "oauth"
    );
    assert_eq!(
        result["providers"]["anthropic"]["activeCredential"]["label"],
        "main"
    );
}

#[tokio::test]
async fn auth_set_active_api_key() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    crate::llm::auth::storage::save_named_api_key(
        &ctx.auth_path, "anthropic", "work", "sk-123",
    )
    .unwrap();

    let result = SetActiveCredentialHandler
        .handle(
            Some(json!({"provider": "anthropic", "credential": {"type": "apiKey", "label": "work"}})),
            &ctx,
        )
        .await
        .unwrap();

    assert_eq!(
        result["providers"]["anthropic"]["activeCredential"]["type"],
        "apiKey"
    );
}

#[tokio::test]
async fn auth_set_active_nonexistent_errors() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let err = SetActiveCredentialHandler
        .handle(
            Some(json!({"provider": "anthropic", "credential": {"type": "oauth", "label": "nope"}})),
            &ctx,
        )
        .await
        .unwrap_err();

    assert_eq!(err.code(), "INVALID_PARAMS");
}

// ── auth.removeAccount ──

#[tokio::test]
async fn auth_remove_account() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let tokens = OAuthTokens {
        access_token: "at".into(),
        refresh_token: "rt".into(),
        expires_at: crate::llm::auth::types::now_ms() + 3_600_000,
    };
    crate::llm::auth::storage::save_account_oauth_tokens(
        &ctx.auth_path, "anthropic", "del-me", &tokens,
    )
    .unwrap();

    let result = RemoveAccountHandler
        .handle(
            Some(json!({"provider": "anthropic", "label": "del-me"})),
            &ctx,
        )
        .await
        .unwrap();

    let accounts = result["providers"]["anthropic"]["accounts"].as_array().unwrap();
    assert!(accounts.is_empty());
}

#[tokio::test]
async fn auth_remove_account_clears_active() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let tokens = OAuthTokens {
        access_token: "at".into(),
        refresh_token: "rt".into(),
        expires_at: crate::llm::auth::types::now_ms() + 3_600_000,
    };
    crate::llm::auth::storage::save_account_oauth_tokens(
        &ctx.auth_path, "anthropic", "active-one", &tokens,
    )
    .unwrap();
    crate::llm::auth::storage::set_active_credential(
        &ctx.auth_path,
        "anthropic",
        &ActiveCredential::OAuth { label: "active-one".into() },
    )
    .unwrap();

    let result = RemoveAccountHandler
        .handle(
            Some(json!({"provider": "anthropic", "label": "active-one"})),
            &ctx,
        )
        .await
        .unwrap();

    assert!(result["providers"]["anthropic"]["activeCredential"].is_null());
}

// ── auth.removeApiKey ──

#[tokio::test]
async fn auth_remove_api_key() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    crate::llm::auth::storage::save_named_api_key(
        &ctx.auth_path, "anthropic", "del-me", "sk-123",
    )
    .unwrap();

    let result = RemoveApiKeyHandler
        .handle(
            Some(json!({"provider": "anthropic", "label": "del-me"})),
            &ctx,
        )
        .await
        .unwrap();

    let api_keys = result["providers"]["anthropic"]["apiKeys"].as_array().unwrap();
    assert!(api_keys.is_empty());
}

// ── auth.get response shape ──

#[tokio::test]
async fn auth_get_returns_api_keys_and_active_credential() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    crate::llm::auth::storage::save_named_api_key(
        &ctx.auth_path, "anthropic", "work", "sk-ant-api03-workkey123456789",
    )
    .unwrap();
    crate::llm::auth::storage::set_active_credential(
        &ctx.auth_path,
        "anthropic",
        &ActiveCredential::ApiKey { label: "work".into() },
    )
    .unwrap();

    let result = GetAuthHandler.handle(None, &ctx).await.unwrap();

    let api_keys = result["providers"]["anthropic"]["apiKeys"].as_array().unwrap();
    assert_eq!(api_keys.len(), 1);
    assert_eq!(api_keys[0]["label"], "work");
    assert!(api_keys[0]["keyHint"].as_str().unwrap().contains("..."));

    assert_eq!(
        result["providers"]["anthropic"]["activeCredential"]["type"],
        "apiKey"
    );
}

// ── auth.update with apiKeyLabel ──

#[tokio::test]
async fn auth_update_with_api_key_label_creates_named_key() {
    let (ctx, _dir) = make_ctx_with_temp_auth();
    let result = UpdateAuthHandler
        .handle(
            Some(json!({
                "provider": "anthropic",
                "apiKey": "sk-ant-api03-namedkey123456789",
                "apiKeyLabel": "work"
            })),
            &ctx,
        )
        .await
        .unwrap();

    let api_keys = result["providers"]["anthropic"]["apiKeys"].as_array().unwrap();
    assert_eq!(api_keys.len(), 1);
    assert_eq!(api_keys[0]["label"], "work");
}
