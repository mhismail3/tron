use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CATALOG_DISCOVERY_REPORT_KIND, CausalContext,
    EngineHostHandle, FunctionId, Invocation, SUBAGENT_TASK_KIND, TraceId,
};
use crate::shared::server::error_mapping::engine_error_to_failure;
use crate::shared::server::failure::{
    CAPABILITY_RESULT_INVALID, ENGINE_POLICY_VIOLATION, FailureCategory, FailureEnvelope,
    FailureOrigin,
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

pub(super) struct CapabilityRuntimeGrant {
    pub(super) grant_id: AuthorityGrantId,
    pub(super) authority_scopes: Vec<String>,
}

#[allow(clippy::too_many_arguments)]
pub(super) async fn derive_capability_runtime_grant(
    engine_host: &EngineHostHandle,
    actor_id: &ActorId,
    target_function_id: &FunctionId,
    target_authority_scopes: &[String],
    session_id: &str,
    workspace_id: Option<&str>,
    working_directory: &str,
    trace_id: &TraceId,
    invocation_id: &str,
    model_primitive_name: &str,
    turn: i64,
    run_id: Option<&str>,
    effective_args: &Value,
) -> Result<CapabilityRuntimeGrant, FailureEnvelope> {
    let operation = effective_args
        .get("operation")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let state_operation = matches!(operation, "state_get" | "state_set" | "state_list");
    let catalog_discovery_operation = is_catalog_discovery_operation(operation);
    let catalog_conformance_operation = operation == "catalog_conformance";
    let capability_binding_operation = is_capability_binding_operation(operation);
    let capability_route_operation = is_capability_route_operation(operation);
    let capability_shadow_trial_operation = is_capability_shadow_trial_operation(operation);
    let context_control_operation = matches!(
        operation,
        "context_control_status"
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
    );
    let delegated_subagent_operation = matches!(
        operation,
        "subagent_launch" | "subagent_status" | "subagent_result" | "subagent_cancel"
    );
    let diagnostic_read_operation = is_diagnostic_read_operation(operation);
    let web_network_operation = matches!(operation, "web_fetch" | "web_robots_check");
    let notification_push_requested = operation == "notification_send"
        && effective_args
            .get("pushRequested")
            .and_then(Value::as_bool)
            .unwrap_or(false);
    let web_fetch_uses_robots_policy = operation == "web_fetch"
        && has_non_empty_string(effective_args, "webRobotsPolicyResourceId")
        && has_non_empty_string(effective_args, "expectedWebRobotsPolicyVersionId");
    let mut allowed_capabilities = vec![target_function_id.as_str().to_owned()];
    if let Some(state_capability) = state_runtime_capability(operation) {
        allowed_capabilities.push(state_capability.to_owned());
    }
    allowed_capabilities.sort();
    allowed_capabilities.dedup();
    let mut allowed_authority_scopes = target_authority_scopes.to_vec();
    if state_operation {
        match operation {
            "state_get" | "state_list" => allowed_authority_scopes.push("state.read".to_owned()),
            "state_set" => allowed_authority_scopes.push("state.write".to_owned()),
            _ => {}
        }
    }
    if catalog_conformance_operation {
        allowed_authority_scopes.extend([
            "catalog_discovery.write".to_owned(),
            "resource.write".to_owned(),
        ]);
    } else if catalog_discovery_operation {
        allowed_authority_scopes.push("catalog_discovery.read".to_owned());
    } else if matches!(
        operation,
        "goal_create" | "goal_cancel" | "question_create" | "question_answer"
    ) {
        allowed_authority_scopes.extend(["goals.write".to_owned(), "resource.write".to_owned()]);
        if matches!(
            operation,
            "goal_cancel" | "question_create" | "question_answer"
        ) {
            allowed_authority_scopes.extend(["goals.read".to_owned(), "resource.read".to_owned()]);
        }
    } else if matches!(
        operation,
        "goal_list" | "goal_inspect" | "question_list" | "question_inspect"
    ) {
        allowed_authority_scopes.extend(["goals.read".to_owned(), "resource.read".to_owned()]);
    } else if operation == "web_fetch" {
        allowed_authority_scopes.extend(["resource.write".to_owned(), "web.write".to_owned()]);
        if web_fetch_uses_robots_policy {
            allowed_authority_scopes.extend(["resource.read".to_owned(), "web.read".to_owned()]);
        }
    } else if operation == "web_robots_check" {
        allowed_authority_scopes.extend([
            "resource.read".to_owned(),
            "resource.write".to_owned(),
            "web.write".to_owned(),
        ]);
    } else if matches!(operation, "web_source_list" | "web_source_inspect") {
        allowed_authority_scopes.extend(["resource.read".to_owned(), "web.read".to_owned()]);
    } else if operation == "web_source_archive" {
        allowed_authority_scopes.extend([
            "resource.read".to_owned(),
            "resource.write".to_owned(),
            "web.read".to_owned(),
            "web.write".to_owned(),
        ]);
    } else if matches!(operation, "media_list" | "media_inspect") {
        allowed_authority_scopes.extend(["media.read".to_owned(), "resource.read".to_owned()]);
    } else if matches!(operation, "media_create" | "media_archive") {
        allowed_authority_scopes.extend([
            "media.read".to_owned(),
            "media.write".to_owned(),
            "resource.read".to_owned(),
            "resource.write".to_owned(),
        ]);
    } else if matches!(operation, "import_history_list" | "import_history_inspect") {
        allowed_authority_scopes
            .extend(["import_history.read".to_owned(), "resource.read".to_owned()]);
    } else if operation == "import_history_record" {
        allowed_authority_scopes.extend([
            "import_history.read".to_owned(),
            "import_history.write".to_owned(),
            "resource.read".to_owned(),
            "resource.write".to_owned(),
        ]);
    } else if matches!(
        operation,
        "repository_tree_list" | "repository_tree_inspect"
    ) {
        allowed_authority_scopes.extend([
            "repository_tree.read".to_owned(),
            "resource.read".to_owned(),
        ]);
    } else if operation == "repository_tree_snapshot" {
        allowed_authority_scopes.extend([
            "repository_tree.read".to_owned(),
            "repository_tree.write".to_owned(),
            "resource.read".to_owned(),
            "resource.write".to_owned(),
        ]);
    } else if matches!(operation, "import_preview_list" | "import_preview_inspect") {
        allowed_authority_scopes
            .extend(["import_preview.read".to_owned(), "resource.read".to_owned()]);
    } else if operation == "import_preview_record" {
        allowed_authority_scopes.extend([
            "import_preview.read".to_owned(),
            "import_preview.write".to_owned(),
            "resource.read".to_owned(),
            "resource.write".to_owned(),
        ]);
    } else if matches!(
        operation,
        "program_execution_list" | "program_execution_inspect"
    ) {
        allowed_authority_scopes.extend([
            "program_execution.read".to_owned(),
            "resource.read".to_owned(),
        ]);
    } else if operation == "program_execution_record" {
        allowed_authority_scopes.extend([
            "program_execution.read".to_owned(),
            "program_execution.write".to_owned(),
            "resource.read".to_owned(),
            "resource.write".to_owned(),
        ]);
    } else if matches!(
        operation,
        "prompt_artifact_list" | "prompt_artifact_inspect"
    ) {
        allowed_authority_scopes.extend([
            "prompt_artifacts.read".to_owned(),
            "resource.read".to_owned(),
        ]);
    } else if operation == "prompt_artifact_record" {
        allowed_authority_scopes.extend([
            "prompt_artifacts.read".to_owned(),
            "prompt_artifacts.write".to_owned(),
            "resource.read".to_owned(),
            "resource.write".to_owned(),
        ]);
    } else if matches!(
        operation,
        "update_diagnostic_list" | "update_diagnostic_inspect"
    ) {
        allowed_authority_scopes.extend([
            "update_diagnostics.read".to_owned(),
            "resource.read".to_owned(),
        ]);
    } else if operation == "update_diagnostic_record" {
        allowed_authority_scopes.extend([
            "update_diagnostics.read".to_owned(),
            "update_diagnostics.write".to_owned(),
            "resource.read".to_owned(),
            "resource.write".to_owned(),
        ]);
    } else if matches!(
        operation,
        "memory_status"
            | "memory_list"
            | "memory_inspect"
            | "memory_query_list"
            | "memory_query_inspect"
            | "memory_decision_list"
            | "memory_decision_inspect"
    ) {
        allowed_authority_scopes.extend(["memory.read".to_owned(), "resource.read".to_owned()]);
    } else if matches!(operation, "worker_package_list" | "worker_package_inspect") {
        allowed_authority_scopes.extend([
            "worker.lifecycle.read".to_owned(),
            "resource.read".to_owned(),
        ]);
    } else if matches!(operation, "module_list" | "module_inspect") {
        allowed_authority_scopes.extend([
            "module_registry.read".to_owned(),
            "resource.read".to_owned(),
        ]);
    } else if matches!(
        operation,
        "module_proposal_list" | "module_proposal_inspect"
    ) {
        allowed_authority_scopes.extend([
            "module_authoring.read".to_owned(),
            "resource.read".to_owned(),
        ]);
    } else if operation == "module_proposal_record" {
        allowed_authority_scopes.extend([
            "module_authoring.read".to_owned(),
            "module_authoring.write".to_owned(),
            "resource.read".to_owned(),
            "resource.write".to_owned(),
        ]);
    } else if matches!(
        operation,
        "module_validation_list" | "module_validation_inspect"
    ) {
        allowed_authority_scopes.extend([
            "module_validation.read".to_owned(),
            "resource.read".to_owned(),
        ]);
    } else if operation == "module_validation_record" {
        allowed_authority_scopes.extend([
            "module_validation.read".to_owned(),
            "module_validation.write".to_owned(),
            "resource.read".to_owned(),
            "resource.write".to_owned(),
        ]);
    } else if matches!(
        operation,
        "module_install_request_list"
            | "module_install_request_inspect"
            | "module_install_decision_list"
            | "module_install_decision_inspect"
    ) {
        allowed_authority_scopes
            .extend(["module_install.read".to_owned(), "resource.read".to_owned()]);
    } else if matches!(
        operation,
        "module_install_request_record" | "module_install_decision_record"
    ) {
        allowed_authority_scopes.extend([
            "module_install.read".to_owned(),
            "module_install.write".to_owned(),
            "resource.read".to_owned(),
            "resource.write".to_owned(),
        ]);
    } else if matches!(
        operation,
        "module_dependency_request_list"
            | "module_dependency_request_inspect"
            | "module_dependency_decision_list"
            | "module_dependency_decision_inspect"
            | "module_dependency_policy_list"
            | "module_dependency_policy_inspect"
    ) {
        allowed_authority_scopes.extend([
            "module_dependencies.read".to_owned(),
            "resource.read".to_owned(),
        ]);
    } else if matches!(
        operation,
        "module_dependency_request_record"
            | "module_dependency_decision_record"
            | "module_dependency_policy_activate"
    ) {
        allowed_authority_scopes.extend([
            "module_dependencies.read".to_owned(),
            "module_dependencies.write".to_owned(),
            "resource.read".to_owned(),
            "resource.write".to_owned(),
        ]);
    } else if is_capability_binding_read_operation(operation) {
        allowed_authority_scopes.extend([
            "capability_binding.read".to_owned(),
            "resource.read".to_owned(),
        ]);
    } else if is_capability_binding_write_operation(operation) {
        allowed_authority_scopes.extend([
            "capability_binding.read".to_owned(),
            "capability_binding.write".to_owned(),
            "resource.read".to_owned(),
            "resource.write".to_owned(),
        ]);
    } else if is_capability_route_read_operation(operation) {
        allowed_authority_scopes.extend([
            "capability_binding.read".to_owned(),
            "resource.read".to_owned(),
        ]);
    } else if is_capability_route_write_operation(operation) {
        allowed_authority_scopes.extend([
            "capability_binding.read".to_owned(),
            "capability_binding.write".to_owned(),
            "resource.read".to_owned(),
            "resource.write".to_owned(),
        ]);
    } else if is_capability_shadow_trial_read_operation(operation) {
        allowed_authority_scopes.extend([
            "capability_binding.read".to_owned(),
            "resource.read".to_owned(),
        ]);
    } else if is_capability_shadow_trial_write_operation(operation) {
        allowed_authority_scopes.extend([
            "capability_binding.read".to_owned(),
            "capability_binding.write".to_owned(),
            "resource.read".to_owned(),
            "resource.write".to_owned(),
        ]);
    } else if matches!(
        operation,
        "web_research_request_list"
            | "web_research_request_inspect"
            | "web_research_review_list"
            | "web_research_review_inspect"
            | "web_research_source_list"
            | "web_research_source_inspect"
    ) {
        allowed_authority_scopes
            .extend(["web_research.read".to_owned(), "resource.read".to_owned()]);
    } else if matches!(
        operation,
        "web_research_request_record" | "web_research_review_record" | "web_research_source_record"
    ) {
        allowed_authority_scopes.extend([
            "web_research.read".to_owned(),
            "web_research.write".to_owned(),
            "resource.read".to_owned(),
            "resource.write".to_owned(),
        ]);
    } else if matches!(
        operation,
        "module_lifecycle_list" | "module_lifecycle_inspect"
    ) {
        allowed_authority_scopes.extend([
            "module_lifecycle.read".to_owned(),
            "resource.read".to_owned(),
        ]);
    } else if matches!(
        operation,
        "module_lifecycle_request" | "module_lifecycle_decision"
    ) {
        allowed_authority_scopes.extend([
            "module_lifecycle.read".to_owned(),
            "module_lifecycle.write".to_owned(),
            "resource.read".to_owned(),
            "resource.write".to_owned(),
        ]);
    } else if matches!(operation, "module_runtime_list" | "module_runtime_inspect") {
        allowed_authority_scopes
            .extend(["module_runtime.read".to_owned(), "resource.read".to_owned()]);
    } else if matches!(
        operation,
        "module_runtime_request" | "module_runtime_cancel"
    ) {
        allowed_authority_scopes.extend([
            "module_runtime.read".to_owned(),
            "module_runtime.write".to_owned(),
            "resource.read".to_owned(),
            "resource.write".to_owned(),
        ]);
    } else if matches!(
        operation,
        "context_control_status"
            | "context_control_action_list"
            | "context_control_action_inspect"
            | "context_survivor_list"
            | "context_exclusion_list"
    ) {
        allowed_authority_scopes.extend([
            "context_control.read".to_owned(),
            "resource.read".to_owned(),
        ]);
    } else if matches!(
        operation,
        "context_control_snapshot"
            | "context_control_compact"
            | "context_control_clear"
            | "context_survivor_record"
            | "context_survivor_disable"
            | "context_exclusion_record"
            | "context_exclusion_disable"
            | "context_policy_snapshot"
    ) {
        allowed_authority_scopes.extend([
            "context_control.read".to_owned(),
            "context_control.write".to_owned(),
            "resource.read".to_owned(),
            "resource.write".to_owned(),
        ]);
    } else if operation == "module_program_execution_start" {
        allowed_authority_scopes.extend([
            "module_runtime.read".to_owned(),
            "module_runtime.write".to_owned(),
            "program_execution.read".to_owned(),
            "program_execution.write".to_owned(),
            "jobs.read".to_owned(),
            "jobs.write".to_owned(),
            "resource.read".to_owned(),
            "resource.write".to_owned(),
        ]);
    } else if operation == "module_program_execution_status" {
        allowed_authority_scopes.extend([
            "module_runtime.read".to_owned(),
            "program_execution.read".to_owned(),
            "jobs.read".to_owned(),
            "resource.read".to_owned(),
        ]);
    } else if matches!(
        operation,
        "module_program_execution_cancel" | "module_program_execution_cleanup"
    ) {
        allowed_authority_scopes.extend([
            "module_runtime.read".to_owned(),
            "module_runtime.write".to_owned(),
            "program_execution.read".to_owned(),
            "jobs.read".to_owned(),
            "jobs.write".to_owned(),
            "resource.read".to_owned(),
            "resource.write".to_owned(),
        ]);
    } else if operation == "job_start" {
        allowed_authority_scopes.extend(["jobs.write".to_owned(), "resource.write".to_owned()]);
    } else if matches!(operation, "job_status" | "job_list" | "job_log") {
        allowed_authority_scopes.extend(["jobs.read".to_owned(), "resource.read".to_owned()]);
    } else if operation == "job_cancel" {
        allowed_authority_scopes.extend([
            "jobs.read".to_owned(),
            "jobs.write".to_owned(),
            "resource.read".to_owned(),
            "resource.write".to_owned(),
        ]);
    } else if matches!(
        operation,
        "filesystem_read"
            | "filesystem_list"
            | "filesystem_find"
            | "filesystem_glob"
            | "filesystem_search_text"
            | "filesystem_diff"
    ) {
        allowed_authority_scopes.extend(["filesystem.read".to_owned(), "resource.read".to_owned()]);
    } else if matches!(
        operation,
        "filesystem_write" | "filesystem_edit" | "filesystem_apply_patch"
    ) {
        allowed_authority_scopes.extend([
            "filesystem.read".to_owned(),
            "filesystem.write".to_owned(),
            "resource.read".to_owned(),
            "resource.write".to_owned(),
        ]);
    } else if matches!(
        operation,
        "git_status" | "git_diff" | "git_branch_inventory"
    ) {
        allowed_authority_scopes.extend(["git.read".to_owned(), "resource.read".to_owned()]);
    } else if matches!(
        operation,
        "git_stage" | "git_unstage" | "git_commit" | "git_branch_start"
    ) {
        allowed_authority_scopes.extend([
            "git.read".to_owned(),
            "git.write".to_owned(),
            "resource.write".to_owned(),
        ]);
    } else if matches!(
        operation,
        "procedural_state_list"
            | "procedural_state_inspect"
            | "procedural_activation_request_list"
            | "procedural_activation_request_inspect"
            | "procedural_activation_decision_list"
            | "procedural_activation_decision_inspect"
    ) {
        allowed_authority_scopes.extend(["procedural.read".to_owned(), "resource.read".to_owned()]);
    } else if matches!(
        operation,
        "procedural_definition_record"
            | "procedural_activation_request_record"
            | "procedural_activation_decision_record"
    ) {
        allowed_authority_scopes.extend([
            "procedural.read".to_owned(),
            "procedural.write".to_owned(),
            "resource.read".to_owned(),
            "resource.write".to_owned(),
        ]);
    } else if matches!(
        operation,
        "subagent_status" | "subagent_result" | "subagent_task_list" | "subagent_task_inspect"
    ) {
        allowed_authority_scopes.extend(["subagents.read".to_owned(), "resource.read".to_owned()]);
    } else if matches!(operation, "subagent_launch" | "subagent_cancel") {
        allowed_authority_scopes.extend([
            "subagents.read".to_owned(),
            "subagents.write".to_owned(),
            "resource.read".to_owned(),
            "resource.write".to_owned(),
        ]);
    } else if matches!(operation, "device_list" | "device_inspect") {
        allowed_authority_scopes.extend(["device.read".to_owned(), "resource.read".to_owned()]);
    } else if matches!(operation, "notification_list" | "notification_inspect") {
        allowed_authority_scopes
            .extend(["notifications.read".to_owned(), "resource.read".to_owned()]);
    } else if matches!(
        operation,
        "notification_send" | "notification_mark_read" | "notification_mark_all_read"
    ) {
        allowed_authority_scopes.extend([
            "notifications.read".to_owned(),
            "notifications.write".to_owned(),
            "resource.read".to_owned(),
            "resource.write".to_owned(),
        ]);
        if notification_push_requested {
            allowed_authority_scopes.push("device.read".to_owned());
        }
    }
    if delegated_subagent_operation {
        allowed_authority_scopes.extend(delegated_subagent_module_scopes(operation));
    }
    allowed_authority_scopes.sort();
    allowed_authority_scopes.dedup();
    let network_policy = if web_network_operation {
        "declared"
    } else {
        "none"
    };
    let mut allowed_resource_kinds = if state_operation {
        vec!["agent_state".to_owned()]
    } else {
        Vec::new()
    };
    if state_operation {
        // State is the only execute operation family allowed to carry the
        // scratch-state resource kind. Every other operation must declare its
        // own resource custody below.
    } else if catalog_conformance_operation {
        allowed_resource_kinds.push(CATALOG_DISCOVERY_REPORT_KIND.to_owned());
    } else if diagnostic_read_operation {
        allowed_resource_kinds.extend(diagnostic_read_resource_kinds(operation));
    } else if matches!(
        operation,
        "goal_create" | "goal_list" | "goal_inspect" | "goal_cancel"
    ) {
        allowed_resource_kinds.push("goal".to_owned());
    } else if operation == "question_create" {
        if effective_args.get("goalResourceId").is_some() {
            allowed_resource_kinds.push("goal".to_owned());
        }
        allowed_resource_kinds.push("user_question".to_owned());
    } else if matches!(operation, "question_list" | "question_inspect") {
        allowed_resource_kinds.push("user_question".to_owned());
    } else if operation == "question_answer" {
        allowed_resource_kinds.extend(["user_question".to_owned(), "goal_answer".to_owned()]);
    } else if operation == "web_robots_check" {
        allowed_resource_kinds.push("web_robots_policy".to_owned());
    } else if matches!(
        operation,
        "web_fetch" | "web_source_list" | "web_source_inspect" | "web_source_archive"
    ) {
        allowed_resource_kinds.push("web_source".to_owned());
        if web_fetch_uses_robots_policy {
            allowed_resource_kinds.push("web_robots_policy".to_owned());
        }
    } else if matches!(
        operation,
        "media_create" | "media_list" | "media_inspect" | "media_archive"
    ) {
        allowed_resource_kinds.push("media_artifact".to_owned());
    } else if matches!(
        operation,
        "import_history_record" | "import_history_list" | "import_history_inspect"
    ) {
        allowed_resource_kinds.push("import_history_record".to_owned());
    } else if matches!(
        operation,
        "repository_tree_snapshot" | "repository_tree_list" | "repository_tree_inspect"
    ) {
        allowed_resource_kinds.push("repository_tree_snapshot".to_owned());
    } else if matches!(
        operation,
        "import_preview_record" | "import_preview_list" | "import_preview_inspect"
    ) {
        allowed_resource_kinds.push("import_preview".to_owned());
    } else if matches!(
        operation,
        "program_execution_record" | "program_execution_list" | "program_execution_inspect"
    ) {
        allowed_resource_kinds.push("program_execution_record".to_owned());
    } else if matches!(
        operation,
        "prompt_artifact_record" | "prompt_artifact_list" | "prompt_artifact_inspect"
    ) {
        allowed_resource_kinds.push("prompt_artifact".to_owned());
    } else if matches!(
        operation,
        "update_diagnostic_record" | "update_diagnostic_list" | "update_diagnostic_inspect"
    ) {
        allowed_resource_kinds.push("update_diagnostic_record".to_owned());
    } else if operation == "memory_status" {
        allowed_resource_kinds.extend(["memory_policy".to_owned(), "memory_engine".to_owned()]);
    } else if matches!(operation, "memory_list" | "memory_inspect") {
        allowed_resource_kinds.push("memory_record".to_owned());
    } else if matches!(operation, "memory_query_list" | "memory_query_inspect") {
        allowed_resource_kinds.push("memory_query".to_owned());
    } else if matches!(
        operation,
        "memory_decision_list" | "memory_decision_inspect"
    ) {
        allowed_resource_kinds.push("memory_decision".to_owned());
    } else if operation == "worker_package_list" {
        if let Some(kind) = worker_package_list_kind(effective_args) {
            allowed_resource_kinds.push(kind.to_owned());
        }
    } else if operation == "worker_package_inspect"
        && let Some(kind) = worker_package_inspect_kind(effective_args)
    {
        allowed_resource_kinds.push(kind.to_owned());
    } else if matches!(operation, "module_list" | "module_inspect") {
        allowed_resource_kinds.push("module_manifest".to_owned());
    } else if matches!(
        operation,
        "module_proposal_record" | "module_proposal_list" | "module_proposal_inspect"
    ) {
        allowed_resource_kinds.push("module_proposal".to_owned());
    } else if matches!(
        operation,
        "module_validation_record" | "module_validation_list" | "module_validation_inspect"
    ) {
        allowed_resource_kinds.push("module_validation_report".to_owned());
    } else if matches!(
        operation,
        "module_install_request_record"
            | "module_install_request_list"
            | "module_install_request_inspect"
            | "module_install_decision_record"
            | "module_install_decision_list"
            | "module_install_decision_inspect"
    ) {
        allowed_resource_kinds.extend([
            "module_install_request".to_owned(),
            "module_install_decision".to_owned(),
        ]);
    } else if matches!(
        operation,
        "module_dependency_request_record"
            | "module_dependency_request_list"
            | "module_dependency_request_inspect"
            | "module_dependency_decision_record"
            | "module_dependency_decision_list"
            | "module_dependency_decision_inspect"
            | "module_dependency_policy_activate"
            | "module_dependency_policy_list"
            | "module_dependency_policy_inspect"
    ) {
        allowed_resource_kinds.extend([
            "module_dependency_request".to_owned(),
            "module_dependency_decision".to_owned(),
            "module_dependency_policy".to_owned(),
        ]);
    } else if capability_binding_operation {
        allowed_resource_kinds.extend(capability_binding_resource_kinds(operation));
    } else if capability_route_operation {
        allowed_resource_kinds.extend(capability_route_resource_kinds());
    } else if capability_shadow_trial_operation {
        allowed_resource_kinds.extend(capability_shadow_trial_resource_kinds());
    } else if matches!(
        operation,
        "web_research_request_record"
            | "web_research_request_list"
            | "web_research_request_inspect"
            | "web_research_review_record"
            | "web_research_review_list"
            | "web_research_review_inspect"
            | "web_research_source_record"
            | "web_research_source_list"
            | "web_research_source_inspect"
    ) {
        allowed_resource_kinds.extend([
            "web_research_request".to_owned(),
            "web_research_review".to_owned(),
            "web_research_source".to_owned(),
        ]);
    } else if matches!(
        operation,
        "module_lifecycle_request"
            | "module_lifecycle_decision"
            | "module_lifecycle_list"
            | "module_lifecycle_inspect"
    ) {
        allowed_resource_kinds.push("module_lifecycle_state".to_owned());
    } else if matches!(
        operation,
        "module_runtime_request"
            | "module_runtime_list"
            | "module_runtime_inspect"
            | "module_runtime_cancel"
    ) {
        allowed_resource_kinds.push("module_runtime_state".to_owned());
        if operation == "module_runtime_request" {
            allowed_resource_kinds.push("module_lifecycle_state".to_owned());
        }
    } else if context_control_operation {
        allowed_resource_kinds.extend([
            "context_control_snapshot".to_owned(),
            "context_control_action".to_owned(),
            "context_control_epoch".to_owned(),
            "context_survivor".to_owned(),
            "context_exclusion".to_owned(),
            "context_policy_snapshot".to_owned(),
        ]);
    } else if operation == "module_program_execution_start" {
        allowed_resource_kinds.extend([
            "module_runtime_state".to_owned(),
            "module_lifecycle_state".to_owned(),
            "program_execution_record".to_owned(),
            "job_process".to_owned(),
            "execution_output".to_owned(),
        ]);
    } else if matches!(
        operation,
        "module_program_execution_status"
            | "module_program_execution_cancel"
            | "module_program_execution_cleanup"
    ) {
        allowed_resource_kinds.extend([
            "module_runtime_state".to_owned(),
            "program_execution_record".to_owned(),
            "job_process".to_owned(),
            "execution_output".to_owned(),
        ]);
    } else if matches!(
        operation,
        "job_start" | "job_status" | "job_list" | "job_log" | "job_cancel"
    ) {
        allowed_resource_kinds.extend(["job_process".to_owned(), "execution_output".to_owned()]);
    } else if matches!(
        operation,
        "filesystem_read"
            | "filesystem_list"
            | "filesystem_find"
            | "filesystem_glob"
            | "filesystem_search_text"
            | "filesystem_diff"
    ) {
        allowed_resource_kinds.push("materialized_file".to_owned());
    } else if matches!(
        operation,
        "filesystem_write" | "filesystem_edit" | "filesystem_apply_patch"
    ) {
        allowed_resource_kinds
            .extend(["patch_proposal".to_owned(), "materialized_file".to_owned()]);
    } else if matches!(
        operation,
        "git_status" | "git_diff" | "git_branch_inventory"
    ) {
        allowed_resource_kinds.extend([
            "git_index_change".to_owned(),
            "git_commit".to_owned(),
            "git_branch_start".to_owned(),
        ]);
    } else if matches!(operation, "git_stage" | "git_unstage") {
        allowed_resource_kinds.push("git_index_change".to_owned());
    } else if operation == "git_commit" {
        allowed_resource_kinds.push("git_commit".to_owned());
    } else if operation == "git_branch_start" {
        allowed_resource_kinds.push("git_branch_start".to_owned());
    } else if matches!(
        operation,
        "subagent_launch"
            | "subagent_status"
            | "subagent_result"
            | "subagent_cancel"
            | "subagent_task_list"
            | "subagent_task_inspect"
    ) {
        allowed_resource_kinds.push("subagent_task".to_owned());
        if delegated_subagent_operation {
            allowed_resource_kinds.extend(delegated_subagent_module_resource_kinds(operation));
        }
    } else if is_procedural_module_operation(operation) && procedural_kind(effective_args).is_some()
    {
        allowed_resource_kinds.extend(procedural_resource_kinds(operation));
    } else if matches!(operation, "device_list" | "device_inspect") {
        allowed_resource_kinds.push("device_registration".to_owned());
    } else if operation == "notification_list" {
        allowed_resource_kinds.push("notification".to_owned());
    } else if operation == "notification_inspect" {
        allowed_resource_kinds.extend([
            "notification".to_owned(),
            "notification_delivery".to_owned(),
        ]);
    } else if matches!(
        operation,
        "notification_send" | "notification_mark_read" | "notification_mark_all_read"
    ) {
        allowed_resource_kinds.extend([
            "notification".to_owned(),
            "notification_delivery".to_owned(),
        ]);
        if notification_push_requested {
            allowed_resource_kinds.push("device_registration".to_owned());
        }
    }
    let mut resource_selectors = allowed_resource_kinds
        .iter()
        .map(|kind| format!("kind:{kind}"))
        .collect::<Vec<_>>();
    if context_control_operation {
        resource_selectors.push(format!("session:{session_id}"));
    }
    if capability_route_operation || operation == "capability_binding_cockpit_overview" {
        resource_selectors.push(format!("session:{session_id}"));
    }
    for (operations, field) in exact_resource_selector_fields() {
        if operations.contains(&operation) {
            push_resource_selector_arg(&mut resource_selectors, effective_args, field);
        }
    }
    if operation == "module_lifecycle_request" {
        push_module_lifecycle_request_selector(&mut resource_selectors, session_id, effective_args);
    }
    if operation == "module_runtime_request" {
        push_module_runtime_request_selector(&mut resource_selectors, session_id, effective_args);
    }
    if operation == "module_program_execution_start" {
        push_module_runtime_request_selector(&mut resource_selectors, session_id, effective_args);
    }
    if operation == "subagent_launch" {
        push_resource_selector_arg(
            &mut resource_selectors,
            effective_args,
            "moduleLifecycleResourceId",
        );
        push_module_runtime_request_selector(&mut resource_selectors, session_id, effective_args);
        push_subagent_launch_selector(
            &mut resource_selectors,
            session_id,
            workspace_id,
            working_directory,
            invocation_id,
            model_primitive_name,
            turn,
            run_id,
            effective_args,
        );
    } else if matches!(
        operation,
        "subagent_status" | "subagent_result" | "subagent_cancel"
    ) {
        push_resource_selector_arg(
            &mut resource_selectors,
            effective_args,
            "subagentTaskResourceId",
        );
        push_delegated_subagent_followup_selectors(
            engine_host,
            &mut resource_selectors,
            effective_args,
        )
        .await?;
    }
    if matches!(
        operation,
        "procedural_definition_record"
            | "procedural_state_list"
            | "procedural_state_inspect"
            | "procedural_activation_request_record"
            | "procedural_activation_request_list"
            | "procedural_activation_request_inspect"
            | "procedural_activation_decision_record"
            | "procedural_activation_decision_list"
            | "procedural_activation_decision_inspect"
    ) && let Some(kind) = procedural_kind(effective_args)
    {
        resource_selectors.push(format!("proceduralKind:{kind}"));
    }
    let idempotency_material = json!({
        "version": 1,
        "sessionId": session_id,
        "workspaceId": workspace_id,
        "workingDirectory": working_directory,
        "actorId": actor_id.as_str(),
        "targetFunctionId": target_function_id.as_str(),
        "targetAuthorityScopes": target_authority_scopes,
        "providerInvocationId": invocation_id,
        "modelPrimitiveName": model_primitive_name,
        "operation": operation,
        "turn": turn,
        "runId": run_id
    });
    let idempotency_key = format!(
        "capability-runtime-grant:v1:{}",
        sha256_hex(
            serde_json::to_string(&idempotency_material)
                .unwrap_or_else(|_| "{}".to_owned())
                .as_bytes()
        )
    );
    let derive_context = CausalContext::new(
        ActorId::new("system:capability-runtime")
            .map_err(|error| engine_error_to_failure(&error))?,
        ActorKind::System,
        AuthorityGrantId::new("grant").map_err(|error| engine_error_to_failure(&error))?,
        trace_id.clone(),
    )
    .with_scope("grant.write")
    .with_session_id(session_id.to_owned())
    .with_idempotency_key(idempotency_key);
    let payload = json!({
        "parentGrantId": "agent-capability-runtime",
        "subjectActorId": actor_id.as_str(),
        "allowedCapabilities": allowed_capabilities,
        "allowedNamespaces": ["__no_namespace_authority__"],
        "allowedAuthorityScopes": allowed_authority_scopes.clone(),
        "allowedResourceKinds": allowed_resource_kinds,
        "resourceSelectors": resource_selectors,
        "fileRoots": [working_directory],
        "networkPolicy": network_policy,
        "maxRisk": "medium",
        "budget": {
            "remainingInvocations": 2,
            "remainingProcessMs": 120000
        },
        "canDelegate": false,
        "provenance": {
            "source": "agent.capability_runtime",
            "sessionId": session_id,
            "workspaceId": workspace_id,
            "targetFunctionId": target_function_id.as_str(),
            "providerInvocationId": invocation_id,
            "modelPrimitiveName": model_primitive_name,
            "operation": operation,
            "turn": turn,
            "runId": run_id,
            "workingDirectory": working_directory,
            "networkPolicy": network_policy
        }
    });
    let result = engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("grant::derive").map_err(|error| engine_error_to_failure(&error))?,
            payload,
            derive_context,
        ))
        .await;
    if let Some(error) = result.error {
        return Err(engine_error_to_failure(&error));
    }
    let value = result.value.ok_or_else(|| {
        FailureEnvelope::new(
            ENGINE_POLICY_VIOLATION,
            FailureCategory::Engine,
            "Capability runtime grant derivation returned no value",
            false,
            false,
            FailureOrigin::Engine,
        )
    })?;
    let grant_id = value
        .get("grant")
        .and_then(|grant| grant.get("grantId"))
        .and_then(Value::as_str)
        .ok_or_else(|| {
            FailureEnvelope::new(
                CAPABILITY_RESULT_INVALID,
                FailureCategory::Parse,
                "Capability runtime grant derivation returned an invalid grant payload",
                false,
                false,
                FailureOrigin::Engine,
            )
        })?;
    let grant_id = AuthorityGrantId::new(grant_id.to_owned())
        .map_err(|error| engine_error_to_failure(&error))?;
    let causal_authority_scopes = allowed_authority_scopes
        .into_iter()
        .filter(|scope| {
            matches!(scope.as_str(), "capability.execute")
                || operation.starts_with("state_")
                || !matches!(scope.as_str(), "state.read" | "state.write")
        })
        .collect();
    Ok(CapabilityRuntimeGrant {
        grant_id,
        authority_scopes: causal_authority_scopes,
    })
}

