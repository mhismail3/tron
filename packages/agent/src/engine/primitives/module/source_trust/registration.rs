//! Source trust registration operations.

use super::support::*;
use super::*;

impl ModulePrimitiveHandler {
    pub(in crate::engine::primitives::module) fn register_source(
        &self,
        invocation: &Invocation,
    ) -> Result<Value> {
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
    pub(in crate::engine::primitives::module) fn register_ed25519_trust_root(
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
    pub(in crate::engine::primitives::module) fn register_local_digest_source(
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
    pub(in crate::engine::primitives::module) fn register_source_revocation(
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
}
