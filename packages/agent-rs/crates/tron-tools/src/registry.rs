//! Tool registry — central index of all registered tools.
//!
//! The [`ToolRegistry`] maps tool names to their [`TronTool`] implementations.
//! The runtime registers tools at startup and queries the registry to dispatch
//! tool calls and to generate the LLM tool schema.

use std::collections::HashMap;
use std::sync::Arc;

use tron_core::tools::Tool;
use tracing::debug;

use crate::traits::TronTool;

/// Central registry mapping tool names to their implementations.
pub struct ToolRegistry {
    tools: HashMap<String, Arc<dyn TronTool>>,
}

impl ToolRegistry {
    /// Create an empty registry.
    pub fn new() -> Self {
        Self {
            tools: HashMap::new(),
        }
    }

    /// Register a tool. Overwrites any existing tool with the same name.
    pub fn register(&mut self, tool: Arc<dyn TronTool>) {
        debug!(tool_name = tool.name(), "tool registered");
        let _ = self.tools.insert(tool.name().to_owned(), tool);
    }

    /// Look up a tool by name.
    pub fn get(&self, name: &str) -> Option<Arc<dyn TronTool>> {
        self.tools.get(name).cloned()
    }

    /// Return all registered tools (arbitrary order).
    pub fn list(&self) -> Vec<Arc<dyn TronTool>> {
        self.tools.values().cloned().collect()
    }

    /// Return all tool schemas for the LLM.
    pub fn definitions(&self) -> Vec<Tool> {
        self.tools.values().map(|t| t.definition()).collect()
    }

    /// Return all tool names, sorted alphabetically.
    pub fn names(&self) -> Vec<String> {
        let mut names: Vec<String> = self.tools.keys().cloned().collect();
        names.sort();
        names
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
        self.tools.remove(name)
    }

    /// Whether a tool with the given name is registered.
    pub fn contains(&self, name: &str) -> bool {
        self.tools.contains_key(name)
    }
}

impl Default for ToolRegistry {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use async_trait::async_trait;
    use serde_json::Value;
    use tron_core::tools::{ToolCategory, ToolParameterSchema, TronToolResult};

    use super::*;
    use crate::errors::ToolError;
    use crate::traits::ToolContext;

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
            Tool {
                name: self.tool_name.clone(),
                description: format!("Stub {}", self.tool_name),
                parameters: ToolParameterSchema {
                    schema_type: "object".into(),
                    properties: None,
                    required: None,
                    description: None,
                    extra: serde_json::Map::new(),
                },
            }
        }

        async fn execute(
            &self,
            _params: Value,
            _ctx: &ToolContext,
        ) -> Result<TronToolResult, ToolError> {
            Ok(tron_core::tools::text_result("ok", false))
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
    fn names_returns_sorted() {
        let mut reg = ToolRegistry::new();
        reg.register(Arc::new(StubTool::new("Write")));
        reg.register(Arc::new(StubTool::new("Bash")));
        reg.register(Arc::new(StubTool::new("Read")));
        assert_eq!(reg.names(), vec!["Bash", "Read", "Write"]);
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
}
