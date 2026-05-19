//! Module source trust, policy, signature, and revocation operations.
//!
//! Package source decisions, local trust roots, signature verification, policy
//! audits, trust inspection, renewal/rotation, reconciliation, and explicit
//! revocation enforcement all stay resource-backed. This submodule owns those
//! operator trust paths without introducing package, policy, trust, or audit
//! tables.

use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64_STANDARD};
use ed25519_dalek::{Signature, Verifier, VerifyingKey};

use super::*;

struct SourcePolicyEvaluation {
    decision: &'static str,
    reasons: Vec<String>,
    missing_prerequisites: Vec<String>,
    source_trust: Value,
    approval: Value,
    conformance: Value,
}
struct SourceVerification {
    source_kind: String,
    package_digest: String,
    effective_trust_tier: String,
    signature_verification: Value,
    findings: Vec<Value>,
    checked_at: String,
}
struct ActiveTrustRoot {
    decision_resource_id: String,
    decision_version_id: Option<String>,
    key_id: String,
    public_key: String,
    expires_at: DateTime<Utc>,
}

impl ModulePrimitiveHandler {
    pub(super) fn register_source(&self, invocation: &Invocation) -> Result<Value> {
        let source_kind = required_string_owned(&invocation.payload, "sourceKind")?;
        let (scope, scope_token) = resource_scope_and_token(invocation)?;
        let reason = required_string_owned(&invocation.payload, "reason")?;
        reject_raw_secrets(&json!({"reason": reason}))?;
        match source_kind.as_str() {
            "ed25519_trust_root" => {
                self.register_ed25519_trust_root(invocation, scope, &scope_token, &reason)
            }
            "local_digest_source" => {
                self.register_local_digest_source(invocation, scope, &scope_token, &reason)
            }
            "source_revocation" => {
                self.register_source_revocation(invocation, scope, &scope_token, &reason)
            }
            other => Err(EngineError::PolicyViolation(format!(
                "unsupported module sourceKind {other}"
            ))),
        }
    }
    pub(super) fn register_ed25519_trust_root(
        &self,
        invocation: &Invocation,
        scope: EngineResourceScope,
        scope_token: &str,
        reason: &str,
    ) -> Result<Value> {
        let algorithm = optional_string(invocation.payload.get("algorithm"))?
            .unwrap_or_else(|| "ed25519".to_owned());
        if algorithm != "ed25519" {
            return Err(EngineError::PolicyViolation(format!(
                "unsupported trust-root algorithm {algorithm}"
            )));
        }
        let public_key = required_string_owned(&invocation.payload, "publicKey")?;
        let public_key_bytes = decode_base64_prefixed(&public_key, "publicKey")?;
        let _ = verifying_key_from_bytes(&public_key_bytes)?;
        let key_id = key_id_for_public_key(&public_key_bytes);
        if let Some(requested) = optional_string(invocation.payload.get("keyId"))?
            && requested != key_id
        {
            return Err(EngineError::PolicyViolation(format!(
                "trust-root keyId {requested} does not match derived {key_id}"
            )));
        }
        let expires_at = parse_datetime(required_value_str(&invocation.payload, "expiresAt")?)?;
        if expires_at <= Utc::now() {
            return Err(EngineError::PolicyViolation(
                "trust-root expiresAt must be in the future".to_owned(),
            ));
        }
        let trust_tier_ceiling = optional_string(invocation.payload.get("trustTierCeiling"))?
            .unwrap_or_else(|| SIGNED_LOCAL_TRUST.to_owned());
        if trust_tier_ceiling != SIGNED_LOCAL_TRUST {
            return Err(EngineError::PolicyViolation(format!(
                "trust-root trustTierCeiling {trust_tier_ceiling} exceeds {SIGNED_LOCAL_TRUST}"
            )));
        }
        let selectors = string_array_from(
            invocation.payload.get("allowedPackageSelectors"),
            "allowedPackageSelectors",
        )?;
        if selectors.is_empty() {
            return Err(EngineError::PolicyViolation(
                "trust-root allowedPackageSelectors must not be empty".to_owned(),
            ));
        }
        let grant_ceiling =
            required_object(invocation.payload.get("grantCeiling"), "grantCeiling")?;
        ensure_grant_ceiling_narrows_caller(self, invocation, grant_ceiling)?;
        let payload = json!({
            "status": "active",
            "summary": format!("Registered Ed25519 trust root {}", trust_root_ref(&key_id)),
            "metadata": {
                "decisionType": "module_trust_root",
                "algorithm": "ed25519",
                "keyId": key_id,
                "trustRootRef": trust_root_ref(&key_id),
                "publicKey": public_key,
                "publicKeyEncoding": "base64",
                "scope": scope_token,
                "allowedPackageSelectors": selectors,
                "trustTierCeiling": trust_tier_ceiling,
                "grantCeiling": grant_ceiling,
                "expiresAt": expires_at.to_rfc3339(),
                "operatorActor": invocation.causal_context.actor_id.as_str(),
                "reason": reason,
                "registeredAt": Utc::now().to_rfc3339(),
            }
        });
        let decision = self.create_decision_resource(
            invocation,
            payload.clone(),
            Some(scope),
            &trust_root_ref(payload["metadata"]["keyId"].as_str().unwrap_or_default()),
            "trusts_source",
        )?;
        let evidence = self.create_evidence_resource(
            invocation,
            "module trust root registered",
            REGISTER_SOURCE_FUNCTION,
            &decision.resource.resource_id,
            json!({
                "evidenceType": "source_registration",
                "decisionType": "module_trust_root",
                "keyId": payload["metadata"]["keyId"],
                "scope": scope_token,
                "registeredAt": payload["metadata"]["registeredAt"],
            }),
        )?;
        Ok(json!({
            "decision": payload,
            "resource": decision.resource,
            "evidence": evidence.resource,
            "trustRoot": payload["metadata"],
            "resourceRefs": [decision.reference, evidence.reference],
        }))
    }
    pub(super) fn register_local_digest_source(
        &self,
        invocation: &Invocation,
        scope: EngineResourceScope,
        scope_token: &str,
        reason: &str,
    ) -> Result<Value> {
        let source_digest = required_string_owned(&invocation.payload, "sourceDigest")?;
        if !source_digest.starts_with("sha256:") {
            return Err(EngineError::PolicyViolation(
                "local sourceDigest must be sha256-prefixed".to_owned(),
            ));
        }
        let source_ref = required_object(invocation.payload.get("sourceRef"), "sourceRef")?;
        reject_raw_secrets(&Value::Object(source_ref.clone()))?;
        let selectors = string_array_from(
            invocation.payload.get("allowedPackageSelectors"),
            "allowedPackageSelectors",
        )?;
        if selectors.is_empty() {
            return Err(EngineError::PolicyViolation(
                "local source allowedPackageSelectors must not be empty".to_owned(),
            ));
        }
        let expires_at = parse_datetime(required_value_str(&invocation.payload, "expiresAt")?)?;
        if expires_at <= Utc::now() {
            return Err(EngineError::PolicyViolation(
                "local source expiresAt must be in the future".to_owned(),
            ));
        }
        if let Some(grant_ceiling) = invocation
            .payload
            .get("grantCeiling")
            .and_then(Value::as_object)
        {
            ensure_grant_ceiling_narrows_caller(self, invocation, grant_ceiling)?;
        }
        let payload = json!({
            "status": "active",
            "summary": format!("Registered local package source {source_digest}"),
            "metadata": {
                "decisionType": "module_source_registration",
                "sourceKind": "local_digest_source",
                "sourceDigest": source_digest,
                "sourceRef": source_ref,
                "scope": scope_token,
                "allowedPackageSelectors": selectors,
                "grantCeiling": invocation.payload.get("grantCeiling").cloned().unwrap_or(Value::Null),
                "expiresAt": expires_at.to_rfc3339(),
                "operatorActor": invocation.causal_context.actor_id.as_str(),
                "reason": reason,
                "registeredAt": Utc::now().to_rfc3339(),
            }
        });
        let decision = self.create_decision_resource(
            invocation,
            payload.clone(),
            Some(scope),
            &format!("source:{source_digest}"),
            "trusts_source",
        )?;
        let evidence = self.create_evidence_resource(
            invocation,
            "module local source registered",
            REGISTER_SOURCE_FUNCTION,
            &decision.resource.resource_id,
            json!({
                "evidenceType": "source_registration",
                "decisionType": "module_source_registration",
                "sourceDigest": source_digest,
                "scope": scope_token,
                "registeredAt": payload["metadata"]["registeredAt"],
            }),
        )?;
        Ok(json!({
            "decision": payload,
            "resource": decision.resource,
            "evidence": evidence.resource,
            "resourceRefs": [decision.reference, evidence.reference],
        }))
    }
    pub(super) fn register_source_revocation(
        &self,
        invocation: &Invocation,
        scope: EngineResourceScope,
        scope_token: &str,
        reason: &str,
    ) -> Result<Value> {
        let revoked_decision_resource_id =
            required_string_owned(&invocation.payload, "revokedDecisionResourceId")?;
        let revoked = require_inspection(self, &revoked_decision_resource_id, "decision")?;
        let current = current_version(&revoked).ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "decision {revoked_decision_resource_id} has no current version"
            ))
        })?;
        let metadata = current
            .payload
            .get("metadata")
            .cloned()
            .unwrap_or(Value::Null);
        let payload = json!({
            "status": "revoked",
            "summary": format!("Revoked module source decision {revoked_decision_resource_id}"),
            "metadata": {
                "decisionType": "module_source_revocation",
                "revokedDecisionResourceId": revoked_decision_resource_id,
                "revokedDecisionVersionId": current.version_id,
                "revokedDecisionMetadata": bounded_json(&metadata, 2048),
                "scope": scope_token,
                "operatorActor": invocation.causal_context.actor_id.as_str(),
                "reason": reason,
                "revokedAt": Utc::now().to_rfc3339(),
            }
        });
        let decision = self.create_decision_resource(
            invocation,
            payload.clone(),
            Some(scope),
            &revoked_decision_resource_id,
            "revokes",
        )?;
        let evidence = self.create_evidence_resource(
            invocation,
            "module source decision revoked",
            REGISTER_SOURCE_FUNCTION,
            &revoked_decision_resource_id,
            json!({
                "evidenceType": "source_registration",
                "decisionType": "module_source_revocation",
                "revokedDecisionResourceId": revoked_decision_resource_id,
                "scope": scope_token,
                "revokedAt": payload["metadata"]["revokedAt"],
            }),
        )?;
        Ok(json!({
            "decision": payload,
            "resource": decision.resource,
            "evidence": evidence.resource,
            "resourceRefs": [decision.reference, evidence.reference],
        }))
    }
    pub(super) fn verify_signature(&self, invocation: &Invocation) -> Result<Value> {
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
    pub(super) fn audit_policy(&self, invocation: &Invocation) -> Result<Value> {
        Ok(json!({
            "audit": self.policy_audit(invocation)?,
        }))
    }
    pub(super) fn record_policy_audit(&self, invocation: &Invocation) -> Result<Value> {
        let audit = self.policy_audit(invocation)?;
        let package_resource_id = required_string_owned(&invocation.payload, "packageResourceId")?;
        let evidence = self.create_evidence_resource(
            invocation,
            "module package policy audit recorded",
            RECORD_POLICY_AUDIT_FUNCTION,
            &package_resource_id,
            json!({
                "evidenceType": "policy_audit",
                "audit": bounded_json(&audit, 4096),
                "recordedAt": Utc::now().to_rfc3339(),
            }),
        )?;
        Ok(json!({
            "audit": audit,
            "evidence": evidence.resource,
            "resourceRefs": [evidence.reference],
        }))
    }
    pub(super) fn reconcile_trust(&self, invocation: &Invocation) -> Result<Value> {
        let scope_filter = optional_string(invocation.payload.get("scope"))?;
        let (_, scope_token) = if scope_filter.is_some() {
            resource_scope_and_token(invocation)?
        } else {
            (EngineResourceScope::System, "system".to_owned())
        };
        let package_filter = optional_string(invocation.payload.get("packageResourceId"))?;
        let packages = self.list_resources(ListResources {
            kind: Some(WORKER_PACKAGE_KIND.to_owned()),
            scope: None,
            lifecycle: None,
            limit: 500,
        })?;
        let mut affected_packages = Vec::new();
        let mut affected_activations = Vec::new();
        for package in packages {
            if package_filter
                .as_deref()
                .is_some_and(|filter| filter != package.resource_id)
            {
                continue;
            }
            let Some(inspection) = self.inspect_resource(&package.resource_id)? else {
                continue;
            };
            let Some(current) = current_version(&inspection) else {
                continue;
            };
            let audit = self.policy_audit_for_manifest(
                &package.resource_id,
                &current.version_id,
                &current.payload,
                &scope_token,
                None,
                true,
            )?;
            if audit["decision"] != "allow" {
                affected_packages.push(json!({
                    "packageResourceId": package.resource_id,
                    "packageVersionId": current.version_id,
                    "decision": audit["decision"],
                    "reasons": audit["reasons"],
                    "missingPrerequisites": audit["missingPrerequisites"],
                    "recommendedActions": audit["recommendedActions"],
                }));
                if let Some(items) = audit.get("affectedActivations").and_then(Value::as_array) {
                    affected_activations.extend(items.iter().cloned());
                }
            }
        }
        let reason = optional_string(invocation.payload.get("reason"))?
            .unwrap_or_else(|| "operator requested trust reconciliation".to_owned());
        reject_raw_secrets(&json!({"reason": reason}))?;
        let affected_packages_value = json!(affected_packages);
        let affected_activations_value = json!(affected_activations);
        let evidence = self.create_evidence_resource(
            invocation,
            "module trust reconciliation recorded",
            RECONCILE_TRUST_FUNCTION,
            package_filter.as_deref().unwrap_or("module:trust"),
            json!({
                "evidenceType": "trust_reconciliation",
                "scope": scope_filter.unwrap_or_else(|| "system".to_owned()),
                "scopeValue": scope_token,
                "reason": reason,
                "affectedPackages": affected_packages_value.clone(),
                "affectedActivations": affected_activations_value.clone(),
                "reconciledAt": Utc::now().to_rfc3339(),
            }),
        )?;
        Ok(json!({
            "reconciliation": {
                "affectedPackages": affected_packages_value,
                "affectedActivations": affected_activations_value,
            },
            "evidence": evidence.resource,
            "resourceRefs": [evidence.reference],
        }))
    }
    pub(super) fn inspect_trust(&self, invocation: &Invocation) -> Result<Value> {
        let target_type = required_value_str(&invocation.payload, "targetType")?;
        let target_resource_id = required_string_owned(&invocation.payload, "targetResourceId")?;
        let include_evidence = invocation
            .payload
            .get("includeEvidence")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let limit = invocation
            .payload
            .get("limit")
            .and_then(Value::as_u64)
            .unwrap_or(50)
            .min(200) as usize;
        let target = self.trust_target_summary(target_type, &target_resource_id)?;
        let affected_packages =
            self.affected_packages_for_trust_target(target_type, &target_resource_id, limit)?;
        let affected_activations =
            self.affected_activations_for_packages(&affected_packages, limit)?;
        let decision_refs =
            self.decision_refs_for_trust_target(target_type, &target_resource_id, limit)?;
        let evidence_refs = if include_evidence {
            self.evidence_refs_for_trust_target(&target_resource_id, limit)?
        } else {
            Vec::new()
        };
        let latest_policy_audit =
            self.latest_policy_audit_for_trust_target(&target_resource_id, &affected_packages)?;
        let grant_refs = affected_activations
            .iter()
            .filter_map(|activation| activation.get("derivedGrantId").and_then(Value::as_str))
            .map(|grant_id| json!({"grantId": grant_id}))
            .collect::<Vec<_>>();
        let status = trust_target_status(target.get("payload").unwrap_or(&Value::Null));
        Ok(json!({
            "target": target,
            "status": status,
            "dependencyGraph": {
                "targetType": target_type,
                "targetResourceId": target_resource_id,
                "decisionRefs": decision_refs,
                "evidenceRefs": evidence_refs,
                "packageRefs": affected_packages,
                "activationRefs": affected_activations,
                "grantRefs": grant_refs,
            },
            "affectedPackages": affected_packages,
            "affectedActivations": affected_activations,
            "evidenceRefs": evidence_refs,
            "decisionRefs": decision_refs,
            "grantRefs": grant_refs,
            "latestPolicyAudit": latest_policy_audit,
            "warnings": trust_warnings_for_status(status),
            "availableActions": module_actions_for_trust_target(target_type, &target_resource_id),
        }))
    }
    pub(super) fn renew_trust_root(&self, invocation: &Invocation) -> Result<Value> {
        let decision_resource_id =
            required_string_owned(&invocation.payload, "trustRootDecisionResourceId")?;
        let decision_version_id =
            required_string_owned(&invocation.payload, "trustRootDecisionVersionId")?;
        let expected_current_version_id =
            required_string_owned(&invocation.payload, "expectedCurrentVersionId")?;
        if decision_version_id != expected_current_version_id {
            return Err(EngineError::PolicyViolation(
                "trustRootDecisionVersionId must match expectedCurrentVersionId".to_owned(),
            ));
        }
        let old = require_inspection(self, &decision_resource_id, "decision")?;
        ensure_expected_current_version(&old, &expected_current_version_id)?;
        let old_payload = version_payload(&old, &decision_version_id)?;
        let old_metadata = trust_decision_metadata(&old_payload, "module_trust_root")?;
        if old_payload.get("status").and_then(Value::as_str) != Some("active") {
            return Err(EngineError::PolicyViolation(
                "module::renew_trust_root requires an active trust-root decision".to_owned(),
            ));
        }
        if self.trust_root_decision_revoked(&decision_resource_id)? {
            return Err(EngineError::PolicyViolation(
                "module::renew_trust_root cannot renew a revoked trust root".to_owned(),
            ));
        }
        let old_expires_at = parse_datetime(required_map_str(old_metadata, "expiresAt")?)?;
        if old_expires_at <= Utc::now() {
            return Err(EngineError::PolicyViolation(
                "module::renew_trust_root cannot renew an expired trust root".to_owned(),
            ));
        }
        let new_expires_at = parse_datetime(required_value_str(&invocation.payload, "expiresAt")?)?;
        if new_expires_at <= Utc::now() {
            return Err(EngineError::PolicyViolation(
                "module::renew_trust_root expiresAt must be in the future".to_owned(),
            ));
        }
        let requested_selectors = string_array_from(
            invocation.payload.get("allowedPackageSelectors"),
            "allowedPackageSelectors",
        )?;
        let old_selectors = string_array_from(
            old_metadata.get("allowedPackageSelectors"),
            "allowedPackageSelectors",
        )?;
        ensure_subset(
            &requested_selectors,
            &old_selectors,
            "renewed trust-root selectors",
        )?;
        let requested_ceiling = invocation
            .payload
            .get("grantCeiling")
            .and_then(Value::as_object)
            .ok_or_else(|| {
                EngineError::PolicyViolation("renew_trust_root requires grantCeiling".to_owned())
            })?;
        let old_ceiling = old_metadata
            .get("grantCeiling")
            .and_then(Value::as_object)
            .ok_or_else(|| {
                EngineError::PolicyViolation(
                    "old trust-root decision missing grantCeiling".to_owned(),
                )
            })?;
        ensure_grant_ceiling_within_ceiling(
            requested_ceiling,
            old_ceiling,
            "renewed trust root grant ceiling",
        )?;
        ensure_grant_ceiling_narrows_caller(self, invocation, requested_ceiling)?;
        let trust_tier = required_value_str(&invocation.payload, "trustTierCeiling")?;
        if trust_tier
            != old_metadata
                .get("trustTierCeiling")
                .and_then(Value::as_str)
                .unwrap_or("")
            || trust_tier != SIGNED_LOCAL_TRUST
        {
            return Err(EngineError::PolicyViolation(
                "renewed trustTierCeiling must match the old signed_local trust root".to_owned(),
            ));
        }
        let reason = required_value_str(&invocation.payload, "reason")?;
        reject_raw_secrets(&json!({"reason": reason}))?;
        let public_key = required_map_str(old_metadata, "publicKey")?;
        let key_id = required_map_str(old_metadata, "keyId")?;
        let scope = required_map_str(old_metadata, "scope")?;
        let payload = json!({
            "status": "active",
            "summary": format!("Renewed module Ed25519 trust root {key_id}"),
            "metadata": {
                "decisionType": "module_trust_root",
                "algorithm": "ed25519",
                "publicKey": public_key,
                "keyId": key_id,
                "scope": scope,
                "allowedPackageSelectors": requested_selectors,
                "trustTierCeiling": trust_tier,
                "grantCeiling": requested_ceiling,
                "expiresAt": new_expires_at.to_rfc3339(),
                "reason": reason,
                "renewedFromDecisionResourceId": decision_resource_id,
                "renewedFromDecisionVersionId": decision_version_id,
            }
        });
        let decision = self.create_decision_resource(
            invocation,
            payload.clone(),
            Some(old.resource.scope.clone()),
            &decision_resource_id,
            "supersedes",
        )?;
        self.link_required(
            &decision.resource.resource_id,
            &decision_resource_id,
            "supersedes",
            invocation,
        )?;
        let evidence = self.create_evidence_resource(
            invocation,
            "module trust root renewed",
            RENEW_TRUST_ROOT_FUNCTION,
            &decision.resource.resource_id,
            json!({
                "evidenceType": "trust_root_renewal",
                "oldDecisionResourceId": decision_resource_id,
                "oldDecisionVersionId": decision_version_id,
                "newDecisionResourceId": decision.resource.resource_id,
                "keyId": key_id,
                "expiresAt": new_expires_at.to_rfc3339(),
            }),
        )?;
        self.link_required(
            &evidence.resource.resource_id,
            &decision.resource.resource_id,
            "renewed_by",
            invocation,
        )?;
        Ok(json!({
            "decision": payload,
            "resource": decision.resource,
            "evidence": evidence.resource,
            "resourceRefs": [decision.reference, evidence.reference],
        }))
    }
    pub(super) fn rotate_signature_key(&self, invocation: &Invocation) -> Result<Value> {
        let old_id = required_string_owned(&invocation.payload, "oldTrustRootDecisionResourceId")?;
        let old_version_id =
            required_string_owned(&invocation.payload, "oldTrustRootDecisionVersionId")?;
        let new_id = required_string_owned(&invocation.payload, "newTrustRootDecisionResourceId")?;
        let new_version_id =
            required_string_owned(&invocation.payload, "newTrustRootDecisionVersionId")?;
        let old = self.active_trust_root_decision(&old_id, &old_version_id)?;
        let new = self.active_trust_root_decision(&new_id, &new_version_id)?;
        let old_metadata = trust_decision_metadata(&old, "module_trust_root")?;
        let new_metadata = trust_decision_metadata(&new, "module_trust_root")?;
        if required_map_str(old_metadata, "scope")? != required_map_str(new_metadata, "scope")? {
            return Err(EngineError::PolicyViolation(
                "signature key rotation requires matching trust-root scopes".to_owned(),
            ));
        }
        if required_map_str(old_metadata, "keyId")? == required_map_str(new_metadata, "keyId")? {
            return Err(EngineError::PolicyViolation(
                "signature key rotation requires a new key id".to_owned(),
            ));
        }
        let new_selectors = string_array_from(
            new_metadata.get("allowedPackageSelectors"),
            "allowedPackageSelectors",
        )?;
        let old_selectors = string_array_from(
            old_metadata.get("allowedPackageSelectors"),
            "allowedPackageSelectors",
        )?;
        ensure_subset(
            &new_selectors,
            &old_selectors,
            "rotated trust-root selectors",
        )?;
        let new_ceiling = new_metadata
            .get("grantCeiling")
            .and_then(Value::as_object)
            .ok_or_else(|| {
                EngineError::PolicyViolation(
                    "new trust-root decision missing grantCeiling".to_owned(),
                )
            })?;
        let old_ceiling = old_metadata
            .get("grantCeiling")
            .and_then(Value::as_object)
            .ok_or_else(|| {
                EngineError::PolicyViolation(
                    "old trust-root decision missing grantCeiling".to_owned(),
                )
            })?;
        ensure_grant_ceiling_within_ceiling(
            new_ceiling,
            old_ceiling,
            "rotated trust root grant ceiling",
        )?;
        ensure_grant_ceiling_narrows_caller(self, invocation, new_ceiling)?;
        let reason = required_value_str(&invocation.payload, "reason")?;
        reject_raw_secrets(&json!({"reason": reason}))?;
        let evidence = self.create_evidence_resource(
            invocation,
            "module signature key rotation recorded",
            ROTATE_SIGNATURE_KEY_FUNCTION,
            &old_id,
            json!({
                "evidenceType": "signature_key_rotation",
                "oldTrustRootDecisionResourceId": old_id,
                "oldTrustRootDecisionVersionId": old_version_id,
                "oldKeyId": required_map_str(old_metadata, "keyId")?,
                "newTrustRootDecisionResourceId": new_id,
                "newTrustRootDecisionVersionId": new_version_id,
                "newKeyId": required_map_str(new_metadata, "keyId")?,
                "reason": reason,
                "rotatedAt": Utc::now().to_rfc3339(),
            }),
        )?;
        self.link_required(
            &evidence.resource.resource_id,
            &old_id,
            "rotates_from",
            invocation,
        )?;
        self.link_required(
            &evidence.resource.resource_id,
            &new_id,
            "rotates_to",
            invocation,
        )?;
        Ok(json!({
            "rotation": {
                "oldTrustRootDecisionResourceId": old_id,
                "newTrustRootDecisionResourceId": new_id,
            },
            "evidence": evidence.resource,
            "resourceRefs": [evidence.reference],
        }))
    }
    pub(super) fn expire_trust_decision(&self, invocation: &Invocation) -> Result<Value> {
        let decision_resource_id =
            required_string_owned(&invocation.payload, "decisionResourceId")?;
        let decision_version_id = required_string_owned(&invocation.payload, "decisionVersionId")?;
        let expected_current_version_id =
            required_string_owned(&invocation.payload, "expectedCurrentVersionId")?;
        if decision_version_id != expected_current_version_id {
            return Err(EngineError::PolicyViolation(
                "decisionVersionId must match expectedCurrentVersionId".to_owned(),
            ));
        }
        let inspection = require_inspection(self, &decision_resource_id, "decision")?;
        ensure_expected_current_version(&inspection, &expected_current_version_id)?;
        let mut payload = version_payload(&inspection, &decision_version_id)?;
        let decision_type = payload
            .get("metadata")
            .and_then(|metadata| metadata.get("decisionType"))
            .and_then(Value::as_str)
            .map(ToOwned::to_owned)
            .ok_or_else(|| {
                EngineError::PolicyViolation(
                    "expire_trust_decision requires a module decision type".to_owned(),
                )
            })?;
        if !matches!(
            decision_type.as_str(),
            "module_trust_root"
                | "module_source_registration"
                | "module_source_approval"
                | "module_trust_audit_schedule"
        ) {
            return Err(EngineError::PolicyViolation(format!(
                "expire_trust_decision does not accept {decision_type}"
            )));
        }
        let reason = required_value_str(&invocation.payload, "reason")?;
        reject_raw_secrets(&json!({"reason": reason}))?;
        payload["status"] = json!("expired");
        payload["expiredAt"] = json!(Utc::now().to_rfc3339());
        payload["expirationReason"] = json!(reason);
        if let Some(metadata) = payload.get_mut("metadata").and_then(Value::as_object_mut) {
            metadata.insert("expiredAt".to_owned(), json!(Utc::now().to_rfc3339()));
            metadata.insert("expirationReason".to_owned(), json!(reason));
        }
        let version = self.update_resource(UpdateResource {
            resource_id: decision_resource_id.clone(),
            expected_current_version_id: Some(expected_current_version_id),
            lifecycle: Some("archived".to_owned()),
            payload: payload.clone(),
            state: None,
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })?;
        let evidence = self.create_evidence_resource(
            invocation,
            "module trust decision expired",
            EXPIRE_TRUST_DECISION_FUNCTION,
            &decision_resource_id,
            json!({
                "evidenceType": "trust_decision_expired",
                "decisionType": decision_type,
                "decisionResourceId": decision_resource_id,
                "decisionVersionId": decision_version_id,
                "expiredVersionId": version.version_id,
                "reason": reason,
            }),
        )?;
        self.link_required(
            &evidence.resource.resource_id,
            &decision_resource_id,
            "evidence_for",
            invocation,
        )?;
        Ok(json!({
            "decision": payload,
            "version": version,
            "evidence": evidence.resource,
            "resourceRefs": [
                resource_ref_from_version(&version, "decision", "expired"),
                evidence.reference
            ],
        }))
    }
    pub(super) async fn enforce_revocation(&self, invocation: &Invocation) -> Result<Value> {
        let mode = required_value_str(&invocation.payload, "mode")?;
        if !matches!(mode, "disable" | "quarantine") {
            return Err(EngineError::PolicyViolation(
                "enforce_revocation mode must be disable or quarantine".to_owned(),
            ));
        }
        let activation_ids = string_array_from(
            invocation.payload.get("activationResourceIds"),
            "activationResourceIds",
        )?;
        if activation_ids.is_empty() {
            return Err(EngineError::PolicyViolation(
                "enforce_revocation requires explicit affected activation ids".to_owned(),
            ));
        }
        let reason = required_value_str(&invocation.payload, "reason")?;
        reject_raw_secrets(&json!({"reason": reason}))?;
        let (trust_decision_id, revocation_decision_id, expected_decision_version_id) =
            self.revocation_enforcement_target(invocation)?;
        let affected_packages =
            self.affected_packages_for_trust_target("decision", &trust_decision_id, 500)?;
        let affected_activations =
            self.affected_activations_for_packages(&affected_packages, 500)?;
        let affected_activation_ids = affected_activations
            .iter()
            .filter_map(|activation| {
                activation
                    .get("activationResourceId")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned)
            })
            .collect::<Vec<_>>();
        for activation_id in &activation_ids {
            if !affected_activation_ids
                .iter()
                .any(|item| item == activation_id)
            {
                return Err(EngineError::PolicyViolation(format!(
                    "activation {activation_id} is not affected by revoked trust {trust_decision_id}"
                )));
            }
        }
        let evidence = self.create_evidence_resource(
            invocation,
            "module trust revocation enforcement requested",
            ENFORCE_REVOCATION_FUNCTION,
            &trust_decision_id,
            json!({
                "evidenceType": "revocation_enforcement",
                "trustDecisionResourceId": trust_decision_id,
                "revocationDecisionResourceId": revocation_decision_id,
                "expectedDecisionVersionId": expected_decision_version_id,
                "mode": mode,
                "activationResourceIds": activation_ids,
                "reason": reason,
                "requestedAt": Utc::now().to_rfc3339(),
            }),
        )?;
        self.link_required(
            &evidence.resource.resource_id,
            &trust_decision_id,
            "enforces_revocation",
            invocation,
        )?;
        let mut refs = vec![evidence.reference.clone()];
        let mut child_invocation_ids = Vec::new();
        let mut per_activation = Vec::new();
        for activation_id in activation_ids {
            self.link_required(
                &evidence.resource.resource_id,
                &activation_id,
                "affects_activation",
                invocation,
            )?;
            let activation = require_inspection(self, &activation_id, ACTIVATION_RECORD_KIND)?;
            let expected_current_version_id = activation
                .resource
                .current_version_id
                .clone()
                .ok_or_else(|| {
                    EngineError::PolicyViolation(format!(
                        "activation {activation_id} has no current version"
                    ))
                })?;
            let (function_id, payload) = if mode == "disable" {
                (
                    DISABLE_FUNCTION,
                    json!({
                        "activationResourceId": activation_id,
                        "expectedCurrentVersionId": expected_current_version_id,
                    }),
                )
            } else {
                (
                    QUARANTINE_FUNCTION,
                    json!({
                        "resourceId": activation_id,
                        "expectedCurrentVersionId": expected_current_version_id,
                        "evidenceResourceIds": [evidence.resource.resource_id],
                    }),
                )
            };
            let mut context = invocation.causal_context.clone();
            context.parent_invocation_id = Some(invocation.id.clone());
            context.idempotency_key = Some(format!(
                "module.enforce_revocation:{mode}:{activation_id}:{}",
                invocation
                    .causal_context
                    .idempotency_key
                    .as_deref()
                    .unwrap_or(invocation.id.as_str())
            ));
            context.authority_scopes.push("module.write".to_owned());
            let child = Invocation::new_sync(FunctionId::new(function_id)?, payload, context);
            let result = self.stores.engine_host()?.invoke(child).await;
            child_invocation_ids.push(json!(result.invocation_id.as_str()));
            let status = if let Some(error) = result.error {
                json!({
                    "activationResourceId": activation_id,
                    "status": "failed",
                    "error": error.to_string(),
                    "childInvocationId": result.invocation_id.as_str(),
                })
            } else {
                if let Some(value) = &result.value
                    && let Some(resource_refs) = value.get("resourceRefs").and_then(Value::as_array)
                {
                    refs.extend(resource_refs.iter().cloned());
                }
                json!({
                    "activationResourceId": activation_id,
                    "status": "completed",
                    "childInvocationId": result.invocation_id.as_str(),
                    "result": result.value.unwrap_or(Value::Null),
                })
            };
            per_activation.push(status);
        }
        Ok(json!({
            "enforcement": {
                "mode": mode,
                "trustDecisionResourceId": trust_decision_id,
                "revocationDecisionResourceId": revocation_decision_id,
                "results": per_activation,
            },
            "evidence": evidence.resource,
            "childInvocationIds": child_invocation_ids,
            "perActivationResults": per_activation,
            "resourceRefs": refs,
        }))
    }
    pub(super) fn verify_source(&self, invocation: &Invocation) -> Result<Value> {
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
    pub(super) fn approve_source(&self, invocation: &Invocation) -> Result<Value> {
        let package_resource_id = required_string_owned(&invocation.payload, "packageResourceId")?;
        let package_version_id = required_string_owned(&invocation.payload, "packageVersionId")?;
        let package = require_inspection(self, &package_resource_id, WORKER_PACKAGE_KIND)?;
        let manifest = version_payload(&package, &package_version_id)?;
        ensure_version_is_current(&package, &package_version_id)?;
        let package_id = required_value_str(&manifest, "packageId")?;
        if required_value_str(&invocation.payload, "packageId")? != package_id {
            return Err(EngineError::PolicyViolation(
                "source approval packageId does not match package resource".to_owned(),
            ));
        }
        let package_digest = required_value_str(&manifest, "packageDigest")?;
        if required_value_str(&invocation.payload, "packageDigest")? != package_digest {
            return Err(EngineError::PolicyViolation(
                "source approval packageDigest does not match package resource".to_owned(),
            ));
        }
        if source_kind(&manifest)? != LOCAL_DIGEST_PINNED {
            return Err(EngineError::PolicyViolation(
                "module::approve_source only approves local_digest_pinned package sources"
                    .to_owned(),
            ));
        }
        if manifest.get("sourceTrustStatus").and_then(Value::as_str) != Some(SOURCE_STATUS_VERIFIED)
        {
            return Err(EngineError::PolicyViolation(
                "source approval requires verified package source evidence".to_owned(),
            ));
        }
        let trust_tier_ceiling = required_string_owned(&invocation.payload, "trustTierCeiling")?;
        if trust_tier_ceiling != LOCAL_DIGEST_PINNED {
            return Err(EngineError::PolicyViolation(format!(
                "source approval trustTierCeiling {trust_tier_ceiling} exceeds local_digest_pinned source"
            )));
        }
        let expires_at = parse_datetime(required_value_str(&invocation.payload, "expiresAt")?)?;
        if expires_at <= Utc::now() {
            return Err(EngineError::PolicyViolation(
                "source approval expiresAt must be in the future".to_owned(),
            ));
        }
        let grant_ceiling =
            required_object(invocation.payload.get("grantCeiling"), "grantCeiling")?;
        let worker_id = manifest
            .get("runtimeEntryPoint")
            .and_then(|entry| entry.get("workerId"))
            .and_then(Value::as_str)
            .ok_or_else(|| {
                EngineError::PolicyViolation(
                    "source approval requires runtimeEntryPoint.workerId".to_owned(),
                )
            })?;
        let ceiling_request = child_grant_from_payload(
            invocation,
            &manifest,
            &WorkerId::new(worker_id.to_owned())?,
            grant_ceiling,
        )?;
        ensure_grant_request_narrows_caller(self, invocation, &ceiling_request)?;
        let (scope, scope_token) = resource_scope_and_token(invocation)?;
        let reason = required_string_owned(&invocation.payload, "reason")?;
        reject_raw_secrets(&json!({"reason": reason}))?;
        let decision_payload = json!({
            "status": "approved",
            "summary": format!("Approved local package source {package_id} for scope {scope_token}"),
            "metadata": {
                "decisionType": "module_source_approval",
                "packageResourceId": package_resource_id,
                "packageVersionId": package_version_id,
                "packageId": package_id,
                "packageDigest": package_digest,
                "scope": scope_token,
                "trustTierCeiling": trust_tier_ceiling,
                "grantCeiling": grant_ceiling,
                "expiresAt": expires_at.to_rfc3339(),
                "operatorActor": invocation.causal_context.actor_id.as_str(),
                "reason": reason,
                "approvedAt": Utc::now().to_rfc3339(),
            }
        });
        let decision = self.create_decision_resource(
            invocation,
            decision_payload.clone(),
            Some(scope),
            &package_resource_id,
            "supports",
        )?;
        Ok(json!({
            "decision": decision_payload,
            "resource": decision.resource,
            "resourceRefs": [decision.reference],
        }))
    }
    pub(super) fn revoke_source_approval(&self, invocation: &Invocation) -> Result<Value> {
        let decision_resource_id =
            required_string_owned(&invocation.payload, "decisionResourceId")?;
        let reason = required_string_owned(&invocation.payload, "reason")?;
        reject_raw_secrets(&json!({"reason": reason}))?;
        let inspection = require_inspection(self, &decision_resource_id, "decision")?;
        let current = current_version(&inspection).ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "decision {decision_resource_id} has no current version"
            ))
        })?;
        let mut payload = current.payload.clone();
        if payload
            .get("metadata")
            .and_then(|metadata| metadata.get("decisionType"))
            .and_then(Value::as_str)
            != Some("module_source_approval")
        {
            return Err(EngineError::PolicyViolation(
                "module::revoke_source_approval requires a module source approval decision"
                    .to_owned(),
            ));
        }
        payload["status"] = json!("revoked");
        payload["summary"] = json!("Revoked module source approval");
        payload["metadata"]["revokedAt"] = json!(Utc::now().to_rfc3339());
        payload["metadata"]["revokedBy"] = json!(invocation.causal_context.actor_id.as_str());
        payload["metadata"]["revocationReason"] = json!(reason);
        let version = self.update_resource(UpdateResource {
            resource_id: decision_resource_id.clone(),
            expected_current_version_id: optional_string(
                invocation.payload.get("expectedCurrentVersionId"),
            )?
            .or_else(|| inspection.resource.current_version_id.clone()),
            lifecycle: Some("archived".to_owned()),
            payload: payload.clone(),
            state: None,
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })?;
        let package_resource_id = payload
            .get("metadata")
            .and_then(|metadata| metadata.get("packageResourceId"))
            .and_then(Value::as_str)
            .unwrap_or(&decision_resource_id);
        let evidence = self.create_evidence_resource(
            invocation,
            &format!("module source approval {decision_resource_id} revoked"),
            REVOKE_SOURCE_APPROVAL_FUNCTION,
            package_resource_id,
            json!({
                "decisionResourceId": decision_resource_id,
                "reason": payload["metadata"]["revocationReason"],
                "revokedAt": payload["metadata"]["revokedAt"],
            }),
        )?;
        Ok(json!({
            "decision": payload,
            "version": version,
            "evidence": evidence.resource,
            "resourceRefs": [
                resource_ref_from_version(&version, "decision", "revoked"),
                evidence.reference
            ],
        }))
    }
    pub(super) fn policy_decide(&self, invocation: &Invocation) -> Result<Value> {
        let package_resource_id = required_string_owned(&invocation.payload, "packageResourceId")?;
        let package_version_id = required_string_owned(&invocation.payload, "packageVersionId")?;
        let package = require_inspection(self, &package_resource_id, WORKER_PACKAGE_KIND)?;
        let manifest = version_payload(&package, &package_version_id)?;
        let (_, scope_token) = resource_scope_and_token(invocation)?;
        let child_request = invocation
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
                            "policy decision requires runtimeEntryPoint.workerId".to_owned(),
                        )
                    })?;
                child_grant_from_payload(
                    invocation,
                    &manifest,
                    &WorkerId::new(worker_id.to_owned())?,
                    request,
                )
            })
            .transpose()?;
        let evaluation = self.evaluate_source_policy(
            &manifest,
            &package_resource_id,
            &package_version_id,
            &scope_token,
            child_request.as_ref(),
        )?;
        Ok(policy_evaluation_value(evaluation))
    }
    fn evaluate_source_policy(
        &self,
        manifest: &Value,
        package_resource_id: &str,
        package_version_id: &str,
        scope_token: &str,
        child_request: Option<&DeriveGrant>,
    ) -> Result<SourcePolicyEvaluation> {
        let source_kind = source_kind(manifest)?;
        let mut reasons = Vec::new();
        let mut missing = Vec::new();
        let source_trust = json!({
            "kind": source_kind,
            "status": manifest.get("sourceTrustStatus").cloned().unwrap_or_else(|| json!(SOURCE_STATUS_UNVERIFIED)),
            "effectiveTrustTier": manifest.get("effectiveTrustTier").cloned().unwrap_or_else(|| json!("untrusted")),
            "evidenceRefs": manifest.get("sourceEvidenceRefs").cloned().unwrap_or_else(|| json!([])),
        });
        let conformance = json!({
            "evidenceRefs": manifest.get("conformanceEvidenceRefs").cloned().unwrap_or_else(|| json!([])),
            "status": manifest
                .get("policyDiagnostics")
                .and_then(|diagnostics| diagnostics.get("conformance"))
                .and_then(|conformance| conformance.get("status"))
                .and_then(Value::as_str)
                .unwrap_or("not_required")
        });
        let signed_local = package_has_signature(manifest);
        let approval = if source_kind == BUILTIN_PROVENANCE {
            json!({"status": "not_required"})
        } else if signed_local {
            match signature_key_id(manifest).and_then(|key_id| {
                self.active_trust_root(
                    &key_id,
                    manifest,
                    package_resource_id,
                    scope_token,
                    child_request,
                )
            }) {
                Ok(root) => json!({
                    "status": "trusted_signature",
                    "decisionResourceId": root.decision_resource_id,
                    "decisionVersionId": root.decision_version_id,
                    "keyId": root.key_id,
                    "expiresAt": root.expires_at.to_rfc3339(),
                }),
                Err(error) => {
                    reasons.push(format!("signature trust is missing, revoked, expired, or narrower than requested authority: {error}"));
                    missing.push("signature_trust".to_owned());
                    json!({"status": "missing"})
                }
            }
        } else {
            match self.active_source_approval(
                manifest,
                package_resource_id,
                package_version_id,
                scope_token,
                child_request,
            )? {
                Some(value) => value,
                None => {
                    reasons.push("source approval is missing, revoked, expired, or narrower than requested authority".to_owned());
                    missing.push("source_approval".to_owned());
                    json!({"status": "missing"})
                }
            }
        };
        if source_kind == BUILTIN_PROVENANCE {
            if required_value_str(manifest, "signatureStatus")? != SOURCE_STATUS_TRUSTED_BUILTIN {
                reasons.push("builtin package signatureStatus is not trusted_builtin".to_owned());
            }
        } else if source_kind == LOCAL_DIGEST_PINNED {
            let expected_status = if signed_local {
                SOURCE_STATUS_SIGNATURE_VERIFIED
            } else {
                SOURCE_STATUS_VERIFIED
            };
            if manifest.get("sourceTrustStatus").and_then(Value::as_str) != Some(expected_status) {
                reasons.push(if signed_local {
                    "signature verification is missing or stale".to_owned()
                } else {
                    "source verification is missing or stale".to_owned()
                });
                missing.push(if signed_local {
                    "signature_verification".to_owned()
                } else {
                    "source_verification".to_owned()
                });
            }
            if manifest
                .get("sourceEvidenceRefs")
                .and_then(Value::as_array)
                .is_none_or(Vec::is_empty)
            {
                reasons.push("source verification evidence is missing".to_owned());
                missing.push("source_evidence".to_owned());
            }
        }
        if let Some(policy) = manifest.get("packagePolicy")
            && policy
                .get("requiresConformanceBeforeActivation")
                .and_then(Value::as_bool)
                .unwrap_or(false)
            && manifest
                .get("conformanceEvidenceRefs")
                .and_then(Value::as_array)
                .is_none_or(Vec::is_empty)
        {
            reasons.push("package policy requires conformance evidence".to_owned());
            missing.push("conformance_evidence".to_owned());
        }
        Ok(SourcePolicyEvaluation {
            decision: if reasons.is_empty() { "allow" } else { "deny" },
            reasons,
            missing_prerequisites: missing,
            source_trust,
            approval,
            conformance,
        })
    }
    pub(super) fn ensure_activation_source_policy(
        &self,
        manifest: &Value,
        package_resource_id: &str,
        package_version_id: &str,
        scope_token: &str,
        child_request: &DeriveGrant,
    ) -> Result<()> {
        let evaluation = self.evaluate_source_policy(
            manifest,
            package_resource_id,
            package_version_id,
            scope_token,
            Some(child_request),
        )?;
        if evaluation.decision == "allow" {
            Ok(())
        } else {
            Err(EngineError::PolicyViolation(format!(
                "source policy denied activation: {}",
                evaluation.reasons.join("; ")
            )))
        }
    }
    pub(super) fn active_source_approval(
        &self,
        manifest: &Value,
        package_resource_id: &str,
        package_version_id: &str,
        scope_token: &str,
        child_request: Option<&DeriveGrant>,
    ) -> Result<Option<Value>> {
        let package_digest = required_value_str(manifest, "packageDigest")?;
        let decisions = self.list_resources(ListResources {
            kind: Some("decision".to_owned()),
            scope: None,
            lifecycle: None,
            limit: 500,
        })?;
        for decision in decisions {
            if matches!(decision.lifecycle.as_str(), "archived") {
                continue;
            }
            let Some(inspection) = self.inspect_resource(&decision.resource_id)? else {
                continue;
            };
            let Some(payload) = current_payload(&inspection) else {
                continue;
            };
            if payload.get("status").and_then(Value::as_str) != Some("approved") {
                continue;
            }
            let metadata = payload.get("metadata").and_then(Value::as_object);
            let Some(metadata) = metadata else {
                continue;
            };
            let matches_target = metadata.get("decisionType").and_then(Value::as_str)
                == Some("module_source_approval")
                && metadata.get("packageResourceId").and_then(Value::as_str)
                    == Some(package_resource_id)
                && metadata.get("packageVersionId").and_then(Value::as_str)
                    == Some(package_version_id)
                && metadata.get("packageDigest").and_then(Value::as_str) == Some(package_digest)
                && metadata.get("scope").and_then(Value::as_str) == Some(scope_token);
            if !matches_target {
                continue;
            }
            let expires_at = metadata
                .get("expiresAt")
                .and_then(Value::as_str)
                .map(parse_datetime)
                .transpose()?
                .ok_or_else(|| {
                    EngineError::PolicyViolation(
                        "source approval decision is missing expiresAt".to_owned(),
                    )
                })?;
            if expires_at <= Utc::now() {
                continue;
            }
            if let Some(child_request) = child_request {
                let ceiling = metadata
                    .get("grantCeiling")
                    .and_then(Value::as_object)
                    .ok_or_else(|| {
                        EngineError::PolicyViolation(
                            "source approval decision missing grantCeiling".to_owned(),
                        )
                    })?;
                ensure_grant_request_within_ceiling(child_request, ceiling)?;
            }
            let current = current_version(&inspection);
            return Ok(Some(json!({
                "status": "approved",
                "decisionResourceId": decision.resource_id,
                "decisionVersionId": current.map(|version| version.version_id.clone()),
                "expiresAt": expires_at.to_rfc3339(),
            })));
        }
        Ok(None)
    }
    fn active_trust_root(
        &self,
        key_id: &str,
        manifest: &Value,
        package_resource_id: &str,
        scope_token: &str,
        child_request: Option<&DeriveGrant>,
    ) -> Result<ActiveTrustRoot> {
        let decisions = self.list_resources(ListResources {
            kind: Some("decision".to_owned()),
            scope: None,
            lifecycle: None,
            limit: 500,
        })?;
        for decision in decisions {
            if matches!(decision.lifecycle.as_str(), "archived") {
                continue;
            }
            let Some(inspection) = self.inspect_resource(&decision.resource_id)? else {
                continue;
            };
            let Some(payload) = current_payload(&inspection) else {
                continue;
            };
            if payload.get("status").and_then(Value::as_str) != Some("active") {
                continue;
            }
            let Some(metadata) = payload.get("metadata").and_then(Value::as_object) else {
                continue;
            };
            let matches_target = metadata.get("decisionType").and_then(Value::as_str)
                == Some("module_trust_root")
                && metadata.get("algorithm").and_then(Value::as_str) == Some("ed25519")
                && metadata.get("keyId").and_then(Value::as_str) == Some(key_id)
                && metadata.get("scope").and_then(Value::as_str) == Some(scope_token);
            if !matches_target {
                continue;
            }
            if self.trust_root_decision_revoked(&decision.resource_id)? {
                return Err(EngineError::PolicyViolation(format!(
                    "trust root decision {} has a matching revocation decision",
                    decision.resource_id
                )));
            }
            let expires_at = metadata
                .get("expiresAt")
                .and_then(Value::as_str)
                .map(parse_datetime)
                .transpose()?
                .ok_or_else(|| {
                    EngineError::PolicyViolation(
                        "trust-root decision is missing expiresAt".to_owned(),
                    )
                })?;
            if expires_at <= Utc::now() {
                return Err(EngineError::PolicyViolation(format!(
                    "trust root {key_id} is expired"
                )));
            }
            let selectors = string_array_from(
                metadata.get("allowedPackageSelectors"),
                "allowedPackageSelectors",
            )?;
            if !package_selector_matches(&selectors, manifest, package_resource_id)? {
                return Err(EngineError::PolicyViolation(format!(
                    "trust root {key_id} does not cover package {package_resource_id}"
                )));
            }
            if metadata
                .get("trustTierCeiling")
                .and_then(Value::as_str)
                .unwrap_or("")
                != SIGNED_LOCAL_TRUST
            {
                return Err(EngineError::PolicyViolation(format!(
                    "trust root {key_id} does not allow {SIGNED_LOCAL_TRUST}"
                )));
            }
            if let Some(child_request) = child_request {
                let ceiling = metadata
                    .get("grantCeiling")
                    .and_then(Value::as_object)
                    .ok_or_else(|| {
                        EngineError::PolicyViolation(
                            "trust-root decision missing grantCeiling".to_owned(),
                        )
                    })?;
                ensure_grant_request_within_ceiling(child_request, ceiling)?;
            }
            let current = current_version(&inspection);
            let public_key = metadata
                .get("publicKey")
                .and_then(Value::as_str)
                .ok_or_else(|| {
                    EngineError::PolicyViolation("trust-root decision missing publicKey".to_owned())
                })?
                .to_owned();
            return Ok(ActiveTrustRoot {
                decision_resource_id: decision.resource_id,
                decision_version_id: current.map(|version| version.version_id.clone()),
                key_id: key_id.to_owned(),
                public_key,
                expires_at,
            });
        }
        Err(EngineError::PolicyViolation(format!(
            "active trust root {key_id} not found"
        )))
    }
    pub(super) fn trust_root_decision_revoked(&self, decision_resource_id: &str) -> Result<bool> {
        let decisions = self.list_resources(ListResources {
            kind: Some("decision".to_owned()),
            scope: None,
            lifecycle: None,
            limit: 500,
        })?;
        for decision in decisions {
            if self.revocation_targets_decision(&decision, decision_resource_id)? {
                return Ok(true);
            }
        }
        Ok(false)
    }
    pub(super) fn revocation_targets_decision(
        &self,
        decision: &EngineResource,
        decision_resource_id: &str,
    ) -> Result<bool> {
        let Some(inspection) = self.inspect_resource(&decision.resource_id)? else {
            return Ok(false);
        };
        let Some(payload) = current_payload(&inspection) else {
            return Ok(false);
        };
        let Some(metadata) = payload.get("metadata").and_then(Value::as_object) else {
            return Ok(false);
        };
        if metadata.get("decisionType").and_then(Value::as_str) != Some("module_source_revocation")
        {
            return Ok(false);
        }
        Ok(metadata
            .get("revokedDecisionResourceId")
            .and_then(Value::as_str)
            == Some(decision_resource_id))
    }
    pub(super) fn active_trust_root_decision(
        &self,
        decision_resource_id: &str,
        decision_version_id: &str,
    ) -> Result<Value> {
        let inspection = require_inspection(self, decision_resource_id, "decision")?;
        ensure_version_is_current(&inspection, decision_version_id)?;
        if inspection.resource.lifecycle == "archived" {
            return Err(EngineError::PolicyViolation(format!(
                "trust root decision {decision_resource_id} is archived"
            )));
        }
        let payload = version_payload(&inspection, decision_version_id)?;
        let metadata = trust_decision_metadata(&payload, "module_trust_root")?;
        if payload.get("status").and_then(Value::as_str) != Some("active") {
            return Err(EngineError::PolicyViolation(format!(
                "trust root decision {decision_resource_id} is not active"
            )));
        }
        if self.trust_root_decision_revoked(decision_resource_id)? {
            return Err(EngineError::PolicyViolation(format!(
                "trust root decision {decision_resource_id} is revoked"
            )));
        }
        let expires_at = parse_datetime(required_map_str(metadata, "expiresAt")?)?;
        if expires_at <= Utc::now() {
            return Err(EngineError::PolicyViolation(format!(
                "trust root decision {decision_resource_id} is expired"
            )));
        }
        Ok(payload)
    }
    pub(super) fn trust_target_summary(
        &self,
        target_type: &str,
        target_resource_id: &str,
    ) -> Result<Value> {
        let expected_kind = match target_type {
            "package" => WORKER_PACKAGE_KIND,
            "activation" => ACTIVATION_RECORD_KIND,
            "trust_root"
            | "source_registration"
            | "source_approval"
            | "source_revocation"
            | "decision" => "decision",
            other => {
                return Err(EngineError::PolicyViolation(format!(
                    "unsupported trust inspect targetType {other}"
                )));
            }
        };
        let inspection = require_inspection(self, target_resource_id, expected_kind)?;
        let payload = current_payload(&inspection).unwrap_or(Value::Null);
        Ok(json!({
            "targetType": target_type,
            "resourceId": target_resource_id,
            "kind": inspection.resource.kind,
            "lifecycle": inspection.resource.lifecycle,
            "currentVersionId": inspection.resource.current_version_id,
            "payload": bounded_json(&payload, 4096),
        }))
    }
    pub(super) fn affected_packages_for_trust_target(
        &self,
        target_type: &str,
        target_resource_id: &str,
        limit: usize,
    ) -> Result<Vec<Value>> {
        match target_type {
            "package" => {
                let inspection = require_inspection(self, target_resource_id, WORKER_PACKAGE_KIND)?;
                return Ok(vec![package_trust_summary(&inspection)?]);
            }
            "activation" => {
                let inspection =
                    require_inspection(self, target_resource_id, ACTIVATION_RECORD_KIND)?;
                let payload = current_payload(&inspection).ok_or_else(|| {
                    EngineError::PolicyViolation(format!(
                        "activation {target_resource_id} has no current payload"
                    ))
                })?;
                let package_resource_id = required_value_str(&payload, "packageResourceId")?;
                let package = require_inspection(self, package_resource_id, WORKER_PACKAGE_KIND)?;
                return Ok(vec![package_trust_summary(&package)?]);
            }
            "source_revocation" => {
                let inspection = require_inspection(self, target_resource_id, "decision")?;
                let payload = current_payload(&inspection).ok_or_else(|| {
                    EngineError::PolicyViolation(format!(
                        "decision {target_resource_id} has no current payload"
                    ))
                })?;
                let metadata = trust_decision_metadata(&payload, "module_source_revocation")?;
                let revoked = required_map_str(metadata, "revokedDecisionResourceId")?;
                return self.affected_packages_for_trust_target("decision", revoked, limit);
            }
            _ => {}
        }
        let decision = require_inspection(self, target_resource_id, "decision")?;
        let payload = current_payload(&decision).ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "decision {target_resource_id} has no current payload"
            ))
        })?;
        let Some(metadata) = payload.get("metadata").and_then(Value::as_object) else {
            return Ok(Vec::new());
        };
        let decision_type = metadata
            .get("decisionType")
            .and_then(Value::as_str)
            .unwrap_or("");
        let packages = self.list_resources(ListResources {
            kind: Some(WORKER_PACKAGE_KIND.to_owned()),
            scope: None,
            lifecycle: None,
            limit: 500,
        })?;
        let mut affected = Vec::new();
        for package in packages {
            if affected.len() >= limit {
                break;
            }
            let Some(package_inspection) = self.inspect_resource(&package.resource_id)? else {
                continue;
            };
            let Some(manifest) = current_payload(&package_inspection) else {
                continue;
            };
            let matches = match decision_type {
                "module_trust_root" => {
                    let selectors = string_array_from(
                        metadata.get("allowedPackageSelectors"),
                        "allowedPackageSelectors",
                    )?;
                    package_selector_matches(&selectors, &manifest, &package.resource_id)?
                }
                "module_source_registration" => metadata
                    .get("sourceDigest")
                    .and_then(Value::as_str)
                    .is_some_and(|digest| {
                        manifest.get("packageDigest").and_then(Value::as_str) == Some(digest)
                    }),
                "module_source_approval" => {
                    metadata.get("packageResourceId").and_then(Value::as_str)
                        == Some(package.resource_id.as_str())
                }
                "module_source_revocation" => {
                    let revoked = required_map_str(metadata, "revokedDecisionResourceId")?;
                    return self.affected_packages_for_trust_target("decision", revoked, limit);
                }
                _ => false,
            };
            if matches {
                affected.push(package_trust_summary(&package_inspection)?);
            }
        }
        Ok(affected)
    }
    pub(super) fn affected_activations_for_packages(
        &self,
        packages: &[Value],
        limit: usize,
    ) -> Result<Vec<Value>> {
        let activations = self.list_resources(ListResources {
            kind: Some(ACTIVATION_RECORD_KIND.to_owned()),
            scope: None,
            lifecycle: None,
            limit: 500,
        })?;
        let package_ids = packages
            .iter()
            .filter_map(|package| package.get("packageId").and_then(Value::as_str))
            .collect::<Vec<_>>();
        let package_resource_ids = packages
            .iter()
            .filter_map(|package| package.get("packageResourceId").and_then(Value::as_str))
            .collect::<Vec<_>>();
        let mut affected = Vec::new();
        for activation in activations {
            if affected.len() >= limit {
                break;
            }
            let Some(inspection) = self.inspect_resource(&activation.resource_id)? else {
                continue;
            };
            let Some(payload) = current_payload(&inspection) else {
                continue;
            };
            if payload
                .get("packageId")
                .and_then(Value::as_str)
                .is_some_and(|package_id| package_ids.contains(&package_id))
                || payload
                    .get("packageResourceId")
                    .and_then(Value::as_str)
                    .is_some_and(|resource_id| package_resource_ids.contains(&resource_id))
            {
                affected.push(activation_trust_summary(&inspection)?);
            }
        }
        Ok(affected)
    }
    pub(super) fn decision_refs_for_trust_target(
        &self,
        target_type: &str,
        target_resource_id: &str,
        limit: usize,
    ) -> Result<Vec<Value>> {
        let mut refs = Vec::new();
        if matches!(
            target_type,
            "trust_root"
                | "source_registration"
                | "source_approval"
                | "source_revocation"
                | "decision"
        ) {
            if let Some(inspection) = self.inspect_resource(target_resource_id)? {
                refs.push(decision_summary(&inspection)?);
            }
        }
        let decisions = self.list_resources(ListResources {
            kind: Some("decision".to_owned()),
            scope: None,
            lifecycle: None,
            limit: 500,
        })?;
        for decision in decisions {
            if refs.len() >= limit {
                break;
            }
            let Some(inspection) = self.inspect_resource(&decision.resource_id)? else {
                continue;
            };
            let Some(payload) = current_payload(&inspection) else {
                continue;
            };
            let Some(metadata) = payload.get("metadata").and_then(Value::as_object) else {
                continue;
            };
            let references_target = metadata
                .get("revokedDecisionResourceId")
                .and_then(Value::as_str)
                == Some(target_resource_id)
                || metadata
                    .get("renewedFromDecisionResourceId")
                    .and_then(Value::as_str)
                    == Some(target_resource_id);
            if references_target
                && !refs.iter().any(|item| {
                    item.get("resourceId").and_then(Value::as_str)
                        == Some(decision.resource_id.as_str())
                })
            {
                refs.push(decision_summary(&inspection)?);
            }
        }
        Ok(refs)
    }
    pub(super) fn evidence_refs_for_trust_target(
        &self,
        target_resource_id: &str,
        limit: usize,
    ) -> Result<Vec<Value>> {
        let evidences = self.list_resources(ListResources {
            kind: Some("evidence".to_owned()),
            scope: None,
            lifecycle: None,
            limit: 500,
        })?;
        let mut refs = Vec::new();
        for evidence in evidences {
            if refs.len() >= limit {
                break;
            }
            let Some(inspection) = self.inspect_resource(&evidence.resource_id)? else {
                continue;
            };
            let Some(payload) = current_payload(&inspection) else {
                continue;
            };
            let text = payload.to_string();
            if payload.get("resourceRef").and_then(Value::as_str) == Some(target_resource_id)
                || text.contains(target_resource_id)
            {
                refs.push(json!({
                    "resourceId": evidence.resource_id,
                    "versionId": inspection.resource.current_version_id,
                    "kind": "evidence",
                    "summary": payload.get("summary").cloned().unwrap_or(Value::Null),
                    "evidenceType": payload
                        .get("metadata")
                        .and_then(|metadata| metadata.get("evidenceType"))
                        .cloned()
                        .unwrap_or(Value::Null),
                }));
            }
        }
        Ok(refs)
    }
    pub(super) fn latest_policy_audit_for_trust_target(
        &self,
        target_resource_id: &str,
        affected_packages: &[Value],
    ) -> Result<Value> {
        let mut candidate_ids = vec![target_resource_id.to_owned()];
        candidate_ids.extend(
            affected_packages
                .iter()
                .filter_map(|package| package.get("packageResourceId").and_then(Value::as_str))
                .map(ToOwned::to_owned),
        );
        let evidences = self.list_resources(ListResources {
            kind: Some("evidence".to_owned()),
            scope: None,
            lifecycle: None,
            limit: 500,
        })?;
        for evidence in evidences {
            let Some(inspection) = self.inspect_resource(&evidence.resource_id)? else {
                continue;
            };
            let Some(payload) = current_payload(&inspection) else {
                continue;
            };
            let Some(metadata) = payload.get("metadata").and_then(Value::as_object) else {
                continue;
            };
            if metadata.get("evidenceType").and_then(Value::as_str) != Some("policy_audit") {
                continue;
            }
            let resource_ref = payload.get("resourceRef").and_then(Value::as_str);
            if !resource_ref.is_some_and(|resource_ref| {
                candidate_ids
                    .iter()
                    .any(|candidate| candidate == resource_ref)
            }) {
                continue;
            }
            return Ok(json!({
                "evidenceResourceId": evidence.resource_id,
                "evidenceVersionId": inspection.resource.current_version_id,
                "audit": metadata.get("audit").cloned().unwrap_or(Value::Null),
            }));
        }
        Ok(Value::Null)
    }
    pub(super) fn revocation_enforcement_target(
        &self,
        invocation: &Invocation,
    ) -> Result<(String, Option<String>, Option<String>)> {
        let expected_version =
            optional_string(invocation.payload.get("expectedDecisionVersionId"))?;
        if let Some(revocation_id) =
            optional_string(invocation.payload.get("revocationDecisionResourceId"))?
        {
            let inspection = require_inspection(self, &revocation_id, "decision")?;
            if let Some(expected) = &expected_version {
                ensure_expected_current_version(&inspection, expected)?;
            }
            let payload = current_payload(&inspection).ok_or_else(|| {
                EngineError::PolicyViolation(format!(
                    "revocation decision {revocation_id} has no current payload"
                ))
            })?;
            let metadata = trust_decision_metadata(&payload, "module_source_revocation")?;
            let revoked = required_map_str(metadata, "revokedDecisionResourceId")?.to_owned();
            if !self.revocation_targets_decision(&inspection.resource, &revoked)? {
                return Err(EngineError::PolicyViolation(format!(
                    "decision {revocation_id} is not a valid revocation for {revoked}"
                )));
            }
            return Ok((revoked, Some(revocation_id), expected_version));
        }
        let trust_id = required_string_owned(&invocation.payload, "trustDecisionResourceId")?;
        let inspection = require_inspection(self, &trust_id, "decision")?;
        if let Some(expected) = &expected_version {
            ensure_expected_current_version(&inspection, expected)?;
        }
        let payload = current_payload(&inspection).ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "trust decision {trust_id} has no current payload"
            ))
        })?;
        let status = payload.get("status").and_then(Value::as_str).unwrap_or("");
        if status != "expired" && !self.trust_root_decision_revoked(&trust_id)? {
            return Err(EngineError::PolicyViolation(format!(
                "trust decision {trust_id} is not expired or revoked"
            )));
        }
        Ok((trust_id, None, expected_version))
    }
    pub(super) fn policy_audit(&self, invocation: &Invocation) -> Result<Value> {
        let package_resource_id = required_string_owned(&invocation.payload, "packageResourceId")?;
        let package_version_id = required_string_owned(&invocation.payload, "packageVersionId")?;
        let package = require_inspection(self, &package_resource_id, WORKER_PACKAGE_KIND)?;
        let manifest = version_payload(&package, &package_version_id)?;
        let (_, scope_token) = resource_scope_and_token(invocation)?;
        let child_request = policy_child_request(invocation, &manifest)?;
        self.policy_audit_for_manifest(
            &package_resource_id,
            &package_version_id,
            &manifest,
            &scope_token,
            child_request.as_ref(),
            invocation
                .payload
                .get("includeActivations")
                .and_then(Value::as_bool)
                .unwrap_or(true),
        )
    }
    pub(super) fn policy_audit_for_manifest(
        &self,
        package_resource_id: &str,
        package_version_id: &str,
        manifest: &Value,
        scope_token: &str,
        child_request: Option<&DeriveGrant>,
        include_activations: bool,
    ) -> Result<Value> {
        let evaluation = self.evaluate_source_policy(
            manifest,
            package_resource_id,
            package_version_id,
            scope_token,
            child_request,
        )?;
        let affected_activations = if include_activations {
            self.activations_for_package(package_resource_id)?
        } else {
            Vec::new()
        };
        let mut audit = policy_evaluation_value(evaluation);
        let decision = audit
            .get("decision")
            .and_then(Value::as_str)
            .unwrap_or("deny");
        let recommended_actions = recommended_actions_for_policy(decision, &affected_activations);
        audit["packageResourceId"] = json!(package_resource_id);
        audit["packageVersionId"] = json!(package_version_id);
        audit["packageDigest"] = manifest
            .get("packageDigest")
            .cloned()
            .unwrap_or(Value::Null);
        audit["signatureVerification"] = manifest
            .get("signatureVerification")
            .cloned()
            .unwrap_or(Value::Null);
        audit["affectedActivations"] = json!(affected_activations);
        audit["recommendedActions"] = json!(recommended_actions);
        audit["auditedAt"] = json!(Utc::now().to_rfc3339());
        Ok(audit)
    }
    pub(super) fn activations_for_package(&self, package_resource_id: &str) -> Result<Vec<Value>> {
        let activations = self.list_resources(ListResources {
            kind: Some(ACTIVATION_RECORD_KIND.to_owned()),
            scope: None,
            lifecycle: None,
            limit: 500,
        })?;
        let mut values = Vec::new();
        for activation in activations {
            let Some(inspection) = self.inspect_resource(&activation.resource_id)? else {
                continue;
            };
            let Some(payload) = current_payload(&inspection) else {
                continue;
            };
            if payload.get("packageResourceId").and_then(Value::as_str) != Some(package_resource_id)
            {
                continue;
            }
            values.push(json!({
                "activationResourceId": activation.resource_id,
                "activationVersionId": activation.current_version_id,
                "activationStatus": payload.get("activationStatus").cloned().unwrap_or(Value::Null),
                "workerId": payload.get("workerId").cloned().unwrap_or(Value::Null),
                "derivedGrantId": payload.get("derivedGrantId").cloned().unwrap_or(Value::Null),
            }));
        }
        Ok(values)
    }
    pub(super) fn source_approval_status_for_package(
        &self,
        manifest: &Value,
        package_resource_id: &str,
        package_version_id: &str,
    ) -> Result<&'static str> {
        if source_kind(manifest)? == BUILTIN_PROVENANCE {
            return Ok("not_required");
        }
        let package_digest = required_value_str(manifest, "packageDigest")?;
        let decisions = self.list_resources(ListResources {
            kind: Some("decision".to_owned()),
            scope: None,
            lifecycle: None,
            limit: 500,
        })?;
        let mut saw_revoked = false;
        for decision in decisions {
            let Some(inspection) = self.inspect_resource(&decision.resource_id)? else {
                continue;
            };
            let Some(payload) = current_payload(&inspection) else {
                continue;
            };
            let Some(metadata) = payload.get("metadata").and_then(Value::as_object) else {
                continue;
            };
            let matches_target = metadata.get("decisionType").and_then(Value::as_str)
                == Some("module_source_approval")
                && metadata.get("packageResourceId").and_then(Value::as_str)
                    == Some(package_resource_id)
                && metadata.get("packageVersionId").and_then(Value::as_str)
                    == Some(package_version_id)
                && metadata.get("packageDigest").and_then(Value::as_str) == Some(package_digest);
            if !matches_target {
                continue;
            }
            if payload.get("status").and_then(Value::as_str) == Some("approved")
                && decision.lifecycle != "archived"
                && metadata
                    .get("expiresAt")
                    .and_then(Value::as_str)
                    .map(parse_datetime)
                    .transpose()?
                    .is_some_and(|expires_at| expires_at > Utc::now())
            {
                return Ok("approved");
            }
            saw_revoked = true;
        }
        Ok(if saw_revoked {
            "revoked_or_expired"
        } else {
            "missing"
        })
    }
}

