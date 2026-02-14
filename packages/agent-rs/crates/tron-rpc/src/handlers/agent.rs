//! Agent handlers: prompt, abort, getState.

use async_trait::async_trait;
use serde_json::Value;
use tracing::{info, instrument, warn};

use crate::context::RpcContext;
use crate::errors::{self, RpcError};
use crate::handlers::require_string_param;
use crate::registry::MethodHandler;

/// Submit a prompt to the agent for a session.
pub struct PromptHandler;

#[async_trait]
impl MethodHandler for PromptHandler {
    #[instrument(skip(self, ctx), fields(method = "agent.prompt", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let prompt = require_string_param(params.as_ref(), "prompt")?;

        // Extract optional extra params (iOS sends these)
        let _reasoning_level = params
            .as_ref()
            .and_then(|p| p.get("reasoningLevel"))
            .and_then(|v| v.as_str());
        let _images = params
            .as_ref()
            .and_then(|p| p.get("images"))
            .and_then(|v| v.as_array());
        let _attachments = params
            .as_ref()
            .and_then(|p| p.get("attachments"))
            .and_then(|v| v.as_array());
        let _skills = params
            .as_ref()
            .and_then(|p| p.get("skills"))
            .and_then(|v| v.as_array());
        let _spells = params
            .as_ref()
            .and_then(|p| p.get("spells"))
            .and_then(|v| v.as_array());

        // Verify the session exists and get its details
        let session = ctx
            .session_manager
            .get_session(&session_id)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?
            .ok_or_else(|| RpcError::NotFound {
                code: errors::SESSION_NOT_FOUND.into(),
                message: format!("Session '{session_id}' not found"),
            })?;

        let run_id = uuid::Uuid::now_v7().to_string();

        // Register the run with the orchestrator (tracks CancellationToken).
        // If the session already has an active run, this returns an error.
        let cancel_token = ctx
            .orchestrator
            .start_run(&session_id, &run_id)
            .map_err(|e| RpcError::Custom {
                code: "SESSION_BUSY".into(),
                message: e.to_string(),
                details: None,
            })?;

