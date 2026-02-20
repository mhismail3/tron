//! Tool executor — guardrails → pre-hooks → execute → post-hooks pipeline.

use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::guardrails::{EvaluationContext, GuardrailEngine};
use crate::hooks::engine::HookEngine;
use crate::hooks::types::{HookAction, HookContext};
use serde_json::Value;
use tokio_util::sync::CancellationToken;
use tron_core::events::{BaseEvent, HookResult as EventHookResult, TronEvent};
use tron_core::messages::ToolCall;
use tron_tools::registry::ToolRegistry;
use tron_tools::traits::ToolContext;

use metrics::{counter, histogram};
use tracing::{debug, error, info, instrument, warn};

use crate::agent::event_emitter::EventEmitter;
use crate::types::ToolExecutionResult;

/// Convert a `Duration` to milliseconds, rounding up (ceiling).
///
/// `Duration::as_millis()` truncates sub-millisecond values to 0, which makes
/// fast tools (file glob, SQLite lookup) report "0ms". This function ensures
/// at least 1ms is reported for any non-zero duration.
fn duration_ceil_ms(d: Duration) -> u64 {
    let micros = d.as_micros();
    if micros == 0 {
        return 0;
    }
    // Ceiling division: (micros + 999) / 1000, minimum 1
    ((micros + 999) / 1000) as u64
}

