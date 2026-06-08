//! Default provider factory — creates providers on-demand per model.
//!
//! Auth is re-loaded from disk on each call so refreshed OAuth tokens
//! are picked up immediately after a token refresh or model switch.

use std::path::PathBuf;
use std::sync::Arc;

use crate::domains::model::providers::shared::provider::{
    Provider, ProviderError, ProviderFactory,
};
use crate::domains::model::routing::models::registry::{
    detect_provider_from_model, strip_provider_prefix,
};
use async_trait::async_trait;
use tracing::info;

// ─── Captured settings ───────────────────────────────────────────────

/// Anthropic-specific settings captured at startup.
#[derive(Clone, Debug)]
struct AnthropicSettings {
    client_id: String,
    system_prompt_prefix: String,
    token_expiry_buffer_seconds: u64,
    oauth_beta_headers: String,
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
    /// `MiniMax` base URL override from settings.
    minimax_base_url: Option<String>,
    /// Kimi base URL override from settings.
    kimi_base_url: Option<String>,
    /// Ollama base URL override from settings.
    ollama_base_url: Option<String>,
    /// Shared HTTP client — connection pool reused across all providers.
    http_client: reqwest::Client,
}

impl DefaultProviderFactory {
    /// Create a new factory from the current server settings.
    pub fn new(settings: &crate::domains::settings::TronSettings) -> Self {
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
            },
            retry: CapturedRetrySettings {
                max_retries: settings.retry.max_retries,
                base_delay_ms: settings.retry.base_delay_ms,
                max_delay_ms: settings.retry.max_delay_ms,
                jitter_factor: settings.retry.jitter_factor,
            },
            minimax_base_url: settings.api.minimax.as_ref().map(|m| m.base_url.clone()),
            kimi_base_url: settings.api.kimi.as_ref().map(|k| k.base_url.clone()),
            ollama_base_url: settings.api.ollama.as_ref().map(|o| o.base_url.clone()),
            http_client,
        }
    }

    /// Override the auth path (for testing with non-existent auth files).
    #[must_use]
    pub fn with_auth_path(mut self, path: PathBuf) -> Self {
        self.auth_path = path;
        self
    }

    /// Get a clone of the shared HTTP client.
    pub fn http_client(&self) -> reqwest::Client {
        self.http_client.clone()
    }

    // ── Per-provider construction ────────────────────────────────────

    async fn create_anthropic_with_credential(
        &self,
        model: &str,
        credential_override: Option<&crate::domains::auth::credentials::ActiveCredential>,
    ) -> Result<Arc<dyn Provider>, ProviderError> {
        let mut oauth_config = crate::domains::auth::credentials::anthropic::default_config();
        if !self.anthropic.client_id.is_empty() {
            oauth_config.client_id = self.anthropic.client_id.clone();
        }

        let server_auth =
            match crate::domains::auth::credentials::anthropic::load_server_auth_with_client(
                &self.auth_path,
                &oauth_config,
                credential_override,
                &self.http_client,
            )
            .await
            {
                Ok(Some(auth)) => auth,
                Ok(None) => {
                    return Err(ProviderError::Auth {
                        message:
                            "no Anthropic auth configured — add credentials in Settings > Providers"
                                .into(),
                    });
                }
                Err(e) => {
                    if e.is_transient() {
                        return Err(ProviderError::Api {
                            status: match &e {
                                crate::domains::auth::credentials::errors::AuthError::OAuth {
                                    status,
                                    ..
                                } => *status,
                                crate::domains::auth::credentials::errors::AuthError::Http(he) => {
                                    he.status().map_or(503, |s| s.as_u16())
                                }
                                _ => 503,
                            },
                            message: format!("Anthropic auth failed (transient): {e}"),
                            code: None,
                            retryable: true,
                        });
                    }
                    return Err(ProviderError::Auth {
                        message: format!("Anthropic auth failed: {e}"),
                    });
                }
            };

        let auth = match server_auth {
            crate::domains::auth::credentials::ServerAuth::OAuth {
                access_token,
                refresh_token,
                expires_at,
            } => crate::domains::model::providers::anthropic::types::AnthropicAuth::OAuth {
                tokens: crate::domains::auth::credentials::OAuthTokens {
                    access_token,
                    refresh_token,
                    expires_at,
                },
            },
            crate::domains::auth::credentials::ServerAuth::ApiKey { api_key } => {
                crate::domains::model::providers::anthropic::types::AnthropicAuth::ApiKey {
                    api_key,
                }
            }
        };

        let config = crate::domains::model::providers::anthropic::types::AnthropicConfig {
            model: model.to_string(),
            auth,
            max_tokens: None,
            base_url: None,
            retry: Some(
                crate::domains::model::providers::shared::StreamRetryConfig {
                    retry: crate::shared::foundation::retry::RetryConfig {
                        max_retries: self.retry.max_retries,
                        base_delay_ms: self.retry.base_delay_ms,
                        max_delay_ms: self.retry.max_delay_ms,
                        jitter_factor: self.retry.jitter_factor,
                    },
                    emit_retry_events: true,
                    cancel_token: None,
                },
            ),
            provider_settings:
                crate::domains::model::providers::anthropic::types::AnthropicProviderSettings {
                    system_prompt_prefix: Some(self.anthropic.system_prompt_prefix.clone()),
                    token_expiry_buffer_seconds: Some(self.anthropic.token_expiry_buffer_seconds),
                    oauth_beta_headers: self.anthropic.oauth_beta_headers.clone(),
                },
        };
        Ok(Arc::new(
            crate::domains::model::providers::anthropic::provider::AnthropicProvider::with_client(
                config,
                self.http_client.clone(),
            ),
        ))
    }

    async fn create_openai_with_credential(
        &self,
        model: &str,
        credential_override: Option<&crate::domains::auth::credentials::ActiveCredential>,
    ) -> Result<Arc<dyn Provider>, ProviderError> {
        let server_auth =
            match crate::domains::auth::credentials::openai::load_server_auth_with_client(
                &self.auth_path,
                credential_override,
                &self.http_client,
            )
            .await
            {
                Ok(Some(auth)) => auth,
                Ok(None) => {
                    return Err(ProviderError::Auth {
                        message:
                            "no OpenAI auth configured — add credentials in Settings > Providers"
                                .into(),
                    });
                }
                Err(e) => {
                    return Err(ProviderError::Auth {
                        message: format!("OpenAI auth failed: {e}"),
                    });
                }
            };

        let (auth, auth_path) = match server_auth {
            crate::domains::auth::credentials::ServerAuth::OAuth {
                access_token,
                refresh_token,
                expires_at,
                ..
            } => (
                crate::domains::model::providers::openai::types::OpenAIAuth::OAuth {
                    tokens: crate::domains::auth::credentials::OAuthTokens {
                        access_token,
                        refresh_token,
                        expires_at,
                    },
                },
                crate::domains::model::providers::openai::types::OpenAIAuthPath::ChatGptCodex,
            ),
            crate::domains::auth::credentials::ServerAuth::ApiKey { api_key } => (
                crate::domains::model::providers::openai::types::OpenAIAuth::ApiKey { api_key },
                crate::domains::model::providers::openai::types::OpenAIAuthPath::PlatformApiKey,
            ),
        };
        let request_model =
            crate::domains::model::providers::openai::types::openai_request_model_id(model);
        if !crate::domains::model::providers::openai::types::openai_model_available_for_auth_path(
            &request_model,
            auth_path,
        ) {
            return Err(ProviderError::Other {
                message: format!(
                    "OpenAI model '{model}' is not available for the active auth path ({})",
                    auth_path.as_str()
                ),
            });
        }

        let config = crate::domains::model::providers::openai::types::OpenAIConfig {
            model: request_model,
            auth,
            max_tokens: None,
            temperature: None,
            base_url: None,
            reasoning_effort: None,
            provider_settings:
                crate::domains::model::providers::openai::types::OpenAIApiSettings::default(),
        };
        Ok(Arc::new(
            crate::domains::model::providers::openai::provider::OpenAIProvider::with_client(
                config,
                self.http_client.clone(),
            ),
        ))
    }

    async fn create_google_with_credential(
        &self,
        model: &str,
        credential_override: Option<&crate::domains::auth::credentials::ActiveCredential>,
    ) -> Result<Arc<dyn Provider>, ProviderError> {
        let google_auth =
            match crate::domains::auth::credentials::google::load_server_auth_with_client(
                &self.auth_path,
                credential_override,
                &self.http_client,
            )
            .await
            {
                Ok(Some(auth)) => auth,
                Ok(None) => {
                    return Err(ProviderError::Auth {
                        message:
                            "no Google auth configured — add credentials in Settings > Providers"
                                .into(),
                    });
                }
                Err(e) => {
                    return Err(ProviderError::Auth {
                        message: format!("Google auth failed: {e}"),
                    });
                }
            };

        let google_auth_is_oauth = google_auth.auth.is_oauth();
        let auth = match google_auth.auth {
            crate::domains::auth::credentials::ServerAuth::OAuth {
                access_token,
                refresh_token,
                expires_at,
                ..
            } => crate::domains::model::providers::google::types::GoogleAuth::Oauth {
                tokens: crate::domains::auth::credentials::OAuthTokens {
                    access_token,
                    refresh_token,
                    expires_at,
                },
                project_id: google_auth.project_id,
            },
            crate::domains::auth::credentials::ServerAuth::ApiKey { api_key } => {
                crate::domains::model::providers::google::types::GoogleAuth::ApiKey { api_key }
            }
        };

        // Populate provider_settings with client credentials for mid-session
        // token refresh. Without this, ensure_valid_tokens() would fail after
        // the access token expires (~1 hour).
        let provider_settings = if google_auth_is_oauth {
            let gpa = crate::domains::auth::credentials::storage::get_google_provider_auth(
                &self.auth_path,
            )
            .map_err(|e| ProviderError::Auth {
                message: e.to_string(),
            })?;
            crate::domains::model::providers::google::types::GoogleApiSettings {
                token_url: None,
                client_id: gpa.as_ref().and_then(|g| g.client_id.clone()),
                client_secret: gpa.as_ref().and_then(|g| g.client_secret.clone()),
            }
        } else {
            crate::domains::model::providers::google::types::GoogleApiSettings::default()
        };

        let config = crate::domains::model::providers::google::types::GoogleConfig {
            model: model.to_string(),
            auth,
            max_tokens: None,
            temperature: None,
            base_url: None,
            thinking_level: None,
            thinking_budget: None,
            safety_settings: None,
            provider_settings,
        };
        Ok(Arc::new(
            crate::domains::model::providers::google::provider::GoogleProvider::with_client(
                config,
                self.http_client.clone(),
            ),
        ))
    }
    fn create_minimax(&self, model: &str) -> Result<Arc<dyn Provider>, ProviderError> {
        let provider_auth = crate::domains::auth::credentials::storage::get_provider_auth(
            &self.auth_path,
            "minimax",
        )
        .map_err(|e| ProviderError::Auth {
            message: e.to_string(),
        })?;
        let api_key = if let Some(pa) = provider_auth {
            if let Some(key) = pa
                .api_keys
                .as_ref()
                .and_then(|k| k.first())
                .map(|k| k.key.clone())
            {
                info!("using MiniMax API key from auth.json");
                key
            } else {
                return Err(ProviderError::Auth {
                    message: "MiniMax entry in auth.json has no apiKey".into(),
                });
            }
        } else {
            return Err(ProviderError::Auth {
                message: "no MiniMax auth configured — add API key in Settings > Providers".into(),
            });
        };

        let config = crate::domains::model::providers::minimax::types::MiniMaxConfig {
            model: model.to_string(),
            auth: crate::domains::model::providers::minimax::types::MiniMaxAuth::ApiKey { api_key },
            max_tokens: None,
            base_url: self.minimax_base_url.clone(),
            retry: Some(
                crate::domains::model::providers::shared::StreamRetryConfig {
                    retry: crate::shared::foundation::retry::RetryConfig {
                        max_retries: self.retry.max_retries,
                        base_delay_ms: self.retry.base_delay_ms,
                        max_delay_ms: self.retry.max_delay_ms,
                        jitter_factor: self.retry.jitter_factor,
                    },
                    emit_retry_events: true,
                    cancel_token: None,
                },
            ),
        };
        Ok(Arc::new(
            crate::domains::model::providers::minimax::provider::MiniMaxProvider::with_client(
                config,
                self.http_client.clone(),
            ),
        ))
    }

    fn create_kimi(&self, model: &str) -> Result<Arc<dyn Provider>, ProviderError> {
        let provider_auth =
            crate::domains::auth::credentials::storage::get_provider_auth(&self.auth_path, "kimi")
                .map_err(|e| ProviderError::Auth {
                    message: e.to_string(),
                })?;
        let api_key = if let Some(pa) = provider_auth {
            if let Some(key) = pa
                .api_keys
                .as_ref()
                .and_then(|k| k.first())
                .map(|k| k.key.clone())
            {
                info!("using Kimi API key from auth.json");
                key
            } else {
                return Err(ProviderError::Auth {
                    message: "Kimi entry in auth.json has no apiKey".into(),
                });
            }
        } else {
            return Err(ProviderError::Auth {
                message: "no Kimi auth configured — add API key in Settings > Providers".into(),
            });
        };

        let config = crate::domains::model::providers::kimi::types::KimiConfig {
            model: model.to_string(),
            auth: crate::domains::model::providers::kimi::types::KimiAuth::ApiKey { api_key },
            max_tokens: None,
            base_url: self.kimi_base_url.clone(),
            retry: Some(
                crate::domains::model::providers::shared::StreamRetryConfig {
                    retry: crate::shared::foundation::retry::RetryConfig {
                        max_retries: self.retry.max_retries,
                        base_delay_ms: self.retry.base_delay_ms,
                        max_delay_ms: self.retry.max_delay_ms,
                        jitter_factor: self.retry.jitter_factor,
                    },
                    emit_retry_events: true,
                    cancel_token: None,
                },
            ),
        };
        Ok(Arc::new(
            crate::domains::model::providers::kimi::provider::KimiProvider::with_client(
                config,
                self.http_client.clone(),
            ),
        ))
    }

    /// Create an Ollama provider — no auth required (local inference).
    fn create_ollama(&self, model: &str) -> Result<Arc<dyn Provider>, ProviderError> {
        info!("creating Ollama provider for model: {model}");
        let config = crate::domains::model::providers::ollama::types::OllamaConfig {
            model: model.to_string(),
            base_url: self.ollama_base_url.clone(),
            max_tokens: None,
            retry: Some(
                crate::domains::model::providers::shared::StreamRetryConfig {
                    retry: crate::shared::foundation::retry::RetryConfig {
                        max_retries: self.retry.max_retries,
                        base_delay_ms: self.retry.base_delay_ms,
                        max_delay_ms: self.retry.max_delay_ms,
                        jitter_factor: self.retry.jitter_factor,
                    },
                    emit_retry_events: true,
                    cancel_token: None,
                },
            ),
        };
        Ok(Arc::new(
            crate::domains::model::providers::ollama::provider::OllamaProvider::with_client(
                config,
                self.http_client.clone(),
            ),
        ))
    }
}