        // If agent deps are configured, spawn background execution
        if let Some(deps) = &ctx.agent_deps {
            let orchestrator = ctx.orchestrator.clone();
            let session_manager = ctx.session_manager.clone();
            let broadcast = orchestrator.broadcast().clone();
            let provider = deps.provider.clone();
            let tool_factory = deps.tool_factory.clone();
            let guardrails = deps.guardrails.clone();
            let hooks = deps.hooks.clone();
            let session_id_clone = session_id.clone();
            let run_id_clone = run_id.clone();
            let model = session.latest_model.clone();
            let working_dir = session.working_directory.clone();

            let event_store = ctx.event_store.clone();
            let prompt_clone = prompt.clone();

            drop(tokio::spawn(async move {
                use tron_runtime::orchestrator::agent_factory::{AgentFactory, CreateAgentOpts};
                use tron_runtime::orchestrator::agent_runner::run_agent;
                use tron_runtime::types::{AgentConfig, RunContext};

                // 1. Resume session to get reconstructed state (messages, model, etc.)
                let state = match session_manager.resume_session(&session_id_clone) {
                    Ok(active) => active.state.clone(),
                    Err(e) => {
                        warn!(session_id = %session_id_clone, error = %e, "failed to resume session, starting fresh");
                        tron_runtime::orchestrator::session_reconstructor::ReconstructedState {
                            model: model.clone(),
                            working_directory: Some(working_dir.clone()),
                            ..Default::default()
                        }
                    }
                };

                // 2. Load project rules via ContextLoader
                let project_rules = {
                    let wd = std::path::Path::new(&working_dir);
                    let mut loader = tron_context::loader::ContextLoader::new(
                        tron_context::loader::ContextLoaderConfig {
                            project_root: wd.to_path_buf(),
                            ..Default::default()
                        },
                    );
                    loader.load(wd).ok().and_then(|ctx| {
                        if ctx.merged.is_empty() { None } else { Some(ctx.merged) }
                    })
                };

                // 3. Load global rules (~/.tron/CLAUDE.md)
                let home_dir = std::env::var("HOME").ok().map(std::path::PathBuf::from);
                let global_rules = home_dir
                    .as_deref()
                    .and_then(tron_context::loader::load_global_rules);

                // 4. Merge rules (global first, then project)
                let combined_rules = tron_context::loader::merge_rules(global_rules, project_rules);

                // 5. Load memory from ~/.tron/notes/MEMORY.md
                let memory = home_dir
                    .as_ref()
                    .map(|h| h.join(".tron").join("notes").join("MEMORY.md"))
                    .and_then(|p| std::fs::read_to_string(p).ok())
                    .filter(|s| !s.trim().is_empty());

                // 6. Get messages from reconstructed state
                let messages = state.messages.clone();

                let config = AgentConfig {
                    model,
                    working_directory: Some(working_dir),
                    enable_thinking: true,
                    ..AgentConfig::default()
                };

                let tools = tool_factory();
                let mut agent = AgentFactory::create_agent(
                    config,
                    session_id_clone.clone(),
                    CreateAgentOpts {
                        provider,
                        tools,
                        guardrails,
                        hooks: hooks.clone(),
                        is_subagent: false,
                        denied_tools: vec![],
                        rules_content: combined_rules,
                        initial_messages: messages,
                        memory_content: memory,
                    },
                );

                agent.set_abort_token(cancel_token);

                // 7a. Create inline persister — events are written during turn execution
                let persister = std::sync::Arc::new(
                    tron_runtime::orchestrator::event_persister::EventPersister::new(
                        event_store.clone(),
                        session_id_clone.clone(),
                    ),
                );
                agent.set_persister(Some(persister.clone()));

                // 7b. Persist message.user event BEFORE agent runs (matches TS server)
                let _ = event_store.append(&tron_events::AppendOptions {
                    session_id: &session_id_clone,
                    event_type: tron_events::EventType::MessageUser,
                    payload: serde_json::json!({"content": prompt_clone}),
                    parent_id: None,
                });

                let result = run_agent(
                    &mut agent,
                    &prompt,
                    RunContext::default(),
                    &hooks,
                    &broadcast,
                )
                .await;

                // 8. Flush persister to ensure all inline-persisted events are written
                let _ = persister.flush().await;

                // 9. Invalidate cached session so next resume reconstructs from events
                session_manager.invalidate_session(&session_id_clone);

                info!(
                    session_id = %session_id_clone,
                    run_id = %run_id_clone,
                    stop_reason = ?result.stop_reason,
                    turns = result.turns_executed,
                    "prompt run completed"
                );
                orchestrator.complete_run(&session_id_clone);
            }));
        }

        Ok(serde_json::json!({
            "acknowledged": true,
            "runId": run_id,
        }))
    }
}

/// Abort a running agent in a session.
pub struct AbortHandler;

#[async_trait]
impl MethodHandler for AbortHandler {
    #[instrument(skip(self, ctx), fields(method = "agent.abort", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        let aborted = ctx
            .orchestrator
            .abort(&session_id)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?;

        Ok(serde_json::json!({ "aborted": aborted }))
    }
}

/// Get the current agent state for a session.
pub struct GetAgentStateHandler;

#[async_trait]
impl MethodHandler for GetAgentStateHandler {
    #[instrument(skip(self, ctx), fields(method = "agent.getState", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        let is_running = ctx.orchestrator.has_active_run(&session_id);
        let run_id = ctx.orchestrator.get_run_id(&session_id);

        // Try to get session metadata for model/turn/message info
        let (model, current_turn, message_count, total_input, total_output) =
            if let Ok(Some(session)) = ctx.session_manager.get_session(&session_id) {
                let model = session.latest_model.clone();
                let input = session.total_input_tokens;
                let output = session.total_output_tokens;
                // Try reconstructing state for turn/message counts
                if let Ok(active) = ctx.session_manager.resume_session(&session_id) {
                    (
                        model,
                        active.state.turn_count,
                        active.state.messages.len(),
                        input,
                        output,
                    )
                } else {
                    (model, 0, 0, input, output)
                }
            } else {
                (String::new(), 0, 0, 0, 0)
            };

