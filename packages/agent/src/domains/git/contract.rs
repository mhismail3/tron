use serde_json::json;

use crate::domains::registration::catalog::CapabilitySpec;
use crate::domains::registration::contract::CapabilityContract;
use crate::engine::{EffectClass, RiskLevel};

use super::{DIFF_FUNCTION, READ_SCOPE, STATUS_FUNCTION, WORKER};

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
