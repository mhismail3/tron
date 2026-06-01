use super::*;
use crate::domains::agent::runner::context::types::ContextManagerConfig;
use crate::domains::model::providers::models::types::Provider as ProviderKind;
use crate::domains::model::providers::provider::{
    Provider, ProviderError, ProviderStreamOptions, StreamEventStream,
};
use crate::shared::content::AssistantContent;
use crate::shared::events::{AssistantMessage, StreamEvent, TronEvent};
use crate::shared::messages::TokenUsage;
use async_trait::async_trait;
use futures::stream;
use std::sync::Arc;

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

fn test_context_manager(model: &str) -> ContextManager {
    let spec = crate::shared::profile::bundled_default_execution_spec();
    ContextManager::new(ContextManagerConfig {
        model: model.to_owned(),
        system_prompt: Some("You are a test agent.".into()),
        context_policy:
            crate::domains::agent::runner::context::local_policy::ContextPolicy::from_provider_with_spec(
                ProviderKind::Anthropic,
                &spec,
            ),
        working_directory: Some("/tmp".into()),
        capabilities: vec![],
        rules_content: None,
        compaction: crate::domains::agent::runner::context::types::CompactionConfig::default(),
    })
}

fn make_deps(provider: impl Provider + 'static) -> AgentDeps {
    AgentDeps {
        provider: Arc::new(provider),
        primitive_surface_policy:
            crate::domains::capability_support::implementations::primitive_surface::PrimitiveSurfacePolicy::default(),
        capability_execution_policy:
            crate::shared::profile::bundled_default_execution_spec().capability_execution_policies
                ["default"]
                .clone(),
        guardrails: None,
        hooks: None,
        context_manager: test_context_manager("mock-model"),
        subagent_manager: None,
        compaction_trigger_config:
            crate::domains::agent::runner::context::types::CompactionTriggerConfig::default(),
        process_manager: None,
        job_manager: None,
        output_buffer_registry: None,
        engine_host: None,
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
    let tempdir = tempfile::tempdir().expect("profile tempdir");
    let home = tempdir.path().join(".tron");
    crate::shared::constitution::ensure_tron_home_at(&home).expect("seed profile home");
    let profile = Arc::new(
        crate::shared::profile::resolve_profile_at(&home, crate::shared::profile::NORMAL_PROFILE)
            .expect("normal profile"),
    );
    let result = agent
        .run(
            "hello",
            crate::domains::agent::runner::types::RunContext {
                profile_name: Some(profile.name.clone()),
                resolved_profile: Some(profile),
                ..Default::default()
            },
        )
        .await;
    assert!(
        result.error.is_none(),
        "run should succeed: {:?}",
        result.error
    );
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

    let profile = {
        let tempdir = tempfile::tempdir().expect("profile tempdir");
        let home = tempdir.path().join(".tron");
        crate::shared::constitution::ensure_tron_home_at(&home).expect("seed profile home");
        let profile = crate::shared::profile::resolve_profile_at(
            &home,
            crate::shared::profile::NORMAL_PROFILE,
        )
        .expect("normal profile");
        std::mem::forget(tempdir);
        Arc::new(profile)
    };
    let result = agent
        .run(
            "hello",
            crate::domains::agent::runner::types::RunContext {
                profile_name: Some(profile.name.clone()),
                resolved_profile: Some(profile),
                ..Default::default()
            },
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
