//! Module source-trust projection for control snapshots.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::{PrimitiveRuntimeHost, Result, current_payload};
use crate::engine::resources::{EngineResource, ListResources};

pub(super) fn module_source_trust_summary(
    host: &dyn PrimitiveRuntimeHost,
    resource: &EngineResource,
) -> Result<Option<Value>> {
    let Some(inspection) = host.inspect_resource(&resource.resource_id)? else {
        return Ok(None);
    };
    let Some(payload) = current_payload(&inspection) else {
        return Ok(None);
    };
    let package_digest = payload.get("packageDigest").and_then(Value::as_str);
    let source_registration_refs = source_registration_refs(host, &payload)?;
    let trust_root_refs = trust_root_refs(host, &payload)?;
    let source_approval_refs = source_approval_refs(
        host,
        &resource.resource_id,
        resource.current_version_id.as_deref(),
        package_digest,
    )?;
    let approval_warnings = source_approval_refs
        .iter()
        .filter_map(source_approval_warning)
        .collect::<Vec<_>>();
    let trust_warnings = trust_root_refs
        .iter()
        .filter_map(source_approval_warning)
        .collect::<Vec<_>>();
    let conformance_evidence_refs = payload
        .get("conformanceEvidenceRefs")
        .cloned()
        .unwrap_or_else(|| json!([]));
    let trust_presentation = module_trust_presentation(
        resource,
        &payload,
        &source_registration_refs,
        &trust_root_refs,
        &source_approval_refs,
        &approval_warnings,
        &trust_warnings,
        &conformance_evidence_refs,
    );
    Ok(Some(json!({
        "packageResourceId": resource.resource_id,
        "packageVersionId": resource.current_version_id,
        "packageId": payload.get("packageId").cloned().unwrap_or(Value::Null),
        "packageDigest": payload.get("packageDigest").cloned().unwrap_or(Value::Null),
        "sourceTrustStatus": payload.get("sourceTrustStatus").cloned().unwrap_or(Value::Null),
        "effectiveTrustTier": payload.get("effectiveTrustTier").cloned().unwrap_or(Value::Null),
        "signatureVerification": payload.get("signatureVerification").cloned().unwrap_or(Value::Null),
        "sourceEvidenceRefs": payload.get("sourceEvidenceRefs").cloned().unwrap_or_else(|| json!([])),
        "sourceRegistrationRefs": source_registration_refs,
        "trustRootRefs": trust_root_refs,
        "sourceApprovalRefs": source_approval_refs,
        "approvalWarnings": approval_warnings,
        "trustWarnings": trust_warnings,
        "conformanceEvidenceRefs": conformance_evidence_refs,
        "policyDiagnostics": payload.get("policyDiagnostics").cloned().unwrap_or_else(|| json!({})),
        "trustPresentation": trust_presentation,
    })))
}

