//! MCP server lifecycle management.
//!
//! Handles starting, stopping, health monitoring, and automatic crash recovery
//! for MCP servers. Discovers tools from connected servers and registers them
//! dynamically.
//!
//! ## Crash Recovery
//!
//! When a server connection is lost (detected on tool call failure), the manager
//! attempts automatic restart with exponential backoff. After
//! [`MAX_CONSECUTIVE_FAILURES`] consecutive failures, the server is marked
//! [`McpServerHealth::Failed`] and its tools are disabled until manual restart.

use std::collections::HashMap;
use std::sync::Arc;

use chrono::Utc;
use tracing::{debug, error, info, warn};

use crate::mcp::client::{McpClient, McpError, McpErrorKind};
use crate::mcp::types::{
    McpServerConfig, McpServerHealth, McpServerStatus, McpToolDef,
    BACKOFF_BASE_MS, BACKOFF_MAX_MS, MAX_CONSECUTIVE_FAILURES,
};

/// Per-server runtime state tracked by the manager.
struct ServerState {
    client: Arc<McpClient>,
    tool_count: usize,
    health: McpServerHealth,
    consecutive_failures: u32,
    last_error: Option<String>,
    connected_at: String,
}

/// Manages the lifecycle of MCP server connections.
pub struct McpServerManager {
    /// Active server states keyed by server name.
    servers: HashMap<String, ServerState>,
    /// Configuration for each server.
    configs: Vec<McpServerConfig>,
}

impl McpServerManager {
    /// Create a new manager with the given server configurations.
    pub fn new(configs: Vec<McpServerConfig>) -> Self {
        Self {
            servers: HashMap::new(),
            configs,
        }
    }

    /// Start all enabled MCP servers and discover their tools.
    ///
    /// Returns `(server_name, tool_defs)` pairs for indexing.
    /// Disabled servers are skipped. Servers that fail to start are tracked as Failed.
    pub async fn start_all(&mut self) -> Vec<(String, Vec<McpToolDef>)> {
        let mut discovered: Vec<(String, Vec<McpToolDef>)> = Vec::new();

        let configs: Vec<McpServerConfig> = self.configs.clone();
        for config in &configs {
            if !config.enabled {
                debug!(server = %config.name, "skipping disabled MCP server");
                continue;
            }
            match self.connect_server(config).await {
                Ok((client, tool_defs)) => {
                    let tool_count = tool_defs.len();
                    info!(
                        server = %config.name,
                        tool_count,
                        "MCP server connected"
                    );
                    let _ = self.servers.insert(config.name.clone(), ServerState {
                        client,
                        tool_count,
                        health: McpServerHealth::Healthy,
                        consecutive_failures: 0,
                        last_error: None,
                        connected_at: Utc::now().to_rfc3339(),
                    });
                    discovered.push((config.name.clone(), tool_defs));
                }
                Err(e) => {
                    warn!(server = %config.name, error = %e, "failed to connect MCP server");
                    let _ = self.servers.insert(config.name.clone(), ServerState {
                        client: Arc::new(McpClient::failed_placeholder(&config.name)),
                        tool_count: 0,
                        health: McpServerHealth::Failed,
                        consecutive_failures: 1,
                        last_error: Some(e.message.clone()),
                        connected_at: Utc::now().to_rfc3339(),
                    });
                }
            }
        }

        debug!(
            total_tools = discovered.iter().map(|(_, d)| d.len()).sum::<usize>(),
            servers = self.servers.iter().filter(|(_, s)| s.health == McpServerHealth::Healthy).count(),
            "MCP server manager initialized"
        );

        discovered
    }

    /// Connect to a single MCP server and discover its tools.
    async fn connect_server(
        &self,
        config: &McpServerConfig,
    ) -> Result<(Arc<McpClient>, Vec<McpToolDef>), McpError> {
        let client = if config.url.is_some() {
            McpClient::connect_http(config).await?
        } else if config.command.is_some() {
            McpClient::connect_stdio(config).await?
        } else {
            return Err(McpError {
                server: config.name.clone(),
                kind: McpErrorKind::Protocol("no command or url".into()),
                message: format!(
                    "MCP server '{}' needs either 'command' (stdio) or 'url' (HTTP)",
                    config.name
                ),
            });
        };

        let client = Arc::new(client);
        let tool_defs = client.list_tools().await?;

        Ok((client, tool_defs))
    }

