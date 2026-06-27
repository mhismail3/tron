use chrono::Utc;
use serde_json::Value;
use std::path::{Path, PathBuf};

use crate::engine::authority::grants::model::{EngineGrant, EngineGrantLifecycle};
use crate::engine::invocation::model::{Invocation, RUNTIME_METADATA_WORKING_DIRECTORY};
use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::ids::FunctionId;
use crate::engine::kernel::types::FunctionDefinition;

use super::paths::{canonical_payload_path, root_allows_path};

pub(super) fn authorize_with_grant(
    grant: &EngineGrant,
    function: &FunctionDefinition,
    invocation: &Invocation,
) -> Result<()> {
    if grant.lifecycle != EngineGrantLifecycle::Active {
        return Err(EngineError::PolicyViolation(format!(
            "authority grant {} is not active",
            grant.grant_id
        )));
    }
    if let Some(expires_at) = grant.expires_at
        && expires_at <= Utc::now()
    {
        return Err(EngineError::PolicyViolation(format!(
            "authority grant {} is expired",
            grant.grant_id
        )));
    }
    ensure_budget_available(grant)?;
    if grant
        .subject_actor_id
        .as_ref()
        .is_some_and(|actor| actor != &invocation.causal_context.actor_id)
    {
        return Err(EngineError::PolicyViolation(format!(
            "authority grant {} subject actor mismatch",
            grant.grant_id
        )));
    }
    if grant.subject_invocation_id.as_ref().is_some_and(|parent| {
        invocation.causal_context.parent_invocation_id.as_ref() != Some(parent)
    }) {
        return Err(EngineError::PolicyViolation(format!(
            "authority grant {} subject invocation mismatch",
            grant.grant_id
        )));
    }
    if grant
        .subject_worker_id
        .as_ref()
        .is_some_and(|worker| worker != &function.owner_worker)
    {
        return Err(EngineError::PolicyViolation(format!(
            "authority grant {} subject worker mismatch",
            grant.grant_id
        )));
    }
    if function.risk_level > grant.max_risk {
        return Err(EngineError::PolicyViolation(format!(
            "function {} risk {:?} exceeds grant {} max risk {:?}",
            function.id, function.risk_level, grant.grant_id, grant.max_risk
        )));
    }
    if !allows_function(grant, &function.id) {
        return Err(EngineError::PolicyViolation(format!(
            "authority grant {} does not allow function {}",
            grant.grant_id, function.id
        )));
    }
    if is_module_registry_invocation(invocation) {
        ensure_module_registry_grant_is_explicit(grant)?;
    }
    if is_module_authoring_invocation(invocation) {
        ensure_module_authoring_grant_is_explicit(grant)?;
    }
    if is_module_validation_invocation(invocation) {
        ensure_module_validation_grant_is_explicit(grant)?;
    }
    for scope in &function.required_authority.scopes {
        if !allows_item(&grant.allowed_authority_scopes, scope) {
            return Err(EngineError::PolicyViolation(format!(
                "authority grant {} does not allow required authority {scope}",
                grant.grant_id
            )));
        }
    }
    for scope in authority_scopes_from_invocation(invocation) {
        if !allows_item(&grant.allowed_authority_scopes, &scope) {
            return Err(EngineError::PolicyViolation(format!(
                "authority grant {} does not allow required authority {scope}",
                grant.grant_id
            )));
        }
    }
    let resource_kinds = resource_kinds_from_invocation(invocation);
    for kind in &resource_kinds {
        if !allows_item(&grant.allowed_resource_kinds, kind) {
            return Err(EngineError::PolicyViolation(format!(
                "authority grant {} does not allow resource kind {kind}",
                grant.grant_id
            )));
        }
    }
    ensure_resource_selectors(grant, invocation, &resource_kinds)?;
    ensure_file_roots(grant, invocation)?;
    Ok(())
}

fn ensure_budget_available(grant: &EngineGrant) -> Result<()> {
    for field in ["remainingTokens", "remainingProcessMs"] {
        if grant
            .budget
            .get(field)
            .and_then(Value::as_u64)
            .is_some_and(|remaining| remaining == 0)
        {
            return Err(EngineError::PolicyViolation(format!(
                "authority grant {} budget {field} is exhausted",
                grant.grant_id
            )));
        }
    }
    Ok(())
}

fn ensure_module_registry_grant_is_explicit(grant: &EngineGrant) -> Result<()> {
    for (label, items) in [
        (
            "authority scopes",
            grant.allowed_authority_scopes.as_slice(),
        ),
        ("resource kinds", grant.allowed_resource_kinds.as_slice()),
        ("resource selectors", grant.resource_selectors.as_slice()),
    ] {
        if items.iter().any(|item| item == "*") {
            return Err(EngineError::PolicyViolation(format!(
                "authority grant {} cannot use wildcard {label} for module registry reads",
                grant.grant_id
            )));
        }
    }
    Ok(())
}

fn ensure_module_authoring_grant_is_explicit(grant: &EngineGrant) -> Result<()> {
    for (label, items) in [
        (
            "authority scopes",
            grant.allowed_authority_scopes.as_slice(),
        ),
        ("resource kinds", grant.allowed_resource_kinds.as_slice()),
        ("resource selectors", grant.resource_selectors.as_slice()),
    ] {
        if items.iter().any(|item| item == "*") {
            return Err(EngineError::PolicyViolation(format!(
                "authority grant {} cannot use wildcard {label} for module proposal operations",
                grant.grant_id
            )));
        }
    }
    Ok(())
}