fn module_trust_presentation(
    resource: &EngineResource,
    payload: &Value,
    source_registration_refs: &[Value],
    trust_root_refs: &[Value],
    source_approval_refs: &[Value],
    approval_warnings: &[Value],
    trust_warnings: &[Value],
    conformance_evidence_refs: &Value,
) -> Value {
    let source_status = payload
        .get("sourceTrustStatus")
        .and_then(Value::as_str)
        .unwrap_or("unverified");
    let signature_status = payload
        .get("signatureVerification")
        .and_then(|signature| signature.get("status"))
        .and_then(Value::as_str);
    let has_signature_key = payload
        .get("signatureKeyRef")
        .and_then(Value::as_str)
        .is_some();
    let source_evidence_count = ref_count(payload.get("sourceEvidenceRefs"));
    let conformance_count = ref_count(Some(conformance_evidence_refs));
    let source_verified = matches!(
        source_status,
        "verified" | "signature_verified" | "trusted_builtin"
    );
    let signature_verified = matches!(
        signature_status,
        Some("verified" | "signature_verified" | "trusted_builtin")
    ) || source_status == "signature_verified";
    let source_approval_revoked = warnings_contain(approval_warnings, "source_approval_revoked");
    let source_approval_expired = warnings_contain(approval_warnings, "source_approval_expired");
    let trust_root_revoked = warnings_contain(trust_warnings, "trust_root_revoked");
    let trust_root_expired = warnings_contain(trust_warnings, "trust_root_expired");
    let current_approval =
        !source_approval_refs.is_empty() && !source_approval_revoked && !source_approval_expired;
    let current_signature_trust = signature_verified
        && !trust_root_refs.is_empty()
        && !trust_root_revoked
        && !trust_root_expired;
    let removed = matches!(resource.lifecycle.as_str(), "discarded" | "removed")
        || payload.get("packageStatus").and_then(Value::as_str) == Some("removed");
    let has_revocation = source_approval_revoked || trust_root_revoked;
    let has_auth =
        current_approval || current_signature_trust || source_status == "trusted_builtin";
    let has_conformance = conformance_count > 0;

    let (status_label, status_tone, summary) = if removed {
        (
            "Removed",
            "neutral",
            "Pack was removed locally; history remains inspectable.",
        )
    } else if has_revocation {
        (
            "Trust revoked",
            "danger",
            "Trust was revoked; activate only after new approval or signature trust.",
        )
    } else if source_approval_expired || trust_root_expired {
        (
            "Trust expired",
            "warning",
            "Trust expired; renew approval or signature trust before activation.",
        )
    } else if source_verified && has_auth && has_conformance {
        (
            "Ready to activate",
            "success",
            "Source, approval, and conformance evidence are current.",
        )
    } else if source_verified && has_auth {
        (
            "Needs conformance",
            "warning",
            "Run conformance before activation.",
        )
    } else if source_verified {
        (
            "Needs approval",
            "warning",
            "Source evidence is present; approval or signature trust is still required.",
        )
    } else {
        (
            "Needs verification",
            "warning",
            "Verify local source evidence before activation.",
        )
    };

    json!({
        "statusLabel": status_label,
        "statusTone": status_tone,
        "summary": summary,
        "sourceLabel": source_label(source_status, source_evidence_count),
        "signatureLabel": signature_label(signature_status, has_signature_key),
        "approvalLabel": approval_label(
            current_approval,
            current_signature_trust,
            source_approval_revoked,
            source_approval_expired,
            source_approval_refs.len(),
        ),
        "conformanceLabel": if has_conformance {
            "Conformance passed"
        } else {
            "Conformance not run"
        },
        "revocationLabel": if has_revocation {
            "Revocation evidence present"
        } else {
            "No active revocation"
        },
        "promotionLabel": promotion_label(payload),
        "cleanupLabel": if removed {
            "Removed locally"
        } else {
            "Cleanup not needed"
        },
        "evidenceLabels": evidence_labels(
            source_evidence_count,
            source_registration_refs.len(),
            trust_root_refs.len(),
            source_approval_refs.len(),
            conformance_count,
        ),
        "warningLabels": warning_labels(approval_warnings, trust_warnings),
    })
}

fn ref_count(value: Option<&Value>) -> usize {
    value.and_then(Value::as_array).map(Vec::len).unwrap_or(0)
}

fn warnings_contain(warnings: &[Value], code: &str) -> bool {
    warnings
        .iter()
        .any(|warning| warning.get("code").and_then(Value::as_str) == Some(code))
}

fn source_label(source_status: &str, evidence_count: usize) -> &'static str {
    match source_status {
        "verified" | "signature_verified" | "trusted_builtin" if evidence_count > 0 => {
            "Source verified"
        }
        "trusted_builtin" => "Built-in source trusted",
        "verified" | "signature_verified" => "Source verified",
        "unverified" => "Source not verified",
        _ => "Source needs review",
    }
}

fn signature_label(signature_status: Option<&str>, has_signature_key: bool) -> &'static str {
    if !has_signature_key {
        return "Unsigned local pack";
    }
    match signature_status {
        Some("signature_verified" | "verified" | "trusted_builtin") => "Signature verified",
        Some("failed" | "invalid") => "Signature failed",
        Some(_) => "Signature needs review",
        None => "Unsigned local pack",
    }
}

fn approval_label(
    current_approval: bool,
    current_signature_trust: bool,
    revoked: bool,
    expired: bool,
    approval_count: usize,
) -> &'static str {
    if revoked {
        "Approval revoked"
    } else if expired {
        "Approval expired"
    } else if current_approval {
        "Approval active"
    } else if current_signature_trust {
        "Signature trust active"
    } else if approval_count > 0 {
        "Approval needs review"
    } else {
        "Approval required"
    }
}

fn promotion_label(payload: &Value) -> &'static str {
    let promotion_refs = ref_count(payload.get("promotionEvidenceRefs"));
    match payload.get("promotionStatus").and_then(Value::as_str) {
        Some("promoted") if promotion_refs > 0 => "Promotion evidence recorded",
        Some("promoted") => "Promoted",
        Some("revoked") => "Promotion revoked",
        _ => "No promotion evidence",
    }
}

