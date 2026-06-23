//! Capability contracts for the workspace-browser filesystem domain.

use serde_json::json;

use crate::domains::registration::catalog::{CapabilitySpec, TransportIdempotencyMode};
use crate::domains::registration::contract::CapabilityContract;
use crate::engine::{
    CompensationContract, CompensationKind, DurableOutputContract, EffectClass,
    IdempotencyContract, ResourceLeaseRequirement, Result as EngineResult, RiskLevel,
};

use super::{FILESYSTEM_LIFECYCLE_TOPIC, READ_SCOPE, WORKER, WRITE_SCOPE};

pub(super) const GET_HOME_FUNCTION: &str = "filesystem::get_home";
pub(super) const LIST_DIR_FUNCTION: &str = "filesystem::list_dir";
pub(super) const CREATE_DIR_FUNCTION: &str = "filesystem::create_dir";
pub(crate) const READ_FUNCTION: &str = "filesystem::read";
pub(crate) const LIST_FUNCTION: &str = "filesystem::list";
pub(crate) const FIND_FUNCTION: &str = "filesystem::find";
pub(crate) const GLOB_FUNCTION: &str = "filesystem::glob";
pub(crate) const SEARCH_TEXT_FUNCTION: &str = "filesystem::search_text";
pub(crate) const DIFF_FUNCTION: &str = "filesystem::diff";
pub(crate) const WRITE_FUNCTION: &str = "filesystem::write";
pub(crate) const EDIT_FUNCTION: &str = "filesystem::edit";
pub(crate) const APPLY_PATCH_FUNCTION: &str = "filesystem::apply_patch";

pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new(
            GET_HOME_FUNCTION,
            WORKER,
            EffectClass::PureRead,
            RiskLevel::Low,
            Some(READ_SCOPE),
        )
        .request_schema(json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }))
        .response_schema(json!({
            "type": "object",
            "required": ["homePath", "suggestedPaths"],
            "additionalProperties": false,
            "properties": {
                "homePath": {"type": "string"},
                "suggestedPaths": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "required": ["name", "path", "exists"],
                        "additionalProperties": false,
                        "properties": {
                            "name": {"type": "string"},
                            "path": {"type": "string"},
                            "exists": {"type": "boolean"}
                        }
                    }
                }
            }
        }))
        .build()?,
        CapabilityContract::new(
            LIST_DIR_FUNCTION,
            WORKER,
            EffectClass::PureRead,
            RiskLevel::Low,
            Some(READ_SCOPE),
        )
        .request_schema(json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "path": {"type": "string"},
                "showHidden": {"type": "boolean"},
                "maxResults": {"type": "integer"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }))
        .response_schema(json!({
            "type": "object",
            "required": ["path", "parent", "entries", "truncated"],
            "additionalProperties": false,
            "properties": {
                "path": {"type": "string"},
                "parent": {"type": ["string", "null"]},
                "truncated": {"type": "boolean"},
                "entries": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "required": ["name", "path", "isDirectory", "isSymlink"],
                        "additionalProperties": false,
                        "properties": {
                            "name": {"type": "string"},
                            "path": {"type": "string"},
                            "isDirectory": {"type": "boolean"},
                            "isSymlink": {"type": "boolean"},
                            "size": {"type": ["integer", "null"]},
                            "modifiedAt": {"type": ["string", "null"]}
                        }
                    }
                }
            }
        }))
        .build()?,
        CapabilityContract::new(
            CREATE_DIR_FUNCTION,
            WORKER,
            EffectClass::IdempotentWrite,
            RiskLevel::Medium,
            Some(WRITE_SCOPE),
        )
        .request_schema(json!({
            "type": "object",
            "required": ["path"],
            "additionalProperties": false,
            "properties": {
                "path": {"type": "string"},
                "recursive": {"type": "boolean"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }))
        .response_schema(json!({
            "type": "object",
            "required": ["created", "path"],
            "additionalProperties": false,
            "properties": {
                "created": {"type": "boolean"},
                "path": {"type": "string"}
            }
        }))
        .idempotency(IdempotencyContract::caller_system_engine_ledger())
        .idempotency_mode(TransportIdempotencyMode::ExplicitRequired)
        .resource_lease(ResourceLeaseRequirement::exclusive_template(
            WORKER,
            "filesystem:workspace_browser",
            60_000,
        ))
        .compensation(CompensationContract::new(
            CompensationKind::ManualOnly,
            "workspace browser folder creation is idempotent; manual cleanup is required if the user wants the new folder removed",
        ))
        .build()?,
        read_contract(
            READ_FUNCTION,
            "Read one bounded text file preview under the trusted working-directory root.",
        )
        .request_schema(read_schema())
        .response_schema(json_schema())
        .build()?,
        read_contract(
            LIST_FUNCTION,
            "List one bounded directory under the trusted working-directory root.",
        )
        .request_schema(list_schema())
        .response_schema(json_schema())
        .build()?,
        read_contract(
            FIND_FUNCTION,
            "Find filesystem entries by substring or glob under the trusted working-directory root.",
        )
        .request_schema(find_schema(false))
        .response_schema(json_schema())
        .build()?,
        read_contract(
            GLOB_FUNCTION,
            "Find filesystem entries by glob under the trusted working-directory root.",
        )
        .request_schema(find_schema(true))
        .response_schema(json_schema())
        .build()?,
        read_contract(
            SEARCH_TEXT_FUNCTION,
            "Search bounded UTF-8 text files under the trusted working-directory root.",
        )
        .request_schema(search_schema())
        .response_schema(json_schema())
        .build()?,
        read_contract(
            DIFF_FUNCTION,
            "Preview a bounded unified diff for proposed file content without mutating the file.",
        )
        .request_schema(diff_schema())
        .response_schema(json_schema())
        .build()?,
        write_contract(
            WRITE_FUNCTION,
            "Create a patch proposal for a full-file write and optionally commit it with resource-backed evidence.",
        )
        .request_schema(write_schema())
        .response_schema(json_schema())
        .build()?,
        write_contract(
            EDIT_FUNCTION,
            "Create a patch proposal for one exact text replacement and optionally commit it with resource-backed evidence.",
        )
        .request_schema(edit_schema())
        .response_schema(json_schema())
        .build()?,
        write_contract(
            APPLY_PATCH_FUNCTION,
            "Apply one exact text patch under the trusted working-directory root with hash checks and rollback evidence.",
        )
        .request_schema(edit_schema())
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
    .tags(vec!["filesystem", "workspace", "bounded"])
    .domain_module("filesystem")
    .presentation_hints(json!({"systemImage": "folder"}))
}

fn write_contract(function_id: &'static str, description: &'static str) -> CapabilityContract {
    CapabilityContract::new(
        function_id,
        WORKER,
        EffectClass::IdempotentWrite,
        RiskLevel::Medium,
        Some(WRITE_SCOPE),
    )
    .description(description)
    .tags(vec!["filesystem", "patch", "resource", "rollback"])
    .domain_module("filesystem")
    .idempotency(IdempotencyContract::caller_system_engine_ledger())
    .idempotency_mode(TransportIdempotencyMode::ExplicitRequired)
    .resource_lease(ResourceLeaseRequirement::exclusive_template(
        WORKER,
        "filesystem:{path}",
        60_000,
    ))
    .compensation(CompensationContract::new(
        CompensationKind::ManualOnly,
        "filesystem writes return before/after hashes, bounded rollback previews, and patch/materialized-file resource refs; automatic rollback is not performed",
    ))
    .output_contract(DurableOutputContract::resource_backed([
        "patch_proposal",
        "materialized_file",
    ]))
    .stream_topics(vec![FILESYSTEM_LIFECYCLE_TOPIC])
    .presentation_hints(json!({"systemImage": "doc.text"}))
}

fn json_schema() -> serde_json::Value {
    json!({"type": "object", "additionalProperties": true})
}

fn read_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["path"],
        "additionalProperties": false,
        "properties": {
            "path": {"type": "string"},
            "maxBytes": {"type": "integer", "minimum": 1, "maximum": 262144}
        }
    })
}