fn has_non_empty_string(value: &Value, field: &str) -> bool {
    value
        .get(field)
        .and_then(Value::as_str)
        .is_some_and(|item| !item.trim().is_empty())
}

fn is_catalog_discovery_operation(operation: &str) -> bool {
    matches!(
        operation,
        "catalog_search" | "catalog_inspect" | "catalog_conformance"
    )
}

fn is_diagnostic_read_operation(operation: &str) -> bool {
    matches!(
        operation,
        "trace_list" | "trace_get" | "log_recent" | "replay_manifest"
    )
}

fn diagnostic_read_resource_kinds(operation: &str) -> Vec<String> {
    match operation {
        "trace_list" | "trace_get" => vec!["trace_record".to_owned()],
        "log_recent" => vec!["log_entry".to_owned()],
        "replay_manifest" => vec!["session".to_owned()],
        _ => Vec::new(),
    }
}

fn state_runtime_capability(operation: &str) -> Option<&'static str> {
    match operation {
        "state_get" => Some("state::get"),
        "state_set" => Some("state::set"),
        "state_list" => Some("state::list"),
        _ => None,
    }
}

fn is_capability_route_operation(operation: &str) -> bool {
    is_capability_route_read_operation(operation) || is_capability_route_write_operation(operation)
}

fn is_capability_shadow_trial_operation(operation: &str) -> bool {
    is_capability_shadow_trial_read_operation(operation)
        || is_capability_shadow_trial_write_operation(operation)
}