fn evidence_labels(
    source_evidence_count: usize,
    source_registration_count: usize,
    trust_root_count: usize,
    approval_count: usize,
    conformance_count: usize,
) -> Vec<Value> {
    [
        ("Source evidence", source_evidence_count),
        ("Source registration", source_registration_count),
        ("Trust root", trust_root_count),
        ("Approval decision", approval_count),
        ("Conformance evidence", conformance_count),
    ]
    .into_iter()
    .filter(|(_, count)| *count > 0)
    .map(|(label, count)| json!(format!("{label} {count}")))
    .collect()
}

fn warning_labels(approval_warnings: &[Value], trust_warnings: &[Value]) -> Vec<Value> {
    approval_warnings
        .iter()
        .chain(trust_warnings.iter())
        .filter_map(|warning| warning.get("code").and_then(Value::as_str))
        .map(|code| {
            json!(match code {
                "source_approval_revoked" => "Approval revoked",
                "source_approval_expired" => "Approval expired",
                "trust_root_expired" => "Signature trust expired",
                "trust_root_revoked" => "Trust root revoked",
                _ => "Trust needs review",
            })
        })
        .collect()
}

fn source_registration_refs(
    host: &dyn PrimitiveRuntimeHost,
    package_payload: &Value,
) -> Result<Vec<Value>> {
    let package_digest = package_payload.get("packageDigest").and_then(Value::as_str);
    let package_id = package_payload.get("packageId").and_then(Value::as_str);
    let package_resource_id = package_id.map(|id| format!("worker-package:{id}"));
    if package_digest.is_none() {
        return Ok(Vec::new());
    }
    let decisions = host.list_resources(ListResources {
        kind: Some("decision".to_owned()),
        scope: None,
        lifecycle: None,
        limit: 500,
    })?;
    let mut refs = Vec::new();
    for resource in decisions {
        let Some(inspection) = host.inspect_resource(&resource.resource_id)? else {
            continue;
        };
        let Some(payload) = current_payload(&inspection) else {
            continue;
        };
        let Some(metadata) = payload.get("metadata").and_then(Value::as_object) else {
            continue;
        };
        if metadata.get("decisionType").and_then(Value::as_str)
            != Some("module_source_registration")
            || metadata.get("sourceDigest").and_then(Value::as_str) != package_digest
        {
            continue;
        }
        let selectors = metadata
            .get("allowedPackageSelectors")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let selector_matches = selectors.iter().any(|selector| {
            let Some(selector) = selector.as_str() else {
                return false;
            };
            selector == "*"
                || package_id.is_some_and(|id| selector == id)
                || package_resource_id.as_deref() == Some(selector)
        });
        if selector_matches {
            refs.push(decision_ref(
                host,
                &resource,
                payload,
                metadata,
                "source_registration",
            )?);
        }
    }
    Ok(refs)
}

fn trust_root_refs(host: &dyn PrimitiveRuntimeHost, package_payload: &Value) -> Result<Vec<Value>> {
    let Some(key_ref) = package_payload
        .get("signatureKeyRef")
        .and_then(Value::as_str)
        .and_then(|value| value.strip_prefix("trust-root:"))
    else {
        return Ok(Vec::new());
    };
    let decisions = host.list_resources(ListResources {
        kind: Some("decision".to_owned()),
        scope: None,
        lifecycle: None,
        limit: 500,
    })?;
    let mut refs = Vec::new();
    for resource in decisions {
        let Some(inspection) = host.inspect_resource(&resource.resource_id)? else {
            continue;
        };
        let Some(payload) = current_payload(&inspection) else {
            continue;
        };
        let Some(metadata) = payload.get("metadata").and_then(Value::as_object) else {
            continue;
        };
        if metadata.get("decisionType").and_then(Value::as_str) == Some("module_trust_root")
            && metadata.get("keyId").and_then(Value::as_str) == Some(key_ref)
        {
            refs.push(decision_ref(
                host,
                &resource,
                payload,
                metadata,
                "trust_root",
            )?);
        }
    }
    Ok(refs)
}

fn source_approval_refs(
    host: &dyn PrimitiveRuntimeHost,
    package_resource_id: &str,
    package_version_id: Option<&str>,
    package_digest: Option<&str>,
) -> Result<Vec<Value>> {
    let decisions = host.list_resources(ListResources {
        kind: Some("decision".to_owned()),
        scope: None,
        lifecycle: None,
        limit: 500,
    })?;
    decisions
        .into_iter()
        .filter_map(|resource| {
            source_approval_ref_for_decision(
                host,
                resource,
                package_resource_id,
                package_version_id,
                package_digest,
            )
            .transpose()
        })
        .collect()
}

