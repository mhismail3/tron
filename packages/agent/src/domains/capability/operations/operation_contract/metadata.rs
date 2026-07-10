//! Canonical ownership and evolution metadata for provider-visible operations.

use super::super::registry::is_supported_operation;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct OperationMetadata {
    pub(super) family: &'static str,
    pub(super) current_owner: &'static str,
    pub(super) ownership_class: &'static str,
    pub(super) replacement_target: &'static str,
}

pub(super) fn metadata(operation: &str) -> Option<OperationMetadata> {
    if !is_supported_operation(operation) {
        return None;
    }
    let values = match operation {
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
        "context_control_status" => (
            "context_control",
            "domains::capability::operations::context_control + domains::context_control",
            "record_plane",
            "modules_may_consume_ephemeral_context_status_but_must_not_bypass_snapshot_epoch_action_or_policy_records",
        ),
        operation if operation.starts_with("context_control_") => (
            "context_control",
            "domains::capability::operations::context_control + domains::context_control",
            "record_plane",
            "modules_may_consume_context_audit_refs_but_must_not_bypass_epoch_or_action_records",
        ),
        operation
            if operation.starts_with("context_survivor_")
                || operation.starts_with("context_exclusion_")
                || operation == "context_policy_snapshot" =>
        {
            (
                "context_control",
                "domains::capability::operations::context_control + domains::context_control",
                "record_plane",
                "modules_may_consume_context_policy_refs_but_must_not_bypass_survivor_exclusion_or_policy_snapshot_custody",
            )
        }
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
        operation if operation.starts_with("capability_replacement_") => (
            "capability_binding",
            "domains::capability::operations::capability_binding + domains::capability_binding::route",
            "governance_locked",
            "candidate_governance_pipeline",
        ),
        operation if operation.starts_with("capability_route_") => (
            "capability_binding",
            "domains::capability::operations::capability_binding + domains::capability_binding::route",
            "governance_locked",
            "runtime_route_governance_pipeline",
        ),
        operation if operation.starts_with("capability_binding_") => (
            "capability_binding",
            "domains::capability::operations::capability_binding + domains::capability_binding",
            "governance_locked",
            "binding_policy_governance_pipeline",
        ),
        operation if operation.starts_with("capability_shadow_trial_") => (
            "capability_binding",
            "domains::capability::operations::capability_binding + domains::capability_binding",
            "governance_locked",
            "shadow_trial_governance_pipeline",
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
    Some(OperationMetadata {
        family: values.0,
        current_owner: values.1,
        ownership_class: values.2,
        replacement_target: values.3,
    })
}

#[cfg(test)]
mod tests {
    use super::super::super::registry::supported_operation_names;
    use super::*;

    #[test]
    fn metadata_covers_only_supported_operations() {
        for operation in supported_operation_names() {
            assert!(
                metadata(operation).is_some(),
                "missing metadata for {operation}"
            );
        }
        assert!(metadata("filesystem_not_real").is_none());
    }
}
