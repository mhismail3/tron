//! Tool registry — central index of all registered tools.
//!
//! The [`ToolRegistry`] maps tool names to their [`TronTool`] implementations.
//! The runtime registers tools at startup and queries the registry to dispatch
//! tool calls and to generate the LLM tool schema.

use std::collections::HashSet;
use std::sync::{Arc, OnceLock};

use crate::core::tools::Tool;
use indexmap::IndexMap;
use tracing::debug;

use crate::tools::traits::TronTool;

/// Central registry mapping tool names to their implementations.
///
/// Uses `IndexMap` to preserve insertion order — tool ordering matters for the
/// LLM API (tools are sent in registration order) and must match the TS server.
pub struct ToolRegistry {
    tools: IndexMap<String, Arc<dyn TronTool>>,
    cached_definitions: OnceLock<Vec<Tool>>,
}

impl ToolRegistry {
    /// Create an empty registry.
    pub fn new() -> Self {
        Self {
            tools: IndexMap::new(),
            cached_definitions: OnceLock::new(),
        }
    }

    /// Register a tool. Overwrites any existing tool with the same name.
    pub fn register(&mut self, tool: Arc<dyn TronTool>) {
        debug!(tool_name = tool.name(), "tool registered");
        let _ = self.tools.insert(tool.name().to_owned(), tool);
        self.cached_definitions = OnceLock::new();
    }

    /// Look up a tool by name.
    pub fn get(&self, name: &str) -> Option<Arc<dyn TronTool>> {
        self.tools.get(name).cloned()
    }

    /// Return all registered tools in registration order.
    pub fn list(&self) -> Vec<Arc<dyn TronTool>> {
        self.tools.values().cloned().collect()
    }

    /// Return all tool schemas for the LLM in registration order.
    pub fn definitions(&self) -> Vec<Tool> {
        self.cached_definitions
            .get_or_init(|| self.tools.values().map(|t| t.definition()).collect())
            .clone()
    }

    /// Return condensed tool schemas for local models, filtered to `allowed` names.
    ///
    /// Uses [`TronTool::local_definition()`] for each tool, which may return a
    /// stripped-down schema with fewer parameters and shorter descriptions.
    pub fn local_definitions(&self, allowed: &[&str]) -> Vec<Tool> {
        self.tools
            .values()
            .filter(|t| allowed.contains(&t.name()))
            .map(|t| t.local_definition())
            .collect()
    }

    /// Return condensed tool schemas for local models using profile-resolved
    /// tool names.
    pub fn local_definitions_for_names(&self, allowed: &[String]) -> Vec<Tool> {
        self.tools
            .values()
            .filter(|t| allowed.iter().any(|name| name == t.name()))
            .map(|t| t.local_definition())
            .collect()
    }

    /// Return all tool names in registration order.
    pub fn names(&self) -> Vec<String> {
        self.tools.keys().cloned().collect()
    }

    /// Number of registered tools.
    pub fn len(&self) -> usize {
        self.tools.len()
    }

    /// Whether the registry is empty.
    pub fn is_empty(&self) -> bool {
        self.tools.is_empty()
    }

    /// Remove a tool by name, returning it if it existed.
    pub fn remove(&mut self, name: &str) -> Option<Arc<dyn TronTool>> {
        let removed = self.tools.swap_remove(name);
        if removed.is_some() {
            self.cached_definitions = OnceLock::new();
        }
        removed
    }

    /// Whether a tool with the given name is registered.
    pub fn contains(&self, name: &str) -> bool {
        self.tools.contains_key(name)
    }

    /// Return names of all tools where `stops_turn()` is true.
    ///
    /// Used by the stream processor to detect interactive tools during streaming
    /// and enter drain mode (stop accumulating content but keep reading for token usage).
    pub fn turn_stopping_tool_names(&self) -> HashSet<String> {
        self.tools
            .iter()
            .filter(|(_, t)| t.stops_turn())
            .map(|(name, _)| name.clone())
            .collect()
    }

    /// Register multiple tools at once (e.g., from MCP server discovery).
    pub fn register_many(&mut self, tools: Vec<Arc<dyn TronTool>>) {
        for tool in tools {
            self.register(tool);
        }
    }
}

impl Default for ToolRegistry {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use crate::core::tools::{ToolCategory, TronToolResult};
    use async_trait::async_trait;
    use serde_json::Value;

    use super::*;
    use crate::tools::errors::ToolError;
    use crate::tools::traits::ToolContext;
    use crate::tools::utils::schema::ToolSchemaBuilder;

    /// Minimal stub tool for registry tests.
    struct StubTool {
        tool_name: String,
    }

