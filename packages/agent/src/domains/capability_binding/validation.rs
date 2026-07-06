use serde_json::{Map, Value, json};

use crate::domains::capability::operation_binding_metadata;
use crate::engine::{EngineResourceScope, Invocation};
use crate::shared::server::errors::CapabilityError;

use super::payload_safety::{
    reject_path_like, reject_prompt_like, reject_provider_visible_token_like, reject_secret_like,
    reject_shell_command_like,
};

pub(super) const CAPABILITY_BINDING_POLICY_VERSION: &str =
    "tron.capability_binding_policy_plane.v1";
pub(super) const CAPABILITY_MODULARITY_INVENTORY_VERSION: &str =
    "capability-modularity-inventory.v3";

pub(super) const LIST_LIMIT_DEFAULT: usize = 25;
pub(super) const LIST_LIMIT_MAX: usize = 100;
pub(super) const REQUEST_ID_MAX_BYTES: usize = 160;
pub(super) const DECISION_ID_MAX_BYTES: usize = 160;
pub(super) const POLICY_ID_MAX_BYTES: usize = 160;
pub(super) const TOKEN_MAX_BYTES: usize = 256;
pub(super) const TITLE_MAX_BYTES: usize = 160;
pub(super) const SUMMARY_MAX_BYTES: usize = 2_000;
pub(super) const IDEMPOTENCY_KEY_MAX_BYTES: usize = 256;
pub(super) const MAX_REFS: usize = 25;

pub(super) fn required_string(payload: &Value, field: &str) -> Result<String, CapabilityError> {
    optional_string(payload, field)?.ok_or_else(|| invalid(format!("{field} is required")))
}

pub(super) fn optional_string(
    payload: &Value,
    field: &str,
) -> Result<Option<String>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) if !value.trim().is_empty() => Ok(Some(value.clone())),
        Some(Value::String(_)) => Err(invalid(format!("{field} must not be empty"))),
        Some(_) => Err(invalid(format!("{field} must be a string"))),
    }
}

pub(super) fn optional_u64(payload: &Value, field: &str) -> Result<Option<u64>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(value)) => value
            .as_u64()
            .map(Some)
            .ok_or_else(|| invalid(format!("{field} must be a positive integer"))),
        Some(_) => Err(invalid(format!("{field} must be a positive integer"))),
    }
}

pub(super) fn optional_bool(payload: &Value, field: &str) -> Result<Option<bool>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(value)) => Ok(Some(*value)),
        Some(_) => Err(invalid(format!("{field} must be a boolean"))),
    }
}

pub(super) fn optional_array(
    payload: &Value,
    field: &str,
) -> Result<Option<Vec<Value>>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Array(items)) => Ok(Some(items.clone())),
        Some(_) => Err(invalid(format!("{field} must be an array"))),
    }
}

pub(super) fn bounded_text(
    field: &str,
    value: &str,
    max_bytes: usize,
) -> Result<String, CapabilityError> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Err(invalid(format!("{field} must not be empty")));
    }
    if trimmed.len() > max_bytes {
        return Err(invalid(format!("{field} exceeds {max_bytes} bytes")));
    }
    reject_secret_like(field, trimmed)?;
    reject_provider_visible_token_like(field, trimmed)?;
    reject_prompt_like(field, trimmed)?;
    reject_shell_command_like(field, trimmed)?;
    Ok(trimmed.to_owned())
}

pub(super) fn bounded_token(
    field: &str,
    value: &str,
    max_bytes: usize,
) -> Result<String, CapabilityError> {
    let trimmed = value.trim();
    if trimmed.is_empty()
        || trimmed == "*"
        || trimmed.eq_ignore_ascii_case("all")
        || trimmed.eq_ignore_ascii_case("any")
        || trimmed.len() > max_bytes
        || !trimmed
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b':' | b'-' | b'_' | b'.'))
    {
        return Err(invalid(format!(
            "{field} must be a bounded non-wildcard token"
        )));
    }
    reject_secret_like(field, trimmed)?;
    reject_path_like(field, trimmed)?;
    Ok(trimmed.to_owned())
}

