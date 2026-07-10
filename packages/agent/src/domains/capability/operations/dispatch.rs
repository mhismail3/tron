use chrono::{DateTime, Utc};

use super::capability_binding::*;
use super::catalog::*;
use super::common::{observe, unsupported_operation};
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
    operation: &str,
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    Ok(match operation {
        "observe" => observe(invocation)?,
        "state_get" => state_get(invocation, deps).await?,
        "state_set" => state_set(invocation, deps).await?,
        "state_list" => state_list(invocation, deps).await?,
        "filesystem_read" => filesystem_read(invocation).await?,
        "filesystem_list" => filesystem_list(invocation).await?,
        "filesystem_find" => filesystem_find(invocation).await?,
        "filesystem_glob" => filesystem_glob(invocation).await?,
        "filesystem_search_text" => filesystem_search_text(invocation).await?,
        "filesystem_diff" => filesystem_diff(invocation).await?,
        "filesystem_write" => filesystem_write(invocation, deps).await?,
        "filesystem_edit" => filesystem_edit(invocation, deps).await?,
        "filesystem_apply_patch" => filesystem_apply_patch(invocation, deps).await?,
        "git_status" => git_status(invocation, deps).await?,
        "git_diff" => git_diff(invocation).await?,
        "git_branch_inventory" => git_branch_inventory(invocation).await?,
        "git_stage" => git_stage(invocation, deps).await?,
        "git_unstage" => git_unstage(invocation, deps).await?,
        "git_commit" => git_commit(invocation, deps).await?,
        "git_branch_start" => git_branch_start(invocation, deps).await?,
        "process_run" => process_run(invocation, deps).await?,
        "job_start" => job_start(invocation, deps).await?,
        "job_status" => job_status(invocation, deps).await?,
        "job_list" => job_list(invocation, deps).await?,
        "job_log" => job_log(invocation, deps).await?,
        "job_cancel" => job_cancel(invocation, deps).await?,
        "goal_create" => goal_create(invocation, deps).await?,
        "goal_list" => goal_list(invocation, deps).await?,
        "goal_inspect" => goal_inspect(invocation, deps).await?,
        "goal_cancel" => goal_cancel(invocation, deps).await?,
        "question_create" => question_create(invocation, deps).await?,
        "question_list" => question_list(invocation, deps).await?,
        "question_inspect" => question_inspect(invocation, deps).await?,
        "question_answer" => question_answer(invocation, deps).await?,
        "trace_list" => trace_list(invocation, deps)?,
        "trace_get" => trace_get(invocation, deps)?,
        "log_recent" => log_recent(invocation, deps).await?,
        "replay_manifest" => replay_manifest(invocation, deps).await?,
        "catalog_search" => catalog_search(invocation, deps).await?,
        "catalog_inspect" => catalog_inspect(invocation, deps).await?,
        "catalog_conformance" => catalog_conformance(invocation, deps).await?,
        "memory_status" => memory_status(invocation, deps).await?,
        "memory_list" => memory_list(invocation, deps).await?,
        "memory_inspect" => memory_inspect(invocation, deps).await?,
        "memory_query_list" => memory_query_list(invocation, deps).await?,
        "memory_query_inspect" => memory_query_inspect(invocation, deps).await?,
        "memory_decision_list" => memory_decision_list(invocation, deps).await?,
        "memory_decision_inspect" => memory_decision_inspect(invocation, deps).await?,
        "context_control_status" => context_control_status(invocation, deps, operation_at).await?,
        "context_control_snapshot" => {
            context_control_snapshot(invocation, deps, operation_at).await?
        }
        "context_control_compact" => {
            context_control_compact(invocation, deps, operation_at).await?
        }
        "context_control_clear" => context_control_clear(invocation, deps, operation_at).await?,
        "context_control_action_list" => context_control_action_list(invocation, deps).await?,
        "context_control_action_inspect" => {
            context_control_action_inspect(invocation, deps).await?
        }
        "context_survivor_record" => {
            context_survivor_record(invocation, deps, operation_at).await?
        }
        "context_survivor_list" => context_survivor_list(invocation, deps).await?,
        "context_survivor_disable" => {
            context_survivor_disable(invocation, deps, operation_at).await?
        }
        "context_exclusion_record" => {
            context_exclusion_record(invocation, deps, operation_at).await?
        }
        "context_exclusion_list" => context_exclusion_list(invocation, deps).await?,
        "context_exclusion_disable" => {
            context_exclusion_disable(invocation, deps, operation_at).await?
        }
        "context_policy_snapshot" => {
            context_policy_snapshot(invocation, deps, operation_at).await?
        }
        "media_create" => media_create(invocation, deps, operation_at).await?,
        "media_list" => media_list(invocation, deps).await?,
        "media_inspect" => media_inspect(invocation, deps).await?,
        "media_archive" => media_archive(invocation, deps, operation_at).await?,
        "import_history_record" => import_history_record(invocation, deps, operation_at).await?,
        "import_history_list" => import_history_list(invocation, deps).await?,
        "import_history_inspect" => import_history_inspect(invocation, deps).await?,
        "repository_tree_snapshot" => {
            repository_tree_snapshot(invocation, deps, operation_at).await?
        }
        "repository_tree_list" => repository_tree_list(invocation, deps).await?,
        "repository_tree_inspect" => repository_tree_inspect(invocation, deps).await?,
        "import_preview_record" => import_preview_record(invocation, deps, operation_at).await?,
        "import_preview_list" => import_preview_list(invocation, deps).await?,
        "import_preview_inspect" => import_preview_inspect(invocation, deps).await?,
        "program_execution_record" => {
            program_execution_record(invocation, deps, operation_at).await?
        }
        "program_execution_list" => program_execution_list(invocation, deps).await?,
        "program_execution_inspect" => program_execution_inspect(invocation, deps).await?,
        "prompt_artifact_record" => prompt_artifact_record(invocation, deps, operation_at).await?,
        "prompt_artifact_list" => prompt_artifact_list(invocation, deps).await?,
        "prompt_artifact_inspect" => prompt_artifact_inspect(invocation, deps).await?,
        "update_diagnostic_record" => {
            update_diagnostic_record(invocation, deps, operation_at).await?
        }
        "update_diagnostic_list" => update_diagnostic_list(invocation, deps).await?,
        "update_diagnostic_inspect" => update_diagnostic_inspect(invocation, deps).await?,
        "device_list" => device_list(invocation, deps).await?,
        "device_inspect" => device_inspect(invocation, deps).await?,
        "notification_send" => notification_send(invocation, deps, operation_at).await?,
        "notification_list" => notification_list(invocation, deps).await?,
        "notification_inspect" => notification_inspect(invocation, deps).await?,
        "notification_mark_read" => notification_mark_read(invocation, deps, operation_at).await?,
        "notification_mark_all_read" => {
            notification_mark_all_read(invocation, deps, operation_at).await?
        }
        "procedural_definition_record" => {
            procedural_definition_record(invocation, deps, operation_at).await?
        }
        "procedural_state_list" => procedural_state_list(invocation, deps).await?,
        "procedural_state_inspect" => procedural_state_inspect(invocation, deps).await?,
        "procedural_activation_request_record" => {
            procedural_activation_request_record(invocation, deps, operation_at).await?
        }
        "procedural_activation_request_list" => {
            procedural_activation_request_list(invocation, deps).await?
        }
        "procedural_activation_request_inspect" => {
            procedural_activation_request_inspect(invocation, deps).await?
        }
        "procedural_activation_decision_record" => {
            procedural_activation_decision_record(invocation, deps, operation_at).await?
        }
        "procedural_activation_decision_list" => {
            procedural_activation_decision_list(invocation, deps).await?
        }
        "procedural_activation_decision_inspect" => {
            procedural_activation_decision_inspect(invocation, deps).await?
        }
        "schedule_create" => schedule_create(invocation, deps).await?,
        "schedule_list" => schedule_list(invocation, deps).await?,
        "schedule_inspect" => schedule_inspect(invocation, deps).await?,
        "schedule_cancel" => schedule_cancel(invocation, deps).await?,
        "schedule_fire_due" => schedule_fire_due(invocation, deps).await?,
        "tool_source_list" => tool_source_list(invocation, deps).await?,
        "tool_source_inspect" => tool_source_inspect(invocation, deps).await?,
        "subagent_launch" => subagent_launch(invocation, deps).await?,
        "subagent_status" => subagent_status(invocation, deps).await?,
        "subagent_result" => subagent_result(invocation, deps).await?,
        "subagent_cancel" => subagent_cancel(invocation, deps).await?,
        "subagent_task_list" => subagent_task_list(invocation, deps).await?,
        "subagent_task_inspect" => subagent_task_inspect(invocation, deps).await?,
        "worker_package_list" => worker_package_list(invocation, deps).await?,
        "worker_package_inspect" => worker_package_inspect(invocation, deps).await?,
        "module_list" => module_list(invocation, deps).await?,
        "module_inspect" => module_inspect(invocation, deps).await?,
        "module_proposal_record" => module_proposal_record(invocation, deps, operation_at).await?,
        "module_proposal_list" => module_proposal_list(invocation, deps).await?,
        "module_proposal_inspect" => module_proposal_inspect(invocation, deps).await?,
        "module_validation_record" => {
            module_validation_record(invocation, deps, operation_at).await?
        }
        "module_validation_list" => module_validation_list(invocation, deps).await?,
        "module_validation_inspect" => module_validation_inspect(invocation, deps).await?,
        "module_install_request_record" => {
            module_install_request_record(invocation, deps, operation_at).await?
        }
        "module_install_request_list" => module_install_request_list(invocation, deps).await?,
        "module_install_request_inspect" => {
            module_install_request_inspect(invocation, deps).await?
        }
        "module_install_decision_record" => {
            module_install_decision_record(invocation, deps, operation_at).await?
        }
        "module_install_decision_list" => module_install_decision_list(invocation, deps).await?,
        "module_install_decision_inspect" => {
            module_install_decision_inspect(invocation, deps).await?
        }
        "module_dependency_request_record" => {
            module_dependency_request_record(invocation, deps, operation_at).await?
        }
        "module_dependency_request_list" => {
            module_dependency_request_list(invocation, deps).await?
        }
        "module_dependency_request_inspect" => {
            module_dependency_request_inspect(invocation, deps).await?
        }
        "module_dependency_decision_record" => {
            module_dependency_decision_record(invocation, deps, operation_at).await?
        }
        "module_dependency_decision_list" => {
            module_dependency_decision_list(invocation, deps).await?
        }
        "module_dependency_decision_inspect" => {
            module_dependency_decision_inspect(invocation, deps).await?
        }
        "module_dependency_policy_activate" => {
            module_dependency_policy_activate(invocation, deps, operation_at).await?
        }
        "module_dependency_policy_list" => module_dependency_policy_list(invocation, deps).await?,
        "module_dependency_policy_inspect" => {
            module_dependency_policy_inspect(invocation, deps).await?
        }
        "capability_binding_request_record" => {
            capability_binding_request_record(invocation, deps, operation_at).await?
        }
        "capability_binding_request_list" => {
            capability_binding_request_list(invocation, deps).await?
        }
        "capability_binding_request_inspect" => {
            capability_binding_request_inspect(invocation, deps).await?
        }
        "capability_binding_decision_record" => {
            capability_binding_decision_record(invocation, deps, operation_at).await?
        }
        "capability_binding_decision_list" => {
            capability_binding_decision_list(invocation, deps).await?
        }
        "capability_binding_decision_inspect" => {
            capability_binding_decision_inspect(invocation, deps).await?
        }
        "capability_binding_policy_activate" => {
            capability_binding_policy_activate(invocation, deps, operation_at).await?
        }
        "capability_binding_policy_list" => {
            capability_binding_policy_list(invocation, deps).await?
        }
        "capability_binding_policy_inspect" => {
            capability_binding_policy_inspect(invocation, deps).await?
        }
        "capability_binding_cockpit_overview" => {
            capability_binding_cockpit_overview(invocation, deps).await?
        }
        "capability_shadow_trial_request_record" => {
            capability_shadow_trial_request_record(invocation, deps, operation_at).await?
        }
        "capability_shadow_trial_decision_record" => {
            capability_shadow_trial_decision_record(invocation, deps, operation_at).await?
        }
        "capability_shadow_trial_run_record" => {
            capability_shadow_trial_run_record(invocation, deps, operation_at).await?
        }
        "capability_shadow_trial_evidence_inspect" => {
            capability_shadow_trial_evidence_inspect(invocation, deps).await?
        }
        "capability_replacement_candidate_record" => {
            capability_replacement_candidate_record(invocation, deps, operation_at).await?
        }
        "capability_replacement_candidate_list" => {
            capability_replacement_candidate_list(invocation, deps).await?
        }
        "capability_replacement_candidate_inspect" => {
            capability_replacement_candidate_inspect(invocation, deps).await?
        }
        "capability_route_binding_record" => {
            capability_route_binding_record(invocation, deps, operation_at).await?
        }
        "capability_route_binding_list" => capability_route_binding_list(invocation, deps).await?,
        "capability_route_binding_inspect" => {
            capability_route_binding_inspect(invocation, deps).await?
        }
        "capability_route_activate" => {
            capability_route_activate(invocation, deps, operation_at).await?
        }
        "capability_route_disable" => {
            capability_route_disable(invocation, deps, operation_at).await?
        }
        "capability_route_rollback" => {
            capability_route_rollback(invocation, deps, operation_at).await?
        }
        "capability_route_event_list" => capability_route_event_list(invocation, deps).await?,
        "capability_route_event_inspect" => {
            capability_route_event_inspect(invocation, deps).await?
        }
        "module_lifecycle_request" => {
            module_lifecycle_request(invocation, deps, operation_at).await?
        }
        "module_lifecycle_decision" => {
            module_lifecycle_decision(invocation, deps, operation_at).await?
        }
        "module_lifecycle_list" => module_lifecycle_list(invocation, deps).await?,
        "module_lifecycle_inspect" => module_lifecycle_inspect(invocation, deps).await?,
        "module_program_execution_start" => {
            module_program_execution_start(invocation, deps, operation_at).await?
        }
        "module_program_execution_status" => {
            module_program_execution_status(invocation, deps).await?
        }
        "module_program_execution_cancel" => {
            module_program_execution_cancel(invocation, deps, operation_at).await?
        }
        "module_program_execution_cleanup" => {
            module_program_execution_cleanup(invocation, deps, operation_at).await?
        }
        "module_runtime_request" => module_runtime_request(invocation, deps, operation_at).await?,
        "module_runtime_list" => module_runtime_list(invocation, deps).await?,
        "module_runtime_inspect" => module_runtime_inspect(invocation, deps).await?,
        "module_runtime_cancel" => module_runtime_cancel(invocation, deps, operation_at).await?,
        "web_fetch" => web_fetch(invocation, deps).await?,
        "web_robots_check" => web_robots_check(invocation, deps).await?,
        "web_source_list" => web_source_list(invocation, deps).await?,
        "web_source_inspect" => web_source_inspect(invocation, deps).await?,
        "web_source_archive" => web_source_archive(invocation, deps).await?,
        "web_research_request_record" => {
            web_research_request_record(invocation, deps, operation_at).await?
        }
        "web_research_request_list" => web_research_request_list(invocation, deps).await?,
        "web_research_request_inspect" => web_research_request_inspect(invocation, deps).await?,
        "web_research_review_record" => {
            web_research_review_record(invocation, deps, operation_at).await?
        }
        "web_research_review_list" => web_research_review_list(invocation, deps).await?,
        "web_research_review_inspect" => web_research_review_inspect(invocation, deps).await?,
        "web_research_source_record" => {
            web_research_source_record(invocation, deps, operation_at).await?
        }
        "web_research_source_list" => web_research_source_list(invocation, deps).await?,
        "web_research_source_inspect" => web_research_source_inspect(invocation, deps).await?,
        other => return Err(unsupported_operation(other)),
    })
}
