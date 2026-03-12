//! Agent handlers: prompt, abort, getState.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;
#[cfg(test)]
use tron_events::EventType;

use crate::rpc::agent_commands::AgentCommandService;
use crate::rpc::agent_queries::AgentQueryService;
use crate::rpc::context::RpcContext;
use crate::rpc::errors::RpcError;
use crate::rpc::handlers::{opt_array, opt_string, require_string_param};
use crate::rpc::registry::MethodHandler;
#[path = "agent_prompt_runtime.rs"]
mod prompt_runtime;
#[path = "agent_prompt_service.rs"]
mod prompt_service;

use prompt_runtime::extract_skills;
#[cfg(test)]
use prompt_runtime::{
    build_user_event_payload, format_subagent_results, get_pending_subagent_results,
};
use prompt_service::{PromptRequest, spawn_prompt_run};

/// Submit a prompt to the agent for a session.
pub struct PromptHandler;

#[async_trait]
impl MethodHandler for PromptHandler {
    #[instrument(skip(self, ctx), fields(method = "agent.prompt", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let prompt = require_string_param(params.as_ref(), "prompt")?;

        crate::rpc::validation::validate_string_param(
            &prompt,
            "prompt",
            crate::rpc::validation::MAX_PROMPT_LENGTH,
        )?;

        // Extract optional extra params
        let reasoning_level = opt_string(params.as_ref(), "reasoningLevel");
        let images = opt_array(params.as_ref(), "images").cloned();
        let attachments = opt_array(params.as_ref(), "attachments").cloned();
        let raw_skills_json = opt_array(params.as_ref(), "skills").cloned();
        let raw_spells_json = opt_array(params.as_ref(), "spells").cloned();
        let device_context = opt_string(params.as_ref(), "deviceContext");
        let skills = {
            let tmp = raw_skills_json.clone().map(Value::Array);
            let v = extract_skills(tmp.as_ref());
            if v.is_empty() { None } else { Some(v) }
        };
        let spells = {
            let tmp = raw_spells_json.clone().map(Value::Array);
            let v = extract_skills(tmp.as_ref());
            if v.is_empty() { None } else { Some(v) }
        };

        // Verify the session exists and get its details
        let session = AgentCommandService::load_prompt_session(ctx, &session_id).await?;

        let deps = ctx
            .agent_deps
            .as_ref()
            .ok_or_else(|| RpcError::NotAvailable {
                message: "Agent execution dependencies are not configured".into(),
            })?;

        let run_id = uuid::Uuid::now_v7().to_string();

        // Register the run with the orchestrator (tracks CancellationToken).
        // If the session already has an active run, this returns an error.
        let started_run = ctx
            .orchestrator
            .begin_run(&session_id, &run_id)
            .map_err(|e| RpcError::Custom {
                code: e.category().to_uppercase(),
                message: e.to_string(),
                details: None,
            })?;
        spawn_prompt_run(
            ctx,
            deps,
            &session,
            started_run,
            run_id.clone(),
            PromptRequest {
                session_id,
                prompt,
                reasoning_level,
                images,
                attachments,
                skills,
                spells,
                raw_skills_json,
                raw_spells_json,
                device_context,
            },
        );

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
        AgentCommandService::abort(ctx, &session_id)
    }
}

/// Get the current agent state for a session.
pub struct GetAgentStateHandler;

#[async_trait]
impl MethodHandler for GetAgentStateHandler {
    #[instrument(skip(self, ctx), fields(method = "agent.getState", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        AgentQueryService::get_state(ctx, session_id).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::context::AgentDeps;
    use crate::rpc::handlers::session::CreateSessionHandler;
    use crate::rpc::handlers::test_helpers::{FixedProviderFactory, make_test_context};
    use futures::stream;
    use serde_json::json;
    use std::sync::Arc;
    use tokio_util::sync::CancellationToken;
    use tron_core::content::AssistantContent;
    use tron_core::events::{AssistantMessage, StreamEvent};
    use tron_core::messages::TokenUsage;
    use tron_llm::models::types::Provider as ProviderKind;
    use tron_llm::provider::{Provider, ProviderError, ProviderStreamOptions, StreamEventStream};
    use tron_tools::registry::ToolRegistry;

    use crate::device::{DeviceRequestBroker, DeviceRequestError};
    use crate::websocket::broadcast::BroadcastManager;

    // ── extract_skills tests ──

    #[test]
    fn skills_extracted_from_object_format() {
        let params = json!({"skills": [{"name": "my-skill", "source": "global"}]});
        let skills = extract_skills(params.get("skills"));
        assert_eq!(skills, vec!["my-skill"]);
    }

    #[test]
    fn skills_extracted_from_string_format() {
        let params = json!({"skills": ["my-skill"]});
        let skills = extract_skills(params.get("skills"));
        assert_eq!(skills, vec!["my-skill"]);
    }

    #[test]
    fn skills_extracted_mixed_format() {
        let params = json!({"skills": [{"name": "a", "source": "global"}, "b"]});
        let skills = extract_skills(params.get("skills"));
        assert_eq!(skills, vec!["a", "b"]);
    }

    #[test]
    fn skills_extracted_empty_array() {
        let params = json!({"skills": []});
        let skills = extract_skills(params.get("skills"));
        assert!(skills.is_empty());
    }