    impl StubTool {
        fn new(name: &str) -> Self {
            Self {
                tool_name: name.into(),
            }
        }
    }

    #[async_trait]
    impl TronTool for StubTool {
        fn name(&self) -> &str {
            &self.tool_name
        }

        fn category(&self) -> ToolCategory {
            ToolCategory::Custom
        }

        fn definition(&self) -> Tool {
            ToolSchemaBuilder::new(self.tool_name.clone(), format!("Stub {}", self.tool_name))
                .build()
        }

        async fn execute(
            &self,
            _params: Value,
            _ctx: &ToolContext,
        ) -> Result<TronToolResult, ToolError> {
            Ok(crate::core::tools::text_result("ok", false))
        }
    }

    /// Stub tool that stops the turn (like AskUserQuestion).
    struct StoppingStubTool {
        tool_name: String,
    }

    impl StoppingStubTool {
        fn new(name: &str) -> Self {
            Self {
                tool_name: name.into(),
            }
        }
    }

    #[async_trait]
    impl TronTool for StoppingStubTool {
        fn name(&self) -> &str {
            &self.tool_name
        }

        fn category(&self) -> ToolCategory {
            ToolCategory::Custom
        }

        fn stops_turn(&self) -> bool {
            true
        }

        fn definition(&self) -> Tool {
            ToolSchemaBuilder::new(
                self.tool_name.clone(),
                format!("Stopping {}", self.tool_name),
            )
            .build()
        }

        async fn execute(
            &self,
            _params: Value,
            _ctx: &ToolContext,
        ) -> Result<TronToolResult, ToolError> {
            Ok(crate::core::tools::text_result("ok", false))
        }
    }

    #[test]
    fn new_creates_empty_registry() {
        let reg = ToolRegistry::new();
        assert!(reg.is_empty());
        assert_eq!(reg.len(), 0);
    }

    #[test]
    fn register_and_get() {
        let mut reg = ToolRegistry::new();
        reg.register(Arc::new(StubTool::new("Read")));
        let tool = reg.get("Read");
        assert!(tool.is_some());
        assert_eq!(tool.unwrap().name(), "Read");
    }

    #[test]
    fn get_unknown_returns_none() {
        let reg = ToolRegistry::new();
        assert!(reg.get("NonExistent").is_none());
    }

    #[test]
    fn register_duplicate_overwrites() {
        let mut reg = ToolRegistry::new();
        reg.register(Arc::new(StubTool::new("Read")));
        reg.register(Arc::new(StubTool::new("Read")));
        assert_eq!(reg.len(), 1);
    }

    #[test]
    fn list_returns_all_tools() {
        let mut reg = ToolRegistry::new();
        reg.register(Arc::new(StubTool::new("Read")));
        reg.register(Arc::new(StubTool::new("Write")));
        let tools = reg.list();
        assert_eq!(tools.len(), 2);
    }

    #[test]
    fn definitions_returns_schemas() {
        let mut reg = ToolRegistry::new();
        reg.register(Arc::new(StubTool::new("Read")));
        reg.register(Arc::new(StubTool::new("Write")));
        let defs = reg.definitions();
        assert_eq!(defs.len(), 2);
        let names: Vec<&str> = defs.iter().map(|d| d.name.as_str()).collect();
        assert!(names.contains(&"Read"));
        assert!(names.contains(&"Write"));
    }

    #[test]
    fn names_returns_insertion_order() {
        let mut reg = ToolRegistry::new();
        reg.register(Arc::new(StubTool::new("Write")));
        reg.register(Arc::new(StubTool::new("Bash")));
        reg.register(Arc::new(StubTool::new("Read")));
        assert_eq!(reg.names(), vec!["Write", "Bash", "Read"]);
    }

    #[test]
    fn len_reflects_count() {
        let mut reg = ToolRegistry::new();
        assert_eq!(reg.len(), 0);
        reg.register(Arc::new(StubTool::new("Read")));
        assert_eq!(reg.len(), 1);
        reg.register(Arc::new(StubTool::new("Write")));
        assert_eq!(reg.len(), 2);
    }

    #[test]
    fn is_empty_on_empty_and_non_empty() {
        let mut reg = ToolRegistry::new();
        assert!(reg.is_empty());
        reg.register(Arc::new(StubTool::new("Read")));
        assert!(!reg.is_empty());
    }

    #[test]
    fn remove_existing_returns_some() {
        let mut reg = ToolRegistry::new();
        reg.register(Arc::new(StubTool::new("Read")));
        let removed = reg.remove("Read");
        assert!(removed.is_some());
        assert_eq!(removed.unwrap().name(), "Read");
        assert!(reg.is_empty());
    }

