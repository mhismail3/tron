use super::*;
use crate::domains::agent::runner::context::types::ContextManagerConfig;
use crate::domains::model::providers::models::types::Provider as ProviderKind;
use crate::domains::model::providers::provider::{
    Provider, ProviderError, ProviderStreamOptions, StreamEventStream,
};
use crate::shared::content::AssistantContent;
use crate::shared::events::{AssistantMessage, StreamEvent, TronEvent};
use crate::shared::messages::{CapabilityResultMessageContent, Context, Message, TokenUsage};
use async_trait::async_trait;
use futures::stream;
use parking_lot::Mutex;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

struct MockProvider;

#[async_trait]
impl Provider for MockProvider {
    fn provider_type(&self) -> ProviderKind {
        ProviderKind::Anthropic
    }

    fn model(&self) -> &'static str {
        "mock-model"
    }

    async fn stream(
        &self,
        _context: &crate::shared::messages::Context,
        _options: &ProviderStreamOptions,
    ) -> Result<StreamEventStream, ProviderError> {
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
        Ok(Box::pin(stream::iter(events)))
    }
}

struct TokenUsageProvider;

#[async_trait]
impl Provider for TokenUsageProvider {
    fn provider_type(&self) -> ProviderKind {
        ProviderKind::Anthropic
    }

    fn model(&self) -> &'static str {
        "mock-model"
    }

    async fn stream(
        &self,
        _context: &crate::shared::messages::Context,
        _options: &ProviderStreamOptions,
    ) -> Result<StreamEventStream, ProviderError> {
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
        Ok(Box::pin(stream::iter(events)))
    }
}

struct PrimitiveExecuteLoopProvider {
    calls: Arc<AtomicUsize>,
    observed_result: Arc<Mutex<Option<String>>>,
}

#[async_trait]
impl Provider for PrimitiveExecuteLoopProvider {
    fn provider_type(&self) -> ProviderKind {
        ProviderKind::Anthropic
    }

    fn model(&self) -> &'static str {
        "mock-model"
    }

    async fn stream(
        &self,
        context: &Context,
        _options: &ProviderStreamOptions,
    ) -> Result<StreamEventStream, ProviderError> {
        let capability_names = context
            .capabilities
            .as_ref()
            .expect("provider capabilities")
            .iter()
            .map(|capability| capability.name.as_str())
            .collect::<Vec<_>>();
        assert_eq!(capability_names, ["execute"]);

        let call = self.calls.fetch_add(1, Ordering::SeqCst);
        if call == 0 {
            let mut arguments = serde_json::Map::new();
            let _ = arguments.insert("operation".into(), serde_json::json!("observe"));
            let _ = arguments.insert(
                "input".into(),
                serde_json::json!("primitive loop observed through execute"),
            );
            let events = vec![
                Ok(StreamEvent::Start),
                Ok(StreamEvent::CapabilityInvocationDraftStart {
                    invocation_id: "tc-primitive-observe".into(),
                    name: "execute".into(),
                }),
                Ok(StreamEvent::CapabilityInvocationDraftDelta {
                    invocation_id: "tc-primitive-observe".into(),
                    arguments_delta: serde_json::to_string(&arguments).expect("arguments json"),
                }),
                Ok(StreamEvent::CapabilityInvocationDraftEnd {
                    capability_invocation: crate::shared::messages::CapabilityInvocationDraft::new(
                        "tc-primitive-observe",
                        "execute",
                        arguments,
                    ),
                }),
                Ok(StreamEvent::Done {
                    message: AssistantMessage {
                        content: vec![],
                        token_usage: None,
                    },
                    stop_reason: "capability_invocation".into(),
                }),
            ];
            return Ok(Box::pin(stream::iter(events)));
        }

        let observed = context
            .messages
            .iter()
            .find_map(|message| match message {
                Message::CapabilityResult {
                    invocation_id,
                    content,
                    ..
                } if invocation_id == "tc-primitive-observe" => match content {
                    CapabilityResultMessageContent::Text(text) => Some(text.clone()),
                    CapabilityResultMessageContent::Blocks(blocks) => Some(
                        blocks
                            .iter()
                            .filter_map(|block| match block {
                                crate::shared::content::CapabilityResultContent::Text { text } => {
                                    Some(text.as_str())
                                }
                                crate::shared::content::CapabilityResultContent::Image {
                                    ..
                                } => None,
                            })
                            .collect::<Vec<_>>()
                            .join("\n"),
                    ),
                },
                _ => None,
            })
            .expect("execute result should be in second provider context");
        assert!(
            observed.contains("primitive loop observed through execute"),
            "{observed}"
        );
        *self.observed_result.lock() = Some(observed);

        let events = vec![
            Ok(StreamEvent::Start),
            Ok(StreamEvent::TextDelta {
                delta: "continued after execute".into(),
            }),
            Ok(StreamEvent::Done {
                message: AssistantMessage {
                    content: vec![AssistantContent::text("continued after execute")],
                    token_usage: None,
                },
                stop_reason: "end_turn".into(),
            }),
        ];
        Ok(Box::pin(stream::iter(events)))
    }
}