fn is_capability_binding_operation(operation: &str) -> bool {
    is_capability_binding_read_operation(operation)
        || is_capability_binding_write_operation(operation)
}

fn is_capability_binding_read_operation(operation: &str) -> bool {
    matches!(
        operation,
        "capability_binding_cockpit_overview"
            | "capability_binding_request_list"
            | "capability_binding_request_inspect"
            | "capability_binding_decision_list"
            | "capability_binding_decision_inspect"
            | "capability_binding_policy_list"
            | "capability_binding_policy_inspect"
    )
}

fn is_capability_binding_write_operation(operation: &str) -> bool {
    matches!(
        operation,
        "capability_binding_request_record"
            | "capability_binding_decision_record"
            | "capability_binding_policy_activate"
    )
}

fn capability_binding_resource_kinds(operation: &str) -> Vec<String> {
    match operation {
        "capability_binding_cockpit_overview" => {
            let mut kinds = vec![
                "capability_binding_request".to_owned(),
                "capability_binding_decision".to_owned(),
                "capability_binding_policy".to_owned(),
            ];
            kinds.extend(capability_route_resource_kinds());
            kinds.sort();
            kinds.dedup();
            kinds
        }
        "capability_binding_request_record"
        | "capability_binding_request_list"
        | "capability_binding_request_inspect" => vec!["capability_binding_request".to_owned()],
        "capability_binding_decision_record" => vec![
            "capability_binding_request".to_owned(),
            "capability_binding_decision".to_owned(),
        ],
        "capability_binding_decision_list" | "capability_binding_decision_inspect" => {
            vec!["capability_binding_decision".to_owned()]
        }
        "capability_binding_policy_activate" => vec![
            "capability_binding_decision".to_owned(),
            "capability_binding_policy".to_owned(),
        ],
        "capability_binding_policy_list" | "capability_binding_policy_inspect" => {
            vec!["capability_binding_policy".to_owned()]
        }
        _ => Vec::new(),
    }
}

