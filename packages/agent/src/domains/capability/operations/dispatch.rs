use chrono::{DateTime, Utc};

use super::capability_binding::*;
use super::catalog::*;
use super::common::observe;
use super::context_control::*;
use super::device::*;
use super::filesystem::*;
use super::git::*;
use super::goals::*;
use super::import_history::*;
use super::import_preview::*;
use super::jobs::*;
use super::logs::*;
use super::media::*;
use super::memory::*;
use super::module_authoring::*;
use super::module_dependencies::*;
use super::module_install::*;
use super::module_lifecycle::*;
use super::module_manifest::*;
use super::module_program_execution::*;
use super::module_runtime::*;
use super::module_validation::*;
use super::notifications::*;
use super::operation_contract::OperationId;
use super::procedural::*;
use super::process::*;
use super::program_execution::*;
use super::prompt_artifacts::*;
use super::replay::*;
use super::repository_tree::*;
use super::scheduler::*;
use super::state::*;
use super::subagents::*;
use super::tool_sources::*;
use super::trace::*;
use super::update_diagnostics::*;
use super::web::*;
use super::web_research::*;
use super::worker_packages::*;
use crate::domains::capability::Deps;
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn execute_operation(
    operation: OperationId,
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    Ok(match operation {
        OperationId::Observe => observe(invocation)?,
        OperationId::StateGet => state_get(invocation, deps).await?,
        OperationId::StateSet => state_set(invocation, deps).await?,
        OperationId::StateList => state_list(invocation, deps).await?,
        OperationId::FilesystemRead => filesystem_read(invocation).await?,
        OperationId::FilesystemList => filesystem_list(invocation).await?,
        OperationId::FilesystemFind => filesystem_find(invocation).await?,
        OperationId::FilesystemGlob => filesystem_glob(invocation).await?,
        OperationId::FilesystemSearchText => filesystem_search_text(invocation).await?,
        OperationId::FilesystemDiff => filesystem_diff(invocation).await?,
        OperationId::FilesystemWrite => filesystem_write(invocation, deps).await?,
        OperationId::FilesystemEdit => filesystem_edit(invocation, deps).await?,
        OperationId::FilesystemApplyPatch => filesystem_apply_patch(invocation, deps).await?,
        OperationId::GitStatus => git_status(invocation, deps).await?,
        OperationId::GitDiff => git_diff(invocation).await?,
        OperationId::GitBranchInventory => git_branch_inventory(invocation).await?,
        OperationId::GitStage => git_stage(invocation, deps).await?,
        OperationId::GitUnstage => git_unstage(invocation, deps).await?,
        OperationId::GitCommit => git_commit(invocation, deps).await?,
        OperationId::GitBranchStart => git_branch_start(invocation, deps).await?,
        OperationId::ProcessRun => process_run(invocation, deps).await?,
        OperationId::JobStart => job_start(invocation, deps).await?,
        OperationId::JobStatus => job_status(invocation, deps).await?,
        OperationId::JobList => job_list(invocation, deps).await?,
        OperationId::JobLog => job_log(invocation, deps).await?,
        OperationId::JobCancel => job_cancel(invocation, deps).await?,
        OperationId::GoalCreate => goal_create(invocation, deps).await?,
        OperationId::GoalList => goal_list(invocation, deps).await?,
        OperationId::GoalInspect => goal_inspect(invocation, deps).await?,
        OperationId::GoalCancel => goal_cancel(invocation, deps).await?,
        OperationId::QuestionCreate => question_create(invocation, deps).await?,
        OperationId::QuestionList => question_list(invocation, deps).await?,
        OperationId::QuestionInspect => question_inspect(invocation, deps).await?,
        OperationId::QuestionAnswer => question_answer(invocation, deps).await?,
        OperationId::TraceList => trace_list(invocation, deps)?,
        OperationId::TraceGet => trace_get(invocation, deps)?,
        OperationId::LogRecent => log_recent(invocation, deps).await?,
        OperationId::ReplayManifest => replay_manifest(invocation, deps).await?,
        OperationId::CatalogSearch => catalog_search(invocation, deps).await?,
        OperationId::CatalogInspect => catalog_inspect(invocation, deps).await?,
        OperationId::CatalogConformance => catalog_conformance(invocation, deps).await?,
        OperationId::MemoryStatus => memory_status(invocation, deps).await?,
        OperationId::MemoryList => memory_list(invocation, deps).await?,
        OperationId::MemoryInspect => memory_inspect(invocation, deps).await?,
        OperationId::MemoryQueryList => memory_query_list(invocation, deps).await?,
        OperationId::MemoryQueryInspect => memory_query_inspect(invocation, deps).await?,
        OperationId::MemoryDecisionList => memory_decision_list(invocation, deps).await?,
        OperationId::MemoryDecisionInspect => memory_decision_inspect(invocation, deps).await?,
        OperationId::ContextControlStatus => {
            context_control_status(invocation, deps, operation_at).await?
        }
        OperationId::ContextControlSnapshot => {
            context_control_snapshot(invocation, deps, operation_at).await?
        }
        OperationId::ContextControlCompact => {
            context_control_compact(invocation, deps, operation_at).await?
        }
        OperationId::ContextControlClear => {
            context_control_clear(invocation, deps, operation_at).await?
        }
        OperationId::ContextControlActionList => {
            context_control_action_list(invocation, deps).await?
        }
        OperationId::ContextControlActionInspect => {
            context_control_action_inspect(invocation, deps).await?
        }
        OperationId::ContextSurvivorRecord => {
            context_survivor_record(invocation, deps, operation_at).await?
        }
        OperationId::ContextSurvivorList => context_survivor_list(invocation, deps).await?,
        OperationId::ContextSurvivorDisable => {
            context_survivor_disable(invocation, deps, operation_at).await?
        }
        OperationId::ContextExclusionRecord => {
            context_exclusion_record(invocation, deps, operation_at).await?
        }
        OperationId::ContextExclusionList => context_exclusion_list(invocation, deps).await?,
        OperationId::ContextExclusionDisable => {
            context_exclusion_disable(invocation, deps, operation_at).await?
        }
        OperationId::ContextPolicySnapshot => {
            context_policy_snapshot(invocation, deps, operation_at).await?
        }
        OperationId::MediaCreate => media_create(invocation, deps, operation_at).await?,
        OperationId::MediaList => media_list(invocation, deps).await?,
        OperationId::MediaInspect => media_inspect(invocation, deps).await?,
        OperationId::MediaArchive => media_archive(invocation, deps, operation_at).await?,
        OperationId::ImportHistoryRecord => {
            import_history_record(invocation, deps, operation_at).await?
        }
        OperationId::ImportHistoryList => import_history_list(invocation, deps).await?,
        OperationId::ImportHistoryInspect => import_history_inspect(invocation, deps).await?,
        OperationId::RepositoryTreeSnapshot => {
            repository_tree_snapshot(invocation, deps, operation_at).await?
        }
        OperationId::RepositoryTreeList => repository_tree_list(invocation, deps).await?,
        OperationId::RepositoryTreeInspect => repository_tree_inspect(invocation, deps).await?,
        OperationId::ImportPreviewRecord => {
            import_preview_record(invocation, deps, operation_at).await?
        }
        OperationId::ImportPreviewList => import_preview_list(invocation, deps).await?,
        OperationId::ImportPreviewInspect => import_preview_inspect(invocation, deps).await?,
        OperationId::ProgramExecutionRecord => {
            program_execution_record(invocation, deps, operation_at).await?
        }
        OperationId::ProgramExecutionList => program_execution_list(invocation, deps).await?,
        OperationId::ProgramExecutionInspect => program_execution_inspect(invocation, deps).await?,
        OperationId::PromptArtifactRecord => {
            prompt_artifact_record(invocation, deps, operation_at).await?
        }
        OperationId::PromptArtifactList => prompt_artifact_list(invocation, deps).await?,
        OperationId::PromptArtifactInspect => prompt_artifact_inspect(invocation, deps).await?,
        OperationId::UpdateDiagnosticRecord => {
            update_diagnostic_record(invocation, deps, operation_at).await?
        }
        OperationId::UpdateDiagnosticList => update_diagnostic_list(invocation, deps).await?,
        OperationId::UpdateDiagnosticInspect => update_diagnostic_inspect(invocation, deps).await?,
        OperationId::DeviceList => device_list(invocation, deps).await?,
        OperationId::DeviceInspect => device_inspect(invocation, deps).await?,
        OperationId::NotificationSend => notification_send(invocation, deps, operation_at).await?,
        OperationId::NotificationList => notification_list(invocation, deps).await?,
        OperationId::NotificationInspect => notification_inspect(invocation, deps).await?,
        OperationId::NotificationMarkRead => {
            notification_mark_read(invocation, deps, operation_at).await?
        }
        OperationId::NotificationMarkAllRead => {
            notification_mark_all_read(invocation, deps, operation_at).await?
        }
        OperationId::ProceduralDefinitionRecord => {
            procedural_definition_record(invocation, deps, operation_at).await?
        }
        OperationId::ProceduralStateList => procedural_state_list(invocation, deps).await?,
        OperationId::ProceduralStateInspect => procedural_state_inspect(invocation, deps).await?,
        OperationId::ProceduralActivationRequestRecord => {
            procedural_activation_request_record(invocation, deps, operation_at).await?
        }
        OperationId::ProceduralActivationRequestList => {
            procedural_activation_request_list(invocation, deps).await?
        }
        OperationId::ProceduralActivationRequestInspect => {
            procedural_activation_request_inspect(invocation, deps).await?
        }
        OperationId::ProceduralActivationDecisionRecord => {
            procedural_activation_decision_record(invocation, deps, operation_at).await?
        }
        OperationId::ProceduralActivationDecisionList => {
            procedural_activation_decision_list(invocation, deps).await?
        }
        OperationId::ProceduralActivationDecisionInspect => {
            procedural_activation_decision_inspect(invocation, deps).await?
        }
        OperationId::ScheduleCreate => schedule_create(invocation, deps).await?,
        OperationId::ScheduleList => schedule_list(invocation, deps).await?,
        OperationId::ScheduleInspect => schedule_inspect(invocation, deps).await?,
        OperationId::ScheduleCancel => schedule_cancel(invocation, deps).await?,
        OperationId::ScheduleFireDue => schedule_fire_due(invocation, deps).await?,
        OperationId::ToolSourceList => tool_source_list(invocation, deps).await?,
        OperationId::ToolSourceInspect => tool_source_inspect(invocation, deps).await?,
        OperationId::SubagentLaunch => subagent_launch(invocation, deps).await?,
        OperationId::SubagentStatus => subagent_status(invocation, deps).await?,
        OperationId::SubagentResult => subagent_result(invocation, deps).await?,
        OperationId::SubagentCancel => subagent_cancel(invocation, deps).await?,
        OperationId::SubagentTaskList => subagent_task_list(invocation, deps).await?,
        OperationId::SubagentTaskInspect => subagent_task_inspect(invocation, deps).await?,
        OperationId::WorkerPackageList => worker_package_list(invocation, deps).await?,
        OperationId::WorkerPackageInspect => worker_package_inspect(invocation, deps).await?,
        OperationId::ModuleList => module_list(invocation, deps).await?,
        OperationId::ModuleInspect => module_inspect(invocation, deps).await?,
        OperationId::ModuleProposalRecord => {
            module_proposal_record(invocation, deps, operation_at).await?
        }
        OperationId::ModuleProposalList => module_proposal_list(invocation, deps).await?,
        OperationId::ModuleProposalInspect => module_proposal_inspect(invocation, deps).await?,
        OperationId::ModuleValidationRecord => {
            module_validation_record(invocation, deps, operation_at).await?
        }
        OperationId::ModuleValidationList => module_validation_list(invocation, deps).await?,
        OperationId::ModuleValidationInspect => module_validation_inspect(invocation, deps).await?,
        OperationId::ModuleInstallRequestRecord => {
            module_install_request_record(invocation, deps, operation_at).await?
        }
        OperationId::ModuleInstallRequestList => {
            module_install_request_list(invocation, deps).await?
        }
        OperationId::ModuleInstallRequestInspect => {
            module_install_request_inspect(invocation, deps).await?
        }
        OperationId::ModuleInstallDecisionRecord => {
            module_install_decision_record(invocation, deps, operation_at).await?
        }
        OperationId::ModuleInstallDecisionList => {
            module_install_decision_list(invocation, deps).await?
        }
        OperationId::ModuleInstallDecisionInspect => {
            module_install_decision_inspect(invocation, deps).await?
        }
        OperationId::ModuleDependencyRequestRecord => {
            module_dependency_request_record(invocation, deps, operation_at).await?
        }
        OperationId::ModuleDependencyRequestList => {
            module_dependency_request_list(invocation, deps).await?
        }
        OperationId::ModuleDependencyRequestInspect => {
            module_dependency_request_inspect(invocation, deps).await?
        }
        OperationId::ModuleDependencyDecisionRecord => {
            module_dependency_decision_record(invocation, deps, operation_at).await?
        }
        OperationId::ModuleDependencyDecisionList => {
            module_dependency_decision_list(invocation, deps).await?
        }
        OperationId::ModuleDependencyDecisionInspect => {
            module_dependency_decision_inspect(invocation, deps).await?
        }
        OperationId::ModuleDependencyPolicyActivate => {
            module_dependency_policy_activate(invocation, deps, operation_at).await?
        }
        OperationId::ModuleDependencyPolicyList => {
            module_dependency_policy_list(invocation, deps).await?
        }
        OperationId::ModuleDependencyPolicyInspect => {
            module_dependency_policy_inspect(invocation, deps).await?
        }
        OperationId::CapabilityBindingRequestRecord => {
            capability_binding_request_record(invocation, deps, operation_at).await?
        }
        OperationId::CapabilityBindingRequestList => {
            capability_binding_request_list(invocation, deps).await?
        }
        OperationId::CapabilityBindingRequestInspect => {
            capability_binding_request_inspect(invocation, deps).await?
        }
        OperationId::CapabilityBindingDecisionRecord => {
            capability_binding_decision_record(invocation, deps, operation_at).await?
        }
        OperationId::CapabilityBindingDecisionList => {
            capability_binding_decision_list(invocation, deps).await?
        }
        OperationId::CapabilityBindingDecisionInspect => {
            capability_binding_decision_inspect(invocation, deps).await?
        }
        OperationId::CapabilityBindingPolicyActivate => {
            capability_binding_policy_activate(invocation, deps, operation_at).await?
        }
        OperationId::CapabilityBindingPolicyList => {
            capability_binding_policy_list(invocation, deps).await?
        }
        OperationId::CapabilityBindingPolicyInspect => {
            capability_binding_policy_inspect(invocation, deps).await?
        }
        OperationId::CapabilityBindingCockpitOverview => {
            capability_binding_cockpit_overview(invocation, deps).await?
        }
        OperationId::CapabilityShadowTrialRequestRecord => {
            capability_shadow_trial_request_record(invocation, deps, operation_at).await?
        }
        OperationId::CapabilityShadowTrialDecisionRecord => {
            capability_shadow_trial_decision_record(invocation, deps, operation_at).await?
        }
        OperationId::CapabilityShadowTrialRunRecord => {
            capability_shadow_trial_run_record(invocation, deps, operation_at).await?
        }
        OperationId::CapabilityShadowTrialEvidenceInspect => {
            capability_shadow_trial_evidence_inspect(invocation, deps).await?
        }
        OperationId::CapabilityReplacementCandidateRecord => {
            capability_replacement_candidate_record(invocation, deps, operation_at).await?
        }
        OperationId::CapabilityReplacementCandidateList => {
            capability_replacement_candidate_list(invocation, deps).await?
        }
        OperationId::CapabilityReplacementCandidateInspect => {
            capability_replacement_candidate_inspect(invocation, deps).await?
        }
        OperationId::CapabilityRouteBindingRecord => {
            capability_route_binding_record(invocation, deps, operation_at).await?
        }
        OperationId::CapabilityRouteBindingList => {
            capability_route_binding_list(invocation, deps).await?
        }
        OperationId::CapabilityRouteBindingInspect => {
            capability_route_binding_inspect(invocation, deps).await?
        }
        OperationId::CapabilityRouteActivate => {
            capability_route_activate(invocation, deps, operation_at).await?
        }
        OperationId::CapabilityRouteDisable => {
            capability_route_disable(invocation, deps, operation_at).await?
        }
        OperationId::CapabilityRouteRollback => {
            capability_route_rollback(invocation, deps, operation_at).await?
        }
        OperationId::CapabilityRouteEventList => {
            capability_route_event_list(invocation, deps).await?
        }
        OperationId::CapabilityRouteEventInspect => {
            capability_route_event_inspect(invocation, deps).await?
        }
        OperationId::ModuleLifecycleRequest => {
            module_lifecycle_request(invocation, deps, operation_at).await?
        }
        OperationId::ModuleLifecycleDecision => {
            module_lifecycle_decision(invocation, deps, operation_at).await?
        }
        OperationId::ModuleLifecycleList => module_lifecycle_list(invocation, deps).await?,
        OperationId::ModuleLifecycleInspect => module_lifecycle_inspect(invocation, deps).await?,
        OperationId::ModuleProgramExecutionStart => {
            module_program_execution_start(invocation, deps, operation_at).await?
        }
        OperationId::ModuleProgramExecutionStatus => {
            module_program_execution_status(invocation, deps).await?
        }
        OperationId::ModuleProgramExecutionCancel => {
            module_program_execution_cancel(invocation, deps, operation_at).await?
        }
        OperationId::ModuleProgramExecutionCleanup => {
            module_program_execution_cleanup(invocation, deps, operation_at).await?
        }
        OperationId::ModuleRuntimeRequest => {
            module_runtime_request(invocation, deps, operation_at).await?
        }
        OperationId::ModuleRuntimeList => module_runtime_list(invocation, deps).await?,
        OperationId::ModuleRuntimeInspect => module_runtime_inspect(invocation, deps).await?,
        OperationId::ModuleRuntimeCancel => {
            module_runtime_cancel(invocation, deps, operation_at).await?
        }
        OperationId::WebFetch => web_fetch(invocation, deps).await?,
        OperationId::WebRobotsCheck => web_robots_check(invocation, deps).await?,
        OperationId::WebSourceList => web_source_list(invocation, deps).await?,
        OperationId::WebSourceInspect => web_source_inspect(invocation, deps).await?,
        OperationId::WebSourceArchive => web_source_archive(invocation, deps).await?,
        OperationId::WebResearchRequestRecord => {
            web_research_request_record(invocation, deps, operation_at).await?
        }
        OperationId::WebResearchRequestList => web_research_request_list(invocation, deps).await?,
        OperationId::WebResearchRequestInspect => {
            web_research_request_inspect(invocation, deps).await?
        }
        OperationId::WebResearchReviewRecord => {
            web_research_review_record(invocation, deps, operation_at).await?
        }
        OperationId::WebResearchReviewList => web_research_review_list(invocation, deps).await?,
        OperationId::WebResearchReviewInspect => {
            web_research_review_inspect(invocation, deps).await?
        }
        OperationId::WebResearchSourceRecord => {
            web_research_source_record(invocation, deps, operation_at).await?
        }
        OperationId::WebResearchSourceList => web_research_source_list(invocation, deps).await?,
        OperationId::WebResearchSourceInspect => {
            web_research_source_inspect(invocation, deps).await?
        }
    })
}
