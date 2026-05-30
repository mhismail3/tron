//! Shared source trust model and helper functions.

use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64_STANDARD};
use ed25519_dalek::VerifyingKey;

use super::*;

pub(super) struct SourcePolicyEvaluation {
    pub(super) decision: &'static str,
    pub(super) reasons: Vec<String>,
    pub(super) missing_prerequisites: Vec<String>,
    pub(super) source_trust: Value,
    pub(super) approval: Value,
    pub(super) conformance: Value,
}
pub(super) struct SourceVerification {
    pub(super) source_kind: String,
    pub(super) package_digest: String,
    pub(super) effective_trust_tier: String,
    pub(super) signature_verification: Value,
    pub(super) findings: Vec<Value>,
    pub(super) checked_at: String,
}
pub(super) struct ActiveTrustRoot {
    pub(super) decision_resource_id: String,
    pub(super) decision_version_id: Option<String>,
    pub(super) key_id: String,
    pub(super) public_key: String,
    pub(super) expires_at: DateTime<Utc>,
}

pub(super) fn signature_key_id(manifest: &Value) -> Result<String> {
    let key_ref = required_value_str(manifest, "signatureKeyRef")?;
    key_ref
        .strip_prefix(TRUST_ROOT_PREFIX)
        .map(ToOwned::to_owned)
        .ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "signatureKeyRef must start with {TRUST_ROOT_PREFIX}"
            ))
        })
}
pub(super) fn validate_manifest_signature_inputs<F>(
    manifest: &Value,
    mut verify_ref: F,
) -> Result<()>
where
    F: FnMut(&ResourceVersionRef) -> Result<()>,
{
    validate_manifest(manifest)?;
    if source_kind(manifest)? != LOCAL_DIGEST_PINNED {
        return Err(EngineError::PolicyViolation(
            "signed packages must use local_digest_pinned provenance".to_owned(),
        ));
    }
    let package_digest = required_value_str(manifest, "packageDigest")?;
    let computed = manifest_digest(manifest)?;
    if package_digest != computed {
        return Err(EngineError::PolicyViolation(format!(
            "packageDigest mismatch: expected {computed}, got {package_digest}"
        )));
    }
    if manifest
        .get("sourceDigest")
        .and_then(Value::as_str)
        .is_some_and(|value| value != package_digest)
    {
        return Err(EngineError::PolicyViolation(
            "sourceDigest does not match packageDigest".to_owned(),
        ));
    }
    for reference in resource_version_refs(manifest.get("declaredFiles"), "declaredFiles")? {
        verify_ref(&reference)?;
    }
    let signature = required_object(manifest.get("signature"), "signature")?;
    if required_map_str(signature, "algorithm")? != "ed25519" {
        return Err(EngineError::PolicyViolation(
            "only ed25519 package signatures are supported".to_owned(),
        ));
    }
    let signature_bytes = signature_bytes_from_manifest(manifest)?;
    if signature_bytes.len() != 64 {
        return Err(EngineError::PolicyViolation(
            "ed25519 signature must be 64 bytes".to_owned(),
        ));
    }
    let _ = signature_key_id(manifest)?;
    reject_raw_secrets(manifest)?;
    Ok(())
}
pub(super) fn signature_bytes_from_manifest(manifest: &Value) -> Result<Vec<u8>> {
    let signature = required_object(manifest.get("signature"), "signature")?;
    let value = required_map_str(signature, "value")?;
    decode_base64_prefixed(value, "signature.value")
}
pub(super) fn signed_package_message(package_digest: &str) -> String {
    format!("{MANIFEST_SCHEMA_ID}\n{package_digest}")
}
pub(super) fn decode_base64_prefixed(value: &str, field: &str) -> Result<Vec<u8>> {
    let encoded = value.strip_prefix("base64:").unwrap_or(value);
    BASE64_STANDARD.decode(encoded).map_err(|error| {
        EngineError::PolicyViolation(format!("{field} must be base64 encoded: {error}"))
    })
}
pub(super) fn verifying_key_from_bytes(bytes: &[u8]) -> Result<VerifyingKey> {
    let key_bytes: [u8; 32] = bytes.try_into().map_err(|_| {
        EngineError::PolicyViolation("ed25519 publicKey must decode to 32 bytes".to_owned())
    })?;
    VerifyingKey::from_bytes(&key_bytes).map_err(|error| {
        EngineError::PolicyViolation(format!("invalid ed25519 publicKey: {error}"))
    })
}
pub(super) fn key_id_for_public_key(bytes: &[u8]) -> String {
    format!("ed25519:{:x}", Sha256::digest(bytes))
}
pub(super) fn trust_root_ref(key_id: &str) -> String {
    format!("{TRUST_ROOT_PREFIX}{key_id}")
}
pub(super) fn source_verification<F>(
    manifest: &Value,
    mut verify_ref: F,
) -> Result<SourceVerification>
where
    F: FnMut(&ResourceVersionRef) -> Result<()>,
{
    let checked_at = Utc::now().to_rfc3339();
    let mut findings = Vec::new();
    if let Err(error) = validate_manifest(manifest) {
        findings.push(json!({"code": "manifest_invalid", "message": error.to_string()}));
    }
    let package_digest = required_value_str(manifest, "packageDigest")?.to_owned();
    let computed = manifest_digest(manifest)?;
    if package_digest != computed {
        findings.push(json!({
            "code": "package_digest_mismatch",
            "expected": computed,
            "actual": package_digest,
        }));
    }
    let kind = source_kind(manifest)?;
    if manifest
        .get("sourceDigest")
        .and_then(Value::as_str)
        .is_some_and(|value| value != package_digest)
    {
        findings.push(json!({"code": "source_digest_mismatch"}));
    }
    match kind.as_str() {
        BUILTIN_PROVENANCE => {
            if required_value_str(manifest, "signatureStatus")? != SOURCE_STATUS_TRUSTED_BUILTIN {
                findings.push(json!({"code": "builtin_signature_untrusted"}));
            }
        }
        LOCAL_DIGEST_PINNED => {
            match resource_version_refs(manifest.get("declaredFiles"), "declaredFiles") {
                Ok(refs) => {
                    for reference in refs {
                        if let Err(error) = verify_ref(&reference) {
                            findings.push(json!({
                                "code": "declared_file_invalid",
                                "resourceId": reference.resource_id,
                                "versionId": reference.version_id,
                                "message": error.to_string(),
                            }));
                        }
                    }
                }
                Err(error) => {
                    findings.push(
                        json!({"code": "declared_files_invalid", "message": error.to_string()}),
                    );
                }
            }
        }
        other => findings.push(json!({"code": "unsupported_source_kind", "kind": other})),
    }
    if manifest
        .get("signature")
        .is_some_and(|value| !value.is_null())
        || manifest
            .get("signatureKeyRef")
            .is_some_and(|value| !value.is_null())
    {
        findings.push(json!({"code": "signature_verification_unsupported"}));
    }
    if let Err(error) = reject_raw_secrets(manifest) {
        findings.push(json!({"code": "raw_secret", "message": error.to_string()}));
    }
    let effective_trust_tier = match kind.as_str() {
        BUILTIN_PROVENANCE => BUILTIN_PROVENANCE,
        LOCAL_DIGEST_PINNED => LOCAL_DIGEST_PINNED,
        _ => "untrusted",
    }
    .to_owned();
    Ok(SourceVerification {
        source_kind: kind,
        package_digest,
        effective_trust_tier,
        signature_verification: json!({
            "status": if findings.is_empty() { "verified" } else { "invalid" },
            "method": "local_digest",
        }),
        findings,
        checked_at,
    })
}
pub(super) fn policy_evaluation_value(evaluation: SourcePolicyEvaluation) -> Value {
    json!({
        "decision": evaluation.decision,
        "reasons": evaluation.reasons,
        "missingPrerequisites": evaluation.missing_prerequisites,
        "sourceTrust": evaluation.source_trust,
        "approval": evaluation.approval,
        "conformance": evaluation.conformance,
    })
}
pub(super) fn policy_child_request(
    invocation: &Invocation,
    manifest: &Value,
) -> Result<Option<DeriveGrant>> {
    invocation
        .payload
        .get("childGrantRequest")
        .and_then(Value::as_object)
        .map(|request| {
            let worker_id = manifest
                .get("runtimeEntryPoint")
                .and_then(|entry| entry.get("workerId"))
                .and_then(Value::as_str)
                .ok_or_else(|| {
                    EngineError::PolicyViolation(
                        "policy audit requires runtimeEntryPoint.workerId".to_owned(),
                    )
                })?;
            child_grant_from_payload(
                invocation,
                manifest,
                &WorkerId::new(worker_id.to_owned())?,
                request,
            )
        })
        .transpose()
}
pub(super) fn recommended_actions_for_policy(
    decision: &str,
    affected_activations: &[Value],
) -> Vec<Value> {
    let mut actions = vec![json!({
        "functionId": AUDIT_POLICY_FUNCTION,
        "reason": "refresh policy audit",
    })];
    if decision != "allow" {
        actions.push(json!({
            "functionId": RECORD_POLICY_AUDIT_FUNCTION,
            "reason": "persist audit evidence",
        }));
        actions.push(json!({
            "functionId": RECONCILE_TRUST_FUNCTION,
            "reason": "record affected package and activation state",
        }));
    }
    if !affected_activations.is_empty() && decision != "allow" {
        actions.push(json!({
            "functionId": QUARANTINE_FUNCTION,
            "reason": "operator may quarantine affected activation explicitly",
        }));
        actions.push(json!({
            "functionId": DISABLE_FUNCTION,
            "reason": "operator may disable affected activation explicitly",
        }));
    }
    actions
}