    /// Record a successful tool call for a server (resets failure counters).
    pub fn record_success(&mut self, server_name: &str) {
        if let Some(state) = self.servers.get_mut(server_name) {
            if state.health == McpServerHealth::Degraded {
                info!(server = %server_name, "MCP server recovered to healthy");
            }
            state.health = McpServerHealth::Healthy;
            state.consecutive_failures = 0;
            state.last_error = None;
        }
    }

    /// Record a failed tool call. Returns the new health state.
    ///
    /// Increments the failure counter (saturating on u32 overflow) and
    /// transitions health:
    /// - 1..MAX → Degraded
    /// - >= MAX → Failed (tools should be disabled; auto-restart refuses)
    pub fn record_failure(&mut self, server_name: &str, error: &str) -> McpServerHealth {
        if let Some(state) = self.servers.get_mut(server_name) {
            // INVARIANT: consecutive_failures uses saturating_add so the
            // counter can never wrap on a server stuck in a restart loop.
            state.consecutive_failures = state.consecutive_failures.saturating_add(1);
            state.last_error = Some(error.to_string());

            state.health = if state.consecutive_failures >= MAX_CONSECUTIVE_FAILURES {
                error!(
                    server = %server_name,
                    failures = state.consecutive_failures,
                    "MCP server exceeded max failures — tools disabled"
                );
                McpServerHealth::Failed
            } else {
                warn!(
                    server = %server_name,
                    failures = state.consecutive_failures,
                    max = MAX_CONSECUTIVE_FAILURES,
                    "MCP server degraded"
                );
                McpServerHealth::Degraded
            };

            state.health.clone()
        } else {
            McpServerHealth::Failed
        }
    }

    /// Auto-restart attempt from the tool-call recovery path.
    ///
    /// Refuses with [`McpErrorKind::PermanentlyFailed`] if the server is
    /// already `Failed` — the caller must surface the error to the user and
    /// wait for manual intervention. Does NOT increment the failure counter
    /// on refusal; the counter advance happens only in the actual restart
    /// path when connect_server fails.
    pub async fn try_auto_restart(
        &mut self,
        name: &str,
    ) -> Result<Vec<McpToolDef>, McpError> {
        if let Some(state) = self.servers.get(name) {
            if state.health == McpServerHealth::Failed {
                return Err(McpError {
                    server: name.to_string(),
                    kind: McpErrorKind::PermanentlyFailed,
                    message: format!(
                        "MCP server '{name}' exceeded {MAX_CONSECUTIVE_FAILURES} consecutive failures; \
                         manual restart required via settings",
                    ),
                });
            }
        }
        self.do_restart(name).await
    }

    /// Manual restart initiated by the user (RPC / settings UI).
    ///
    /// Always proceeds regardless of the server's current health, so that
    /// a user can recover a `Failed` server after fixing the underlying
    /// config. On success, `do_restart` replaces `ServerState` wholesale
    /// and the counter resets to 0.
    pub async fn manual_restart(
        &mut self,
        name: &str,
    ) -> Result<Vec<McpToolDef>, McpError> {
        self.do_restart(name).await
    }

