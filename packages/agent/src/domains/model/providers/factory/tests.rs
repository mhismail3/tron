use super::*;

/// Build a factory that reads from a non-existent auth file (no credentials).
fn no_auth_factory() -> DefaultProviderFactory {
    let settings = crate::domains::settings::TronSettings::default();
    DefaultProviderFactory::new(&settings)
        .with_auth_path(PathBuf::from("/tmp/tron-test-no-such-auth.json"))
}

#[test]
fn factory_captures_anthropic_settings() {
    let mut settings = crate::domains::settings::TronSettings::default();
    settings.api.anthropic.client_id = "test-client-id".into();

    let factory = DefaultProviderFactory::new(&settings);
    assert_eq!(factory.anthropic.client_id, "test-client-id");
}

/// Helper: extract the auth error from a factory call that should fail.
async fn expect_auth_error(factory: &DefaultProviderFactory, model: &str) -> ProviderError {
    match factory.create_for_model(model).await {
        Err(e) => e,
        Ok(_) => panic!("expected auth error for model '{model}', got Ok"),
    }
}

#[tokio::test]
async fn factory_rejects_openai_without_auth() {
    let factory = no_auth_factory();
    let err = expect_auth_error(&factory, "gpt-5.3-codex").await;
    assert_eq!(err.category(), "auth");
}

#[tokio::test]
async fn factory_rejects_google_without_auth() {
    let factory = no_auth_factory();
    let err = expect_auth_error(&factory, "gemini-2.5-flash").await;
    assert_eq!(err.category(), "auth");
}

#[tokio::test]
async fn factory_rejects_anthropic_without_auth() {
    let factory = no_auth_factory();
    let err = expect_auth_error(&factory, "claude-opus-4-6").await;
    assert_eq!(err.category(), "auth");
}

#[tokio::test]
async fn factory_detects_provider_from_model_id() {
    let factory = no_auth_factory();

    // OpenAI model → OpenAI auth error (not Anthropic)
    let err = expect_auth_error(&factory, "gpt-5.3-codex").await;
    assert!(err.to_string().contains("OpenAI"));

    // Google model → Google auth error
    let err = expect_auth_error(&factory, "gemini-2.5-flash").await;
    assert!(err.to_string().contains("Google"));

    // Anthropic model → Anthropic auth error
    let err = expect_auth_error(&factory, "claude-opus-4-6").await;
    assert!(err.to_string().contains("Anthropic"));
}

#[tokio::test]
async fn factory_strips_provider_prefix() {
    let factory = no_auth_factory();

    // "openai/gpt-5.3-codex" should route to OpenAI
    let err = expect_auth_error(&factory, "openai/gpt-5.3-codex").await;
    assert!(err.to_string().contains("OpenAI"));
}

#[tokio::test]
async fn factory_openai_api_key_uses_platform_profile() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("auth.json");
    crate::domains::auth::credentials::storage::save_named_api_key(
        &path,
        crate::domains::auth::credentials::openai::PROVIDER_KEY,
        "test",
        "sk-test",
    )
    .unwrap();

    let settings = crate::domains::settings::TronSettings::default();
    let factory = DefaultProviderFactory::new(&settings).with_auth_path(path);
    let provider = factory.create_for_model("gpt-5.5").await.unwrap();
    assert_eq!(provider.model(), "gpt-5.5");
    assert_eq!(provider.context_window(), 1_050_000);
}

#[tokio::test]
async fn factory_openai_oauth_uses_codex_profile() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("auth.json");
    let tokens = crate::domains::auth::credentials::OAuthTokens {
        access_token: "tok".into(),
        refresh_token: "ref".into(),
        expires_at: crate::domains::auth::credentials::now_ms() + 3_600_000,
    };
    crate::domains::auth::credentials::storage::save_account_oauth_tokens(
        &path,
        crate::domains::auth::credentials::openai::PROVIDER_KEY,
        "test",
        &tokens,
    )
    .unwrap();

    let settings = crate::domains::settings::TronSettings::default();
    let factory = DefaultProviderFactory::new(&settings).with_auth_path(path);
    let provider = factory.create_for_model("gpt-5.5").await.unwrap();
    assert_eq!(provider.model(), "gpt-5.5");
    assert_eq!(provider.context_window(), 272_000);
}

#[tokio::test]
async fn factory_rejects_openai_model_unavailable_for_active_auth_path() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("auth.json");
    crate::domains::auth::credentials::storage::save_named_api_key(
        &path,
        crate::domains::auth::credentials::openai::PROVIDER_KEY,
        "test",
        "sk-test",
    )
    .unwrap();

    let settings = crate::domains::settings::TronSettings::default();
    let factory = DefaultProviderFactory::new(&settings).with_auth_path(path);
    let err = match factory.create_for_model("gpt-5.3-codex-spark").await {
        Ok(_) => panic!("expected auth-path availability error"),
        Err(err) => err,
    };
    assert!(err.to_string().contains("not available"));
    assert!(err.to_string().contains("platform-api-key"));
}

#[tokio::test]
async fn factory_rejects_minimax_without_auth() {
    let factory = no_auth_factory();
    let err = expect_auth_error(&factory, "MiniMax-M2.5").await;
    assert_eq!(err.category(), "auth");
    assert!(err.to_string().contains("MiniMax"));
}

#[tokio::test]
async fn factory_detects_minimax_from_model_id() {
    let factory = no_auth_factory();
    let err = expect_auth_error(&factory, "MiniMax-M2.5").await;
    // Should route to MiniMax (auth error, not unsupported model)
    assert_eq!(err.category(), "auth");
}

