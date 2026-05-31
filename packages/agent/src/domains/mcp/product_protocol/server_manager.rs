//! MCP server lifecycle management.
//!
//! Handles starting, stopping, health monitoring, and automatic crash recovery
//! for MCP servers. Discovers capabilities from connected servers and registers them
//! dynamically.
//!
//! ## Crash Recovery
//!
//! When a server connection is lost (detected on capability invocation failure), the manager
//! attempts automatic restart with exponential backoff. After
//! [`MAX_CONSECUTIVE_FAILURES`] consecutive failures, the server is marked
//! [`McpServerHealth::Failed`] and its capabilities are disabled until manual restart.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use chrono::Utc;
use tracing::{debug, error, info, warn};

use crate::domains::mcp::client::{McpClient, McpError, McpErrorKind};
use crate::domains::mcp::schemas::{SchemaDiff, diff_schemas};
use crate::domains::mcp::types::{
    BACKOFF_BASE_MS, BACKOFF_MAX_MS, MAX_CONSECUTIVE_FAILURES, McpServerConfig, McpServerHealth,
    McpServerStatus, McpToolDef,
};

/// Per-server runtime state tracked by the manager.
struct ServerState {
    client: Arc<McpClient>,
    tool_defs: Vec<McpToolDef>,
    health: McpServerHealth,
    consecutive_failures: u32,
    last_error: Option<String>,
    connected_at: String,
    /// Monotonic clock instant of the last successful `tools/list` fetch.
    /// INVARIANT: read by `refresh_schemas_if_stale` under `&mut self`, so
    /// concurrent refreshes for the same server serialize at the caller.
    tools_refreshed_at: Instant,
}

impl ServerState {
    fn capability_count(&self) -> usize {
        self.tool_defs.len()
    }
}

/// Result of a TTL-driven schema refresh. Returned by
/// [`McpServerManager::refresh_schemas_if_stale`] when a refresh actually ran.
#[derive(Debug, Clone)]
pub struct SchemaRefreshResult {
    /// Diff against the previously-cached tool set (empty when unchanged).
    pub diff: SchemaDiff,
    /// Fresh tool list as returned by the MCP server.
    pub capabilities: Vec<McpToolDef>,
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

