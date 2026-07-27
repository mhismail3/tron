use super::*;
use crate::domains::agent::context::types::ContextManagerConfig;
use crate::domains::model::responder::{
    ModelResponder, ModelResponderInfo, ModelResponse, ModelResponseError, ModelResponseRequest,
    ModelResponseStream,
};
use crate::shared::protocol::content::AssistantContent;
use crate::shared::protocol::events::{AssistantMessage, StreamEvent, TronEvent};
use crate::shared::protocol::messages::{Message, TokenUsage, ToolResultMessageContent};
use async_trait::async_trait;
use futures::stream;
use parking_lot::Mutex;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

struct MockResponder;

#[async_trait]
impl ModelResponder for MockResponder {
    fn info(&self) -> ModelResponderInfo {
        test_responder_info()
    }

    async fn respond(
        &self,
        _request: ModelResponseRequest,
    ) -> Result<ModelResponse, ModelResponseError> {
        let events = vec![
            Ok(StreamEvent::Start),
            Ok(StreamEvent::TextDelta {
                delta: "hello".into(),
            }),
            Ok(StreamEvent::Done {
                message: AssistantMessage {
                    content: vec![AssistantContent::text("hello")],
                    token_usage: None,
                },
                stop_reason: "end_turn".into(),
            }),
        ];
        Ok(model_response(events))
    }
}

struct TokenUsageResponder;

#[async_trait]
impl ModelResponder for TokenUsageResponder {
    fn info(&self) -> ModelResponderInfo {
        test_responder_info()
    }

    async fn respond(
        &self,
        _request: ModelResponseRequest,
    ) -> Result<ModelResponse, ModelResponseError> {
        let events = vec![
            Ok(StreamEvent::Start),
            Ok(StreamEvent::TextDelta {
                delta: "hello".into(),
            }),
            Ok(StreamEvent::Done {
                message: AssistantMessage {
                    content: vec![AssistantContent::text("hello")],
                    token_usage: Some(TokenUsage {
                        input_tokens: 100,
                        output_tokens: 25,
                        ..Default::default()
                    }),
                },
                stop_reason: "end_turn".into(),
            }),
        ];
        Ok(model_response(events))
    }
}

struct DirectWorkerListLoopResponder {
    calls: Arc<AtomicUsize>,
    observed_result: Arc<Mutex<Option<String>>>,
}

struct OrdinarySurfaceResponder {
    calls: Arc<AtomicUsize>,
}

#[async_trait]
impl ModelResponder for OrdinarySurfaceResponder {
    fn info(&self) -> ModelResponderInfo {
        test_responder_info()
    }

    async fn respond(
        &self,
        request: ModelResponseRequest,
    ) -> Result<ModelResponse, ModelResponseError> {
        let names = request
            .context
            .tools
            .as_ref()
            .expect("provider tools")
            .iter()
            .map(|tool| tool.name.as_str())
            .collect::<Vec<_>>();
        assert_eq!(self.calls.fetch_add(1, Ordering::SeqCst), 0);
        assert_eq!(names.len(), 11, "{names:?}");
        assert!(names.contains(&"worker_discover"), "{names:?}");
        for hidden in [
            "worker_upsert",
            "worker_list",
            "worker_inspect",
            "worker_purge",
            "worker_webhook_rotate",
            "worker_stop_all",
        ] {
            assert!(!names.contains(&hidden), "{hidden} leaked into {names:?}");
        }
        let system_prompt = request.context.system_prompt.as_deref().unwrap_or_default();
        assert!(system_prompt.contains("Worker Forge"), "{system_prompt}");
        assert!(system_prompt.contains("Engine Steward"), "{system_prompt}");
        Ok(model_response(vec![
            Ok(StreamEvent::Start),
            Ok(StreamEvent::TextDelta {
                delta: "Ordinary chat retained a small fixed surface.".to_owned(),
            }),
            Ok(StreamEvent::Done {
                message: AssistantMessage {
                    content: vec![AssistantContent::text(
                        "Ordinary chat retained a small fixed surface.",
                    )],
                    token_usage: None,
                },
                stop_reason: "end_turn".to_owned(),
            }),
        ]))
    }
}

#[async_trait]
impl ModelResponder for DirectWorkerListLoopResponder {
    fn info(&self) -> ModelResponderInfo {
        test_responder_info()
    }

