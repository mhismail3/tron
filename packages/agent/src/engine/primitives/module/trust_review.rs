use super::*;

pub(crate) const SIMULATE_TRUST_CHANGE_FUNCTION: &str = "module::simulate_trust_change";
pub(crate) const RECORD_TRUST_REVIEW_FUNCTION: &str = "module::record_trust_review";
pub(crate) const TRUST_REVIEW_OPERATIONS: &[&str] = &[
    "expire",
    "renew",
    "rotate",
    "revoke",
    "enforce_disable",
    "enforce_quarantine",
    "approve_source",
    "reconcile",
];

impl ModulePrimitiveHandler {
    pub(super) fn simulate_trust_change(&self, invocation: &Invocation) -> Result<Value> {
        self.resolve_trust_review(invocation, &invocation.payload)
    }

    pub(super) fn record_trust_review(&self, invocation: &Invocation) -> Result<Value> {
        let review = self.resolve_trust_review(invocation, &invocation.payload)?;
        let target_resource_id = required_string_owned(&invocation.payload, "targetResourceId")?;
        let operator_notes =
            if let Some(notes) = optional_string(invocation.payload.get("operatorNotes"))? {
                reject_raw_secrets(&json!({"operatorNotes": notes}))?;
                json!(truncate_utf8_bytes(notes, 2048))
            } else {
                Value::Null
            };
        let evidence = self.create_evidence_resource(
            invocation,
            &format!("module trust review recorded for {target_resource_id}"),
            RECORD_TRUST_REVIEW_FUNCTION,
            &target_resource_id,
            json!({
                "evidenceType": "trust_review",
                "review": bounded_json(&review, 16 * 1024),
                "operatorNotes": operator_notes,
                "recordedAt": Utc::now().to_rfc3339(),
            }),
        )?;
        self.link_required(
            &evidence.resource.resource_id,
            &target_resource_id,
            "evidence_for",
            invocation,
        )?;
        for package in review
            .get("affectedPackages")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            if let Some(package_id) = package.get("packageResourceId").and_then(Value::as_str) {
                self.link_required(
                    &evidence.resource.resource_id,
                    package_id,
                    "affects_package",
                    invocation,
                )?;
            }
        }
        for activation in review
            .get("affectedActivations")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            if let Some(activation_id) = activation
                .get("activationResourceId")
                .and_then(Value::as_str)
            {
                self.link_required(
                    &evidence.resource.resource_id,
                    activation_id,
                    "affects_activation",
                    invocation,
                )?;
            }
        }
        Ok(json!({
            "review": review,
            "evidence": evidence.resource,
            "resourceRefs": [evidence.reference],
        }))
    }

    fn resolve_trust_review(&self, invocation: &Invocation, payload: &Value) -> Result<Value> {
        let target_type = required_value_str(payload, "targetType")?;
        let target_resource_id = required_string_owned(payload, "targetResourceId")?;
        let operation = required_value_str(payload, "operation")?;
        validate_trust_review_operation(operation)?;
        let limit = payload
            .get("limit")
            .and_then(Value::as_u64)
            .unwrap_or(50)
            .clamp(1, 200) as usize;
        let include_generated_ui = payload
            .get("includeGeneratedUi")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        if let Some(bounds) = payload.get("proposedBounds") {
            reject_raw_secrets(bounds)?;
        }
        let target = self.trust_target_summary(target_type, &target_resource_id)?;
        let affected_packages =
            self.affected_packages_for_trust_target(target_type, &target_resource_id, limit)?;
        let affected_activations =
            self.affected_activations_for_packages(&affected_packages, limit)?;
        let decision_refs =
            self.decision_refs_for_trust_target(target_type, &target_resource_id, limit)?;
        let evidence_refs = self.evidence_refs_for_trust_target(&target_resource_id, limit)?;
        let grant_refs = affected_activations
            .iter()
            .filter_map(|activation| activation.get("derivedGrantId").and_then(Value::as_str))
            .map(|grant_id| json!({"grantId": grant_id}))
            .collect::<Vec<_>>();
        let ui_surface_refs = if include_generated_ui {
            self.ui_surface_refs_for_trust_review(
                target_type,
                &target_resource_id,
                &affected_packages,
                &affected_activations,
                limit,
            )?
        } else {
            Vec::new()
        };

        let mut decision = "allow";
        let mut reasons = Vec::new();
        let mut missing = Vec::new();
        let mut warnings = Vec::new();
        let mut policy_deltas = Vec::new();
        let mut grant_deltas = Vec::new();

        match operation {
            "renew" => {
                if !target_is_active_trust_root(&target) {
                    decision = "blocked";
                    missing.push(json!("active_trust_root"));
                    warnings.push(json!({
                        "code": "target_not_active_trust_root",
                        "message": "renew requires an active module_trust_root decision",
                    }));
                }
                if let Some(bounds) = payload.get("proposedBounds").and_then(Value::as_object) {
                    if let Err(error) =
                        self.validate_proposed_trust_bounds(invocation, &target, bounds)
                    {
                        decision = "blocked";
                        reasons.push(json!(error.to_string()));
                        warnings.push(json!({
                            "code": "proposed_bounds_exceed_current",
                            "message": error.to_string(),
                        }));
                    }
                } else {
                    missing.push(json!("proposedBounds"));
                    policy_deltas.push(json!({
                        "field": "expiresAt",
                        "change": "required_for_renewal",
                    }));
                }
            }
            "rotate" => {
                if !target_is_active_trust_root(&target) {
                    decision = "blocked";
                    missing.push(json!("active_trust_root"));
                }
                if payload
                    .get("proposedBounds")
                    .and_then(|bounds| bounds.get("newTrustRootDecisionResourceId"))
                    .is_none()
                {
                    missing.push(json!("newTrustRootDecisionResourceId"));
                    policy_deltas.push(json!({
                        "field": "signatureKeyRef",
                        "change": "new package signatures required before rotated trust satisfies packages",
                    }));
                }
            }
            "expire" | "revoke" => {
                if trust_target_status(target.get("payload").unwrap_or(&Value::Null)) == "stale" {
                    decision = "noop";
                    warnings.push(json!({
                        "code": "trust_already_stale",
                        "message": "target trust decision is already stale",
                    }));
                }
                if !affected_activations.is_empty() {
                    policy_deltas.push(json!({
                        "field": "activationPolicy",
                        "change": "affected activations become stale until explicit enforcement",
                    }));
                }
            }
            "enforce_disable" | "enforce_quarantine" => {
                let requested = if payload.get("activationResourceIds").is_some() {
                    string_array_from(
                        payload.get("activationResourceIds"),
                        "activationResourceIds",
                    )?
                } else {
                    Vec::new()
                };
                if requested.is_empty() {
                    decision = "blocked";
                    missing.push(json!("activationResourceIds"));
                }
                let affected_ids = affected_activations
                    .iter()
                    .filter_map(|activation| {
                        activation
                            .get("activationResourceId")
                            .and_then(Value::as_str)
                    })
                    .collect::<Vec<_>>();
                for activation_id in requested {
                    if !affected_ids
                        .iter()
                        .any(|affected| *affected == activation_id)
                    {
                        decision = "blocked";
                        warnings.push(json!({
                            "code": "activation_not_affected",
                            "activationResourceId": activation_id,
                        }));
                    }
                }
                grant_deltas.push(json!({
                    "change": if operation == "enforce_disable" { "disable" } else { "quarantine" },
                    "affectedGrantCount": grant_refs.len(),
                }));
            }
            "approve_source" => {
                if target_type != "package" {
                    decision = "blocked";
                    missing.push(json!("package_target"));
                }
                let source_status = target
                    .get("payload")
                    .and_then(|payload| payload.get("sourceTrustStatus"))
                    .and_then(Value::as_str)
                    .unwrap_or(SOURCE_STATUS_UNVERIFIED);
                if !matches!(
                    source_status,
                    SOURCE_STATUS_VERIFIED
                        | SOURCE_STATUS_SIGNATURE_VERIFIED
                        | SOURCE_STATUS_TRUSTED_BUILTIN
                ) {
                    decision = "blocked";
                    missing.push(json!("source_verification"));
                }
            }
            "reconcile" => {
                policy_deltas.push(json!({
                    "field": "trustRecommendations",
                    "change": "recompute stale trust and recommended canonical actions",
                }));
            }
            _ => unreachable!("operation is validated"),
        }

        let recommended_actions = recommended_actions_for_trust_review(
            operation,
            decision,
            target_type,
            &target_resource_id,
            &affected_activations,
        );
        Ok(json!({
            "decision": decision,
            "operation": operation,
            "target": target,
            "affectedPackages": affected_packages,
            "affectedActivations": affected_activations,
            "affectedGrants": grant_refs,
            "affectedWorkers": workers_from_activation_refs(&affected_activations),
            "uiSurfaceRefs": ui_surface_refs,
            "decisionRefs": decision_refs,
            "evidenceRefs": evidence_refs,
            "policyDeltas": policy_deltas,
            "grantDeltas": grant_deltas,
            "reasons": reasons,
            "missingPrerequisites": missing,
            "staleRefs": stale_refs_for_review(&decision_refs),
            "warnings": warnings,
            "recommendedActions": recommended_actions,
            "simulatedAt": Utc::now().to_rfc3339(),
        }))
    }

    fn validate_proposed_trust_bounds(
        &self,
        invocation: &Invocation,
        target: &Value,
        bounds: &serde_json::Map<String, Value>,
    ) -> Result<()> {
        let payload = target.get("payload").unwrap_or(&Value::Null);
        let metadata = payload.get("metadata").and_then(Value::as_object);
        if let Some(selectors) = bounds.get("allowedPackageSelectors") {
            let requested = string_array_from(Some(selectors), "allowedPackageSelectors")?;
            let current = metadata
                .and_then(|metadata| metadata.get("allowedPackageSelectors"))
                .map(|value| string_array_from(Some(value), "allowedPackageSelectors"))
                .transpose()?
                .unwrap_or_default();
            if !current.is_empty() {
                ensure_subset(&requested, &current, "proposed trust selectors")?;
            }
        }
        if let Some(ceiling) = bounds.get("grantCeiling") {
            let requested = ceiling.as_object().ok_or_else(|| {
                EngineError::PolicyViolation("proposed grantCeiling must be an object".to_owned())
            })?;
            if let Some(current) = metadata
                .and_then(|metadata| metadata.get("grantCeiling"))
                .and_then(Value::as_object)
            {
                ensure_grant_ceiling_within_ceiling(
                    requested,
                    current,
                    "proposed trust grant ceiling",
                )?;
            }
            ensure_grant_ceiling_narrows_caller(self, invocation, requested)?;
        }
        if let Some(trust_tier) = bounds.get("trustTierCeiling").and_then(Value::as_str) {
            let current = metadata
                .and_then(|metadata| metadata.get("trustTierCeiling"))
                .and_then(Value::as_str)
                .unwrap_or(SIGNED_LOCAL_TRUST);
            if trust_tier != current {
                return Err(EngineError::PolicyViolation(
                    "proposed trustTierCeiling exceeds or changes current trust tier".to_owned(),
                ));
            }
        }
        if let Some(expires_at) = bounds.get("expiresAt").and_then(Value::as_str)
            && parse_datetime(expires_at)? <= Utc::now()
        {
            return Err(EngineError::PolicyViolation(
                "proposed expiresAt must be in the future".to_owned(),
            ));
        }
        Ok(())
    }

    fn ui_surface_refs_for_trust_review(
        &self,
        target_type: &str,
        target_resource_id: &str,
        packages: &[Value],
        activations: &[Value],
        limit: usize,
    ) -> Result<Vec<Value>> {
        let resources = self.list_resources(ListResources {
            kind: Some("ui_surface".to_owned()),
            scope: None,
            lifecycle: None,
            limit: 500,
        })?;
        let mut target_ids = vec![target_resource_id.to_owned()];
        target_ids.extend(
            packages
                .iter()
                .filter_map(|package| package.get("packageResourceId").and_then(Value::as_str))
                .map(ToOwned::to_owned),
        );
        target_ids.extend(
            packages
                .iter()
                .filter_map(|package| package.get("packageId").and_then(Value::as_str))
                .map(ToOwned::to_owned),
        );
        target_ids.extend(
            activations
                .iter()
                .filter_map(|activation| {
                    activation
                        .get("activationResourceId")
                        .and_then(Value::as_str)
                })
                .map(ToOwned::to_owned),
        );
        let mut refs = Vec::new();
        for resource in resources {
            if refs.len() >= limit {
                break;
            }
            let Some(inspection) = self.inspect_resource(&resource.resource_id)? else {
                continue;
            };
            let Some(payload) = current_payload(&inspection) else {
                continue;
            };
            let authoring = payload.get("authoring").and_then(Value::as_object);
            let surface_target_type = authoring
                .and_then(|authoring| authoring.get("targetType"))
                .and_then(Value::as_str);
            let surface_target_id = authoring
                .and_then(|authoring| authoring.get("targetId"))
                .and_then(Value::as_str);
            let matches_target = surface_target_id
                .is_some_and(|id| target_ids.iter().any(|target| target == id))
                || surface_target_type == Some(target_type)
                    && surface_target_id == Some(target_resource_id);
            if matches_target {
                refs.push(json!({
                    "resourceId": resource.resource_id,
                    "versionId": inspection.resource.current_version_id,
                    "lifecycle": inspection.resource.lifecycle,
                }));
            }
        }
        Ok(refs)
    }
}

