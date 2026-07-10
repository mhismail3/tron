//! Canonical ownership and evolution metadata for provider-visible operations.

use super::OperationId;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct OperationMetadata {
    pub(super) family: &'static str,
    pub(super) current_owner: &'static str,
    pub(super) ownership_class: &'static str,
    pub(super) replacement_target: &'static str,
}

pub(super) fn metadata(operation: OperationId) -> OperationMetadata {
    let values = match operation {
        OperationId::Observe => (
            "core",
            "domains::capability::operations::common",
            "kernel_locked",
            "kernel_diagnostic_stays_engine_owned",
        ),
        OperationId::ProcessRun => (
            "core",
            "domains::capability::operations::process",
            "adapter_replaceable",
            "future_process_adapter_requires_exact_workdir_authority_network_none_bounded_output_replay_idempotency_and_rollback_disable_refs",
        ),
        OperationId::ReplayManifest => (
            "core",
            "domains::capability::operations::replay",
            "kernel_locked",
            "replay_manifest_stays_engine_owned_audit_substrate",
        ),
        OperationId::StateGet | OperationId::StateSet | OperationId::StateList => (
            "state",
            "domains::capability::operations::state",
            "kernel_locked",
            "session_scratch_state_stays_engine_owned_until_new_state_plane",
        ),
        OperationId::TraceList | OperationId::TraceGet => (
            "trace",
            "domains::capability::operations::trace",
            "kernel_locked",
            "engine_audit_substrate_stays_engine_owned",
        ),
        OperationId::LogRecent => (
            "logs",
            "domains::capability::operations::logs",
            "kernel_locked",
            "engine_log_filter_substrate_stays_engine_owned",
        ),
        OperationId::CatalogSearch
        | OperationId::CatalogInspect
        | OperationId::CatalogConformance => (
            "catalog_discovery",
            "domains::capability::operations::catalog",
            "kernel_locked",
            "capability_catalog_trust_substrate_stays_engine_owned",
        ),
        OperationId::FilesystemRead
        | OperationId::FilesystemList
        | OperationId::FilesystemFind
        | OperationId::FilesystemGlob
        | OperationId::FilesystemSearchText
        | OperationId::FilesystemDiff
        | OperationId::FilesystemWrite
        | OperationId::FilesystemEdit
        | OperationId::FilesystemApplyPatch => (
            "filesystem",
            "domains::capability::operations::filesystem + domains::filesystem",
            "adapter_replaceable",
            "future_filesystem_adapter_requires_exact_root_authority_preview_commit_evidence_provider_safe_refs_replay_idempotency_and_rollback_disable_refs",
        ),
        OperationId::GitStatus
        | OperationId::GitDiff
        | OperationId::GitBranchInventory
        | OperationId::GitStage
        | OperationId::GitUnstage
        | OperationId::GitCommit
        | OperationId::GitBranchStart => (
            "git",
            "domains::capability::operations::git + domains::git",
            "adapter_replaceable",
            "future_git_adapter_requires_exact_repo_authority_head_index_evidence_provider_safe_refs_replay_idempotency_and_rollback_disable_refs",
        ),
        OperationId::JobStart
        | OperationId::JobStatus
        | OperationId::JobList
        | OperationId::JobLog
        | OperationId::JobCancel => (
            "jobs",
            "domains::capability::operations::jobs + domains::jobs",
            "adapter_replaceable",
            "future_jobs_adapter_requires_supervised_runtime_authority_lifecycle_evidence_provider_safe_refs_replay_idempotency_and_rollback_disable_refs",
        ),
        OperationId::GoalCreate
        | OperationId::GoalList
        | OperationId::GoalInspect
        | OperationId::GoalCancel
        | OperationId::QuestionCreate
        | OperationId::QuestionList
        | OperationId::QuestionInspect
        | OperationId::QuestionAnswer => (
            "goals_questions",
            "domains::capability::operations::goals",
            "record_plane",
            "modules_may_extend_workflows_but_must_not_bypass_durable_record_custody",
        ),
        OperationId::ScheduleCreate
        | OperationId::ScheduleList
        | OperationId::ScheduleInspect
        | OperationId::ScheduleCancel
        | OperationId::ScheduleFireDue => (
            "scheduler",
            "domains::capability::operations::scheduler + domains::scheduler",
            "record_plane",
            "modules_may_extend_scheduling_workflows_but_must_not_bypass_schedule_records",
        ),
        OperationId::ContextControlCompact => (
            "context_control",
            "domains::capability::operations::context_control + domains::context_control",
            "record_plane",
            "compaction_strategy_requires_summarizer_seam_provider_safe_summary_context_audit_records_replay_idempotency_and_rollback_disable_refs",
        ),
        OperationId::ContextControlStatus => (
            "context_control",
            "domains::capability::operations::context_control + domains::context_control",
            "record_plane",
            "modules_may_consume_ephemeral_context_status_but_must_not_bypass_snapshot_epoch_action_or_policy_records",
        ),
        OperationId::ContextControlSnapshot
        | OperationId::ContextControlClear
        | OperationId::ContextControlActionList
        | OperationId::ContextControlActionInspect => (
            "context_control",
            "domains::capability::operations::context_control + domains::context_control",
            "record_plane",
            "modules_may_consume_context_audit_refs_but_must_not_bypass_epoch_or_action_records",
        ),
        OperationId::ContextSurvivorRecord
        | OperationId::ContextSurvivorList
        | OperationId::ContextSurvivorDisable
        | OperationId::ContextExclusionRecord
        | OperationId::ContextExclusionList
        | OperationId::ContextExclusionDisable
        | OperationId::ContextPolicySnapshot => (
            "context_control",
            "domains::capability::operations::context_control + domains::context_control",
            "record_plane",
            "modules_may_consume_context_policy_refs_but_must_not_bypass_survivor_exclusion_or_policy_snapshot_custody",
        ),
        OperationId::MemoryStatus
        | OperationId::MemoryList
        | OperationId::MemoryInspect
        | OperationId::MemoryQueryList
        | OperationId::MemoryQueryInspect
        | OperationId::MemoryDecisionList
        | OperationId::MemoryDecisionInspect => (
            "memory",
            "domains::capability::operations::memory + domains::memory",
            "record_plane",
            "future_memory_modules_may_add_retrieval_or_retention_only_after_activation_policy",
        ),
        OperationId::MediaCreate
        | OperationId::MediaList
        | OperationId::MediaInspect
        | OperationId::MediaArchive => (
            "media",
            "domains::capability::operations::media + domains::media",
            "record_plane",
            "modules_may_add_media_producers_but_not_bypass_resource_custody",
        ),
        OperationId::ImportHistoryRecord
        | OperationId::ImportHistoryList
        | OperationId::ImportHistoryInspect => (
            "import_history",
            "domains::capability::operations::import_history + domains::import",
            "record_plane",
            "modules_may_add_import_producers_but_not_bypass_import_history_records",
        ),
        OperationId::RepositoryTreeSnapshot
        | OperationId::RepositoryTreeList
        | OperationId::RepositoryTreeInspect => (
            "repository_tree",
            "domains::capability::operations::repository_tree + domains::repository",
            "record_plane",
            "modules_may_add_repository_scanners_but_not_bypass_tree_snapshot_records",
        ),
        OperationId::ImportPreviewRecord
        | OperationId::ImportPreviewList
        | OperationId::ImportPreviewInspect => (
            "import_preview",
            "domains::capability::operations::import_preview + domains::import",
            "record_plane",
            "modules_may_add_preview_producers_but_not_bypass_preview_records",
        ),
        OperationId::ProgramExecutionRecord
        | OperationId::ProgramExecutionList
        | OperationId::ProgramExecutionInspect => (
            "program_execution",
            "domains::capability::operations::program_execution + domains::program_execution",
            "record_plane",
            "modules_may_add_execution_metadata_but_not_bypass_program_execution_records",
        ),
        OperationId::PromptArtifactRecord
        | OperationId::PromptArtifactList
        | OperationId::PromptArtifactInspect => (
            "prompt_artifacts",
            "domains::capability::operations::prompt_artifacts + domains::prompt_artifacts",
            "record_plane",
            "modules_may_add_prompt_artifact_producers_but_not_bypass_artifact_custody",
        ),
        OperationId::UpdateDiagnosticRecord
        | OperationId::UpdateDiagnosticList
        | OperationId::UpdateDiagnosticInspect => (
            "update_diagnostics",
            "domains::capability::operations::update_diagnostics + domains::update_diagnostics",
            "record_plane",
            "modules_may_add_diagnostics_but_not_bypass_update_diagnostic_records",
        ),
        OperationId::DeviceList | OperationId::DeviceInspect => (
            "device",
            "domains::capability::operations::device + domains::device",
            "record_plane",
            "modules_may_inspect_redacted_device_evidence_but_not_bypass_token_custody",
        ),
        OperationId::NotificationSend => (
            "notifications",
            "domains::capability::operations::notifications + domains::notifications",
            "governance_locked",
            "delivery_policy_stays_server_governed_until_push_transport_policy_exists",
        ),
        OperationId::NotificationList
        | OperationId::NotificationInspect
        | OperationId::NotificationMarkRead
        | OperationId::NotificationMarkAllRead => (
            "notifications",
            "domains::capability::operations::notifications + domains::notifications",
            "record_plane",
            "modules_may_extend_notification_workflows_but_not_bypass_inbox_delivery_records",
        ),
        OperationId::ProceduralDefinitionRecord
        | OperationId::ProceduralStateList
        | OperationId::ProceduralStateInspect
        | OperationId::ProceduralActivationRequestRecord
        | OperationId::ProceduralActivationRequestList
        | OperationId::ProceduralActivationRequestInspect
        | OperationId::ProceduralActivationDecisionRecord
        | OperationId::ProceduralActivationDecisionList
        | OperationId::ProceduralActivationDecisionInspect => (
            "procedural",
            "domains::capability::operations::procedural + domains::procedural",
            "governance_locked",
            "activation_framework_governs_future_learned_behavior",
        ),
        OperationId::ToolSourceList | OperationId::ToolSourceInspect => (
            "tool_sources",
            "domains::capability::operations::tool_sources + domains::tool_sources",
            "governance_locked",
            "tool_source_provenance_is_inspect_only_and_not_an_execution_route",
        ),
        OperationId::WorkerPackageList | OperationId::WorkerPackageInspect => (
            "worker_packages",
            "domains::capability::operations::worker_packages + domains::workers",
            "governance_locked",
            "worker_package_lifecycle_inspection_is_governance",
        ),
        OperationId::SubagentTaskList | OperationId::SubagentTaskInspect => (
            "subagents",
            "domains::capability::operations::subagents + domains::subagents",
            "record_plane",
            "modules_may_produce_subagent_task_evidence_but_not_bypass_task_custody",
        ),
        OperationId::SubagentLaunch
        | OperationId::SubagentStatus
        | OperationId::SubagentResult
        | OperationId::SubagentCancel => (
            "subagents",
            "domains::capability::operations::subagents + domains::subagents",
            "adapter_replaceable",
            "future_subagent_adapter_requires_task_runtime_authority_merge_evidence_provider_safe_refs_replay_idempotency_and_rollback_disable_refs",
        ),
        OperationId::ModuleProgramExecutionStart
        | OperationId::ModuleProgramExecutionStatus
        | OperationId::ModuleProgramExecutionCancel
        | OperationId::ModuleProgramExecutionCleanup => (
            "module_program_execution",
            "domains::capability::operations::module_program_execution + module_program_execution pack",
            "module_owned",
            "already_module_owned_template_for_supervised_replacement",
        ),
        OperationId::ModuleList | OperationId::ModuleInspect => (
            "module_registry",
            "domains::capability::operations::module_manifest + domains::module_registry",
            "governance_locked",
            "module_manifest_registry_governance_pipeline",
        ),
        OperationId::ModuleProposalRecord
        | OperationId::ModuleProposalList
        | OperationId::ModuleProposalInspect => (
            "module_authoring",
            "domains::capability::operations::module_authoring + domains::module_authoring",
            "governance_locked",
            "authoring_record_governance_pipeline",
        ),
        OperationId::ModuleValidationRecord
        | OperationId::ModuleValidationList
        | OperationId::ModuleValidationInspect => (
            "module_validation",
            "domains::capability::operations::module_validation + domains::module_validation",
            "governance_locked",
            "validation_gate_governance_pipeline",
        ),
        OperationId::ModuleInstallRequestRecord
        | OperationId::ModuleInstallRequestList
        | OperationId::ModuleInstallRequestInspect
        | OperationId::ModuleInstallDecisionRecord
        | OperationId::ModuleInstallDecisionList
        | OperationId::ModuleInstallDecisionInspect => (
            "module_install",
            "domains::capability::operations::module_install + domains::module_install",
            "governance_locked",
            "install_gate_governance_pipeline",
        ),
        OperationId::ModuleDependencyRequestRecord
        | OperationId::ModuleDependencyRequestList
        | OperationId::ModuleDependencyRequestInspect
        | OperationId::ModuleDependencyDecisionRecord
        | OperationId::ModuleDependencyDecisionList
        | OperationId::ModuleDependencyDecisionInspect
        | OperationId::ModuleDependencyPolicyActivate
        | OperationId::ModuleDependencyPolicyList
        | OperationId::ModuleDependencyPolicyInspect => (
            "module_dependencies",
            "domains::capability::operations::module_dependencies + domains::module_dependencies",
            "governance_locked",
            "dependency_policy_governance_pipeline",
        ),
        OperationId::CapabilityReplacementCandidateRecord
        | OperationId::CapabilityReplacementCandidateList
        | OperationId::CapabilityReplacementCandidateInspect => (
            "capability_binding",
            "domains::capability::operations::capability_binding + domains::capability_binding::route",
            "governance_locked",
            "candidate_governance_pipeline",
        ),
        OperationId::CapabilityRouteBindingRecord
        | OperationId::CapabilityRouteBindingList
        | OperationId::CapabilityRouteBindingInspect
        | OperationId::CapabilityRouteActivate
        | OperationId::CapabilityRouteDisable
        | OperationId::CapabilityRouteRollback
        | OperationId::CapabilityRouteEventList
        | OperationId::CapabilityRouteEventInspect => (
            "capability_binding",
            "domains::capability::operations::capability_binding + domains::capability_binding::route",
            "governance_locked",
            "runtime_route_governance_pipeline",
        ),
        OperationId::CapabilityBindingRequestRecord
        | OperationId::CapabilityBindingRequestList
        | OperationId::CapabilityBindingRequestInspect
        | OperationId::CapabilityBindingDecisionRecord
        | OperationId::CapabilityBindingDecisionList
        | OperationId::CapabilityBindingDecisionInspect
        | OperationId::CapabilityBindingPolicyActivate
        | OperationId::CapabilityBindingPolicyList
        | OperationId::CapabilityBindingPolicyInspect
        | OperationId::CapabilityBindingCockpitOverview => (
            "capability_binding",
            "domains::capability::operations::capability_binding + domains::capability_binding",
            "governance_locked",
            "binding_policy_governance_pipeline",
        ),
        OperationId::CapabilityShadowTrialRequestRecord
        | OperationId::CapabilityShadowTrialDecisionRecord
        | OperationId::CapabilityShadowTrialRunRecord
        | OperationId::CapabilityShadowTrialEvidenceInspect => (
            "capability_binding",
            "domains::capability::operations::capability_binding + domains::capability_binding",
            "governance_locked",
            "shadow_trial_governance_pipeline",
        ),
        OperationId::ModuleLifecycleRequest
        | OperationId::ModuleLifecycleDecision
        | OperationId::ModuleLifecycleList
        | OperationId::ModuleLifecycleInspect => (
            "module_lifecycle",
            "domains::capability::operations::module_lifecycle + domains::module_lifecycle",
            "governance_locked",
            "lifecycle_gate_governance_pipeline",
        ),
        OperationId::ModuleRuntimeRequest
        | OperationId::ModuleRuntimeList
        | OperationId::ModuleRuntimeInspect
        | OperationId::ModuleRuntimeCancel => (
            "module_runtime",
            "domains::capability::operations::module_runtime + domains::module_runtime",
            "governance_locked",
            "runtime_gate_governance_pipeline",
        ),
        OperationId::WebResearchRequestRecord
        | OperationId::WebResearchRequestList
        | OperationId::WebResearchRequestInspect
        | OperationId::WebResearchReviewRecord
        | OperationId::WebResearchReviewList
        | OperationId::WebResearchReviewInspect
        | OperationId::WebResearchSourceRecord
        | OperationId::WebResearchSourceList
        | OperationId::WebResearchSourceInspect => (
            "web_research",
            "domains::capability::operations::web_research + domains::web_research",
            "record_plane",
            "future_live_research_modules_may_produce_records_after_binding_policy",
        ),
        OperationId::WebFetch
        | OperationId::WebRobotsCheck
        | OperationId::WebSourceList
        | OperationId::WebSourceInspect
        | OperationId::WebSourceArchive => (
            "web",
            "domains::capability::operations::web + domains::web",
            "adapter_replaceable",
            "future_web_adapter_requires_exact_network_authority_robots_source_evidence_provider_safe_refs_replay_idempotency_and_rollback_disable_refs",
        ),
    };
    OperationMetadata {
        family: values.0,
        current_owner: values.1,
        ownership_class: values.2,
        replacement_target: values.3,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn metadata_covers_every_operation_id() {
        for operation in OperationId::ALL_NAMES {
            let operation = OperationId::parse(operation).expect("all operation names parse");
            let metadata = metadata(operation);
            assert!(!metadata.family.is_empty());
            assert!(!metadata.current_owner.is_empty());
            assert!(!metadata.ownership_class.is_empty());
            assert!(!metadata.replacement_target.is_empty());
        }
    }
}