fn is_capability_route_read_operation(operation: &str) -> bool {
    matches!(
        operation,
        "capability_replacement_candidate_list"
            | "capability_replacement_candidate_inspect"
            | "capability_route_binding_list"
            | "capability_route_binding_inspect"
            | "capability_route_event_list"
            | "capability_route_event_inspect"
    )
}

fn is_capability_route_write_operation(operation: &str) -> bool {
    matches!(
        operation,
        "capability_replacement_candidate_record"
            | "capability_route_binding_record"
            | "capability_route_activate"
            | "capability_route_disable"
            | "capability_route_rollback"
    )
}

fn is_capability_shadow_trial_read_operation(operation: &str) -> bool {
    operation == "capability_shadow_trial_evidence_inspect"
}

fn is_capability_shadow_trial_write_operation(operation: &str) -> bool {
    matches!(
        operation,
        "capability_shadow_trial_request_record"
            | "capability_shadow_trial_decision_record"
            | "capability_shadow_trial_run_record"
    )
}

fn capability_route_resource_kinds() -> Vec<String> {
    vec![
        "capability_replacement_candidate".to_owned(),
        "capability_route_binding".to_owned(),
        "capability_route_activation".to_owned(),
        "capability_route_event".to_owned(),
        "capability_route_rollback".to_owned(),
        "capability_shadow_trial_evidence".to_owned(),
        "capability_shadow_trial_run".to_owned(),
        "capability_shadow_trial_decision".to_owned(),
        "capability_shadow_trial_request".to_owned(),
        "capability_binding_policy".to_owned(),
    ]
}