fn source_approval_ref_for_decision(
    host: &dyn PrimitiveRuntimeHost,
    resource: EngineResource,
    package_resource_id: &str,
    package_version_id: Option<&str>,
    package_digest: Option<&str>,
) -> Result<Option<Value>> {
    let Some(inspection) = host.inspect_resource(&resource.resource_id)? else {
        return Ok(None);
    };
    let Some(payload) = current_payload(&inspection) else {
        return Ok(None);
    };
    let Some(metadata) = payload.get("metadata").and_then(Value::as_object) else {
        return Ok(None);
    };
    let target_matches = metadata.get("decisionType").and_then(Value::as_str)
        == Some("module_source_approval")
        && metadata.get("packageResourceId").and_then(Value::as_str) == Some(package_resource_id)
        && package_version_id.is_none_or(|version_id| {
            metadata.get("packageVersionId").and_then(Value::as_str) == Some(version_id)
        })
        && package_digest.is_none_or(|digest| {
            metadata.get("packageDigest").and_then(Value::as_str) == Some(digest)
        });
    if !target_matches {
        return Ok(None);
    }
    Ok(Some(json!({
        "resourceId": resource.resource_id,
        "versionId": resource.current_version_id,
        "status": payload.get("status").cloned().unwrap_or(Value::Null),
        "lifecycle": resource.lifecycle,
        "scope": metadata.get("scope").cloned().unwrap_or(Value::Null),
        "expiresAt": metadata.get("expiresAt").cloned().unwrap_or(Value::Null),
        "relation": "source_approval",
    })))
}

fn decision_ref(
    host: &dyn PrimitiveRuntimeHost,
    resource: &EngineResource,
    payload: &Value,
    metadata: &serde_json::Map<String, Value>,
    relation: &str,
) -> Result<Value> {
    Ok(json!({
        "resourceId": resource.resource_id,
        "versionId": resource.current_version_id,
        "status": payload.get("status").cloned().unwrap_or(Value::Null),
        "lifecycle": resource.lifecycle,
        "scope": metadata.get("scope").cloned().unwrap_or(Value::Null),
        "expiresAt": metadata.get("expiresAt").cloned().unwrap_or(Value::Null),
        "relation": relation,
        "revoked": decision_is_revoked(host, &resource.resource_id)?,
    }))
}

fn decision_is_revoked(
    host: &dyn PrimitiveRuntimeHost,
    decision_resource_id: &str,
) -> Result<bool> {
    let decisions = host.list_resources(ListResources {
        kind: Some("decision".to_owned()),
        scope: None,
        lifecycle: None,
        limit: 500,
    })?;
    for resource in decisions {
        let Some(inspection) = host.inspect_resource(&resource.resource_id)? else {
            continue;
        };
        let Some(payload) = current_payload(&inspection) else {
            continue;
        };
        let Some(metadata) = payload.get("metadata").and_then(Value::as_object) else {
            continue;
        };
        if metadata.get("decisionType").and_then(Value::as_str) == Some("module_source_revocation")
            && metadata
                .get("revokedDecisionResourceId")
                .and_then(Value::as_str)
                == Some(decision_resource_id)
        {
            return Ok(true);
        }
    }
    Ok(false)
}

fn source_approval_warning(reference: &Value) -> Option<Value> {
    let status = reference.get("status").and_then(Value::as_str);
    let lifecycle = reference.get("lifecycle").and_then(Value::as_str);
    let expired_code = if reference.get("relation").and_then(Value::as_str) == Some("trust_root") {
        "trust_root_expired"
    } else {
        "source_approval_expired"
    };
    let expires_at = reference
        .get("expiresAt")
        .and_then(Value::as_str)
        .and_then(|value| DateTime::parse_from_rfc3339(value).ok())
        .map(|value| value.with_timezone(&Utc));
    if status == Some("expired") || expires_at.is_some_and(|value| value <= Utc::now()) {
        return Some(json!({
            "code": expired_code,
            "decisionResourceId": reference.get("resourceId").cloned().unwrap_or(Value::Null),
        }));
    }
    if status == Some("revoked")
        || lifecycle == Some("archived")
        || reference
            .get("revoked")
            .and_then(Value::as_bool)
            .unwrap_or(false)
    {
        return Some(json!({
            "code": if reference.get("relation").and_then(Value::as_str) == Some("trust_root") {
                "trust_root_revoked"
            } else {
                "source_approval_revoked"
            },
            "decisionResourceId": reference.get("resourceId").cloned().unwrap_or(Value::Null),
        }));
    }
    None
}
