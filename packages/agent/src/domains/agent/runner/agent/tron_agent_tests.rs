use super::*;
use crate::domains::agent::runner::context::types::ContextManagerConfig;
use crate::domains::model::providers::models::types::Provider as ProviderKind;
use crate::domains::model::providers::provider::{
    Provider, ProviderError, ProviderStreamOptions, StreamEventStream,
};
use crate::shared::content::AssistantContent;
use crate::shared::events::{AssistantMessage, StreamEvent, TronEvent};
use crate::shared::messages::{Context, TokenUsage};
use async_trait::async_trait;
use futures::stream;
use parking_lot::Mutex;
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

#[derive(Clone, Debug)]
struct HarnessAnswerObservation {
    provider: ProviderKind,
    model: String,
    answer: String,
    capability_names: Vec<String>,
    primer: String,
    memory_present: bool,
    skill_index_present: bool,
    job_results_present: bool,
}

struct HarnessQuestionProvider {
    provider: ProviderKind,
    model: &'static str,
    observations: Arc<Mutex<Vec<HarnessAnswerObservation>>>,
}

#[async_trait]
impl Provider for HarnessQuestionProvider {
    fn provider_type(&self) -> ProviderKind {
        self.provider
    }

    fn model(&self) -> &'static str {
        self.model
    }

    async fn stream(
        &self,
        context: &Context,
        _options: &ProviderStreamOptions,
    ) -> Result<StreamEventStream, ProviderError> {
        assert_harness_question_context(self.provider, context);
        let primer = context
            .capability_primer_context
            .clone()
            .expect("provider-visible primer");
        let resource_id = primer_field(&primer, "resourceId").expect("resource id");
        let version_id = primer_field(&primer, "versionId").expect("version id");
        let answer = format!(
            "Customize the harness through execute: inspect the versioned harness_doc with resource::inspect resourceId={resource_id} versionId={version_id}, run worker::protocol_guide, author the worker, spawn it with worker::spawn, inspect the live catalog, run conformance/test evidence, expose generated ui_surface controls, promote only through engine::promote when evidence passes, then clean up with worker::disconnect or sandbox::stop_spawned_worker."
        );
        self.observations.lock().push(HarnessAnswerObservation {
            provider: self.provider,
            model: self.model.to_owned(),
            answer: answer.clone(),
            capability_names: context
                .capabilities
                .as_ref()
                .expect("capabilities")
                .iter()
                .map(|capability| capability.name.clone())
                .collect(),
            primer,
            memory_present: context.memory_content.is_some(),
            skill_index_present: context.skill_index_context.is_some(),
            job_results_present: context.job_results_context.is_some(),
        });

        let events = vec![
            Ok(StreamEvent::Start),
            Ok(StreamEvent::TextDelta {
                delta: answer.clone(),
            }),
            Ok(StreamEvent::Done {
                message: AssistantMessage {
                    content: vec![AssistantContent::text(answer)],
                    token_usage: None,
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

fn harness_context_manager(provider: ProviderKind, model: &str) -> ContextManager {
    let spec = crate::shared::profile::bundled_default_execution_spec();
    ContextManager::new(ContextManagerConfig {
        model: model.to_owned(),
        system_prompt: Some("You answer from live provider-visible context.".into()),
        context_policy:
            crate::domains::agent::runner::context::local_policy::ContextPolicy::from_provider_with_spec(
                provider,
                &spec,
            ),
        working_directory: Some("/tmp".into()),
        capabilities: vec![],
        rules_content: Some("Use execute for harness customization.".into()),
        compaction: crate::domains::agent::runner::context::types::CompactionConfig::default(),
    })
}

fn make_harness_deps(
    provider: HarnessQuestionProvider,
    engine_host: crate::engine::EngineHostHandle,
) -> AgentDeps {
    let spec = crate::shared::profile::bundled_default_execution_spec();
    let provider_kind = provider.provider_type();
    let model = provider.model().to_owned();
    AgentDeps {
        provider: Arc::new(provider),
        primitive_surface_policy:
            crate::domains::capability_support::implementations::primitive_surface::PrimitiveSurfacePolicy::default(),
        capability_execution_policy: spec.capability_execution_policies["default"].clone(),
        guardrails: None,
        hooks: None,
        context_manager: harness_context_manager(provider_kind, &model),
        subagent_manager: None,
        compaction_trigger_config:
            crate::domains::agent::runner::context::types::CompactionTriggerConfig::default(),
        process_manager: None,
        job_manager: None,
        output_buffer_registry: None,
        engine_host: Some(engine_host),
    }
}

fn seeded_harness_engine_host() -> crate::engine::EngineHostHandle {
    let host = crate::engine::EngineHostHandle::new_in_memory().expect("engine host");
    let worker = crate::engine::WorkerDefinition::new(
        crate::engine::WorkerId::new("capability").expect("worker id"),
        crate::engine::WorkerKind::InProcess,
        crate::engine::ActorId::new("system").expect("actor id"),
        crate::engine::AuthorityGrantId::new("engine-transport").expect("grant id"),
    )
    .with_namespace_claim("capability");
    host.register_worker_for_setup(worker, false)
        .expect("capability worker");
    for spec in crate::domains::capability::contract::capabilities().expect("capabilities") {
        let mut definition = crate::domains::contract::function_definition_for_capability(&spec);
        merge_metadata(
            &mut definition.metadata,
            crate::domains::capability::contract::model_metadata(definition.id.as_str()),
        );
        host.register_function_for_setup(definition, None, false)
            .expect("capability function");
    }
    host
}

fn merge_metadata(target: &mut serde_json::Value, extra: serde_json::Value) {
    match (target, extra) {
        (serde_json::Value::Object(target), serde_json::Value::Object(extra)) => {
            for (key, value) in extra {
                let _ = target.insert(key, value);
            }
        }
        (target, extra) if !extra.is_null() => {
            *target = extra;
        }
        _ => {}
    }
}

fn resolved_normal_profile() -> Arc<crate::shared::profile::ResolvedProfile> {
    let tempdir = tempfile::tempdir().expect("profile tempdir");
    let home = tempdir.path().join(".tron");
    crate::shared::constitution::ensure_tron_home_at(&home).expect("seed profile home");
    let profile =
        crate::shared::profile::resolve_profile_at(&home, crate::shared::profile::NORMAL_PROFILE)
            .expect("normal profile");
    std::mem::forget(tempdir);
    Arc::new(profile)
}

fn assert_harness_question_context(provider: ProviderKind, context: &Context) {
    let user_messages = serde_json::to_string(&context.messages).expect("serialize messages");
    assert!(
        user_messages.contains("how can you customize your harness?"),
        "{user_messages}"
    );
    let capability_names = context
        .capabilities
        .as_ref()
        .expect("capabilities")
        .iter()
        .map(|capability| capability.name.as_str())
        .collect::<Vec<_>>();
    assert_eq!(capability_names, ["execute"]);
    let primer = context
        .capability_primer_context
        .as_ref()
        .expect("provider-visible primer");
    for required in [
        "To customize the harness",
        "worker::protocol_guide",
        "worker::spawn",
        "capability::inspect",
        "module::run_conformance",
        "ui_surface",
        "engine::promote",
        "worker::disconnect",
        "Harness docs resource:",
        "kind=harness_doc",
        "inspectTarget=resource::inspect",
    ] {
        assert!(
            primer.contains(required),
            "{provider:?} primer missing {required}: {primer}"
        );
    }
}

fn primer_field(text: &str, field: &str) -> Option<String> {
    let prefix = format!("{field}=");
    text.lines()
        .find(|line| line.contains("Harness docs resource:"))
        .and_then(|line| {
            line.split_whitespace()
                .find_map(|part| part.strip_prefix(&prefix))
        })
        .map(|value| value.trim_matches('`').trim_matches('.').to_owned())
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
async fn model_run_proves_harness_customization_across_providers() {
    let profile = resolved_normal_profile();
    let cases = [
        (ProviderKind::OpenAi, "gpt-5.3"),
        (ProviderKind::Ollama, "gemma4:27b"),
    ];

    for (provider_kind, model) in cases {
        let observations = Arc::new(Mutex::new(Vec::new()));
        let provider = HarnessQuestionProvider {
            provider: provider_kind,
            model,
            observations: observations.clone(),
        };
        let engine_host = seeded_harness_engine_host();
        let mut agent = TronAgent::new(
            AgentConfig {
                provider_type: Some(provider_kind),
                model: model.to_owned(),
                max_turns: 1,
                workspace_id: Some(format!("workspace-hmh-c5-{}", provider_kind.as_str())),
                ..AgentConfig::default()
            },
            make_harness_deps(provider, engine_host),
            format!("session-hmh-c5-{}", provider_kind.as_str()),
        );
        agent
            .context_manager_mut()
            .set_memory_content(Some("memory must be stripped for local".into()));
        let result = agent
            .run(
                "how can you customize your harness?",
                crate::domains::agent::runner::types::RunContext {
                    profile_name: Some(profile.name.clone()),
                    resolved_profile: Some(profile.clone()),
                    skill_index_context: Some("skill index must be stripped for local".into()),
                    job_results: Some("job results must be stripped for local".into()),
                    ..Default::default()
                },
            )
            .await;
        assert!(
            result.error.is_none(),
            "{provider_kind:?} run should succeed: {:?}",
            result.error
        );
        assert_eq!(result.turns_executed, 1);

        let observations = observations.lock();
        let observation = observations
            .first()
            .unwrap_or_else(|| panic!("{provider_kind:?} provider was not called"));
        assert_eq!(observation.provider, provider_kind);
        assert_eq!(observation.model, model);
        assert_eq!(observation.capability_names, ["execute"]);
        assert!(
            observation.answer.contains("resource::inspect")
                && observation.answer.contains("worker::protocol_guide")
                && observation.answer.contains("worker::spawn")
                && observation.answer.contains("engine::promote")
                && observation.answer.contains("worker::disconnect"),
            "{}",
            observation.answer
        );
        assert!(observation.primer.contains("resourceId=harness_doc:"));
        if provider_kind == ProviderKind::Ollama {
            assert!(!observation.memory_present);
            assert!(!observation.skill_index_present);
            assert!(!observation.job_results_present);
        } else {
            assert!(observation.memory_present);
            assert!(observation.skill_index_present);
            assert!(observation.job_results_present);
        }

        let persisted_messages =
            serde_json::to_string(&agent.context_manager().get_messages()).expect("messages");
        assert!(
            persisted_messages.contains("worker::spawn")
                && persisted_messages.contains("resource::inspect"),
            "{persisted_messages}"
        );
    }
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