fn ensure_module_validation_grant_is_explicit(grant: &EngineGrant) -> Result<()> {
    for (label, items) in [
        (
            "authority scopes",
            grant.allowed_authority_scopes.as_slice(),
        ),
        ("resource kinds", grant.allowed_resource_kinds.as_slice()),
        ("resource selectors", grant.resource_selectors.as_slice()),
    ] {
        if items.iter().any(|item| item == "*") {
            return Err(EngineError::PolicyViolation(format!(
                "authority grant {} cannot use wildcard {label} for module validation operations",
                grant.grant_id
            )));
        }
    }
    Ok(())
}

fn ensure_resource_selectors(
    grant: &EngineGrant,
    invocation: &Invocation,
    resource_kinds: &[String],
) -> Result<()> {
    if allows_item(&grant.resource_selectors, "*") {
        return Ok(());
    }
    let resource_ids = resource_ids_from_invocation(invocation);
    for resource_id in &resource_ids {
        if !allows_resource_id(grant, &resource_id) {
            return Err(EngineError::PolicyViolation(format!(
                "authority grant {} does not allow resource {resource_id}",
                grant.grant_id
            )));
        }
    }
    let selector_kinds = if resource_ids.is_empty() {
        resource_kinds.to_vec()
    } else {
        created_resource_kinds_from_invocation(invocation)
    };
    for kind in selector_kinds {
        if !allows_item(&grant.resource_selectors, &format!("kind:{kind}")) {
            return Err(EngineError::PolicyViolation(format!(
                "authority grant {} does not allow new resource kind {kind}",
                grant.grant_id
            )));
        }
    }
    Ok(())
}

fn allows_resource_id(grant: &EngineGrant, resource_id: &str) -> bool {
    allows_item(&grant.resource_selectors, resource_id)
        || allows_item(
            &grant.resource_selectors,
            &format!("resource:{resource_id}"),
        )
}

fn resource_ids_from_invocation(invocation: &Invocation) -> Vec<String> {
    [
        "resourceId",
        "sourceResourceId",
        "targetResourceId",
        "goalResourceId",
        "questionResourceId",
        "answerResourceId",
        "mediaResourceId",
        "importHistoryResourceId",
        "repositoryTreeResourceId",
        "importPreviewResourceId",
        "programExecutionResourceId",
        "promptArtifactResourceId",
        "updateDiagnosticResourceId",
        "queryResourceId",
        "decisionResourceId",
        "moduleManifestResourceId",
        "moduleProposalResourceId",
        "moduleValidationReportResourceId",
    ]
    .into_iter()
    .filter_map(|field| invocation.payload.get(field).and_then(Value::as_str))
    .map(str::to_owned)
    .collect()
}

