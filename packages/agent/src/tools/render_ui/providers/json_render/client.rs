//! HTTP client for the json-render-server spec API.
//!
//! Endpoints:
//! - `POST /api/spec`          — push full spec
//! - `POST /api/spec/chunk`    — push partial chunk
//! - `POST /api/spec/complete` — finalize streaming render
//! - `GET  /api/health`        — health check

use reqwest::Client;
use serde_json::{Value, json};
use std::time::Duration;

use crate::tools::errors::ToolError;
use crate::tools::render_ui::types::RenderResult;

const HEALTH_TIMEOUT: Duration = Duration::from_secs(2);
const SPEC_TIMEOUT: Duration = Duration::from_secs(10);
const CHUNK_TIMEOUT: Duration = Duration::from_secs(5);

/// HTTP client for communicating with the json-render-server.
pub struct RenderClient {
    client: Client,
    base_url: String,
}

impl RenderClient {
    /// Create a new client targeting the given base URL.
    pub fn new(base_url: impl Into<String>) -> Self {
        Self {
            client: Client::new(),
            base_url: base_url.into(),
        }
    }

    /// Health check — returns `true` if the server is reachable.
    pub async fn health_check(&self) -> bool {
        let url = format!("{}/api/health", self.base_url);
        match self
            .client
            .get(&url)
            .timeout(HEALTH_TIMEOUT)
            .send()
            .await
        {
            Ok(resp) => resp.status().is_success(),
            Err(_) => false,
        }
    }

    /// Push a full spec to the server.
    pub async fn push_spec(
        &self,
        canvas_id: &str,
        spec: &Value,
        title: Option<&str>,
    ) -> Result<RenderResult, ToolError> {
        let url = format!("{}/api/spec", self.base_url);
        let mut body = json!({
            "canvasId": canvas_id,
            "spec": spec,
        });
        if let Some(t) = title {
            body["title"] = json!(t);
        }

        let resp = self
            .client
            .post(&url)
            .json(&body)
            .timeout(SPEC_TIMEOUT)
            .send()
            .await
            .map_err(|e| ToolError::Internal {
                message: format!("Failed to push spec to json-render-server: {e}"),
            })?;

        if !resp.status().is_success() {
            let status = resp.status();
            let error_body = resp.text().await.unwrap_or_default();
            return Err(ToolError::Internal {
                message: format!(
                    "json-render-server returned {status}: {error_body}"
                ),
            });
        }

        let result: Value = resp.json().await.map_err(|e| ToolError::Internal {
            message: format!("Failed to parse spec response: {e}"),
        })?;

        let element_count = spec
            .get("elements")
            .and_then(Value::as_object)
            .map_or(0, |m| m.len());

        Ok(RenderResult {
            canvas_id: result["canvasId"]
                .as_str()
                .unwrap_or(canvas_id)
                .to_string(),
            url: result["url"]
                .as_str()
                .unwrap_or(&format!("{}/canvas/{}", self.base_url, canvas_id))
                .to_string(),
            element_count,
        })
    }

    /// Push a partial chunk for streaming rendering.
    pub async fn push_chunk(
        &self,
        canvas_id: &str,
        chunk: &str,
    ) -> Result<(), ToolError> {
        let url = format!("{}/api/spec/chunk", self.base_url);
        let body = json!({
            "canvasId": canvas_id,
            "chunk": chunk,
        });

        let resp = self
            .client
            .post(&url)
            .json(&body)
            .timeout(CHUNK_TIMEOUT)
            .send()
            .await
            .map_err(|e| ToolError::Internal {
                message: format!("Failed to push chunk: {e}"),
            })?;

        if !resp.status().is_success() {
            let status = resp.status();
            let error_body = resp.text().await.unwrap_or_default();
            return Err(ToolError::Internal {
                message: format!("json-render-server chunk error {status}: {error_body}"),
            });
        }
        Ok(())
    }

    /// Finalize a streaming render.
    pub async fn complete_render(
        &self,
        canvas_id: &str,
    ) -> Result<RenderResult, ToolError> {
        let url = format!("{}/api/spec/complete", self.base_url);
        let body = json!({ "canvasId": canvas_id });

        let resp = self
            .client
            .post(&url)
            .json(&body)
            .timeout(SPEC_TIMEOUT)
            .send()
            .await
            .map_err(|e| ToolError::Internal {
                message: format!("Failed to complete render: {e}"),
            })?;

        if !resp.status().is_success() {
            let status = resp.status();
            let error_body = resp.text().await.unwrap_or_default();
            return Err(ToolError::Internal {
                message: format!("json-render-server complete error {status}: {error_body}"),
            });
        }

        let result: Value = resp.json().await.map_err(|e| ToolError::Internal {
            message: format!("Failed to parse complete response: {e}"),
        })?;

        Ok(RenderResult {
            canvas_id: result["canvasId"]
                .as_str()
                .unwrap_or(canvas_id)
                .to_string(),
            url: result["url"]
                .as_str()
                .unwrap_or(&format!("{}/canvas/{}", self.base_url, canvas_id))
                .to_string(),
            element_count: result["elementCount"].as_u64().unwrap_or(0) as usize,
        })
    }

    /// Get the URL for a canvas.
    pub fn canvas_url(&self, canvas_id: &str) -> String {
        format!("{}/canvas/{}", self.base_url, canvas_id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canvas_url_format() {
        let client = RenderClient::new("http://localhost:9250");
        assert_eq!(
            client.canvas_url("my-canvas"),
            "http://localhost:9250/canvas/my-canvas"
        );
    }

    #[tokio::test]
    async fn health_check_unreachable_returns_false() {
        // Connecting to a port that's almost certainly not listening
        let client = RenderClient::new("http://127.0.0.1:19999");
        assert!(!client.health_check().await);
    }

    #[tokio::test]
    async fn push_spec_unreachable_returns_error() {
        let client = RenderClient::new("http://127.0.0.1:19999");
        let result = client
            .push_spec("c1", &json!({"root": "main", "elements": {}}), None)
            .await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn push_chunk_unreachable_returns_error() {
        let client = RenderClient::new("http://127.0.0.1:19999");
        let result = client.push_chunk("c1", "{}").await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn complete_render_unreachable_returns_error() {
        let client = RenderClient::new("http://127.0.0.1:19999");
        let result = client.complete_render("c1").await;
        assert!(result.is_err());
    }
}