pub(super) fn bounded_provider_visible_token(
    field: &str,
    value: &str,
    max_bytes: usize,
) -> Result<String, CapabilityError> {
    let trimmed = bounded_token(field, value, max_bytes)?;
    reject_provider_visible_token_like(field, &trimmed)?;
    Ok(trimmed)
}

pub(super) fn idempotency_key(
    invocation: &Invocation,
    payload: &Value,
) -> Result<String, CapabilityError> {
    if let Some(key) = invocation.causal_context.idempotency_key.as_deref() {
        return bounded_token("idempotencyKey", key, IDEMPOTENCY_KEY_MAX_BYTES);
    }
    optional_string(payload, "idempotencyKey")?
        .map(|key| bounded_token("idempotencyKey", &key, IDEMPOTENCY_KEY_MAX_BYTES))
        .transpose()?
        .ok_or_else(|| invalid("capability binding write operations require an idempotencyKey"))
}

pub(super) fn resource_scope(
    invocation: &Invocation,
) -> Result<EngineResourceScope, CapabilityError> {
    invocation
        .causal_context
        .session_id
        .as_ref()
        .map(|session| EngineResourceScope::Session(session.clone()))
        .or_else(|| {
            invocation
                .causal_context
                .workspace_id
                .as_ref()
                .map(|workspace| EngineResourceScope::Workspace(workspace.clone()))
        })
        .ok_or_else(|| invalid("capability binding requires trusted session or workspace scope"))
}

pub(super) fn request_lifecycle_state(payload: &Value) -> Result<String, CapabilityError> {
    let state =
        optional_string(payload, "lifecycleState")?.unwrap_or_else(|| "pending_review".to_owned());
    if matches!(state.as_str(), "pending_review" | "superseded" | "archived") {
        Ok(state)
    } else {
        Err(invalid(format!(
            "unsupported capability binding request lifecycle {state}"
        )))
    }
}

pub(super) fn decision_lifecycle_state(payload: &Value) -> Result<String, CapabilityError> {
    let decision = required_string(payload, "decision")?;
    if matches!(decision.as_str(), "approved" | "rejected" | "denied") {
        Ok(if decision == "approved" {
            "approved_policy".to_owned()
        } else {
            "rejected".to_owned()
        })
    } else {
        Err(invalid(format!(
            "unsupported capability binding decision {decision}"
        )))
    }
}

pub(super) fn policy_lifecycle_state(payload: &Value) -> Result<String, CapabilityError> {
    let state = optional_string(payload, "lifecycleState")?.unwrap_or_else(|| "active".to_owned());
    if matches!(
        state.as_str(),
        "active" | "disabled" | "superseded" | "archived"
    ) {
        Ok(state)
    } else {
        Err(invalid(format!(
            "unsupported capability binding policy lifecycle {state}"
        )))
    }
}

pub(super) fn operation_name(payload: &Value) -> Result<String, CapabilityError> {
    bounded_provider_visible_token(
        "targetOperation",
        &required_string(payload, "targetOperation")?,
        TOKEN_MAX_BYTES,
    )
}

pub(super) struct TargetOperationBindingMetadata {
    pub(super) operation_name: String,
    pub(super) family: String,
    pub(super) current_owner: String,
    pub(super) ownership_class: String,
    pub(super) replacement_target: String,
}

pub(super) fn target_operation_binding_metadata(
    payload: &Value,
) -> Result<TargetOperationBindingMetadata, CapabilityError> {
    let operation_name = operation_name(payload)?;
    let metadata = operation_binding_metadata(&operation_name)
        .ok_or_else(|| invalid(format!("unknown targetOperation {operation_name}")))?;
    let supplied_owner = current_owner(payload)?;
    if supplied_owner != metadata.current_owner {
        return Err(invalid(format!(
            "currentBuiltInOwner mismatch for {operation_name}: expected {}",
            metadata.current_owner
        )));
    }
    let supplied_class = ownership_class(payload)?;
    if supplied_class != metadata.ownership_class {
        return Err(invalid(format!(
            "ownershipClass mismatch for {operation_name}: expected {}",
            metadata.ownership_class
        )));
    }
    let supplied_replacement_target = replacement_target(payload)?;
    if supplied_replacement_target != metadata.replacement_target {
        return Err(invalid(format!(
            "replacementTarget mismatch for {operation_name}: expected {}",
            metadata.replacement_target
        )));
    }
    Ok(TargetOperationBindingMetadata {
        operation_name,
        family: metadata.family.to_owned(),
        current_owner: metadata.current_owner.to_owned(),
        ownership_class: metadata.ownership_class.to_owned(),
        replacement_target: metadata.replacement_target.to_owned(),
    })
}