fn signature_key_id(manifest: &Value) -> Result<String> {
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
fn validate_manifest_signature_inputs<F>(manifest: &Value, mut verify_ref: F) -> Result<()>
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
fn signature_bytes_from_manifest(manifest: &Value) -> Result<Vec<u8>> {
    let signature = required_object(manifest.get("signature"), "signature")?;
    let value = required_map_str(signature, "value")?;
    decode_base64_prefixed(value, "signature.value")
}
fn signed_package_message(package_digest: &str) -> String {
    format!("{MANIFEST_SCHEMA_ID}\n{package_digest}")
}
fn decode_base64_prefixed(value: &str, field: &str) -> Result<Vec<u8>> {
    let encoded = value.strip_prefix("base64:").unwrap_or(value);
    BASE64_STANDARD.decode(encoded).map_err(|error| {
        EngineError::PolicyViolation(format!("{field} must be base64 encoded: {error}"))
    })
}
fn verifying_key_from_bytes(bytes: &[u8]) -> Result<VerifyingKey> {
    let key_bytes: [u8; 32] = bytes.try_into().map_err(|_| {
        EngineError::PolicyViolation("ed25519 publicKey must decode to 32 bytes".to_owned())
    })?;
    VerifyingKey::from_bytes(&key_bytes).map_err(|error| {
        EngineError::PolicyViolation(format!("invalid ed25519 publicKey: {error}"))
    })
}
fn key_id_for_public_key(bytes: &[u8]) -> String {
    format!("ed25519:{:x}", Sha256::digest(bytes))
}
fn trust_root_ref(key_id: &str) -> String {
    format!("{TRUST_ROOT_PREFIX}{key_id}")
}
fn source_verification<F>(manifest: &Value, mut verify_ref: F) -> Result<SourceVerification>
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
fn policy_evaluation_value(evaluation: SourcePolicyEvaluation) -> Value {
    json!({
        "decision": evaluation.decision,
        "reasons": evaluation.reasons,
        "missingPrerequisites": evaluation.missing_prerequisites,
        "sourceTrust": evaluation.source_trust,
        "approval": evaluation.approval,
        "conformance": evaluation.conformance,
    })
}
fn policy_child_request(invocation: &Invocation, manifest: &Value) -> Result<Option<DeriveGrant>> {
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
fn recommended_actions_for_policy(decision: &str, affected_activations: &[Value]) -> Vec<Value> {
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
pub(super) fn verify_source_schema() -> Value {
    json!({
        "type": "object",
        "required": ["packageResourceId", "packageVersionId"],
        "additionalProperties": false,
        "properties": {
            "packageResourceId": {"type": "string"},
            "packageVersionId": {"type": "string"},
            "expectedCurrentVersionId": {"type": "string"},
            "mode": {"type": "string", "enum": ["on_demand", "scheduled", "registration"]}
        }
    })
}
pub(super) fn approve_source_schema() -> Value {
    json!({
        "type": "object",
        "required": [
            "packageResourceId",
            "packageVersionId",
            "packageDigest",
            "packageId",
            "scope",
            "trustTierCeiling",
            "grantCeiling",
            "expiresAt",
            "reason"
        ],
        "additionalProperties": false,
        "properties": {
            "packageResourceId": {"type": "string"},
            "packageVersionId": {"type": "string"},
            "packageDigest": {"type": "string"},
            "packageId": {"type": "string"},
            "scope": {"type": "string"},
            "workspaceId": {"type": "string"},
            "sessionId": {"type": "string"},
            "trustTierCeiling": {"type": "string"},
            "grantCeiling": {"type": "object"},
            "expiresAt": {"type": "string"},
            "reason": {"type": "string"}
        }
    })
}
pub(super) fn revoke_source_approval_schema() -> Value {
    json!({
        "type": "object",
        "required": ["decisionResourceId", "reason"],
        "additionalProperties": false,
        "properties": {
            "decisionResourceId": {"type": "string"},
            "expectedCurrentVersionId": {"type": "string"},
            "reason": {"type": "string"}
        }
    })
}
pub(super) fn policy_decide_schema() -> Value {
    json!({
        "type": "object",
        "required": ["packageResourceId", "packageVersionId", "scope"],
        "additionalProperties": false,
        "properties": {
            "packageResourceId": {"type": "string"},
            "packageVersionId": {"type": "string"},
            "scope": {"type": "string"},
            "workspaceId": {"type": "string"},
            "sessionId": {"type": "string"},
            "childGrantRequest": {"type": "object"}
        }
    })
}
pub(super) fn register_source_schema() -> Value {
    json!({
        "type": "object",
        "required": ["sourceKind", "scope", "reason"],
        "additionalProperties": false,
        "properties": {
            "sourceKind": {
                "type": "string",
                "enum": ["local_digest_source", "ed25519_trust_root", "source_revocation"]
            },
            "scope": {"type": "string"},
            "workspaceId": {"type": "string"},
            "sessionId": {"type": "string"},
            "sourceDigest": {"type": "string"},
            "sourceRef": {"type": "object"},
            "publicKey": {"type": "string"},
            "publicKeyEncoding": {"type": "string", "enum": ["base64"]},
            "keyId": {"type": "string"},
            "algorithm": {"type": "string", "enum": ["ed25519"]},
            "allowedPackageSelectors": {"type": "array", "items": {"type": "string"}},
            "trustTierCeiling": {"type": "string"},
            "grantCeiling": {"type": "object"},
            "expiresAt": {"type": "string"},
            "revokedDecisionResourceId": {"type": "string"},
            "expectedCurrentVersionId": {"type": "string"},
            "reason": {"type": "string"}
        }
    })
}
pub(super) fn verify_signature_schema() -> Value {
    json!({
        "type": "object",
        "required": ["packageResourceId", "packageVersionId", "scope"],
        "additionalProperties": false,
        "properties": {
            "packageResourceId": {"type": "string"},
            "packageVersionId": {"type": "string"},
            "expectedCurrentVersionId": {"type": "string"},
            "scope": {"type": "string"},
            "workspaceId": {"type": "string"},
            "sessionId": {"type": "string"}
        }
    })
}
pub(super) fn audit_policy_schema() -> Value {
    json!({
        "type": "object",
        "required": ["packageResourceId", "packageVersionId", "scope"],
        "additionalProperties": false,
        "properties": {
            "packageResourceId": {"type": "string"},
            "packageVersionId": {"type": "string"},
            "scope": {"type": "string"},
            "workspaceId": {"type": "string"},
            "sessionId": {"type": "string"},
            "childGrantRequest": {"type": "object"},
            "includeActivations": {"type": "boolean"}
        }
    })
}
pub(super) fn reconcile_trust_schema() -> Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "scope": {"type": "string"},
            "workspaceId": {"type": "string"},
            "sessionId": {"type": "string"},
            "packageResourceId": {"type": "string"},
            "reason": {"type": "string"}
        }
    })
}
pub(super) fn inspect_trust_schema() -> Value {
    json!({
        "type": "object",
        "required": ["targetType", "targetResourceId"],
        "additionalProperties": false,
        "properties": {
            "targetType": {
                "type": "string",
                "enum": [
                    "trust_root",
                    "source_registration",
                    "source_approval",
                    "source_revocation",
                    "decision",
                    "package",
                    "activation"
                ]
            },
            "targetResourceId": {"type": "string"},
            "targetVersionId": {"type": "string"},
            "scope": {"type": "string"},
            "workspaceId": {"type": "string"},
            "sessionId": {"type": "string"},
            "includeEvidence": {"type": "boolean"},
            "limit": {"type": "integer", "minimum": 1, "maximum": 200}
        }
    })
}
pub(super) fn renew_trust_root_schema() -> Value {
    json!({
        "type": "object",
        "required": [
            "trustRootDecisionResourceId",
            "trustRootDecisionVersionId",
            "expectedCurrentVersionId",
            "expiresAt",
            "allowedPackageSelectors",
            "grantCeiling",
            "trustTierCeiling",
            "reason"
        ],
        "additionalProperties": false,
        "properties": {
            "trustRootDecisionResourceId": {"type": "string"},
            "trustRootDecisionVersionId": {"type": "string"},
            "expectedCurrentVersionId": {"type": "string"},
            "expiresAt": {"type": "string"},
            "allowedPackageSelectors": {"type": "array", "items": {"type": "string"}},
            "grantCeiling": {"type": "object"},
            "trustTierCeiling": {"type": "string"},
            "reason": {"type": "string"}
        }
    })
}
pub(super) fn rotate_signature_key_schema() -> Value {
    json!({
        "type": "object",
        "required": [
            "oldTrustRootDecisionResourceId",
            "oldTrustRootDecisionVersionId",
            "newTrustRootDecisionResourceId",
            "newTrustRootDecisionVersionId",
            "reason"
        ],
        "additionalProperties": false,
        "properties": {
            "oldTrustRootDecisionResourceId": {"type": "string"},
            "oldTrustRootDecisionVersionId": {"type": "string"},
            "newTrustRootDecisionResourceId": {"type": "string"},
            "newTrustRootDecisionVersionId": {"type": "string"},
            "reason": {"type": "string"}
        }
    })
}
pub(super) fn expire_trust_decision_schema() -> Value {
    json!({
        "type": "object",
        "required": ["decisionResourceId", "decisionVersionId", "expectedCurrentVersionId", "reason"],
        "additionalProperties": false,
        "properties": {
            "decisionResourceId": {"type": "string"},
            "decisionVersionId": {"type": "string"},
            "expectedCurrentVersionId": {"type": "string"},
            "reason": {"type": "string"}
        }
    })
}
pub(super) fn enforce_revocation_schema() -> Value {
    json!({
        "type": "object",
        "required": ["mode", "activationResourceIds", "reason"],
        "additionalProperties": false,
        "properties": {
            "trustDecisionResourceId": {"type": "string"},
            "revocationDecisionResourceId": {"type": "string"},
            "expectedDecisionVersionId": {"type": "string"},
            "mode": {"type": "string", "enum": ["disable", "quarantine"]},
            "activationResourceIds": {"type": "array", "items": {"type": "string"}},
            "reason": {"type": "string"}
        }
    })
}
pub(super) fn policy_audit_response_schema() -> Value {
    json!({
        "type": "object",
        "required": ["audit"],
        "additionalProperties": true,
        "properties": {
            "audit": {"type": "object"}
        }
    })
}
