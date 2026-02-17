//! Hook execution engine.
//!
//! Orchestrates hook execution with priority ordering, blocking/background
//! mode support, fail-open error handling, and background task tracking.
//!
//! # Execution Model
//!
//! Hooks are evaluated in priority order (highest first). For blocking hooks:
//! - A `Block` action stops the chain immediately.
//! - A `Modify` action collects modifications and continues.
//! - A `Continue` action continues to the next hook.
//!
//! Background hooks are fire-and-forget: spawned as tasks and tracked for
//! eventual draining.
//!
//! # Fail-Open
//!
//! Hook errors never crash the agent. They are logged and treated as `Continue`.

use std::sync::Arc;
use std::time::Instant;

use tracing::{debug, instrument, warn};

use super::background::BackgroundTracker;
use super::handler::HookHandler;
use super::registry::HookRegistry;
use super::types::{HookAction, HookContext, HookExecutionMode, HookResult, HookType};

/// Hook execution engine.
///
/// Owns the [`HookRegistry`] and [`BackgroundTracker`]. Provides the main
/// `execute()` method that runs all registered hooks for a given context.
pub struct HookEngine {
    registry: HookRegistry,
    background: BackgroundTracker,
}

impl HookEngine {
    /// Create a new engine with the given registry.
    #[must_use]
    pub fn new(registry: HookRegistry) -> Self {
        Self {
            registry,
            background: BackgroundTracker::new(),
        }
    }

    /// Execute all registered hooks for the given context.
    ///
    /// Blocking hooks run sequentially in priority order.
    /// Background hooks are spawned and tracked.
    ///
    /// Returns the aggregated result. If any blocking hook returns `Block`,
    /// execution stops and the block result is returned. Modifications from
    /// all `Modify` results are merged.
    #[instrument(skip_all, fields(hook_type = %context.hook_type()))]
    pub async fn execute(&self, context: &HookContext) -> HookResult {
        let hook_type = context.hook_type();
        let handlers = self.registry.get_handlers(hook_type);

        if handlers.is_empty() {
            return HookResult::continue_();
        }

        let start = Instant::now();

        // Separate blocking and background handlers
        let (blocking, background): (Vec<_>, Vec<_>) = handlers
            .into_iter()
            .partition(|h| Self::effective_mode(h, hook_type) == HookExecutionMode::Blocking);

        // Execute blocking hooks sequentially
        let result = self.execute_blocking(&blocking, context).await;

        // Spawn background hooks
        if !background.is_empty() {
            self.spawn_background(background, context);
        }

        let duration_ms = start.elapsed().as_millis();
        debug!(
            hook_type = %hook_type,
            duration_ms = duration_ms,
            blocked = result.is_blocked(),
            "Hook execution complete"
        );

        result
    }

    /// Execute blocking hooks sequentially.
    async fn execute_blocking(
        &self,
        handlers: &[Arc<dyn HookHandler>],
        context: &HookContext,
    ) -> HookResult {
        let mut merged_modifications: Option<serde_json::Value> = None;
        let mut messages: Vec<String> = Vec::new();

        for handler in handlers {
            // Check filter
            if !handler.should_handle(context) {
                debug!(name = %handler.name(), "Hook skipped by filter");
                continue;
            }

            // Execute with optional timeout
            let result = self
                .execute_single_handler(handler.as_ref(), context)
                .await;

            match result.action {
                HookAction::Block => {
                    debug!(
                        name = %handler.name(),
                        reason = result.reason.as_deref().unwrap_or("(none)"),
                        "Hook blocked execution"
                    );
                    return result;
                }
                HookAction::Modify => {
                    if let Some(mods) = &result.modifications {
                        merged_modifications = Some(merge_json(
                            merged_modifications.as_ref(),
                            mods,
                        ));
                    }
                    if let Some(msg) = &result.message {
                        messages.push(msg.clone());
                    }
                }
                HookAction::Continue => {
                    if let Some(msg) = &result.message {
                        messages.push(msg.clone());
                    }
                }
            }
        }

        // Build aggregated result
        if merged_modifications.is_some() || !messages.is_empty() {
            HookResult {
                action: if merged_modifications.is_some() {
                    HookAction::Modify
                } else {
                    HookAction::Continue
                },
                reason: None,
                message: if messages.is_empty() {
                    None
                } else {
                    Some(messages.join("\n"))
                },
                modifications: merged_modifications,
            }
        } else {
            HookResult::continue_()
        }
    }