pub(super) fn current_owner(payload: &Value) -> Result<String, CapabilityError> {
    bounded_text(
        "currentBuiltInOwner",
        &required_string(payload, "currentBuiltInOwner")?,
        SUMMARY_MAX_BYTES,
    )
}

pub(super) fn replacement_target(payload: &Value) -> Result<String, CapabilityError> {
    bounded_provider_visible_token(
        "replacementTarget",
        &required_string(payload, "replacementTarget")?,
        TOKEN_MAX_BYTES,
    )
}

pub(super) fn ownership_class(payload: &Value) -> Result<String, CapabilityError> {
    let value = required_string(payload, "ownershipClass")?;
    if matches!(
        value.as_str(),
        "kernel_locked"
            | "governance_locked"
            | "record_plane"
            | "adapter_replaceable"
            | "module_owned"
            | "deferred"
    ) {
        bounded_provider_visible_token("ownershipClass", &value, TOKEN_MAX_BYTES)
    } else {
        Err(invalid(format!("unsupported ownershipClass {value}")))
    }
}

pub(super) fn binding_mode(payload: &Value) -> Result<String, CapabilityError> {
    let value = required_string(payload, "bindingMode")?;
    if matches!(value.as_str(), "shadow" | "extend" | "replace") {
        bounded_provider_visible_token("bindingMode", &value, TOKEN_MAX_BYTES)
    } else {
        Err(invalid(format!("unsupported bindingMode {value}")))
    }
}

pub(super) fn ensure_binding_mode_allowed(
    ownership_class: &str,
    binding_mode: &str,
    rollback_ref: &Option<Value>,
    disable_ref: &Option<Value>,
) -> Result<(), CapabilityError> {
    match ownership_class {
        "kernel_locked" | "governance_locked" if binding_mode == "replace" => Err(invalid(
            format!("{ownership_class} operations cannot request replacement"),
        )),
        "deferred" => Err(invalid(
            "deferred operations require a resolved ownership class before binding policy",
        )),
        "record_plane" if binding_mode == "replace" => Err(invalid(
            "record_plane operations may extend producers but cannot replace custody records",
        )),
        "adapter_replaceable" | "module_owned" if binding_mode == "replace" => {
            if rollback_ref.is_none() {
                Err(invalid(
                    "replace binding requests require rollbackRef metadata",
                ))
            } else if disable_ref.is_none() {
                Err(invalid(
                    "replace binding requests require disableRef metadata",
                ))
            } else {
                Ok(())
            }
        }
        _ => Ok(()),
    }
}

pub(super) fn actor_scope(payload: &Value) -> Result<String, CapabilityError> {
    let value = required_string(payload, "actorScope")?;
    if matches!(value.as_str(), "session" | "workspace") {
        bounded_provider_visible_token("actorScope", &value, TOKEN_MAX_BYTES)
    } else {
        Err(invalid(format!("unsupported actorScope {value}")))
    }
}

