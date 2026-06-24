//! Deterministic grant policy hashing for scoped runtime tokens.

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

#[cfg(test)]
use super::model::TEST_BOOTSTRAP_GRANT_IDS;
use super::model::{BOOTSTRAP_GRANT_IDS, EngineGrant, EngineGrantLifecycle, bootstrap_grant};
use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::ids::AuthorityGrantId;
use crate::engine::kernel::types::RiskLevel;

/// Hash the authority-relevant fields of an active grant.
///
/// List fields are treated as sets by the grant policy model, so they are
/// sorted before canonical JSON serialization.
#[must_use]
pub(crate) fn grant_policy_hash(grant: &EngineGrant) -> String {
    let policy = json!({
        "version": 1,
        "grantId": grant.grant_id.as_str(),
        "parentGrantId": grant.parent_grant_id.as_ref().map(AuthorityGrantId::as_str),
        "subjectActorId": grant.subject_actor_id.as_ref().map(crate::engine::ActorId::as_str),
        "subjectWorkerId": grant.subject_worker_id.as_ref().map(crate::engine::WorkerId::as_str),
        "subjectInvocationId": grant.subject_invocation_id.as_ref().map(crate::engine::InvocationId::as_str),
        "lifecycle": lifecycle_as_str(&grant.lifecycle),
        "allowedCapabilities": sorted_strings(&grant.allowed_capabilities),
        "allowedNamespaces": sorted_strings(&grant.allowed_namespaces),
        "allowedAuthorityScopes": sorted_strings(&grant.allowed_authority_scopes),
        "allowedResourceKinds": sorted_strings(&grant.allowed_resource_kinds),
        "resourceSelectors": sorted_strings(&grant.resource_selectors),
        "fileRoots": sorted_strings(&grant.file_roots),
        "networkPolicy": grant.network_policy,
        "maxRisk": risk_as_str(grant.max_risk),
        "budget": grant.budget,
        "expiresAt": grant.expires_at.map(|value| value.to_rfc3339()),
        "canDelegate": grant.can_delegate,
        "revision": grant.revision,
    });
    let mut canonical = String::new();
    write_canonical_json(&policy, &mut canonical);
    hex::encode(Sha256::digest(canonical.as_bytes()))
}

/// Compute the policy hash for a first-party bootstrap grant id.
pub(crate) fn bootstrap_grant_policy_hash(grant_id: &AuthorityGrantId) -> Result<String> {
    if !BOOTSTRAP_GRANT_IDS
        .iter()
        .any(|candidate| *candidate == grant_id.as_str())
        && !test_bootstrap_grant_ids()
            .iter()
            .any(|candidate| *candidate == grant_id.as_str())
    {
        return Err(EngineError::PolicyViolation(format!(
            "authority grant {} is not a bootstrap grant",
            grant_id
        )));
    }
    Ok(grant_policy_hash(&bootstrap_grant(grant_id.as_str())))
}

fn test_bootstrap_grant_ids() -> &'static [&'static str] {
    #[cfg(test)]
    {
        TEST_BOOTSTRAP_GRANT_IDS
    }
    #[cfg(not(test))]
    {
        &[]
    }
}

fn sorted_strings(values: &[String]) -> Vec<String> {
    let mut values = values.to_vec();
    values.sort();
    values
}

fn lifecycle_as_str(lifecycle: &EngineGrantLifecycle) -> &'static str {
    match lifecycle {
        EngineGrantLifecycle::Active => "active",
        EngineGrantLifecycle::Revoked => "revoked",
    }
}

fn risk_as_str(risk: RiskLevel) -> &'static str {
    match risk {
        RiskLevel::Low => "low",
        RiskLevel::Medium => "medium",
        RiskLevel::High => "high",
        RiskLevel::Critical => "critical",
    }
}

fn write_canonical_json(value: &Value, out: &mut String) {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(value) => out.push_str(if *value { "true" } else { "false" }),
        Value::Number(value) => out.push_str(&value.to_string()),
        Value::String(value) => {
            let encoded = serde_json::to_string(value).expect("string serialization cannot fail");
            out.push_str(&encoded);
        }
        Value::Array(values) => {
            out.push('[');
            for (index, value) in values.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_canonical_json(value, out);
            }
            out.push(']');
        }
        Value::Object(values) => {
            out.push('{');
            let mut keys = values.keys().collect::<Vec<_>>();
            keys.sort();
            for (index, key) in keys.into_iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                let encoded = serde_json::to_string(key).expect("string serialization cannot fail");
                out.push_str(&encoded);
                out.push(':');
                write_canonical_json(
                    values.get(key).expect("key was collected from this object"),
                    out,
                );
            }
            out.push('}');
        }
    }
}
