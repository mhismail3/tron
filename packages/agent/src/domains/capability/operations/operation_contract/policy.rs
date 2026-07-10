//! Canonical invocation-context and effect policy for provider-visible operations.

use super::OperationId;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum OperationEffect {
    ReadOnly,
    MetadataWrite,
    StateChange,
    StartsWork,
}

impl OperationEffect {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::ReadOnly => "read_only",
            Self::MetadataWrite => "metadata_write",
            Self::StateChange => "state_change",
            Self::StartsWork => "starts_work",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum InvocationScope {
    None,
    CurrentSession,
    SessionOrWorkspace,
}

pub(super) fn invocation_scope(operation: &str) -> InvocationScope {
    if OperationId::parse(operation).is_none() {
        return InvocationScope::None;
    }
    if matches!(
        operation,
        "media_create"
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
            | "device_list"
            | "device_inspect"
    ) {
        return InvocationScope::SessionOrWorkspace;
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
            | "notification_send"
            | "notification_list"
            | "notification_inspect"
            | "notification_mark_read"
            | "notification_mark_all_read"
            | "context_control_status"
            | "context_control_snapshot"
            | "context_control_compact"
            | "context_control_clear"
            | "context_control_action_list"
            | "context_control_action_inspect"
            | "context_survivor_record"
            | "context_survivor_list"
            | "context_survivor_disable"
            | "context_exclusion_record"
            | "context_exclusion_list"
            | "context_exclusion_disable"
            | "context_policy_snapshot"
            | "trace_list"
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
            | "schedule_create"
            | "schedule_list"
            | "schedule_inspect"
            | "schedule_cancel"
            | "schedule_fire_due"
    ) {
        InvocationScope::CurrentSession
    } else {
        InvocationScope::None
    }
}

pub(super) fn effect(operation: &str) -> Option<OperationEffect> {
    OperationId::parse(operation).map(|_| {
        if is_read_only(operation) {
            OperationEffect::ReadOnly
        } else if starts_work(operation) {
            OperationEffect::StartsWork
        } else if writes_metadata(operation) {
            OperationEffect::MetadataWrite
        } else {
            OperationEffect::StateChange
        }
    })
}

fn is_read_only(operation: &str) -> bool {
    matches!(
        operation,
        "observe"
            | "state_get"
            | "state_list"
            | "filesystem_read"
            | "filesystem_list"
            | "filesystem_find"
            | "filesystem_glob"
            | "filesystem_search_text"
            | "filesystem_diff"
            | "git_status"
            | "git_diff"
            | "git_branch_inventory"
            | "job_status"
            | "job_list"
            | "job_log"
            | "trace_list"
            | "trace_get"
            | "log_recent"
            | "replay_manifest"
            | "catalog_search"
            | "catalog_inspect"
            | "memory_status"
            | "memory_list"
            | "memory_inspect"
            | "memory_query_list"
            | "memory_query_inspect"
            | "memory_decision_list"
            | "memory_decision_inspect"
            | "context_control_action_list"
            | "context_control_action_inspect"
            | "context_survivor_list"
            | "context_exclusion_list"
            | "subagent_status"
            | "subagent_result"
            | "subagent_task_list"
            | "subagent_task_inspect"
            | "capability_binding_cockpit_overview"
    ) || operation.ends_with("_list")
        || operation.ends_with("_inspect")
        || operation.ends_with("_status")
}

fn writes_metadata(operation: &str) -> bool {
    operation.ends_with("_record")
        || matches!(
            operation,
            "state_set"
                | "catalog_conformance"
                | "context_control_snapshot"
                | "context_control_compact"
                | "context_control_clear"
                | "context_policy_snapshot"
                | "context_survivor_disable"
                | "context_exclusion_disable"
                | "media_create"
                | "media_archive"
                | "module_lifecycle_request"
                | "module_lifecycle_decision"
                | "module_runtime_cancel"
                | "module_dependency_policy_activate"
                | "capability_binding_policy_activate"
                | "capability_route_activate"
                | "capability_route_disable"
                | "capability_route_rollback"
                | "procedural_definition_record"
                | "procedural_activation_request_record"
                | "procedural_activation_decision_record"
        )
}

fn starts_work(operation: &str) -> bool {
    matches!(
        operation,
        "process_run"
            | "job_start"
            | "subagent_launch"
            | "module_runtime_request"
            | "module_program_execution_start"
            | "schedule_fire_due"
    )
}

#[cfg(test)]
mod tests {
    use super::super::supported_operation_names;
    use super::*;

    #[test]
    fn every_supported_operation_has_one_effect() {
        for operation in supported_operation_names() {
            assert!(
                effect(operation).is_some(),
                "missing effect for {operation}"
            );
        }
        assert!(effect("not_real").is_none());
    }

    #[test]
    fn invocation_scope_distinguishes_session_and_workspace_capable_records() {
        for operation in [
            "media_create",
            "repository_tree_list",
            "program_execution_inspect",
            "device_list",
        ] {
            assert_eq!(
                invocation_scope(operation),
                InvocationScope::SessionOrWorkspace,
                "{operation}"
            );
        }
        assert_eq!(
            invocation_scope("context_control_snapshot"),
            InvocationScope::CurrentSession
        );
        assert_eq!(invocation_scope("git_status"), InvocationScope::None);
        assert_eq!(invocation_scope("not_real"), InvocationScope::None);
    }
}
