//! Module-specific grant derivation and narrowing checks.
//!
//! Module activation, source approval, trust roots, scheduled audits, and
//! local-process runtime materialization all derive or validate grants through
//! one policy surface. Keeping those checks here avoids scattering risk,
//! network, delegation, approval, and file-root narrowing rules across the
//! lifecycle and trust submodules.

use std::path::PathBuf;

use super::*;

pub(super) fn child_grant_from_payload(
    invocation: &Invocation,
    manifest: &Value,
    worker_id: &WorkerId,
    request: &serde_json::Map<String, Value>,
) -> Result<DeriveGrant> {
    let manifest_grants = required_object(manifest.get("requiredGrants"), "requiredGrants")?;
    let allowed_capabilities = child_string_array(request, manifest_grants, "allowedCapabilities")?;
    let allowed_namespaces = child_string_array(request, manifest_grants, "allowedNamespaces")?;
    let allowed_authority_scopes =
        child_string_array(request, manifest_grants, "allowedAuthorityScopes")?;
    let allowed_resource_kinds =
        child_string_array(request, manifest_grants, "allowedResourceKinds")?;
    let resource_selectors = child_string_array(request, manifest_grants, "resourceSelectors")?;
    let file_roots = child_string_array(request, manifest_grants, "fileRoots")?;
    ensure_subset(
        &allowed_capabilities,
        &string_array_from(
            manifest_grants.get("allowedCapabilities"),
            "allowedCapabilities",
        )?,
        "declared capabilities",
    )?;
    ensure_subset(
        &allowed_namespaces,
        &string_array_from(
            manifest_grants.get("allowedNamespaces"),
            "allowedNamespaces",
        )?,
        "declared namespaces",
    )?;
    ensure_subset(
        &allowed_authority_scopes,
        &string_array_from(
            manifest_grants.get("allowedAuthorityScopes"),
            "allowedAuthorityScopes",
        )?,
        "declared authority scopes",
    )?;
    ensure_subset(
        &allowed_resource_kinds,
        &string_array_from(
            manifest_grants.get("allowedResourceKinds"),
            "allowedResourceKinds",
        )?,
        "declared resource kinds",
    )?;
    ensure_subset(
        &resource_selectors,
        &string_array_from(
            manifest_grants.get("resourceSelectors"),
            "resourceSelectors",
        )?,
        "declared resource selectors",
    )?;
    ensure_subset(
        &file_roots,
        &string_array_from(manifest_grants.get("fileRoots"), "fileRoots")?,
        "declared file roots",
    )?;
    let network_policy = request
        .get("networkPolicy")
        .and_then(Value::as_str)
        .unwrap_or_else(|| {
            manifest_grants
                .get("networkPolicy")
                .and_then(Value::as_str)
                .unwrap_or("none")
        })
        .to_owned();
    if network_rank(&network_policy)?
        > network_rank(required_map_str(manifest_grants, "networkPolicy")?)?
    {
        return Err(EngineError::PolicyViolation(
            "requested network policy exceeds package manifest".to_owned(),
        ));
    }
    let max_risk = parse_risk(
        request
            .get("maxRisk")
            .and_then(Value::as_str)
            .unwrap_or(required_map_str(manifest_grants, "maxRisk")?),
    )?;
    if max_risk > parse_risk(required_map_str(manifest_grants, "maxRisk")?)? {
        return Err(EngineError::PolicyViolation(
            "requested risk exceeds package manifest".to_owned(),
        ));
    }
    let can_delegate = request
        .get("canDelegate")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    if can_delegate
        && !manifest_grants
            .get("canDelegate")
            .and_then(Value::as_bool)
            .unwrap_or(false)
    {
        return Err(EngineError::PolicyViolation(
            "requested delegation exceeds package manifest".to_owned(),
        ));
    }
    let approval_required = request
        .get("approvalRequired")
        .and_then(Value::as_bool)
        .unwrap_or_else(|| {
            manifest_grants
                .get("approvalRequired")
                .and_then(Value::as_bool)
                .unwrap_or(false)
        });
    Ok(DeriveGrant {
        grant_id: request
            .get("grantId")
            .and_then(Value::as_str)
            .map(|value| AuthorityGrantId::new(value.to_owned()))
            .transpose()?,
        parent_grant_id: invocation.causal_context.authority_grant_id.clone(),
        subject_actor_id: None,
        subject_worker_id: Some(worker_id.clone()),
        subject_invocation_id: Some(invocation.id.clone()),
        allowed_capabilities,
        allowed_namespaces,
        allowed_authority_scopes,
        allowed_resource_kinds,
        resource_selectors,
        file_roots,
        network_policy,
        max_risk,
        budget: request
            .get("budget")
            .cloned()
            .unwrap_or_else(|| json!({"class": "module_activation"})),
        expires_at: request
            .get("expiresAt")
            .and_then(Value::as_str)
            .map(parse_datetime)
            .transpose()?,
        can_delegate,
        approval_required,
        provenance: json!({
            "source": "module.activate",
            "invocationId": invocation.id.as_str(),
        }),
        trace_id: invocation.causal_context.trace_id.clone(),
    })
}

