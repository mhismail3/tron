use super::*;

/// Providers that support OAuth login.
const OAUTH_PROVIDERS: &[&str] = &["anthropic", "openai-codex", "google"];

/// Begin an OAuth flow: generate PKCE (Anthropic) or state (OpenAI), return auth URL + flow ID.
pub struct OAuthBeginHandler;

#[async_trait]
impl MethodHandler for OAuthBeginHandler {
    #[instrument(skip(self, ctx), fields(method = "auth.oauthBegin"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let provider = require_string_param(params.as_ref(), "provider")?;

        let (auth_url, verifier_or_state) = match provider.as_str() {
            "anthropic" => {
                let pair = crate::llm::auth::pkce::generate_pkce();
                let config = crate::llm::auth::anthropic::default_config();
                // Use verifier as state (matches tron login CLI behavior)
                let url = crate::llm::auth::anthropic::get_authorization_url_with_state(
                    &config,
                    &pair.challenge,
                    Some(&pair.verifier),
                );
                (url, pair.verifier)
            }
            "openai-codex" => {
                let pair = crate::llm::auth::pkce::generate_pkce();
                let config = crate::llm::auth::openai::default_config();
                let url = crate::llm::auth::openai::get_authorization_url_with_state(
                    &config,
                    &pair.challenge,
                    Some(&pair.verifier),
                );
                (url, pair.verifier)
            }
            "google" => {
                let gpa = crate::llm::auth::storage::get_google_provider_auth(&ctx.auth_path)
                    .map_err(map_auth_error)?;
                let client_id = gpa
                    .as_ref()
                    .and_then(|g| g.client_id.clone())
                    .ok_or_else(|| RpcError::InvalidParams {
                        message: "Google OAuth requires a client_id — configure it in Settings > Providers > Google".into(),
                    })?;
                let client_secret = gpa.and_then(|g| g.client_secret);

                let base_cfg = crate::llm::auth::google::cloud_code_assist_config();
                let config = crate::llm::auth::google::GoogleOAuthConfig {
                    oauth: crate::llm::auth::types::OAuthConfig {
                        client_id,
                        client_secret,
                        ..base_cfg.oauth
                    },
                    ..base_cfg
                };

                let pair = crate::llm::auth::pkce::generate_pkce();
                let url = crate::llm::auth::google::get_authorization_url(&config, &pair.challenge);
                (url, pair.verifier)
            }
            _ => {
                return Err(RpcError::InvalidParams {
                    message: format!(
                        "OAuth login supported for: {}. Got: {provider}",
                        OAUTH_PROVIDERS.join(", "),
                    ),
                });
            }
        };

        let flow_id = uuid::Uuid::now_v7().to_string();

        let mut flows = ctx.oauth_flows.lock().await;

        // Lazy cleanup: remove expired flows (>10 minutes)
        flows.retain(|_, f| f.created_at.elapsed() < std::time::Duration::from_secs(600));

        let _ = flows.insert(
            flow_id.clone(),
            PendingOAuthFlow {
                verifier: verifier_or_state,
                provider,
                created_at: std::time::Instant::now(),
            },
        );

        Ok(json!({
            "flowId": flow_id,
            "authUrl": auth_url,
        }))
    }
}

/// Complete an OAuth flow: exchange code for tokens, save to auth.json.
pub struct OAuthCompleteHandler;

#[async_trait]
impl MethodHandler for OAuthCompleteHandler {
    #[instrument(skip(self, ctx), fields(method = "auth.oauthComplete"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let flow_id = require_string_param(params.as_ref(), "flowId")?;
        let code = require_string_param(params.as_ref(), "code")?;
        let label = require_string_param(params.as_ref(), "label")?;

        // Remove flow from map (single-use)
        let flow = {
            let mut flows = ctx.oauth_flows.lock().await;
            flows.remove(&flow_id)
        };