    /// Shared restart body. Performs exponential backoff, shuts down the old
    /// client, reconnects, and installs a fresh ServerState on success.
    async fn do_restart(&mut self, name: &str) -> Result<Vec<McpToolDef>, McpError> {
        let attempt = self.servers.get(name)
            .map_or(0, |s| s.consecutive_failures);

        // Exponential backoff: base * 2^(attempt-1), capped at max.
        // Every arithmetic op is saturating so a pathological `attempt`
        // (e.g. from a counter that reached its cap) can never overflow.
        if attempt > 0 {
            let factor = 2u64.saturating_pow(attempt.saturating_sub(1));
            let delay_ms = BACKOFF_BASE_MS
                .saturating_mul(factor)
                .min(BACKOFF_MAX_MS);
            debug!(server = %name, delay_ms, attempt, "backoff before restart");
            tokio::time::sleep(std::time::Duration::from_millis(delay_ms)).await;
        }

        // Shut down existing connection
        if let Some(state) = self.servers.get(name) {
            state.client.shutdown().await;
        }

        // Find config
        let config = self.configs.iter()
            .find(|c| c.name == name)
            .ok_or_else(|| McpError {
                server: name.to_string(),
                kind: McpErrorKind::Protocol("unknown server".into()),
                message: format!("No MCP server configured with name: {name}"),
            })?
            .clone();

        match self.connect_server(&config).await {
            Ok((client, tool_defs)) => {
                let tool_count = tool_defs.len();
                info!(server = %name, tool_count, "MCP server restarted successfully");
                let _ = self.servers.insert(name.to_string(), ServerState {
                    client,
                    tool_count,
                    health: McpServerHealth::Healthy,
                    consecutive_failures: 0,
                    last_error: None,
                    connected_at: Utc::now().to_rfc3339(),
                });
                Ok(tool_defs)
            }
            Err(e) => {
                if let Some(state) = self.servers.get_mut(name) {
                    // INVARIANT: saturating_add keeps the counter bounded.
                    state.consecutive_failures =
                        state.consecutive_failures.saturating_add(1);
                    state.last_error = Some(e.message.clone());
                    state.health = if state.consecutive_failures >= MAX_CONSECUTIVE_FAILURES {
                        McpServerHealth::Failed
                    } else {
                        McpServerHealth::Degraded
                    };
                }
                Err(e)
            }
        }
    }

    /// Shut down all MCP servers gracefully.
    pub async fn shutdown_all(&mut self) {
        for (name, state) in self.servers.drain() {
            debug!(server = %name, "shutting down MCP server");
            state.client.shutdown().await;
        }
    }

    /// Get status snapshots for all configured servers.
    pub fn status(&self) -> Vec<McpServerStatus> {
        self.configs.iter().map(|config| {
            if let Some(state) = self.servers.get(&config.name) {
                McpServerStatus {
                    name: config.name.clone(),
                    health: state.health.clone(),
                    tool_count: state.tool_count,
                    consecutive_failures: state.consecutive_failures,
                    last_error: state.last_error.clone(),
                    connected_at: Some(state.connected_at.clone()),
                }
            } else {
                McpServerStatus {
                    name: config.name.clone(),
                    health: McpServerHealth::Failed,
                    tool_count: 0,
                    consecutive_failures: 0,
                    last_error: Some("never started".into()),
                    connected_at: None,
                }
            }
        }).collect()
    }

    /// Get a list of connected (healthy or degraded) server names.
    pub fn connected_servers(&self) -> Vec<&str> {
        self.servers.iter()
            .filter(|(_, s)| s.health != McpServerHealth::Failed)
            .map(|(name, _)| name.as_str())
            .collect()
    }

    /// Check if a specific server is connected and operational.
    pub fn is_connected(&self, name: &str) -> bool {
        self.servers.get(name)
            .is_some_and(|s| s.health != McpServerHealth::Failed)
    }

    /// Get the health state of a specific server.
    pub fn health(&self, name: &str) -> Option<McpServerHealth> {
        self.servers.get(name).map(|s| s.health.clone())
    }

    /// Get the client for a specific server (if connected).
    pub fn client(&self, name: &str) -> Option<Arc<McpClient>> {
        self.servers.get(name)
            .filter(|s| s.health != McpServerHealth::Failed)
            .map(|s| s.client.clone())
    }

    /// Number of configured servers.
    pub fn config_count(&self) -> usize {
        self.configs.len()
    }

    /// Add a new server config. Does not start it — caller should use `restart_server`.
    pub fn add_config(&mut self, config: McpServerConfig) {
        self.configs.push(config);
    }

    /// Remove a server config and shut down its connection.
    pub async fn remove_config(&mut self, name: &str) {
        if let Some(state) = self.servers.remove(name) {
            state.client.shutdown().await;
        }
        self.configs.retain(|c| c.name != name);
    }