    #[test]
    fn remove_unknown_returns_none() {
        let mut reg = ToolRegistry::new();
        assert!(reg.remove("NonExistent").is_none());
    }

    #[test]
    fn contains_true_and_false() {
        let mut reg = ToolRegistry::new();
        reg.register(Arc::new(StubTool::new("Read")));
        assert!(reg.contains("Read"));
        assert!(!reg.contains("Write"));
    }

    #[test]
    fn definitions_cached_across_calls() {
        let mut reg = ToolRegistry::new();
        reg.register(Arc::new(StubTool::new("Read")));
        reg.register(Arc::new(StubTool::new("Write")));
        let defs1 = reg.definitions();
        let defs2 = reg.definitions();
        assert_eq!(defs1.len(), defs2.len());
        assert_eq!(defs1[0].name, defs2[0].name);
        assert_eq!(defs1[1].name, defs2[1].name);
    }

    #[test]
    fn register_invalidates_definition_cache() {
        let mut reg = ToolRegistry::new();
        reg.register(Arc::new(StubTool::new("Read")));
        let defs1 = reg.definitions();
        assert_eq!(defs1.len(), 1);

        reg.register(Arc::new(StubTool::new("Write")));
        let defs2 = reg.definitions();
        assert_eq!(defs2.len(), 2);
        let names: Vec<&str> = defs2.iter().map(|d| d.name.as_str()).collect();
        assert!(names.contains(&"Read"));
        assert!(names.contains(&"Write"));
    }

    #[test]
    fn register_many_adds_all() {
        let mut reg = ToolRegistry::new();
        let tools: Vec<Arc<dyn TronTool>> = vec![
            Arc::new(StubTool::new("A")),
            Arc::new(StubTool::new("B")),
            Arc::new(StubTool::new("C")),
        ];
        reg.register_many(tools);
        assert_eq!(reg.len(), 3);
        assert!(reg.contains("A"));
        assert!(reg.contains("B"));
        assert!(reg.contains("C"));
    }

    #[test]
    fn remove_invalidates_definition_cache() {
        let mut reg = ToolRegistry::new();
        reg.register(Arc::new(StubTool::new("Read")));
        reg.register(Arc::new(StubTool::new("Write")));
        let defs1 = reg.definitions();
        assert_eq!(defs1.len(), 2);

        let _ = reg.remove("Write");
        let defs2 = reg.definitions();
        assert_eq!(defs2.len(), 1);
        assert_eq!(defs2[0].name, "Read");
    }

    #[test]
    fn turn_stopping_tool_names_returns_correct_set() {
        let mut reg = ToolRegistry::new();
        reg.register(Arc::new(StubTool::new("Read")));
        reg.register(Arc::new(StubTool::new("Bash")));
        reg.register(Arc::new(StoppingStubTool::new("AskUserQuestion")));
        reg.register(Arc::new(StoppingStubTool::new("GetConfirmation")));
        reg.register(Arc::new(StubTool::new("Write")));

        let stopping = reg.turn_stopping_tool_names();
        assert_eq!(stopping.len(), 2);
        assert!(stopping.contains("AskUserQuestion"));
        assert!(stopping.contains("GetConfirmation"));
        assert!(!stopping.contains("Read"));
    }

    #[test]
    fn turn_stopping_tool_names_empty_when_none_stop() {
        let mut reg = ToolRegistry::new();
        reg.register(Arc::new(StubTool::new("Read")));
        reg.register(Arc::new(StubTool::new("Write")));

        let stopping = reg.turn_stopping_tool_names();
        assert!(stopping.is_empty());
    }

    #[test]
    fn local_definitions_filters_by_allowed() {
        let mut reg = ToolRegistry::new();
        reg.register(Arc::new(StubTool::new("Read")));
        reg.register(Arc::new(StubTool::new("Write")));
        reg.register(Arc::new(StubTool::new("AskUserQuestion")));
        reg.register(Arc::new(StubTool::new("SpawnSubagent")));

        let defs = reg.local_definitions(&["Read", "Write"]);
        assert_eq!(defs.len(), 2);
        let names: Vec<&str> = defs.iter().map(|d| d.name.as_str()).collect();
        assert!(names.contains(&"Read"));
        assert!(names.contains(&"Write"));
        assert!(!names.contains(&"AskUserQuestion"));
    }

    #[test]
    fn local_definitions_empty_when_no_match() {
        let mut reg = ToolRegistry::new();
        reg.register(Arc::new(StubTool::new("Read")));
        let defs = reg.local_definitions(&["NonExistent"]);
        assert!(defs.is_empty());
    }
}