fn authority_scopes_from_invocation(invocation: &Invocation) -> Vec<String> {
    if invocation.function_id.as_str() != "capability::execute" {
        return Vec::new();
    }
    let mut scopes = Vec::new();
    match invocation.payload.get("operation").and_then(Value::as_str) {
        Some("goal_create" | "goal_cancel" | "question_create" | "question_answer") => {
            push_unique(&mut scopes, "goals.write");
        }
        Some("goal_list" | "goal_inspect" | "question_list" | "question_inspect") => {
            push_unique(&mut scopes, "goals.read");
        }
        Some("web_fetch") => {
            push_unique(&mut scopes, "resource.write");
            push_unique(&mut scopes, "web.write");
            if web_fetch_uses_robots_policy(invocation) {
                push_unique(&mut scopes, "resource.read");
                push_unique(&mut scopes, "web.read");
            }
        }
        Some("web_robots_check") => {
            push_unique(&mut scopes, "resource.read");
            push_unique(&mut scopes, "resource.write");
            push_unique(&mut scopes, "web.write");
        }
        Some("web_source_list" | "web_source_inspect") => {
            push_unique(&mut scopes, "resource.read");
            push_unique(&mut scopes, "web.read");
        }
        Some("web_source_archive") => {
            push_unique(&mut scopes, "resource.read");
            push_unique(&mut scopes, "resource.write");
            push_unique(&mut scopes, "web.read");
            push_unique(&mut scopes, "web.write");
        }
        Some("media_list" | "media_inspect") => {
            push_unique(&mut scopes, "media.read");
            push_unique(&mut scopes, "resource.read");
        }
        Some("media_create" | "media_archive") => {
            push_unique(&mut scopes, "media.read");
            push_unique(&mut scopes, "media.write");
            push_unique(&mut scopes, "resource.read");
            push_unique(&mut scopes, "resource.write");
        }
        Some("import_history_list" | "import_history_inspect") => {
            push_unique(&mut scopes, "import_history.read");
            push_unique(&mut scopes, "resource.read");
        }
        Some("import_history_record") => {
            push_unique(&mut scopes, "import_history.read");
            push_unique(&mut scopes, "import_history.write");
            push_unique(&mut scopes, "resource.read");
            push_unique(&mut scopes, "resource.write");
        }
        Some("repository_tree_list" | "repository_tree_inspect") => {
            push_unique(&mut scopes, "repository_tree.read");
            push_unique(&mut scopes, "resource.read");
        }
        Some("repository_tree_snapshot") => {
            push_unique(&mut scopes, "repository_tree.read");
            push_unique(&mut scopes, "repository_tree.write");
            push_unique(&mut scopes, "resource.read");
            push_unique(&mut scopes, "resource.write");
        }
        Some("import_preview_list" | "import_preview_inspect") => {
            push_unique(&mut scopes, "import_preview.read");
            push_unique(&mut scopes, "resource.read");
        }
        Some("import_preview_record") => {
            push_unique(&mut scopes, "import_preview.read");
            push_unique(&mut scopes, "import_preview.write");
            push_unique(&mut scopes, "resource.read");
            push_unique(&mut scopes, "resource.write");
        }
        Some("program_execution_list" | "program_execution_inspect") => {
            push_unique(&mut scopes, "program_execution.read");
            push_unique(&mut scopes, "resource.read");
        }
        Some("program_execution_record") => {
            push_unique(&mut scopes, "program_execution.read");
            push_unique(&mut scopes, "program_execution.write");
            push_unique(&mut scopes, "resource.read");
            push_unique(&mut scopes, "resource.write");
        }
        Some("prompt_artifact_list" | "prompt_artifact_inspect") => {
            push_unique(&mut scopes, "prompt_artifacts.read");
            push_unique(&mut scopes, "resource.read");
        }
        Some("prompt_artifact_record") => {
            push_unique(&mut scopes, "prompt_artifacts.read");
            push_unique(&mut scopes, "prompt_artifacts.write");
            push_unique(&mut scopes, "resource.read");
            push_unique(&mut scopes, "resource.write");
        }
        Some("update_diagnostic_list" | "update_diagnostic_inspect") => {
            push_unique(&mut scopes, "update_diagnostics.read");
            push_unique(&mut scopes, "resource.read");
        }
        Some("update_diagnostic_record") => {
            push_unique(&mut scopes, "update_diagnostics.read");
            push_unique(&mut scopes, "update_diagnostics.write");
            push_unique(&mut scopes, "resource.read");
            push_unique(&mut scopes, "resource.write");
        }
        Some(
            "memory_query_list"
            | "memory_query_inspect"
            | "memory_decision_list"
            | "memory_decision_inspect",
        ) => {
            push_unique(&mut scopes, "memory.read");
            push_unique(&mut scopes, "resource.read");
        }
        Some("worker_package_list" | "worker_package_inspect") => {
            push_unique(&mut scopes, "worker.lifecycle.read");
            push_unique(&mut scopes, "resource.read");
        }
        Some("module_list" | "module_inspect") => {
            push_unique(&mut scopes, "module_registry.read");
            push_unique(&mut scopes, "resource.read");
        }
        Some("module_proposal_list" | "module_proposal_inspect") => {
            push_unique(&mut scopes, "module_authoring.read");
            push_unique(&mut scopes, "resource.read");
        }
        Some("module_proposal_record") => {
            push_unique(&mut scopes, "module_authoring.read");
            push_unique(&mut scopes, "module_authoring.write");
            push_unique(&mut scopes, "resource.read");
            push_unique(&mut scopes, "resource.write");
        }
        Some("module_validation_list" | "module_validation_inspect") => {
            push_unique(&mut scopes, "module_validation.read");
            push_unique(&mut scopes, "resource.read");
        }
        Some("module_validation_record") => {
            push_unique(&mut scopes, "module_validation.read");
            push_unique(&mut scopes, "module_validation.write");
            push_unique(&mut scopes, "resource.read");
            push_unique(&mut scopes, "resource.write");
        }
        Some("procedural_state_list" | "procedural_state_inspect") => {
            push_unique(&mut scopes, "procedural.read");
            push_unique(&mut scopes, "resource.read");
        }
        Some(
            "subagent_status" | "subagent_result" | "subagent_task_list" | "subagent_task_inspect",
        ) => {
            push_unique(&mut scopes, "subagents.read");
            push_unique(&mut scopes, "resource.read");
        }
        Some("subagent_launch" | "subagent_cancel") => {
            push_unique(&mut scopes, "subagents.read");
            push_unique(&mut scopes, "subagents.write");
            push_unique(&mut scopes, "resource.read");
            push_unique(&mut scopes, "resource.write");
        }
        _ => {}
    }
    scopes
}

fn resource_kinds_from_invocation(invocation: &Invocation) -> Vec<String> {
    let mut kinds = Vec::new();
    match invocation.function_id.as_str() {
        "capability::execute" => {
            for kind in capability_execute_resource_kinds(invocation) {
                push_unique(&mut kinds, kind);
            }
        }
        "resource::create" | "artifact::create" | "goal::create" | "claim::attach"
        | "evidence::attach" | "decision::create" => {
            if let Some(kind) = invocation
                .payload
                .get("kind")
                .and_then(Value::as_str)
                .or_else(|| wrapper_resource_kind(invocation.function_id.as_str()))
            {
                push_unique(&mut kinds, kind);
            }
        }
        _ => {
            if let Some(kind) = wrapper_resource_kind(invocation.function_id.as_str()) {
                push_unique(&mut kinds, kind);
            }
        }
    }
    kinds
}

