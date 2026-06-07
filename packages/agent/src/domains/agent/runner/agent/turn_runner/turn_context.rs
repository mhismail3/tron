//! Turn context construction and live provider capability surface resolution.

use crate::domains::agent::runner::context::context_manager::ContextManager;
use crate::domains::agent::runner::context::local_policy;
use crate::domains::agent::runner::types::RunContext;
use crate::domains::capability_support::implementations::primitive_surface::{
    self, PrimitiveSurfacePolicy, ResolvedCapabilitySurface,
};
use crate::shared::messages::Context;

use tracing::debug;

pub(super) fn build_turn_context(
    context_manager: &mut ContextManager,
    run_context: &RunContext,
    server_origin: Option<&str>,
    context_policy: &local_policy::ContextPolicy,
    primitive_surface: Vec<crate::shared::model_capabilities::ModelCapability>,
    capability_primer_context: Option<String>,
) -> Context {
    let is_local = context_policy.is_local();

    // Set volatile token estimates for accurate snapshots.
    let job_result_tokens = if context_policy.strip_job_results() {
        0
    } else {
        run_context.volatile_tokens.job_results
    };
    context_manager.set_volatile_tokens(
        run_context.volatile_tokens.skill_context,
        run_context.volatile_tokens.skill_removal,
        job_result_tokens,
    );
    // Set server origin for environment token estimation
    context_manager.set_server_origin(server_origin.map(String::from));

    let mut context = context_manager.build_base_context();
    context.messages = context_manager.get_messages_arc();
    context.hook_context.clone_from(&run_context.hook_context);

    // ModelCapability schemas are resolved from the live engine catalog at the provider
    // request boundary. The context policy has already been applied by
    // `resolve_provider_primitive_surface`.
    context.capabilities = Some(primitive_surface);

    context
        .skill_activation_context
        .clone_from(&run_context.skill_activation_context);
    context.skill_context.clone_from(&run_context.skill_context);
    context
        .skill_removal_context
        .clone_from(&run_context.skill_removal_context);
    context.dynamic_rules_context = run_context
        .dynamic_rules_context
        .clone()
        .or(context.dynamic_rules_context);
    context.capability_primer_context = capability_primer_context;

    if context_policy.strip_memory() {
        context.memory_content = None;
    }
    if context_policy.strip_skill_index() {
        context.skill_index_context = None;
    } else {
        context
            .skill_index_context
            .clone_from(&run_context.skill_index_context);
    }
    if context_policy.strip_job_results() {
        context.job_results_context = None;
    } else {
        context
            .job_results_context
            .clone_from(&run_context.job_results);
    }
    if context_policy.rules_truncation().is_some()
        && let Some(ref rules) = context.rules_content
    {
        context.rules_content = Some(context_policy.truncate_rules(rules));
    }

    context.server_origin = server_origin.map(String::from);

    if is_local {
        let truncation_suffix = context_policy
            .spec()
            .rules_truncation_suffix
            .clone()
            .unwrap_or_default();
        let rules_truncated = context
            .rules_content
            .as_ref()
            .is_some_and(|r| r.ends_with(&truncation_suffix));
        debug!(
            provider = "ollama",
            capability_count = context.capabilities.as_ref().map_or(0, Vec::len),
            memory_stripped = context_policy.strip_memory(),
            skill_index_stripped = context_policy.strip_skill_index(),
            job_results_stripped = context_policy.strip_job_results(),
            rules_truncated,
            "local-model turn context"
        );
    }

    context
}

pub(super) async fn build_capability_primer_context(
    _engine_host: Option<&crate::engine::EngineHostHandle>,
    _session_id: &str,
    _workspace_id: Option<&str>,
    _execution_spec: &crate::shared::profile::AgentExecutionSpec,
    _context_policy: &local_policy::ContextPolicy,
) -> Result<Option<String>, crate::shared::server::errors::CapabilityError> {
    Ok(None)
}

pub(super) async fn resolve_provider_primitive_surface(
    engine_host: Option<&crate::engine::EngineHostHandle>,
    session_id: &str,
    workspace_id: Option<&str>,
    provider_type: crate::shared::messages::Provider,
    context_policy: &local_policy::ContextPolicy,
    primitive_surface_policy: &PrimitiveSurfacePolicy,
) -> Result<ResolvedCapabilitySurface, String> {
    if let Some(host) = engine_host {
        return primitive_surface::resolve_provider_capabilities(
            host,
            session_id,
            workspace_id,
            provider_type,
            context_policy,
            primitive_surface_policy,
        )
        .await;
    }

    #[cfg(test)]
    {
        let _ = (
            session_id,
            workspace_id,
            provider_type,
            context_policy,
            primitive_surface_policy,
        );
        return Ok(ResolvedCapabilitySurface {
            catalog_revision: crate::engine::CatalogRevision(0),
            capabilities: Vec::new(),
            targets_by_name: Default::default(),
            all_model_capability_ids: Vec::new(),
            turn_stopping_capabilities: Default::default(),
        });
    }

    #[cfg(not(test))]
    {
        let _ = (
            session_id,
            workspace_id,
            provider_type,
            context_policy,
            primitive_surface_policy,
        );
        Err("engine host is required for provider capability schema resolution".to_owned())
    }
}

pub(super) fn resolved_turn_policy_ids(
    resolved_profile: &crate::shared::profile::ResolvedProfile,
    provider_type: crate::shared::messages::Provider,
) -> (String, String, String, String) {
    let spec = &resolved_profile.spec;
    let entrypoint = spec
        .entrypoints
        .get("main")
        .expect("validated profile must define entrypoints.main");
    let context_policy =
        crate::domains::agent::runner::context::local_policy::ContextPolicy::from_entrypoint_with_spec(
            provider_type,
            spec,
            "main",
        );
    let context_policy_id = context_policy.id().to_string();
    let primitive_surface_policy_id = context_policy
        .primitive_surface_policy_id()
        .map(String::from)
        .unwrap_or_else(|| entrypoint.primitive_surface_policy.clone());
    let capability_execution_policy_id = context_policy
        .capability_execution_policy_id()
        .map(String::from)
        .unwrap_or_else(|| entrypoint.capability_execution_policy.clone());
    let cache_policy_id = entrypoint.cache_policy.clone();

    (
        context_policy_id,
        primitive_surface_policy_id,
        capability_execution_policy_id,
        cache_policy_id,
    )
}
