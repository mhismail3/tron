use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, EngineHostHandle, FunctionId, Invocation,
    SUBAGENT_TASK_KIND, TraceId,
};
use crate::shared::server::error_mapping::engine_error_to_failure;
use crate::shared::server::failure::{
    CAPABILITY_RESULT_INVALID, ENGINE_POLICY_VIOLATION, FailureCategory, FailureEnvelope,
    FailureOrigin,
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

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
) -> Result<AuthorityGrantId, FailureEnvelope> {
    let operation = effective_args
        .get("operation")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let module_registry_read_operation = matches!(operation, "module_list" | "module_inspect");
    let module_authoring_operation = matches!(
        operation,
        "module_proposal_record" | "module_proposal_list" | "module_proposal_inspect"
    );
    let module_validation_operation = matches!(
        operation,
        "module_validation_record" | "module_validation_list" | "module_validation_inspect"
    );
    let module_install_operation = matches!(
        operation,
        "module_install_request_record"
            | "module_install_request_list"
            | "module_install_request_inspect"
            | "module_install_decision_record"
            | "module_install_decision_list"
            | "module_install_decision_inspect"
    );
    let module_dependencies_operation = matches!(
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
    );
    let module_lifecycle_operation = matches!(
        operation,
        "module_lifecycle_request"
            | "module_lifecycle_decision"
            | "module_lifecycle_list"
            | "module_lifecycle_inspect"
    );
    let module_runtime_operation = matches!(
        operation,
        "module_runtime_request"
            | "module_runtime_list"
            | "module_runtime_inspect"
            | "module_runtime_cancel"
    );
    let module_program_execution_operation = matches!(
        operation,
        "module_program_execution_start"
            | "module_program_execution_status"
            | "module_program_execution_cancel"
            | "module_program_execution_cleanup"
    );
    let memory_module_operation = is_memory_module_operation(operation);
    let delegated_subagent_operation = matches!(
        operation,
        "subagent_launch" | "subagent_status" | "subagent_result" | "subagent_cancel"
    );
    let file_git_module_operation = is_file_git_module_operation(operation);
    let notification_push_requested = operation == "notification_send"
        && effective_args
            .get("pushRequested")
            .and_then(Value::as_bool)
            .unwrap_or(false);
    let web_fetch_uses_robots_policy = operation == "web_fetch"
        && has_non_empty_string(effective_args, "webRobotsPolicyResourceId")
        && has_non_empty_string(effective_args, "expectedWebRobotsPolicyVersionId");
    let mut allowed_capabilities = if module_registry_read_operation
        || module_authoring_operation
        || module_validation_operation
        || module_install_operation
        || module_dependencies_operation
        || module_lifecycle_operation
        || module_runtime_operation
        || module_program_execution_operation
        || memory_module_operation
        || delegated_subagent_operation
        || file_git_module_operation
    {
        vec![target_function_id.as_str().to_owned()]
    } else {
        vec![
            target_function_id.as_str().to_owned(),
            "state::get".to_owned(),
            "state::set".to_owned(),
            "state::list".to_owned(),
        ]
    };
    allowed_capabilities.sort();
    allowed_capabilities.dedup();
    let mut allowed_authority_scopes = target_authority_scopes.to_vec();
    if !module_registry_read_operation
        && !module_authoring_operation
        && !module_validation_operation
        && !module_install_operation
        && !module_dependencies_operation
        && !module_lifecycle_operation
        && !module_runtime_operation
        && !module_program_execution_operation
        && !memory_module_operation
        && !delegated_subagent_operation
        && !file_git_module_operation
    {
        allowed_authority_scopes.extend(["state.read".to_owned(), "state.write".to_owned()]);
    }
    if operation == "web_fetch" {
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
        "procedural_state_list" | "procedural_state_inspect"
    ) {
        allowed_authority_scopes.extend(["procedural.read".to_owned(), "resource.read".to_owned()]);
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
    let network_policy = if matches!(operation, "web_fetch" | "web_robots_check") {
        "declared"
    } else {
        "none"
    };
    let mut allowed_resource_kinds = if module_registry_read_operation
        || module_authoring_operation
        || module_validation_operation
        || module_install_operation
        || module_dependencies_operation
        || module_lifecycle_operation
        || module_runtime_operation
        || module_program_execution_operation
        || memory_module_operation
        || delegated_subagent_operation
        || file_git_module_operation
    {
        Vec::new()
    } else {
        vec!["agent_state".to_owned()]
    };
    if operation == "web_robots_check" {
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
    } else if matches!(
        operation,
        "procedural_state_list" | "procedural_state_inspect"
    ) && procedural_kind(effective_args).is_some()
    {
        allowed_resource_kinds.push("procedural_record".to_owned());
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
        "procedural_state_list" | "procedural_state_inspect"
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
        "allowedAuthorityScopes": allowed_authority_scopes,
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
    AuthorityGrantId::new(grant_id.to_owned()).map_err(|error| engine_error_to_failure(&error))
}

fn has_non_empty_string(value: &Value, field: &str) -> bool {
    value
        .get(field)
        .and_then(Value::as_str)
        .is_some_and(|item| !item.trim().is_empty())
}

fn is_file_git_module_operation(operation: &str) -> bool {
    matches!(
        operation,
        "filesystem_read"
            | "filesystem_list"
            | "filesystem_find"
            | "filesystem_glob"
            | "filesystem_search_text"
            | "filesystem_diff"
            | "filesystem_write"
            | "filesystem_edit"
            | "filesystem_apply_patch"
            | "git_status"
            | "git_diff"
            | "git_branch_inventory"
            | "git_stage"
            | "git_unstage"
            | "git_commit"
            | "git_branch_start"
    )
}

fn is_memory_module_operation(operation: &str) -> bool {
    matches!(
        operation,
        "memory_status"
            | "memory_list"
            | "memory_inspect"
            | "memory_query_list"
            | "memory_query_inspect"
            | "memory_decision_list"
            | "memory_decision_inspect"
    )
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
    ]
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
