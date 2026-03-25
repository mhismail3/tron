//! MCP server lifecycle management.
//!
//! Handles starting, stopping, and restarting MCP servers based on configuration.
//! Discovers tools from connected servers and registers them dynamically.

use std::collections::HashMap;
use std::sync::Arc;

use tracing::{debug, error, info, warn};

use crate::mcp::client::McpClient;
use crate::mcp::tool_bridge::create_bridge_tools;
use crate::mcp::types::McpServerConfig;
use crate::tools::traits::TronTool;

/// Manages the lifecycle of MCP server connections.
pub struct McpServerManager {
    /// Active MCP clients keyed by server name.
    clients: HashMap<String, Arc<McpClient>>,
    /// Configuration for each server.
    configs: Vec<McpServerConfig>,
}

impl McpServerManager {
    /// Create a new manager with the given server configurations.
    pub fn new(configs: Vec<McpServerConfig>) -> Self {
        Self {
            clients: HashMap::new(),
            configs,
        }
    }

    /// Start all configured MCP servers and discover their tools.
    ///
    /// Returns a list of bridge tools ready for registration.
    /// Servers that fail to start are skipped with a warning.
    pub async fn start_all(&mut self) -> Vec<Arc<dyn TronTool>> {
        let mut all_tools: Vec<Arc<dyn TronTool>> = Vec::new();

        for config in &self.configs {
            match self.connect_server(config).await {
                Ok((client, tools)) => {
                    info!(
                        server = %config.name,
                        tool_count = tools.len(),
                        "MCP server connected"
                    );
                    self.clients.insert(config.name.clone(), client);
                    all_tools.extend(tools);
                }
                Err(e) => {
                    warn!(server = %config.name, error = %e, "failed to connect MCP server");
                }
            }
        }

        debug!(
            total_tools = all_tools.len(),
            servers = self.clients.len(),
            "MCP server manager initialized"
        );

        all_tools
    }

    /// Connect to a single MCP server and discover its tools.
    async fn connect_server(
        &self,
        config: &McpServerConfig,
    ) -> Result<(Arc<McpClient>, Vec<Arc<dyn TronTool>>), String> {
        let client = if config.url.is_some() {
            McpClient::connect_http(config).await?
        } else if config.command.is_some() {
            McpClient::connect_stdio(config).await?
        } else {
            return Err(format!(
                "MCP server '{}' needs either 'command' (stdio) or 'url' (HTTP)",
                config.name
            ));
        };

        let client = Arc::new(client);

        // Discover tools
        let tool_defs = client.list_tools().await?;
        let tools = create_bridge_tools(&config.name, &tool_defs, client.clone());

        Ok((client, tools))
    }

    /// Restart a specific server by name.
    pub async fn restart_server(&mut self, name: &str) -> Result<Vec<Arc<dyn TronTool>>, String> {
        // Shut down existing
        if let Some(client) = self.clients.remove(name) {
            client.shutdown().await;
        }

        // Find config
        let config = self.configs.iter()
            .find(|c| c.name == name)
            .ok_or_else(|| format!("No MCP server configured with name: {name}"))?
            .clone();

        let (client, tools) = self.connect_server(&config).await?;
        self.clients.insert(name.to_string(), client);

        Ok(tools)
    }

    /// Shut down all MCP servers.
    pub async fn shutdown_all(&mut self) {
        for (name, client) in self.clients.drain() {
            debug!(server = %name, "shutting down MCP server");
            client.shutdown().await;
        }
    }

    /// Get a list of connected server names.
    pub fn connected_servers(&self) -> Vec<&str> {
        self.clients.keys().map(String::as_str).collect()
    }

    /// Check if a specific server is connected.
    pub fn is_connected(&self, name: &str) -> bool {
        self.clients.contains_key(name)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_manager_empty() {
        let manager = McpServerManager::new(Vec::new());
        assert!(manager.connected_servers().is_empty());
    }

    #[test]
    fn is_connected_false_when_empty() {
        let manager = McpServerManager::new(Vec::new());
        assert!(!manager.is_connected("sqlite"));
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
        }];
        let mut manager = McpServerManager::new(configs);
        let tools = manager.start_all().await;
        // Should skip the failing server gracefully
        assert!(tools.is_empty());
        assert!(!manager.is_connected("bad-server"));
    }

    #[test]
    fn server_config_missing_both_command_and_url() {
        let config = McpServerConfig {
            name: "incomplete".into(),
            command: None,
            args: Vec::new(),
            env: HashMap::new(),
            url: None,
            tool_timeout_ms: 30_000,
        };
        // This would fail at connect_server time
        assert!(config.command.is_none());
        assert!(config.url.is_none());
    }

    #[tokio::test]
    async fn shutdown_all_no_panic_when_empty() {
        let mut manager = McpServerManager::new(Vec::new());
        manager.shutdown_all().await;
    }
}