fn capability_shadow_trial_resource_kinds() -> Vec<String> {
    vec![
        "capability_shadow_trial_request".to_owned(),
        "capability_shadow_trial_decision".to_owned(),
        "capability_shadow_trial_run".to_owned(),
        "capability_shadow_trial_evidence".to_owned(),
    ]
}

fn delegated_subagent_module_scopes(operation: &str) -> Vec<String> {
    let mut scopes = vec![
        "module_runtime.read".to_owned(),
        "program_execution.read".to_owned(),
        "jobs.read".to_owned(),
    ];
    if operation == "subagent_launch" {
        scopes.extend([
            "module_runtime.write".to_owned(),
            "program_execution.write".to_owned(),
            "jobs.write".to_owned(),
        ]);
    } else if operation == "subagent_cancel" {
        scopes.extend(["module_runtime.write".to_owned(), "jobs.write".to_owned()]);
    }
    scopes
}

fn delegated_subagent_module_resource_kinds(operation: &str) -> Vec<String> {
    let mut kinds = vec![
        "module_runtime_state".to_owned(),
        "program_execution_record".to_owned(),
        "job_process".to_owned(),
        "execution_output".to_owned(),
    ];
    if operation == "subagent_launch" {
        kinds.push("module_lifecycle_state".to_owned());
    }
    kinds
}

