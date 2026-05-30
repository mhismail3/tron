pub(super) use super::super::super::capability_result_value;
pub(super) use super::super::super::target_arguments::IntentFileReadRequest;
pub(super) use super::super::*;
pub(super) use crate::domains::capability::registry::{
    CapabilityRegistryEntry, CapabilityRegistrySnapshot,
};
pub(super) use crate::domains::capability::types::CapabilityBindingDecision;
pub(super) use crate::engine::resources::{ACTIVATION_RECORD_KIND, WORKER_PACKAGE_KIND};
pub(super) use crate::engine::{
    ActorId, AuthorityGrantId, CausalContext, FunctionDefinition, FunctionId, TraceId,
};
pub(super) use crate::shared::content::CapabilityResultContent;
pub(super) use crate::shared::model_capabilities::{CapabilityResult, CapabilityResultBody};

pub(super) fn test_invocation_with_session_context() -> Invocation {
    Invocation::new_sync(
        FunctionId::new("capability::execute").expect("function id"),
        json!({}),
        CausalContext::new(
            ActorId::new("agent:test").expect("actor id"),
            crate::engine::ActorKind::Agent,
            AuthorityGrantId::new("grant:test").expect("grant id"),
            TraceId::new("trace:test").expect("trace id"),
        )
        .with_session_id("sess-context")
        .with_runtime_metadata(
            crate::engine::invocation::RUNTIME_METADATA_WORKING_DIRECTORY,
            "/tmp/tron/.worktrees/session/sess-context",
        ),
    )
}

pub(super) fn function_from_capability(function_id: &str) -> FunctionDefinition {
    let specs = crate::domains::filesystem::contract::capabilities()
        .expect("filesystem specs")
        .into_iter()
        .chain(crate::domains::worktree::contract::capabilities().expect("worktree specs"))
        .chain(crate::domains::git::contract::capabilities().expect("git specs"))
        .chain(crate::domains::settings::contract::capabilities().expect("settings specs"))
        .chain(crate::domains::model::contract::capabilities().expect("model specs"))
        .chain(crate::domains::logs::contract::capabilities().expect("logs specs"));
    let spec = specs
        .into_iter()
        .find(|spec| spec.function_id.as_str() == function_id)
        .unwrap_or_else(|| panic!("{function_id} spec"));
    crate::domains::contract::function_definition_for_capability(&spec)
}

pub(super) fn resource_list_function() -> FunctionDefinition {
    FunctionDefinition::new(
        FunctionId::new("resource::list").expect("function id"),
        crate::engine::WorkerId::new("resource").expect("worker id"),
        "list typed resources",
        crate::engine::VisibilityScope::System,
        crate::engine::EffectClass::PureRead,
    )
    .with_request_schema(json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "kind": {"type": "string"},
            "scope": {"type": "string", "enum": ["system", "workspace", "session"]},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"},
            "lifecycle": {"type": "string"},
            "limit": {"type": "integer"}
        }
    }))
}

pub(super) fn observability_metrics_function() -> FunctionDefinition {
    FunctionDefinition::new(
        FunctionId::new("observability::metrics_snapshot").expect("function id"),
        crate::engine::WorkerId::new("observability").expect("worker id"),
        "return a local metrics snapshot for engine primitives",
        crate::engine::VisibilityScope::System,
        crate::engine::EffectClass::PureRead,
    )
    .with_request_schema(json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {}
    }))
}

pub(super) fn resolved_target_for(function: FunctionDefinition) -> ResolvedCapabilityTarget {
    let entry = CapabilityRegistryEntry::from_function(function, 391);
    ResolvedCapabilityTarget {
        binding_decision: crate::domains::capability::types::CapabilityBindingDecision {
            decision_id: "decision:test".to_owned(),
            contract_id: entry.contract_id.clone(),
            selected_implementation: entry.implementation_id.clone(),
            selected_function_id: entry.function_id.clone(),
            selection_policy: "test".to_owned(),
            rejected_candidates: Vec::new(),
            catalog_revision: entry.catalog_revision,
            schema_digest: entry.schema_digest.clone(),
        },
        entry,
    }
}
