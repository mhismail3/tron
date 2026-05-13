//! Central MCP coordinator.
//!
//! Wraps [`McpServerManager`] and [`McpCapabilityIndex`] into a single struct shared
//! via `Arc<tokio::sync::RwLock<McpRouter>>`. Provides search, call routing,
//! server lifecycle management, and settings persistence. Settings writes go
//! through `settings::SettingsStore`; this module deliberately has no
//! dependency on the server/RPC layer.
//!
//! ## Schema-drift refresh (C8)
//!
//! MCP servers may update their tool set mid-session (feature flags, schema
//! bumps, tool additions). The router proactively re-fetches `tools/list` on
//! every `call` when the per-server cache is older than
//! `schema_refresh_ttl_ms`. If a drift is detected, the [`McpCapabilityIndex`] is
//! rebuilt for that server so the next capability search result shows
//! the live schema. TTL `0` disables proactive refresh entirely.

use std::path::PathBuf;
use std::time::Duration;

use serde_json::Value;
use tracing::{debug, info, warn};

use crate::domains::mcp::capability_index::{McpCapabilityIndex, McpCapabilityMatch};
use crate::domains::mcp::client::McpError;
use crate::domains::mcp::server_manager::McpServerManager;
use crate::domains::mcp::types::{
    McpServerConfig, McpServerHealth, McpServerStatus, McpToolResult,
};

/// Central coordinator for MCP servers and tool discovery.
pub struct McpRouter {
    manager: McpServerManager,
    index: McpCapabilityIndex,
    settings_path: PathBuf,
    /// Proactive schema-refresh TTL. `None` ⇒ disabled.
    schema_refresh_ttl: Option<Duration>,
}

impl McpRouter {
    /// Create a new router, start all enabled servers, and index their capabilities.
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

        let mut index = McpCapabilityIndex::new();
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

    /// Search for capabilities matching keywords.
    pub fn search(&self, query: &str, server_filter: Option<&str>) -> Vec<McpCapabilityMatch> {
        self.index.search(query, server_filter)
    }

    /// Format search results as compact text for LLM consumption.
    pub fn format_search_results(&self, query: &str, server_filter: Option<&str>) -> String {
        let matches = self.search(query, server_filter);
        McpCapabilityIndex::format_results(&matches)
    }

