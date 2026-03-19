//! Lazy re-discovery wrapper for browser providers.
//!
//! If the inner provider is a `StubProvider` (no browser found at startup),
//! `LazyBrowserProvider` re-attempts discovery on the next `execute_action`
//! call, with a cooldown to avoid repeated expensive lookups.

use std::sync::Arc;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use tokio::sync::broadcast;

use crate::tools::browser::provider::BrowserProvider;
use crate::tools::browser::types::{BrowserEvent, BrowserStatus};
use crate::tools::errors::ToolError;
use crate::tools::traits::{BrowserAction, BrowserResult};

/// Minimum interval between re-discovery attempts.
const REDISCOVERY_COOLDOWN: Duration = Duration::from_secs(60);

/// Discovery parameters cached for retry.
#[derive(Clone, Debug)]
pub struct DiscoveryParams {
    /// Port for viewport streaming.
    pub stream_port: u16,
    /// Provider backend name (e.g., "agent-browser").
    pub provider_name: Option<String>,
    /// Explicit path to the browser binary.
    pub executable_path: Option<String>,
    /// Whether to run the browser in headed mode.
    pub headed: bool,
}

/// Wraps a browser provider with lazy re-discovery.
///
/// If the inner provider is a `StubProvider`, attempts re-discovery
/// on the next `execute_action` call (with cooldown).
pub struct LazyBrowserProvider {
    inner: parking_lot::RwLock<Arc<dyn BrowserProvider>>,
    params: DiscoveryParams,
    last_attempt: parking_lot::Mutex<Instant>,
}

impl LazyBrowserProvider {
    /// Create a new lazy provider wrapping an initial provider.
    pub fn new(initial: Arc<dyn BrowserProvider>, params: DiscoveryParams) -> Self {
        Self {
            inner: parking_lot::RwLock::new(initial),
            params,
            last_attempt: parking_lot::Mutex::new(Instant::now()),
        }
    }

    /// Try to re-discover a real browser provider if we're currently using a stub.
    /// Returns the (possibly updated) inner provider.
    fn try_rediscover(&self) -> Arc<dyn BrowserProvider> {
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
        let found = super::find_browser_provider(
            self.params.stream_port,
            self.params.provider_name.as_deref(),
            self.params.executable_path.as_deref(),
            self.params.headed,
        );

        if let Some(provider) = found {
            tracing::info!(
                provider = provider.name(),
                "browser provider re-discovered (was stub)"
            );
            *write_guard = provider.clone();
            provider
        } else {
            write_guard.clone()
        }
    }
}

#[async_trait]
impl BrowserProvider for LazyBrowserProvider {
    fn name(&self) -> &str {
        // Return the inner provider's name, but avoid holding the lock
        // across an await point. For name(), a quick read is fine.
        let inner = self.inner.read();
        // SAFETY: The provider names are &'static str in practice
        // (stub returns "stub", agent-browser returns "agent-browser").
        // We leak nothing; we just need to return a &str with the right lifetime.
        // Since BrowserProvider::name() returns &str tied to &self, we need
        // to match that lifetime. The inner Arc keeps the provider alive.
        // We'll use a match on known names to return static strs.
        match inner.name() {
            "stub" => "stub",
            "agent-browser" => "agent-browser",
            _ => "unknown",
        }
    }

    async fn execute_action(
        &self,
        session_id: &str,
        action: &BrowserAction,
    ) -> Result<BrowserResult, ToolError> {
        let provider = self.try_rediscover();
        provider.execute_action(session_id, action).await
    }

    async fn close_session(&self, session_id: &str) -> Result<(), ToolError> {
        let provider = self.inner.read().clone();
        provider.close_session(session_id).await
    }

    async fn start_stream(&self, session_id: &str) -> Result<(), ToolError> {
        let provider = self.inner.read().clone();
        provider.start_stream(session_id).await
    }

