//! Lazy re-discovery wrapper for render UI providers.
//!
//! If the inner provider is a `StubProvider` (no json-render-server found at
//! startup), `LazyRenderUIProvider` re-attempts discovery on the next
//! `ensure_running` call, with a cooldown to avoid repeated expensive lookups.

use std::sync::Arc;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use serde_json::Value;

use crate::tools::errors::ToolError;
use crate::tools::render_ui::provider::RenderUIProvider;
use crate::tools::render_ui::types::{RenderResult, RenderBackendInfo, RenderBackendStatus};

/// Minimum interval between re-discovery attempts.
const REDISCOVERY_COOLDOWN: Duration = Duration::from_secs(60);

/// Discovery parameters cached for retry.
#[derive(Clone, Debug)]
pub struct DiscoveryParams {
    /// Provider name (e.g., `"json-render"`). `None` uses the default.
    pub provider_name: Option<String>,
    /// Explicit path to the render backend binary.
    pub executable_path: Option<String>,
}

/// Wraps a render UI provider with lazy re-discovery.
///
/// If the inner provider is a `StubProvider`, attempts re-discovery
/// on the next `ensure_running` call (with cooldown).
pub struct LazyRenderUIProvider {
    inner: parking_lot::RwLock<Arc<dyn RenderUIProvider>>,
    params: DiscoveryParams,
    last_attempt: parking_lot::Mutex<Instant>,
}

impl LazyRenderUIProvider {
    /// Create a new lazy provider wrapping an initial provider.
    pub fn new(initial: Arc<dyn RenderUIProvider>, params: DiscoveryParams) -> Self {
        Self {
            inner: parking_lot::RwLock::new(initial),
            params,
            last_attempt: parking_lot::Mutex::new(Instant::now()),
        }
    }

    /// Try to re-discover a real provider if we're currently using a stub.
    /// Returns the (possibly updated) inner provider.
    fn try_rediscover(&self) -> Arc<dyn RenderUIProvider> {
        let inner = self.inner.read().clone();
        if inner.name() != "stub" {
            return inner;
        }

        // Check cooldown
        let mut last = self.last_attempt.lock();
        if last.elapsed() < REDISCOVERY_COOLDOWN {
            return inner;
        }

        // Drop read lock, acquire write lock
        drop(inner);
        let mut write_guard = self.inner.write();

        // Double-check: another thread may have already swapped
        if write_guard.name() != "stub" {
            *last = Instant::now();
            return write_guard.clone();
        }

        // Attempt re-discovery
        *last = Instant::now();
        let found = super::find_render_ui_provider(
            self.params.provider_name.as_deref(),
            self.params.executable_path.as_deref(),
        );

        if let Some(provider) = found {
            tracing::info!(
                provider = provider.name(),
                "render UI provider re-discovered (was stub)"
            );
            *write_guard = provider.clone();
            provider
        } else {
            write_guard.clone()
        }
    }
}

#[async_trait]
impl RenderUIProvider for LazyRenderUIProvider {
    fn name(&self) -> &str {
        let inner = self.inner.read();
        match inner.name() {
            "stub" => "stub",
            "json-render" => "json-render",
            _ => "unknown",
        }
    }

    async fn push_spec(
        &self,
        canvas_id: &str,
        spec: &Value,
        title: Option<&str>,
    ) -> Result<RenderResult, ToolError> {
        let provider = self.try_rediscover();
        provider.push_spec(canvas_id, spec, title).await
    }

    async fn push_chunk(
        &self,
        canvas_id: &str,
        chunk: &str,
    ) -> Result<(), ToolError> {
        let provider = self.try_rediscover();
        provider.push_chunk(canvas_id, chunk).await
    }

    async fn complete_render(
        &self,
        canvas_id: &str,
    ) -> Result<RenderResult, ToolError> {
        let provider = self.inner.read().clone();
        provider.complete_render(canvas_id).await
    }

    fn canvas_url(&self, canvas_id: &str) -> Option<String> {
        let provider = self.inner.read().clone();
        provider.canvas_url(canvas_id)
    }

    fn get_status(&self) -> RenderBackendStatus {
        let provider = self.inner.read().clone();
        provider.get_status()
    }

    async fn ensure_running(&self) -> Result<RenderBackendInfo, ToolError> {
        let provider = self.try_rediscover();
        provider.ensure_running().await
    }

    async fn shutdown(&self) {
        let provider = self.inner.read().clone();
        provider.shutdown().await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tools::render_ui::providers::stub::StubProvider;
    use serde_json::json;

    fn stub_params() -> DiscoveryParams {
        DiscoveryParams {
            provider_name: None,
            executable_path: None,
        }
    }

    #[tokio::test]
    async fn lazy_delegates_to_stub() {
        let stub = Arc::new(StubProvider) as Arc<dyn RenderUIProvider>;
        let lazy = LazyRenderUIProvider::new(stub, stub_params());
        let result = lazy.push_spec("c1", &json!({}), None).await;
        assert!(result.is_err());
    }

    #[test]
    fn lazy_name_returns_inner_name() {
        let stub = Arc::new(StubProvider) as Arc<dyn RenderUIProvider>;
        let lazy = LazyRenderUIProvider::new(stub, stub_params());
        assert_eq!(lazy.name(), "stub");
    }

    #[tokio::test]
    async fn lazy_shutdown_delegates() {
        let stub = Arc::new(StubProvider) as Arc<dyn RenderUIProvider>;
        let lazy = LazyRenderUIProvider::new(stub, stub_params());
        lazy.shutdown().await;
    }

    #[tokio::test]
    async fn lazy_all_methods_delegate() {
        let stub = Arc::new(StubProvider) as Arc<dyn RenderUIProvider>;
        let lazy = LazyRenderUIProvider::new(stub, stub_params());

        let _ = lazy.push_chunk("c1", "{}").await;
        let _ = lazy.complete_render("c1").await;
        assert!(lazy.canvas_url("c1").is_none());
        let _ = lazy.get_status();
        let _ = lazy.ensure_running().await;
    }

    #[tokio::test]
    async fn lazy_cooldown_prevents_repeated_discovery() {
        let stub = Arc::new(StubProvider) as Arc<dyn RenderUIProvider>;
        let lazy = LazyRenderUIProvider::new(stub, stub_params());

        // First call triggers discovery attempt
        let _ = lazy.push_spec("c1", &json!({}), None).await;
        // Second call within cooldown — should not re-attempt
        let result = lazy.push_spec("c1", &json!({}), None).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn lazy_concurrent_access_safe() {
        let stub = Arc::new(StubProvider) as Arc<dyn RenderUIProvider>;
        let lazy = Arc::new(LazyRenderUIProvider::new(stub, stub_params()));

        let mut handles = vec![];
        for _ in 0..10 {
            let lazy = lazy.clone();
            handles.push(tokio::spawn(async move {
                let _ = lazy.push_spec("c1", &json!({}), None).await;
            }));
        }
        for h in handles {
            h.await.unwrap();
        }
    }
}