fn capability_execute_resource_kinds(invocation: &Invocation) -> Vec<&'static str> {
    match invocation.payload.get("operation").and_then(Value::as_str) {
        Some("goal_create" | "goal_list" | "goal_inspect" | "goal_cancel") => vec!["goal"],
        Some("question_create") => {
            if invocation.payload.get("goalResourceId").is_some() {
                vec!["goal", "user_question"]
            } else {
                vec!["user_question"]
            }
        }
        Some("question_list" | "question_inspect") => vec!["user_question"],
        Some("question_answer") => vec!["user_question", "goal_answer"],
        Some("web_fetch") => {
            if web_fetch_uses_robots_policy(invocation) {
                vec!["web_source", "web_robots_policy"]
            } else {
                vec!["web_source"]
            }
        }
        Some("web_source_list" | "web_source_inspect" | "web_source_archive") => {
            vec!["web_source"]
        }
        Some("media_create" | "media_list" | "media_inspect" | "media_archive") => {
            vec!["media_artifact"]
        }
        Some("import_history_record" | "import_history_list" | "import_history_inspect") => {
            vec!["import_history_record"]
        }
        Some("repository_tree_snapshot" | "repository_tree_list" | "repository_tree_inspect") => {
            vec!["repository_tree_snapshot"]
        }
        Some("import_preview_record" | "import_preview_list" | "import_preview_inspect") => {
            vec!["import_preview"]
        }
        Some(
            "program_execution_record" | "program_execution_list" | "program_execution_inspect",
        ) => {
            vec!["program_execution_record"]
        }
        Some("prompt_artifact_record" | "prompt_artifact_list" | "prompt_artifact_inspect") => {
            vec!["prompt_artifact"]
        }
        Some(
            "update_diagnostic_record" | "update_diagnostic_list" | "update_diagnostic_inspect",
        ) => {
            vec!["update_diagnostic_record"]
        }
        Some("memory_query_list" | "memory_query_inspect") => vec!["memory_query"],
        Some("memory_decision_list" | "memory_decision_inspect") => vec!["memory_decision"],
        Some("web_robots_check") => vec!["web_robots_policy"],
        Some("worker_package_list") => {
            vec![worker_package_list_kind(invocation).unwrap_or("worker_package")]
        }
        Some("worker_package_inspect") => worker_package_inspect_kind(invocation)
            .map(|kind| vec![kind])
            .unwrap_or_default(),
        Some("module_list" | "module_inspect") => vec!["module_manifest"],
        Some("module_proposal_record" | "module_proposal_list" | "module_proposal_inspect") => {
            vec!["module_proposal"]
        }
        Some(
            "module_validation_record" | "module_validation_list" | "module_validation_inspect",
        ) => {
            vec!["module_validation_report"]
        }
        Some(
            "subagent_launch"
            | "subagent_status"
            | "subagent_result"
            | "subagent_cancel"
            | "subagent_task_list"
            | "subagent_task_inspect",
        ) => vec!["subagent_task"],
        Some("procedural_state_list" | "procedural_state_inspect") => vec!["procedural_record"],
        _ => Vec::new(),
    }
}

fn is_module_registry_invocation(invocation: &Invocation) -> bool {
    invocation.function_id.as_str() == "capability::execute"
        && matches!(
            invocation.payload.get("operation").and_then(Value::as_str),
            Some("module_list" | "module_inspect")
        )
}

fn is_module_authoring_invocation(invocation: &Invocation) -> bool {
    invocation.function_id.as_str() == "capability::execute"
        && matches!(
            invocation.payload.get("operation").and_then(Value::as_str),
            Some("module_proposal_record" | "module_proposal_list" | "module_proposal_inspect")
        )
}

fn is_module_validation_invocation(invocation: &Invocation) -> bool {
    invocation.function_id.as_str() == "capability::execute"
        && matches!(
            invocation.payload.get("operation").and_then(Value::as_str),
            Some(
                "module_validation_record" | "module_validation_list" | "module_validation_inspect"
            )
        )
}

fn worker_package_list_kind(invocation: &Invocation) -> Option<&'static str> {
    match invocation
        .payload
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

fn worker_package_inspect_kind(invocation: &Invocation) -> Option<&'static str> {
    let resource_id = invocation
        .payload
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

fn web_fetch_uses_robots_policy(invocation: &Invocation) -> bool {
    invocation
        .payload
        .get("webRobotsPolicyResourceId")
        .and_then(Value::as_str)
        .is_some_and(|value| !value.trim().is_empty())
        && invocation
            .payload
            .get("expectedWebRobotsPolicyVersionId")
            .and_then(Value::as_str)
            .is_some_and(|value| !value.trim().is_empty())
}

fn created_resource_kinds_from_invocation(invocation: &Invocation) -> Vec<String> {
    if invocation.function_id.as_str() != "capability::execute" {
        return Vec::new();
    }
    let mut kinds = Vec::new();
    match invocation.payload.get("operation").and_then(Value::as_str) {
        Some("goal_create") => push_unique(&mut kinds, "goal"),
        Some("question_create") => push_unique(&mut kinds, "user_question"),
        Some("question_answer") => push_unique(&mut kinds, "goal_answer"),
        Some("web_fetch") => push_unique(&mut kinds, "web_source"),
        Some("web_robots_check") => push_unique(&mut kinds, "web_robots_policy"),
        Some("media_create") => push_unique(&mut kinds, "media_artifact"),
        Some("import_history_record") => push_unique(&mut kinds, "import_history_record"),
        Some("repository_tree_snapshot") => push_unique(&mut kinds, "repository_tree_snapshot"),
        Some("import_preview_record") => push_unique(&mut kinds, "import_preview"),
        Some("program_execution_record") => push_unique(&mut kinds, "program_execution_record"),
        Some("prompt_artifact_record") => push_unique(&mut kinds, "prompt_artifact"),
        Some("update_diagnostic_record") => push_unique(&mut kinds, "update_diagnostic_record"),
        Some("module_validation_record") => push_unique(&mut kinds, "module_validation_report"),
        Some("subagent_launch") => push_unique(&mut kinds, "subagent_task"),
        _ => {}
    }
    kinds
}