        let flow = flow.ok_or_else(|| RpcError::InvalidParams {
            message: "OAuth flow not found or expired".into(),
        })?;

        if flow.created_at.elapsed() > std::time::Duration::from_secs(600) {
            return Err(RpcError::InvalidParams {
                message: "OAuth flow expired".into(),
            });
        }

        // Exchange code for tokens (provider-specific)
        let tokens = match flow.provider.as_str() {
            "anthropic" => {
                let config = crate::llm::auth::anthropic::default_config();
                // Pass verifier as state (matches tron login CLI behavior)
                crate::llm::auth::anthropic::exchange_code_for_tokens(
                    &config,
                    &code,
                    &flow.verifier,
                    Some(&flow.verifier),
                )
                .await
            }
            "openai-codex" => {
                let config = crate::llm::auth::openai::default_config();
                crate::llm::auth::openai::exchange_code_for_tokens(&config, &code, &flow.verifier)
                    .await
            }
            "google" => {
                let gpa = crate::llm::auth::storage::get_google_provider_auth(&ctx.auth_path)
                    .map_err(map_auth_error)?;
                let client_id =
                    gpa.as_ref()
                        .and_then(|g| g.client_id.clone())
                        .ok_or_else(|| RpcError::Internal {
                            message:
                                "Google client_id is no longer configured — cannot complete OAuth"
                                    .into(),
                        })?;
                let client_secret = gpa.and_then(|g| g.client_secret);

                let base_cfg = crate::llm::auth::google::cloud_code_assist_config();
                let config = crate::llm::auth::google::GoogleOAuthConfig {
                    oauth: crate::llm::auth::types::OAuthConfig {
                        client_id,
                        client_secret,
                        ..base_cfg.oauth
                    },
                    ..base_cfg
                };

                crate::llm::auth::google::exchange_code_for_tokens(&config, &code, &flow.verifier)
                    .await
            }
            _ => {
                return Err(RpcError::InvalidParams {
                    message: format!("Unsupported OAuth provider: {}", flow.provider),
                });
            }
        }
        .map_err(map_auth_error)?;

        // Save tokens to auth.json (under the correct provider key)
        let auth_path = ctx.auth_path.clone();
        let provider_key = flow.provider.clone();
        let label_clone = label.clone();
        let tokens_clone = tokens.clone();
        let masked_state = ctx
            .run_blocking("auth.oauthComplete", move || {
                let _lock = acquire_auth_file_lock(&auth_path).map_err(|e| RpcError::Internal {
                    message: format!("Failed to acquire auth lock: {e}"),
                })?;

                crate::llm::auth::storage::save_account_oauth_tokens(
                    &auth_path,
                    &provider_key,
                    &label_clone,
                    &tokens_clone,
                )
                .map_err(map_auth_error)?;

                build_masked_state(&auth_path).map_err(map_auth_error)
            })
            .await?;

        broadcast_auth_updated(ctx, &masked_state).await;
        Ok(masked_state)
    }
}

pub(super) fn parse_oauth_tokens(oauth: &Value) -> Result<OAuthTokens, RpcError> {
    let access_token = oauth
        .get("accessToken")
        .and_then(|v| v.as_str())
        .ok_or_else(|| RpcError::InvalidParams {
            message: "oauth.accessToken is required".into(),
        })?
        .to_string();

    let refresh_token = oauth
        .get("refreshToken")
        .and_then(|v| v.as_str())
        .ok_or_else(|| RpcError::InvalidParams {
            message: "oauth.refreshToken is required".into(),
        })?
        .to_string();

    let expires_at = oauth
        .get("expiresAt")
        .and_then(serde_json::Value::as_i64)
        .ok_or_else(|| RpcError::InvalidParams {
            message: "oauth.expiresAt is required (milliseconds)".into(),
        })?;

    Ok(OAuthTokens {
        access_token,
        refresh_token,
        expires_at,
    })
}
