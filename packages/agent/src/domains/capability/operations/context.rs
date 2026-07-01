use serde_json::Value;

use crate::engine::{ActorKind, Invocation, is_bootstrap_authority_grant_id};
use crate::shared::server::errors::CapabilityError;

use super::scheduler::{is_scheduler_operation, requires_scheduler_idempotency};

pub(super) fn validate_execute_context(
    invocation: &Invocation,
    operation: &str,
) -> Result<(), CapabilityError> {
    match invocation.causal_context.actor_kind {
        ActorKind::Agent => {
            let session_id = invocation
                .causal_context
                .session_id
                .as_deref()
                .ok_or_else(|| invalid("capability::execute agent context requires session id"))?;
            let expected_actor = format!("agent:{session_id}");
            if invocation.causal_context.actor_id.as_str() != expected_actor {
                return Err(invalid(
                    "capability::execute agent actor must match the current session",
                ));
            }
        }
        ActorKind::System => {}
        _ => {
            return Err(invalid(
                "capability::execute requires a trusted agent or system runtime context",
            ));
        }
    }
    if is_bootstrap_authority_grant_id(&invocation.causal_context.authority_grant_id) {
        return Err(invalid(
            "capability::execute requires a derived least-privilege authority grant",
        ));
    }
    if matches!(
        operation,
        "job_start"
            | "job_status"
            | "job_list"
            | "job_log"
            | "job_cancel"
            | "goal_create"
            | "goal_list"
            | "goal_inspect"
            | "goal_cancel"
            | "question_create"
            | "question_list"
            | "question_inspect"
            | "question_answer"
            | "web_fetch"
            | "web_robots_check"
            | "web_source_list"
            | "web_source_inspect"
            | "web_source_archive"
            | "media_create"
            | "media_list"
            | "media_inspect"
            | "media_archive"
            | "import_history_record"
            | "import_history_list"
            | "import_history_inspect"
            | "repository_tree_snapshot"
            | "repository_tree_list"
            | "repository_tree_inspect"
            | "import_preview_record"
            | "import_preview_list"
            | "import_preview_inspect"
            | "program_execution_record"
            | "program_execution_list"
            | "program_execution_inspect"
            | "prompt_artifact_record"
            | "prompt_artifact_list"
            | "prompt_artifact_inspect"
            | "update_diagnostic_record"
            | "update_diagnostic_list"
            | "update_diagnostic_inspect"
            | "tool_source_list"
            | "tool_source_inspect"
            | "subagent_launch"
            | "subagent_status"
            | "subagent_result"
            | "subagent_cancel"
            | "subagent_task_list"
            | "subagent_task_inspect"
            | "worker_package_list"
            | "worker_package_inspect"
            | "module_list"
            | "module_inspect"
            | "module_program_execution_start"
            | "module_program_execution_status"
            | "module_program_execution_cancel"
            | "module_program_execution_cleanup"
            | "procedural_state_list"
            | "procedural_state_inspect"
            | "device_list"
            | "device_inspect"
            | "notification_send"
            | "notification_list"
            | "notification_inspect"
            | "notification_mark_read"
            | "notification_mark_all_read"
            | "context_control_snapshot"
            | "context_control_compact"
            | "context_control_clear"
            | "context_control_action_list"
            | "context_control_action_inspect"
    ) {
        require_current_session(invocation, operation)?;
    }
    if is_scheduler_operation(operation) {
        require_current_session(invocation, operation)?;
    }
    match operation {
        "state_get" | "state_set" | "state_list" => validate_state_scope(invocation),
        "trace_list"
        | "trace_get"
        | "log_recent"
        | "replay_manifest"
        | "memory_status"
        | "memory_list"
        | "memory_inspect"
        | "memory_query_list"
        | "memory_query_inspect"
        | "memory_decision_list"
        | "memory_decision_inspect"
        | "context_control_action_list"
        | "context_control_action_inspect"
        | "module_list"
        | "module_inspect"
        | "module_program_execution_status"
        | "procedural_state_list"
        | "procedural_state_inspect"
        | "device_list"
        | "device_inspect"
        | "notification_list"
        | "notification_inspect" => require_current_session(invocation, operation),
        "catalog_conformance"
        | "filesystem_write"
        | "filesystem_edit"
        | "filesystem_apply_patch"
        | "git_stage"
        | "git_unstage"
        | "git_commit"
        | "git_branch_start"
        | "job_start"
        | "job_cancel"
        | "goal_create"
        | "goal_cancel"
        | "question_create"
        | "question_answer"
        | "web_fetch"
        | "web_robots_check"
        | "web_source_archive"
        | "media_create"
        | "media_archive"
        | "import_history_record"
        | "repository_tree_snapshot"
        | "import_preview_record"
        | "program_execution_record"
        | "prompt_artifact_record"
        | "update_diagnostic_record"
        | "module_program_execution_start"
        | "module_program_execution_cancel"
        | "module_program_execution_cleanup"
        | "device_register"
        | "device_unregister"
        | "notification_send"
        | "notification_mark_read"
        | "notification_mark_all_read"
        | "context_control_snapshot"
        | "context_control_compact"
        | "context_control_clear"
        | "subagent_launch"
        | "subagent_cancel" => require_idempotency_key(invocation, operation),
        _ if requires_scheduler_idempotency(operation) => {
            require_idempotency_key(invocation, operation)
        }
        _ => Ok(()),
    }
}

fn validate_state_scope(invocation: &Invocation) -> Result<(), CapabilityError> {
    match optional_str(&invocation.payload, "scope")?.unwrap_or("session") {
        "session" => require_current_session(invocation, "state operation"),
        "workspace" => {
            if invocation.causal_context.workspace_id.is_none() {
                return Err(invalid(
                    "workspace state requires trusted workspace context",
                ));
            }
            Ok(())
        }
        "system" => Err(invalid(
            "capability::execute cannot read or write system-scoped state",
        )),
        other => Err(invalid(format!("unsupported execute state scope {other}"))),
    }
}

fn require_current_session(
    invocation: &Invocation,
    operation: &str,
) -> Result<(), CapabilityError> {
    if invocation.causal_context.session_id.is_none() {
        return Err(invalid(format!(
            "{operation} requires trusted current session context"
        )));
    }
    Ok(())
}

fn require_idempotency_key(
    invocation: &Invocation,
    operation: &str,
) -> Result<(), CapabilityError> {
    if invocation.causal_context.idempotency_key.is_none()
        && optional_str(&invocation.payload, "idempotencyKey")?.is_none()
    {
        return Err(invalid(format!(
            "{operation} writes durable evidence and requires an idempotencyKey"
        )));
    }
    Ok(())
}

fn optional_str<'a>(payload: &'a Value, field: &str) -> Result<Option<&'a str>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Ok(Some(value)),
        Some(_) => Err(invalid(format!("{field} must be a string"))),
    }
}

fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}