/// Execute a single tool call through the full pipeline.
///
/// Pipeline: guardrails → pre-hooks → execute → post-hooks → result
#[allow(
    clippy::too_many_arguments,
    clippy::too_many_lines,
    clippy::cast_possible_truncation
)]
#[instrument(skip_all, fields(tool_name = tool_call.name, session_id))]
pub async fn execute_tool(
    tool_call: &ToolCall,
    registry: &ToolRegistry,
    guardrails: &Option<Arc<parking_lot::Mutex<GuardrailEngine>>>,
    hooks: &Option<Arc<HookEngine>>,
    session_id: &str,
    working_directory: &str,
    emitter: &Arc<EventEmitter>,
    cancel: &CancellationToken,
    subagent_depth: u32,
    subagent_max_depth: u32,
) -> ToolExecutionResult {
    let start = Instant::now();
    let tool_call_id = tool_call.id.clone();
    let tool_name = tool_call.name.clone();

    // 1. Look up tool
    let Some(tool) = registry.get(&tool_name) else {
        error!(tool_name, "tool not found");
        return ToolExecutionResult {
            tool_call_id,
            result: tron_core::tools::error_result(format!("Tool not found: {tool_name}")),
            duration_ms: duration_ceil_ms(start.elapsed()),
            blocked_by_hook: false,
            blocked_by_guardrail: false,
            stops_turn: false,
            is_interactive: false,
        };
    };

    let stops_turn = tool.stops_turn();
    let is_interactive = tool.is_interactive();

    // 2. Evaluate guardrails (synchronous)
    if let Some(guardrail_engine) = guardrails {
        let eval_ctx = EvaluationContext {
            tool_name: tool_name.clone(),
            tool_arguments: Value::Object(tool_call.arguments.clone()),
            session_id: Some(session_id.to_owned()),
            tool_call_id: Some(tool_call_id.clone()),
        };
        {
            let mut engine = guardrail_engine.lock();
            let eval = engine.evaluate(&eval_ctx);
            if eval.blocked {
                warn!(tool_name, "blocked by guardrail");
                let reason = eval
                    .block_reason
                    .unwrap_or_else(|| "Blocked by guardrail".into());
                return ToolExecutionResult {
                    tool_call_id,
                    result: tron_core::tools::error_result(reason),
                    duration_ms: duration_ceil_ms(start.elapsed()),
                    blocked_by_hook: false,
                    blocked_by_guardrail: true,
                    stops_turn,
                    is_interactive,
                };
            }
        }
    }

    // 3. Execute PreToolUse hooks (blocking, sequential)
    let mut effective_args = Value::Object(tool_call.arguments.clone());
    if let Some(hook_engine) = hooks {
        let hook_ctx = HookContext::PreToolUse {
            session_id: session_id.to_owned(),
            timestamp: chrono::Utc::now().to_rfc3339(),
            tool_name: tool_name.clone(),
            tool_arguments: effective_args.clone(),
            tool_call_id: tool_call_id.clone(),
        };
        let _ = emitter.emit(TronEvent::HookTriggered {
            base: BaseEvent::now(session_id),
            hook_names: vec![],
            hook_event: "PreToolUse".into(),
            tool_name: Some(tool_name.clone()),
            tool_call_id: Some(tool_call_id.clone()),
        });
        let result = hook_engine.execute(&hook_ctx).await;
        let event_result = match result.action {
            HookAction::Block => EventHookResult::Block,
            HookAction::Modify => EventHookResult::Modify,
            HookAction::Continue => EventHookResult::Continue,
        };
        let _ = emitter.emit(TronEvent::HookCompleted {
            base: BaseEvent::now(session_id),
            hook_names: vec![],
            hook_event: "PreToolUse".into(),
            result: event_result,
            duration: None,
            reason: result.reason.clone(),
            tool_name: Some(tool_name.clone()),
            tool_call_id: Some(tool_call_id.clone()),
        });
        match result.action {
            HookAction::Block => {
                warn!(tool_name, "blocked by PreToolUse hook");
                let reason = result
                    .reason
                    .unwrap_or_else(|| "Blocked by PreToolUse hook".into());
                return ToolExecutionResult {
                    tool_call_id,
                    result: tron_core::tools::error_result(reason),
                    duration_ms: duration_ceil_ms(start.elapsed()),
                    blocked_by_hook: true,
                    blocked_by_guardrail: false,
                    stops_turn,
                    is_interactive,
                };
            }
            HookAction::Modify => {
                if let Some(mods) = result.modifications {
                    effective_args = mods;
                }
            }
            HookAction::Continue => {}
        }
    }

    // 4. Emit ToolExecutionStart
    let _ = emitter.emit(TronEvent::ToolExecutionStart {
        base: BaseEvent::now(session_id),
        tool_call_id: tool_call_id.clone(),
        tool_name: tool_name.clone(),
        arguments: effective_args.as_object().cloned(),
    });
    debug!(
        tool_name,
        tool_call_id, session_id, "tool execution started"
    );

    // 5. Execute tool
    let ctx = ToolContext {
        tool_call_id: tool_call_id.clone(),
        session_id: session_id.to_owned(),
        working_directory: working_directory.to_owned(),
        cancellation: cancel.clone(),
        subagent_depth,
        subagent_max_depth,
    };

    let tool_result = if cancel.is_cancelled() {
        tron_core::tools::error_result("Operation cancelled")
    } else {
        match tool.execute(effective_args, &ctx).await {
            Ok(r) => r,
            Err(e) => tron_core::tools::error_result(e.to_string()),
        }
    };

    let duration_ms = duration_ceil_ms(start.elapsed());

    // Record tool metrics
    counter!("tool_executions_total", "tool" => tool_name.clone()).increment(1);
    histogram!("tool_execution_duration_seconds", "tool" => tool_name.clone())
        .record(start.elapsed().as_secs_f64());

    // 6. Emit ToolExecutionEnd
    let _ = emitter.emit(TronEvent::ToolExecutionEnd {
        base: BaseEvent::now(session_id),
        tool_call_id: tool_call_id.clone(),
        tool_name: tool_name.clone(),
        duration: duration_ms,
        is_error: tool_result.is_error,
        result: Some(tool_result.clone()),
    });
    info!(tool = %tool_name, duration_ms, "tool executed");

    // 7. Execute PostToolUse hooks (background, fire-and-forget)
    if let Some(hook_engine) = hooks {
        let hook_ctx = HookContext::PostToolUse {
            session_id: session_id.to_owned(),
            timestamp: chrono::Utc::now().to_rfc3339(),
            tool_name: tool_name.clone(),
            tool_call_id: tool_call_id.clone(),
            result: serde_json::to_value(&tool_result).unwrap_or_default(),
            duration_ms,
        };
        let _ = emitter.emit(TronEvent::HookTriggered {
            base: BaseEvent::now(session_id),
            hook_names: vec![],
            hook_event: "PostToolUse".into(),
            tool_name: Some(tool_name.clone()),
            tool_call_id: Some(tool_call_id.clone()),
        });
        // PostToolUse hooks run fire-and-forget with a 30s timeout to prevent leaks.
        let engine = hook_engine.clone();
        let emitter_bg = emitter.clone();
        let sid = session_id.to_owned();
        let tn = tool_name.clone();
        let tcid = tool_call_id.clone();
        let _handle = tokio::spawn(async move {
            match tokio::time::timeout(
                std::time::Duration::from_secs(30),
                engine.execute(&hook_ctx),
            )
            .await
            {
                Ok(bg_result) => {
                    let event_result = match bg_result.action {
                        HookAction::Block => EventHookResult::Block,
                        HookAction::Modify => EventHookResult::Modify,
                        HookAction::Continue => EventHookResult::Continue,
                    };
                    let _ = emitter_bg.emit(TronEvent::HookCompleted {
                        base: BaseEvent::now(&sid),
                        hook_names: vec![],
                        hook_event: "PostToolUse".into(),
                        result: event_result,
                        duration: None,
                        reason: bg_result.reason.clone(),
                        tool_name: Some(tn),
                        tool_call_id: Some(tcid),
                    });
                }
                Err(_) => {
                    warn!(
                        tool_name = %tn,
                        tool_call_id = %tcid,
                        "PostToolUse hook timed out after 30s"
                    );
                }
            }
        });
    }

    ToolExecutionResult {
        tool_call_id,
        result: tool_result,
        duration_ms,
        blocked_by_hook: false,
        blocked_by_guardrail: false,
        stops_turn,
        is_interactive,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use async_trait::async_trait;
    use serde_json::{Map, json};
    use tron_core::content::ToolResultContent;
    use tron_core::tools::{
        Tool, ToolCategory, ToolParameterSchema, ToolResultBody, TronToolResult, text_result,
    };
    use tron_tools::traits::TronTool;

    // ── Test tool implementations ──

    struct EchoTool;

    #[async_trait]
    impl TronTool for EchoTool {
        fn name(&self) -> &str {
            "echo"
        }
        fn category(&self) -> ToolCategory {
            ToolCategory::Custom
        }
        fn definition(&self) -> Tool {
            Tool {
                name: "echo".into(),
                description: "Echoes input".into(),
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
            params: Value,
            _ctx: &ToolContext,
        ) -> Result<TronToolResult, tron_tools::errors::ToolError> {
            let text = params
                .get("text")
                .and_then(|v| v.as_str())
                .unwrap_or("no text");
            Ok(text_result(text, false))
        }
    }

    struct StopTurnTool;

    #[async_trait]
    impl TronTool for StopTurnTool {
        fn name(&self) -> &str {
            "ask_user"
        }
        fn category(&self) -> ToolCategory {
            ToolCategory::Custom
        }
        fn stops_turn(&self) -> bool {
            true
        }
        fn is_interactive(&self) -> bool {
            true
        }
        fn definition(&self) -> Tool {
            Tool {
                name: "ask_user".into(),
                description: "Ask user".into(),
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
        ) -> Result<TronToolResult, tron_tools::errors::ToolError> {
            Ok(text_result("Asked user", false))
        }
    }

    fn make_registry(tools: Vec<Arc<dyn TronTool>>) -> ToolRegistry {
        let mut registry = ToolRegistry::new();
        for tool in tools {
            registry.register(tool);
        }
        registry
    }

    fn make_tool_call(name: &str, args: Map<String, Value>) -> ToolCall {
        ToolCall::new("tc-1", name, args)
    }

    #[tokio::test]
    async fn successful_execution() {
        let registry = make_registry(vec![Arc::new(EchoTool)]);
        let emitter = Arc::new(EventEmitter::new());
        let cancel = CancellationToken::new();

        let mut args = Map::new();
        let _ = args.insert("text".into(), json!("hello"));
        let tc = make_tool_call("echo", args);

        let result = execute_tool(
            &tc, &registry, &None, &None, "s1", "/tmp", &emitter, &cancel, 0, 0,
        )
        .await;

        assert!(!result.result.is_error.unwrap_or(false));
        assert!(!result.blocked_by_hook);
        assert!(!result.blocked_by_guardrail);
        assert!(!result.stops_turn);
        assert!(!result.is_interactive);
        assert!(result.duration_ms < 1000);
    }

    #[tokio::test]
    async fn tool_not_found() {
        let registry = ToolRegistry::new();
        let emitter = Arc::new(EventEmitter::new());
        let cancel = CancellationToken::new();

        let tc = make_tool_call("nonexistent", Map::new());
        let result = execute_tool(
            &tc, &registry, &None, &None, "s1", "/tmp", &emitter, &cancel, 0, 0,
        )
        .await;

        assert!(result.result.is_error.unwrap_or(false));
        match &result.result.content {
            ToolResultBody::Blocks(blocks) => {
                let text = match &blocks[0] {
                    ToolResultContent::Text { text } => text,
                    _ => panic!("Expected text block"),
                };
                assert!(text.contains("not found"));
            }
            _ => panic!("Expected blocks result"),
        }
    }

    #[tokio::test]
    async fn guardrail_blocks() {
        let registry = make_registry(vec![Arc::new(EchoTool)]);
        let emitter = Arc::new(EventEmitter::new());
        let cancel = CancellationToken::new();

        // Set up guardrails that block "echo" with dangerous args
        let mut engine = GuardrailEngine::new(crate::guardrails::GuardrailEngineOptions::default());
        use crate::guardrails::rules::{GuardrailRule, RuleBase, pattern::PatternRule};
        use crate::guardrails::types::Severity;
        engine.register_rule(GuardrailRule::Pattern(PatternRule {
            base: RuleBase {
                id: "test-block".into(),
                name: "Block rm".into(),
                description: "Block rm commands".into(),
                severity: Severity::Block,
                scope: crate::guardrails::types::Scope::Tool,
                tier: crate::guardrails::types::RuleTier::Custom,
                tools: vec!["echo".into()],
                priority: 100,
                enabled: true,
                tags: vec![],
            },
            target_argument: "text".into(),
            patterns: vec![regex::Regex::new("rm -rf").unwrap()],
        }));

        let guardrails = Some(Arc::new(parking_lot::Mutex::new(engine)));

        let mut args = Map::new();
        let _ = args.insert("text".into(), json!("rm -rf /"));
        let tc = make_tool_call("echo", args);

        let result = execute_tool(
            &tc,
            &registry,
            &guardrails,
            &None,
            "s1",
            "/tmp",
            &emitter,
            &cancel,
            0,
            0,
        )
        .await;

        assert!(result.result.is_error.unwrap_or(false));
        assert!(result.blocked_by_guardrail);
    }

    #[tokio::test]
    async fn stop_turn_tool_flags() {
        let registry = make_registry(vec![Arc::new(StopTurnTool)]);
        let emitter = Arc::new(EventEmitter::new());
        let cancel = CancellationToken::new();

        let tc = make_tool_call("ask_user", Map::new());
        let result = execute_tool(
            &tc, &registry, &None, &None, "s1", "/tmp", &emitter, &cancel, 0, 0,
        )
        .await;

        assert!(!result.result.is_error.unwrap_or(false));
        assert!(result.stops_turn);
        assert!(result.is_interactive);
    }

    #[tokio::test]
    async fn cancelled_before_execution() {
        let registry = make_registry(vec![Arc::new(EchoTool)]);
        let emitter = Arc::new(EventEmitter::new());
        let cancel = CancellationToken::new();
        cancel.cancel();

        let tc = make_tool_call("echo", Map::new());
        let result = execute_tool(
            &tc, &registry, &None, &None, "s1", "/tmp", &emitter, &cancel, 0, 0,
        )
        .await;

        assert!(result.result.is_error.unwrap_or(false));
    }

    #[tokio::test]
    async fn emits_start_and_end_events() {
        let registry = make_registry(vec![Arc::new(EchoTool)]);
        let emitter = Arc::new(EventEmitter::new());
        let mut rx = emitter.subscribe();
        let cancel = CancellationToken::new();

        let mut args = Map::new();
        let _ = args.insert("text".into(), json!("test"));
        let tc = make_tool_call("echo", args);

        let _ = execute_tool(
            &tc, &registry, &None, &None, "s1", "/tmp", &emitter, &cancel, 0, 0,
        )
        .await;

        let mut saw_start = false;
        let mut saw_end = false;
        while let Ok(event) = rx.try_recv() {
            match event {
                TronEvent::ToolExecutionStart { tool_name, .. } if tool_name == "echo" => {
                    saw_start = true;
                }
                TronEvent::ToolExecutionEnd { tool_name, .. } if tool_name == "echo" => {
                    saw_end = true;
                }
                _ => {}
            }
        }
        assert!(saw_start);
        assert!(saw_end);
    }

    #[tokio::test]
    async fn pre_tool_use_hook_emits_triggered_and_completed() {
        use crate::hooks::errors::HookError;
        use crate::hooks::handler::HookHandler;
        use crate::hooks::registry::HookRegistry;
        use crate::hooks::types::{HookResult as HookExecResult, HookType};

        struct ContinueHandler;

        #[async_trait]
        impl HookHandler for ContinueHandler {
            fn name(&self) -> &str {
                "test-continue"
            }
            fn hook_type(&self) -> HookType {
                HookType::PreToolUse
            }
            async fn handle(&self, _ctx: &HookContext) -> Result<HookExecResult, HookError> {
                Ok(HookExecResult::continue_())
            }
        }

        let mut hook_registry = HookRegistry::new();
        hook_registry.register(Arc::new(ContinueHandler));
        let hook_engine = Arc::new(HookEngine::new(hook_registry));

        let registry = make_registry(vec![Arc::new(EchoTool)]);
        let emitter = Arc::new(EventEmitter::new());
        let mut rx = emitter.subscribe();
        let cancel = CancellationToken::new();

        let mut args = Map::new();
        let _ = args.insert("text".into(), json!("test"));
        let tc = make_tool_call("echo", args);

        let _ = execute_tool(
            &tc,
            &registry,
            &None,
            &Some(hook_engine),
            "s1",
            "/tmp",
            &emitter,
            &cancel,
            0,
            0,
        )
        .await;

        let mut saw_triggered = false;
        let mut saw_completed = false;
        while let Ok(event) = rx.try_recv() {
            match &event {
                TronEvent::HookTriggered { hook_event, .. } if hook_event == "PreToolUse" => {
                    saw_triggered = true;
                }
                TronEvent::HookCompleted { hook_event, .. } if hook_event == "PreToolUse" => {
                    saw_completed = true;
                }
                _ => {}
            }
        }
        assert!(saw_triggered, "should emit HookTriggered for PreToolUse");
        assert!(saw_completed, "should emit HookCompleted for PreToolUse");
    }

    #[tokio::test]
    async fn post_tool_use_hook_emits_triggered() {
        use crate::hooks::errors::HookError;
        use crate::hooks::handler::HookHandler;
        use crate::hooks::registry::HookRegistry;
        use crate::hooks::types::{HookExecutionMode, HookResult as HookExecResult, HookType};

        struct BgHandler;

        #[async_trait]
        impl HookHandler for BgHandler {
            fn name(&self) -> &str {
                "test-bg"
            }
            fn hook_type(&self) -> HookType {
                HookType::PostToolUse
            }
            fn execution_mode(&self) -> HookExecutionMode {
                HookExecutionMode::Background
            }
            async fn handle(&self, _ctx: &HookContext) -> Result<HookExecResult, HookError> {
                Ok(HookExecResult::continue_())
            }
        }

        let mut hook_registry = HookRegistry::new();
        hook_registry.register(Arc::new(BgHandler));
        let hook_engine = Arc::new(HookEngine::new(hook_registry));

        let registry = make_registry(vec![Arc::new(EchoTool)]);
        let emitter = Arc::new(EventEmitter::new());
        let mut rx = emitter.subscribe();
        let cancel = CancellationToken::new();

        let mut args = Map::new();
        let _ = args.insert("text".into(), json!("test"));
        let tc = make_tool_call("echo", args);

        let _ = execute_tool(
            &tc,
            &registry,
            &None,
            &Some(hook_engine),
            "s1",
            "/tmp",
            &emitter,
            &cancel,
            0,
            0,
        )
        .await;

        // Give background task a moment to complete
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;

        let mut saw_triggered = false;
        let mut saw_completed = false;
        while let Ok(event) = rx.try_recv() {
            match &event {
                TronEvent::HookTriggered { hook_event, .. } if hook_event == "PostToolUse" => {
                    saw_triggered = true;
                }
                TronEvent::HookCompleted { hook_event, .. } if hook_event == "PostToolUse" => {
                    saw_completed = true;
                }
                _ => {}
            }
        }
        assert!(saw_triggered, "should emit HookTriggered for PostToolUse");
        assert!(saw_completed, "should emit HookCompleted for PostToolUse");
    }

    #[tokio::test]
    async fn post_tool_use_hook_timeout() {
        use crate::hooks::errors::HookError;
        use crate::hooks::handler::HookHandler;
        use crate::hooks::registry::HookRegistry;
        use crate::hooks::types::{HookExecutionMode, HookResult as HookExecResult, HookType};
        use std::sync::atomic::{AtomicBool, Ordering};

        // Track whether the handler completed (it shouldn't — timeout fires first)
        let handler_completed = Arc::new(AtomicBool::new(false));
        let handler_completed_clone = handler_completed.clone();

        struct SlowHandler {
            completed: Arc<AtomicBool>,
        }

        #[async_trait]
        impl HookHandler for SlowHandler {
            fn name(&self) -> &str {
                "test-slow"
            }
            fn hook_type(&self) -> HookType {
                HookType::PostToolUse
            }
            fn execution_mode(&self) -> HookExecutionMode {
                HookExecutionMode::Background
            }
            async fn handle(&self, _ctx: &HookContext) -> Result<HookExecResult, HookError> {
                tokio::time::sleep(std::time::Duration::from_secs(60)).await;
                self.completed.store(true, Ordering::SeqCst);
                Ok(HookExecResult::continue_())
            }
        }

        tokio::time::pause();

        let mut hook_registry = HookRegistry::new();
        hook_registry.register(Arc::new(SlowHandler {
            completed: handler_completed_clone,
        }));
        let hook_engine = Arc::new(HookEngine::new(hook_registry));

        let registry = make_registry(vec![Arc::new(EchoTool)]);
        let emitter = Arc::new(EventEmitter::new());
        let cancel = CancellationToken::new();

        let mut args = Map::new();
        let _ = args.insert("text".into(), json!("test"));
        let tc = make_tool_call("echo", args);

        let _ = execute_tool(
            &tc,
            &registry,
            &None,
            &Some(hook_engine),
            "s1",
            "/tmp",
            &emitter,
            &cancel,
            0,
            0,
        )
        .await;

        // Let the spawned task start and register its timers
        tokio::task::yield_now().await;

        // Advance past the 30s timeout (but not past 60s handler sleep)
        tokio::time::advance(std::time::Duration::from_secs(31)).await;
        tokio::task::yield_now().await;

        // The handler should NOT have completed (timeout fired first)
        assert!(
            !handler_completed.load(Ordering::SeqCst),
            "handler should not have completed — timeout should have fired"
        );
    }

    #[tokio::test]
    async fn multiple_sequential_tools() {
        let registry = make_registry(vec![Arc::new(EchoTool), Arc::new(StopTurnTool)]);
        let emitter = Arc::new(EventEmitter::new());
        let cancel = CancellationToken::new();

        let tc1 = make_tool_call("echo", {
            let mut m = Map::new();
            let _ = m.insert("text".into(), json!("a"));
            m
        });
        let tc2 = make_tool_call("ask_user", Map::new());

        let r1 = execute_tool(
            &tc1, &registry, &None, &None, "s1", "/tmp", &emitter, &cancel, 0, 0,
        )
        .await;
        let r2 = execute_tool(
            &tc2, &registry, &None, &None, "s1", "/tmp", &emitter, &cancel, 0, 0,
        )
        .await;

        assert!(!r1.result.is_error.unwrap_or(false));
        assert!(!r1.stops_turn);
        assert!(!r2.result.is_error.unwrap_or(false));
        assert!(r2.stops_turn);
    }

    #[tokio::test]
    async fn guardrail_lock_always_succeeds() {
        let engine = GuardrailEngine::new(crate::guardrails::GuardrailEngineOptions::default());
        let guardrails = Arc::new(parking_lot::Mutex::new(engine));
        // parking_lot::Mutex::lock() always succeeds (no Result, no poison)
        let _guard = guardrails.lock();
    }

    #[tokio::test]
    async fn guardrail_evaluates_after_lock() {
        let mut engine = GuardrailEngine::new(crate::guardrails::GuardrailEngineOptions::default());
        use crate::guardrails::rules::{GuardrailRule, RuleBase, pattern::PatternRule};
        use crate::guardrails::types::Severity;
        engine.register_rule(GuardrailRule::Pattern(PatternRule {
            base: RuleBase {
                id: "test".into(),
                name: "Test".into(),
                description: "Test".into(),
                severity: Severity::Block,
                scope: crate::guardrails::types::Scope::Tool,
                tier: crate::guardrails::types::RuleTier::Custom,
                tools: vec!["bash".into()],
                priority: 100,
                enabled: true,
                tags: vec![],
            },
            target_argument: "command".into(),
            patterns: vec![regex::Regex::new("rm").unwrap()],
        }));

        let guardrails = Arc::new(parking_lot::Mutex::new(engine));
        let guard = guardrails.lock();
        let eval_ctx = EvaluationContext {
            tool_name: "bash".into(),
            tool_arguments: json!({"command": "rm -rf /"}),
            session_id: None,
            tool_call_id: None,
        };
        // Can't call evaluate on immutable guard — drop and re-lock as mutable
        drop(guard);
        let mut guard = guardrails.lock();
        let eval = guard.evaluate(&eval_ctx);
        assert!(eval.blocked);
    }
}