fn ensure_file_roots(grant: &EngineGrant, invocation: &Invocation) -> Result<()> {
    if allows_item(&grant.file_roots, "*") {
        return Ok(());
    }
    for path in paths_from_invocation(invocation)? {
        let canonical = canonical_payload_path(&path)?;
        if !grant
            .file_roots
            .iter()
            .filter(|root| root.as_str() != "*")
            .any(|root| root_allows_path(root, &canonical).unwrap_or(false))
        {
            return Err(EngineError::PolicyViolation(format!(
                "authority grant {} does not allow file path {}",
                grant.grant_id,
                canonical.display()
            )));
        }
    }
    Ok(())
}

fn paths_from_invocation(invocation: &Invocation) -> Result<Vec<PathBuf>> {
    let mut paths = [
        "path",
        "filePath",
        "targetPath",
        "directory",
        "cwd",
        "workingDirectory",
    ]
    .into_iter()
    .filter_map(|field| invocation.payload.get(field).and_then(Value::as_str))
    .map(|raw| resolve_invocation_path(invocation, raw))
    .collect::<Result<Vec<_>>>()?;

    if capability_execute_requires_working_directory(invocation) {
        paths.push(capability_working_directory(invocation)?);
    }
    Ok(paths)
}

fn resolve_invocation_path(invocation: &Invocation, raw: &str) -> Result<PathBuf> {
    let path = Path::new(raw);
    if path.is_absolute() || invocation.function_id.as_str() != "capability::execute" {
        return Ok(path.to_path_buf());
    }
    Ok(capability_working_directory(invocation)?.join(path))
}

fn capability_execute_requires_working_directory(invocation: &Invocation) -> bool {
    invocation.function_id.as_str() == "capability::execute"
        && invocation
            .payload
            .get("operation")
            .and_then(Value::as_str)
            .is_some_and(|operation| {
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
                        | "process_run"
                        | "job_start"
                )
            })
}

fn capability_working_directory(invocation: &Invocation) -> Result<PathBuf> {
    let raw = invocation
        .causal_context
        .runtime_metadata(RUNTIME_METADATA_WORKING_DIRECTORY)
        .ok_or_else(|| {
            EngineError::PolicyViolation(
                "capability::execute requires trusted working directory metadata".to_owned(),
            )
        })?;
    crate::shared::foundation::paths::normalize_working_directory(raw)
        .map_err(EngineError::PolicyViolation)
}

fn wrapper_resource_kind(function_id: &str) -> Option<&'static str> {
    match function_id {
        id if id.starts_with("artifact::") => Some("artifact"),
        id if id.starts_with("goal::") => Some("goal"),
        id if id.starts_with("claim::") => Some("claim"),
        id if id.starts_with("evidence::") => Some("evidence"),
        id if id.starts_with("decision::") => Some("decision"),
        id if id.starts_with("materialized_file::") => Some("materialized_file"),
        id if id.starts_with("patch::") => Some("patch_proposal"),
        id if id.starts_with("ui::") => Some("ui_surface"),
        id if id.starts_with("jobs::") => Some("job_process"),
        _ => None,
    }
}

fn push_unique(kinds: &mut Vec<String>, kind: &str) {
    if !kinds.iter().any(|existing| existing == kind) {
        kinds.push(kind.to_owned());
    }
}

#[cfg(test)]
mod tests {
    use chrono::DateTime;
    use serde_json::json;

    use super::*;
    use crate::engine::kernel::ids::{ActorId, AuthorityGrantId, InvocationId, TraceId, WorkerId};
    use crate::engine::kernel::types::{EffectClass, RiskLevel, VisibilityScope};
    use crate::engine::{ActorKind, CausalContext, DeliveryMode};

    #[test]
    fn update_diagnostic_resource_id_is_selector_enforced() {
        let grant = test_grant(
            &[
                "capability.execute",
                "update_diagnostics.read",
                "resource.read",
            ],
            &["update_diagnostic_record"],
            &[
                "kind:update_diagnostic_record",
                "resource:update_diagnostic_record:first",
            ],
        );
        let function = test_execute_function();

        let allowed = test_invocation(json!({
            "operation": "update_diagnostic_inspect",
            "updateDiagnosticResourceId": "update_diagnostic_record:first"
        }));
        authorize_with_grant(&grant, &function, &allowed).expect("first resource allowed");

        let denied = test_invocation(json!({
            "operation": "update_diagnostic_inspect",
            "updateDiagnosticResourceId": "update_diagnostic_record:second"
        }));
        let error = authorize_with_grant(&grant, &function, &denied)
            .expect_err("second same-kind resource must be selector denied")
            .to_string();
        assert!(
            error.contains("does not allow resource update_diagnostic_record:second"),
            "{error}"
        );
    }

    #[test]
    fn repository_tree_resource_id_is_selector_enforced() {
        let grant = test_grant(
            &[
                "capability.execute",
                "repository_tree.read",
                "resource.read",
            ],
            &["repository_tree_snapshot"],
            &[
                "kind:repository_tree_snapshot",
                "resource:repository_tree_snapshot:first",
            ],
        );
        let function = test_execute_function();

        let allowed = test_invocation(json!({
            "operation": "repository_tree_inspect",
            "repositoryTreeResourceId": "repository_tree_snapshot:first"
        }));
        authorize_with_grant(&grant, &function, &allowed).expect("first resource allowed");

        let denied = test_invocation(json!({
            "operation": "repository_tree_inspect",
            "repositoryTreeResourceId": "repository_tree_snapshot:second"
        }));
        let error = authorize_with_grant(&grant, &function, &denied)
            .expect_err("second same-kind resource must be selector denied")
            .to_string();
        assert!(
            error.contains("does not allow resource repository_tree_snapshot:second"),
            "{error}"
        );
    }