    /// Execute a single handler, applying timeout and fail-open.
    async fn execute_single_handler(
        &self,
        handler: &dyn HookHandler,
        context: &HookContext,
    ) -> HookResult {
        let timeout_ms = handler.timeout_ms().unwrap_or(30_000);

        let result = tokio::time::timeout(
            std::time::Duration::from_millis(timeout_ms),
            handler.handle(context),
        )
        .await;

        match result {
            Ok(Ok(hook_result)) => hook_result,
            Ok(Err(e)) => {
                warn!(
                    name = %handler.name(),
                    error = %e,
                    "Hook handler error (fail-open)"
                );
                HookResult::continue_()
            }
            Err(_) => {
                warn!(
                    name = %handler.name(),
                    timeout_ms = timeout_ms,
                    "Hook handler timed out (fail-open)"
                );
                HookResult::continue_()
            }
        }
    }

    /// Spawn background hooks as tracked tasks.
    fn spawn_background(
        &self,
        handlers: Vec<Arc<dyn HookHandler>>,
        context: &HookContext,
    ) {
        for handler in handlers {
            if !handler.should_handle(context) {
                continue;
            }

            let ctx = context.clone();
            let name = handler.name().to_string();

            self.background.spawn(async move {
                match handler.handle(&ctx).await {
                    Ok(result) => {
                        debug!(name = %name, action = ?result.action, "Background hook completed");
                    }
                    Err(e) => {
                        warn!(name = %name, error = %e, "Background hook error");
                    }
                }
            });
        }
    }

    /// Determine the effective execution mode for a handler.
    ///
    /// Forced-blocking hook types always run in blocking mode regardless
    /// of the handler's declared mode.
    fn effective_mode(handler: &Arc<dyn HookHandler>, hook_type: HookType) -> HookExecutionMode {
        if hook_type.is_forced_blocking() {
            HookExecutionMode::Blocking
        } else {
            handler.execution_mode()
        }
    }

    /// Wait for all pending background hooks to complete.
    pub async fn wait_for_background(&self) {
        self.background.drain_all().await;
    }

    /// Wait for background hooks with a timeout.
    ///
    /// Returns `true` if all completed within the timeout.
    pub async fn wait_for_background_with_timeout(
        &self,
        timeout: std::time::Duration,
    ) -> bool {
        self.background.drain_with_timeout(timeout).await
    }

    /// Get the number of pending background hooks.
    #[must_use]
    pub fn pending_background_count(&self) -> usize {
        self.background.pending_count()
    }

    /// Get a reference to the hook registry.
    #[must_use]
    pub fn registry(&self) -> &HookRegistry {
        &self.registry
    }

    /// Get a mutable reference to the hook registry.
    pub fn registry_mut(&mut self) -> &mut HookRegistry {
        &mut self.registry
    }
}

impl std::fmt::Debug for HookEngine {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("HookEngine")
            .field("registry", &self.registry)
            .field("background", &self.background)
            .finish()
    }
}