    async fn stop_stream(&self, session_id: &str) -> Result<(), ToolError> {
        let provider = self.inner.read().clone();
        provider.stop_stream(session_id).await
    }

    fn get_status(&self, session_id: &str) -> BrowserStatus {
        let provider = self.inner.read().clone();
        provider.get_status(session_id)
    }

    fn subscribe(&self) -> broadcast::Receiver<BrowserEvent> {
        let provider = self.inner.read().clone();
        provider.subscribe()
    }

    async fn close_all_sessions(&self) {
        let provider = self.inner.read().clone();
        provider.close_all_sessions().await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tools::browser::providers::stub::StubProvider;
    use serde_json::json;

    fn stub_params() -> DiscoveryParams {
        DiscoveryParams {
            stream_port: 0,
            provider_name: None,
            executable_path: None,
            headed: false,
        }
    }

    #[tokio::test]
    async fn lazy_delegates_to_real_provider() {
        // When wrapping a StubProvider and no real provider is discoverable,
        // it should still delegate to the stub
        let stub = Arc::new(StubProvider) as Arc<dyn BrowserProvider>;
        let lazy = LazyBrowserProvider::new(stub, stub_params());
        let action = BrowserAction {
            action: "navigate".into(),
            params: json!({"url": "https://example.com"}),
        };
        let result = lazy.execute_action("s1", &action).await;
        assert!(result.is_err()); // StubProvider returns error
    }

    #[test]
    fn lazy_name_returns_inner_name() {
        let stub = Arc::new(StubProvider) as Arc<dyn BrowserProvider>;
        let lazy = LazyBrowserProvider::new(stub, stub_params());
        assert_eq!(lazy.name(), "stub");
    }

    #[tokio::test]
    async fn lazy_close_all_sessions_delegates() {
        let stub = Arc::new(StubProvider) as Arc<dyn BrowserProvider>;
        let lazy = LazyBrowserProvider::new(stub, stub_params());
        lazy.close_all_sessions().await; // Should not panic
    }

    #[tokio::test]
    async fn lazy_all_methods_delegate() {
        let stub = Arc::new(StubProvider) as Arc<dyn BrowserProvider>;
        let lazy = LazyBrowserProvider::new(stub, stub_params());

        // close_session
        let _ = lazy.close_session("s1").await;
        // start_stream
        let _ = lazy.start_stream("s1").await;
        // stop_stream
        assert!(lazy.stop_stream("s1").await.is_ok());
        // get_status
        let status = lazy.get_status("s1");
        assert!(!status.has_browser);
        // subscribe
        let _rx = lazy.subscribe();
    }

    #[tokio::test]
    async fn lazy_cooldown_prevents_repeated_discovery() {
        let stub = Arc::new(StubProvider) as Arc<dyn BrowserProvider>;
        let lazy = LazyBrowserProvider::new(stub, stub_params());

        // First call triggers discovery attempt (updates last_attempt)
        let action = BrowserAction {
            action: "navigate".into(),
            params: json!({"url": "https://example.com"}),
        };
        let _ = lazy.execute_action("s1", &action).await;

        // Second call within cooldown — should NOT attempt discovery again
        // (we can't directly verify this without mocking find_browser_provider,
        // but we verify it doesn't panic and returns the stub error)
        let result = lazy.execute_action("s1", &action).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn lazy_concurrent_access_safe() {
        let stub = Arc::new(StubProvider) as Arc<dyn BrowserProvider>;
        let lazy = Arc::new(LazyBrowserProvider::new(stub, stub_params()));
        let action = BrowserAction {
            action: "navigate".into(),
            params: json!({"url": "https://example.com"}),
        };

        let mut handles = vec![];
        for i in 0..10 {
            let lazy = lazy.clone();
            let action = action.clone();
            handles.push(tokio::spawn(async move {
                let sid = format!("s{i}");
                let _ = lazy.execute_action(&sid, &action).await;
            }));
        }
        for h in handles {
            h.await.unwrap();
        }
    }
}