#[tokio::test]
async fn factory_strips_minimax_prefix() {
    let factory = no_auth_factory();
    let err = expect_auth_error(&factory, "minimax/MiniMax-M2.5").await;
    assert_eq!(err.category(), "auth");
    assert!(err.to_string().contains("MiniMax"));
}

#[tokio::test]
async fn factory_rejects_kimi_without_auth() {
    let factory = no_auth_factory();
    let err = expect_auth_error(&factory, "kimi-k2.5").await;
    assert_eq!(err.category(), "auth");
    assert!(err.to_string().contains("Kimi"));
}

#[tokio::test]
async fn factory_detects_kimi_from_model_id() {
    let factory = no_auth_factory();
    let err = expect_auth_error(&factory, "kimi-k2.5").await;
    assert_eq!(err.category(), "auth");
}

#[tokio::test]
async fn factory_detects_moonshot_from_model_id() {
    let factory = no_auth_factory();
    let err = expect_auth_error(&factory, "moonshot-v1-128k").await;
    assert_eq!(err.category(), "auth");
    assert!(err.to_string().contains("Kimi"));
}

#[tokio::test]
async fn factory_strips_kimi_prefix() {
    let factory = no_auth_factory();
    let err = expect_auth_error(&factory, "kimi/kimi-k2.5").await;
    assert_eq!(err.category(), "auth");
    assert!(err.to_string().contains("Kimi"));
}

#[tokio::test]
async fn factory_uses_api_key_when_no_oauth_exists() {
    // When auth.json has no OAuth tokens and no API key, should fail
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("auth.json");
    // Write empty auth.json (no OAuth tokens, no API key in file)
    std::fs::write(&path, "{}").unwrap();

    let settings = crate::domains::settings::TronSettings::default();
    let factory = DefaultProviderFactory::new(&settings).with_auth_path(path);

    // No OAuth, no auth.json credentials → should fail with auth error
    let err = expect_auth_error(&factory, "claude-opus-4-6").await;
    assert_eq!(err.category(), "auth");
    assert!(
        err.to_string().contains("Anthropic"),
        "should be Anthropic auth error: {err}"
    );
}

#[tokio::test]
async fn factory_errors_when_oauth_fails_and_no_api_key() {
    // Set up auth.json with expired OAuth tokens (refresh will fail without network)
    // and NO API key available — should error
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("auth.json");
    let expired_tokens = crate::domains::auth::credentials::OAuthTokens {
        access_token: "expired-tok".into(),
        refresh_token: "old-ref".into(),
        expires_at: 0, // long expired
    };
    crate::domains::auth::credentials::storage::save_account_oauth_tokens(
        &path,
        "anthropic",
        "test",
        &expired_tokens,
    )
    .unwrap();

    let settings = crate::domains::settings::TronSettings::default();
    let factory = DefaultProviderFactory::new(&settings).with_auth_path(path);

    // Should fail: OAuth exists but refresh fails, and no API key is available.
    let err = expect_auth_error(&factory, "claude-opus-4-6").await;
    assert!(
        err.to_string().contains("auth") || err.to_string().contains("Auth"),
        "should report auth failure: {err}"
    );
}

// ── Ollama (no auth required) ─────────────────────────────────────

#[tokio::test]
async fn factory_creates_ollama_without_auth() {
    let factory = no_auth_factory();
    // Ollama doesn't need auth — should succeed (create provider, not error)
    let result = factory.create_for_model("gemma4:e4b").await;
    assert!(
        result.is_ok(),
        "Ollama should not require auth: {}",
        result.err().map_or(String::new(), |e| e.to_string())
    );
    let provider = result.unwrap();
    assert_eq!(
        provider.provider_type(),
        crate::shared::protocol::messages::Provider::Ollama
    );
    assert_eq!(provider.model(), "gemma4:e4b");
}

#[tokio::test]
async fn factory_creates_ollama_with_prefix() {
    let factory = no_auth_factory();
    let result = factory.create_for_model("ollama/gemma4:e4b").await;
    assert!(result.is_ok());
    assert_eq!(result.unwrap().model(), "gemma4:e4b");
}

#[tokio::test]
async fn factory_creates_ollama_26b() {
    let factory = no_auth_factory();
    let result = factory.create_for_model("gemma4:26b").await;
    assert!(result.is_ok());
    assert_eq!(result.unwrap().model(), "gemma4:26b");
}

#[test]
fn factory_captures_ollama_base_url() {
    let mut settings = crate::domains::settings::TronSettings::default();
    settings.api.ollama = Some(crate::domains::settings::OllamaApiSettings {
        base_url: "http://192.168.1.100:11434".into(),
    });
    let factory = DefaultProviderFactory::new(&settings);
    assert_eq!(
        factory.ollama_base_url.as_deref(),
        Some("http://192.168.1.100:11434")
    );
}

#[test]
fn factory_ollama_base_url_none_by_default() {
    let settings = crate::domains::settings::TronSettings::default();
    let factory = DefaultProviderFactory::new(&settings);
    assert!(factory.ollama_base_url.is_none());
}

#[tokio::test]
async fn factory_unknown_model_returns_unsupported_model() {
    let factory = no_auth_factory();

    let Err(err) = factory.create_for_model("totally-unknown-model").await else {
        panic!("expected UnsupportedModel");
    };
    match err {
        ProviderError::UnsupportedModel { model } => {
            assert_eq!(model, "totally-unknown-model");
        }
        _ => panic!("expected UnsupportedModel, got: {err}"),
    }
}
