//! Package source approval operations.

use super::*;

impl ModulePrimitiveHandler {
    pub(in crate::engine::primitives::module) fn approve_source(
        &self,
        invocation: &Invocation,
    ) -> Result<Value> {
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
    pub(in crate::engine::primitives::module) fn revoke_source_approval(
        &self,
        invocation: &Invocation,
    ) -> Result<Value> {
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
}
