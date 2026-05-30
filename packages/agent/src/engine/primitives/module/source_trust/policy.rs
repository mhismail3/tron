//! Source trust policy, audit, and lookup operations.

use super::support::*;
use super::*;

impl ModulePrimitiveHandler {
    pub(in crate::engine::primitives::module) fn audit_policy(
        &self,
        invocation: &Invocation,
    ) -> Result<Value> {
        Ok(json!({
            "audit": self.policy_audit(invocation)?,
        }))
    }
    pub(in crate::engine::primitives::module) fn record_policy_audit(
        &self,
        invocation: &Invocation,
    ) -> Result<Value> {
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
    pub(in crate::engine::primitives::module) fn reconcile_trust(
        &self,
        invocation: &Invocation,
    ) -> Result<Value> {
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

    pub(in crate::engine::primitives::module) fn policy_decide(
        &self,
        invocation: &Invocation,
    ) -> Result<Value> {
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
    pub(in crate::engine::primitives::module) fn ensure_activation_source_policy(
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
    pub(in crate::engine::primitives::module) fn active_source_approval(
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
    pub(in crate::engine::primitives::module::source_trust) fn active_trust_root(
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
    pub(in crate::engine::primitives::module) fn trust_root_decision_revoked(
        &self,
        decision_resource_id: &str,
    ) -> Result<bool> {
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
    pub(in crate::engine::primitives::module) fn revocation_targets_decision(
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
    pub(in crate::engine::primitives::module) fn active_trust_root_decision(
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

    pub(in crate::engine::primitives::module) fn revocation_enforcement_target(
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
    pub(in crate::engine::primitives::module) fn policy_audit(
        &self,
        invocation: &Invocation,
    ) -> Result<Value> {
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
    pub(in crate::engine::primitives::module) fn policy_audit_for_manifest(
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

    pub(in crate::engine::primitives::module) fn source_approval_status_for_package(
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
