//! Supported model-facing `capability::execute` operation names.
//!
//! Operation names are model-visible syntax. Keep this registry as the source
//! for schema descriptions, provider guidance, catalog discovery, and
//! unsupported-operation diagnostics so the model is never handed stale spellings.

pub(crate) const SUPPORTED_OPERATION_NAMES: &[&str] = &[
    "observe",
    "state_get",
    "state_set",
    "state_list",
    "filesystem_read",
    "filesystem_list",
    "filesystem_find",
    "filesystem_glob",
    "filesystem_search_text",
    "filesystem_diff",
    "filesystem_write",
    "filesystem_edit",
    "filesystem_apply_patch",
    "git_status",
    "git_diff",
    "git_branch_inventory",
    "git_stage",
    "git_unstage",
    "git_commit",
    "git_branch_start",
    "process_run",
    "job_start",
    "job_status",
    "job_list",
    "job_log",
    "job_cancel",
    "goal_create",
    "goal_list",
    "goal_inspect",
    "goal_cancel",
    "question_create",
    "question_list",
    "question_inspect",
    "question_answer",
    "trace_list",
    "trace_get",
    "log_recent",
    "replay_manifest",
    "catalog_search",
    "catalog_inspect",
    "catalog_conformance",
    "memory_status",
    "memory_list",
    "memory_inspect",
    "memory_query_list",
    "memory_query_inspect",
    "memory_decision_list",
    "memory_decision_inspect",
    "media_create",
    "media_list",
    "media_inspect",
    "media_archive",
    "import_history_record",
    "import_history_list",
    "import_history_inspect",
    "repository_tree_snapshot",
    "repository_tree_list",
    "repository_tree_inspect",
    "import_preview_record",
    "import_preview_list",
    "import_preview_inspect",
    "program_execution_record",
    "program_execution_list",
    "program_execution_inspect",
    "prompt_artifact_record",
    "prompt_artifact_list",
    "prompt_artifact_inspect",
    "update_diagnostic_record",
    "update_diagnostic_list",
    "update_diagnostic_inspect",
    "device_register",
    "device_unregister",
    "device_list",
    "device_inspect",
    "notification_send",
    "notification_list",
    "notification_inspect",
    "notification_mark_read",
    "notification_mark_all_read",
    "procedural_definition_record",
    "procedural_state_list",
    "procedural_state_inspect",
    "procedural_activation_request_record",
    "procedural_activation_request_list",
    "procedural_activation_request_inspect",
    "procedural_activation_decision_record",
    "procedural_activation_decision_list",
    "procedural_activation_decision_inspect",
    "schedule_create",
    "schedule_list",
    "schedule_inspect",
    "schedule_cancel",
    "schedule_fire_due",
    "tool_source_list",
    "tool_source_inspect",
    "subagent_launch",
    "subagent_status",
    "subagent_result",
    "subagent_cancel",
    "subagent_task_list",
    "subagent_task_inspect",
    "worker_package_list",
    "worker_package_inspect",
    "module_list",
    "module_inspect",
    "module_proposal_record",
    "module_proposal_list",
    "module_proposal_inspect",
    "module_validation_record",
    "module_validation_list",
    "module_validation_inspect",
    "module_install_request_record",
    "module_install_request_list",
    "module_install_request_inspect",
    "module_install_decision_record",
    "module_install_decision_list",
    "module_install_decision_inspect",
    "module_dependency_request_record",
    "module_dependency_request_list",
    "module_dependency_request_inspect",
    "module_dependency_decision_record",
    "module_dependency_decision_list",
    "module_dependency_decision_inspect",
    "module_dependency_policy_activate",
    "module_dependency_policy_list",
    "module_dependency_policy_inspect",
    "module_lifecycle_request",
    "module_lifecycle_decision",
    "module_lifecycle_list",
    "module_lifecycle_inspect",
    "module_program_execution_start",
    "module_program_execution_status",
    "module_program_execution_cancel",
    "module_program_execution_cleanup",
    "module_runtime_request",
    "module_runtime_list",
    "module_runtime_inspect",
    "module_runtime_cancel",
    "web_fetch",
    "web_robots_check",
    "web_source_list",
    "web_source_inspect",
    "web_source_archive",
    "web_research_request_record",
    "web_research_request_list",
    "web_research_request_inspect",
    "web_research_review_record",
    "web_research_review_list",
    "web_research_review_inspect",
    "web_research_source_record",
    "web_research_source_list",
    "web_research_source_inspect",
];

pub(crate) fn supported_operation_names() -> &'static [&'static str] {
    SUPPORTED_OPERATION_NAMES
}

pub(crate) fn is_supported_operation(operation: &str) -> bool {
    SUPPORTED_OPERATION_NAMES.contains(&operation)
}

pub(crate) fn operation_list_text() -> String {
    match SUPPORTED_OPERATION_NAMES {
        [] => String::new(),
        [only] => (*only).to_owned(),
        names => {
            let (last, rest) = names.split_last().expect("non-empty operation names");
            format!("{}, or {}", rest.join(", "), last)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    #[test]
    fn operation_registry_has_no_duplicates() {
        let unique = SUPPORTED_OPERATION_NAMES
            .iter()
            .copied()
            .collect::<BTreeSet<_>>();
        assert_eq!(
            unique.len(),
            SUPPORTED_OPERATION_NAMES.len(),
            "supported execute operation registry must not contain duplicates"
        );
    }

    #[test]
    fn operation_registry_names_have_dispatch_arms() {
        let dispatch_source = include_str!("mod.rs");
        for operation in SUPPORTED_OPERATION_NAMES {
            let arm = format!("\"{operation}\" =>");
            assert!(
                dispatch_source.contains(&arm),
                "{operation} is model-visible but has no execute dispatch arm"
            );
        }
    }

    #[test]
    fn operation_list_text_is_model_readable() {
        let text = operation_list_text();
        assert!(text.contains("observe, state_get"));
        assert!(text.ends_with("or web_research_source_inspect"));
    }
}
