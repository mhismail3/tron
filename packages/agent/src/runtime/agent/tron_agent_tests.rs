use super::*;
use crate::core::content::AssistantContent;
use crate::core::events::{AssistantMessage, StreamEvent};
use crate::llm::models::types::Provider as ProviderKind;
use crate::llm::provider::{Provider, ProviderError, ProviderStreamOptions, StreamEventStream};
use crate::runtime::context::types::ContextManagerConfig;
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
        _context: &crate::core::messages::Context,
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

fn test_context_manager(model: &str) -> ContextManager {
    let spec = crate::core::profile::bundled_default_execution_spec();
    ContextManager::new(ContextManagerConfig {
        model: model.to_owned(),
        system_prompt: Some("You are a test agent.".into()),
        context_policy:
            crate::runtime::context::local_policy::ContextPolicy::from_provider_with_spec(
                ProviderKind::Anthropic,
                &spec,
            ),
        working_directory: Some("/tmp".into()),
        tools: vec![],
        rules_content: None,
        compaction: crate::runtime::context::types::CompactionConfig::default(),
    })
}

fn make_deps(provider: impl Provider + 'static) -> AgentDeps {
    AgentDeps {
        provider: Arc::new(provider),
        tool_surface_policy: crate::tools::capability_surface::ToolSurfacePolicy::default(),
        guardrails: None,
        hooks: None,
        context_manager: test_context_manager("mock-model"),
        subagent_manager: None,
        compaction_trigger_config: crate::runtime::context::types::CompactionTriggerConfig::default(
        ),
        process_manager: None,
        job_manager: None,
        output_buffer_registry: None,
        engine_host: None,
    }
}

#[test]
fn agent_uses_empty_initial_tool_snapshot() {
    let agent = TronAgent::new(AgentConfig::default(), make_deps(MockProvider), "s1".into());
    assert!(agent.context_manager().tool_names().is_empty());
}

#[tokio::test]
async fn text_only_run_succeeds_without_frozen_tools() {
    let mut agent = TronAgent::new(
        AgentConfig {
            max_turns: 1,
            ..AgentConfig::default()
        },
        make_deps(MockProvider),
        "s1".into(),
    );
    let profile = {
        let tempdir = tempfile::tempdir().expect("profile tempdir");
        let home = tempdir.path().join(".tron");
        crate::core::constitution::ensure_tron_home_at(&home).expect("seed profile home");
        let profile =
            crate::core::profile::resolve_profile_at(&home, crate::core::profile::NORMAL_PROFILE)
                .expect("normal profile");
        std::mem::forget(tempdir);
        Arc::new(profile)
    };
    let result = agent
        .run(
            "hello",
            crate::runtime::types::RunContext {
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
