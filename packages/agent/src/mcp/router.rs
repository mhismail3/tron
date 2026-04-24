//! Central MCP coordinator.
//!
//! Wraps [`McpServerManager`] and [`ToolIndex`] into a single struct shared
//! via `Arc<tokio::sync::RwLock<McpRouter>>`. Provides search, call routing,
//! server lifecycle management, and settings persistence.
//!
//! ## Schema-drift refresh (C8)
//!
//! MCP servers may update their tool set mid-session (feature flags, schema
//! bumps, tool additions). The router proactively re-fetches `tools/list` on
//! every `call` when the per-server cache is older than
//! `schema_refresh_ttl_ms`. If a drift is detected, the [`ToolIndex`] is
//! rebuilt for that server so the next `McpSearch` response to the LLM shows
//! the live schema. TTL `0` disables proactive refresh entirely.

use std::path::PathBuf;
use std::time::Duration;

use serde_json::Value;
use tracing::{debug, info, warn};

use crate::mcp::client::McpError;
use crate::mcp::server_manager::McpServerManager;
use crate::mcp::tool_index::{ToolIndex, ToolMatch};
use crate::mcp::types::{McpServerConfig, McpServerStatus, McpToolResult};

/// Central coordinator for MCP servers and tool discovery.
pub struct McpRouter {
    manager: McpServerManager,
    index: ToolIndex,
    settings_path: PathBuf,
    /// Proactive schema-refresh TTL. `None` ⇒ disabled.
    schema_refresh_ttl: Option<Duration>,
}

impl McpRouter {
    /// Create a new router, start all enabled servers, and index their tools.
    ///
    /// `schema_refresh_ttl_ms` of `0` disables proactive TTL-driven refresh.
    /// See module docs for the refresh contract.
    pub async fn new(
        configs: Vec<McpServerConfig>,
        settings_path: PathBuf,
        schema_refresh_ttl_ms: u64,
    ) -> Self {
        let mut manager = McpServerManager::new(configs);
        let discovered = manager.start_all().await;

        let mut index = ToolIndex::new();
        for (server, defs) in &discovered {
            index.add_server_tools(server, defs);
        }

        let schema_refresh_ttl =
            (schema_refresh_ttl_ms > 0).then(|| Duration::from_millis(schema_refresh_ttl_ms));

        Self {
            manager,
            index,
            settings_path,
            schema_refresh_ttl,
        }
    }

    /// Update the proactive schema-refresh TTL (in ms). Setting `0` disables.
    ///
    /// Used by `reload_from_settings` so a settings edit takes effect without
    /// a daemon restart.
    pub fn set_schema_refresh_ttl_ms(&mut self, ttl_ms: u64) {
        self.schema_refresh_ttl = (ttl_ms > 0).then(|| Duration::from_millis(ttl_ms));
    }