fn push_resource_selector_arg(selectors: &mut Vec<String>, args: &Value, field: &str) {
    if let Some(resource_id) = args
        .get(field)
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
    {
        selectors.push(format!("resource:{resource_id}"));
    }
}

#[allow(clippy::too_many_arguments)]
fn push_subagent_launch_selector(
    selectors: &mut Vec<String>,
    session_id: &str,
    workspace_id: Option<&str>,
    working_directory: &str,
    invocation_id: &str,
    model_primitive_name: &str,
    turn: i64,
    run_id: Option<&str>,
    args: &Value,
) {
    let task_id = args
        .get("taskId")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .unwrap_or(invocation_id);
    let idempotency_key = model_capability_invocation_idempotency_key(
        run_id,
        session_id,
        turn,
        invocation_id,
        model_primitive_name,
        working_directory,
        workspace_id,
        args,
    );
    selectors.push(format!(
        "resource:{}",
        subagent_task_resource_id(session_id, task_id, &idempotency_key)
    ));
}

async fn push_delegated_subagent_followup_selectors(
    engine_host: &EngineHostHandle,
    selectors: &mut Vec<String>,
    args: &Value,
) -> Result<(), FailureEnvelope> {
    let Some(resource_id) = args
        .get("subagentTaskResourceId")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
    else {
        return Ok(());
    };
    let Some(inspection) = engine_host
        .inspect_resource(resource_id)
        .await
        .map_err(|error| engine_error_to_failure(&error))?
    else {
        return Ok(());
    };
    if inspection.resource.kind != SUBAGENT_TASK_KIND {
        return Ok(());
    }
    let Some(payload) = inspection
        .versions
        .iter()
        .find(|version| {
            inspection
                .resource
                .current_version_id
                .as_ref()
                .is_some_and(|current| current == &version.version_id)
        })
        .or_else(|| inspection.versions.last())
        .map(|version| &version.payload)
    else {
        return Ok(());
    };
    for pointer in [
        "/delegation/moduleRuntimeResourceId",
        "/delegation/jobResourceId",
        "/delegation/programExecutionResourceId",
    ] {
        if let Some(resource_id) = payload
            .pointer(pointer)
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
        {
            selectors.push(format!("resource:{resource_id}"));
        }
    }
    Ok(())
}

