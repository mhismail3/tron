//! Package source and signature verification operations.

use ed25519_dalek::{Signature, Verifier};

use super::support::*;
use super::*;

impl ModulePrimitiveHandler {
    pub(in crate::engine::primitives::module) fn verify_signature(
        &self,
        invocation: &Invocation,
    ) -> Result<Value> {
        let package_resource_id = required_string_owned(&invocation.payload, "packageResourceId")?;
        let package_version_id = required_string_owned(&invocation.payload, "packageVersionId")?;
        let package = require_inspection(self, &package_resource_id, WORKER_PACKAGE_KIND)?;
        if let Some(expected) = optional_string(invocation.payload.get("expectedCurrentVersionId"))?
        {
            ensure_expected_current_version(&package, &expected)?;
        }
        ensure_version_is_current(&package, &package_version_id)?;
        let mut manifest = version_payload(&package, &package_version_id)?;
        if source_kind(&manifest)? != LOCAL_DIGEST_PINNED {
            return Err(EngineError::PolicyViolation(
                "module::verify_signature only supports local_digest_pinned packages".to_owned(),
            ));
        }
        validate_manifest_signature_inputs(&manifest, |reference| {
            self.verify_materialized_ref(reference)
        })?;
        let key_ref = required_value_str(&manifest, "signatureKeyRef")?;
        let key_id = key_ref.strip_prefix(TRUST_ROOT_PREFIX).ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "signatureKeyRef must start with {TRUST_ROOT_PREFIX}"
            ))
        })?;
        let (_, scope_token) = resource_scope_and_token(invocation)?;
        let trust_root =
            self.active_trust_root(key_id, &manifest, &package_resource_id, &scope_token, None)?;
        let signature_bytes = signature_bytes_from_manifest(&manifest)?;
        let public_key_bytes = decode_base64_prefixed(&trust_root.public_key, "publicKey")?;
        let verifying_key = verifying_key_from_bytes(&public_key_bytes)?;
        let signature = Signature::from_slice(&signature_bytes).map_err(|error| {
            EngineError::PolicyViolation(format!("invalid ed25519 signature bytes: {error}"))
        })?;
        let package_digest = required_value_str(&manifest, "packageDigest")?.to_owned();
        verifying_key
            .verify(
                signed_package_message(&package_digest).as_bytes(),
                &signature,
            )
            .map_err(|error| {
                EngineError::PolicyViolation(format!(
                    "package signature verification failed: {error}"
                ))
            })?;
        let evidence = self.create_evidence_resource(
            invocation,
            &format!("module package {package_resource_id} signature verified"),
            VERIFY_SIGNATURE_FUNCTION,
            &package_resource_id,
            json!({
                "evidenceType": "signature_verification",
                "packageVersionId": package_version_id,
                "packageDigest": package_digest,
                "algorithm": "ed25519",
                "keyId": trust_root.key_id,
                "trustRootDecisionResourceId": trust_root.decision_resource_id,
                "trustRootDecisionVersionId": trust_root.decision_version_id,
                "expiresAt": trust_root.expires_at.to_rfc3339(),
                "verifiedAt": Utc::now().to_rfc3339(),
            }),
        )?;
        manifest["sourceDigest"] = json!(package_digest);
        manifest["sourceTrustStatus"] = json!(SOURCE_STATUS_SIGNATURE_VERIFIED);
        manifest["effectiveTrustTier"] = json!(SIGNED_LOCAL_TRUST);
        manifest["signatureVerification"] = json!({
            "status": "verified",
            "method": "ed25519",
            "keyId": trust_root.key_id,
            "trustRootDecisionResourceId": trust_root.decision_resource_id,
            "trustRootDecisionVersionId": trust_root.decision_version_id,
            "evidenceRef": evidence.reference,
        });
        manifest["sourceEvidenceRefs"] = append_value_array(
            manifest.get("sourceEvidenceRefs"),
            evidence.reference.clone(),
        );
        if !manifest
            .get("policyDiagnostics")
            .is_some_and(Value::is_object)
        {
            manifest["policyDiagnostics"] = json!({});
        }
        manifest["policyDiagnostics"]["source"] = json!({
            "status": SOURCE_STATUS_SIGNATURE_VERIFIED,
            "checkedAt": Utc::now().to_rfc3339(),
            "evidenceRef": evidence.reference,
        });
        let version = self.update_resource(UpdateResource {
            resource_id: package_resource_id.clone(),
            expected_current_version_id: Some(package_version_id),
            lifecycle: Some(package.resource.lifecycle.clone()),
            payload: manifest.clone(),
            state: None,
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })?;
        Ok(json!({
            "signatureVerification": manifest["signatureVerification"],
            "resource": package.resource,
            "version": version,
            "evidence": evidence.resource,
            "resourceRefs": [
                evidence.reference,
                resource_ref_from_version(&version, WORKER_PACKAGE_KIND, "signature_verified")
            ],
        }))
    }
    pub(in crate::engine::primitives::module) fn verify_source(
        &self,
        invocation: &Invocation,
    ) -> Result<Value> {
        let package_resource_id = required_string_owned(&invocation.payload, "packageResourceId")?;
        let package_version_id = required_string_owned(&invocation.payload, "packageVersionId")?;
        let mode = optional_string(invocation.payload.get("mode"))?
            .unwrap_or_else(|| "on_demand".to_owned());
        if !matches!(mode.as_str(), "on_demand" | "scheduled" | "registration") {
            return Err(EngineError::PolicyViolation(format!(
                "unsupported module source verification mode {mode}"
            )));
        }
        let package = require_inspection(self, &package_resource_id, WORKER_PACKAGE_KIND)?;
        if let Some(expected) = optional_string(invocation.payload.get("expectedCurrentVersionId"))?
        {
            ensure_expected_current_version(&package, &expected)?;
        }
        let current = current_version(&package).ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "worker_package {package_resource_id} has no current version"
            ))
        })?;
        if current.version_id != package_version_id {
            return Err(EngineError::PolicyViolation(format!(
                "packageVersionId {package_version_id} is not current package version {}",
                current.version_id
            )));
        }
        let mut manifest = current.payload.clone();
        let verification = source_verification(&manifest, |reference| {
            self.verify_materialized_ref(reference)
        })?;
        if !verification.findings.is_empty() {
            return Err(EngineError::PolicyViolation(format!(
                "source verification failed: {}",
                verification
                    .findings
                    .iter()
                    .filter_map(|finding| finding.get("code").and_then(Value::as_str))
                    .collect::<Vec<_>>()
                    .join(", ")
            )));
        }
        let evidence = self.create_evidence_resource(
            invocation,
            &format!("module package {package_resource_id} source verified"),
            VERIFY_SOURCE_FUNCTION,
            &package_resource_id,
            json!({
                "mode": mode,
                "packageVersionId": package_version_id,
                "packageDigest": verification.package_digest,
                "sourceKind": verification.source_kind,
                "effectiveTrustTier": verification.effective_trust_tier,
                "signatureVerification": verification.signature_verification,
                "verifiedAt": verification.checked_at,
            }),
        )?;
        manifest["sourceDigest"] = json!(verification.package_digest);
        manifest["sourceTrustStatus"] = json!(SOURCE_STATUS_VERIFIED);
        manifest["effectiveTrustTier"] = json!(verification.effective_trust_tier);
        manifest["signatureVerification"] = verification.signature_verification.clone();
        manifest["sourceEvidenceRefs"] = append_value_array(
            manifest.get("sourceEvidenceRefs"),
            evidence.reference.clone(),
        );
        if !manifest
            .get("policyDiagnostics")
            .is_some_and(Value::is_object)
        {
            manifest["policyDiagnostics"] = json!({});
        }
        manifest["policyDiagnostics"]["source"] = json!({
            "status": SOURCE_STATUS_VERIFIED,
            "checkedAt": verification.checked_at,
            "evidenceRef": evidence.reference,
        });
        let version = self.update_resource(UpdateResource {
            resource_id: package_resource_id.clone(),
            expected_current_version_id: Some(package_version_id),
            lifecycle: Some(package.resource.lifecycle.clone()),
            payload: manifest.clone(),
            state: None,
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })?;
        let package_ref =
            resource_ref_from_version(&version, WORKER_PACKAGE_KIND, "source_verified");
        Ok(json!({
            "sourceVerification": {
                "status": SOURCE_STATUS_VERIFIED,
                "packageDigest": manifest["sourceDigest"],
                "effectiveTrustTier": manifest["effectiveTrustTier"],
                "evidenceRef": evidence.reference,
            },
            "resource": package.resource,
            "version": version,
            "evidence": evidence.resource,
            "resourceRefs": [evidence.reference, package_ref],
        }))
    }
}
