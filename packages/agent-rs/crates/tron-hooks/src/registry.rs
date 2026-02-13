//! Hook registry.
//!
//! Maintains a priority-sorted collection of [`HookHandler`] instances per
//! [`HookType`]. The registry is the source of truth for which hooks are
//! active and what order they run in.

use std::collections::HashMap;
use std::sync::Arc;

use tracing::debug;

use crate::handler::HookHandler;
use crate::types::{HookInfo, HookType};

/// Registry of lifecycle hook handlers.
///
/// Handlers are organized by [`HookType`] and sorted by priority (descending)
/// within each type. Higher priority handlers run first.
#[derive(Default)]
pub struct HookRegistry {
    /// Handlers keyed by hook type, sorted by priority descending.
    hooks: HashMap<HookType, Vec<Arc<dyn HookHandler>>>,
}

impl HookRegistry {
    /// Create a new empty registry.
    #[must_use]
    pub fn new() -> Self {
        Self {
            hooks: HashMap::new(),
        }
    }

    /// Register a hook handler.
    ///
    /// The handler is inserted into the correct type bucket and the bucket
    /// is re-sorted by priority (descending). If a handler with the same
    /// name already exists for the same type, it is replaced.
    pub fn register(&mut self, handler: Arc<dyn HookHandler>) {
        let hook_type = handler.hook_type();
        let name = handler.name().to_string();

        let handlers = self.hooks.entry(hook_type).or_default();

        // Remove existing handler with same name
        handlers.retain(|h| h.name() != name);

        debug!(name = %name, hook_type = %hook_type, priority = handler.priority(), "Registering hook");
        handlers.push(handler);

        // Sort by priority descending (higher priority first)
        handlers.sort_by_key(|h| std::cmp::Reverse(h.priority()));
    }

    /// Unregister a handler by name.
    ///
    /// Searches all hook types. Returns `true` if a handler was found and
    /// removed, `false` otherwise.
    pub fn unregister(&mut self, name: &str) -> bool {
        let mut found = false;
        for handlers in self.hooks.values_mut() {
            let before_len = handlers.len();
            handlers.retain(|h| h.name() != name);
            if handlers.len() < before_len {
                found = true;
            }
        }
        if found {
            debug!(name = %name, "Unregistered hook");
        }
        found
    }

    /// Get handlers for a specific hook type, sorted by priority (descending).
    #[must_use]
    pub fn get_handlers(&self, hook_type: HookType) -> Vec<Arc<dyn HookHandler>> {
        self.hooks.get(&hook_type).cloned().unwrap_or_default()
    }

    /// List information about all registered hooks.
    #[must_use]
    pub fn list_all(&self) -> Vec<HookInfo> {
        let mut infos = Vec::new();
        for handlers in self.hooks.values() {
            for handler in handlers {
                infos.push(HookInfo {
                    name: handler.name().to_string(),
                    hook_type: handler.hook_type(),
                    priority: handler.priority(),
                    execution_mode: handler.execution_mode(),
                    description: handler.description().map(ToString::to_string),
                    timeout_ms: handler.timeout_ms(),
                });
            }
        }
        infos.sort_by(|a, b| a.name.cmp(&b.name));
        infos
    }

    /// Get a handler by name.
    #[must_use]
    pub fn get_by_name(&self, name: &str) -> Option<Arc<dyn HookHandler>> {
        for handlers in self.hooks.values() {
            for handler in handlers {
                if handler.name() == name {
                    return Some(Arc::clone(handler));
                }
            }
        }
        None
    }

    /// Get the total number of registered handlers.
    #[must_use]
    pub fn count(&self) -> usize {
        self.hooks.values().map(Vec::len).sum()
    }

    /// Clear all registered handlers.
    pub fn clear(&mut self) {
        self.hooks.clear();
    }
}

impl std::fmt::Debug for HookRegistry {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("HookRegistry")
            .field("hook_count", &self.count())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{HookContext, HookExecutionMode, HookResult};
    use async_trait::async_trait;

    struct TestHandler {
        name: String,
        hook_type: HookType,
        priority: i32,
        mode: HookExecutionMode,
    }

    #[async_trait]
    impl HookHandler for TestHandler {
        fn name(&self) -> &str {
            &self.name
        }
        fn hook_type(&self) -> HookType {
            self.hook_type
        }
        fn priority(&self) -> i32 {
            self.priority
        }
        fn execution_mode(&self) -> HookExecutionMode {
            self.mode
        }
        async fn handle(
            &self,
            _context: &HookContext,
        ) -> Result<HookResult, crate::errors::HookError> {
            Ok(HookResult::continue_())
        }
    }

    fn make_handler(name: &str, hook_type: HookType, priority: i32) -> Arc<dyn HookHandler> {
        Arc::new(TestHandler {
            name: name.to_string(),
            hook_type,
            priority,
            mode: HookExecutionMode::Blocking,
        })
    }