fn push_module_lifecycle_request_selector(
    selectors: &mut Vec<String>,
    session_id: &str,
    args: &Value,
) {
    if let Some(install_decision_resource_id) = args
        .get("moduleInstallDecisionResourceId")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
    {
        selectors.push(format!(
            "resource:{}",
            module_lifecycle_state_resource_id(session_id, install_decision_resource_id)
        ));
    }
}

fn push_module_runtime_request_selector(
    selectors: &mut Vec<String>,
    session_id: &str,
    args: &Value,
) {
    if let Some(lifecycle_resource_id) = args
        .get("moduleLifecycleResourceId")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
    {
        selectors.push(format!(
            "resource:{}",
            module_runtime_state_resource_id(
                session_id,
                lifecycle_resource_id,
                args.get("runtimeRequestId")
                    .and_then(Value::as_str)
                    .filter(|value| !value.trim().is_empty())
                    .unwrap_or_else(|| {
                        args.get("idempotencyKey")
                            .and_then(Value::as_str)
                            .unwrap_or("runtime")
                    })
            )
        ));
    }
}

fn module_lifecycle_state_resource_id(
    session_id: &str,
    install_decision_resource_id: &str,
) -> String {
    format!(
        "module_lifecycle_state:{}",
        sha256_hex(format!("session:{session_id}:{install_decision_resource_id}").as_bytes())
    )
}

fn module_runtime_state_resource_id(
    session_id: &str,
    lifecycle_resource_id: &str,
    runtime_request_id: &str,
) -> String {
    format!(
        "module_runtime_state:{}",
        sha256_hex(
            format!("session:{session_id}:{lifecycle_resource_id}:{runtime_request_id}").as_bytes()
        )
    )
}

fn subagent_task_resource_id(session_id: &str, task_id: &str, idempotency_key: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"session");
    hasher.update(b":");
    hasher.update(session_id.as_bytes());
    hasher.update(b":");
    hasher.update(task_id.as_bytes());
    hasher.update(b":");
    hasher.update(idempotency_key.as_bytes());
    format!("subagent_task:{:x}", hasher.finalize())
}

fn exact_resource_selector_fields() -> &'static [(&'static [&'static str], &'static str)] {
    &[
        (
            &["goal_inspect", "goal_cancel", "question_create"],
            "goalResourceId",
        ),
        (
            &["question_inspect", "question_answer"],
            "questionResourceId",
        ),
        (&["media_inspect", "media_archive"], "mediaResourceId"),
        (&["import_history_inspect"], "importHistoryResourceId"),
        (&["repository_tree_inspect"], "repositoryTreeResourceId"),
        (&["import_preview_inspect"], "importPreviewResourceId"),
        (&["program_execution_inspect"], "programExecutionResourceId"),
        (&["prompt_artifact_inspect"], "promptArtifactResourceId"),
        (&["update_diagnostic_inspect"], "updateDiagnosticResourceId"),
        (&["memory_inspect"], "recordResourceId"),
        (&["memory_query_inspect"], "queryResourceId"),
        (&["memory_decision_inspect"], "decisionResourceId"),
        (
            &["context_control_action_inspect"],
            "contextControlActionResourceId",
        ),
        (&["context_survivor_disable"], "contextSurvivorResourceId"),
        (&["context_exclusion_disable"], "contextExclusionResourceId"),
        (&["module_inspect"], "moduleManifestResourceId"),
        (&["module_proposal_inspect"], "moduleProposalResourceId"),
        (
            &["module_validation_inspect"],
            "moduleValidationReportResourceId",
        ),
        (
            &["module_install_request_record"],
            "moduleValidationReportResourceId",
        ),
        (
            &[
                "module_install_request_inspect",
                "module_install_decision_record",
            ],
            "moduleInstallRequestResourceId",
        ),
        (
            &["module_install_decision_inspect"],
            "moduleInstallDecisionResourceId",
        ),
        (
            &[
                "module_dependency_request_inspect",
                "module_dependency_decision_record",
            ],
            "moduleDependencyRequestResourceId",
        ),
        (
            &[
                "module_dependency_decision_inspect",
                "module_dependency_policy_activate",
            ],
            "moduleDependencyDecisionResourceId",
        ),
        (
            &["module_dependency_policy_inspect"],
            "moduleDependencyPolicyResourceId",
        ),
        (
            &["capability_binding_request_inspect"],
            "capabilityBindingRequestResourceId",
        ),
        (
            &["capability_binding_decision_record"],
            "capabilityBindingRequestResourceId",
        ),
        (
            &["capability_binding_decision_inspect"],
            "capabilityBindingDecisionResourceId",
        ),
        (
            &["capability_binding_policy_activate"],
            "capabilityBindingDecisionResourceId",
        ),
        (
            &["capability_binding_policy_inspect"],
            "capabilityBindingPolicyResourceId",
        ),
        (
            &["capability_replacement_candidate_inspect"],
            "capabilityReplacementCandidateResourceId",
        ),
        (
            &["capability_route_binding_record"],
            "capabilityReplacementCandidateResourceId",
        ),
        (
            &[
                "capability_route_binding_inspect",
                "capability_route_activate",
            ],
            "capabilityRouteBindingResourceId",
        ),
        (
            &["capability_route_disable", "capability_route_rollback"],
            "capabilityRouteBindingResourceId",
        ),
        (
            &["capability_route_disable", "capability_route_rollback"],
            "capabilityRouteActivationResourceId",
        ),
        (
            &["capability_route_event_inspect"],
            "capabilityRouteEventResourceId",
        ),
        (
            &[
                "web_research_request_inspect",
                "web_research_review_record",
                "web_research_source_record",
            ],
            "webResearchRequestResourceId",
        ),
        (
            &["web_research_review_inspect", "web_research_source_record"],
            "webResearchReviewResourceId",
        ),
        (
            &["web_research_source_inspect"],
            "webResearchSourceResourceId",
        ),
        (
            &["module_lifecycle_decision", "module_lifecycle_inspect"],
            "moduleLifecycleResourceId",
        ),
        (
            &["module_lifecycle_request"],
            "moduleInstallDecisionResourceId",
        ),
        (&["module_runtime_request"], "moduleLifecycleResourceId"),
        (
            &["module_program_execution_start"],
            "moduleLifecycleResourceId",
        ),
        (
            &["module_runtime_inspect", "module_runtime_cancel"],
            "moduleRuntimeResourceId",
        ),
        (
            &[
                "module_program_execution_status",
                "module_program_execution_cancel",
                "module_program_execution_cleanup",
            ],
            "moduleRuntimeResourceId",
        ),
        (
            &[
                "module_program_execution_status",
                "module_program_execution_cancel",
                "module_program_execution_cleanup",
            ],
            "jobResourceId",
        ),
        (&["procedural_state_inspect"], "proceduralRecordResourceId"),
        (
            &["procedural_activation_request_record"],
            "proceduralRecordResourceId",
        ),
        (
            &[
                "procedural_activation_request_inspect",
                "procedural_activation_decision_record",
            ],
            "proceduralActivationRequestResourceId",
        ),
        (
            &["procedural_activation_decision_inspect"],
            "proceduralActivationDecisionResourceId",
        ),
    ]
}

