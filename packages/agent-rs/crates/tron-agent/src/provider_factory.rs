//! Default provider factory — creates providers on-demand per model.
//!
//! Auth is re-loaded from disk on each call so refreshed OAuth tokens
//! are picked up immediately after a token refresh or model switch.

use std::path::PathBuf;
use std::sync::Arc;

use async_trait::async_trait;
use tracing::{info, warn};
use tron_llm::models::registry::{detect_provider_from_model, strip_provider_prefix};
use tron_llm::models::types::ProviderType;
use tron_llm::provider::{Provider, ProviderError, ProviderFactory};

// ─── Captured settings ───────────────────────────────────────────────

/// Anthropic-specific settings captured at startup.
#[derive(Clone, Debug)]
struct AnthropicSettings {
    client_id: String,
    system_prompt_prefix: String,
    token_expiry_buffer_seconds: u64,
    oauth_beta_headers: String,
    preferred_account: Option<String>,
}

/// Retry settings captured at startup.
#[derive(Clone, Debug)]
struct CapturedRetrySettings {
    max_retries: u32,
    base_delay_ms: u64,
    max_delay_ms: u64,
    jitter_factor: f64,
}

/// Default factory that creates a fresh `Provider` for any supported model.
///
/// The factory captures config at startup but re-reads auth on every call
/// so that refreshed OAuth tokens take effect without restarting.
pub struct DefaultProviderFactory {
    auth_path: PathBuf,
    anthropic: AnthropicSettings,
    retry: CapturedRetrySettings,
    /// Shared HTTP client — connection pool reused across all providers.
    http_client: reqwest::Client,
}

impl DefaultProviderFactory {
    /// Create a new factory from the current server settings.
    pub fn new(settings: &tron_settings::TronSettings) -> Self {
        let http_client = reqwest::Client::builder()
            .pool_idle_timeout(std::time::Duration::from_secs(90))
            .timeout(std::time::Duration::from_secs(300))
            .user_agent("tron-agent/1.0")
            .build()
            .unwrap_or_default();

        Self {
            auth_path: auth_path(),
            anthropic: AnthropicSettings {
                client_id: settings.api.anthropic.client_id.clone(),
                system_prompt_prefix: settings.api.anthropic.system_prompt_prefix.clone(),
                token_expiry_buffer_seconds: settings.api.anthropic.token_expiry_buffer_seconds,
                oauth_beta_headers: settings.api.anthropic.oauth_beta_headers.clone(),
                preferred_account: settings.server.anthropic_account.clone(),
            },
            retry: CapturedRetrySettings {
                max_retries: settings.retry.max_retries,
                base_delay_ms: settings.retry.base_delay_ms,
                max_delay_ms: settings.retry.max_delay_ms,
                jitter_factor: settings.retry.jitter_factor,
            },
            http_client,
        }
    }

    /// Override the auth path (for testing with non-existent auth files).
    #[cfg(test)]
    pub(crate) fn with_auth_path(mut self, path: PathBuf) -> Self {
        self.auth_path = path;
        self
    }

    /// Get a clone of the shared HTTP client.
    pub fn http_client(&self) -> reqwest::Client {
        self.http_client.clone()
    }

    // ── Per-provider construction ────────────────────────────────────

