//! Prompt-run bootstrap and volatile context assembly.

use std::sync::Arc;

use serde_json::{Value, json};
use tracing::warn;

use super::{
    PromptBootstrapData, PromptContextArtifacts, VolatileTokens, load_prompt_bootstrap,
    load_prompt_bootstrap_minimal,
};

pub(super) struct PromptContextBundle {
    pub(super) combined_rules: Option<String>,
    pub(super) rules_index: Option<crate::domains::agent::runner::context::rules_index::RulesIndex>,
    pub(super) pre_activated_rules: Vec<String>,
    pub(super) resolved_workspace_id: Option<String>,
    pub(super) memory: Option<String>,
    pub(super) job_results_context: Option<String>,
}

impl PromptContextBundle {
    pub(super) fn volatile_tokens(
        &self,
        skill_context: Option<&String>,
        skill_removal_context: Option<&String>,
        context_policy: &crate::domains::agent::runner::context::local_policy::ContextPolicy,
    ) -> VolatileTokens {
        let chars_per_token = 4u64;
        let skill_context = skill_context.map_or(0, |s| s.len() as u64 / chars_per_token);
        let skill_removal = skill_removal_context.map_or(0, |s| s.len() as u64 / chars_per_token);
        let job_results = if context_policy.strip_job_results() {
            0
        } else {
            self.job_results_context
                .as_ref()
                .map_or(0, |s| s.len() as u64 / chars_per_token)
        };
        VolatileTokens {
            skill_context,
            skill_removal,
            job_results,
        }
    }
}

pub(super) async fn load_prompt_context_bundle(
    context_artifacts: Arc<crate::domains::session::context::ContextArtifactsService>,
    engine_host: crate::engine::EngineHostHandle,
    event_store: Arc<crate::domains::session::event_store::EventStore>,
    memory_registry: Arc<parking_lot::Mutex<crate::domains::agent::runner::memory::MemoryRegistry>>,
    session_id: &str,
    working_dir: &str,
    settings: crate::domains::settings::TronSettings,
    is_resumed: bool,
    source: Option<String>,
    context_policy: &crate::domains::agent::runner::context::local_policy::ContextPolicy,
    worktree_info: Option<&crate::domains::worktree::WorktreeInfo>,
    resolved_profile: &Arc<crate::shared::profile::ResolvedProfile>,
) -> PromptContextBundle {
    let prompt_bootstrap = load_bootstrap(
        context_artifacts,
        event_store,
        session_id,
        working_dir,
        settings,
        is_resumed,
        source,
        context_policy,
    )
    .await;
    let PromptBootstrapData {
        artifacts: prompt_artifacts,
        subagent_results_context,
        process_results_context,
        user_job_actions_context,
    } = prompt_bootstrap;
    let job_results_context = join_job_results_context(
        subagent_results_context,
        process_results_context,
        user_job_actions_context,
    );
    let memory = load_memory_context(engine_host, memory_registry, context_policy).await;
    let memory = append_worktree_context(memory, worktree_info, resolved_profile);

    PromptContextBundle {
        combined_rules: prompt_artifacts.rules_content,
        rules_index: prompt_artifacts.rules_index,
        pre_activated_rules: prompt_artifacts.pre_activated_rules,
        resolved_workspace_id: prompt_artifacts.workspace_id,
        memory,
        job_results_context,
    }
}

async fn load_bootstrap(
    context_artifacts: Arc<crate::domains::session::context::ContextArtifactsService>,
    event_store: Arc<crate::domains::session::event_store::EventStore>,
    session_id: &str,
    working_dir: &str,
    settings: crate::domains::settings::TronSettings,
    is_resumed: bool,
    source: Option<String>,
    context_policy: &crate::domains::agent::runner::context::local_policy::ContextPolicy,
) -> PromptBootstrapData {
    let bootstrap_result = if context_policy.skip_pending_jobs_bootstrap() {
        load_prompt_bootstrap_minimal(
            context_artifacts,
            event_store,
            session_id.to_owned(),
            working_dir.to_owned(),
            settings,
            is_resumed,
            source,
        )
        .await
    } else {
        load_prompt_bootstrap(
            context_artifacts,
            event_store,
            session_id.to_owned(),
            working_dir.to_owned(),
            settings,
            is_resumed,
            source,
        )
        .await
    };

    match bootstrap_result {
        Ok(artifacts) => artifacts,
        Err(error) => {
            warn!(
                session_id = %session_id,
                working_dir = %working_dir,
                error = %error,
                "failed to load prompt bootstrap"
            );
            PromptBootstrapData {
                artifacts: PromptContextArtifacts::default(),
                subagent_results_context: None,
                process_results_context: None,
                user_job_actions_context: None,
            }
        }
    }
}

fn join_job_results_context(
    subagent_results_context: Option<String>,
    process_results_context: Option<String>,
    user_job_actions_context: Option<String>,
) -> Option<String> {
    let mut job_parts: Vec<String> = Vec::new();
    if let Some(subagent) = subagent_results_context {
        job_parts.push(subagent);
    }
    if let Some(process) = process_results_context {
        job_parts.push(process);
    }
    if let Some(actions) = user_job_actions_context {
        job_parts.push(actions);
    }
    if job_parts.is_empty() {
        None
    } else {
        Some(job_parts.join("\n\n"))
    }
}

async fn load_memory_context(
    engine_host: crate::engine::EngineHostHandle,
    memory_registry: Arc<parking_lot::Mutex<crate::domains::agent::runner::memory::MemoryRegistry>>,
    context_policy: &crate::domains::agent::runner::context::local_policy::ContextPolicy,
) -> Option<String> {
    if context_policy.strip_memory() {
        return None;
    }
    let base = {
        let mut registry = memory_registry.lock();
        registry
            .content(&crate::shared::paths::home_dir())
            .to_string()
    };
    join_context_parts([
        Some(base),
        load_retained_memory_resource_context(&engine_host).await,
    ])
}