fn child_string_array(
    request: &serde_json::Map<String, Value>,
    manifest: &serde_json::Map<String, Value>,
    field: &str,
) -> Result<Vec<String>> {
    if let Some(value) = request.get(field) {
        string_array_from(Some(value), field)
    } else {
        string_array_from(manifest.get(field), field)
    }
}

pub(super) fn ensure_subset(child: &[String], parent: &[String], label: &str) -> Result<()> {
    if parent.iter().any(|value| value == "*") {
        return Ok(());
    }
    for value in child {
        if !parent.iter().any(|allowed| allowed == value) {
            return Err(EngineError::PolicyViolation(format!(
                "requested {label} include unauthorized value {value}"
            )));
        }
    }
    Ok(())
}

pub(super) fn ensure_grant_request_narrows_caller(
    host: &ModulePrimitiveHandler,
    invocation: &Invocation,
    request: &DeriveGrant,
) -> Result<()> {
    let parent = host
        .inspect_grant(&invocation.causal_context.authority_grant_id)?
        .ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "caller grant {} is not inspectable",
                invocation.causal_context.authority_grant_id
            ))
        })?;
    if parent.lifecycle != EngineGrantLifecycle::Active {
        return Err(EngineError::PolicyViolation(format!(
            "caller grant {} is not active",
            parent.grant_id
        )));
    }
    ensure_subset(
        &request.allowed_capabilities,
        &parent.allowed_capabilities,
        "caller grant capabilities",
    )?;
    ensure_subset(
        &request.allowed_namespaces,
        &parent.allowed_namespaces,
        "caller grant namespaces",
    )?;
    ensure_subset(
        &request.allowed_authority_scopes,
        &parent.allowed_authority_scopes,
        "caller grant authority scopes",
    )?;
    ensure_subset(
        &request.allowed_resource_kinds,
        &parent.allowed_resource_kinds,
        "caller grant resource kinds",
    )?;
    ensure_subset(
        &request.resource_selectors,
        &parent.resource_selectors,
        "caller grant resource selectors",
    )?;
    ensure_subset(
        &request.file_roots,
        &parent.file_roots,
        "caller grant file roots",
    )?;
    if network_rank(&request.network_policy)? > network_rank(&parent.network_policy)? {
        return Err(EngineError::PolicyViolation(
            "requested network policy exceeds caller grant".to_owned(),
        ));
    }
    if request.max_risk > parent.max_risk {
        return Err(EngineError::PolicyViolation(
            "requested maxRisk exceeds caller grant".to_owned(),
        ));
    }
    if let (Some(child), Some(parent)) = (request.expires_at, parent.expires_at)
        && child > parent
    {
        return Err(EngineError::PolicyViolation(
            "requested expiry exceeds caller grant".to_owned(),
        ));
    }
    if request.can_delegate && !parent.can_delegate {
        return Err(EngineError::PolicyViolation(
            "requested delegation exceeds caller grant".to_owned(),
        ));
    }
    if parent.approval_required && !request.approval_required {
        return Err(EngineError::PolicyViolation(
            "caller grant requires child approval".to_owned(),
        ));
    }
    Ok(())
}

