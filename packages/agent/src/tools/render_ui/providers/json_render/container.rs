//! Container lifecycle management for json-render-server.
//!
//! Manages the `tron-json-render` container: create, start, health check.
//! The `json-render-server` CLI handles Docker image details, port mapping,
//! and volume mounts — this module just invokes it and monitors health.

use std::path::PathBuf;
use std::time::Duration;

use tokio::time::{sleep, timeout};
use tracing::{debug, info, warn};

use crate::tools::errors::ToolError;
use crate::tools::render_ui::types::RenderBackendInfo;
use super::client::RenderClient;

const CONTAINER_NAME: &str = "tron-json-render";
const DEFAULT_PORT: u16 = 9250;
const HEALTH_TIMEOUT: Duration = Duration::from_secs(30);
const INITIAL_DELAY: Duration = Duration::from_millis(500);
const MAX_DELAY: Duration = Duration::from_secs(4);

/// Manages the json-render-server container lifecycle.
pub struct ContainerManager {
    binary_path: PathBuf,
    port: u16,
}

impl ContainerManager {
    /// Create a new container manager.
    pub fn new(binary_path: PathBuf) -> Self {
        Self {
            binary_path,
            port: DEFAULT_PORT,
        }
    }

    /// Base URL for the server.
    pub fn base_url(&self) -> String {
        format!("http://localhost:{}", self.port)
    }

    /// Ensure the container is running. Returns server info on success.
    pub async fn ensure_running(&self) -> Result<RenderBackendInfo, ToolError> {
        // 1. Check if container already exists and is running
        let status = self.query_container_status().await;

        match status.as_deref() {
            Some("running") => {
                debug!("tron-json-render container already running");
                // Verify health
                if self.wait_for_health().await? {
                    return Ok(self.server_info());
                }
                // Container running but not healthy — restart
                warn!("tron-json-render running but not healthy, restarting");
                self.stop_container().await;
                self.create_and_start().await?;
            }
            Some(_) => {
                // Exists but stopped — start it
                info!("starting stopped tron-json-render container");
                self.start_container().await?;
            }
            None => {
                // Doesn't exist — create and start
                info!("creating tron-json-render container");
                self.create_and_start().await?;
            }
        }

        // Wait for health
        if self.wait_for_health().await? {
            Ok(self.server_info())
        } else {
            Err(ToolError::Internal {
                message: "json-render-server failed to start within 30s".into(),
            })
        }
    }

    /// Query the container status via `container list`.
    async fn query_container_status(&self) -> Option<String> {
        let result = timeout(
            Duration::from_secs(3),
            tokio::process::Command::new("container")
                .args(["list", "--all", "--format", "json"])
                .output(),
        )
        .await;

        let output = match result {
            Ok(Ok(output)) if output.status.success() => output.stdout,
            _ => return None,
        };

        let entries: Vec<serde_json::Value> = serde_json::from_slice(&output).ok()?;
        entries.iter().find_map(|entry| {
            let name = entry.get("name")?.as_str()?;
            if name == CONTAINER_NAME {
                Some(entry.get("status")?.as_str()?.to_string())
            } else {
                None
            }
        })
    }

    /// Create and start the container via `json-render-server create-container`.
    async fn create_and_start(&self) -> Result<(), ToolError> {
        let output = timeout(
            Duration::from_secs(30),
            tokio::process::Command::new(&self.binary_path)
                .args([
                    "create-container",
                    "--name",
                    CONTAINER_NAME,
                    "--port",
                    &self.port.to_string(),
                ])
                .output(),
        )
        .await
        .map_err(|_| ToolError::Internal {
            message: "json-render-server create-container timed out".into(),
        })?
        .map_err(|e| ToolError::Internal {
            message: format!("Failed to run json-render-server: {e}"),
        })?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(ToolError::Internal {
                message: format!("json-render-server create-container failed: {stderr}"),
            });
        }

        Ok(())
    }

    /// Start an existing stopped container.
    async fn start_container(&self) -> Result<(), ToolError> {
        let output = timeout(
            Duration::from_secs(10),
            tokio::process::Command::new("container")
                .args(["start", CONTAINER_NAME])
                .output(),
        )
        .await
        .map_err(|_| ToolError::Internal {
            message: "container start timed out".into(),
        })?
        .map_err(|e| ToolError::Internal {
            message: format!("Failed to start container: {e}"),
        })?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(ToolError::Internal {
                message: format!("container start failed: {stderr}"),
            });
        }
        Ok(())
    }

    /// Stop the container (best-effort).
    async fn stop_container(&self) {
        let _ = timeout(
            Duration::from_secs(10),
            tokio::process::Command::new("container")
                .args(["stop", CONTAINER_NAME])
                .output(),
        )
        .await;
    }

    /// Remove the container (best-effort).
    pub async fn remove_container(&self) {
        self.stop_container().await;
        let _ = timeout(
            Duration::from_secs(10),
            tokio::process::Command::new("container")
                .args(["rm", CONTAINER_NAME])
                .output(),
        )
        .await;
    }

    /// Wait for the server health check to pass, with exponential backoff.
    async fn wait_for_health(&self) -> Result<bool, ToolError> {
        let client = RenderClient::new(self.base_url());
        let mut delay = INITIAL_DELAY;

        let deadline = tokio::time::Instant::now() + HEALTH_TIMEOUT;
        while tokio::time::Instant::now() < deadline {
            if client.health_check().await {
                info!("json-render-server healthy at {}", self.base_url());
                return Ok(true);
            }
            sleep(delay).await;
            delay = (delay * 2).min(MAX_DELAY);
        }
        Ok(false)
    }

    fn server_info(&self) -> RenderBackendInfo {
        RenderBackendInfo {
            base_url: self.base_url(),
            backend_id: CONTAINER_NAME.into(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base_url_uses_default_port() {
        let mgr = ContainerManager::new(PathBuf::from("/usr/local/bin/json-render-server"));
        assert_eq!(mgr.base_url(), "http://localhost:9250");
    }

    #[test]
    fn server_info_has_backend_id() {
        let mgr = ContainerManager::new(PathBuf::from("/usr/local/bin/json-render-server"));
        let info = mgr.server_info();
        assert_eq!(info.backend_id, "tron-json-render");
        assert_eq!(info.base_url, "http://localhost:9250");
    }

    #[tokio::test]
    async fn query_status_returns_none_without_container_cli() {
        // container CLI almost certainly not available in test env
        let mgr = ContainerManager::new(PathBuf::from("/nonexistent/json-render-server"));
        let status = mgr.query_container_status().await;
        // Should return None (graceful fallback), not panic
        assert!(status.is_none());
    }
}