    async fn create_anthropic(&self, model: &str) -> Result<Arc<dyn Provider>, ProviderError> {
        let mut oauth_config = tron_llm::auth::anthropic::default_config();
        if !self.anthropic.client_id.is_empty() {
            oauth_config.client_id = self.anthropic.client_id.clone();
        }
        let env_token = std::env::var("CLAUDE_CODE_OAUTH_TOKEN").ok();
        let preferred = self.anthropic.preferred_account.as_deref();

        let server_auth = match tron_llm::auth::anthropic::load_server_auth_with_client(
            &self.auth_path,
            &oauth_config,
            env_token.as_deref(),
            preferred,
            &self.http_client,
        )
        .await
        {
            Ok(Some(auth)) => auth,
            Ok(None) => match std::env::var("ANTHROPIC_API_KEY") {
                Ok(key) => {
                    info!("using ANTHROPIC_API_KEY env var (no OAuth tokens found)");
                    tron_llm::auth::ServerAuth::from_api_key(key)
                }
                Err(_) => {
                    return Err(ProviderError::Auth {
                        message: "no Anthropic auth available (OAuth or API key)".into(),
                    });
                }
            },
            Err(e) => match std::env::var("ANTHROPIC_API_KEY") {
                Ok(key) => {
                    warn!(error = %e, "Anthropic OAuth failed, falling back to API key");
                    tron_llm::auth::ServerAuth::from_api_key(key)
                }
                Err(_) => {
                    return Err(ProviderError::Auth {
                        message: format!("Anthropic auth failed: {e}"),
                    });
                }
            },
        };

        let auth = match server_auth {
            tron_llm::auth::ServerAuth::OAuth {
                access_token,
                refresh_token,
                expires_at,
                account_label,
            } => tron_llm::anthropic::types::AnthropicAuth::OAuth {
                tokens: tron_llm::auth::OAuthTokens {
                    access_token,
                    refresh_token,
                    expires_at,
                },
                account_label,
            },
            tron_llm::auth::ServerAuth::ApiKey { api_key } => {
                tron_llm::anthropic::types::AnthropicAuth::ApiKey { api_key }
            }
        };

        let config = tron_llm::anthropic::types::AnthropicConfig {
            model: model.to_string(),
            auth,
            max_tokens: None,
            base_url: None,
            retry: Some(tron_llm::StreamRetryConfig {
                retry: tron_core::retry::RetryConfig {
                    max_retries: self.retry.max_retries,
                    base_delay_ms: self.retry.base_delay_ms,
                    max_delay_ms: self.retry.max_delay_ms,
                    jitter_factor: self.retry.jitter_factor,
                },
                emit_retry_events: true,
                cancel_token: None,
            }),
            provider_settings: tron_llm::anthropic::types::AnthropicProviderSettings {
                system_prompt_prefix: Some(self.anthropic.system_prompt_prefix.clone()),
                token_expiry_buffer_seconds: Some(self.anthropic.token_expiry_buffer_seconds),
                oauth_beta_headers: self.anthropic.oauth_beta_headers.clone(),
            },
        };
        Ok(Arc::new(
            tron_llm::anthropic::provider::AnthropicProvider::with_client(config, self.http_client.clone()),
        ))
    }

    async fn create_openai(&self, model: &str) -> Result<Arc<dyn Provider>, ProviderError> {
        let env_token = std::env::var("OPENAI_OAUTH_TOKEN").ok();
        let env_api_key = std::env::var("OPENAI_API_KEY").ok();

        let server_auth = match tron_llm::auth::openai::load_server_auth_with_client(
            &self.auth_path,
            env_token.as_deref(),
            env_api_key.as_deref(),
            &self.http_client,
        )
        .await
        {
            Ok(Some(auth)) => auth,
            Ok(None) => {
                return Err(ProviderError::Auth {
                    message: "no OpenAI auth available (set OPENAI_API_KEY or sign in)".into(),
                });
            }
            Err(e) => {
                return Err(ProviderError::Auth {
                    message: format!("OpenAI auth failed: {e}"),
                });
            }
        };

        let tokens = match server_auth {
            tron_llm::auth::ServerAuth::OAuth {
                access_token,
                refresh_token,
                expires_at,
                ..
            } => tron_llm::auth::OAuthTokens {
                access_token,
                refresh_token,
                expires_at,
            },
            tron_llm::auth::ServerAuth::ApiKey { api_key } => tron_llm::auth::OAuthTokens {
                access_token: api_key,
                refresh_token: String::new(),
                expires_at: i64::MAX,
            },
        };

        let config = tron_llm::openai::types::OpenAIConfig {
            model: model.to_string(),
            auth: tron_llm::openai::types::OpenAIAuth::OAuth { tokens },
            max_tokens: None,
            temperature: None,
            base_url: None,
            reasoning_effort: None,
            provider_settings: tron_llm::openai::types::OpenAIApiSettings::default(),
        };
        Ok(Arc::new(
            tron_llm::openai::provider::OpenAIProvider::with_client(config, self.http_client.clone()),
        ))
    }