    /// Call a tool on an MCP server.
    ///
    /// Before forwarding, the server's capability schemas are re-fetched if the
    /// per-server cache is older than `schema_refresh_ttl_ms` (C8). On drift,
    /// the [`McpCapabilityIndex`] is rebuilt for that server so subsequent
    /// capability search results reflect the live schema. Refresh failures are
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
                    self.index.add_server_tools(server, &refresh.capabilities);
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
            kind: crate::domains::mcp::client::McpErrorKind::Protocol("unknown server".into()),
            message: format!(
                "MCP tool '{tool}' not found on server '{server}'. Use capability search to discover available MCP functions.",
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
                            kind: crate::domains::mcp::client::McpErrorKind::ConnectionLost,
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

    /// Add a new server, connect, discover capabilities, persist to settings.
    pub async fn add_server(&mut self, config: McpServerConfig) -> Result<usize, McpError> {
        let name = config.name.clone();
        let enabled = config.enabled;
        self.manager.add_config(config);

        let capability_count = if enabled {
            let defs = match self.manager.manual_restart(&name).await {
                Ok(defs) => defs,
                Err(error) => {
                    self.manager.remove_config(&name).await;
                    return Err(error);
                }
            };
            let capability_count = defs.len();
            self.index.add_server_tools(&name, &defs);
            capability_count
        } else {
            0
        };

        if let Err(error) = self.persist_configs().await {
            self.index.remove_server(&name);
            self.manager.remove_config(&name).await;
            return Err(McpError {
                server: name,
                kind: crate::domains::mcp::client::McpErrorKind::Protocol(
                    "settings persist failed".into(),
                ),
                message: error,
            });
        };

        info!(server = %name, capability_count, "MCP server added");
        Ok(capability_count)
    }

    /// Remove a server, shut it down, remove from index, persist.
    pub async fn remove_server(&mut self, name: &str) -> Result<(), String> {
        let configs: Vec<McpServerConfig> = self
            .manager
            .configs()
            .iter()
            .filter(|config| config.name != name)
            .cloned()
            .collect();
        self.persist_configs_slice(&configs).await?;
        self.index.remove_server(name);
        self.manager.remove_config(name).await;
        info!(server = %name, "MCP server removed");
        Ok(())
    }

    /// Enable a disabled server: toggle config, connect, index capabilities.
    pub async fn enable_server(&mut self, name: &str) -> Result<(), McpError> {
        let old_config = if let Some(config) = self.manager.config_mut(name) {
            let old = config.clone();
            config.enabled = true;
            old
        } else {
            return Err(McpError {
                server: name.to_string(),
                kind: crate::domains::mcp::client::McpErrorKind::Protocol("unknown server".into()),
                message: format!("No MCP server configured with name: {name}"),
            });
        };

        let defs = match self.manager.manual_restart(name).await {
            Ok(defs) => defs,
            Err(error) => {
                self.manager.disconnect_server(name).await;
                if let Some(config) = self.manager.config_mut(name) {
                    *config = old_config;
                }
                return Err(error);
            }
        };
        self.index.add_server_tools(name, &defs);
        if let Err(message) = self.persist_configs().await {
            self.index.remove_server(name);
            self.manager.disconnect_server(name).await;
            if let Some(config) = self.manager.config_mut(name) {
                *config = old_config;
            }
            return Err(McpError {
                server: name.to_string(),
                kind: crate::domains::mcp::client::McpErrorKind::Protocol(
                    "settings persist failed".into(),
                ),
                message,
            });
        }
        Ok(())
    }

    /// Disable a server: disconnect, remove from index, toggle config.
    pub async fn disable_server(&mut self, name: &str) -> Result<(), McpError> {
        let Some(existing) = self.manager.configs().iter().find(|c| c.name == name) else {
            return Err(McpError {
                server: name.to_string(),
                kind: crate::domains::mcp::client::McpErrorKind::Protocol("unknown server".into()),
                message: format!("No MCP server configured with name: {name}"),
            });
        };
        let mut next = existing.clone();
        next.enabled = false;
        let configs: Vec<McpServerConfig> = self
            .manager
            .configs()
            .iter()
            .map(|config| {
                if config.name == name {
                    next.clone()
                } else {
                    config.clone()
                }
            })
            .collect();

        self.persist_configs_slice(&configs)
            .await
            .map_err(|message| McpError {
                server: name.to_string(),
                kind: crate::domains::mcp::client::McpErrorKind::Protocol(
                    "settings persist failed".into(),
                ),
                message,
            })?;

        self.index.remove_server(name);
        self.manager.disconnect_server(name).await;
        if let Some(config) = self.manager.config_mut(name) {
            config.enabled = false;
        }
        Ok(())
    }

    /// Restart a server: reconnect and rebuild its index entries.
    ///
    /// Always treated as a manual restart — the user has explicitly asked for
    /// a restart via RPC, so any prior `Failed` state is forgiven.
    pub async fn restart_server(&mut self, name: &str) -> Result<usize, McpError> {
        let defs = self.manager.manual_restart(name).await?;
        let capability_count = defs.len();
        self.index.remove_server(name);
        self.index.add_server_tools(name, &defs);
        Ok(capability_count)
    }

    /// Reload configs from settings file, diff against current state.
    pub async fn reload_from_settings(&mut self) -> Result<usize, String> {
        let settings = crate::domains::settings::load_settings_from_path(&self.settings_path)
            .map_err(|error| error.to_string())?;
        let new_configs = settings.mcp.servers;
        let new_ttl_ms = settings.mcp.schema_refresh_ttl_ms;

        let mut staged_manager = McpServerManager::new(new_configs.clone());
        let discovered = staged_manager.start_all().await;
        for config in &new_configs {
            if config.enabled
                && staged_manager.health(&config.name) != Some(McpServerHealth::Healthy)
            {
                staged_manager.shutdown_all().await;
                return Err(format!("failed to connect MCP server '{}'", config.name));
            }
        }

        let mut staged_index = McpCapabilityIndex::new();
        for (server, defs) in &discovered {
            staged_index.add_server_tools(server, defs);
        }

        let mut old_manager = std::mem::replace(&mut self.manager, staged_manager);
        self.index = staged_index;

        // Pick up any change to the refresh TTL without requiring a daemon
        // restart. Setting it to 0 disables proactive refresh.
        self.set_schema_refresh_ttl_ms(new_ttl_ms);
        old_manager.shutdown_all().await;

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
    async fn persist_configs(&self) -> Result<(), String> {
        let configs = self.manager.configs();
        self.persist_configs_slice(configs).await
    }

    async fn persist_configs_slice(&self, configs: &[McpServerConfig]) -> Result<(), String> {
        let update = serde_json::json!({
            "mcp": {
                "servers": configs
            }
        });
        let _operation_guard = crate::domains::settings::SettingsStore::operation_lock().await;
        crate::domains::settings::SettingsStore::new(&self.settings_path)
            .update(update)
            .map_err(|error| {
                warn!(error = %error, "failed to persist MCP server configs");
                error.to_string()
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_settings_path(dir: &tempfile::TempDir) -> PathBuf {
        let home = dir.path().join(".tron");
        crate::shared::constitution::ensure_tron_home_at(&home).unwrap();
        home.join(crate::shared::paths::dirs::PROFILES)
            .join(crate::shared::profile::USER_PROFILE)
            .join(crate::shared::paths::files::PROFILE_TOML)
    }

    fn disabled_config(name: &str) -> McpServerConfig {
        McpServerConfig {
            name: name.into(),
            command: Some("sh".into()),
            args: vec!["-c".into(), "exit 0".into()],
            env: Default::default(),
            url: None,
            tool_timeout_ms: 30_000,
            enabled: false,
        }
    }

    fn bad_enabled_config(name: &str) -> McpServerConfig {
        McpServerConfig {
            name: name.into(),
            command: Some("nonexistent-mcp-binary-12345".into()),
            args: Vec::new(),
            env: Default::default(),
            url: None,
            tool_timeout_ms: 30_000,
            enabled: true,
        }
    }

    #[tokio::test]
    async fn new_with_empty_configs() {
        let dir = tempfile::tempdir().unwrap();
        let settings_path = temp_settings_path(&dir);
        let router = McpRouter::new(Vec::new(), settings_path, 0).await;
        assert!(router.status().is_empty());
    }

    #[tokio::test]
    async fn search_delegates_to_index() {
        let dir = tempfile::tempdir().unwrap();
        let settings_path = temp_settings_path(&dir);
        let mut router = McpRouter::new(Vec::new(), settings_path, 0).await;

        // Manually populate index for unit test
        let defs = vec![crate::domains::mcp::types::McpToolDef {
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
        let settings_path = temp_settings_path(&dir);
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
        let settings_path = temp_settings_path(&dir);
        let router = McpRouter::new(Vec::new(), settings_path, 0).await;
        assert!(router.status().is_empty());
    }

    #[tokio::test]
    async fn reload_from_malformed_settings_returns_error_without_mutating_runtime() {
        let dir = tempfile::tempdir().unwrap();
        let settings_path = temp_settings_path(&dir);
        let mut router =
            McpRouter::new(vec![disabled_config("disabled")], settings_path.clone(), 0).await;
        std::fs::write(&settings_path, "{broken").unwrap();

        let err = router.reload_from_settings().await.unwrap_err();

        assert!(err.contains("parse settings TOML"));
        assert_eq!(router.status().len(), 1);
        assert_eq!(router.status()[0].name, "disabled");
    }

    #[tokio::test]
    async fn reload_from_failed_server_add_preserves_existing_runtime() {
        let dir = tempfile::tempdir().unwrap();
        let settings_path = temp_settings_path(&dir);
        let existing = disabled_config("existing");
        let mut router = McpRouter::new(vec![existing.clone()], settings_path.clone(), 0).await;
        std::fs::write(
            &settings_path,
            serde_json::json!({
                "mcp": {
                    "servers": [
                        existing,
                        bad_enabled_config("broken")
                    ]
                }
            })
            .to_string(),
        )
        .unwrap();

        let err = router.reload_from_settings().await.unwrap_err();

        assert!(err.contains("broken"));
        let statuses = router.status();
        assert_eq!(statuses.len(), 1);
        assert_eq!(statuses[0].name, "existing");
    }

    #[tokio::test]
    async fn add_disabled_server_persists_without_starting_runtime() {
        let dir = tempfile::tempdir().unwrap();
        let settings_path = temp_settings_path(&dir);
        let mut router = McpRouter::new(Vec::new(), settings_path.clone(), 0).await;

        let count = router
            .add_server(disabled_config("disabled"))
            .await
            .unwrap();

        assert_eq!(count, 0);
        let settings = crate::domains::settings::load_settings_from_path(&settings_path).unwrap();
        assert_eq!(settings.mcp.servers.len(), 1);
        assert_eq!(settings.mcp.servers[0].name, "disabled");
        assert!(!settings.mcp.servers[0].enabled);
    }

    #[tokio::test]
    async fn failed_enabled_add_preserves_existing_settings_and_runtime() {
        let dir = tempfile::tempdir().unwrap();
        let settings_path = temp_settings_path(&dir);
        let mut router = McpRouter::new(Vec::new(), settings_path.clone(), 0).await;
        router
            .add_server(disabled_config("existing"))
            .await
            .unwrap();

        let err = router
            .add_server(bad_enabled_config("broken"))
            .await
            .unwrap_err();

        assert_eq!(err.server, "broken");
        let statuses = router.status();
        assert_eq!(statuses.len(), 1);
        assert_eq!(statuses[0].name, "existing");
        let settings = crate::domains::settings::load_settings_from_path(&settings_path).unwrap();
        assert_eq!(settings.mcp.servers.len(), 1);
        assert_eq!(settings.mcp.servers[0].name, "existing");
    }

    #[tokio::test]
    async fn failed_enable_preserves_disabled_config_and_settings() {
        let dir = tempfile::tempdir().unwrap();
        let settings_path = temp_settings_path(&dir);
        let mut router = McpRouter::new(Vec::new(), settings_path.clone(), 0).await;
        router.add_server(disabled_config("broken")).await.unwrap();

        let err = router.enable_server("broken").await.unwrap_err();

        assert_eq!(err.server, "broken");
        assert!(!router.manager.configs()[0].enabled);
        let settings = crate::domains::settings::load_settings_from_path(&settings_path).unwrap();
        assert_eq!(settings.mcp.servers.len(), 1);
        assert!(!settings.mcp.servers[0].enabled);
    }

    #[tokio::test]
    async fn remove_server_persists_before_runtime_removal() {
        let dir = tempfile::tempdir().unwrap();
        let settings_path = temp_settings_path(&dir);
        let mut router = McpRouter::new(Vec::new(), settings_path.clone(), 0).await;
        router
            .add_server(disabled_config("remove-me"))
            .await
            .unwrap();

        router.remove_server("remove-me").await.unwrap();

        assert!(router.status().is_empty());
        let settings = crate::domains::settings::load_settings_from_path(&settings_path).unwrap();
        assert!(settings.mcp.servers.is_empty());
    }
}
