//! `RenderUIProvider` trait — swappable render backend.
//!
//! Implementors manage the backend lifecycle and communication.
//! The `RenderUI` tool delegates all rendering to the provider.
//!
//! To add a new provider:
//! 1. Create a module under `providers/`
//! 2. Implement this trait
//! 3. Register discovery in `providers/mod.rs`

use async_trait::async_trait;
use serde_json::Value;

use crate::tools::errors::ToolError;
use super::types::{RenderResult, RenderBackendInfo, RenderBackendStatus};

/// Trait for swappable render UI backends.
#[async_trait]
pub trait RenderUIProvider: Send + Sync {
    /// Provider identifier (e.g., "json-render", "stub").
    fn name(&self) -> &str;

    /// Push a UI spec to the backend. Returns the URL where it's visible.
    async fn push_spec(
        &self,
        canvas_id: &str,
        spec: &Value,
        title: Option<&str>,
    ) -> Result<RenderResult, ToolError>;

    /// Stream a partial spec chunk (for progressive rendering).
    async fn push_chunk(
        &self,
        canvas_id: &str,
        chunk: &str,
    ) -> Result<(), ToolError>;

    /// Finalize a streaming render.
    async fn complete_render(
        &self,
        canvas_id: &str,
    ) -> Result<RenderResult, ToolError>;

    /// Get the URL for a canvas.
    fn canvas_url(&self, canvas_id: &str) -> Option<String>;

    /// Backend status.
    fn get_status(&self) -> RenderBackendStatus;

    /// Ensure the render backend is ready.
    async fn ensure_running(&self) -> Result<RenderBackendInfo, ToolError>;

    /// Shut down the render backend.
    async fn shutdown(&self);
}