    async fn respond(
        &self,
        request: ModelResponseRequest,
    ) -> Result<ModelResponse, ModelResponseError> {
        let context = &request.context;
        let tool_names = context
            .tools
            .as_ref()
            .expect("provider tools")
            .iter()
            .map(|tool| tool.name.as_str())
            .collect::<Vec<_>>();
        assert!(tool_names.contains(&"worker_discover"), "{tool_names:?}");

        let call = self.calls.fetch_add(1, Ordering::SeqCst);
        if call == 0 {
            let arguments = serde_json::Map::from_iter([(
                "query".to_owned(),
                serde_json::json!("worker inventory"),
            )]);
            let events = vec![
                Ok(StreamEvent::Start),
                Ok(StreamEvent::ToolInvocationDraftStart {
                    invocation_id: "tc-primitive-observe".into(),
                    name: "worker_discover".into(),
                }),
                Ok(StreamEvent::ToolInvocationDraftDelta {
                    invocation_id: "tc-primitive-observe".into(),
                    arguments_delta: serde_json::to_string(&arguments).expect("arguments json"),
                }),
                Ok(StreamEvent::ToolInvocationDraftEnd {
                    tool_invocation: crate::shared::protocol::messages::ToolInvocationDraft::new(
                        "tc-primitive-observe",
                        "worker_discover",
                        arguments,
                    ),
                }),
                Ok(StreamEvent::Done {
                    message: AssistantMessage {
                        content: vec![],
                        token_usage: None,
                    },
                    stop_reason: "tool_invocation".into(),
                }),
            ];
            return Ok(model_response(events));
        }

        let observed = context
            .messages
            .iter()
            .find_map(|message| match message {
                Message::ToolResult {
                    invocation_id,
                    content,
                    ..
                } if invocation_id == "tc-primitive-observe" => match content {
                    ToolResultMessageContent::Text(text) => Some(text.clone()),
                    ToolResultMessageContent::Blocks(blocks) => Some(
                        blocks
                            .iter()
                            .filter_map(|block| match block {
                                crate::shared::protocol::content::ToolResultContent::Text {
                                    text,
                                } => Some(text.as_str()),
                                crate::shared::protocol::content::ToolResultContent::Image {
                                    ..
                                } => None,
                            })
                            .collect::<Vec<_>>()
                            .join("\n"),
                    ),
                },
                _ => None,
            })
            .expect("worker_discover result should be in second provider context");
        assert!(observed.contains("workers"), "{observed}");
        *self.observed_result.lock() = Some(observed);

        let events = vec![
            Ok(StreamEvent::Start),
            Ok(StreamEvent::TextDelta {
                delta: "continued after direct worker tool".into(),
            }),
            Ok(StreamEvent::Done {
                message: AssistantMessage {
                    content: vec![AssistantContent::text("continued after direct worker tool")],
                    token_usage: None,
                },
                stop_reason: "end_turn".into(),
            }),
        ];
        Ok(model_response(events))
    }
}

fn test_responder_info() -> ModelResponderInfo {
    ModelResponderInfo {
        provider_type: crate::shared::protocol::messages::Provider::Anthropic,
        provider_name: "anthropic",
        model: "mock-model".to_owned(),
        context_window: 200_000,
    }
}

fn model_response(events: Vec<Result<StreamEvent, ModelResponseError>>) -> ModelResponse {
    ModelResponse {
        info: test_responder_info(),
        stream: Box::pin(stream::iter(events)) as ModelResponseStream,
    }
}

fn test_context_manager() -> ContextManager {
    ContextManager::new(ContextManagerConfig {
        system_prompt: Some("You are a test agent.".into()),
        working_directory: Some("/tmp".into()),
        compaction: crate::domains::agent::context::types::CompactionConfig::default(),
    })
}

fn make_deps_with_host(
    responder: impl ModelResponder + 'static,
    engine_host: crate::engine::EngineHostHandle,
) -> AgentDeps {
    AgentDeps {
        responder: Arc::new(responder),
        context_manager: test_context_manager(),
        compaction_trigger_config:
            crate::domains::agent::context::types::CompactionTriggerConfig::default(),
        invocation_abort_registry: Arc::new(InvocationAbortRegistry::new()),
        engine_host,
    }
}

fn make_deps(responder: impl ModelResponder + 'static) -> AgentDeps {
    make_deps_with_host(
        responder,
        crate::engine::EngineHostHandle::new_in_memory().expect("engine host"),
    )
}

fn make_primitive_loop_deps(
    responder: impl ModelResponder + 'static,
    engine_host: crate::engine::EngineHostHandle,
) -> AgentDeps {
    make_deps_with_host(responder, engine_host)
}

#[tokio::test]
async fn text_only_run_succeeds_without_frozen_tools() {
    let mut agent = TronAgent::new(
        AgentConfig {
            max_turns: 1,
            ..AgentConfig::default()
        },
        make_deps(MockResponder),
        "text-only-run-session".into(),
    );
    let result = agent
        .run(
            "hello",
            crate::domains::agent::r#loop::types::RunContext::default(),
        )
        .await;
    assert!(
        result.error.is_none(),
        "run should succeed: {:?}",
        result.error
    );
}