    #[test]
    fn import_preview_resource_id_is_selector_enforced() {
        let grant = test_grant(
            &["capability.execute", "import_preview.read", "resource.read"],
            &["import_preview"],
            &["kind:import_preview", "resource:import_preview:first"],
        );
        let function = test_execute_function();

        let allowed = test_invocation(json!({
            "operation": "import_preview_inspect",
            "importPreviewResourceId": "import_preview:first"
        }));
        authorize_with_grant(&grant, &function, &allowed).expect("first resource allowed");

        let denied = test_invocation(json!({
            "operation": "import_preview_inspect",
            "importPreviewResourceId": "import_preview:second"
        }));
        let error = authorize_with_grant(&grant, &function, &denied)
            .expect_err("second same-kind resource must be selector denied")
            .to_string();
        assert!(
            error.contains("does not allow resource import_preview:second"),
            "{error}"
        );
    }

    #[test]
    fn program_execution_resource_id_is_selector_enforced() {
        let grant = test_grant(
            &[
                "capability.execute",
                "program_execution.read",
                "resource.read",
            ],
            &["program_execution_record"],
            &[
                "kind:program_execution_record",
                "resource:program_execution_record:first",
            ],
        );
        let function = test_execute_function();

        let allowed = test_invocation(json!({
            "operation": "program_execution_inspect",
            "programExecutionResourceId": "program_execution_record:first"
        }));
        authorize_with_grant(&grant, &function, &allowed).expect("first resource allowed");

        let denied = test_invocation(json!({
            "operation": "program_execution_inspect",
            "programExecutionResourceId": "program_execution_record:second"
        }));
        let error = authorize_with_grant(&grant, &function, &denied)
            .expect_err("second same-kind resource must be selector denied")
            .to_string();
        assert!(
            error.contains("does not allow resource program_execution_record:second"),
            "{error}"
        );
    }

    #[test]
    fn prompt_artifact_resource_id_is_selector_enforced() {
        let grant = test_grant(
            &[
                "capability.execute",
                "prompt_artifacts.read",
                "resource.read",
            ],
            &["prompt_artifact"],
            &["kind:prompt_artifact", "resource:prompt_artifact:first"],
        );
        let function = test_execute_function();

        let allowed = test_invocation(json!({
            "operation": "prompt_artifact_inspect",
            "promptArtifactResourceId": "prompt_artifact:first"
        }));
        authorize_with_grant(&grant, &function, &allowed).expect("first resource allowed");

        let denied = test_invocation(json!({
            "operation": "prompt_artifact_inspect",
            "promptArtifactResourceId": "prompt_artifact:second"
        }));
        let error = authorize_with_grant(&grant, &function, &denied)
            .expect_err("second same-kind resource must be selector denied")
            .to_string();
        assert!(
            error.contains("does not allow resource prompt_artifact:second"),
            "{error}"
        );
    }

    #[test]
    fn module_manifest_resource_id_is_selector_enforced() {
        let grant = test_grant(
            &[
                "capability.execute",
                "module_registry.read",
                "resource.read",
            ],
            &["module_manifest"],
            &["kind:module_manifest", "resource:module_manifest:first"],
        );
        let function = test_execute_function();

        let allowed = test_invocation(json!({
            "operation": "module_inspect",
            "moduleManifestResourceId": "module_manifest:first"
        }));
        authorize_with_grant(&grant, &function, &allowed).expect("first resource allowed");

        let denied = test_invocation(json!({
            "operation": "module_inspect",
            "moduleManifestResourceId": "module_manifest:second"
        }));
        let error = authorize_with_grant(&grant, &function, &denied)
            .expect_err("second same-kind resource must be selector denied")
            .to_string();
        assert!(
            error.contains("does not allow resource module_manifest:second"),
            "{error}"
        );
    }

    #[test]
    fn module_manifest_requires_explicit_authority_and_resource_kind() {
        let function = test_execute_function();
        let missing_scope = test_grant(
            &["capability.execute", "resource.read"],
            &["module_manifest"],
            &["kind:module_manifest"],
        );
        let error = authorize_with_grant(
            &missing_scope,
            &function,
            &test_invocation(json!({"operation": "module_list"})),
        )
        .expect_err("missing module registry read authority denied")
        .to_string();
        assert!(
            error.contains("does not allow required authority module_registry.read"),
            "{error}"
        );

        let wrong_kind = test_grant(
            &[
                "capability.execute",
                "module_registry.read",
                "resource.read",
            ],
            &["web_source"],
            &["kind:module_manifest"],
        );
        let error = authorize_with_grant(
            &wrong_kind,
            &function,
            &test_invocation(json!({"operation": "module_list"})),
        )
        .expect_err("missing module manifest resource kind denied")
        .to_string();
        assert!(
            error.contains("does not allow resource kind module_manifest"),
            "{error}"
        );
    }