        Ok(serde_json::json!({
            "sessionId": session_id,
            "isRunning": is_running,
            "currentTurn": current_turn,
            "messageCount": message_count,
            "model": model,
            "runId": run_id,
            "tokenUsage": {
                "input": total_input,
                "output": total_output,
            },
            "tools": [],
            "wasInterrupted": false,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use crate::context::AgentDeps;
    use crate::handlers::test_helpers::{make_test_context, make_test_context_with_agent_deps};
    use futures::stream;
    use serde_json::json;
    use tron_core::content::AssistantContent;
    use tron_core::events::{AssistantMessage, StreamEvent};
    use tron_core::messages::TokenUsage;
    use tron_llm::models::types::ProviderType;
    use tron_llm::provider::{Provider, ProviderError, ProviderStreamOptions, StreamEventStream};
    use tron_tools::registry::ToolRegistry;

    /// A mock provider that returns a single text response.
    struct TextProvider {
        text: String,
    }
    impl TextProvider {
        fn new(text: &str) -> Self {
            Self {
                text: text.to_owned(),
            }
        }
    }
    #[async_trait]
    impl Provider for TextProvider {
        fn provider_type(&self) -> ProviderType {
            ProviderType::Anthropic
        }
        fn model(&self) -> &str {
            "mock"
        }
        async fn stream(
            &self,
            _c: &tron_core::messages::Context,
            _o: &ProviderStreamOptions,
        ) -> Result<StreamEventStream, ProviderError> {
            let text = self.text.clone();
            let events = vec![
                Ok(StreamEvent::Start),
                Ok(StreamEvent::TextDelta {
                    delta: text.clone(),
                }),
                Ok(StreamEvent::Done {
                    message: AssistantMessage {
                        content: vec![AssistantContent::text(&text)],
                        token_usage: Some(TokenUsage {
                            input_tokens: 10,
                            output_tokens: 5,
                            ..Default::default()
                        }),
                    },
                    stop_reason: "end_turn".into(),
                }),
            ];
            Ok(Box::pin(stream::iter(events)))
        }
    }

    fn make_text_context(text: &str) -> RpcContext {
        let mut ctx = make_test_context();
        ctx.agent_deps = Some(AgentDeps {
            provider: Arc::new(TextProvider::new(text)),
            tool_factory: Arc::new(ToolRegistry::new),
            guardrails: None,
            hooks: None,
        });
        ctx
    }

    #[tokio::test]
    async fn prompt_returns_acknowledged() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let result = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hello"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);
        assert!(result["runId"].is_string());
    }

    #[tokio::test]
    async fn prompt_generates_unique_run_ids() {
        let ctx = make_test_context();
        let sid1 = ctx
            .session_manager
            .create_session("m", "/tmp/1", Some("t1"))
            .unwrap();
        let sid2 = ctx
            .session_manager
            .create_session("m", "/tmp/2", Some("t2"))
            .unwrap();

        let r1 = PromptHandler
            .handle(Some(json!({"sessionId": sid1, "prompt": "hi"})), &ctx)
            .await
            .unwrap();
        let r2 = PromptHandler
            .handle(Some(json!({"sessionId": sid2, "prompt": "hi"})), &ctx)
            .await
            .unwrap();
        assert_ne!(r1["runId"], r2["runId"]);
    }

    #[tokio::test]
    async fn prompt_missing_session_id() {
        let ctx = make_test_context();
        let err = PromptHandler
            .handle(Some(json!({"prompt": "hi"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn prompt_missing_prompt() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();
        let err = PromptHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn prompt_session_not_found() {
        let ctx = make_test_context();
        let err = PromptHandler
            .handle(
                Some(json!({"sessionId": "nonexistent", "prompt": "hi"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "SESSION_NOT_FOUND");
    }

    #[tokio::test]
    async fn prompt_rejects_busy_session() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        // First prompt succeeds
        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hello"})), &ctx)
            .await
            .unwrap();

        // Second prompt should fail (session busy)
        let err = PromptHandler
            .handle(
                Some(json!({"sessionId": sid, "prompt": "hello again"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "SESSION_BUSY");
    }

    #[tokio::test]
    async fn abort_active_returns_true() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        // Start a run so there's something to abort
        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hi"})), &ctx)
            .await
            .unwrap();

        let result = AbortHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["aborted"], true);
    }

    #[tokio::test]
    async fn abort_inactive_returns_false() {
        let ctx = make_test_context();
        let result = AbortHandler
            .handle(Some(json!({"sessionId": "unknown"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["aborted"], false);
    }

    #[tokio::test]
    async fn abort_missing_param() {
        let ctx = make_test_context();
        let err = AbortHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn get_state_returns_is_running() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        let result = GetAgentStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["isRunning"], false);
    }

    #[tokio::test]
    async fn get_state_returns_model() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", None)
            .unwrap();

        let result = GetAgentStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["model"], "claude-opus-4-6");
    }

    #[tokio::test]
    async fn get_state_returns_message_count() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        let result = GetAgentStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["messageCount"], 0);
    }

    #[tokio::test]
    async fn get_state_returns_current_turn() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        let result = GetAgentStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["currentTurn"], 0);
    }

    #[tokio::test]
    async fn get_state_busy_session_is_running() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        // Start a run
        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hi"})), &ctx)
            .await
            .unwrap();

        let result = GetAgentStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["isRunning"], true);
        assert!(result["runId"].is_string());
    }

    #[tokio::test]
    async fn get_state_returns_token_usage() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        let result = GetAgentStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert!(result["tokenUsage"].is_object());
        assert!(result["tokenUsage"]["input"].is_number());
        assert!(result["tokenUsage"]["output"].is_number());
    }

    #[tokio::test]
    async fn get_state_returns_tools_array() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        let result = GetAgentStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert!(result["tools"].is_array());
    }

    #[tokio::test]
    async fn get_state_returns_was_interrupted() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        let result = GetAgentStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["wasInterrupted"], false);
    }