    #[test]
    fn skills_extracted_none() {
        let skills = extract_skills(None);
        assert!(skills.is_empty());
    }

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
        fn provider_type(&self) -> ProviderKind {
            ProviderKind::Anthropic
        }
        fn model(&self) -> &'static str {
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
            provider_factory: Arc::new(FixedProviderFactory(Arc::new(TextProvider::new(text)))),
            tool_factory: Arc::new(ToolRegistry::new),
            guardrails: None,
            hooks: None,
        });
        ctx
    }

    /// A mock provider that yields partial text then sleeps, allowing cancellation.
    struct SlowProvider;
    #[async_trait]
    impl Provider for SlowProvider {
        fn provider_type(&self) -> ProviderKind {
            ProviderKind::Anthropic
        }
        fn model(&self) -> &'static str {
            "mock"
        }
        async fn stream(
            &self,
            _c: &tron_core::messages::Context,
            _o: &ProviderStreamOptions,
        ) -> Result<StreamEventStream, ProviderError> {
            let s = async_stream::stream! {
                yield Ok(StreamEvent::Start);
                yield Ok(StreamEvent::TextDelta { delta: "partial text".into() });
                tokio::time::sleep(tokio::time::Duration::from_secs(30)).await;
                yield Ok(StreamEvent::Done {
                    message: AssistantMessage {
                        content: vec![AssistantContent::text("partial text")],
                        token_usage: Some(TokenUsage {
                            input_tokens: 10,
                            output_tokens: 3,
                            ..Default::default()
                        }),
                    },
                    stop_reason: "end_turn".into(),
                });
            };
            Ok(Box::pin(s))
        }
    }

    fn make_slow_context() -> RpcContext {
        let mut ctx = make_test_context();
        ctx.agent_deps = Some(AgentDeps {
            provider_factory: Arc::new(FixedProviderFactory(Arc::new(SlowProvider))),
            tool_factory: Arc::new(ToolRegistry::new),
            guardrails: None,
            hooks: None,
        });
        ctx
    }

    struct SignalledSlowProvider {
        ready: Arc<tokio::sync::Notify>,
    }

    #[async_trait]
    impl Provider for SignalledSlowProvider {
        fn provider_type(&self) -> ProviderKind {
            ProviderKind::Anthropic
        }
        fn model(&self) -> &'static str {
            "mock"
        }
        async fn stream(
            &self,
            _c: &tron_core::messages::Context,
            _o: &ProviderStreamOptions,
        ) -> Result<StreamEventStream, ProviderError> {
            let ready = self.ready.clone();
            let s = async_stream::stream! {
                yield Ok(StreamEvent::Start);
                yield Ok(StreamEvent::TextDelta { delta: "partial text".into() });
                ready.notify_waiters();
                tokio::time::sleep(tokio::time::Duration::from_secs(30)).await;
                yield Ok(StreamEvent::Done {
                    message: AssistantMessage {
                        content: vec![AssistantContent::text("partial text")],
                        token_usage: Some(TokenUsage {
                            input_tokens: 10,
                            output_tokens: 3,
                            ..Default::default()
                        }),
                    },
                    stop_reason: "end_turn".into(),
                });
            };
            Ok(Box::pin(s))
        }
    }

    fn make_signalled_slow_context(ready: Arc<tokio::sync::Notify>) -> RpcContext {
        let mut ctx = make_test_context();
        ctx.agent_deps = Some(AgentDeps {
            provider_factory: Arc::new(FixedProviderFactory(Arc::new(SignalledSlowProvider {
                ready,
            }))),
            tool_factory: Arc::new(ToolRegistry::new),
            guardrails: None,
            hooks: None,
        });
        ctx
    }

    #[tokio::test]
    async fn prompt_returns_acknowledged() {
        let ctx = make_text_context("Done.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", Some("t"))
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
        let ctx = make_text_context("Done.");
        let sid1 = ctx
            .session_manager
            .create_session("mock", "/tmp/1", Some("t1"))
            .unwrap();
        let sid2 = ctx
            .session_manager
            .create_session("mock", "/tmp/2", Some("t2"))
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
        let ctx = make_slow_context();
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", Some("t"))
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
        let ctx = make_slow_context();
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
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
    async fn abort_active_cancels_pending_device_requests() {
        let mut ctx = make_slow_context();
        let broker = Arc::new(DeviceRequestBroker::new(
            Arc::new(BroadcastManager::new()),
            CancellationToken::new(),
        ));
        ctx.device_request_broker = Some(broker.clone());

        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hi"})), &ctx)
            .await
            .unwrap();

        let broker_for_request = broker.clone();
        let sid_for_request = sid.clone();
        let pending = tokio::spawn(async move {
            broker_for_request
                .request(
                    &sid_for_request,
                    "device.test",
                    json!({"k": "v"}),
                    std::time::Duration::from_secs(5),
                )
                .await
        });

        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        assert_eq!(broker.pending_count(), 1);

        let result = AbortHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["aborted"], true);
        assert_eq!(broker.pending_count(), 0);

        let request_result = pending.await.unwrap();
        assert!(matches!(request_result, Err(DeviceRequestError::Cancelled)));
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
        let ctx = make_slow_context();
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
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
        assert_eq!(result["wasInterrupted"], false);
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
    async fn get_state_returns_cache_read_tokens() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        let result = GetAgentStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert!(result["tokenUsage"]["cacheReadTokens"].is_number());
    }

    #[tokio::test]
    async fn get_state_returns_cache_creation_tokens() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        let result = GetAgentStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert!(result["tokenUsage"]["cacheCreationTokens"].is_number());
    }

    #[tokio::test]
    async fn get_state_cache_tokens_default_zero() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        let result = GetAgentStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["tokenUsage"]["cacheReadTokens"], 0);
        assert_eq!(result["tokenUsage"]["cacheCreationTokens"], 0);
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
        // Wire format uses "input"/"output" not "inputTokens"/"outputTokens"
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

    #[tokio::test]
    async fn get_state_interrupted_when_no_turn_end() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        // Persist an assistant message without a following stream.turn_end
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({"content": [{"type": "text", "text": "hello"}], "turn": 1}),
            parent_id: None,
        });

        let result = GetAgentStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["wasInterrupted"], true);
    }

    #[tokio::test]
    async fn get_state_not_interrupted_when_turn_end_follows() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        // Persist an assistant message followed by stream.turn_end
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({"content": [{"type": "text", "text": "hello"}], "turn": 1}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::StreamTurnEnd,
            payload: json!({"turn": 1}),
            parent_id: None,
        });

        let result = GetAgentStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["wasInterrupted"], false);
    }

    // ── Extra prompt params ──

    #[tokio::test]
    async fn prompt_accepts_reasoning_level() {
        let ctx = make_text_context("Done.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
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
        let ctx = make_text_context("Done.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
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
        let ctx = make_text_context("Done.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
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
        let ctx = make_text_context("Done.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
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

    // ── Phase 3: prompt parameters with agent execution ──

    #[tokio::test]
    async fn prompt_with_images_creates_multimodal_message() {
        let ctx = make_text_context("Analyzed image.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let result = PromptHandler
            .handle(
                Some(json!({
                    "sessionId": sid,
                    "prompt": "What's in this image?",
                    "images": [{"data": "iVBOR...", "mediaType": "image/png"}]
                })),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_with_reasoning_level_runs_successfully() {
        let ctx = make_text_context("Thought deeply.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let result = PromptHandler
            .handle(
                Some(json!({
                    "sessionId": sid,
                    "prompt": "Think about this",
                    "reasoningLevel": "high"
                })),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_accepts_xhigh_reasoning_level() {
        let ctx = make_text_context("Done.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();
        let result = PromptHandler
            .handle(
                Some(json!({"sessionId": sid, "prompt": "hi", "reasoningLevel": "xhigh"})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);
    }

    #[tokio::test]
    async fn prompt_accepts_max_reasoning_level() {
        let ctx = make_text_context("Done.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();
        let result = PromptHandler
            .handle(
                Some(json!({"sessionId": sid, "prompt": "hi", "reasoningLevel": "max"})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);
    }

    #[tokio::test]
    async fn prompt_with_xhigh_reasoning_runs_successfully() {
        let ctx = make_text_context("Deep reasoning.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let result = PromptHandler
            .handle(
                Some(json!({
                    "sessionId": sid,
                    "prompt": "Think very hard",
                    "reasoningLevel": "xhigh"
                })),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_with_skills_runs_successfully() {
        let ctx = make_text_context("Using skills.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let result = PromptHandler
            .handle(
                Some(json!({
                    "sessionId": sid,
                    "prompt": "Search the web",
                    "skills": ["web-search", "code-review"]
                })),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_empty_images_no_multimodal() {
        let ctx = make_text_context("Plain text.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let result = PromptHandler
            .handle(
                Some(json!({
                    "sessionId": sid,
                    "prompt": "hello",
                    "images": []
                })),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
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
    async fn prompt_without_agent_deps_returns_not_available() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        let err = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hi"})), &ctx)
            .await
            .unwrap_err();

        assert_eq!(err.code(), "NOT_AVAILABLE");
        assert!(!ctx.orchestrator.has_active_run(&sid));
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
            fn provider_type(&self) -> ProviderKind {
                ProviderKind::Anthropic
            }
            fn model(&self) -> &'static str {
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
            provider_factory: Arc::new(FixedProviderFactory(Arc::new(ErrorProvider))),
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
    async fn prompt_cleans_run_on_panic() {
        struct PanicProvider;
        #[async_trait]
        impl Provider for PanicProvider {
            fn provider_type(&self) -> ProviderKind {
                ProviderKind::Anthropic
            }
            fn model(&self) -> &'static str {
                "mock"
            }
            async fn stream(
                &self,
                _c: &tron_core::messages::Context,
                _o: &ProviderStreamOptions,
            ) -> Result<StreamEventStream, ProviderError> {
                panic!("provider panicked");
            }
        }

        let mut ctx = make_test_context();
        ctx.agent_deps = Some(AgentDeps {
            provider_factory: Arc::new(FixedProviderFactory(Arc::new(PanicProvider))),
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
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    // ── Fix 3: agent.error emission tests ──

    #[tokio::test]
    async fn prompt_error_emits_agent_error_event() {
        struct ErrorProvider;
        #[async_trait]
        impl Provider for ErrorProvider {
            fn provider_type(&self) -> ProviderKind {
                ProviderKind::Anthropic
            }
            fn model(&self) -> &'static str {
                "mock"
            }
            async fn stream(
                &self,
                _c: &tron_core::messages::Context,
                _o: &ProviderStreamOptions,
            ) -> Result<StreamEventStream, ProviderError> {
                Err(ProviderError::Auth {
                    message: "authentication_error: invalid key".into(),
                })
            }
        }

        let mut ctx = make_test_context();
        ctx.agent_deps = Some(AgentDeps {
            provider_factory: Arc::new(FixedProviderFactory(Arc::new(ErrorProvider))),
            tool_factory: Arc::new(ToolRegistry::new),
            guardrails: None,
            hooks: None,
        });

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

        let mut found_error = false;
        while let Ok(event) = rx.try_recv() {
            if let tron_core::events::TronEvent::Error {
                error,
                provider,
                category,
                retryable,
                model,
                ..
            } = &event
            {
                assert!(error.contains("authentication_error"));
                assert_eq!(provider.as_deref(), Some("anthropic"));
                assert_eq!(category.as_deref(), Some("authentication"));
                assert_eq!(*retryable, Some(false));
                assert!(model.is_some());
                found_error = true;
            }
        }
        assert!(found_error, "expected TronEvent::Error in broadcast");
    }

    #[tokio::test]
    async fn prompt_error_agent_error_has_rate_limit_category() {
        struct RateLimitProvider;
        #[async_trait]
        impl Provider for RateLimitProvider {
            fn provider_type(&self) -> ProviderKind {
                ProviderKind::Anthropic
            }
            fn model(&self) -> &'static str {
                "mock"
            }
            async fn stream(
                &self,
                _c: &tron_core::messages::Context,
                _o: &ProviderStreamOptions,
            ) -> Result<StreamEventStream, ProviderError> {
                Err(ProviderError::RateLimited {
                    message: "429 Too Many Requests".into(),
                    retry_after_ms: 0,
                })
            }
        }

        let mut ctx = make_test_context();
        ctx.agent_deps = Some(AgentDeps {
            provider_factory: Arc::new(FixedProviderFactory(Arc::new(RateLimitProvider))),
            tool_factory: Arc::new(ToolRegistry::new),
            guardrails: None,
            hooks: None,
        });

        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();
        let mut rx = ctx.orchestrator.subscribe();

        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hi"})), &ctx)
            .await
            .unwrap();

        // With retry enabled (default: 1 retry, 1000ms base delay), the error
        // propagates after retry exhaustion. Wait long enough for that.
        tokio::time::sleep(std::time::Duration::from_millis(4000)).await;

        let mut found_error = false;
        while let Ok(event) = rx.try_recv() {
            if let tron_core::events::TronEvent::Error {
                category,
                retryable,
                ..
            } = &event
            {
                assert_eq!(category.as_deref(), Some("rate_limit"));
                assert_eq!(*retryable, Some(true));
                found_error = true;
            }
        }
        assert!(
            found_error,
            "expected TronEvent::Error with rate_limit category"
        );
    }

    #[tokio::test]
    async fn prompt_success_no_agent_error() {
        let ctx = make_text_context("Hello!");
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

        while let Ok(event) = rx.try_recv() {
            assert!(
                !matches!(&event, tron_core::events::TronEvent::Error { .. }),
                "no TronEvent::Error expected on success"
            );
        }
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
    async fn prompt_emits_session_updated_after_completion() {
        let ctx = make_text_context("Hello session update!");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let mut rx = ctx.orchestrator.subscribe();

        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hi"})), &ctx)
            .await
            .unwrap();

        let found = tokio::time::timeout(std::time::Duration::from_secs(2), async {
            loop {
                match rx.try_recv() {
                    Ok(tron_core::events::TronEvent::SessionUpdated { base, .. }) => {
                        if base.session_id == sid {
                            break true;
                        }
                    }
                    Ok(_) | Err(tokio::sync::broadcast::error::TryRecvError::Lagged(_)) => {}
                    Err(tokio::sync::broadcast::error::TryRecvError::Empty) => {
                        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
                    }
                    Err(err) => panic!("unexpected broadcast error: {err}"),
                }
            }
        })
        .await
        .expect("timed out waiting for session_updated");

        assert!(found);
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

        // agent_end MUST come before agent_ready (client ordering dependency)
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
            .handle(
                Some(json!({"sessionId": sid, "prompt": "first message"})),
                &ctx,
            )
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
    async fn prompt_reuses_warmed_context_artifacts() {
        let tmp = tempfile::tempdir().unwrap();
        let scoped_rules_dir = tmp.path().join("src").join(".claude");
        std::fs::create_dir_all(&scoped_rules_dir).unwrap();
        std::fs::write(scoped_rules_dir.join("AGENTS.md"), "# Scoped Rules").unwrap();

        let ctx = make_text_context("Done.");
        let result = CreateSessionHandler
            .handle(
                Some(json!({"workingDirectory": tmp.path().to_string_lossy()})),
                &ctx,
            )
            .await
            .unwrap();
        let sid = result["sessionId"].as_str().unwrap().to_string();

        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            loop {
                if ctx.context_artifacts.rules_index_builds() == 1 {
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_millis(25)).await;
            }
        })
        .await
        .expect("timed out waiting for warmup to populate rules cache");

        let builds_before_prompt = ctx.context_artifacts.rules_index_builds();

        let prompt = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hi"})), &ctx)
            .await
            .unwrap();
        assert_eq!(prompt["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert_eq!(
            ctx.context_artifacts.rules_index_builds(),
            builds_before_prompt,
            "prompt should reuse the session.create warmup rules-index build"
        );
    }

    // ── Fix 4+6: skill/spell loading tests ──

    fn register_test_skill(ctx: &RpcContext, name: &str, content: &str) {
        let mut registry = ctx.skill_registry.write();
        registry.insert(tron_skills::types::SkillMetadata {
            name: name.to_string(),
            display_name: name.to_string(),
            description: format!("{name} skill"),
            content: content.to_string(),
            frontmatter: tron_skills::types::SkillFrontmatter::default(),
            source: tron_skills::types::SkillSource::Global,
            path: String::new(),
            skill_md_path: String::new(),
            additional_files: Vec::new(),
            last_modified: 0,
        });
    }

    #[tokio::test]
    async fn prompt_with_registered_skill_loads_content() {
        let ctx = make_text_context("Done.");
        register_test_skill(&ctx, "web-search", "Search the web using Bing API.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let result = PromptHandler
            .handle(
                Some(json!({"sessionId": sid, "prompt": "search", "skills": ["web-search"]})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_with_unknown_skill_still_works() {
        let ctx = make_text_context("Done.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let result = PromptHandler
            .handle(
                Some(json!({"sessionId": sid, "prompt": "hi", "skills": ["nonexistent"]})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_with_spells_runs_successfully() {
        let ctx = make_text_context("Done.");
        register_test_skill(&ctx, "auto-commit", "Auto commit changes.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let result = PromptHandler
            .handle(
                Some(json!({"sessionId": sid, "prompt": "commit", "spells": ["auto-commit"]})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_with_skills_and_spells_merges() {
        let ctx = make_text_context("Done.");
        register_test_skill(&ctx, "web-search", "Search the web.");
        register_test_skill(&ctx, "auto-commit", "Auto commit.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let result = PromptHandler
            .handle(
                Some(json!({
                    "sessionId": sid,
                    "prompt": "do both",
                    "skills": ["web-search"],
                    "spells": ["auto-commit"]
                })),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_with_duplicate_skill_and_spell_deduplicates() {
        let ctx = make_text_context("Done.");
        register_test_skill(&ctx, "web-search", "Search the web.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let result = PromptHandler
            .handle(
                Some(json!({
                    "sessionId": sid,
                    "prompt": "search",
                    "skills": ["web-search"],
                    "spells": ["web-search"]
                })),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    // ── Fix 5: attachment tests ──

    #[tokio::test]
    async fn prompt_with_pdf_attachment_runs_successfully() {
        let ctx = make_text_context("Received your PDF.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let result = PromptHandler
            .handle(
                Some(json!({
                    "sessionId": sid,
                    "prompt": "summarize this",
                    "attachments": [{
                        "data": "cGRm",
                        "mimeType": "application/pdf",
                        "fileName": "report.pdf"
                    }]
                })),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_with_image_attachment_uses_image_block() {
        let ctx = make_text_context("Nice image.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let result = PromptHandler
            .handle(
                Some(json!({
                    "sessionId": sid,
                    "prompt": "describe this",
                    "attachments": [{
                        "data": "iVBOR",
                        "mimeType": "image/png"
                    }]
                })),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_with_text_attachment_uses_document_block() {
        let ctx = make_text_context("Read your text.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let result = PromptHandler
            .handle(
                Some(json!({
                    "sessionId": sid,
                    "prompt": "review this",
                    "attachments": [{
                        "data": "aGVsbG8=",
                        "mimeType": "text/plain",
                        "fileName": "readme.txt"
                    }]
                })),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_with_mixed_images_and_attachments() {
        let ctx = make_text_context("Got both.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let result = PromptHandler
            .handle(
                Some(json!({
                    "sessionId": sid,
                    "prompt": "look at these",
                    "images": [{"data": "abc", "mediaType": "image/jpeg"}],
                    "attachments": [{"data": "cGRm", "mimeType": "application/pdf", "fileName": "doc.pdf"}]
                })),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_attachment_without_data_skipped() {
        let ctx = make_text_context("No attachment data.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let result = PromptHandler
            .handle(
                Some(json!({
                    "sessionId": sid,
                    "prompt": "handle this",
                    "attachments": [{"mimeType": "text/plain", "fileName": "empty.txt"}]
                })),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    // ── Fix 2: gather_recent_events tests ──

    #[tokio::test]
    async fn gather_recent_events_returns_event_types() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageUser,
            payload: json!({"text": "hello"}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({"content": []}),
            parent_id: None,
        });

        let (types, _calls) = prompt_runtime::gather_recent_events(&ctx.event_store, &sid);
        assert!(types.contains(&"message.user".to_string()));
        assert!(types.contains(&"message.assistant".to_string()));
    }

    #[tokio::test]
    async fn gather_recent_events_since_boundary() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        // Events before boundary
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageUser,
            payload: json!({"text": "old"}),
            parent_id: None,
        });
        // Boundary
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::CompactBoundary,
            payload: json!({"range": {"from": "a", "to": "b"}, "originalTokens": 100, "compactedTokens": 10}),
            parent_id: None,
        });
        // Events after boundary
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({"content": []}),
            parent_id: None,
        });

        let (types, _calls) = prompt_runtime::gather_recent_events(&ctx.event_store, &sid);
        // Should only have events after boundary
        assert!(!types.contains(&"message.user".to_string()));
        assert!(types.contains(&"message.assistant".to_string()));
    }

    #[tokio::test]
    async fn gather_recent_events_no_boundary_returns_all() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageUser,
            payload: json!({"text": "hi"}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({"content": []}),
            parent_id: None,
        });

        let (types, _calls) = prompt_runtime::gather_recent_events(&ctx.event_store, &sid);
        // session.created + message.user + message.assistant = 3
        assert!(
            types.len() >= 2,
            "expected at least 2 events, got {}",
            types.len()
        );
        assert!(types.contains(&"message.user".to_string()));
        assert!(types.contains(&"message.assistant".to_string()));
    }

    #[tokio::test]
    async fn gather_recent_tool_calls_extracts_bash() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::ToolCall,
            payload: json!({"toolCallId": "tc-1", "name": "Bash", "arguments": {"command": "ls -la"}, "turn": 1}),
            parent_id: None,
        });

        let (types, calls) = prompt_runtime::gather_recent_events(&ctx.event_store, &sid);
        assert!(types.contains(&"tool.call".to_string()));
        assert_eq!(calls, vec!["ls -la".to_string()]);
    }

    #[tokio::test]
    async fn gather_recent_tool_calls_skips_non_bash() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::ToolCall,
            payload: json!({"toolCallId": "tc-1", "name": "Read", "arguments": {"path": "/tmp"}, "turn": 1}),
            parent_id: None,
        });

        let (_types, calls) = prompt_runtime::gather_recent_events(&ctx.event_store, &sid);
        assert!(calls.is_empty());
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
        assert!(
            !events.is_empty(),
            "expected at least one message.assistant event"
        );
        let payload: Value = serde_json::from_str(&events[0].payload).unwrap();
        assert!(
            payload["tokenRecord"]["source"]["rawInputTokens"].is_number(),
            "tokenRecord.source.rawInputTokens should be a number, got: {}",
            payload["tokenRecord"]
        );
    }

    // ── Interrupted session persistence tests ──

    #[tokio::test]
    async fn interrupted_run_persists_notification_event() {
        let ctx = make_slow_context();
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hello"})), &ctx)
            .await
            .unwrap();

        // Wait for the stream to start yielding
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;

        // Abort the session
        let _ = AbortHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();

        // Wait for the background task to finish
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;

        let events = ctx
            .event_store
            .get_events_by_type(&sid, &["notification.interrupted"], None)
            .unwrap();
        assert_eq!(
            events.len(),
            1,
            "expected one notification.interrupted event"
        );

        let payload: Value = serde_json::from_str(&events[0].payload).unwrap();
        assert!(payload.get("timestamp").is_some());
        assert!(payload.get("turn").is_some());
    }

    #[tokio::test]
    async fn interrupted_run_persists_partial_assistant_message() {
        let ready = Arc::new(tokio::sync::Notify::new());
        let ctx = make_signalled_slow_context(ready.clone());
        let tempdir = tempfile::tempdir().unwrap();
        let sid = ctx
            .session_manager
            .create_session("mock", tempdir.path().to_str().unwrap(), None)
            .unwrap();

        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hello"})), &ctx)
            .await
            .unwrap();

        tokio::time::timeout(std::time::Duration::from_secs(10), async {
            ready.notified().await;
        })
        .await
        .expect("timed out waiting for first text delta");

        let _ = AbortHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();

        tokio::time::sleep(std::time::Duration::from_millis(500)).await;

        let events = ctx
            .event_store
            .get_events_by_type(&sid, &["message.assistant"], None)
            .unwrap();
        assert_eq!(events.len(), 1, "expected one message.assistant event");

        let payload: Value = serde_json::from_str(&events[0].payload).unwrap();
        assert_eq!(payload["stopReason"], "interrupted");
        assert_eq!(payload["interrupted"], true);
        let content = payload["content"].as_array().unwrap();
        assert!(!content.is_empty(), "content should contain partial text");
    }

    #[tokio::test]
    async fn normal_run_does_not_persist_interrupted_notification() {
        let ctx = make_text_context("hello world");
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
            .get_events_by_type(&sid, &["notification.interrupted"], None)
            .unwrap();
        assert_eq!(
            events.len(),
            0,
            "normal run should not have notification.interrupted"
        );
    }

    // ── get_pending_subagent_results tests ──

    fn make_event_store() -> Arc<tron_events::EventStore> {
        let pool = tron_events::new_in_memory(&tron_events::ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = tron_events::run_migrations(&conn).unwrap();
        }
        Arc::new(tron_events::EventStore::new(pool))
    }

    #[test]
    fn get_pending_no_notifications_returns_empty() {
        let store = make_event_store();
        let sid = store
            .create_session("mock", "/tmp", None, None, None)
            .unwrap()
            .session
            .id;

        let results = get_pending_subagent_results(&store, &sid);
        assert!(results.is_empty());
    }

    #[test]
    fn get_pending_with_notification_returns_it() {
        let store = make_event_store();
        let sid = store
            .create_session("mock", "/tmp", None, None, None)
            .unwrap()
            .session
            .id;

        let _ = store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: EventType::NotificationSubagentResult,
                payload: json!({
                    "parentSessionId": sid,
                    "subagentSessionId": "child-1",
                    "task": "research",
                    "resultSummary": "done",
                    "success": true,
                    "totalTurns": 3,
                    "duration": 5000,
                    "tokenUsage": {},
                    "completedAt": "2026-01-01T00:00:00Z",
                    "output": "result text"
                }),
                parent_id: None,
            })
            .unwrap();

        let results = get_pending_subagent_results(&store, &sid);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].1["task"], "research");
    }

    #[test]
    fn get_pending_skips_consumed() {
        let store = make_event_store();
        let sid = store
            .create_session("mock", "/tmp", None, None, None)
            .unwrap()
            .session
            .id;

        let notification = store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: EventType::NotificationSubagentResult,
                payload: json!({
                    "parentSessionId": sid,
                    "subagentSessionId": "child-1",
                    "task": "research",
                    "resultSummary": "done",
                    "success": true,
                    "totalTurns": 3,
                    "duration": 5000,
                    "tokenUsage": {},
                    "completedAt": "2026-01-01T00:00:00Z",
                    "output": "result text"
                }),
                parent_id: None,
            })
            .unwrap();

        // Mark it as consumed
        let _ = store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: EventType::SubagentResultsConsumed,
                payload: json!({
                    "consumedEventIds": [notification.id],
                    "count": 1
                }),
                parent_id: None,
            })
            .unwrap();

        let results = get_pending_subagent_results(&store, &sid);
        assert!(results.is_empty());
    }

    #[test]
    fn get_pending_partial_consumed() {
        let store = make_event_store();
        let sid = store
            .create_session("mock", "/tmp", None, None, None)
            .unwrap()
            .session
            .id;

        let n1 = store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: EventType::NotificationSubagentResult,
                payload: json!({
                    "parentSessionId": sid,
                    "subagentSessionId": "child-1",
                    "task": "task-1",
                    "resultSummary": "done",
                    "success": true,
                    "totalTurns": 1,
                    "duration": 1000,
                    "tokenUsage": {},
                    "completedAt": "2026-01-01T00:00:00Z"
                }),
                parent_id: None,
            })
            .unwrap();

        let _n2 = store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: EventType::NotificationSubagentResult,
                payload: json!({
                    "parentSessionId": sid,
                    "subagentSessionId": "child-2",
                    "task": "task-2",
                    "resultSummary": "done",
                    "success": true,
                    "totalTurns": 2,
                    "duration": 2000,
                    "tokenUsage": {},
                    "completedAt": "2026-01-01T00:00:00Z"
                }),
                parent_id: None,
            })
            .unwrap();

        // Consume only n1
        let _ = store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: EventType::SubagentResultsConsumed,
                payload: json!({
                    "consumedEventIds": [n1.id],
                    "count": 1
                }),
                parent_id: None,
            })
            .unwrap();

        let results = get_pending_subagent_results(&store, &sid);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].1["task"], "task-2");
    }

    #[test]
    fn get_pending_multiple_consumption_events() {
        let store = make_event_store();
        let sid = store
            .create_session("mock", "/tmp", None, None, None)
            .unwrap()
            .session
            .id;

        // Three notifications
        let n1 = store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: EventType::NotificationSubagentResult,
                payload: json!({
                    "parentSessionId": sid,
                    "subagentSessionId": "child-1",
                    "task": "task-1",
                    "resultSummary": "done",
                    "success": true,
                    "totalTurns": 1,
                    "duration": 1000,
                    "tokenUsage": {},
                    "completedAt": "2026-01-01T00:00:00Z"
                }),
                parent_id: None,
            })
            .unwrap();

        let n2 = store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: EventType::NotificationSubagentResult,
                payload: json!({
                    "parentSessionId": sid,
                    "subagentSessionId": "child-2",
                    "task": "task-2",
                    "resultSummary": "done",
                    "success": true,
                    "totalTurns": 2,
                    "duration": 2000,
                    "tokenUsage": {},
                    "completedAt": "2026-01-01T00:00:00Z"
                }),
                parent_id: None,
            })
            .unwrap();

        let _n3 = store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: EventType::NotificationSubagentResult,
                payload: json!({
                    "parentSessionId": sid,
                    "subagentSessionId": "child-3",
                    "task": "task-3",
                    "resultSummary": "done",
                    "success": true,
                    "totalTurns": 3,
                    "duration": 3000,
                    "tokenUsage": {},
                    "completedAt": "2026-01-01T00:00:00Z"
                }),
                parent_id: None,
            })
            .unwrap();

        // Two separate consumption events: first consumes n1, second consumes n2
        let _ = store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: EventType::SubagentResultsConsumed,
                payload: json!({
                    "consumedEventIds": [n1.id],
                    "count": 1
                }),
                parent_id: None,
            })
            .unwrap();

        let _ = store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: EventType::SubagentResultsConsumed,
                payload: json!({
                    "consumedEventIds": [n2.id],
                    "count": 1
                }),
                parent_id: None,
            })
            .unwrap();

        // Only n3 should remain (union of consumed IDs across both events)
        let results = get_pending_subagent_results(&store, &sid);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].1["task"], "task-3");
    }

    // ── Event persistence integration tests ──

    #[tokio::test]
    async fn prompt_text_only_event_has_string_content() {
        let ctx = make_text_context("Reply.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hello"})), &ctx)
            .await
            .unwrap();

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;

        let events = ctx
            .event_store
            .get_events_by_type(&sid, &["message.user"], None)
            .unwrap();
        assert!(!events.is_empty(), "expected message.user event");
        let payload: Value = serde_json::from_str(&events[0].payload).unwrap();
        assert_eq!(payload["content"], "hello");
        assert!(payload.get("imageCount").is_none());
        assert!(payload.get("skills").is_none());
    }

    #[tokio::test]
    async fn prompt_with_images_event_has_content_blocks() {
        let ctx = make_text_context("I see the image.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let _ = PromptHandler
            .handle(
                Some(json!({
                    "sessionId": sid,
                    "prompt": "look at this",
                    "images": [
                        {"data": "base64img", "mediaType": "image/png"}
                    ]
                })),
                &ctx,
            )
            .await
            .unwrap();

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;

        let events = ctx
            .event_store
            .get_events_by_type(&sid, &["message.user"], None)
            .unwrap();
        assert!(!events.is_empty(), "expected message.user event");
        let payload: Value = serde_json::from_str(&events[0].payload).unwrap();
        let content = payload["content"]
            .as_array()
            .expect("content should be array");
        assert_eq!(content.len(), 2);
        assert_eq!(content[0]["type"], "text");
        assert_eq!(content[1]["type"], "image");
        assert_eq!(content[1]["data"], "base64img");
        assert_eq!(payload["imageCount"], 1);
    }

    #[tokio::test]
    async fn prompt_with_skills_event_has_skills_array() {
        let ctx = make_text_context("Using skill.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let _ = PromptHandler
            .handle(
                Some(json!({
                    "sessionId": sid,
                    "prompt": "use this skill",
                    "skills": [{"name": "my-skill", "source": "global", "displayName": "My Skill"}]
                })),
                &ctx,
            )
            .await
            .unwrap();

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;

        let events = ctx
            .event_store
            .get_events_by_type(&sid, &["message.user"], None)
            .unwrap();
        assert!(!events.is_empty(), "expected message.user event");
        let payload: Value = serde_json::from_str(&events[0].payload).unwrap();
        assert_eq!(payload["content"], "use this skill"); // text-only
        let skills = payload["skills"]
            .as_array()
            .expect("skills should be array");
        assert_eq!(skills.len(), 1);
        assert_eq!(skills[0]["name"], "my-skill");
    }

    // ── format_subagent_results tests ──

    #[test]
    fn format_subagent_results_empty_returns_none() {
        assert!(format_subagent_results(&[]).is_none());
    }

    #[test]
    fn format_subagent_results_success() {
        let results = vec![(
            "evt-1".to_string(),
            json!({
                "subagentSessionId": "child-1",
                "task": "research task",
                "success": true,
                "totalTurns": 3,
                "duration": 5000,
                "output": "Found the answer."
            }),
        )];
        let formatted = format_subagent_results(&results).unwrap();
        assert!(formatted.contains("Completed Sub-Agent Results"));
        assert!(formatted.contains("research task"));
        assert!(formatted.contains("Completed"));
        assert!(formatted.contains("Found the answer."));
        assert!(formatted.contains("[+]"));
    }

    #[test]
    fn format_subagent_results_failure() {
        let results = vec![(
            "evt-1".to_string(),
            json!({
                "subagentSessionId": "child-1",
                "task": "failing task",
                "success": false,
                "totalTurns": 1,
                "duration": 500,
                "output": "Auth error"
            }),
        )];
        let formatted = format_subagent_results(&results).unwrap();
        assert!(formatted.contains("Failed"));
        assert!(formatted.contains("[x]"));
    }

    #[test]
    fn format_subagent_results_truncates_long_output() {
        let long_output = "x".repeat(3000);
        let results = vec![(
            "evt-1".to_string(),
            json!({
                "subagentSessionId": "child-1",
                "task": "task",
                "success": true,
                "totalTurns": 1,
                "duration": 100,
                "output": long_output
            }),
        )];
        let formatted = format_subagent_results(&results).unwrap();
        assert!(formatted.contains("[Output truncated]"));
        assert!(formatted.len() < long_output.len());
    }

    #[test]
    fn format_subagent_results_multiple() {
        let results = vec![
            (
                "evt-1".to_string(),
                json!({
                    "subagentSessionId": "child-1",
                    "task": "task-1",
                    "success": true,
                    "totalTurns": 1,
                    "duration": 100,
                    "output": "out-1"
                }),
            ),
            (
                "evt-2".to_string(),
                json!({
                    "subagentSessionId": "child-2",
                    "task": "task-2",
                    "success": false,
                    "totalTurns": 2,
                    "duration": 200,
                    "output": "out-2"
                }),
            ),
        ];
        let formatted = format_subagent_results(&results).unwrap();
        assert!(formatted.contains("task-1"));
        assert!(formatted.contains("task-2"));
        assert!(formatted.contains("out-1"));
        assert!(formatted.contains("out-2"));
    }

    // ── build_user_event_payload tests ──

    #[test]
    fn payload_text_only() {
        let payload = build_user_event_payload("hello", None, None, None, None);
        assert_eq!(payload["content"], "hello");
        assert!(payload.get("imageCount").is_none());
        assert!(payload.get("skills").is_none());
        assert!(payload.get("spells").is_none());
    }

    #[test]
    fn payload_with_single_image() {
        let images = vec![json!({"data": "base64img", "mediaType": "image/png"})];
        let payload = build_user_event_payload("look", Some(&images), None, None, None);
        let content = payload["content"].as_array().unwrap();
        assert_eq!(content.len(), 2);
        assert_eq!(content[0]["type"], "text");
        assert_eq!(content[0]["text"], "look");
        assert_eq!(content[1]["type"], "image");
        assert_eq!(content[1]["data"], "base64img");
        assert_eq!(content[1]["mimeType"], "image/png");
        assert_eq!(payload["imageCount"], 1);
    }

    #[test]
    fn payload_with_multiple_images() {
        let images = vec![
            json!({"data": "img1", "mediaType": "image/png"}),
            json!({"data": "img2", "mediaType": "image/jpeg"}),
            json!({"data": "img3", "mediaType": "image/webp"}),
        ];
        let payload = build_user_event_payload("see", Some(&images), None, None, None);
        let content = payload["content"].as_array().unwrap();
        assert_eq!(content.len(), 4); // text + 3 images
        assert_eq!(payload["imageCount"], 3);
    }

    #[test]
    fn payload_with_document_attachment() {
        let atts = vec![json!({
            "data": "pdfdata",
            "mimeType": "application/pdf",
            "fileName": "report.pdf"
        })];
        let payload = build_user_event_payload("read this", None, Some(&atts), None, None);
        let content = payload["content"].as_array().unwrap();
        assert_eq!(content.len(), 2);
        assert_eq!(content[1]["type"], "document");
        assert_eq!(content[1]["data"], "pdfdata");
        assert_eq!(content[1]["mimeType"], "application/pdf");
        assert_eq!(content[1]["fileName"], "report.pdf");
        assert!(payload.get("imageCount").is_none());
    }

    #[test]
    fn payload_with_image_attachment() {
        let atts = vec![json!({
            "data": "jpgdata",
            "mimeType": "image/jpeg",
            "fileName": "photo.jpg"
        })];
        let payload = build_user_event_payload("see", None, Some(&atts), None, None);
        let content = payload["content"].as_array().unwrap();
        assert_eq!(content.len(), 2);
        assert_eq!(content[1]["type"], "image");
        assert_eq!(content[1]["data"], "jpgdata");
        assert_eq!(content[1]["mimeType"], "image/jpeg");
        assert_eq!(payload["imageCount"], 1);
    }

    #[test]
    fn payload_mixed_images_and_documents() {
        let images = vec![json!({"data": "img1", "mediaType": "image/png"})];
        let atts = vec![
            json!({"data": "img2", "mimeType": "image/jpeg"}),
            json!({"data": "doc1", "mimeType": "application/pdf", "fileName": "f.pdf"}),
        ];
        let payload = build_user_event_payload("mixed", Some(&images), Some(&atts), None, None);
        let content = payload["content"].as_array().unwrap();
        // text + 1 image param + 1 image att + 1 doc att = 4
        assert_eq!(content.len(), 4);
        assert_eq!(payload["imageCount"], 2); // only image blocks
    }

    #[test]
    fn payload_with_skills_only() {
        let skills =
            vec![json!({"name": "my-skill", "source": "global", "displayName": "My Skill"})];
        let payload = build_user_event_payload("hello", None, None, Some(&skills), None);
        assert_eq!(payload["content"], "hello"); // text-only path
        let s = payload["skills"].as_array().unwrap();
        assert_eq!(s.len(), 1);
        assert_eq!(s[0]["name"], "my-skill");
        assert_eq!(s[0]["source"], "global");
    }

    #[test]
    fn payload_with_spells_only() {
        let spells = vec![json!({"name": "my-spell", "source": "global"})];
        let payload = build_user_event_payload("cast", None, None, None, Some(&spells));
        assert_eq!(payload["content"], "cast");
        let s = payload["spells"].as_array().unwrap();
        assert_eq!(s.len(), 1);
        assert_eq!(s[0]["name"], "my-spell");
    }

    #[test]
    fn payload_with_skills_and_images() {
        let images = vec![json!({"data": "img", "mediaType": "image/png"})];
        let skills = vec![json!({"name": "sk", "source": "global"})];
        let spells = vec![json!({"name": "sp", "source": "global"})];
        let payload =
            build_user_event_payload("hi", Some(&images), None, Some(&skills), Some(&spells));
        assert!(payload["content"].is_array()); // multimodal
        assert!(payload["skills"].is_array());
        assert!(payload["spells"].is_array());
    }

    #[test]
    fn payload_empty_images_array() {
        let images: Vec<Value> = vec![];
        let payload = build_user_event_payload("text", Some(&images), None, None, None);
        assert_eq!(payload["content"], "text"); // text-only path
        assert!(payload.get("imageCount").is_none());
    }

    #[test]
    fn payload_empty_attachments_array() {
        let atts: Vec<Value> = vec![];
        let payload = build_user_event_payload("text", None, Some(&atts), None, None);
        assert_eq!(payload["content"], "text");
    }

    #[test]
    fn payload_malformed_image_no_data() {
        let images = vec![json!({"mediaType": "image/png"})]; // missing data
        let payload = build_user_event_payload("oops", Some(&images), None, None, None);
        // Malformed image skipped, falls back to text-only (only text block)
        assert_eq!(payload["content"], "oops");
    }

    #[test]
    fn payload_malformed_image_no_mime() {
        let images = vec![json!({"data": "base64"})]; // missing mediaType/mimeType
        let payload = build_user_event_payload("oops", Some(&images), None, None, None);
        assert_eq!(payload["content"], "oops");
    }

    #[test]
    fn payload_media_type_key_variant() {
        // Clients may send `mediaType`, verify it works
        let images = vec![json!({"data": "d", "mediaType": "image/webp"})];
        let payload = build_user_event_payload("pic", Some(&images), None, None, None);
        let content = payload["content"].as_array().unwrap();
        assert_eq!(content[1]["mimeType"], "image/webp");
    }

    #[test]
    fn payload_document_no_filename() {
        let atts = vec![json!({"data": "docdata", "mimeType": "application/pdf"})];
        let payload = build_user_event_payload("doc", None, Some(&atts), None, None);
        let content = payload["content"].as_array().unwrap();
        assert_eq!(content[1]["type"], "document");
        assert!(content[1].get("fileName").is_none());
    }

    #[test]
    fn payload_empty_skills_not_stored() {
        let skills: Vec<Value> = vec![];
        let payload = build_user_event_payload("hi", None, None, Some(&skills), None);
        assert!(payload.get("skills").is_none());
    }

    #[test]
    fn user_content_override_none_without_multimodal_input() {
        let override_content =
            prompt_runtime::build_user_content_override("hello", "mock", None, None);
        assert!(override_content.is_none());
    }

    #[test]
    fn user_content_override_strips_images_for_non_image_models() {
        let images = vec![json!({"data": "img", "mediaType": "image/png"})];
        let attachments =
            vec![json!({"data": "doc", "mimeType": "application/pdf", "fileName": "spec.pdf"})];

        let override_content = prompt_runtime::build_user_content_override(
            "review",
            "gpt-5.3-codex-spark",
            Some(&images),
            Some(&attachments),
        )
        .expect("expected multimodal override");

        match override_content {
            tron_core::messages::UserMessageContent::Blocks(blocks) => {
                assert_eq!(blocks.len(), 2, "text + document");
                assert!(matches!(
                    blocks[0],
                    tron_core::content::UserContent::Text { .. }
                ));
                assert!(matches!(
                    blocks[1],
                    tron_core::content::UserContent::Document { .. }
                ));
            }
            tron_core::messages::UserMessageContent::Text(text) => {
                panic!("unexpected text override content: {text:?}")
            }
        }
    }

    #[test]
    fn user_content_override_keeps_images_for_image_models() {
        let images = vec![json!({"data": "img", "mediaType": "image/png"})];

        let override_content =
            prompt_runtime::build_user_content_override("review", "gpt-4.1", Some(&images), None)
                .expect("expected multimodal override");

        match override_content {
            tron_core::messages::UserMessageContent::Blocks(blocks) => {
                assert_eq!(blocks.len(), 2, "text + image");
                assert!(matches!(
                    blocks[0],
                    tron_core::content::UserContent::Text { .. }
                ));
                assert!(matches!(
                    blocks[1],
                    tron_core::content::UserContent::Image { .. }
                ));
            }
            tron_core::messages::UserMessageContent::Text(text) => {
                panic!("unexpected text override content: {text:?}")
            }
        }
    }

    // ── Fix: spurious auto-compaction in persistent chat sessions ──

    #[tokio::test]
    async fn gather_recent_events_uses_latest_boundary() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        // Progress signal before first boundary
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::ToolCall,
            payload: json!({"toolCallId": "tc-1", "name": "Bash", "arguments": {"command": "git push origin main"}, "turn": 1}),
            parent_id: None,
        });
        // First boundary
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::CompactBoundary,
            payload: json!({"originalTokens": 1000, "compactedTokens": 100, "reason": "auto"}),
            parent_id: None,
        });
        // Progress signal between boundaries (should also be excluded)
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::ToolCall,
            payload: json!({"toolCallId": "tc-2", "name": "Bash", "arguments": {"command": "cargo test"}, "turn": 2}),
            parent_id: None,
        });
        // Second (latest) boundary
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::CompactBoundary,
            payload: json!({"originalTokens": 2000, "compactedTokens": 200, "reason": "auto"}),
            parent_id: None,
        });
        // Events after latest boundary
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageUser,
            payload: json!({"text": "new prompt"}),
            parent_id: None,
        });

        let (types, calls) = prompt_runtime::gather_recent_events(&ctx.event_store, &sid);
        // Only the message.user after the latest boundary
        assert!(types.contains(&"message.user".to_string()));
        assert!(
            !types.contains(&"tool.call".to_string()),
            "stale tool calls leaked through"
        );
        assert!(
            calls.is_empty(),
            "stale bash commands leaked through: {calls:?}"
        );
    }

    #[tokio::test]
    async fn gather_recent_events_falls_back_to_compact_summary() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        // Progress signal before summary
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::ToolCall,
            payload: json!({"toolCallId": "tc-1", "name": "Bash", "arguments": {"command": "git push origin main"}, "turn": 1}),
            parent_id: None,
        });
        // Only a compact.summary (no boundary — legacy session)
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::CompactSummary,
            payload: json!({"summary": "...", "tokensBefore": 1000, "tokensAfter": 100, "compressionRatio": 0.9}),
            parent_id: None,
        });
        // Events after summary
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageUser,
            payload: json!({"text": "new prompt"}),
            parent_id: None,
        });

        let (types, calls) = prompt_runtime::gather_recent_events(&ctx.event_store, &sid);
        assert!(types.contains(&"message.user".to_string()));
        assert!(
            !types.contains(&"tool.call".to_string()),
            "pre-summary tool call leaked"
        );
        assert!(
            calls.is_empty(),
            "pre-summary bash commands leaked: {calls:?}"
        );
    }

    #[tokio::test]
    async fn stale_git_push_excluded_after_boundary() {
        // Regression test: git push from prior interaction should not trigger compaction
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        // Prior interaction: git push
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::ToolCall,
            payload: json!({"toolCallId": "tc-1", "name": "Bash", "arguments": {"command": "git push origin main"}, "turn": 1}),
            parent_id: None,
        });
        // Compaction boundary after that interaction
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::CompactBoundary,
            payload: json!({"originalTokens": 5000, "compactedTokens": 500, "reason": "auto"}),
            parent_id: None,
        });
        // New interaction: simple message exchange (no progress signals)
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageUser,
            payload: json!({"text": "what time is it?"}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({"content": []}),
            parent_id: None,
        });

        let (types, calls) = prompt_runtime::gather_recent_events(&ctx.event_store, &sid);
        // The stale git push must not appear
        assert!(
            !calls.iter().any(|c| c.contains("git push")),
            "stale git push should not be visible after boundary: {calls:?}"
        );
        assert!(types.contains(&"message.user".to_string()));
        assert!(types.contains(&"message.assistant".to_string()));
        assert!(!types.contains(&"tool.call".to_string()));
    }
}
