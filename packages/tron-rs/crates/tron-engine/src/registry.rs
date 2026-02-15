use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use tron_core::tools::{Tool, ToolDefinition};

/// Source of a registered tool.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ToolSource {
    BuiltIn,
    Skill(String),
    Mcp(String),
}

struct ToolEntry {
    tool: Arc<dyn Tool>,
    source: ToolSource,
}

/// Filter for selecting tools when creating subagent registries.
#[derive(Clone, Debug)]
pub enum ToolFilter {
    /// Same tools as parent.
    InheritAll,
    /// Parent tools minus these.
    InheritExcept(HashSet<String>),
    /// Only these tools.
    Explicit(HashSet<String>),
}

/// Registry of available tools.
pub struct ToolRegistry {
    tools: HashMap<String, ToolEntry>,
}

impl ToolRegistry {
    pub fn new() -> Self {
        Self {
            tools: HashMap::new(),
        }
    }

    /// Register a tool.
    pub fn register(&mut self, tool: Arc<dyn Tool>, source: ToolSource) {
        let name = tool.name().to_string();
        self.tools.insert(name, ToolEntry { tool, source });
    }

    /// Unregister a tool by name.
    pub fn unregister(&mut self, name: &str) -> bool {
        self.tools.remove(name).is_some()
    }

    /// Get a tool by name.
    pub fn get(&self, name: &str) -> Option<Arc<dyn Tool>> {
        self.tools.get(name).map(|e| Arc::clone(&e.tool))
    }

    /// Get the source of a tool.
    pub fn source(&self, name: &str) -> Option<&ToolSource> {
        self.tools.get(name).map(|e| &e.source)
    }

    /// Check if a tool is registered.
    pub fn contains(&self, name: &str) -> bool {
        self.tools.contains_key(name)
    }

    /// List all tool names.
    pub fn names(&self) -> Vec<String> {
        let mut names: Vec<String> = self.tools.keys().cloned().collect();
        names.sort();
        names
    }

    /// Get tool definitions for the LLM.
    pub fn definitions(&self) -> Vec<ToolDefinition> {
        let mut defs: Vec<ToolDefinition> = self
            .tools
            .values()
            .map(|e| e.tool.to_definition())
            .collect();
        defs.sort_by(|a, b| a.name.cmp(&b.name));
        defs
    }

    /// Total tool count.
    pub fn count(&self) -> usize {
        self.tools.len()
    }

    /// Create a filtered copy for a subagent.
    pub fn clone_for_subagent(&self, filter: &ToolFilter) -> Self {
        let mut new = Self::new();
        for (name, entry) in &self.tools {
            let include = match filter {
                ToolFilter::InheritAll => true,
                ToolFilter::InheritExcept(excluded) => !excluded.contains(name),
                ToolFilter::Explicit(included) => included.contains(name),
            };
            if include {
                new.tools.insert(
                    name.clone(),
                    ToolEntry {
                        tool: Arc::clone(&entry.tool),
                        source: entry.source.clone(),
                    },
                );
            }
        }
        new
    }
}

impl Default for ToolRegistry {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use async_trait::async_trait;
    use tron_core::tools::{ContentType, ExecutionMode, ToolContext, ToolError, ToolResult};

    struct DummyTool {
        name: String,
    }

    impl DummyTool {
        fn new(name: &str) -> Self {
            Self {
                name: name.to_string(),
            }
        }
    }

    #[async_trait]
    impl Tool for DummyTool {
        fn name(&self) -> &str {
            &self.name
        }
        fn description(&self) -> &str {
            "A dummy tool for testing"
        }
        fn parameters_schema(&self) -> serde_json::Value {
            serde_json::json!({"type": "object"})
        }
        fn execution_mode(&self) -> ExecutionMode {
            ExecutionMode::Concurrent
        }
        async fn execute(
            &self,
            _args: serde_json::Value,
            _ctx: &ToolContext,
        ) -> Result<ToolResult, ToolError> {
            Ok(ToolResult {
                content: "ok".into(),
                is_error: false,
                content_type: ContentType::Text,
                duration: std::time::Duration::from_millis(1),
            })
        }
    }