#[tokio::test]
async fn primitive_loop_calls_direct_worker_tool_observes_result_and_continues() {
    let calls = Arc::new(AtomicUsize::new(0));
    let observed_result = Arc::new(Mutex::new(None));
    let ctx = crate::shared::server::test_support::make_test_context();
    let mut agent = TronAgent::new(
        AgentConfig {
            max_turns: 2,
            ..AgentConfig::default()
        },
        make_primitive_loop_deps(
            DirectWorkerListLoopResponder {
                calls: calls.clone(),
                observed_result: observed_result.clone(),
            },
            ctx.engine_host.clone(),
        ),
        "primitive-loop-session".into(),
    );
    let result = agent
        .run(
            "list workers and continue",
            crate::domains::agent::r#loop::types::RunContext {
                run_id: Some("primitive-loop-run".into()),
                ..Default::default()
            },
        )
        .await;

    assert!(
        result.error.is_none(),
        "run should succeed: {:?}",
        result.error
    );
    assert_eq!(result.turns_executed, 2);
    assert_eq!(calls.load(Ordering::SeqCst), 2);
    assert!(
        observed_result
            .lock()
            .as_ref()
            .is_some_and(|text| text.contains("workers"))
    );

    let persisted_messages =
        serde_json::to_string(&agent.context_manager().get_messages()).expect("messages");
    assert!(persisted_messages.contains("continued after direct worker tool"));
}

#[tokio::test]
async fn ordinary_chat_keeps_admin_tools_hidden_and_routes_to_worker_owners() {
    let calls = Arc::new(AtomicUsize::new(0));
    let ctx = crate::shared::server::test_support::make_test_context();
    let mut agent = TronAgent::new(
        AgentConfig {
            max_turns: 1,
            ..AgentConfig::default()
        },
        make_primitive_loop_deps(
            OrdinarySurfaceResponder {
                calls: Arc::clone(&calls),
            },
            ctx.engine_host.clone(),
        ),
        "proactive-adaptation-session".into(),
    );

    let result = agent
        .run(
            "Explain how I can inspect and improve one of my workers.",
            crate::domains::agent::r#loop::types::RunContext {
                run_id: Some("proactive-adaptation-run".into()),
                ..Default::default()
            },
        )
        .await;

    assert!(
        result.error.is_none(),
        "agent run failed: {:?}",
        result.error
    );
    assert_eq!(result.turns_executed, 1);
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    let messages = serde_json::to_string(&agent.context_manager().get_messages()).unwrap();
    assert!(messages.contains("small fixed surface"));
}

#[tokio::test]
async fn resumed_session_offset_is_used_for_turn_events_and_token_record() {
    let mut agent = TronAgent::new(
        AgentConfig {
            max_turns: 1,
            ..AgentConfig::default()
        },
        make_deps(TokenUsageResponder),
        "resumed-offset-session".into(),
    );
    agent.set_turn_offset(4);
    let mut events = agent.subscribe();

    let result = agent
        .run(
            "hello",
            crate::domains::agent::r#loop::types::RunContext::default(),
        )
        .await;

    assert_eq!(result.turns_executed, 1);
    let mut turn_start = None;
    let mut response_turn = None;
    let mut response_record_turn = None;
    let mut turn_end = None;
    let mut turn_end_record_turn = None;

    while let Ok(event) = events.try_recv() {
        match event {
            TronEvent::TurnStart { turn, .. } => turn_start = Some(turn),
            TronEvent::ResponseComplete {
                turn, token_record, ..
            } => {
                response_turn = Some(turn);
                response_record_turn = token_record
                    .as_ref()
                    .and_then(|record| record["meta"]["turn"].as_u64())
                    .map(|turn| turn as u32);
            }
            TronEvent::TurnEnd {
                turn, token_record, ..
            } => {
                turn_end = Some(turn);
                turn_end_record_turn = token_record
                    .as_ref()
                    .and_then(|record| record["meta"]["turn"].as_u64())
                    .map(|turn| turn as u32);
            }
            _ => {}
        }
    }

    assert_eq!(turn_start, Some(5));
    assert_eq!(response_turn, Some(5));
    assert_eq!(response_record_turn, Some(5));
    assert_eq!(turn_end, Some(5));
    assert_eq!(turn_end_record_turn, Some(5));
}

#[tokio::test]
async fn exhausted_session_turn_ordinal_fails_without_reusing_max() {
    let mut agent = TronAgent::new(
        AgentConfig {
            max_turns: 1,
            ..AgentConfig::default()
        },
        make_deps(TokenUsageResponder),
        "exhausted-turn-session".into(),
    );
    agent.set_turn_offset(u32::MAX);
    let mut events = agent.subscribe();

    let result = agent
        .run(
            "hello",
            crate::domains::agent::r#loop::types::RunContext::default(),
        )
        .await;

    assert_eq!(result.turns_executed, 0);
    assert_eq!(result.stop_reason, StopReason::Error);
    assert_eq!(
        result.error.as_deref(),
        Some("Session turn ordinal exhausted")
    );
    assert!(
        std::iter::from_fn(|| events.try_recv().ok())
            .all(|event| !matches!(event, TronEvent::TurnStart { .. }))
    );
}