fn list_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "path": {"type": "string"},
            "showHidden": {"type": "boolean"},
            "maxResults": {"type": "integer", "minimum": 1, "maximum": 2000}
        }
    })
}

fn find_schema(glob_required: bool) -> serde_json::Value {
    let mut required = vec!["path"];
    if glob_required {
        required.push("glob");
    }
    json!({
        "type": "object",
        "required": required,
        "additionalProperties": false,
        "properties": {
            "path": {"type": "string"},
            "query": {"type": "string"},
            "glob": {"type": "string"},
            "showHidden": {"type": "boolean"},
            "maxResults": {"type": "integer", "minimum": 1, "maximum": 1000}
        }
    })
}

fn search_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["query"],
        "additionalProperties": false,
        "properties": {
            "path": {"type": "string"},
            "query": {"type": "string"},
            "glob": {"type": "string"},
            "showHidden": {"type": "boolean"},
            "maxResults": {"type": "integer", "minimum": 1, "maximum": 1000},
            "maxFileBytes": {"type": "integer", "minimum": 1, "maximum": 262144}
        }
    })
}

fn diff_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["path", "content"],
        "additionalProperties": false,
        "properties": {
            "path": {"type": "string"},
            "content": {"type": "string"},
            "expectedHash": {"type": "string"},
            "maxDiffBytes": {"type": "integer", "minimum": 1, "maximum": 131072}
        }
    })
}

fn write_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["path", "content"],
        "additionalProperties": false,
        "properties": {
            "path": {"type": "string"},
            "content": {"type": "string"},
            "expectedHash": {"type": "string"},
            "commit": {"type": "boolean"},
            "reason": {"type": "string"},
            "maxDiffBytes": {"type": "integer", "minimum": 1, "maximum": 131072}
        }
    })
}

fn edit_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["path", "oldText", "newText"],
        "additionalProperties": false,
        "properties": {
            "path": {"type": "string"},
            "oldText": {"type": "string"},
            "newText": {"type": "string"},
            "expectedHash": {"type": "string"},
            "commit": {"type": "boolean"},
            "reason": {"type": "string"},
            "maxDiffBytes": {"type": "integer", "minimum": 1, "maximum": 131072}
        }
    })
}