pub(super) fn authority_constraints(payload: &Value) -> Result<Value, CapabilityError> {
    let Value::Object(map) = payload
        .get("authorityConstraints")
        .ok_or_else(|| invalid("authorityConstraints is required"))?
    else {
        return Err(invalid("authorityConstraints must be an object"));
    };
    let network_policy = map
        .get("networkPolicy")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid("authorityConstraints.networkPolicy is required"))?;
    if network_policy != "none" {
        return Err(invalid(
            "capability binding policy requires authorityConstraints.networkPolicy none",
        ));
    }
    if map
        .get("agentStateInherited")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        return Err(invalid(
            "capability binding policy rejects agent_state inheritance",
        ));
    }
    let authority_scopes = string_array(map, "authorityScopes")?;
    let resource_kinds = string_array(map, "resourceKinds")?;
    if resource_kinds
        .iter()
        .any(|value| value.as_str() == Some("agent_state"))
    {
        return Err(invalid(
            "capability binding policy rejects agent_state resourceKinds",
        ));
    }
    if let Some(Value::Array(selectors)) = map.get("resourceSelectors") {
        for selector in selectors {
            let Some(selector) = selector.as_str() else {
                return Err(invalid(
                    "authorityConstraints.resourceSelectors entries must be strings",
                ));
            };
            if is_broad_selector(selector) {
                return Err(invalid(
                    "capability binding policy rejects wildcard resource selectors",
                ));
            }
        }
    }
    let resource_selectors = string_array(map, "resourceSelectors")?;
    if resource_selectors.is_empty() {
        return Err(invalid(
            "capability binding policy requires exact resourceSelectors",
        ));
    }
    Ok(json!({
        "networkPolicy": "none",
        "authorityScopes": authority_scopes,
        "resourceKinds": resource_kinds,
        "resourceSelectors": resource_selectors,
        "agentStateInherited": false,
        "rawGrantIdsStored": false,
        "wildcardSelectorsAllowed": false,
        "exactSelectorsRequired": true
    }))
}

pub(super) fn contract_requirements(payload: &Value) -> Result<Value, CapabilityError> {
    let refs = validate_ref_array(
        "contractEvidenceRefs",
        &optional_array(payload, "contractEvidenceRefs")?.unwrap_or_default(),
        MAX_REFS,
    )?;
    if refs.is_empty() {
        return Err(invalid(
            "capability binding requests require contractEvidenceRefs",
        ));
    }
    let evidence = validate_ref_array(
        "evidenceRefs",
        &optional_array(payload, "evidenceRefs")?.unwrap_or_default(),
        MAX_REFS,
    )?;
    let notes = optional_string(payload, "evidenceRequirements")?
        .map(|value| bounded_text("evidenceRequirements", &value, SUMMARY_MAX_BYTES))
        .transpose()?
        .unwrap_or_else(|| "contract-compatible evidence required before routing".to_owned());
    Ok(json!({
        "contractEvidenceRefs": refs,
        "evidenceRefs": evidence,
        "evidenceRequirements": notes,
        "providerSafeProjectionRequired": true,
        "contractCompatible": false,
        "runtimeParityRequired": true
    }))
}

pub(super) fn stale_version_guard(payload: &Value) -> Result<Value, CapabilityError> {
    let Value::Object(map) = payload
        .get("staleVersionGuard")
        .ok_or_else(|| invalid("staleVersionGuard is required"))?
    else {
        return Err(invalid("staleVersionGuard must be an object"));
    };
    let inventory = required_map_string(map, "staleVersionGuard", "expectedInventoryVersion")?;
    if inventory != CAPABILITY_MODULARITY_INVENTORY_VERSION {
        return Err(invalid(format!(
            "stale capability modularity inventory version {inventory}"
        )));
    }
    let policy = required_map_string(map, "staleVersionGuard", "expectedPolicyVersion")?;
    if policy != CAPABILITY_BINDING_POLICY_VERSION {
        return Err(invalid(format!(
            "stale capability binding policy version {policy}"
        )));
    }
    Ok(json!({
        "expectedInventoryVersion": CAPABILITY_MODULARITY_INVENTORY_VERSION,
        "expectedPolicyVersion": CAPABILITY_BINDING_POLICY_VERSION,
        "staleRequestRejected": true
    }))
}

pub(super) fn validate_ref_array(
    label: &str,
    refs: &[Value],
    max_items: usize,
) -> Result<Vec<Value>, CapabilityError> {
    if refs.len() > max_items {
        return Err(invalid(format!(
            "{label} may contain at most {max_items} items"
        )));
    }
    refs.iter()
        .map(|value| sanitize_ref_item(label, value))
        .collect()
}

pub(super) fn required_ref(payload: &Value, field: &str) -> Result<Value, CapabilityError> {
    sanitize_ref_item(
        field,
        payload
            .get(field)
            .ok_or_else(|| invalid(format!("{field} is required")))?,
    )
}

pub(super) fn optional_ref(payload: &Value, field: &str) -> Result<Option<Value>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => sanitize_ref_item(field, value).map(Some),
    }
}

