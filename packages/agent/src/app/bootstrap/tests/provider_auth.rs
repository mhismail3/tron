use crate::domains::model::providers::factory as provider_factory;
use crate::domains::model::providers::shared::provider::ProviderFactory;
use crate::domains::settings::TronSettings;
use std::path::PathBuf;

#[tokio::test]
async fn factory_unknown_model_returns_unsupported_model_error() {
    let settings = TronSettings::default();
    let factory = provider_factory::DefaultProviderFactory::new(&settings)
        .with_auth_path(PathBuf::from("/tmp/tron-test-no-such-auth.json"));
    let result = factory.create_for_model("unknown-model").await;
    assert!(matches!(
        result,
        Err(
            crate::domains::model::providers::shared::provider::ProviderError::UnsupportedModel { .. }
        )
    ));
}
#[tokio::test]
async fn openai_returns_none_without_auth() {
    // With no auth.json, OpenAI returns None
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("auth.json");
    let result = crate::domains::auth::credentials::openai::load_server_auth(&path)
        .await
        .unwrap();
    assert!(result.is_none());
}

#[tokio::test]
async fn google_returns_none_without_auth() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("auth.json");
    let result = crate::domains::auth::credentials::google::load_server_auth(&path)
        .await
        .unwrap();
    assert!(result.is_none());
}
#[tokio::test]
async fn create_anthropic_with_oauth_from_file() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("auth.json");

    // Save fresh OAuth tokens
    let tokens = crate::domains::auth::credentials::OAuthTokens {
        access_token: "sk-ant-oat-test".to_string(),
        refresh_token: "ref".to_string(),
        expires_at: crate::domains::auth::credentials::now_ms() + 3_600_000,
    };
    crate::domains::auth::credentials::storage::save_account_oauth_tokens(
        &path,
        "anthropic",
        "test",
        &tokens,
    )
    .unwrap();

    // load_server_auth should find the OAuth tokens
    let config = crate::domains::auth::credentials::anthropic::default_config();
    let result = crate::domains::auth::credentials::anthropic::load_server_auth(&path, &config)
        .await
        .unwrap();
    let auth = result.unwrap();
    assert!(auth.is_oauth());
    assert_eq!(auth.token(), "sk-ant-oat-test");
}

#[tokio::test]
async fn create_anthropic_oauth_over_api_key() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("auth.json");

    // Save both OAuth account and API key
    crate::domains::auth::credentials::storage::save_named_api_key(
        &path,
        "anthropic",
        "(default)",
        "sk-api-key",
    )
    .unwrap();
    let tokens = crate::domains::auth::credentials::OAuthTokens {
        access_token: "sk-ant-oat-primary".to_string(),
        refresh_token: "ref".to_string(),
        expires_at: crate::domains::auth::credentials::now_ms() + 3_600_000,
    };
    crate::domains::auth::credentials::storage::save_account_oauth_tokens(
        &path,
        "anthropic",
        "test",
        &tokens,
    )
    .unwrap();

    // OAuth takes priority
    let config = crate::domains::auth::credentials::anthropic::default_config();
    let result = crate::domains::auth::credentials::anthropic::load_server_auth(&path, &config)
        .await
        .unwrap();
    let auth = result.unwrap();
    assert!(auth.is_oauth());
    assert_eq!(auth.token(), "sk-ant-oat-primary");
}

#[tokio::test]
async fn create_anthropic_uses_first_account() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("auth.json");

    let work_tokens = crate::domains::auth::credentials::OAuthTokens {
        access_token: "work-tok".to_string(),
        refresh_token: "ref1".to_string(),
        expires_at: crate::domains::auth::credentials::now_ms() + 3_600_000,
    };
    crate::domains::auth::credentials::storage::save_account_oauth_tokens(
        &path,
        "anthropic",
        "work",
        &work_tokens,
    )
    .unwrap();

    let config = crate::domains::auth::credentials::anthropic::default_config();
    let result = crate::domains::auth::credentials::anthropic::load_server_auth(&path, &config)
        .await
        .unwrap();
    assert_eq!(result.unwrap().token(), "work-tok");
}

#[tokio::test]
async fn create_openai_with_oauth_from_file() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("auth.json");

    let tokens = crate::domains::auth::credentials::OAuthTokens {
        access_token: "openai-oauth-tok".to_string(),
        refresh_token: "ref".to_string(),
        expires_at: crate::domains::auth::credentials::now_ms() + 3_600_000,
    };
    crate::domains::auth::credentials::storage::save_account_oauth_tokens(
        &path,
        crate::domains::auth::credentials::openai::PROVIDER_KEY,
        "test",
        &tokens,
    )
    .unwrap();

    let result = crate::domains::auth::credentials::openai::load_server_auth(&path)
        .await
        .unwrap();
    let auth = result.unwrap();
    assert!(auth.is_oauth());
    assert_eq!(auth.token(), "openai-oauth-tok");
}

#[tokio::test]
async fn create_google_with_oauth_from_file() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("auth.json");

    // Save OAuth tokens via account path
    let tokens = crate::domains::auth::credentials::OAuthTokens {
        access_token: "ya29.google-tok".to_string(),
        refresh_token: "ref".to_string(),
        expires_at: crate::domains::auth::credentials::now_ms() + 3_600_000,
    };
    crate::domains::auth::credentials::storage::save_account_oauth_tokens(
        &path, "google", "(test)", &tokens,
    )
    .unwrap();

    // Set client_id (required for OAuth)
    let mut gpa = crate::domains::auth::credentials::storage::get_google_provider_auth(&path)
        .unwrap()
        .unwrap_or_default();
    gpa.client_id = Some("test-client-id".to_string());
    crate::domains::auth::credentials::storage::save_google_provider_auth(&path, &gpa).unwrap();

    let result = crate::domains::auth::credentials::google::load_server_auth(&path)
        .await
        .unwrap();
    let auth = result.unwrap();
    assert_eq!(auth.auth.token(), "ya29.google-tok");
    assert!(auth.project_id.is_none());
}

#[tokio::test]
async fn server_auth_maps_to_anthropic_oauth_auth() {
    let server_auth = crate::domains::auth::credentials::ServerAuth::OAuth {
        access_token: "tok".to_string(),
        refresh_token: "ref".to_string(),
        expires_at: 999,
    };
    assert!(server_auth.is_oauth());
    assert_eq!(server_auth.token(), "tok");
}

#[tokio::test]
async fn server_auth_maps_to_api_key_auth() {
    let server_auth = crate::domains::auth::credentials::ServerAuth::from_api_key("sk-123");
    assert!(!server_auth.is_oauth());
    assert_eq!(server_auth.token(), "sk-123");
}