    /// Start all enabled MCP servers and discover their capabilities.
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
                    let capability_count = tool_defs.len();
                    info!(
                        server = %config.name,
                        capability_count,
                        "MCP server connected"
                    );
                    let _ = self.servers.insert(
                        config.name.clone(),
                        ServerState {
                            client,
                            tool_defs: tool_defs.clone(),
                            health: McpServerHealth::Healthy,
                            consecutive_failures: 0,
                            last_error: None,
                            connected_at: Utc::now().to_rfc3339(),
                            tools_refreshed_at: Instant::now(),
                        },
                    );
                    discovered.push((config.name.clone(), tool_defs));
                }
                Err(e) => {
                    warn!(server = %config.name, error = %e, "failed to connect MCP server");
                    let _ = self.servers.insert(
                        config.name.clone(),
                        ServerState {
                            client: Arc::new(McpClient::failed_placeholder(&config.name)),
                            tool_defs: Vec::new(),
                            health: McpServerHealth::Failed,
                            consecutive_failures: 1,
                            last_error: Some(e.message.clone()),
                            connected_at: Utc::now().to_rfc3339(),
                            tools_refreshed_at: Instant::now(),
                        },
                    );
                }
            }
        }

        debug!(
            total_tools = discovered.iter().map(|(_, d)| d.len()).sum::<usize>(),
            servers = self
                .servers
                .iter()
                .filter(|(_, s)| s.health == McpServerHealth::Healthy)
                .count(),
            "MCP server manager initialized"
        );

        discovered
    }

    /// Connect to a single MCP server and discover its capabilities.
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

    /// Record a successful capability invocation for a server (resets failure counters).
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

    /// Record a failed capability invocation. Returns the new health state.
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
                    "MCP server exceeded max failures — capabilities disabled"
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

    /// Auto-restart attempt from the capability-invocation recovery path.
    ///
    /// Refuses with [`McpErrorKind::PermanentlyFailed`] if the server is
    /// already `Failed` — the caller must surface the error to the user and
    /// wait for manual intervention. Does NOT increment the failure counter
    /// on refusal; the counter advance happens only in the actual restart
    /// path when connect_server fails.
    pub async fn try_auto_restart(&mut self, name: &str) -> Result<Vec<McpToolDef>, McpError> {
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
    pub async fn manual_restart(&mut self, name: &str) -> Result<Vec<McpToolDef>, McpError> {
        self.do_restart(name).await
    }

    /// Shared restart body. Performs exponential backoff, shuts down the old
    /// client, reconnects, and installs a fresh ServerState on success.
    async fn do_restart(&mut self, name: &str) -> Result<Vec<McpToolDef>, McpError> {
        let attempt = self.servers.get(name).map_or(0, |s| s.consecutive_failures);

        // Exponential backoff: base * 2^(attempt-1), capped at max.
        // Every arithmetic op is saturating so a pathological `attempt`
        // (e.g. from a counter that reached its cap) can never overflow.
        if attempt > 0 {
            let factor = 2u64.saturating_pow(attempt.saturating_sub(1));
            let delay_ms = BACKOFF_BASE_MS.saturating_mul(factor).min(BACKOFF_MAX_MS);
            debug!(server = %name, delay_ms, attempt, "backoff before restart");
            tokio::time::sleep(std::time::Duration::from_millis(delay_ms)).await;
        }

        // Shut down existing connection
        if let Some(state) = self.servers.get(name) {
            state.client.shutdown().await;
        }

        // Find config
        let config = self
            .configs
            .iter()
            .find(|c| c.name == name)
            .ok_or_else(|| McpError {
                server: name.to_string(),
                kind: McpErrorKind::Protocol("unknown server".into()),
                message: format!("No MCP server configured with name: {name}"),
            })?
            .clone();

        match self.connect_server(&config).await {
            Ok((client, tool_defs)) => {
                let capability_count = tool_defs.len();
                info!(server = %name, capability_count, "MCP server restarted successfully");
                let _ = self.servers.insert(
                    name.to_string(),
                    ServerState {
                        client,
                        tool_defs: tool_defs.clone(),
                        health: McpServerHealth::Healthy,
                        consecutive_failures: 0,
                        last_error: None,
                        connected_at: Utc::now().to_rfc3339(),
                        tools_refreshed_at: Instant::now(),
                    },
                );
                Ok(tool_defs)
            }
            Err(e) => {
                if let Some(state) = self.servers.get_mut(name) {
                    // INVARIANT: saturating_add keeps the counter bounded.
                    state.consecutive_failures = state.consecutive_failures.saturating_add(1);
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
        self.configs
            .iter()
            .map(|config| {
                if let Some(state) = self.servers.get(&config.name) {
                    McpServerStatus {
                        name: config.name.clone(),
                        health: state.health.clone(),
                        capability_count: state.capability_count(),
                        consecutive_failures: state.consecutive_failures,
                        last_error: state.last_error.clone(),
                        connected_at: Some(state.connected_at.clone()),
                    }
                } else {
                    McpServerStatus {
                        name: config.name.clone(),
                        health: McpServerHealth::Failed,
                        capability_count: 0,
                        consecutive_failures: 0,
                        last_error: Some("never started".into()),
                        connected_at: None,
                    }
                }
            })
            .collect()
    }

    /// Get a list of connected (healthy or degraded) server names.
    pub fn connected_servers(&self) -> Vec<&str> {
        self.servers
            .iter()
            .filter(|(_, s)| s.health != McpServerHealth::Failed)
            .map(|(name, _)| name.as_str())
            .collect()
    }

    /// Check if a specific server is connected and operational.
    pub fn is_connected(&self, name: &str) -> bool {
        self.servers
            .get(name)
            .is_some_and(|s| s.health != McpServerHealth::Failed)
    }

    /// Get the health state of a specific server.
    pub fn health(&self, name: &str) -> Option<McpServerHealth> {
        self.servers.get(name).map(|s| s.health.clone())
    }

    /// Get the client for a specific server (if connected).
    pub fn client(&self, name: &str) -> Option<Arc<McpClient>> {
        self.servers
            .get(name)
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
            state.tool_defs.clear();
        }
    }

    /// Refresh capability schemas for a server if the last refresh is older than `ttl`.
    ///
    /// Returns:
    /// - `Ok(None)` — refresh not needed (still within TTL), OR the refresh
    ///   attempt failed transiently (logged; timestamp bumped to avoid hammering).
    /// - `Ok(Some(SchemaRefreshResult))` — refresh ran, contains the diff vs
    ///   previously-cached schemas and the fresh tool list.
    /// - `Err(McpError)` — server not found or permanently failed.
    ///
    /// INVARIANT: debounced per-server via `tools_refreshed_at`. Because this
    /// method takes `&mut self`, two concurrent callers for the same server
    /// cannot both pass the staleness check — the second observes the updated
    /// timestamp from the first.
    pub async fn refresh_schemas_if_stale(
        &mut self,
        name: &str,
        ttl: Duration,
    ) -> Result<Option<SchemaRefreshResult>, McpError> {
        let Some(state) = self.servers.get(name) else {
            return Ok(None);
        };
        if state.health == McpServerHealth::Failed {
            return Ok(None);
        }
        if state.tools_refreshed_at.elapsed() < ttl {
            return Ok(None);
        }

        let client = state.client.clone();
        let old_capabilities = state.tool_defs.clone();

        match client.list_tools().await {
            Ok(new_capabilities) => {
                let diff = diff_schemas(&old_capabilities, &new_capabilities);
                if let Some(state_mut) = self.servers.get_mut(name) {
                    state_mut.tool_defs = new_capabilities.clone();
                    state_mut.tools_refreshed_at = Instant::now();
                }
                Ok(Some(SchemaRefreshResult {
                    diff,
                    capabilities: new_capabilities,
                }))
            }
            Err(e) => {
                warn!(
                    server = %name,
                    error = %e,
                    "MCP schema refresh failed; continuing with cached schemas"
                );
                if let Some(state_mut) = self.servers.get_mut(name) {
                    // Bump the timestamp on transient failure to avoid refresh
                    // attempts on every subsequent call during an outage. A
                    // real connection loss triggers the restart path elsewhere.
                    state_mut.tools_refreshed_at = Instant::now();
                }
                Ok(None)
            }
        }
    }

    #[cfg(test)]
    pub(crate) fn tool_defs_for_test(&self, name: &str) -> Option<Vec<McpToolDef>> {
        self.servers.get(name).map(|s| s.tool_defs.clone())
    }
}

#[cfg(test)]
#[path = "server_manager/tests.rs"]
mod tests;
