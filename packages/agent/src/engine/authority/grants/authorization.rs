//! Runtime authorization against resolved engine grants.
//!
//! This policy protects authenticated non-local engine boundaries. Trusted-local
//! agent and worker calls bypass it before grant lookup; the authorizer contains
//! no model-tool or worker-operation special cases.

use std::path::{Path, PathBuf};

use chrono::Utc;
use serde_json::Value;

use crate::engine::authority::grants::model::{EngineGrant, EngineGrantLifecycle};
use crate::engine::invocation::model::Invocation;
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

    ensure_resource_authority(grant, invocation)?;
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

fn ensure_resource_authority(grant: &EngineGrant, invocation: &Invocation) -> Result<()> {
    let resource_kinds = invocation_resource_kinds(invocation);
    for kind in &resource_kinds {
        if !allows_item(&grant.allowed_resource_kinds, kind) {
            return Err(EngineError::PolicyViolation(format!(
                "authority grant {} does not allow resource kind {kind}",
                grant.grant_id
            )));
        }
    }
    ensure_resource_selectors(grant, invocation, &resource_kinds)
}

fn ensure_resource_selectors(
    grant: &EngineGrant,
    invocation: &Invocation,
    resource_kinds: &[String],
) -> Result<()> {
    if allows_item(&grant.resource_selectors, "*") {
        return Ok(());
    }
    let resource_ids = invocation_resource_ids(invocation);
    for resource_id in &resource_ids {
        if !allows_resource_id(grant, resource_id) {
            return Err(EngineError::PolicyViolation(format!(
                "authority grant {} does not allow resource {resource_id}",
                grant.grant_id
            )));
        }
    }
    if resource_ids.is_empty() {
        for kind in resource_kinds {
            if !allows_item(&grant.resource_selectors, &format!("kind:{kind}")) {
                return Err(EngineError::PolicyViolation(format!(
                    "authority grant {} does not allow new resource kind {kind}",
                    grant.grant_id
                )));
            }
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

fn invocation_resource_ids(invocation: &Invocation) -> Vec<String> {
    invocation
        .payload
        .as_object()
        .into_iter()
        .flat_map(|payload| payload.iter())
        .filter(|(field, _)| {
            *field == "resourceId"
                || field.ends_with("ResourceId")
                || field.ends_with("ResourceRef")
        })
        .filter_map(|(_, value)| value.as_str())
        .map(str::to_owned)
        .collect()
}

fn invocation_resource_kinds(invocation: &Invocation) -> Vec<String> {
    let mut kinds = Vec::new();
    match invocation.function_id.as_str() {
        "resource::create" => {
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
    [
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
    .collect::<Result<Vec<_>>>()
}

fn resolve_invocation_path(_invocation: &Invocation, raw: &str) -> Result<PathBuf> {
    let path = Path::new(raw);
    Ok(path.to_path_buf())
}

fn wrapper_resource_kind(function_id: &str) -> Option<&'static str> {
    match function_id {
        id if id.starts_with("materialized_file::") => Some("materialized_file"),
        id if id.starts_with("patch::") => Some("patch_proposal"),
        id if id.starts_with("ui::") => Some("ui_surface"),
        _ => None,
    }
}

fn push_unique(kinds: &mut Vec<String>, kind: &str) {
    if !kinds.iter().any(|existing| existing == kind) {
        kinds.push(kind.to_owned());
    }
}

fn allows_function(grant: &EngineGrant, function_id: &FunctionId) -> bool {
    allows_item(&grant.allowed_capabilities, function_id.as_str())
        || allows_item(&grant.allowed_namespaces, function_id.namespace())
}

fn allows_item(allowed: &[String], value: &str) -> bool {
    allowed.iter().any(|item| item == "*" || item == value)
}
