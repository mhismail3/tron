//! Source trust inspection and dependency projection operations.

use super::*;

impl ModulePrimitiveHandler {
    pub(in crate::engine::primitives::module) fn inspect_trust(
        &self,
        invocation: &Invocation,
    ) -> Result<Value> {
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
    pub(in crate::engine::primitives::module) fn trust_target_summary(
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
    pub(in crate::engine::primitives::module) fn affected_packages_for_trust_target(
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
    pub(in crate::engine::primitives::module) fn affected_activations_for_packages(
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
    pub(in crate::engine::primitives::module) fn decision_refs_for_trust_target(
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
    pub(in crate::engine::primitives::module) fn evidence_refs_for_trust_target(
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
    pub(in crate::engine::primitives::module) fn latest_policy_audit_for_trust_target(
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
    pub(in crate::engine::primitives::module) fn activations_for_package(
        &self,
        package_resource_id: &str,
    ) -> Result<Vec<Value>> {
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
}