    /// Current TTL in ms (0 if disabled). Used by tests and diagnostics.
    pub fn schema_refresh_ttl_ms(&self) -> u64 {
        self.schema_refresh_ttl
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0)
    }

    /// Search for tools matching keywords.
    pub fn search(&self, query: &str, server_filter: Option<&str>) -> Vec<ToolMatch> {
        self.index.search(query, server_filter)
    }

    /// Format search results as compact text for LLM consumption.
    pub fn format_search_results(&self, query: &str, server_filter: Option<&str>) -> String {
        let matches = self.search(query, server_filter);
        ToolIndex::format_results(&matches)
    }

    /// Call a tool on an MCP server.
    ///
    /// Before forwarding, the server's tool schemas are re-fetched if the
    /// per-server cache is older than `schema_refresh_ttl_ms` (C8). On drift,
    /// the [`ToolIndex`] is rebuilt for that server so subsequent
    /// `McpSearch` responses reflect the live schema. Refresh failures are
    /// logged and the call proceeds with the cached schema — the actual tool
    /// call will surface its own error if the server is truly unreachable.
    ///
    /// On `ConnectionLost`, attempts one automatic restart + retry.
    pub async fn call(
        &mut self,
        server: &str,
        tool: &str,
        args: Value,
    ) -> Result<McpToolResult, McpError> {
        // Proactive schema refresh (C8). Runs only when TTL is enabled and the
        // server's cached schemas are older than the TTL. `refresh_schemas_if_stale`
        // returns `Ok(None)` for unknown / failed / within-TTL servers and swallows
        // transient list_tools errors (bumping the timestamp to avoid hammering).
        if let Some(ttl) = self.schema_refresh_ttl {
            match self.manager.refresh_schemas_if_stale(server, ttl).await {
                Ok(Some(refresh)) if !refresh.diff.is_empty() => {
                    info!(
                        server,
                        added = ?refresh.diff.added,
                        removed = ?refresh.diff.removed,
                        modified = ?refresh.diff.modified,
                        "MCP schema drift detected; rebuilding tool index"
                    );
                    self.index.remove_server(server);
                    self.index.add_server_tools(server, &refresh.tools);
                }
                Ok(Some(_)) => {
                    debug!(server, "MCP schema refreshed; no drift");
                }
                Ok(None) => {}
                Err(e) => {
                    warn!(server, error = %e, "schema refresh errored; proceeding with cached");
                }
            }
        }

        let client = self.manager.client(server).ok_or_else(|| McpError {
            server: server.to_string(),
            kind: crate::mcp::client::McpErrorKind::Protocol("unknown server".into()),
            message: format!(
                "Tool '{tool}' not found on server '{server}'. Use McpSearch to discover available tools.",
            ),
        })?;

        match client.call_tool(tool, args.clone()).await {
            Ok(result) => {
                self.manager.record_success(server);
                Ok(result)
            }
            Err(e) if e.requires_restart() => {
                warn!(server, tool, "connection lost — attempting restart");
                match self.manager.try_auto_restart(server).await {
                    Ok(new_defs) => {
                        self.index.remove_server(server);
                        self.index.add_server_tools(server, &new_defs);

                        let client = self.manager.client(server).ok_or_else(|| McpError {
                            server: server.to_string(),
                            kind: crate::mcp::client::McpErrorKind::ConnectionLost,
                            message: format!(
                                "Server '{server}' restart succeeded but client unavailable"
                            ),
                        })?;

                        client.call_tool(tool, args).await.inspect(|_| {
                            self.manager.record_success(server);
                        })
                    }
                    Err(restart_err) => {
                        let _ = self.manager.record_failure(server, &restart_err.message);
                        Err(e)
                    }
                }
            }
            Err(e) => {
                let _ = self.manager.record_failure(server, &e.message);
                Err(e)
            }
        }
    }

    /// Add a new server, connect, discover tools, persist to settings.
    pub async fn add_server(&mut self, config: McpServerConfig) -> Result<usize, McpError> {
        let name = config.name.clone();
        self.manager.add_config(config);

        let defs = self.manager.manual_restart(&name).await?;
        let tool_count = defs.len();
        self.index.add_server_tools(&name, &defs);

        self.persist_configs();

        info!(server = %name, tool_count, "MCP server added");
        Ok(tool_count)
    }

    /// Remove a server, shut it down, remove from index, persist.
    pub async fn remove_server(&mut self, name: &str) {
        self.index.remove_server(name);
        self.manager.remove_config(name).await;
        self.persist_configs();
        info!(server = %name, "MCP server removed");
    }

    /// Enable a disabled server: toggle config, connect, index tools.
    pub async fn enable_server(&mut self, name: &str) -> Result<(), McpError> {
        if let Some(config) = self.manager.config_mut(name) {
            config.enabled = true;
        } else {
            return Err(McpError {
                server: name.to_string(),
                kind: crate::mcp::client::McpErrorKind::Protocol("unknown server".into()),
                message: format!("No MCP server configured with name: {name}"),
            });
        }

        let defs = self.manager.manual_restart(name).await?;
        self.index.add_server_tools(name, &defs);
        self.persist_configs();
        Ok(())
    }

    /// Disable a server: disconnect, remove from index, toggle config.
    pub async fn disable_server(&mut self, name: &str) -> Result<(), McpError> {
        if let Some(config) = self.manager.config_mut(name) {
            config.enabled = false;
        } else {
            return Err(McpError {
                server: name.to_string(),
                kind: crate::mcp::client::McpErrorKind::Protocol("unknown server".into()),
                message: format!("No MCP server configured with name: {name}"),
            });
        }

        self.index.remove_server(name);
        self.manager.disconnect_server(name).await;
        self.persist_configs();
        Ok(())
    }

    /// Restart a server: reconnect and rebuild its index entries.
    ///
    /// Always treated as a manual restart — the user has explicitly asked for
    /// a restart via RPC, so any prior `Failed` state is forgiven.
    pub async fn restart_server(&mut self, name: &str) -> Result<usize, McpError> {
        let defs = self.manager.manual_restart(name).await?;
        let tool_count = defs.len();
        self.index.remove_server(name);
        self.index.add_server_tools(name, &defs);
        Ok(tool_count)
    }

    /// Reload configs from settings file, diff against current state.
    pub async fn reload_from_settings(&mut self) -> Result<usize, String> {
        let settings =
            crate::settings::load_settings_from_path(&self.settings_path).unwrap_or_default();
        let new_configs = settings.mcp.servers;
        let new_ttl_ms = settings.mcp.schema_refresh_ttl_ms;

        let current_names: Vec<String> = self
            .manager
            .configs()
            .iter()
            .map(|c| c.name.clone())
            .collect();
        let new_names: Vec<String> = new_configs.iter().map(|c| c.name.clone()).collect();

        // Remove servers no longer in config
        for name in &current_names {
            if !new_names.contains(name) {
                self.remove_server(name).await;
            }
        }

        // Add new servers
        for config in &new_configs {
            if !current_names.contains(&config.name)
                && let Err(e) = self.add_server(config.clone()).await
            {
                warn!(server = %config.name, error = %e, "failed to add server during reload");
            }
        }

        // Pick up any change to the refresh TTL without requiring a daemon
        // restart. Setting it to 0 disables proactive refresh.
        self.set_schema_refresh_ttl_ms(new_ttl_ms);

        Ok(self.manager.configs().len())
    }

    /// Get status snapshots for all servers.
    pub fn status(&self) -> Vec<McpServerStatus> {
        self.manager.status()
    }

    /// Shut down all servers.
    pub async fn shutdown_all(&mut self) {
        self.manager.shutdown_all().await;
    }

    /// Persist current configs to settings file.
    fn persist_configs(&self) {
        let configs = self.manager.configs();
        let update = serde_json::json!({
            "mcp": {
                "servers": configs
            }
        });
        if let Err(e) =
            crate::server::rpc::settings_service::update_settings(&self.settings_path, update)
        {
            warn!(error = %e, "failed to persist MCP server configs");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn new_with_empty_configs() {
        let dir = tempfile::tempdir().unwrap();
        let settings_path = dir.path().join("settings.json");
        let router = McpRouter::new(Vec::new(), settings_path, 0).await;
        assert!(router.status().is_empty());
    }

    #[tokio::test]
    async fn search_delegates_to_index() {
        let dir = tempfile::tempdir().unwrap();
        let settings_path = dir.path().join("settings.json");
        let mut router = McpRouter::new(Vec::new(), settings_path, 0).await;

        // Manually populate index for unit test
        let defs = vec![crate::mcp::types::McpToolDef {
            name: "query".into(),
            description: "Run SQL".into(),
            input_schema: serde_json::json!({"type": "object"}),
        }];
        router.index.add_server_tools("sqlite", &defs);

        let results = router.search("query", None);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].server, "sqlite");
    }

    #[tokio::test]
    async fn call_unknown_server_returns_error() {
        let dir = tempfile::tempdir().unwrap();
        let settings_path = dir.path().join("settings.json");
        let mut router = McpRouter::new(Vec::new(), settings_path, 0).await;

        let result = router
            .call("nonexistent", "tool", serde_json::json!({}))
            .await;
        assert!(result.is_err());
        assert!(result.unwrap_err().message.contains("nonexistent"));
    }

    #[tokio::test]
    async fn status_returns_all_servers() {
        let dir = tempfile::tempdir().unwrap();
        let settings_path = dir.path().join("settings.json");
        let router = McpRouter::new(Vec::new(), settings_path, 0).await;
        assert!(router.status().is_empty());
    }
}