pub(super) fn ensure_grant_ceiling_narrows_caller(
    host: &ModulePrimitiveHandler,
    invocation: &Invocation,
    ceiling: &serde_json::Map<String, Value>,
) -> Result<()> {
    let parent = host
        .inspect_grant(&invocation.causal_context.authority_grant_id)?
        .ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "caller grant {} is not inspectable",
                invocation.causal_context.authority_grant_id
            ))
        })?;
    if parent.lifecycle != EngineGrantLifecycle::Active {
        return Err(EngineError::PolicyViolation(format!(
            "caller grant {} is not active",
            parent.grant_id
        )));
    }
    ensure_subset(
        &string_array_from(ceiling.get("allowedCapabilities"), "allowedCapabilities")?,
        &parent.allowed_capabilities,
        "caller grant capabilities",
    )?;
    ensure_subset(
        &string_array_from(ceiling.get("allowedNamespaces"), "allowedNamespaces")?,
        &parent.allowed_namespaces,
        "caller grant namespaces",
    )?;
    ensure_subset(
        &string_array_from(
            ceiling.get("allowedAuthorityScopes"),
            "allowedAuthorityScopes",
        )?,
        &parent.allowed_authority_scopes,
        "caller grant authority scopes",
    )?;
    ensure_subset(
        &string_array_from(ceiling.get("allowedResourceKinds"), "allowedResourceKinds")?,
        &parent.allowed_resource_kinds,
        "caller grant resource kinds",
    )?;
    ensure_subset(
        &string_array_from(ceiling.get("resourceSelectors"), "resourceSelectors")?,
        &parent.resource_selectors,
        "caller grant resource selectors",
    )?;
    ensure_subset(
        &string_array_from(ceiling.get("fileRoots"), "fileRoots")?,
        &parent.file_roots,
        "caller grant file roots",
    )?;
    if network_rank(required_map_str(ceiling, "networkPolicy")?)?
        > network_rank(&parent.network_policy)?
    {
        return Err(EngineError::PolicyViolation(
            "trust grant ceiling exceeds caller network policy".to_owned(),
        ));
    }
    if parse_risk(required_map_str(ceiling, "maxRisk")?)? > parent.max_risk {
        return Err(EngineError::PolicyViolation(
            "trust grant ceiling exceeds caller maxRisk".to_owned(),
        ));
    }
    if ceiling
        .get("canDelegate")
        .and_then(Value::as_bool)
        .unwrap_or(false)
        && !parent.can_delegate
    {
        return Err(EngineError::PolicyViolation(
            "trust grant ceiling exceeds caller delegation".to_owned(),
        ));
    }
    if parent.approval_required
        && !ceiling
            .get("approvalRequired")
            .and_then(Value::as_bool)
            .unwrap_or(false)
    {
        return Err(EngineError::PolicyViolation(
            "caller grant requires trust ceiling approval".to_owned(),
        ));
    }
    Ok(())
}

pub(super) fn ensure_grant_request_within_ceiling(
    request: &DeriveGrant,
    ceiling: &serde_json::Map<String, Value>,
) -> Result<()> {
    ensure_subset(
        &request.allowed_capabilities,
        &string_array_from(ceiling.get("allowedCapabilities"), "allowedCapabilities")?,
        "approval grant capabilities",
    )?;
    ensure_subset(
        &request.allowed_namespaces,
        &string_array_from(ceiling.get("allowedNamespaces"), "allowedNamespaces")?,
        "approval grant namespaces",
    )?;
    ensure_subset(
        &request.allowed_authority_scopes,
        &string_array_from(
            ceiling.get("allowedAuthorityScopes"),
            "allowedAuthorityScopes",
        )?,
        "approval grant authority scopes",
    )?;
    ensure_subset(
        &request.allowed_resource_kinds,
        &string_array_from(ceiling.get("allowedResourceKinds"), "allowedResourceKinds")?,
        "approval grant resource kinds",
    )?;
    ensure_subset(
        &request.resource_selectors,
        &string_array_from(ceiling.get("resourceSelectors"), "resourceSelectors")?,
        "approval grant resource selectors",
    )?;
    ensure_subset(
        &request.file_roots,
        &string_array_from(ceiling.get("fileRoots"), "fileRoots")?,
        "approval grant file roots",
    )?;
    if network_rank(&request.network_policy)?
        > network_rank(required_map_str(ceiling, "networkPolicy")?)?
    {
        return Err(EngineError::PolicyViolation(
            "requested network policy exceeds source approval".to_owned(),
        ));
    }
    if request.max_risk > parse_risk(required_map_str(ceiling, "maxRisk")?)? {
        return Err(EngineError::PolicyViolation(
            "requested maxRisk exceeds source approval".to_owned(),
        ));
    }
    if request.can_delegate
        && !ceiling
            .get("canDelegate")
            .and_then(Value::as_bool)
            .unwrap_or(false)
    {
        return Err(EngineError::PolicyViolation(
            "requested delegation exceeds source approval".to_owned(),
        ));
    }
    Ok(())
}

pub(super) fn ensure_same_set(child: &[String], parent: &[String], label: &str) -> Result<()> {
    ensure_subset(child, parent, label)?;
    ensure_subset(parent, child, label)?;
    Ok(())
}

pub(super) fn risk_label(risk: RiskLevel) -> &'static str {
    match risk {
        RiskLevel::Low => "low",
        RiskLevel::Medium => "medium",
        RiskLevel::High => "high",
        RiskLevel::Critical => "critical",
    }
}

