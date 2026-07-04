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
    "context_control_snapshot",
    "context_control_compact",
    "context_control_clear",
    "context_control_action_list",
    "context_control_action_inspect",
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
    "capability_binding_request_record",
    "capability_binding_request_list",
    "capability_binding_request_inspect",
    "capability_binding_decision_record",
    "capability_binding_decision_list",
    "capability_binding_decision_inspect",
    "capability_binding_policy_activate",
    "capability_binding_policy_list",
    "capability_binding_policy_inspect",
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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct OperationBindingMetadata {
    pub operation: &'static str,
    pub family: &'static str,
    pub current_owner: &'static str,
    pub ownership_class: &'static str,
    pub replacement_target: &'static str,
}

pub fn operation_binding_metadata(operation: &str) -> Option<OperationBindingMetadata> {
    let operation = SUPPORTED_OPERATION_NAMES
        .iter()
        .copied()
        .find(|supported| *supported == operation)?;
    let (family, current_owner, ownership_class, replacement_target) = match operation {
        "observe" => (
            "core",
            "domains::capability::operations::common",
            "kernel_locked",
            "kernel_diagnostic_stays_engine_owned",
        ),
        "process_run" => (
            "core",
            "domains::capability::operations::process",
            "adapter_replaceable",
            "future_process_adapter_requires_exact_workdir_authority_network_none_bounded_output_replay_idempotency_and_rollback_disable_refs",
        ),
        "replay_manifest" => (
            "core",
            "domains::capability::operations::replay",
            "kernel_locked",
            "replay_manifest_stays_engine_owned_audit_substrate",
        ),
        operation if operation.starts_with("state_") => (
            "state",
            "domains::capability::operations::state",
            "kernel_locked",
            "session_scratch_state_stays_engine_owned_until_new_state_plane",
        ),
        operation if operation.starts_with("trace_") => (
            "trace",
            "domains::capability::operations::trace",
            "kernel_locked",
            "engine_audit_substrate_stays_engine_owned",
        ),
        operation if operation.starts_with("log_") => (
            "logs",
            "domains::capability::operations::logs",
            "kernel_locked",
            "engine_log_filter_substrate_stays_engine_owned",
        ),
        operation if operation.starts_with("catalog_") => (
            "catalog_discovery",
            "domains::capability::operations::catalog",
            "kernel_locked",
            "capability_catalog_trust_substrate_stays_engine_owned",
        ),
        operation if operation.starts_with("filesystem_") => (
            "filesystem",
            "domains::capability::operations::filesystem + domains::filesystem",
            "adapter_replaceable",
            "future_filesystem_adapter_requires_exact_root_authority_preview_commit_evidence_provider_safe_refs_replay_idempotency_and_rollback_disable_refs",
        ),
        operation if operation.starts_with("git_") => (
            "git",
            "domains::capability::operations::git + domains::git",
            "adapter_replaceable",
            "future_git_adapter_requires_exact_repo_authority_head_index_evidence_provider_safe_refs_replay_idempotency_and_rollback_disable_refs",
        ),
        operation if operation.starts_with("job_") => (
            "jobs",
            "domains::capability::operations::jobs + domains::jobs",
            "adapter_replaceable",
            "future_jobs_adapter_requires_supervised_runtime_authority_lifecycle_evidence_provider_safe_refs_replay_idempotency_and_rollback_disable_refs",
        ),
        operation if operation.starts_with("goal_") || operation.starts_with("question_") => (
            "goals_questions",
            "domains::capability::operations::goals",
            "record_plane",
            "modules_may_extend_workflows_but_must_not_bypass_durable_record_custody",
        ),
        operation if operation.starts_with("schedule_") => (
            "scheduler",
            "domains::capability::operations::scheduler + domains::scheduler",
            "record_plane",
            "modules_may_extend_scheduling_workflows_but_must_not_bypass_schedule_records",
        ),
        "context_control_compact" => (
            "context_control",
            "domains::capability::operations::context_control + domains::context_control",
            "record_plane",
            "compaction_strategy_requires_summarizer_seam_provider_safe_summary_context_audit_records_replay_idempotency_and_rollback_disable_refs",
        ),
        operation if operation.starts_with("context_control_") => (
            "context_control",
            "domains::capability::operations::context_control + domains::context_control",
            "record_plane",
            "modules_may_consume_context_audit_refs_but_must_not_bypass_epoch_or_action_records",
        ),
        operation if operation.starts_with("memory_") => (
            "memory",
            "domains::capability::operations::memory + domains::memory",
            "record_plane",
            "future_memory_modules_may_add_retrieval_or_retention_only_after_activation_policy",
        ),
        operation if operation.starts_with("media_") => (
            "media",
            "domains::capability::operations::media + domains::media",
            "record_plane",
            "modules_may_add_media_producers_but_not_bypass_resource_custody",
        ),
        operation if operation.starts_with("import_history_") => (
            "import_history",
            "domains::capability::operations::import_history + domains::import",
            "record_plane",
            "modules_may_add_import_producers_but_not_bypass_import_history_records",
        ),
        operation if operation.starts_with("repository_tree_") => (
            "repository_tree",
            "domains::capability::operations::repository_tree + domains::repository",
            "record_plane",
            "modules_may_add_repository_scanners_but_not_bypass_tree_snapshot_records",
        ),
        operation if operation.starts_with("import_preview_") => (
            "import_preview",
            "domains::capability::operations::import_preview + domains::import",
            "record_plane",
            "modules_may_add_preview_producers_but_not_bypass_preview_records",
        ),
        operation if operation.starts_with("program_execution_") => (
            "program_execution",
            "domains::capability::operations::program_execution + domains::program_execution",
            "record_plane",
            "modules_may_add_execution_metadata_but_not_bypass_program_execution_records",
        ),
        operation if operation.starts_with("prompt_artifact_") => (
            "prompt_artifacts",
            "domains::capability::operations::prompt_artifacts + domains::prompt_artifacts",
            "record_plane",
            "modules_may_add_prompt_artifact_producers_but_not_bypass_artifact_custody",
        ),
        operation if operation.starts_with("update_diagnostic_") => (
            "update_diagnostics",
            "domains::capability::operations::update_diagnostics + domains::update_diagnostics",
            "record_plane",
            "modules_may_add_diagnostics_but_not_bypass_update_diagnostic_records",
        ),
        "device_register" | "device_unregister" => (
            "device",
            "domains::capability::operations::device + domains::device",
            "governance_locked",
            "device_token_custody_requires_trusted_internal_transport",
        ),
        operation if operation.starts_with("device_") => (
            "device",
            "domains::capability::operations::device + domains::device",
            "record_plane",
            "modules_may_inspect_redacted_device_evidence_but_not_bypass_token_custody",
        ),
        "notification_send" => (
            "notifications",
            "domains::capability::operations::notifications + domains::notifications",
            "governance_locked",
            "delivery_policy_stays_server_governed_until_push_transport_policy_exists",
        ),
        operation if operation.starts_with("notification_") => (
            "notifications",
            "domains::capability::operations::notifications + domains::notifications",
            "record_plane",
            "modules_may_extend_notification_workflows_but_not_bypass_inbox_delivery_records",
        ),
        operation if operation.starts_with("procedural_") => (
            "procedural",
            "domains::capability::operations::procedural + domains::procedural",
            "governance_locked",
            "activation_framework_governs_future_learned_behavior",
        ),
        operation if operation.starts_with("tool_source_") => (
            "tool_sources",
            "domains::capability::operations::tool_sources + domains::tool_sources",
            "governance_locked",
            "tool_source_provenance_is_inspect_only_and_not_an_execution_route",
        ),
        operation if operation.starts_with("worker_package_") => (
            "worker_packages",
            "domains::capability::operations::worker_packages + domains::workers",
            "governance_locked",
            "worker_package_lifecycle_inspection_is_governance",
        ),
        operation if operation.starts_with("subagent_task_") => (
            "subagents",
            "domains::capability::operations::subagents + domains::subagents",
            "record_plane",
            "modules_may_produce_subagent_task_evidence_but_not_bypass_task_custody",
        ),
        operation if operation.starts_with("subagent_") => (
            "subagents",
            "domains::capability::operations::subagents + domains::subagents",
            "adapter_replaceable",
            "future_subagent_adapter_requires_task_runtime_authority_merge_evidence_provider_safe_refs_replay_idempotency_and_rollback_disable_refs",
        ),
        operation if operation.starts_with("module_program_execution_") => (
            "module_program_execution",
            "domains::capability::operations::module_program_execution + module_program_execution pack",
            "module_owned",
            "already_module_owned_template_for_supervised_replacement",
        ),
        "module_list" | "module_inspect" => (
            "module_registry",
            "domains::capability::operations::module_manifest + domains::module_registry",
            "governance_locked",
            "module_manifest_registry_governance_pipeline",
        ),
        operation if operation.starts_with("module_proposal_") => (
            "module_authoring",
            "domains::capability::operations::module_authoring + domains::module_authoring",
            "governance_locked",
            "authoring_record_governance_pipeline",
        ),
        operation if operation.starts_with("module_validation_") => (
            "module_validation",
            "domains::capability::operations::module_validation + domains::module_validation",
            "governance_locked",
            "validation_gate_governance_pipeline",
        ),
        operation if operation.starts_with("module_install_") => (
            "module_install",
            "domains::capability::operations::module_install + domains::module_install",
            "governance_locked",
            "install_gate_governance_pipeline",
        ),
        operation if operation.starts_with("module_dependency_") => (
            "module_dependencies",
            "domains::capability::operations::module_dependencies + domains::module_dependencies",
            "governance_locked",
            "dependency_policy_governance_pipeline",
        ),
        operation if operation.starts_with("capability_binding_") => (
            "capability_binding",
            "domains::capability::operations::capability_binding + domains::capability_binding",
            "governance_locked",
            "binding_policy_governance_pipeline",
        ),
        operation if operation.starts_with("module_lifecycle_") => (
            "module_lifecycle",
            "domains::capability::operations::module_lifecycle + domains::module_lifecycle",
            "governance_locked",
            "lifecycle_gate_governance_pipeline",
        ),
        operation if operation.starts_with("module_runtime_") => (
            "module_runtime",
            "domains::capability::operations::module_runtime + domains::module_runtime",
            "governance_locked",
            "runtime_gate_governance_pipeline",
        ),
        operation if operation.starts_with("web_research_") => (
            "web_research",
            "domains::capability::operations::web_research + domains::web_research",
            "record_plane",
            "future_live_research_modules_may_produce_records_after_binding_policy",
        ),
        operation if operation.starts_with("web_") => (
            "web",
            "domains::capability::operations::web + domains::web",
            "adapter_replaceable",
            "future_web_adapter_requires_exact_network_authority_robots_source_evidence_provider_safe_refs_replay_idempotency_and_rollback_disable_refs",
        ),
        _ => return None,
    };
    Some(OperationBindingMetadata {
        operation,
        family,
        current_owner,
        ownership_class,
        replacement_target,
    })
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

    #[test]
    fn operation_registry_binding_metadata_covers_all_operations() {
        for operation in SUPPORTED_OPERATION_NAMES {
            let metadata = operation_binding_metadata(operation)
                .unwrap_or_else(|| panic!("{operation} lacks binding metadata"));
            assert_eq!(metadata.operation, *operation);
            assert!(!metadata.family.is_empty());
            assert!(!metadata.current_owner.is_empty());
            assert!(!metadata.ownership_class.is_empty());
            assert!(!metadata.replacement_target.is_empty());
        }
    }

    #[test]
    fn operation_registry_binding_metadata_rejects_unknown_operations() {
        assert!(operation_binding_metadata("unknown_operation").is_none());
    }

    #[test]
    fn operation_registry_binding_metadata_matches_inventory() {
        let inventory = include_str!("../../../../docs/capability-modularity-inventory.tsv");
        let rows: Vec<_> = inventory
            .lines()
            .skip(1)
            .filter(|line| !line.trim().is_empty())
            .collect();
        assert_eq!(
            rows.len(),
            SUPPORTED_OPERATION_NAMES.len(),
            "inventory must classify every supported operation once"
        );
        for line in rows {
            let columns: Vec<_> = line.split('\t').collect();
            assert_eq!(columns.len(), 15, "inventory row shape changed: {line}");
            let metadata = operation_binding_metadata(columns[0])
                .unwrap_or_else(|| panic!("inventory operation has no registry metadata: {line}"));
            assert_eq!(metadata.family, columns[1], "family drifted: {line}");
            assert_eq!(
                metadata.current_owner, columns[2],
                "currentOwner drifted: {line}"
            );
            assert_eq!(
                metadata.ownership_class, columns[3],
                "ownershipClass drifted: {line}"
            );
            assert_eq!(
                metadata.replacement_target, columns[4],
                "replacementTarget drifted: {line}"
            );
        }
    }
}
