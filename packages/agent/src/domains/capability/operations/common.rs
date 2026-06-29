//! Shared helper utilities for primitive execute operation adapters.

use serde_json::{Value, json};

use crate::engine::Invocation;
use crate::shared::protocol::content::CapabilityResultContent;
use crate::shared::protocol::model_capabilities::{CapabilityResult, CapabilityResultBody};
use crate::shared::server::errors::CapabilityError;

pub(super) fn observe(invocation: &Invocation) -> Result<CapabilityResult, CapabilityError> {
    let input = optional_str(&invocation.payload, "input")?.unwrap_or("");
    Ok(ok_result(
        if input.is_empty() {
            "Observation recorded.".to_owned()
        } else {
            input.to_owned()
        },
        json!({
            "primitiveOperation": "observe",
            "status": "ok"
        }),
    ))
}

pub(super) fn required_str<'a>(
    payload: &'a Value,
    field: &str,
) -> Result<&'a str, CapabilityError> {
    optional_str(payload, field)?.ok_or_else(|| CapabilityError::InvalidParams {
        message: format!("missing required field {field}"),
    })
}

pub(super) fn optional_str<'a>(
    payload: &'a Value,
    field: &str,
) -> Result<Option<&'a str>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Ok(Some(value)),
        Some(_) => Err(CapabilityError::InvalidParams {
            message: format!("{field} must be a string"),
        }),
    }
}

pub(super) fn optional_u64(payload: &Value, field: &str) -> Result<Option<u64>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(value)) => {
            value
                .as_u64()
                .map(Some)
                .ok_or_else(|| CapabilityError::InvalidParams {
                    message: format!("{field} must be a positive integer"),
                })
        }
        Some(_) => Err(CapabilityError::InvalidParams {
            message: format!("{field} must be a positive integer"),
        }),
    }
}

pub(super) fn ok_result(text: String, details: Value) -> CapabilityResult {
    CapabilityResult {
        content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(text)]),
        details: Some(details),
        is_error: Some(false),
        stop_turn: None,
    }
}

pub(super) fn error_capability_result(text: String, details: Value) -> CapabilityResult {
    CapabilityResult {
        content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(text)]),
        details: Some(details),
        is_error: Some(true),
        stop_turn: None,
    }
}

pub(super) fn result_value(result: CapabilityResult) -> Result<Value, CapabilityError> {
    serde_json::to_value(result).map_err(|error| internal(format!("serialize result: {error}")))
}

pub(super) fn compact_json(value: &Value) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "<unserializable>".to_owned())
}

pub(super) fn internal(message: impl Into<String>) -> CapabilityError {
    CapabilityError::Internal {
        message: message.into(),
    }
}

pub(super) fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}

pub(super) fn unsupported_operation(operation: &str) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: format!(
            "Unsupported primitive execute operation '{operation}'. Use observe, state_get, state_set, state_list, filesystem_read, filesystem_list, filesystem_find, filesystem_glob, filesystem_search_text, filesystem_diff, filesystem_write, filesystem_edit, filesystem_apply_patch, git_status, git_diff, git_branch_inventory, git_stage, git_unstage, git_commit, git_branch_start, process_run, job_start, job_status, job_list, job_log, job_cancel, goal_create, goal_list, goal_inspect, goal_cancel, question_create, question_list, question_inspect, question_answer, schedule_create, schedule_list, schedule_inspect, schedule_cancel, schedule_fire_due, web_fetch, web_robots_check, web_source_list, web_source_inspect, web_source_archive, web_research_request_record, web_research_request_list, web_research_request_inspect, web_research_review_record, web_research_review_list, web_research_review_inspect, web_research_source_record, web_research_source_list, web_research_source_inspect, media_create, media_list, media_inspect, media_archive, import_history_record, import_history_list, import_history_inspect, repository_tree_snapshot, repository_tree_list, repository_tree_inspect, import_preview_record, import_preview_list, import_preview_inspect, program_execution_record, program_execution_list, program_execution_inspect, prompt_artifact_record, prompt_artifact_list, prompt_artifact_inspect, update_diagnostic_record, update_diagnostic_list, update_diagnostic_inspect, device_register, device_unregister, device_list, device_inspect, notification_send, notification_list, notification_inspect, notification_mark_read, notification_mark_all_read, tool_source_list, tool_source_inspect, subagent_launch, subagent_status, subagent_result, subagent_cancel, subagent_task_list, subagent_task_inspect, worker_package_list, worker_package_inspect, module_list, module_inspect, module_proposal_record, module_proposal_list, module_proposal_inspect, module_validation_record, module_validation_list, module_validation_inspect, module_install_request_record, module_install_request_list, module_install_request_inspect, module_install_decision_record, module_install_decision_list, module_install_decision_inspect, module_dependency_request_record, module_dependency_request_list, module_dependency_request_inspect, module_dependency_decision_record, module_dependency_decision_list, module_dependency_decision_inspect, module_dependency_policy_activate, module_dependency_policy_list, module_dependency_policy_inspect, module_lifecycle_request, module_lifecycle_decision, module_lifecycle_list, module_lifecycle_inspect, module_program_execution_start, module_program_execution_status, module_program_execution_cancel, module_program_execution_cleanup, module_runtime_request, module_runtime_list, module_runtime_inspect, module_runtime_cancel, procedural_definition_record, procedural_state_list, procedural_state_inspect, procedural_activation_request_record, procedural_activation_request_list, procedural_activation_request_inspect, procedural_activation_decision_record, procedural_activation_decision_list, procedural_activation_decision_inspect, trace_list, trace_get, log_recent, replay_manifest, catalog_search, catalog_inspect, catalog_conformance, memory_status, memory_list, memory_inspect, memory_query_list, memory_query_inspect, memory_decision_list, or memory_decision_inspect."
        ),
    }
}