    #[test]
    fn module_manifest_rejects_wildcard_authority_kinds_and_selectors() {
        let function = test_execute_function();
        for (name, grant, expected) in [
            (
                "authority",
                test_grant(
                    &["*", "module_registry.read", "resource.read"],
                    &["module_manifest"],
                    &["kind:module_manifest"],
                ),
                "wildcard authority scopes",
            ),
            (
                "resource kind",
                test_grant(
                    &[
                        "capability.execute",
                        "module_registry.read",
                        "resource.read",
                    ],
                    &["*", "module_manifest"],
                    &["kind:module_manifest"],
                ),
                "wildcard resource kinds",
            ),
            (
                "selector",
                test_grant(
                    &[
                        "capability.execute",
                        "module_registry.read",
                        "resource.read",
                    ],
                    &["module_manifest"],
                    &["*", "kind:module_manifest"],
                ),
                "wildcard resource selectors",
            ),
        ] {
            let error = match authorize_with_grant(
                &grant,
                &function,
                &test_invocation(json!({"operation": "module_list"})),
            ) {
                Ok(()) => panic!("module registry {name} wildcard grant must be denied"),
                Err(error) => error.to_string(),
            };
            assert!(error.contains(expected), "{error}");
        }
    }

    #[test]
    fn module_proposal_resource_id_is_selector_enforced() {
        let grant = test_grant(
            &[
                "capability.execute",
                "module_authoring.read",
                "resource.read",
            ],
            &["module_proposal"],
            &["kind:module_proposal", "resource:module_proposal:first"],
        );
        let function = test_execute_function();

        let allowed = test_invocation(json!({
            "operation": "module_proposal_inspect",
            "moduleProposalResourceId": "module_proposal:first"
        }));
        authorize_with_grant(&grant, &function, &allowed).expect("first proposal allowed");

        let denied = test_invocation(json!({
            "operation": "module_proposal_inspect",
            "moduleProposalResourceId": "module_proposal:second"
        }));
        let error = authorize_with_grant(&grant, &function, &denied)
            .expect_err("second same-kind proposal must be selector denied")
            .to_string();
        assert!(
            error.contains("does not allow resource module_proposal:second"),
            "{error}"
        );
    }

    #[test]
    fn module_proposal_requires_explicit_authority_and_resource_kind() {
        let function = test_execute_function();
        let missing_scope = test_grant(
            &["capability.execute", "resource.read"],
            &["module_proposal"],
            &["kind:module_proposal"],
        );
        let error = authorize_with_grant(
            &missing_scope,
            &function,
            &test_invocation(json!({"operation": "module_proposal_list"})),
        )
        .expect_err("missing module authoring read authority denied")
        .to_string();
        assert!(
            error.contains("does not allow required authority module_authoring.read"),
            "{error}"
        );

        let wrong_kind = test_grant(
            &[
                "capability.execute",
                "module_authoring.read",
                "resource.read",
            ],
            &["module_manifest"],
            &["kind:module_proposal"],
        );
        let error = authorize_with_grant(
            &wrong_kind,
            &function,
            &test_invocation(json!({"operation": "module_proposal_list"})),
        )
        .expect_err("missing module proposal resource kind denied")
        .to_string();
        assert!(
            error.contains("does not allow resource kind module_proposal"),
            "{error}"
        );
    }

    #[test]
    fn module_proposal_rejects_wildcard_authority_kinds_and_selectors() {
        let function = test_execute_function();
        for (name, grant, expected) in [
            (
                "authority",
                test_grant(
                    &["*", "module_authoring.read", "resource.read"],
                    &["module_proposal"],
                    &["kind:module_proposal"],
                ),
                "wildcard authority scopes",
            ),
            (
                "resource kind",
                test_grant(
                    &[
                        "capability.execute",
                        "module_authoring.read",
                        "resource.read",
                    ],
                    &["*", "module_proposal"],
                    &["kind:module_proposal"],
                ),
                "wildcard resource kinds",
            ),
            (
                "selector",
                test_grant(
                    &[
                        "capability.execute",
                        "module_authoring.read",
                        "resource.read",
                    ],
                    &["module_proposal"],
                    &["*", "kind:module_proposal"],
                ),
                "wildcard resource selectors",
            ),
        ] {
            let error = match authorize_with_grant(
                &grant,
                &function,
                &test_invocation(json!({"operation": "module_proposal_list"})),
            ) {
                Ok(()) => panic!("module proposal {name} wildcard grant must be denied"),
                Err(error) => error.to_string(),
            };
            assert!(error.contains(expected), "{error}");
        }
    }

    #[test]
    fn module_validation_report_resource_id_is_selector_enforced() {
        let grant = test_grant(
            &[
                "capability.execute",
                "module_validation.read",
                "resource.read",
            ],
            &["module_validation_report"],
            &[
                "kind:module_validation_report",
                "resource:module_validation_report:first",
            ],
        );
        let function = test_execute_function();

        let allowed = test_invocation(json!({
            "operation": "module_validation_inspect",
            "moduleValidationReportResourceId": "module_validation_report:first"
        }));
        authorize_with_grant(&grant, &function, &allowed).expect("first report allowed");

        let denied = test_invocation(json!({
            "operation": "module_validation_inspect",
            "moduleValidationReportResourceId": "module_validation_report:second"
        }));
        let error = authorize_with_grant(&grant, &function, &denied)
            .expect_err("second same-kind validation report must be selector denied")
            .to_string();
        assert!(
            error.contains("does not allow resource module_validation_report:second"),
            "{error}"
        );
    }