    /// Get a mutable reference to a server config by name.
    pub fn config_mut(&mut self, name: &str) -> Option<&mut McpServerConfig> {
        self.configs.iter_mut().find(|c| c.name == name)
    }

    /// Get a reference to all configs.
    pub fn configs(&self) -> &[McpServerConfig] {
        &self.configs
    }

    /// Shut down and remove a single server's runtime state (keep config).
    pub async fn disconnect_server(&mut self, name: &str) {
        if let Some(state) = self.servers.remove(name) {
            state.client.shutdown().await;
        }
        if let Some(state) = self.servers.get_mut(name) {
            state.tool_count = 0;
        }
    }
}


#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_manager_empty() {
        let manager = McpServerManager::new(Vec::new());
        assert!(manager.connected_servers().is_empty());
        assert_eq!(manager.config_count(), 0);
    }

    #[test]
    fn is_connected_false_when_empty() {
        let manager = McpServerManager::new(Vec::new());
        assert!(!manager.is_connected("sqlite"));
    }

    #[test]
    fn health_none_when_not_configured() {
        let manager = McpServerManager::new(Vec::new());
        assert!(manager.health("sqlite").is_none());
    }

    #[test]
    fn status_empty_when_no_configs() {
        let manager = McpServerManager::new(Vec::new());
        assert!(manager.status().is_empty());
    }

    #[test]
    fn record_success_resets_failures() {
        let mut manager = McpServerManager::new(Vec::new());
        // Manually insert a degraded server state
        let _ = manager.servers.insert("test".into(), ServerState {
            client: Arc::new(McpClient::failed_placeholder("test")),
            tool_count: 2,
            health: McpServerHealth::Degraded,
            consecutive_failures: 2,
            last_error: Some("timeout".into()),
            connected_at: "2026-03-25T10:00:00Z".into(),
        });

        manager.record_success("test");
        let state = manager.servers.get("test").unwrap();
        assert_eq!(state.health, McpServerHealth::Healthy);
        assert_eq!(state.consecutive_failures, 0);
        assert!(state.last_error.is_none());
    }

    #[test]
    fn record_failure_degrades_then_fails() {
        let mut manager = McpServerManager::new(Vec::new());
        let _ = manager.servers.insert("test".into(), ServerState {
            client: Arc::new(McpClient::failed_placeholder("test")),
            tool_count: 1,
            health: McpServerHealth::Healthy,
            consecutive_failures: 0,
            last_error: None,
            connected_at: "2026-03-25T10:00:00Z".into(),
        });

        // First failure → Degraded
        let h1 = manager.record_failure("test", "timeout");
        assert_eq!(h1, McpServerHealth::Degraded);
        assert_eq!(manager.servers.get("test").unwrap().consecutive_failures, 1);

        // Second failure → still Degraded
        let h2 = manager.record_failure("test", "timeout again");
        assert_eq!(h2, McpServerHealth::Degraded);

        // Third failure → Failed (MAX_CONSECUTIVE_FAILURES = 3)
        let h3 = manager.record_failure("test", "still timing out");
        assert_eq!(h3, McpServerHealth::Failed);
        assert!(!manager.is_connected("test"));
    }

    #[test]
    fn status_reports_all_configured_servers() {
        let configs = vec![
            McpServerConfig {
                name: "a".into(),
                command: Some("echo".into()),
                args: Vec::new(),
                env: HashMap::new(),
                url: None,
                tool_timeout_ms: 5_000,
                enabled: true,
            },
            McpServerConfig {
                name: "b".into(),
                command: None,
                args: Vec::new(),
                env: HashMap::new(),
                url: Some("http://localhost:5000".into()),
                tool_timeout_ms: 10_000,
                enabled: true,
            },
        ];

        let manager = McpServerManager::new(configs);
        let statuses = manager.status();
        assert_eq!(statuses.len(), 2);
        assert_eq!(statuses[0].name, "a");
        assert_eq!(statuses[1].name, "b");
        // Both should be Failed since they were never started
        assert_eq!(statuses[0].health, McpServerHealth::Failed);
    }

    #[tokio::test]
    async fn start_all_with_no_servers() {
        let mut manager = McpServerManager::new(Vec::new());
        let tools = manager.start_all().await;
        assert!(tools.is_empty());
    }

    #[tokio::test]
    async fn start_all_with_invalid_command_skips() {
        let configs = vec![McpServerConfig {
            name: "bad-server".into(),
            command: Some("nonexistent-mcp-binary-12345".into()),
            args: Vec::new(),
            env: HashMap::new(),
            url: None,
            tool_timeout_ms: 5_000,
            enabled: true,
        }];
        let mut manager = McpServerManager::new(configs);
        let tools = manager.start_all().await;
        assert!(tools.is_empty());
        assert!(!manager.is_connected("bad-server"));
        // Should be tracked as Failed
        assert_eq!(manager.health("bad-server"), Some(McpServerHealth::Failed));
    }

    #[tokio::test]
    async fn shutdown_all_no_panic_when_empty() {
        let mut manager = McpServerManager::new(Vec::new());
        manager.shutdown_all().await;
    }

    #[test]
    fn connected_servers_excludes_failed() {
        let mut manager = McpServerManager::new(Vec::new());
        let _ = manager.servers.insert("healthy".into(), ServerState {
            client: Arc::new(McpClient::failed_placeholder("healthy")),
            tool_count: 3,
            health: McpServerHealth::Healthy,
            consecutive_failures: 0,
            last_error: None,
            connected_at: "2026-03-25T10:00:00Z".into(),
        });
        let _ = manager.servers.insert("broken".into(), ServerState {
            client: Arc::new(McpClient::failed_placeholder("broken")),
            tool_count: 0,
            health: McpServerHealth::Failed,
            consecutive_failures: 3,
            last_error: Some("crashed".into()),
            connected_at: "2026-03-25T10:00:00Z".into(),
        });
        let _ = manager.servers.insert("degraded".into(), ServerState {
            client: Arc::new(McpClient::failed_placeholder("degraded")),
            tool_count: 1,
            health: McpServerHealth::Degraded,
            consecutive_failures: 1,
            last_error: Some("timeout".into()),
            connected_at: "2026-03-25T10:00:00Z".into(),
        });

        let connected = manager.connected_servers();
        assert_eq!(connected.len(), 2);
        assert!(connected.contains(&"healthy"));
        assert!(connected.contains(&"degraded"));
        assert!(!connected.contains(&"broken"));
    }

    #[test]
    fn client_returns_none_for_failed() {
        let mut manager = McpServerManager::new(Vec::new());
        let _ = manager.servers.insert("failed".into(), ServerState {
            client: Arc::new(McpClient::failed_placeholder("failed")),
            tool_count: 0,
            health: McpServerHealth::Failed,
            consecutive_failures: 3,
            last_error: None,
            connected_at: "2026-03-25T10:00:00Z".into(),
        });
        assert!(manager.client("failed").is_none());
        assert!(manager.client("nonexistent").is_none());
    }

    #[tokio::test]
    async fn restart_unknown_server_returns_error() {
        let mut manager = McpServerManager::new(Vec::new());
        let result = manager.manual_restart("nonexistent").await;
        assert!(result.is_err());
    }

    // ── Saturating counter + auto-refusal ────────────────────────────────

    #[test]
    fn record_failure_counter_saturates_at_u32_max() {
        let mut manager = McpServerManager::new(Vec::new());
        let _ = manager.servers.insert("s".into(), ServerState {
            client: Arc::new(McpClient::failed_placeholder("s")),
            tool_count: 0,
            health: McpServerHealth::Failed,
            consecutive_failures: u32::MAX,
            last_error: None,
            connected_at: "t".into(),
        });
        let _ = manager.record_failure("s", "more");
        assert_eq!(manager.servers.get("s").unwrap().consecutive_failures, u32::MAX);
    }

    #[tokio::test]
    async fn try_auto_restart_refuses_when_failed() {
        let mut manager = McpServerManager::new(vec![McpServerConfig {
            name: "s".into(),
            command: Some("nonexistent-mcp-binary".into()),
            args: Vec::new(),
            env: HashMap::new(),
            url: None,
            tool_timeout_ms: 5_000,
            enabled: true,
        }]);
        let _ = manager.servers.insert("s".into(), ServerState {
            client: Arc::new(McpClient::failed_placeholder("s")),
            tool_count: 0,
            health: McpServerHealth::Failed,
            consecutive_failures: MAX_CONSECUTIVE_FAILURES,
            last_error: Some("hit cap".into()),
            connected_at: "t".into(),
        });

        let err = manager.try_auto_restart("s").await.unwrap_err();
        assert!(matches!(err.kind, McpErrorKind::PermanentlyFailed));
        // Counter must not have been incremented by the refusal.
        assert_eq!(
            manager.servers.get("s").unwrap().consecutive_failures,
            MAX_CONSECUTIVE_FAILURES
        );
    }

    #[tokio::test]
    async fn try_auto_restart_proceeds_when_degraded() {
        // Configured but pointing at a nonexistent binary, so the restart will
        // fail — we just want to confirm the refusal gate does NOT fire for
        // Degraded health.
        let mut manager = McpServerManager::new(vec![McpServerConfig {
            name: "s".into(),
            command: Some("nonexistent-mcp-binary".into()),
            args: Vec::new(),
            env: HashMap::new(),
            url: None,
            tool_timeout_ms: 5_000,
            enabled: true,
        }]);
        let _ = manager.servers.insert("s".into(), ServerState {
            client: Arc::new(McpClient::failed_placeholder("s")),
            tool_count: 0,
            health: McpServerHealth::Degraded,
            consecutive_failures: 1,
            last_error: None,
            connected_at: "t".into(),
        });

        let err = manager.try_auto_restart("s").await.unwrap_err();
        // Degraded → attempted restart → transient/connection error, NOT refusal.
        assert!(!matches!(err.kind, McpErrorKind::PermanentlyFailed));
    }

    #[tokio::test]
    async fn manual_restart_always_attempts_even_when_failed() {
        // Manual restart should bypass the refusal gate and attempt a real
        // reconnection. We can't run a real MCP server here, so we just check
        // the error kind is from the connection attempt (Transient), not the
        // refusal path (PermanentlyFailed).
        let mut manager = McpServerManager::new(vec![McpServerConfig {
            name: "s".into(),
            command: Some("nonexistent-mcp-binary".into()),
            args: Vec::new(),
            env: HashMap::new(),
            url: None,
            tool_timeout_ms: 5_000,
            enabled: true,
        }]);
        let _ = manager.servers.insert("s".into(), ServerState {
            client: Arc::new(McpClient::failed_placeholder("s")),
            tool_count: 0,
            health: McpServerHealth::Failed,
            consecutive_failures: MAX_CONSECUTIVE_FAILURES,
            last_error: Some("hit cap".into()),
            connected_at: "t".into(),
        });

        let err = manager.manual_restart("s").await.unwrap_err();
        assert!(!matches!(err.kind, McpErrorKind::PermanentlyFailed));
    }

    #[tokio::test]
    async fn restart_counter_increments_saturating_on_failure() {
        // Configured; nonexistent binary makes connect fail.
        let mut manager = McpServerManager::new(vec![McpServerConfig {
            name: "s".into(),
            command: Some("nonexistent-mcp-binary".into()),
            args: Vec::new(),
            env: HashMap::new(),
            url: None,
            tool_timeout_ms: 5_000,
            enabled: true,
        }]);
        let _ = manager.servers.insert("s".into(), ServerState {
            client: Arc::new(McpClient::failed_placeholder("s")),
            tool_count: 0,
            health: McpServerHealth::Degraded,
            consecutive_failures: u32::MAX,
            last_error: None,
            connected_at: "t".into(),
        });

        let _ = manager.manual_restart("s").await;
        // Still saturated; must not have overflowed.
        assert_eq!(
            manager.servers.get("s").unwrap().consecutive_failures,
            u32::MAX
        );
    }
}
