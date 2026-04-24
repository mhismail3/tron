//! Real HTTP client using `reqwest`.

use std::collections::HashMap;

use async_trait::async_trait;

use crate::tools::errors::ToolError;
use crate::tools::traits::{HttpClient, HttpRequest, HttpResponse};

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
                .redirect(reqwest::redirect::Policy::limited(10))
                .user_agent("tron-agent/1.0")
                .build()
                .unwrap_or_default(),
        }
    }

    /// Create from an existing `reqwest::Client` (shared connection pool).
    pub fn from_client(client: reqwest::Client) -> Self {
        Self { client }
    }

    /// Extract response headers into a `HashMap`.
    fn extract_headers(headers: &reqwest::header::HeaderMap) -> HashMap<String, String> {
        headers
            .iter()
            .filter_map(|(k, v)| {
                v.to_str()
                    .ok()
                    .map(|val| (k.as_str().to_string(), val.to_string()))
            })
            .collect()
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
        self.get_with_headers(url, &[]).await
    }

    async fn get_with_headers(
        &self,
        url: &str,
        headers: &[(&str, &str)],
    ) -> Result<HttpResponse, ToolError> {
        let mut request = self.client.get(url);
        for &(key, value) in headers {
            request = request.header(key, value);
        }

        let response = request.send().await.map_err(|e| ToolError::Internal {
            message: format!("HTTP request failed: {e}"),
        })?;

        let status = response.status().as_u16();
        let content_type = response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .map(String::from);
        let resp_headers = Self::extract_headers(response.headers());
        let body = response.text().await.map_err(|e| ToolError::Internal {
            message: format!("Failed to read response body: {e}"),
        })?;

        Ok(HttpResponse {
            status,
            body,
            content_type,
            headers: resp_headers,
        })
    }

    async fn request(&self, req: &HttpRequest<'_>) -> Result<HttpResponse, ToolError> {
        let method = req.method.to_uppercase();
        let reqwest_method = match method.as_str() {
            "GET" => reqwest::Method::GET,
            "POST" => reqwest::Method::POST,
            "PUT" => reqwest::Method::PUT,
            "PATCH" => reqwest::Method::PATCH,
            "DELETE" => reqwest::Method::DELETE,
            "HEAD" => reqwest::Method::HEAD,
            other => {
                return Err(ToolError::Validation {
                    message: format!("Unsupported HTTP method: {other}"),
                });
            }
        };

        // Build a client with the right redirect policy if needed
        let client = if req.follow_redirects {
            self.client.clone()
        } else {
            reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(30))
                .redirect(reqwest::redirect::Policy::none())
                .user_agent("tron-agent/1.0")
                .build()
                .unwrap_or_default()
        };

        let mut request_builder = client.request(reqwest_method, req.url);

        for &(key, value) in &req.headers {
            request_builder = request_builder.header(key, value);
        }

        if let Some(body) = req.body {
            request_builder = request_builder.body(body.to_string());
        }

        let response = request_builder
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
        let resp_headers = Self::extract_headers(response.headers());

        let body = if method == "HEAD" {
            String::new()
        } else {
            response.text().await.map_err(|e| ToolError::Internal {
                message: format!("Failed to read response body: {e}"),
            })?
        };

        Ok(HttpResponse {
            status,
            body,
            content_type,
            headers: resp_headers,
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