impl DefaultProviderFactory {
    /// Create a provider for the given model with an optional credential override.
    ///
    /// Used by [`CredentialPinnedProviderFactory`] for session auth isolation.
    async fn create_for_model_with_credential(
        &self,
        model: &str,
        credential_override: Option<&crate::domains::auth::credentials::ActiveCredential>,
    ) -> Result<Arc<dyn Provider>, ProviderError> {
        use crate::shared::protocol::messages::Provider as ProviderKind;

        let bare_model = strip_provider_prefix(model);
        let provider_type =
            detect_provider_from_model(model).ok_or_else(|| ProviderError::UnsupportedModel {
                model: model.to_string(),
            })?;

        // Only pass credential_override to providers that support it.
        // MiniMax/Kimi use simple API keys without credential selection.
        match provider_type {
            ProviderKind::Anthropic => {
                self.create_anthropic_with_credential(bare_model, credential_override)
                    .await
            }
            ProviderKind::OpenAi | ProviderKind::OpenAiCodex => {
                self.create_openai_with_credential(bare_model, credential_override)
                    .await
            }
            ProviderKind::Google => {
                self.create_google_with_credential(bare_model, credential_override)
                    .await
            }
            ProviderKind::MiniMax => self.create_minimax(bare_model),
            ProviderKind::Kimi => self.create_kimi(bare_model),
            ProviderKind::Ollama => self.create_ollama(bare_model),
            ProviderKind::Unknown => Err(ProviderError::UnsupportedModel {
                model: bare_model.to_string(),
            }),
        }
    }
}

#[async_trait]
impl ProviderFactory for DefaultProviderFactory {
    async fn create_for_model(&self, model: &str) -> Result<Arc<dyn Provider>, ProviderError> {
        self.create_for_model_with_credential(model, None).await
    }
}

/// Resolve the auth file path (`~/.tron/profiles/auth.json`).
fn auth_path() -> PathBuf {
    crate::domains::settings::profile::storage::loader::auth_path()
}

#[cfg(test)]
mod tests {
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

    #[test]
    fn factory_captures_retry_settings() {
        let mut settings = crate::domains::settings::TronSettings::default();
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

        // Should fail — OAuth exists but refresh fails, no API key to fall back to
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
}
