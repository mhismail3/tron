//! Capability contracts for read-only git/worktree evidence.

use serde_json::json;

use crate::domains::registration::catalog::CapabilitySpec;
use crate::domains::registration::contract::CapabilityContract;
use crate::engine::{EffectClass, Result as EngineResult, RiskLevel};

use super::{READ_SCOPE, WORKER};

pub(crate) const STATUS_FUNCTION: &str = "git::status";
pub(crate) const DIFF_FUNCTION: &str = "git::diff";

pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        read_contract(
            STATUS_FUNCTION,
            "Read bounded git repository/worktree status under the trusted working-directory root.",
        )
        .request_schema(git_read_schema(true))
        .response_schema(json_schema())
        .build()?,
        read_contract(
            DIFF_FUNCTION,
            "Read bounded git diff evidence for tracked staged and unstaged changes under the trusted working-directory root.",
        )
        .request_schema(git_read_schema(false))
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
    .tags(vec!["git", "worktree", "read-only", "bounded"])
    .domain_module("git")
    .presentation_hints(json!({"systemImage": "arrow.triangle.branch"}))
}

fn json_schema() -> serde_json::Value {
    json!({"type": "object", "additionalProperties": true})
}

fn git_read_schema(status: bool) -> serde_json::Value {
    let mut properties = serde_json::Map::new();
    properties.insert(
        "path".to_owned(),
        json!({"type": "string", "description": "Relative path under the trusted working directory used to locate the repository."}),
    );
    properties.insert(
        "maxBytes".to_owned(),
        json!({"type": "integer", "minimum": 1, "maximum": 131072}),
    );
    properties.insert(
        "limit".to_owned(),
        json!({"type": "integer", "minimum": 1, "maximum": 500}),
    );
    if !status {
        properties.insert(
            "maxDiffBytes".to_owned(),
            json!({"type": "integer", "minimum": 1, "maximum": 131072}),
        );
    }
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": properties
    })
}
