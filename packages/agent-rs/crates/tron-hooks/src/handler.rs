//! Hook handler trait.
//!
//! Defines the [`HookHandler`] trait that all hook implementations must satisfy.
//! Handlers are registered with the [`HookRegistry`](crate::registry::HookRegistry)
//! and executed by the [`HookEngine`](crate::engine::HookEngine).

use async_trait::async_trait;

use crate::errors::HookError;
use crate::types::{HookContext, HookExecutionMode, HookResult, HookType};

/// A lifecycle hook handler.
///
/// Implementations are registered in the hook registry and executed at the
/// appropriate lifecycle point. Handlers can inspect the context and return
/// a [`HookResult`] indicating whether to continue, block, or modify the
/// operation.
///
/// # Priority
///
/// Higher priority handlers run first. Default priority is 0.
///
/// # Execution Mode
///
/// Handlers declare whether they should run in blocking or background mode.
/// Note that forced-blocking hook types (`PreToolUse`, `UserPromptSubmit`,
/// `PreCompact`) always run in blocking mode regardless of the declared mode.
///
/// # Filtering
///
/// Override [`should_handle`](HookHandler::should_handle) to conditionally
/// skip the handler for specific contexts.
#[async_trait]
pub trait HookHandler: Send + Sync {
    /// Unique name for this handler.
    fn name(&self) -> &str;

    /// Which lifecycle event this handler responds to.
    fn hook_type(&self) -> HookType;

    /// Execution priority. Higher runs first. Default: 0.
    fn priority(&self) -> i32 {
        0
    }

    /// Preferred execution mode. Default: Blocking.
    ///
    /// Note: forced-blocking hook types always run in blocking mode
    /// regardless of this setting.
    fn execution_mode(&self) -> HookExecutionMode {
        HookExecutionMode::Blocking
    }

    /// Optional human-readable description.
    fn description(&self) -> Option<&str> {
        None
    }

    /// Optional timeout in milliseconds.
    fn timeout_ms(&self) -> Option<u64> {
        None
    }

    /// Execute the handler with the given context.
    ///
    /// Errors are caught by the engine and treated as `Continue` (fail-open).
    async fn handle(&self, context: &HookContext) -> Result<HookResult, HookError>;

    /// Optional filter. Return `false` to skip this handler for the context.
    ///
    /// Default returns `true` (always handle).
    fn should_handle(&self, _context: &HookContext) -> bool {
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TestHandler {
        name: String,
        hook_type: HookType,
        priority: i32,
        mode: HookExecutionMode,
        result: HookResult,
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
        async fn handle(&self, _context: &HookContext) -> Result<HookResult, HookError> {
            Ok(self.result.clone())
        }
    }

    fn make_handler(name: &str, hook_type: HookType) -> TestHandler {
        TestHandler {
            name: name.to_string(),
            hook_type,
            priority: 0,
            mode: HookExecutionMode::Blocking,
            result: HookResult::continue_(),
        }
    }

    fn make_context() -> HookContext {
        HookContext::PreToolUse {
            session_id: "s1".to_string(),
            timestamp: "2026-01-01T00:00:00Z".to_string(),
            tool_name: "Bash".to_string(),
            tool_arguments: serde_json::json!({}),
            tool_call_id: "tc1".to_string(),
        }
    }

    #[tokio::test]
    async fn test_handler_default_priority() {
        let handler = make_handler("test", HookType::PreToolUse);
        assert_eq!(handler.priority(), 0);
    }

    #[tokio::test]
    async fn test_handler_default_mode() {
        let handler = make_handler("test", HookType::PreToolUse);
        assert_eq!(handler.execution_mode(), HookExecutionMode::Blocking);
    }

    #[tokio::test]
    async fn test_handler_default_should_handle() {
        let handler = make_handler("test", HookType::PreToolUse);
        let ctx = make_context();
        assert!(handler.should_handle(&ctx));
    }

    #[tokio::test]
    async fn test_handler_default_description() {
        let handler = make_handler("test", HookType::PreToolUse);
        assert!(handler.description().is_none());
    }

    #[tokio::test]
    async fn test_handler_default_timeout() {
        let handler = make_handler("test", HookType::PreToolUse);
        assert!(handler.timeout_ms().is_none());
    }

    #[tokio::test]
    async fn test_handler_returns_result() {
        let handler = TestHandler {
            name: "blocker".to_string(),
            hook_type: HookType::PreToolUse,
            priority: 100,
            mode: HookExecutionMode::Blocking,
            result: HookResult::block("unsafe"),
        };
        let ctx = make_context();
        let result = handler.handle(&ctx).await.unwrap();
        assert!(result.is_blocked());
        assert_eq!(result.reason.as_deref(), Some("unsafe"));
    }
}
