//! Retention policy evidence and denial rules.
//!
//! Memory record lifecycle writes stay explicit: retain/edit/import/tombstone
//! record policy proof, while hard-delete/body-erasure and automatic retention
//! requests fail closed.

use serde_json::{Value, json};

use super::errors::invalid_params;
use super::query_decision_validation::validate_bounded_metadata;
use super::service::ResolvedPolicy;
use crate::shared::server::errors::CapabilityError;

pub(super) fn ensure_retention_policy_supported(
    retention: &Value,
    operation: &str,
) -> Result<(), CapabilityError> {
    validate_bounded_metadata(retention, "retention", 0)?;
    let action = retention.get("action").and_then(Value::as_str);
    if matches!(
        action,
        Some("delete" | "hard_delete" | "erase" | "purge" | "body_delete")
    ) || retention
        .get("hardDelete")
        .and_then(Value::as_bool)
        .unwrap_or(false)
        || retention
            .get("eraseBody")
            .and_then(Value::as_bool)
            .unwrap_or(false)
    {
        return Err(invalid_params(format!(
            "memory {operation} does not support hard delete or body erasure; use explicit tombstone audit"
        )));
    }
    if retention
        .get("automatic")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        return Err(invalid_params(format!(
            "memory {operation} does not support automatic retention without explicit policy evidence"
        )));
    }
    Ok(())
}

pub(super) fn retention_policy_evidence(policy: &ResolvedPolicy, action: &str) -> Value {
    json!({
        "action": action,
        "policyResourceId": policy.resource_id.clone(),
        "policyVersionId": policy.version_id.clone(),
        "policyScope": policy.scope.clone(),
        "mode": policy.record.mode.as_str(),
        "policyRevision": policy.record.revision,
        "automaticRetentionPerformed": false,
        "hardDeletePerformed": false,
        "bodyErasurePerformed": false,
        "supportedDeleteMode": "tombstone_only",
        "networkPolicy": "none"
    })
}