    #[test]
    fn register_and_get() {
        let mut registry = ToolRegistry::new();
        registry.register(Arc::new(DummyTool::new("Read")), ToolSource::BuiltIn);

        assert!(registry.contains("Read"));
        assert!(!registry.contains("Write"));
        assert_eq!(registry.count(), 1);
        assert!(registry.get("Read").is_some());
        assert_eq!(registry.source("Read"), Some(&ToolSource::BuiltIn));
    }

    #[test]
    fn unregister() {
        let mut registry = ToolRegistry::new();
        registry.register(Arc::new(DummyTool::new("Read")), ToolSource::BuiltIn);
        assert!(registry.unregister("Read"));
        assert!(!registry.contains("Read"));
        assert!(!registry.unregister("Read")); // second time returns false
    }

    #[test]
    fn names_sorted() {
        let mut registry = ToolRegistry::new();
        registry.register(Arc::new(DummyTool::new("Grep")), ToolSource::BuiltIn);
        registry.register(Arc::new(DummyTool::new("Bash")), ToolSource::BuiltIn);
        registry.register(Arc::new(DummyTool::new("Read")), ToolSource::BuiltIn);

        assert_eq!(registry.names(), vec!["Bash", "Grep", "Read"]);
    }

    #[test]
    fn definitions() {
        let mut registry = ToolRegistry::new();
        registry.register(Arc::new(DummyTool::new("Read")), ToolSource::BuiltIn);
        registry.register(Arc::new(DummyTool::new("Write")), ToolSource::BuiltIn);

        let defs = registry.definitions();
        assert_eq!(defs.len(), 2);
        assert_eq!(defs[0].name, "Read");
        assert_eq!(defs[1].name, "Write");
    }

    #[test]
    fn clone_for_subagent_inherit_all() {
        let mut registry = ToolRegistry::new();
        registry.register(Arc::new(DummyTool::new("Read")), ToolSource::BuiltIn);
        registry.register(Arc::new(DummyTool::new("Write")), ToolSource::BuiltIn);

        let sub = registry.clone_for_subagent(&ToolFilter::InheritAll);
        assert_eq!(sub.count(), 2);
    }

    #[test]
    fn clone_for_subagent_inherit_except() {
        let mut registry = ToolRegistry::new();
        registry.register(Arc::new(DummyTool::new("Read")), ToolSource::BuiltIn);
        registry.register(Arc::new(DummyTool::new("Write")), ToolSource::BuiltIn);
        registry.register(Arc::new(DummyTool::new("Bash")), ToolSource::BuiltIn);

        let filter = ToolFilter::InheritExcept(HashSet::from(["Bash".to_string()]));
        let sub = registry.clone_for_subagent(&filter);
        assert_eq!(sub.count(), 2);
        assert!(sub.contains("Read"));
        assert!(sub.contains("Write"));
        assert!(!sub.contains("Bash"));
    }

    #[test]
    fn clone_for_subagent_explicit() {
        let mut registry = ToolRegistry::new();
        registry.register(Arc::new(DummyTool::new("Read")), ToolSource::BuiltIn);
        registry.register(Arc::new(DummyTool::new("Write")), ToolSource::BuiltIn);
        registry.register(Arc::new(DummyTool::new("Bash")), ToolSource::BuiltIn);

        let filter = ToolFilter::Explicit(HashSet::from(["Read".to_string()]));
        let sub = registry.clone_for_subagent(&filter);
        assert_eq!(sub.count(), 1);
        assert!(sub.contains("Read"));
    }

    #[test]
    fn tool_sources() {
        let mut registry = ToolRegistry::new();
        registry.register(Arc::new(DummyTool::new("Read")), ToolSource::BuiltIn);
        registry.register(
            Arc::new(DummyTool::new("Custom")),
            ToolSource::Skill("my-skill".into()),
        );
        registry.register(
            Arc::new(DummyTool::new("Remote")),
            ToolSource::Mcp("server-1".into()),
        );

        assert_eq!(registry.source("Read"), Some(&ToolSource::BuiltIn));
        assert_eq!(
            registry.source("Custom"),
            Some(&ToolSource::Skill("my-skill".into()))
        );
        assert_eq!(
            registry.source("Remote"),
            Some(&ToolSource::Mcp("server-1".into()))
        );
    }
}