    #[test]
    fn test_new_registry_is_empty() {
        let registry = HookRegistry::new();
        assert_eq!(registry.count(), 0);
    }

    #[test]
    fn test_register_single() {
        let mut registry = HookRegistry::new();
        registry.register(make_handler("hook1", HookType::PreToolUse, 0));
        assert_eq!(registry.count(), 1);
    }

    #[test]
    fn test_register_multiple_same_type() {
        let mut registry = HookRegistry::new();
        registry.register(make_handler("a", HookType::PreToolUse, 10));
        registry.register(make_handler("b", HookType::PreToolUse, 20));
        assert_eq!(registry.count(), 2);
        let handlers = registry.get_handlers(HookType::PreToolUse);
        assert_eq!(handlers.len(), 2);
    }

    #[test]
    fn test_register_different_types() {
        let mut registry = HookRegistry::new();
        registry.register(make_handler("a", HookType::PreToolUse, 0));
        registry.register(make_handler("b", HookType::PostToolUse, 0));
        assert_eq!(registry.count(), 2);
        assert_eq!(registry.get_handlers(HookType::PreToolUse).len(), 1);
        assert_eq!(registry.get_handlers(HookType::PostToolUse).len(), 1);
    }

    #[test]
    fn test_get_handlers_sorted_by_priority_descending() {
        let mut registry = HookRegistry::new();
        registry.register(make_handler("low", HookType::PreToolUse, 10));
        registry.register(make_handler("high", HookType::PreToolUse, 100));
        registry.register(make_handler("mid", HookType::PreToolUse, 50));

        let handlers = registry.get_handlers(HookType::PreToolUse);
        assert_eq!(handlers[0].name(), "high");
        assert_eq!(handlers[1].name(), "mid");
        assert_eq!(handlers[2].name(), "low");
    }

    #[test]
    fn test_get_handlers_empty_type() {
        let registry = HookRegistry::new();
        assert!(registry.get_handlers(HookType::Stop).is_empty());
    }

    #[test]
    fn test_register_replaces_duplicate_name() {
        let mut registry = HookRegistry::new();
        registry.register(make_handler("hook1", HookType::PreToolUse, 10));
        registry.register(make_handler("hook1", HookType::PreToolUse, 50));
        assert_eq!(registry.count(), 1);
        let handlers = registry.get_handlers(HookType::PreToolUse);
        assert_eq!(handlers[0].priority(), 50);
    }

    #[test]
    fn test_unregister_existing() {
        let mut registry = HookRegistry::new();
        registry.register(make_handler("hook1", HookType::PreToolUse, 0));
        assert!(registry.unregister("hook1"));
        assert_eq!(registry.count(), 0);
    }

    #[test]
    fn test_unregister_nonexistent() {
        let mut registry = HookRegistry::new();
        assert!(!registry.unregister("nonexistent"));
    }

    #[test]
    fn test_unregister_only_removes_named() {
        let mut registry = HookRegistry::new();
        registry.register(make_handler("a", HookType::PreToolUse, 0));
        registry.register(make_handler("b", HookType::PreToolUse, 0));
        let _ = registry.unregister("a");
        assert_eq!(registry.count(), 1);
        assert!(registry.get_by_name("b").is_some());
    }

    #[test]
    fn test_list_all() {
        let mut registry = HookRegistry::new();
        registry.register(make_handler("z-hook", HookType::Stop, 0));
        registry.register(make_handler("a-hook", HookType::PreToolUse, 100));
        let list = registry.list_all();
        assert_eq!(list.len(), 2);
        // Sorted by name
        assert_eq!(list[0].name, "a-hook");
        assert_eq!(list[1].name, "z-hook");
    }

    #[test]
    fn test_get_by_name_found() {
        let mut registry = HookRegistry::new();
        registry.register(make_handler("hook1", HookType::PreToolUse, 0));
        let handler = registry.get_by_name("hook1");
        assert!(handler.is_some());
        assert_eq!(handler.unwrap().name(), "hook1");
    }

    #[test]
    fn test_get_by_name_not_found() {
        let registry = HookRegistry::new();
        assert!(registry.get_by_name("nope").is_none());
    }

    #[test]
    fn test_clear() {
        let mut registry = HookRegistry::new();
        registry.register(make_handler("a", HookType::PreToolUse, 0));
        registry.register(make_handler("b", HookType::PostToolUse, 0));
        registry.clear();
        assert_eq!(registry.count(), 0);
    }

    #[test]
    fn test_debug_impl() {
        let registry = HookRegistry::new();
        let debug = format!("{registry:?}");
        assert!(debug.contains("HookRegistry"));
        assert!(debug.contains("hook_count"));
    }
}
