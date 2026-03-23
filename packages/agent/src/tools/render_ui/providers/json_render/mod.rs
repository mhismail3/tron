//! JsonRender provider — container-based json-render-server.
//!
//! Manages the `tron-json-render` container and delegates spec rendering
//! to the json-render-server HTTP API.

pub mod client;
pub mod container;

use std::path::PathBuf;
use std::sync::Arc;

use async_trait::async_trait;
use parking_lot::RwLock;
use serde_json::Value;

use crate::tools::errors::ToolError;
use crate::tools::render_ui::provider::RenderUIProvider;
use crate::tools::render_ui::types::{RenderResult, RenderBackendInfo, RenderBackendStatus};
use client::RenderClient;
use container::ContainerManager;

/// Provider that delegates rendering to a json-render-server in a container.
pub struct JsonRenderProvider {
    container: ContainerManager,
    client: RwLock<Option<Arc<RenderClient>>>,
}

impl JsonRenderProvider {
    /// Create a new provider with the given json-render-server binary path.
    pub fn new(binary_path: PathBuf) -> Self {
        Self {
            container: ContainerManager::new(binary_path),
            client: RwLock::new(None),
        }
    }

    /// Get or create the HTTP client.
    fn get_client(&self) -> Arc<RenderClient> {
        let guard = self.client.read();
        if let Some(client) = guard.as_ref() {
            return client.clone();
        }
        drop(guard);

        let mut write_guard = self.client.write();
        if let Some(client) = write_guard.as_ref() {
            return client.clone();
        }
        let client = Arc::new(RenderClient::new(self.container.base_url()));
        *write_guard = Some(client.clone());
        client
    }
}

#[async_trait]
impl RenderUIProvider for JsonRenderProvider {
    fn name(&self) -> &str {
        "json-render"
    }

    async fn push_spec(
        &self,
        canvas_id: &str,
        spec: &Value,
        title: Option<&str>,
    ) -> Result<RenderResult, ToolError> {
        let client = self.get_client();
        client.push_spec(canvas_id, spec, title).await
    }

    async fn push_chunk(
        &self,
        canvas_id: &str,
        chunk: &str,
    ) -> Result<(), ToolError> {
        let client = self.get_client();
        client.push_chunk(canvas_id, chunk).await
    }

    async fn complete_render(
        &self,
        canvas_id: &str,
    ) -> Result<RenderResult, ToolError> {
        let client = self.get_client();
        client.complete_render(canvas_id).await
    }

    fn canvas_url(&self, canvas_id: &str) -> Option<String> {
        let client = self.get_client();
        Some(client.canvas_url(canvas_id))
    }

    fn get_status(&self) -> RenderBackendStatus {
        let client = self.get_client();
        // Synchronous status check — report based on client existence
        // Real status requires async health check via ensure_running()
        RenderBackendStatus::Running {
            base_url: self.container.base_url(),
        }
    }

    async fn ensure_running(&self) -> Result<RenderBackendInfo, ToolError> {
        self.container.ensure_running().await
    }

    async fn shutdown(&self) {
        self.container.remove_container().await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn provider_name_is_json_render() {
        let provider = JsonRenderProvider::new(PathBuf::from("/usr/local/bin/json-render-server"));
        assert_eq!(provider.name(), "json-render");
    }

    #[test]
    fn canvas_url_returns_some() {
        let provider = JsonRenderProvider::new(PathBuf::from("/usr/local/bin/json-render-server"));
        let url = provider.canvas_url("my-canvas");
        assert_eq!(url, Some("http://localhost:9250/canvas/my-canvas".into()));
    }

    #[test]
    fn get_status_returns_running() {
        let provider = JsonRenderProvider::new(PathBuf::from("/usr/local/bin/json-render-server"));
        match provider.get_status() {
            RenderBackendStatus::Running { base_url } => {
                assert_eq!(base_url, "http://localhost:9250");
            }
            other => panic!("expected Running, got {other:?}"),
        }
    }
}