async fn load_retained_memory_resource_context(
    engine_host: &crate::engine::EngineHostHandle,
) -> Option<String> {
    let listed = invoke_resource_read(
        engine_host,
        "resource::list",
        json!({"kind": "artifact", "limit": 10_000}),
        "memory-context-list",
    )
    .await?;
    let mut ids = listed["resources"]
        .as_array()?
        .iter()
        .filter_map(|resource| resource.get("resourceId").and_then(Value::as_str))
        .filter(|id| {
            id.starts_with("artifact:memory-rule:") || id.starts_with("artifact:memory-argument:")
        })
        .map(str::to_owned)
        .collect::<Vec<_>>();
    ids.sort();

    let mut sections = Vec::new();
    for id in ids.into_iter().take(200) {
        let inspected = invoke_resource_read(
            engine_host,
            "resource::inspect",
            json!({"resourceId": id}),
            "memory-context-inspect",
        )
        .await?;
        let inspection = inspected.get("inspection")?;
        if inspection["resource"]["lifecycle"] == "discarded" {
            continue;
        }
        let payload = current_resource_payload(inspection)?;
        let title = payload
            .get("title")
            .and_then(Value::as_str)
            .unwrap_or("Retained memory");
        let body = payload
            .get("body")
            .or_else(|| payload.get("summary"))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim();
        if !body.is_empty() {
            sections.push(format!("### {title}\n\n{body}"));
        }
    }
    if sections.is_empty() {
        None
    } else {
        Some(format!(
            "## Resource-backed retained memory\n\n{}",
            sections.join("\n\n")
        ))
    }
}

async fn invoke_resource_read(
    engine_host: &crate::engine::EngineHostHandle,
    function_id: &str,
    payload: Value,
    idempotency_label: &str,
) -> Option<Value> {
    let causal = crate::engine::CausalContext::new(
        crate::engine::ActorId::new("system:memory-context").ok()?,
        crate::engine::ActorKind::System,
        crate::engine::AuthorityGrantId::new("engine-system").ok()?,
        crate::engine::TraceId::new("memory-context").ok()?,
    )
    .with_scope("resource.read")
    .with_idempotency_key(idempotency_label);
    let result = engine_host
        .invoke(crate::engine::Invocation::new_sync(
            crate::engine::FunctionId::new(function_id).ok()?,
            payload,
            causal,
        ))
        .await;
    if let Some(error) = result.error {
        warn!(error = %error, "failed to load resource-backed retained memory");
        return None;
    }
    result.value
}

fn current_resource_payload(inspection: &Value) -> Option<&Value> {
    let current = inspection
        .pointer("/resource/currentVersionId")
        .and_then(Value::as_str)?;
    inspection
        .get("versions")
        .and_then(Value::as_array)?
        .iter()
        .find(|version| version["versionId"] == current)
        .and_then(|version| version.get("payload"))
}

fn join_context_parts(parts: impl IntoIterator<Item = Option<String>>) -> Option<String> {
    let parts = parts
        .into_iter()
        .flatten()
        .map(|part| part.trim().to_owned())
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>();
    if parts.is_empty() {
        None
    } else {
        Some(parts.join("\n\n"))
    }
}

fn append_worktree_context(
    memory: Option<String>,
    worktree_info: Option<&crate::domains::worktree::WorktreeInfo>,
    resolved_profile: &Arc<crate::shared::profile::ResolvedProfile>,
) -> Option<String> {
    let Some(worktree) = worktree_info else {
        return memory;
    };

    let worktree_context = format!(
        "\n\n## Environment Isolation\n\
         Working in git worktree: {}\n\
         Branch: {}{}\n{}",
        worktree.worktree_path.display(),
        worktree.branch,
        worktree
            .base_branch
            .as_ref()
            .map(|branch| format!(" (based on {branch})"))
            .unwrap_or_default(),
        resolved_profile
            .spec
            .entrypoint_prompts
            .get("gitWorkflow")
            .map(|prompt| prompt.content.as_str())
            .unwrap_or(""),
    );
    Some(match memory {
        Some(memory) => format!("{memory}{worktree_context}"),
        None => worktree_context,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_context(key: &str) -> crate::engine::CausalContext {
        crate::engine::CausalContext::new(
            crate::engine::ActorId::new("system:test").unwrap(),
            crate::engine::ActorKind::System,
            crate::engine::AuthorityGrantId::new("engine-system").unwrap(),
            crate::engine::TraceId::new("memory-context-test").unwrap(),
        )
        .with_scope("resource.write")
        .with_idempotency_key(key)
    }

    #[tokio::test]
    async fn retained_memory_context_reads_resource_artifacts() {
        let handle = crate::engine::EngineHostHandle::new_in_memory().unwrap();
        let created = handle
            .invoke(crate::engine::Invocation::new_sync(
                crate::engine::FunctionId::new("artifact::create").unwrap(),
                json!({
                    "resourceId": "artifact:memory-rule:test:001",
                    "scope": "system",
                    "lifecycle": "promoted",
                    "payload": {
                        "title": "Memory rule update: test.md",
                        "body": "- Always verify resource-backed truth",
                        "metadata": {"domain": "memory", "recordKind": "rule"}
                    }
                }),
                write_context("memory-context-artifact-create"),
            ))
            .await;
        assert_eq!(created.error, None);

        let context = load_retained_memory_resource_context(&handle)
            .await
            .expect("resource-backed memory context");
        assert!(context.contains("Resource-backed retained memory"));
        assert!(context.contains("Always verify resource-backed truth"));
    }
}