fn test_context_manager(model: &str) -> ContextManager {
    ContextManager::new(ContextManagerConfig {
        model: model.to_owned(),
        system_prompt: Some("You are a test agent.".into()),
        working_directory: Some("/tmp".into()),
        capabilities: vec![],
        compaction: crate::domains::agent::runner::context::types::CompactionConfig::default(),
    })
}

fn make_deps(provider: impl Provider + 'static) -> AgentDeps {
    AgentDeps {
        provider: Arc::new(provider),
        context_manager: test_context_manager("mock-model"),
        compaction_trigger_config:
            crate::domains::agent::runner::context::types::CompactionTriggerConfig::default(),
        engine_host: None,
    }
}

fn make_primitive_loop_deps(
    provider: impl Provider + 'static,
    engine_host: crate::engine::EngineHostHandle,
) -> AgentDeps {
    AgentDeps {
        engine_host: Some(engine_host),
        ..make_deps(provider)
    }
}

#[test]
fn agent_uses_empty_initial_capability_snapshot() {
    let agent = TronAgent::new(AgentConfig::default(), make_deps(MockProvider), "s1".into());
    assert!(agent.context_manager().model_capability_names().is_empty());
}

#[tokio::test]
async fn text_only_run_succeeds_without_frozen_capabilities() {
    let mut agent = TronAgent::new(
        AgentConfig {
            max_turns: 1,
            ..AgentConfig::default()
        },
        make_deps(MockProvider),
        "s1".into(),
    );
    let result = agent
        .run(
            "hello",
            crate::domains::agent::runner::types::RunContext::default(),
        )
        .await;
    assert!(
        result.error.is_none(),
        "run should succeed: {:?}",
        result.error
    );
}

#[tokio::test]
async fn primitive_loop_calls_execute_observes_result_and_continues() {
    let calls = Arc::new(AtomicUsize::new(0));
    let observed_result = Arc::new(Mutex::new(None));
    let ctx = crate::shared::server::test_support::make_test_context();
    let mut agent = TronAgent::new(
        AgentConfig {
            max_turns: 2,
            ..AgentConfig::default()
        },
        make_primitive_loop_deps(
            PrimitiveExecuteLoopProvider {
                calls: calls.clone(),
                observed_result: observed_result.clone(),
            },
            ctx.engine_host.clone(),
        ),
        "primitive-loop-session".into(),
    );
    let result = agent
        .run(
            "call execute and continue",
            crate::domains::agent::runner::types::RunContext {
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
            .is_some_and(|text| text.contains("primitive loop observed through execute"))
    );

    let persisted_messages =
        serde_json::to_string(&agent.context_manager().get_messages()).expect("messages");
    assert!(persisted_messages.contains("continued after execute"));
}

#[tokio::test]
async fn resumed_session_offset_is_used_for_turn_events_and_token_record() {
    let mut agent = TronAgent::new(
        AgentConfig {
            max_turns: 1,
            ..AgentConfig::default()
        },
        make_deps(TokenUsageProvider),
        "s1".into(),
    );
    agent.set_completed_turn_offset(4);
    let mut events = agent.subscribe();

    let result = agent
        .run(
            "hello",
            crate::domains::agent::runner::types::RunContext::default(),
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