    #[tokio::test]
    async fn get_state_token_usage_field_names() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        let result = GetAgentStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        // iOS expects "input"/"output" not "inputTokens"/"outputTokens"
        assert!(result["tokenUsage"].get("input").is_some());
        assert!(result["tokenUsage"].get("output").is_some());
        assert!(result["tokenUsage"].get("inputTokens").is_none());
        assert!(result["tokenUsage"].get("outputTokens").is_none());
    }

    #[tokio::test]
    async fn get_state_unknown_session() {
        let ctx = make_test_context();
        let result = GetAgentStateHandler
            .handle(Some(json!({"sessionId": "unknown"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["isRunning"], false);
        assert!(result["runId"].is_null());
    }

    // ── Extra prompt params ──

    #[tokio::test]
    async fn prompt_accepts_reasoning_level() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();
        let result = PromptHandler
            .handle(
                Some(json!({"sessionId": sid, "prompt": "hi", "reasoningLevel": "high"})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);
    }

    #[tokio::test]
    async fn prompt_accepts_images() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();
        let result = PromptHandler
            .handle(
                Some(json!({"sessionId": sid, "prompt": "hi", "images": [{"data": "base64..."}]})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);
    }

    #[tokio::test]
    async fn prompt_accepts_attachments() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();
        let result = PromptHandler
            .handle(
                Some(json!({"sessionId": sid, "prompt": "hi", "attachments": [{"path": "/tmp/f.txt"}]})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);
    }

    #[tokio::test]
    async fn prompt_accepts_skills_and_spells() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();
        let result = PromptHandler
            .handle(
                Some(json!({"sessionId": sid, "prompt": "hi", "skills": ["web-search"], "spells": ["auto-commit"]})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);
    }

    // ── Phase 14: Prompt execution chain tests ──

    #[tokio::test]
    async fn prompt_spawns_background_task() {
        let ctx = make_text_context("Hello!");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", Some("t"))
            .unwrap();

        let result = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hi"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        // Wait for background task to complete
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;

        // Run should be completed (not busy anymore)
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_without_agent_deps_stays_busy() {
        // No agent_deps → run is registered but never completed
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hi"})), &ctx)
            .await
            .unwrap();

        // Still busy (no background task to complete it)
        assert!(ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_complete_run_on_success() {
        let ctx = make_text_context("Done.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "work"})), &ctx)
            .await
            .unwrap();

        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_complete_run_on_error() {
        // Use an error provider
        struct ErrorProvider;
        #[async_trait]
        impl Provider for ErrorProvider {
            fn provider_type(&self) -> ProviderType {
                ProviderType::Anthropic
            }
            fn model(&self) -> &str {
                "mock"
            }
            async fn stream(
                &self,
                _c: &tron_core::messages::Context,
                _o: &ProviderStreamOptions,
            ) -> Result<StreamEventStream, ProviderError> {
                Err(ProviderError::Auth {
                    message: "expired".into(),
                })
            }
        }

        let mut ctx = make_test_context();
        ctx.agent_deps = Some(AgentDeps {
            provider: Arc::new(ErrorProvider),
            tool_factory: Arc::new(ToolRegistry::new),
            guardrails: None,
            hooks: None,
        });

        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hi"})), &ctx)
            .await
            .unwrap();

        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        // Even on error, orchestrator should be freed
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_forwards_events_to_broadcast() {
        let ctx = make_text_context("Hello events!");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let mut rx = ctx.orchestrator.subscribe();

        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hi"})), &ctx)
            .await
            .unwrap();

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;

        // Collect events
        let mut event_types = vec![];
        while let Ok(event) = rx.try_recv() {
            event_types.push(event.event_type().to_owned());
        }

        // Should have agent lifecycle events forwarded through broadcast
        assert!(
            event_types.contains(&"agent_end".to_owned()),
            "expected agent_end in {event_types:?}"
        );
        assert!(
            event_types.contains(&"agent_ready".to_owned()),
            "expected agent_ready in {event_types:?}"
        );
    }

    #[tokio::test]
    async fn prompt_event_ordering() {
        let ctx = make_text_context("Ordered!");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let mut rx = ctx.orchestrator.subscribe();

        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hi"})), &ctx)
            .await
            .unwrap();

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;

        let mut event_types = vec![];
        while let Ok(event) = rx.try_recv() {
            event_types.push(event.event_type().to_owned());
        }

        // agent_end MUST come before agent_ready (iOS dependency)
        let end_pos = event_types.iter().position(|t| t == "agent_end");
        let ready_pos = event_types.iter().position(|t| t == "agent_ready");
        assert!(end_pos.is_some(), "agent_end must exist in {event_types:?}");
        assert!(
            ready_pos.is_some(),
            "agent_ready must exist in {event_types:?}"
        );
        assert!(
            end_pos.unwrap() < ready_pos.unwrap(),
            "agent_end ({}) must come before agent_ready ({})",
            end_pos.unwrap(),
            ready_pos.unwrap()
        );
    }

    #[tokio::test]
    async fn prompt_sequential_after_complete() {
        let ctx = make_text_context("Hello!");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        // First prompt
        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "first"})), &ctx)
            .await
            .unwrap();

        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));

        // Second prompt should work after first completes
        let result = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "second"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);
    }

    #[tokio::test]
    async fn prompt_concurrent_reject() {
        let ctx = make_text_context("Hello!");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        // First prompt
        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "first"})), &ctx)
            .await
            .unwrap();

        // Second prompt immediately should still fail (background task likely still running)
        let err = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "second"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "SESSION_BUSY");
    }

    // ── Phase 17: Context loading tests ──

    #[tokio::test]
    async fn prompt_loads_rules_from_working_dir() {
        let tmp = tempfile::tempdir().unwrap();
        let claude_dir = tmp.path().join(".claude");
        std::fs::create_dir_all(&claude_dir).unwrap();
        std::fs::write(claude_dir.join("AGENTS.md"), "# Project Rules\nBe helpful.").unwrap();

        let ctx = make_text_context("Done.");
        let sid = ctx
            .session_manager
            .create_session("mock", tmp.path().to_str().unwrap(), None)
            .unwrap();

        let result = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hi"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_no_rules_still_works() {
        let tmp = tempfile::tempdir().unwrap();

        let ctx = make_text_context("Done.");
        let sid = ctx
            .session_manager
            .create_session("mock", tmp.path().to_str().unwrap(), None)
            .unwrap();

        let result = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hi"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_restores_messages_from_session() {
        let ctx = make_text_context("Response.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        // Store message events in the session
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageUser,
            payload: json!({"text": "hello"}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({
                "content": [{"type": "text", "text": "hi there"}],
                "tokenUsage": {"inputTokens": 10, "outputTokens": 5}
            }),
            parent_id: None,
        });

        // Prompt should succeed with history loaded
        let result = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "follow up"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_empty_session_no_messages() {
        let ctx = make_text_context("Hello.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let result = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "first message"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_nonexistent_working_dir_ok() {
        let ctx = make_text_context("Done.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/nonexistent/path/for/test", None)
            .unwrap();

        let result = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hi"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_persists_token_record_in_assistant_events() {
        let ctx = make_text_context("Hello!");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hi"})), &ctx)
            .await
            .unwrap();

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;

        let events = ctx
            .event_store
            .get_events_by_type(&sid, &["message.assistant"], None)
            .unwrap();
        assert!(!events.is_empty(), "expected at least one message.assistant event");
        let payload: Value = serde_json::from_str(&events[0].payload).unwrap();
        assert!(
            payload["tokenRecord"]["source"]["rawInputTokens"].is_number(),
            "tokenRecord.source.rawInputTokens should be a number, got: {}",
            payload["tokenRecord"]
        );
    }
}