    async fn create_google(&self, model: &str) -> Result<Arc<dyn Provider>, ProviderError> {
        let env_token = std::env::var("GOOGLE_OAUTH_TOKEN").ok();
        let env_api_key = std::env::var("GOOGLE_API_KEY").ok();

        let google_auth = match tron_llm::auth::google::load_server_auth_with_client(
            &self.auth_path,
            env_token.as_deref(),
            env_api_key.as_deref(),
            &self.http_client,
        )
        .await
        {
            Ok(Some(auth)) => auth,
            Ok(None) => {
                return Err(ProviderError::Auth {
                    message: "no Google auth available (set GOOGLE_API_KEY or sign in)".into(),
                });
            }
            Err(e) => {
                return Err(ProviderError::Auth {
                    message: format!("Google auth failed: {e}"),
                });
            }
        };

        let auth = match google_auth.auth {
            tron_llm::auth::ServerAuth::OAuth {
                access_token,
                refresh_token,
                expires_at,
                ..
            } => {
                let endpoint = google_auth
                    .endpoint
                    .map(|e| match e {
                        tron_llm::auth::GoogleOAuthEndpoint::CloudCodeAssist => {
                            tron_llm::google::types::GoogleOAuthEndpoint::CloudCodeAssist
                        }
                        tron_llm::auth::GoogleOAuthEndpoint::Antigravity => {
                            tron_llm::google::types::GoogleOAuthEndpoint::Antigravity
                        }
                    })
                    .unwrap_or_default();
                tron_llm::google::types::GoogleAuth::Oauth {
                    tokens: tron_llm::auth::OAuthTokens {
                        access_token,
                        refresh_token,
                        expires_at,
                    },
                    endpoint,
                    project_id: google_auth.project_id,
                }
            }
            tron_llm::auth::ServerAuth::ApiKey { api_key } => {
                tron_llm::google::types::GoogleAuth::ApiKey { api_key }
            }
        };

        let config = tron_llm::google::types::GoogleConfig {
            model: model.to_string(),
            auth,
            max_tokens: None,
            temperature: None,
            base_url: None,
            thinking_level: None,
            thinking_budget: None,
            safety_settings: None,
            provider_settings: tron_llm::google::types::GoogleApiSettings::default(),
        };
        Ok(Arc::new(
            tron_llm::google::provider::GoogleProvider::with_client(config, self.http_client.clone()),
        ))
    }
}

#[async_trait]
impl ProviderFactory for DefaultProviderFactory {
    async fn create_for_model(&self, model: &str) -> Result<Arc<dyn Provider>, ProviderError> {
        let bare_model = strip_provider_prefix(model);
        let provider_type = detect_provider_from_model(model, false).unwrap_or_else(|| {
            warn!(model, "unknown model, defaulting to Anthropic");
            ProviderType::Anthropic
        });

        match provider_type {
            ProviderType::Anthropic => self.create_anthropic(bare_model).await,
            ProviderType::OpenAi => self.create_openai(bare_model).await,
            ProviderType::Google => self.create_google(bare_model).await,
        }
    }
}

/// Resolve the auth file path (`~/.tron/auth.json`).
fn auth_path() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(home).join(".tron").join("auth.json")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a factory that reads from a non-existent auth file (no credentials).
    fn no_auth_factory() -> DefaultProviderFactory {
        let settings = tron_settings::TronSettings::default();
        DefaultProviderFactory::new(&settings)
            .with_auth_path(PathBuf::from("/tmp/tron-test-no-such-auth.json"))
    }

    #[test]
    fn factory_captures_anthropic_settings() {
        let mut settings = tron_settings::TronSettings::default();
        settings.api.anthropic.client_id = "test-client-id".into();
        settings.server.anthropic_account = Some("work".into());

        let factory = DefaultProviderFactory::new(&settings);
        assert_eq!(factory.anthropic.client_id, "test-client-id");
        assert_eq!(
            factory.anthropic.preferred_account,
            Some("work".to_string())
        );
    }

    #[test]
    fn factory_default_settings() {
        let settings = tron_settings::TronSettings::default();
        let factory = DefaultProviderFactory::new(&settings);
        assert!(factory.anthropic.preferred_account.is_none());
    }

    #[test]
    fn factory_captures_retry_settings() {
        let mut settings = tron_settings::TronSettings::default();
        settings.retry.max_retries = 5;
        settings.retry.base_delay_ms = 2000;
        settings.retry.max_delay_ms = 30_000;
        settings.retry.jitter_factor = 0.3;

        let factory = DefaultProviderFactory::new(&settings);
        assert_eq!(factory.retry.max_retries, 5);
        assert_eq!(factory.retry.base_delay_ms, 2000);
        assert_eq!(factory.retry.max_delay_ms, 30_000);
        assert!((factory.retry.jitter_factor - 0.3).abs() < f64::EPSILON);
    }

    #[test]
    fn factory_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<DefaultProviderFactory>();
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
    async fn factory_unknown_model_defaults_anthropic() {
        let factory = no_auth_factory();

        // Unknown model → defaults to Anthropic
        let err = expect_auth_error(&factory, "totally-unknown-model").await;
        assert!(err.to_string().contains("Anthropic"));
    }
}
