//! Real HTTP client using `reqwest`.

use async_trait::async_trait;

use crate::errors::ToolError;
use crate::traits::{HttpClient, HttpResponse};

/// HTTP client backed by `reqwest`.
pub struct ReqwestHttpClient {
    client: reqwest::Client,
}

impl ReqwestHttpClient {
    /// Create a new HTTP client with default settings.
    pub fn new() -> Self {
        Self {
            client: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(30))
                .user_agent("tron-agent/1.0")
                .build()
                .unwrap_or_default(),
        }
    }
}

impl Default for ReqwestHttpClient {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl HttpClient for ReqwestHttpClient {
    async fn get(&self, url: &str) -> Result<HttpResponse, ToolError> {
        let response = self
            .client
            .get(url)
            .send()
            .await
            .map_err(|e| ToolError::Internal {
                message: format!("HTTP request failed: {e}"),
            })?;

        let status = response.status().as_u16();
        let content_type = response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .map(String::from);
        let body = response
            .text()
            .await
            .map_err(|e| ToolError::Internal {
                message: format!("Failed to read response body: {e}"),
            })?;

        Ok(HttpResponse {
            status,
            body,
            content_type,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn creates_default_client() {
        let client = ReqwestHttpClient::new();
        // Smoke test — just verify construction doesn't panic
        drop(client);
    }

    #[test]
    fn default_impl() {
        let client = ReqwestHttpClient::default();
        drop(client);
    }
}
