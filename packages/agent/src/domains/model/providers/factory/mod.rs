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
                crate::domains::auth::credentials::OpenAIAuthPath::ChatGptCodex,
            ),
            crate::domains::auth::credentials::ServerAuth::ApiKey { api_key } => (
                crate::domains::model::providers::openai::types::OpenAIAuth::ApiKey { api_key },
                crate::domains::auth::credentials::OpenAIAuthPath::PlatformApiKey,
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
            let gpa = crate::domains::auth::credentials::get_google_provider_auth(&self.auth_path)
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
        let provider_auth =
            crate::domains::auth::credentials::get_provider_auth(&self.auth_path, "minimax")
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
            crate::domains::auth::credentials::get_provider_auth(&self.auth_path, "kimi").map_err(
                |e| ProviderError::Auth {
                    message: e.to_string(),
                },
            )?;
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
    crate::domains::settings::profile::auth_path()
}

#[cfg(test)]
mod tests;
