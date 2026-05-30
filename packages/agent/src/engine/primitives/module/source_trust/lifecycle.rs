//! Trust-root lifecycle and revocation enforcement operations.

use super::*;

impl ModulePrimitiveHandler {
    pub(in crate::engine::primitives::module) fn renew_trust_root(
        &self,
        invocation: &Invocation,
    ) -> Result<Value> {
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
    pub(in crate::engine::primitives::module) fn rotate_signature_key(
        &self,
        invocation: &Invocation,
    ) -> Result<Value> {
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
    pub(in crate::engine::primitives::module) fn expire_trust_decision(
        &self,
        invocation: &Invocation,
    ) -> Result<Value> {
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
    pub(in crate::engine::primitives::module) async fn enforce_revocation(
        &self,
        invocation: &Invocation,
    ) -> Result<Value> {
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
}