fn validate_trust_review_operation(operation: &str) -> Result<()> {
    if TRUST_REVIEW_OPERATIONS.contains(&operation) {
        Ok(())
    } else {
        Err(EngineError::PolicyViolation(format!(
            "unsupported trust review operation {operation}"
        )))
    }
}

fn target_is_active_trust_root(target: &Value) -> bool {
    let Some(payload) = target.get("payload") else {
        return false;
    };
    payload.get("status").and_then(Value::as_str) == Some("active")
        && payload
            .get("metadata")
            .and_then(|metadata| metadata.get("decisionType"))
            .and_then(Value::as_str)
            == Some("module_trust_root")
}

fn workers_from_activation_refs(activations: &[Value]) -> Vec<Value> {
    activations
        .iter()
        .filter_map(|activation| {
            activation
                .get("workerId")
                .and_then(Value::as_str)
                .map(|worker_id| {
                    json!({
                        "workerId": worker_id,
                        "activationResourceId": activation.get("activationResourceId").cloned().unwrap_or(Value::Null),
                    })
                })
        })
        .collect()
}

fn stale_refs_for_review(decision_refs: &[Value]) -> Vec<Value> {
    decision_refs
        .iter()
        .filter(|reference| {
            matches!(
                reference.get("status").and_then(Value::as_str),
                Some("expired" | "revoked" | "rejected")
            ) || reference.get("lifecycle").and_then(Value::as_str) == Some("archived")
        })
        .cloned()
        .collect()
}