pub(super) fn ensure_path_within_grant_roots(path: &str, roots: &[String]) -> Result<()> {
    if roots.iter().any(|root| root == "*") {
        return Ok(());
    }
    let path = canonical_path_lossy(path)?;
    for root in roots {
        let root = canonical_path_lossy(root)?;
        if path.starts_with(&root) {
            return Ok(());
        }
    }
    Err(EngineError::PolicyViolation(format!(
        "materialized executable {} is outside activation fileRoots",
        path.display()
    )))
}

fn canonical_path_lossy(path: &str) -> Result<PathBuf> {
    let path = PathBuf::from(path);
    if path.exists() {
        path.canonicalize().map_err(|error| {
            EngineError::PolicyViolation(format!(
                "failed to canonicalize materialized path {}: {error}",
                path.display()
            ))
        })
    } else if path.is_absolute() {
        Ok(path)
    } else {
        std::env::current_dir()
            .map(|cwd| cwd.join(path))
            .map_err(|error| {
                EngineError::PolicyViolation(format!(
                    "failed to resolve relative materialized path: {error}"
                ))
            })
    }
}

fn network_rank(value: &str) -> Result<u8> {
    match value {
        "none" => Ok(0),
        "loopback" => Ok(1),
        "declared" => Ok(2),
        "unrestricted" => Ok(3),
        other => Err(EngineError::PolicyViolation(format!(
            "unsupported network policy {other}"
        ))),
    }
}

pub(super) fn ensure_grant_ceiling_within_ceiling(
    child: &serde_json::Map<String, Value>,
    parent: &serde_json::Map<String, Value>,
    label: &str,
) -> Result<()> {
    ensure_subset(
        &string_array_from(child.get("allowedCapabilities"), "allowedCapabilities")?,
        &string_array_from(parent.get("allowedCapabilities"), "allowedCapabilities")?,
        &format!("{label} capabilities"),
    )?;
    ensure_subset(
        &string_array_from(child.get("allowedNamespaces"), "allowedNamespaces")?,
        &string_array_from(parent.get("allowedNamespaces"), "allowedNamespaces")?,
        &format!("{label} namespaces"),
    )?;
    ensure_subset(
        &string_array_from(
            child.get("allowedAuthorityScopes"),
            "allowedAuthorityScopes",
        )?,
        &string_array_from(
            parent.get("allowedAuthorityScopes"),
            "allowedAuthorityScopes",
        )?,
        &format!("{label} authority scopes"),
    )?;
    ensure_subset(
        &string_array_from(child.get("allowedResourceKinds"), "allowedResourceKinds")?,
        &string_array_from(parent.get("allowedResourceKinds"), "allowedResourceKinds")?,
        &format!("{label} resource kinds"),
    )?;
    ensure_subset(
        &string_array_from(child.get("resourceSelectors"), "resourceSelectors")?,
        &string_array_from(parent.get("resourceSelectors"), "resourceSelectors")?,
        &format!("{label} resource selectors"),
    )?;
    ensure_subset(
        &string_array_from(child.get("fileRoots"), "fileRoots")?,
        &string_array_from(parent.get("fileRoots"), "fileRoots")?,
        &format!("{label} file roots"),
    )?;
    if network_rank(required_map_str(child, "networkPolicy")?)?
        > network_rank(required_map_str(parent, "networkPolicy")?)?
    {
        return Err(EngineError::PolicyViolation(format!(
            "{label} network policy exceeds parent"
        )));
    }
    if parse_risk(required_map_str(child, "maxRisk")?)?
        > parse_risk(required_map_str(parent, "maxRisk")?)?
    {
        return Err(EngineError::PolicyViolation(format!(
            "{label} maxRisk exceeds parent"
        )));
    }
    if child
        .get("canDelegate")
        .and_then(Value::as_bool)
        .unwrap_or(false)
        && !parent
            .get("canDelegate")
            .and_then(Value::as_bool)
            .unwrap_or(false)
    {
        return Err(EngineError::PolicyViolation(format!(
            "{label} delegation exceeds parent"
        )));
    }
    if parent
        .get("approvalRequired")
        .and_then(Value::as_bool)
        .unwrap_or(false)
        && !child
            .get("approvalRequired")
            .and_then(Value::as_bool)
            .unwrap_or(false)
    {
        return Err(EngineError::PolicyViolation(format!(
            "{label} approval policy exceeds parent"
        )));
    }
    Ok(())
}