fn sanitize_ref_item(label: &str, value: &Value) -> Result<Value, CapabilityError> {
    let Value::Object(map) = value else {
        return Err(invalid(format!("{label} entries must be objects")));
    };
    let kind = required_map_string(map, label, "kind")?;
    let resource_id = required_map_string(map, label, "resourceId")?;
    let role = map
        .get("role")
        .and_then(Value::as_str)
        .unwrap_or("evidence");
    let mut sanitized = Map::new();
    sanitized.insert(
        "kind".to_owned(),
        json!(bounded_provider_visible_token(
            &format!("{label}.kind"),
            kind,
            TOKEN_MAX_BYTES,
        )?),
    );
    sanitized.insert(
        "resourceId".to_owned(),
        json!(bounded_provider_visible_token(
            &format!("{label}.resourceId"),
            resource_id,
            TOKEN_MAX_BYTES,
        )?),
    );
    sanitized.insert(
        "role".to_owned(),
        json!(bounded_provider_visible_token(
            &format!("{label}.role"),
            role,
            TOKEN_MAX_BYTES,
        )?),
    );
    if let Some(summary) = map.get("summary").and_then(Value::as_str) {
        sanitized.insert(
            "summary".to_owned(),
            json!(bounded_text(
                &format!("{label}.summary"),
                summary,
                SUMMARY_MAX_BYTES,
            )?),
        );
    }
    Ok(Value::Object(sanitized))
}

fn string_array(map: &Map<String, Value>, field: &str) -> Result<Vec<Value>, CapabilityError> {
    let Some(value) = map.get(field) else {
        return Ok(Vec::new());
    };
    let Value::Array(items) = value else {
        return Err(invalid(format!(
            "authorityConstraints.{field} must be an array"
        )));
    };
    if items.len() > MAX_REFS {
        return Err(invalid(format!(
            "authorityConstraints.{field} may contain at most {MAX_REFS} items"
        )));
    }
    items
        .iter()
        .map(|item| {
            let text = item.as_str().ok_or_else(|| {
                invalid(format!(
                    "authorityConstraints.{field} entries must be strings"
                ))
            })?;
            bounded_provider_visible_token(
                &format!("authorityConstraints.{field}"),
                text,
                TOKEN_MAX_BYTES,
            )
            .map(|value| json!(value))
        })
        .collect()
}

fn required_map_string<'a>(
    map: &'a Map<String, Value>,
    label: &str,
    field: &str,
) -> Result<&'a str, CapabilityError> {
    map.get(field)
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| invalid(format!("{label}.{field} is required")))
}

fn is_broad_selector(selector: &str) -> bool {
    let trimmed = selector.trim();
    trimmed == "*"
        || trimmed == "kind:*"
        || trimmed == "resource:*"
        || trimmed == "kind:"
        || trimmed == "resource:"
        || trimmed.ends_with(":*")
}

pub(super) fn validate_capability_binding_request_resource_id(
    value: &str,
) -> Result<(), CapabilityError> {
    if !value.starts_with("capability_binding_request:") {
        return Err(invalid(
            "capabilityBindingRequestResourceId has unsupported resource kind",
        ));
    }
    bounded_provider_visible_token("capabilityBindingRequestResourceId", value, TOKEN_MAX_BYTES)
        .map(|_| ())
}

pub(super) fn validate_capability_binding_decision_resource_id(
    value: &str,
) -> Result<(), CapabilityError> {
    if !value.starts_with("capability_binding_decision:") {
        return Err(invalid(
            "capabilityBindingDecisionResourceId has unsupported resource kind",
        ));
    }
    bounded_provider_visible_token(
        "capabilityBindingDecisionResourceId",
        value,
        TOKEN_MAX_BYTES,
    )
    .map(|_| ())
}

pub(super) fn validate_capability_binding_policy_resource_id(
    value: &str,
) -> Result<(), CapabilityError> {
    if !value.starts_with("capability_binding_policy:") {
        return Err(invalid(
            "capabilityBindingPolicyResourceId has unsupported resource kind",
        ));
    }
    bounded_provider_visible_token("capabilityBindingPolicyResourceId", value, TOKEN_MAX_BYTES)
        .map(|_| ())
}

pub(super) fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}