fn recommended_actions_for_trust_review(
    operation: &str,
    decision: &str,
    target_type: &str,
    target_resource_id: &str,
    activations: &[Value],
) -> Vec<Value> {
    let mut actions = vec![json!({
        "functionId": SIMULATE_TRUST_CHANGE_FUNCTION,
        "targetType": target_type,
        "targetField": "targetResourceId",
        "target": target_resource_id,
        "requiredRisk": "low",
        "approvalRequired": false,
    })];
    actions.push(json!({
        "functionId": RECORD_TRUST_REVIEW_FUNCTION,
        "targetType": target_type,
        "targetField": "targetResourceId",
        "target": target_resource_id,
        "requiredRisk": "medium",
        "approvalRequired": false,
    }));
    if decision == "blocked" {
        return actions;
    }
    match operation {
        "renew" => actions.push(json!({
            "functionId": RENEW_TRUST_ROOT_FUNCTION,
            "targetType": "trust_root",
            "targetField": "trustRootDecisionResourceId",
            "target": target_resource_id,
            "requiredRisk": "high",
            "approvalRequired": true,
        })),
        "rotate" => actions.push(json!({
            "functionId": ROTATE_SIGNATURE_KEY_FUNCTION,
            "targetType": "trust_root",
            "targetField": "oldTrustRootDecisionResourceId",
            "target": target_resource_id,
            "requiredRisk": "high",
            "approvalRequired": true,
        })),
        "expire" => actions.push(json!({
            "functionId": EXPIRE_TRUST_DECISION_FUNCTION,
            "targetType": "decision",
            "targetField": "decisionResourceId",
            "target": target_resource_id,
            "requiredRisk": "high",
            "approvalRequired": true,
        })),
        "revoke" | "enforce_disable" | "enforce_quarantine" => {
            if !activations.is_empty() {
                actions.push(json!({
                    "functionId": ENFORCE_REVOCATION_FUNCTION,
                    "targetType": "decision",
                    "targetField": "trustDecisionResourceId",
                    "target": target_resource_id,
                    "requiredRisk": "high",
                    "approvalRequired": true,
                }));
            }
        }
        "approve_source" => actions.push(json!({
            "functionId": APPROVE_SOURCE_FUNCTION,
            "targetType": "package",
            "targetField": "packageResourceId",
            "target": target_resource_id,
            "requiredRisk": "high",
            "approvalRequired": true,
        })),
        "reconcile" => actions.push(json!({
            "functionId": RECONCILE_TRUST_FUNCTION,
            "targetType": target_type,
            "targetField": "targetResourceId",
            "target": target_resource_id,
            "requiredRisk": "medium",
            "approvalRequired": false,
        })),
        _ => {}
    }
    actions
}

