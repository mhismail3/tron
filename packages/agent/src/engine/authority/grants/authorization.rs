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
    for scope in &function.required_authority.scopes {
        if !allows_item(&grant.allowed_authority_scopes, scope) {
            return Err(EngineError::PolicyViolation(format!(
                "authority grant {} does not allow required authority {scope}",
                grant.grant_id
            )));
        }
    }
    if let Some(kind) = resource_kind_from_invocation(invocation)
        && !allows_item(&grant.allowed_resource_kinds, &kind)
    {
        return Err(EngineError::PolicyViolation(format!(
            "authority grant {} does not allow resource kind {kind}",
            grant.grant_id
        )));
    }
    ensure_resource_selectors(grant, invocation)?;
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

fn ensure_resource_selectors(grant: &EngineGrant, invocation: &Invocation) -> Result<()> {
    if allows_item(&grant.resource_selectors, "*") {
        return Ok(());
    }
    for resource_id in resource_ids_from_invocation(invocation) {
        if !allows_resource_id(grant, &resource_id) {
            return Err(EngineError::PolicyViolation(format!(
                "authority grant {} does not allow resource {resource_id}",
                grant.grant_id
            )));
        }
    }
    if resource_ids_from_invocation(invocation).is_empty()
        && let Some(kind) = resource_kind_from_invocation(invocation)
        && !allows_item(&grant.resource_selectors, &format!("kind:{kind}"))
    {
        return Err(EngineError::PolicyViolation(format!(
            "authority grant {} does not allow new resource kind {kind}",
            grant.grant_id
        )));
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
    ]
    .into_iter()
    .filter_map(|field| invocation.payload.get(field).and_then(Value::as_str))
    .map(str::to_owned)
    .collect()
}

fn resource_kind_from_invocation(invocation: &Invocation) -> Option<String> {
    match invocation.function_id.as_str() {
        "resource::create" | "artifact::create" | "goal::create" | "claim::attach"
        | "evidence::attach" | "decision::create" => invocation
            .payload
            .get("kind")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .or_else(|| wrapper_resource_kind(invocation.function_id.as_str()).map(str::to_owned)),
        _ => wrapper_resource_kind(invocation.function_id.as_str()).map(str::to_owned),
    }
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
        _ => None,
    }
}

fn allows_function(grant: &EngineGrant, function_id: &FunctionId) -> bool {
    allows_item(&grant.allowed_capabilities, function_id.as_str())
        || allows_item(&grant.allowed_namespaces, function_id.namespace())
}

fn allows_item(allowed: &[String], value: &str) -> bool {
    allowed.iter().any(|item| item == "*" || item == value)
}