fn is_procedural_module_operation(operation: &str) -> bool {
    matches!(
        operation,
        "procedural_definition_record"
            | "procedural_state_list"
            | "procedural_state_inspect"
            | "procedural_activation_request_record"
            | "procedural_activation_request_list"
            | "procedural_activation_request_inspect"
            | "procedural_activation_decision_record"
            | "procedural_activation_decision_list"
            | "procedural_activation_decision_inspect"
    )
}

fn procedural_resource_kinds(operation: &str) -> Vec<String> {
    match operation {
        "procedural_definition_record" | "procedural_state_list" | "procedural_state_inspect" => {
            vec!["procedural_record".to_owned()]
        }
        "procedural_activation_request_record"
        | "procedural_activation_request_list"
        | "procedural_activation_request_inspect" => {
            vec![
                "procedural_record".to_owned(),
                "procedural_activation_request".to_owned(),
            ]
        }
        "procedural_activation_decision_record"
        | "procedural_activation_decision_list"
        | "procedural_activation_decision_inspect" => {
            vec![
                "procedural_record".to_owned(),
                "procedural_activation_request".to_owned(),
                "procedural_activation_decision".to_owned(),
            ]
        }
        _ => Vec::new(),
    }
}

fn procedural_kind(args: &Value) -> Option<&'static str> {
    match args.get("proceduralKind").and_then(Value::as_str) {
        Some("skill") => Some("skill"),
        Some("rule") => Some("rule"),
        Some("hook") => Some("hook"),
        Some("procedure") => Some("procedure"),
        _ => None,
    }
}

fn worker_package_list_kind(args: &Value) -> Option<&'static str> {
    match args
        .get("workerPackageKind")
        .and_then(Value::as_str)
        .unwrap_or("worker_package")
    {
        "worker_package" => Some("worker_package"),
        "worker_package_installation" => Some("worker_package_installation"),
        "worker_package_proposal" => Some("worker_package_proposal"),
        "worker_package_conformance_report" => Some("worker_package_conformance_report"),
        "worker_launch_attempt" => Some("worker_launch_attempt"),
        _ => None,
    }
}

fn worker_package_inspect_kind(args: &Value) -> Option<&'static str> {
    let resource_id = args
        .get("workerPackageResourceId")
        .and_then(Value::as_str)?;
    if resource_id.starts_with("worker_package_installation:") {
        Some("worker_package_installation")
    } else if resource_id.starts_with("worker_package_proposal:") {
        Some("worker_package_proposal")
    } else if resource_id.starts_with("worker_package_conformance_report:") {
        Some("worker_package_conformance_report")
    } else if resource_id.starts_with("worker_launch_attempt:") {
        Some("worker_launch_attempt")
    } else if resource_id.starts_with("worker_package:") {
        Some("worker_package")
    } else {
        None
    }
}

#[allow(clippy::too_many_arguments)]
pub(super) fn stable_capability_invocation_material(
    run_id: Option<&str>,
    session_id: &str,
    turn: i64,
    invocation_id: &str,
    model_primitive_name: &str,
    working_directory: &str,
    workspace_id: Option<&str>,
    effective_args: &Value,
) -> String {
    let payload = json!({
        "runId": run_id,
        "sessionId": session_id,
        "turn": turn,
        "providerCallId": invocation_id,
        "modelPrimitiveName": model_primitive_name,
        "workingDirectory": working_directory,
        "workspaceId": workspace_id,
        "arguments": effective_args
    });
    serde_json::to_string(&payload).unwrap_or_else(|_| {
        format!(
            "{run_id:?}:{session_id}:{turn}:{invocation_id}:{model_primitive_name}:{working_directory}:{workspace_id:?}:{effective_args}",
        )
    })
}

#[allow(clippy::too_many_arguments)]
pub(super) fn model_capability_invocation_idempotency_key(
    run_id: Option<&str>,
    session_id: &str,
    turn: i64,
    invocation_id: &str,
    model_primitive_name: &str,
    working_directory: &str,
    workspace_id: Option<&str>,
    effective_args: &Value,
) -> String {
    if effective_args.get("operation").and_then(Value::as_str) == Some("catalog_conformance")
        && let Some(caller_key) = effective_args.get("idempotencyKey").and_then(Value::as_str)
    {
        let material = json!({
            "version": 1,
            "sessionId": session_id,
            "operation": "catalog_conformance",
            "callerKey": caller_key
        });
        return format!(
            "model-capability-caller-idempotency:v1:{}",
            sha256_hex(
                serde_json::to_string(&material)
                    .unwrap_or_else(|_| format!("{session_id}:catalog_conformance:{caller_key}"))
                    .as_bytes()
            )
        );
    }
    let material = stable_capability_invocation_material(
        run_id,
        session_id,
        turn,
        invocation_id,
        model_primitive_name,
        working_directory,
        workspace_id,
        effective_args,
    );
    format!(
        "model-capability-invocation:v1:{}",
        sha256_hex(material.as_bytes())
    )
}

pub(super) fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}