pub(super) fn simulate_trust_change_schema() -> Value {
    json!({
        "type": "object",
        "required": ["targetType", "targetResourceId", "operation"],
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
            "operation": {
                "type": "string",
                "enum": TRUST_REVIEW_OPERATIONS
            },
            "proposedBounds": {"type": "object"},
            "activationResourceIds": {"type": "array", "items": {"type": "string"}},
            "scope": {"type": "string"},
            "workspaceId": {"type": "string"},
            "sessionId": {"type": "string"},
            "includeGeneratedUi": {"type": "boolean"},
            "limit": {"type": "integer", "minimum": 1, "maximum": 200}
        }
    })
}

pub(super) fn record_trust_review_schema() -> Value {
    let mut schema = simulate_trust_change_schema();
    schema["properties"]["operatorNotes"] = json!({"type": "string"});
    schema
}

pub(super) fn trust_review_response_schema() -> Value {
    json!({
        "type": "object",
        "required": ["decision", "operation", "target", "affectedPackages", "affectedActivations", "recommendedActions"],
        "additionalProperties": true,
        "properties": {
            "decision": {"type": "string", "enum": ["allow", "deny", "blocked", "noop"]},
            "operation": {"type": "string"},
            "target": {"type": "object"},
            "affectedPackages": {"type": "array"},
            "affectedActivations": {"type": "array"},
            "recommendedActions": {"type": "array"}
        }
    })
}
