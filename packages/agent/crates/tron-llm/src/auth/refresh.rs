//! Shared OAuth token refresh logic.
//!
//! Eliminates duplication across Anthropic, Google, and `OpenAI` auth modules.

use super::errors::AuthError;
use super::types::{OAuthTokens, now_ms};

/// Check if tokens need refreshing, and refresh if expired.
///
/// Returns `(tokens, was_refreshed)`. The `refresh_fn` is only called if the
/// token is expired (accounting for `buffer_seconds`).
pub(crate) async fn maybe_refresh<F, Fut>(
    tokens: &OAuthTokens,
    buffer_seconds: i64,
    provider_name: &str,
    refresh_fn: F,
) -> Result<(OAuthTokens, bool), AuthError>
where
    F: FnOnce(&str) -> Fut,
    Fut: std::future::Future<Output = Result<OAuthTokens, AuthError>>,
{
    let buffer_ms = buffer_seconds * 1000;
    if now_ms() + buffer_ms < tokens.expires_at {
        return Ok((tokens.clone(), false));
    }

    tracing::info!(provider = provider_name, "OAuth token expired, refreshing...");
    match refresh_fn(&tokens.refresh_token).await {
        Ok(new_tokens) => {
            metrics::counter!("auth_refresh_total", "provider" => provider_name.to_owned(), "status" => "success").increment(1);
            Ok((new_tokens, true))
        }
        Err(e) => {
            metrics::counter!("auth_refresh_total", "provider" => provider_name.to_owned(), "status" => "failure").increment(1);
            Err(e)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_tokens(expires_at: i64) -> OAuthTokens {
        OAuthTokens {
            access_token: "old-tok".to_string(),
            refresh_token: "ref-tok".to_string(),
            expires_at,
        }
    }

    #[tokio::test]
    async fn fresh_token_no_refresh() {
        let tokens = make_tokens(now_ms() + 3_600_000); // 1 hour from now
        let (result, refreshed) = maybe_refresh(&tokens, 300, "test", |_| {
            async { panic!("refresh_fn should not be called for fresh tokens") }
        })
        .await
        .unwrap();

        assert!(!refreshed);
        assert_eq!(result.access_token, "old-tok");
    }

    #[tokio::test]
    async fn expired_token_triggers_refresh() {
        let tokens = make_tokens(now_ms() - 1000); // already expired
        let (result, refreshed) = maybe_refresh(&tokens, 300, "test", |refresh_tok| {
            let refresh_tok = refresh_tok.to_owned();
            async move {
                assert_eq!(refresh_tok, "ref-tok");
                Ok(OAuthTokens {
                    access_token: "new-tok".to_string(),
                    refresh_token: "new-ref".to_string(),
                    expires_at: now_ms() + 3_600_000,
                })
            }
        })
        .await
        .unwrap();

        assert!(refreshed);
        assert_eq!(result.access_token, "new-tok");
    }

    #[tokio::test]
    async fn refresh_failure_propagates_error() {
        let tokens = make_tokens(now_ms() - 1000);
        let result = maybe_refresh(&tokens, 300, "test", |_| {
            async {
                Err(AuthError::OAuth {
                    status: 401,
                    message: "invalid refresh token".to_string(),
                })
            }
        })
        .await;

        assert!(result.is_err());
    }

    #[tokio::test]
    async fn buffer_seconds_applied() {
        // Token expires in 30s, but buffer is 60s → should trigger refresh
        let tokens = make_tokens(now_ms() + 30_000);
        let (_, refreshed) = maybe_refresh(&tokens, 60, "test", |_| {
            async {
                Ok(OAuthTokens {
                    access_token: "new".to_string(),
                    refresh_token: "ref".to_string(),
                    expires_at: now_ms() + 3_600_000,
                })
            }
        })
        .await
        .unwrap();

        assert!(refreshed, "should refresh when within buffer window");
    }
}