/// Shallow-merge two JSON objects. `b` fields override `a` fields.
fn merge_json(
    a: Option<&serde_json::Value>,
    b: &serde_json::Value,
) -> serde_json::Value {
    match (a, b) {
        (Some(serde_json::Value::Object(base)), serde_json::Value::Object(overlay)) => {
            let mut merged = base.clone();
            for (key, value) in overlay {
                let _ = merged.insert(key.clone(), value.clone());
            }
            serde_json::Value::Object(merged)
        }
        _ => b.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hooks::errors::HookError;
    use async_trait::async_trait;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use tokio::time::Duration;

    // --- Test handler helpers ---

    struct SimpleHandler {
        name: String,
        hook_type: HookType,
        priority: i32,
        mode: HookExecutionMode,
        result: HookResult,
        should_handle: bool,
    }

    #[async_trait]
    impl HookHandler for SimpleHandler {
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
        async fn handle(&self, _ctx: &HookContext) -> Result<HookResult, HookError> {
            Ok(self.result.clone())
        }
        fn should_handle(&self, _ctx: &HookContext) -> bool {
            self.should_handle
        }
    }

    struct ErrorHandler {
        name: String,
        hook_type: HookType,
    }

    #[async_trait]
    impl HookHandler for ErrorHandler {
        fn name(&self) -> &str {
            &self.name
        }
        fn hook_type(&self) -> HookType {
            self.hook_type
        }
        async fn handle(&self, _ctx: &HookContext) -> Result<HookResult, HookError> {
            Err(HookError::HandlerError {
                name: self.name.clone(),
                message: "intentional failure".to_string(),
            })
        }
    }

    struct SlowHandler {
        name: String,
        hook_type: HookType,
        delay_ms: u64,
    }

    #[async_trait]
    impl HookHandler for SlowHandler {
        fn name(&self) -> &str {
            &self.name
        }
        fn hook_type(&self) -> HookType {
            self.hook_type
        }
        fn timeout_ms(&self) -> Option<u64> {
            Some(50)
        }
        async fn handle(&self, _ctx: &HookContext) -> Result<HookResult, HookError> {
            tokio::time::sleep(Duration::from_millis(self.delay_ms)).await;
            Ok(HookResult::block("should not reach"))
        }
    }

    struct TrackingHandler {
        name: String,
        hook_type: HookType,
        mode: HookExecutionMode,
        called: Arc<AtomicBool>,
    }

    #[async_trait]
    impl HookHandler for TrackingHandler {
        fn name(&self) -> &str {
            &self.name
        }
        fn hook_type(&self) -> HookType {
            self.hook_type
        }
        fn execution_mode(&self) -> HookExecutionMode {
            self.mode
        }
        async fn handle(&self, _ctx: &HookContext) -> Result<HookResult, HookError> {
            self.called.store(true, Ordering::SeqCst);
            Ok(HookResult::continue_())
        }
    }

    fn make_ctx(hook_type: HookType) -> HookContext {
        match hook_type {
            HookType::PreToolUse => HookContext::PreToolUse {
                session_id: "s1".to_string(),
                timestamp: "t".to_string(),
                tool_name: "Bash".to_string(),
                tool_arguments: serde_json::json!({}),
                tool_call_id: "tc1".to_string(),
            },
            HookType::PostToolUse => HookContext::PostToolUse {
                session_id: "s1".to_string(),
                timestamp: "t".to_string(),
                tool_name: "Bash".to_string(),
                tool_call_id: "tc1".to_string(),
                result: serde_json::json!({}),
                duration_ms: 100,
            },
            HookType::Stop => HookContext::Stop {
                session_id: "s1".to_string(),
                timestamp: "t".to_string(),
                stop_reason: "end_turn".to_string(),
                final_message: None,
            },
            _ => HookContext::SessionStart {
                session_id: "s1".to_string(),
                timestamp: "t".to_string(),
                working_directory: "/tmp".to_string(),
                parent_handoff_id: None,
            },
        }
    }

    fn make_simple(
        name: &str,
        hook_type: HookType,
        priority: i32,
        result: HookResult,
    ) -> Arc<dyn HookHandler> {
        Arc::new(SimpleHandler {
            name: name.to_string(),
            hook_type,
            priority,
            mode: HookExecutionMode::Blocking,
            result,
            should_handle: true,
        })
    }

    // --- Tests ---

    #[tokio::test]
    async fn test_execute_no_handlers() {
        let engine = HookEngine::new(HookRegistry::new());
        let result = engine.execute(&make_ctx(HookType::PreToolUse)).await;
        assert_eq!(result.action, HookAction::Continue);
    }

    #[tokio::test]
    async fn test_execute_all_continue() {
        let mut registry = HookRegistry::new();
        registry.register(make_simple("a", HookType::PreToolUse, 0, HookResult::continue_()));
        registry.register(make_simple("b", HookType::PreToolUse, 0, HookResult::continue_()));

        let engine = HookEngine::new(registry);
        let result = engine.execute(&make_ctx(HookType::PreToolUse)).await;
        assert_eq!(result.action, HookAction::Continue);
    }

    #[tokio::test]
    async fn test_execute_block_stops_chain() {
        let counter = Arc::new(AtomicUsize::new(0));
        let counter_clone = Arc::clone(&counter);

        struct CountingHandler {
            name: String,
            counter: Arc<AtomicUsize>,
            result: HookResult,
        }

        #[async_trait]
        impl HookHandler for CountingHandler {
            fn name(&self) -> &str {
                &self.name
            }
            fn hook_type(&self) -> HookType {
                HookType::PreToolUse
            }
            fn priority(&self) -> i32 {
                if self.name == "blocker" { 100 } else { 0 }
            }
            async fn handle(&self, _ctx: &HookContext) -> Result<HookResult, HookError> {
                let _ = self.counter.fetch_add(1, Ordering::SeqCst);
                Ok(self.result.clone())
            }
        }

        let mut registry = HookRegistry::new();
        registry.register(Arc::new(CountingHandler {
            name: "blocker".to_string(),
            counter: Arc::clone(&counter),
            result: HookResult::block("blocked"),
        }));
        registry.register(Arc::new(CountingHandler {
            name: "after".to_string(),
            counter: counter_clone,
            result: HookResult::continue_(),
        }));

        let engine = HookEngine::new(registry);
        let result = engine.execute(&make_ctx(HookType::PreToolUse)).await;

        assert!(result.is_blocked());
        assert_eq!(result.reason.as_deref(), Some("blocked"));
        // Only the blocker should have run (priority 100 runs first)
        assert_eq!(counter.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn test_execute_modify_collects_modifications() {
        let mut registry = HookRegistry::new();
        registry.register(make_simple(
            "mod1",
            HookType::PreToolUse,
            10,
            HookResult::modify(serde_json::json!({"key1": "val1"})),
        ));
        registry.register(make_simple(
            "mod2",
            HookType::PreToolUse,
            5,
            HookResult::modify(serde_json::json!({"key2": "val2"})),
        ));

        let engine = HookEngine::new(registry);
        let result = engine.execute(&make_ctx(HookType::PreToolUse)).await;

        assert_eq!(result.action, HookAction::Modify);
        let mods = result.modifications.unwrap();
        assert_eq!(mods["key1"], "val1");
        assert_eq!(mods["key2"], "val2");
    }

    #[tokio::test]
    async fn test_execute_modify_later_overrides() {
        let mut registry = HookRegistry::new();
        registry.register(make_simple(
            "first",
            HookType::PreToolUse,
            100,
            HookResult::modify(serde_json::json!({"key": "first"})),
        ));
        registry.register(make_simple(
            "second",
            HookType::PreToolUse,
            50,
            HookResult::modify(serde_json::json!({"key": "second"})),
        ));

        let engine = HookEngine::new(registry);
        let result = engine.execute(&make_ctx(HookType::PreToolUse)).await;

        let mods = result.modifications.unwrap();
        assert_eq!(mods["key"], "second"); // Later hook's value wins
    }

    #[tokio::test]
    async fn test_execute_messages_concatenated() {
        let mut registry = HookRegistry::new();
        registry.register(make_simple(
            "a",
            HookType::PreToolUse,
            10,
            HookResult::modify_with_message(
                serde_json::json!({}),
                "Message A",
            ),
        ));
        registry.register(make_simple(
            "b",
            HookType::PreToolUse,
            5,
            HookResult::modify_with_message(
                serde_json::json!({}),
                "Message B",
            ),
        ));

        let engine = HookEngine::new(registry);
        let result = engine.execute(&make_ctx(HookType::PreToolUse)).await;

        assert!(result.message.unwrap().contains("Message A"));
    }

    #[tokio::test]
    async fn test_execute_error_fail_open() {
        let mut registry = HookRegistry::new();
        registry.register(Arc::new(ErrorHandler {
            name: "err".to_string(),
            hook_type: HookType::PreToolUse,
        }));

        let engine = HookEngine::new(registry);
        let result = engine.execute(&make_ctx(HookType::PreToolUse)).await;

        // Fail-open: error becomes Continue
        assert_eq!(result.action, HookAction::Continue);
    }

    #[tokio::test]
    async fn test_execute_timeout_fail_open() {
        let mut registry = HookRegistry::new();
        registry.register(Arc::new(SlowHandler {
            name: "slow".to_string(),
            hook_type: HookType::PreToolUse,
            delay_ms: 5000,
        }));

        let engine = HookEngine::new(registry);
        let result = engine.execute(&make_ctx(HookType::PreToolUse)).await;

        // Timeout → fail-open → Continue
        assert_eq!(result.action, HookAction::Continue);
    }

    #[tokio::test]
    async fn test_execute_filter_skips_handler() {
        let mut registry = HookRegistry::new();
        registry.register(Arc::new(SimpleHandler {
            name: "filtered".to_string(),
            hook_type: HookType::PreToolUse,
            priority: 100,
            mode: HookExecutionMode::Blocking,
            result: HookResult::block("should not happen"),
            should_handle: false, // Will be skipped
        }));

        let engine = HookEngine::new(registry);
        let result = engine.execute(&make_ctx(HookType::PreToolUse)).await;
        assert_eq!(result.action, HookAction::Continue);
    }

    #[tokio::test]
    async fn test_execute_background_hooks_spawned() {
        let called = Arc::new(AtomicBool::new(false));
        let mut registry = HookRegistry::new();
        registry.register(Arc::new(TrackingHandler {
            name: "bg".to_string(),
            hook_type: HookType::PostToolUse,
            mode: HookExecutionMode::Background,
            called: Arc::clone(&called),
        }));

        let engine = HookEngine::new(registry);
        let _ = engine.execute(&make_ctx(HookType::PostToolUse)).await;

        // Wait for background to complete
        tokio::time::sleep(Duration::from_millis(100)).await;
        engine.wait_for_background().await;

        assert!(called.load(Ordering::SeqCst));
    }

    #[tokio::test]
    async fn test_forced_blocking_overrides_background_mode() {
        let mut registry = HookRegistry::new();
        registry.register(Arc::new(SimpleHandler {
            name: "forced-bg".to_string(),
            hook_type: HookType::PreToolUse,
            priority: 0,
            mode: HookExecutionMode::Background, // Wants to be background
            result: HookResult::block("blocked by forced-blocking"),
            should_handle: true,
        }));

        let engine = HookEngine::new(registry);
        let result = engine.execute(&make_ctx(HookType::PreToolUse)).await;

        // Should be blocked because PreToolUse forces blocking mode
        assert!(result.is_blocked());
    }

    #[tokio::test]
    async fn test_user_prompt_submit_forced_blocking() {
        let mut registry = HookRegistry::new();
        registry.register(Arc::new(SimpleHandler {
            name: "prompt-hook".to_string(),
            hook_type: HookType::UserPromptSubmit,
            priority: 0,
            mode: HookExecutionMode::Background,
            result: HookResult::block("blocked prompt"),
            should_handle: true,
        }));

        let engine = HookEngine::new(registry);
        let ctx = HookContext::UserPromptSubmit {
            session_id: "s1".to_string(),
            timestamp: "t".to_string(),
            prompt: "test".to_string(),
        };
        let result = engine.execute(&ctx).await;
        assert!(result.is_blocked());
    }

    #[tokio::test]
    async fn test_pre_compact_forced_blocking() {
        let mut registry = HookRegistry::new();
        registry.register(Arc::new(SimpleHandler {
            name: "compact-hook".to_string(),
            hook_type: HookType::PreCompact,
            priority: 0,
            mode: HookExecutionMode::Background,
            result: HookResult::block("blocked compact"),
            should_handle: true,
        }));

        let engine = HookEngine::new(registry);
        let ctx = HookContext::PreCompact {
            session_id: "s1".to_string(),
            timestamp: "t".to_string(),
            current_tokens: 50000,
            target_tokens: 30000,
        };
        let result = engine.execute(&ctx).await;
        assert!(result.is_blocked());
    }

    #[tokio::test]
    async fn test_pending_background_count() {
        let engine = HookEngine::new(HookRegistry::new());
        assert_eq!(engine.pending_background_count(), 0);
    }

    #[tokio::test]
    async fn test_registry_access() {
        let mut registry = HookRegistry::new();
        registry.register(make_simple("a", HookType::PreToolUse, 0, HookResult::continue_()));

        let engine = HookEngine::new(registry);
        assert_eq!(engine.registry().count(), 1);
    }

    #[tokio::test]
    async fn test_registry_mut_access() {
        let registry = HookRegistry::new();
        let mut engine = HookEngine::new(registry);
        engine
            .registry_mut()
            .register(make_simple("a", HookType::PreToolUse, 0, HookResult::continue_()));
        assert_eq!(engine.registry().count(), 1);
    }

    #[tokio::test]
    async fn test_only_matching_type_handlers_execute() {
        let called = Arc::new(AtomicBool::new(false));
        let mut registry = HookRegistry::new();
        registry.register(Arc::new(TrackingHandler {
            name: "post".to_string(),
            hook_type: HookType::PostToolUse,
            mode: HookExecutionMode::Blocking,
            called: Arc::clone(&called),
        }));

        let engine = HookEngine::new(registry);
        let _ = engine.execute(&make_ctx(HookType::PreToolUse)).await;

        // PostToolUse handler should NOT have been called for PreToolUse context
        assert!(!called.load(Ordering::SeqCst));
    }

    #[tokio::test]
    async fn test_debug_impl() {
        let engine = HookEngine::new(HookRegistry::new());
        let debug = format!("{engine:?}");
        assert!(debug.contains("HookEngine"));
    }

    // --- merge_json tests ---

    #[test]
    fn test_merge_json_both_objects() {
        let a = serde_json::json!({"a": 1, "b": 2});
        let b = serde_json::json!({"b": 3, "c": 4});
        let merged = merge_json(Some(&a), &b);
        assert_eq!(merged["a"], 1);
        assert_eq!(merged["b"], 3); // overridden
        assert_eq!(merged["c"], 4);
    }

    #[test]
    fn test_merge_json_none_base() {
        let b = serde_json::json!({"key": "val"});
        let merged = merge_json(None, &b);
        assert_eq!(merged["key"], "val");
    }

    #[test]
    fn test_merge_json_non_object() {
        let a = serde_json::json!("string");
        let b = serde_json::json!(42);
        let merged = merge_json(Some(&a), &b);
        assert_eq!(merged, 42);
    }
}
