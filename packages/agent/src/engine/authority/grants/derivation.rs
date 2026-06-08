use chrono::Utc;
use serde_json::Value;

use crate::engine::authority::grants::model::{DeriveGrant, EngineGrant, EngineGrantLifecycle};
use crate::engine::kernel::errors::{EngineError, Result};

pub(super) fn ensure_parent_can_derive(parent: &EngineGrant) -> Result<()> {
    authorize_active(parent)?;
    if !parent.can_delegate {
        return Err(EngineError::PolicyViolation(format!(
            "authority grant {} cannot delegate",
            parent.grant_id
        )));
    }
    Ok(())
}

pub(super) fn ensure_child_narrows_parent(parent: &EngineGrant, child: &DeriveGrant) -> Result<()> {
    ensure_list_narrows(
        "capabilities",
        &parent.allowed_capabilities,
        &child.allowed_capabilities,
    )?;
    ensure_list_narrows(
        "namespaces",
        &parent.allowed_namespaces,
        &child.allowed_namespaces,
    )?;
    ensure_list_narrows(
        "authority scopes",
        &parent.allowed_authority_scopes,
        &child.allowed_authority_scopes,
    )?;
    ensure_list_narrows(
        "resource kinds",
        &parent.allowed_resource_kinds,
        &child.allowed_resource_kinds,
    )?;
    ensure_list_narrows(
        "resource selectors",
        &parent.resource_selectors,
        &child.resource_selectors,
    )?;
    ensure_file_roots_narrow(&parent.file_roots, &child.file_roots)?;
    if network_rank(&child.network_policy)? > network_rank(&parent.network_policy)? {
        return Err(EngineError::PolicyViolation(
            "child grant network policy exceeds parent".to_owned(),
        ));
    }
    if child.max_risk > parent.max_risk {
        return Err(EngineError::PolicyViolation(
            "child grant risk exceeds parent".to_owned(),
        ));
    }
    ensure_budget_narrows(&parent.budget, &child.budget)?;
    if let (Some(parent_expiry), Some(child_expiry)) = (parent.expires_at, child.expires_at)
        && child_expiry > parent_expiry
    {
        return Err(EngineError::PolicyViolation(
            "child grant expiry exceeds parent".to_owned(),
        ));
    }
    if parent.expires_at.is_some() && child.expires_at.is_none() {
        return Err(EngineError::PolicyViolation(
            "child grant cannot remove parent expiry".to_owned(),
        ));
    }
    if child.can_delegate && !parent.can_delegate {
        return Err(EngineError::PolicyViolation(
            "child grant delegation exceeds parent".to_owned(),
        ));
    }
    Ok(())
}

fn ensure_budget_narrows(parent: &Value, child: &Value) -> Result<()> {
    for field in [
        "remainingInvocations",
        "remainingTokens",
        "remainingProcessMs",
        "maxInvocations",
        "maxTokens",
        "maxProcessMs",
    ] {
        let Some(parent_value) = parent.get(field).and_then(Value::as_u64) else {
            continue;
        };
        if child
            .get(field)
            .and_then(Value::as_u64)
            .is_some_and(|child_value| child_value > parent_value)
        {
            return Err(EngineError::PolicyViolation(format!(
                "child grant budget {field} exceeds parent"
            )));
        }
    }
    Ok(())
}

fn authorize_active(grant: &EngineGrant) -> Result<()> {
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
    Ok(())
}

fn ensure_list_narrows(label: &str, parent: &[String], child: &[String]) -> Result<()> {
    if child.is_empty() {
        return Err(EngineError::PolicyViolation(format!(
            "child grant {label} must not be empty"
        )));
    }
    if parent.iter().any(|item| item == "*") {
        return Ok(());
    }
    for item in child {
        if item == "*" || !parent.iter().any(|parent| parent == item) {
            return Err(EngineError::PolicyViolation(format!(
                "child grant {label} exceeds parent"
            )));
        }
    }
    Ok(())
}

fn ensure_file_roots_narrow(parent: &[String], child: &[String]) -> Result<()> {
    if child.is_empty() {
        return Err(EngineError::PolicyViolation(
            "child grant file roots must not be empty".to_owned(),
        ));
    }
    if parent.iter().any(|item| item == "*") {
        return Ok(());
    }
    for root in child {
        if root == "*" {
            return Err(EngineError::PolicyViolation(
                "child grant file roots exceed parent".to_owned(),
            ));
        }
        if !parent.iter().any(|parent| root.starts_with(parent)) {
            return Err(EngineError::PolicyViolation(
                "child grant file roots exceed parent".to_owned(),
            ));
        }
    }
    Ok(())
}

fn network_rank(value: &str) -> Result<u8> {
    match value {
        "none" => Ok(0),
        "loopback" => Ok(1),
        "declared" => Ok(2),
        "unrestricted" => Ok(3),
        _ => Err(EngineError::PolicyViolation(format!(
            "unsupported network policy {value}"
        ))),
    }
}

pub(super) fn validate_derive_request(request: &DeriveGrant) -> Result<()> {
    validate_non_empty_list("allowedCapabilities", &request.allowed_capabilities)?;
    validate_non_empty_list("allowedNamespaces", &request.allowed_namespaces)?;
    validate_non_empty_list("allowedAuthorityScopes", &request.allowed_authority_scopes)?;
    validate_non_empty_list("allowedResourceKinds", &request.allowed_resource_kinds)?;
    validate_non_empty_list("resourceSelectors", &request.resource_selectors)?;
    validate_non_empty_list("fileRoots", &request.file_roots)?;
    let _ = network_rank(&request.network_policy)?;
    if let Some(expires_at) = request.expires_at
        && expires_at <= Utc::now()
    {
        return Err(EngineError::PolicyViolation(
            "child grant expiry must be in the future".to_owned(),
        ));
    }
    Ok(())
}

fn validate_non_empty_list(field: &str, values: &[String]) -> Result<()> {
    if values.is_empty() || values.iter().any(|value| value.trim().is_empty()) {
        return Err(EngineError::PolicyViolation(format!(
            "{field} must contain non-empty values"
        )));
    }
    Ok(())
}
