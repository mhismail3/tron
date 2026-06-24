use serde_json::json;

use crate::domains::registration::catalog::CapabilitySpec;
use crate::domains::registration::catalog::TransportIdempotencyMode;
use crate::domains::registration::contract::CapabilityContract;
use crate::engine::{
    CompensationContract, CompensationKind, DurableOutputContract, EffectClass,
    IdempotencyContract, ResourceLeaseRequirement, RiskLevel,
};

use super::{
    DIFF_FUNCTION, GIT_LIFECYCLE_TOPIC, READ_SCOPE, STAGE_FUNCTION, STATUS_FUNCTION,
    UNSTAGE_FUNCTION, WORKER, WRITE_SCOPE,
};
use crate::engine::GIT_INDEX_CHANGE_KIND;

pub(crate) fn capabilities() -> crate::engine::Result<Vec<CapabilitySpec>> {
    Ok(vec![
        read_contract(
            STATUS_FUNCTION,
            "Inspect read-only repository/worktree status for the trusted working-directory root.",
        )
        .request_schema(status_schema())
        .response_schema(json_schema())
        .build()?,
        read_contract(
            DIFF_FUNCTION,
            "Read bounded staged and unstaged Git diffs for the trusted working-directory root.",
        )
        .request_schema(diff_schema())
        .response_schema(json_schema())
        .build()?,
        write_contract(
            STAGE_FUNCTION,
            "Stage one explicit relative path into the Git index after expected-HEAD and conflict checks.",
            GIT_INDEX_CHANGE_KIND,
        )
        .request_schema(index_mutation_schema())
        .response_schema(json_schema())
        .build()?,
        write_contract(
            UNSTAGE_FUNCTION,
            "Unstage one explicit relative path from the Git index after expected-HEAD and conflict checks.",
            GIT_INDEX_CHANGE_KIND,
        )
        .request_schema(index_mutation_schema())
        .response_schema(json_schema())
        .build()?,
    ])
}

fn read_contract(function_id: &'static str, description: &'static str) -> CapabilityContract {
    CapabilityContract::new(
        function_id,
        WORKER,
        EffectClass::PureRead,
        RiskLevel::Low,
        Some(READ_SCOPE),
    )
    .description(description)
    .tags(vec!["git", "worktree", "source-control", "read-only"])
    .domain_module("git")
    .presentation_hints(json!({"systemImage": "branch"}))
}

fn write_contract(
    function_id: &'static str,
    description: &'static str,
    resource_kind: &'static str,
) -> CapabilityContract {
    CapabilityContract::new(
        function_id,
        WORKER,
        EffectClass::IdempotentWrite,
        RiskLevel::Medium,
        Some(WRITE_SCOPE),
    )
    .description(description)
    .tags(vec!["git", "source-control", "resource"])
    .domain_module("git")
    .idempotency(IdempotencyContract::caller_session_engine_ledger())
    .idempotency_mode(TransportIdempotencyMode::ExplicitRequired)
    .resource_lease(ResourceLeaseRequirement::exclusive_template(
        WORKER,
        "git:index:{path}",
        60_000,
    ))
    .compensation(CompensationContract::new(
        CompensationKind::ManualOnly,
        "git write operations return bounded before/after evidence; index changes can be manually reversed before commit and committed history requires later manual source-control recovery",
    ))
    .output_contract(DurableOutputContract::resource_backed([resource_kind]))
    .stream_topics(vec![GIT_LIFECYCLE_TOPIC])
    .presentation_hints(json!({"systemImage": "plusminus"}))
}

fn status_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "path": {"type": "string"},
            "maxStatusBytes": {"type": "integer", "minimum": 1}
        }
    })
}

fn diff_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "path": {"type": "string"},
            "maxDiffBytes": {"type": "integer", "minimum": 1}
        }
    })
}

fn index_mutation_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["path", "expectedHead", "reason"],
        "additionalProperties": false,
        "properties": {
            "path": {"type": "string"},
            "expectedHead": {"type": "string"},
            "reason": {"type": "string"},
            "maxStatusBytes": {"type": "integer", "minimum": 1},
            "maxDiffBytes": {"type": "integer", "minimum": 1}
        }
    })
}

fn json_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["schemaVersion", "status", "operation", "repository"],
        "additionalProperties": true,
        "properties": {
            "schemaVersion": {"type": "string"},
            "status": {"type": "string"},
            "operation": {"type": "string"},
            "repository": {"type": "object"}
        }
    })
}