    #[test]
    fn module_validation_report_requires_explicit_authority_and_resource_kind() {
        let function = test_execute_function();
        let missing_scope = test_grant(
            &["capability.execute", "resource.read"],
            &["module_validation_report"],
            &["kind:module_validation_report"],
        );
        let error = authorize_with_grant(
            &missing_scope,
            &function,
            &test_invocation(json!({"operation": "module_validation_list"})),
        )
        .expect_err("missing module validation read authority denied")
        .to_string();
        assert!(
            error.contains("does not allow required authority module_validation.read"),
            "{error}"
        );

        let wrong_kind = test_grant(
            &[
                "capability.execute",
                "module_validation.read",
                "resource.read",
            ],
            &["module_proposal"],
            &["kind:module_validation_report"],
        );
        let error = authorize_with_grant(
            &wrong_kind,
            &function,
            &test_invocation(json!({"operation": "module_validation_list"})),
        )
        .expect_err("missing module validation report resource kind denied")
        .to_string();
        assert!(
            error.contains("does not allow resource kind module_validation_report"),
            "{error}"
        );
    }

    #[test]
    fn module_validation_report_rejects_wildcard_authority_kinds_and_selectors() {
        let function = test_execute_function();
        for (name, grant, expected) in [
            (
                "authority",
                test_grant(
                    &["*", "module_validation.read", "resource.read"],
                    &["module_validation_report"],
                    &["kind:module_validation_report"],
                ),
                "wildcard authority scopes",
            ),
            (
                "resource kind",
                test_grant(
                    &[
                        "capability.execute",
                        "module_validation.read",
                        "resource.read",
                    ],
                    &["*", "module_validation_report"],
                    &["kind:module_validation_report"],
                ),
                "wildcard resource kinds",
            ),
            (
                "selector",
                test_grant(
                    &[
                        "capability.execute",
                        "module_validation.read",
                        "resource.read",
                    ],
                    &["module_validation_report"],
                    &["*", "kind:module_validation_report"],
                ),
                "wildcard resource selectors",
            ),
        ] {
            let error = match authorize_with_grant(
                &grant,
                &function,
                &test_invocation(json!({"operation": "module_validation_list"})),
            ) {
                Ok(()) => panic!("module validation {name} wildcard grant must be denied"),
                Err(error) => error.to_string(),
            };
            assert!(error.contains(expected), "{error}");
        }
    }

    fn test_grant(
        authority_scopes: &[&str],
        resource_kinds: &[&str],
        resource_selectors: &[&str],
    ) -> EngineGrant {
        let occurred_at = DateTime::parse_from_rfc3339("2026-06-25T12:00:00Z")
            .expect("timestamp")
            .with_timezone(&Utc);
        EngineGrant {
            grant_id: AuthorityGrantId::new("grant-update-diagnostic-selector").unwrap(),
            parent_grant_id: None,
            subject_actor_id: None,
            subject_worker_id: None,
            subject_invocation_id: None,
            lifecycle: EngineGrantLifecycle::Active,
            allowed_capabilities: vec!["capability::execute".to_owned()],
            allowed_namespaces: vec!["__no_namespace_authority__".to_owned()],
            allowed_authority_scopes: authority_scopes
                .iter()
                .map(|scope| (*scope).to_owned())
                .collect(),
            allowed_resource_kinds: resource_kinds
                .iter()
                .map(|kind| (*kind).to_owned())
                .collect(),
            resource_selectors: resource_selectors
                .iter()
                .map(|selector| (*selector).to_owned())
                .collect(),
            file_roots: vec!["/tmp".to_owned()],
            network_policy: "none".to_owned(),
            max_risk: RiskLevel::Low,
            budget: json!({"remainingTokens": 1, "remainingProcessMs": 1}),
            expires_at: None,
            can_delegate: false,
            provenance: json!({"source": "authorization_test"}),
            trace_id: TraceId::new("trace-update-diagnostic-selector").unwrap(),
            revision: 1,
            created_at: occurred_at,
            updated_at: occurred_at,
        }
    }

    fn test_execute_function() -> FunctionDefinition {
        FunctionDefinition::new(
            FunctionId::new("capability::execute").unwrap(),
            WorkerId::new("worker:capability").unwrap(),
            "test capability execute",
            VisibilityScope::System,
            EffectClass::DelegatedInvocation,
        )
    }

    fn test_invocation(payload: Value) -> Invocation {
        let context = CausalContext::new(
            ActorId::new("agent:update-diagnostic-selector").unwrap(),
            ActorKind::Agent,
            AuthorityGrantId::new("grant-update-diagnostic-selector").unwrap(),
            TraceId::new("trace-update-diagnostic-selector").unwrap(),
        )
        .with_scope("capability.execute")
        .with_scope("update_diagnostics.read")
        .with_scope("resource.read")
        .with_session_id("session-update-diagnostic-selector")
        .with_workspace_id("workspace-update-diagnostic-selector");
        Invocation {
            id: InvocationId::new("invocation-update-diagnostic-selector").unwrap(),
            function_id: FunctionId::new("capability::execute").unwrap(),
            delivery_mode: DeliveryMode::Sync,
            payload,
            causal_context: context,
        }
    }
}

fn allows_function(grant: &EngineGrant, function_id: &FunctionId) -> bool {
    allows_item(&grant.allowed_capabilities, function_id.as_str())
        || allows_item(&grant.allowed_namespaces, function_id.namespace())
}

fn allows_item(allowed: &[String], value: &str) -> bool {
    allowed.iter().any(|item| item == "*" || item == value)
}
