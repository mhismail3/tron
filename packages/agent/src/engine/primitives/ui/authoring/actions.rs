//! Generated UI action authoring.

use super::*;

pub(in crate::engine::primitives::ui::authoring) fn generated_actions(
    host: &dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
    request: &SurfaceAuthoringRequest,
) -> Result<Vec<Value>> {
    let functions = host.discover_functions(&FunctionQuery {
        actor: Some(actor_context(invocation)),
        include_internal: true,
        ..FunctionQuery::default()
    });
    let refresh = functions
        .iter()
        .find(|function| function.id.as_str() == REFRESH_SURFACE_FUNCTION)
        .ok_or_else(|| EngineError::NotFound {
            kind: "function",
            id: REFRESH_SURFACE_FUNCTION.to_owned(),
        })?;
    let mut actions = vec![json!({
        "actionId": "refresh-surface",
        "label": "Refresh",
        "targetFunctionId": REFRESH_SURFACE_FUNCTION,
        "inputSchema": {"type": "object", "additionalProperties": false, "properties": {}},
        "payloadTemplate": {
            "surfaceResourceId": "${surface.resourceId}",
            "expectedCurrentVersionId": "${surface.versionId}"
        },
        "idempotencyKeyTemplate": "${submission.idempotencyKey}",
        "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
        "requiredRisk": risk_label(&refresh.risk_level),
        "approvalPolicy": {"required": refresh.required_authority.approval_required},
        "targetRevision": refresh.revision.0,
        "expiresAt": default_expires_at()
    })];
    if request.target_type == "capability"
        && let Some(action) = capability_invocation_action(invocation, request, &functions)?
    {
        actions.push(action);
    }
    if request.target_type == RESOURCE_COLLECTION_TARGET {
        actions.extend(resource_collection_actions(
            host, invocation, request, &functions,
        )?);
    }
    if request.target_type == SOURCE_CONTROL_TARGET {
        actions.extend(source_control_actions(invocation, request, &functions)?);
    }
    if request.target_type == AGENT_CONTROL_TARGET {
        actions.extend(agent_control_actions(invocation, request, &functions)?);
    }
    if request.target_type == "package" {
        if let Some(inspect_package) = functions
            .iter()
            .find(|function| function.id.as_str() == "module::inspect_package")
        {
            actions.push(json!({
                "actionId": "inspect-package",
                "label": "Inspect Package",
                "targetFunctionId": "module::inspect_package",
                "inputSchema": {"type": "object", "additionalProperties": false, "properties": {}},
                "payloadTemplate": {
                    "packageId": request.target_id.strip_prefix("worker-package:").unwrap_or(&request.target_id)
                },
                "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                "requiredRisk": risk_label(&inspect_package.risk_level),
                "approvalPolicy": {"required": inspect_package.required_authority.approval_required},
                "targetRevision": inspect_package.revision.0,
                "expiresAt": default_expires_at()
            }));
        }
        if let Some(verify_integrity) = functions
            .iter()
            .find(|function| function.id.as_str() == "module::verify_integrity")
        {
            let resource_id = if request.target_id.starts_with("worker-package:") {
                request.target_id.clone()
            } else {
                format!("worker-package:{}", request.target_id)
            };
            if let Some(inspection) = host.inspect_resource(&resource_id)?
                && let Some(version_id) = inspection.resource.current_version_id
            {
                actions.push(json!({
                    "actionId": "verify-package-integrity",
                    "label": "Verify Integrity",
                    "targetFunctionId": "module::verify_integrity",
                    "inputSchema": {"type": "object", "additionalProperties": false, "properties": {}},
                    "payloadTemplate": {
                        "targetType": "worker_package",
                        "resourceId": resource_id,
                        "resourceVersionId": version_id
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&verify_integrity.risk_level),
                    "approvalPolicy": {"required": verify_integrity.required_authority.approval_required},
                    "targetRevision": verify_integrity.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
        }
        let resource_id = if request.target_id.starts_with("worker-package:") {
            request.target_id.clone()
        } else {
            format!("worker-package:{}", request.target_id)
        };
        if let Some(inspection) = host.inspect_resource(&resource_id)?
            && let Some(version_id) = inspection.resource.current_version_id.clone()
        {
            let manifest = current_payload(&inspection).unwrap_or_else(|| json!({}));
            if let Some(verify_source) = functions
                .iter()
                .find(|function| function.id.as_str() == "module::verify_source")
            {
                actions.push(json!({
                    "actionId": "verify-package-source",
                    "label": "Verify Source",
                    "targetFunctionId": "module::verify_source",
                    "inputSchema": {"type": "object", "additionalProperties": false, "properties": {}},
                    "payloadTemplate": {
                        "packageResourceId": resource_id,
                        "packageVersionId": version_id,
                        "expectedCurrentVersionId": version_id,
                        "mode": "on_demand"
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&verify_source.risk_level),
                    "approvalPolicy": {"required": verify_source.required_authority.approval_required},
                    "targetRevision": verify_source.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
            if let Some(register_source) = functions
                .iter()
                .find(|function| function.id.as_str() == "module::register_source")
            {
                if manifest
                    .get("sourceProvenance")
                    .and_then(|source| source.get("kind"))
                    .and_then(Value::as_str)
                    == Some("local_digest_pinned")
                {
                    actions.push(json!({
                        "actionId": "register-local-package-source",
                        "label": "Register Source",
                        "targetFunctionId": "module::register_source",
                        "inputSchema": {
                            "type": "object",
                            "required": ["reason", "expiresAt"],
                            "additionalProperties": false,
                            "properties": {
                                "reason": {"type": "string"},
                                "expiresAt": {"type": "string"}
                            }
                        },
                        "payloadTemplate": {
                            "sourceKind": "local_digest_source",
                            "scope": "system",
                            "sourceDigest": manifest.get("packageDigest").cloned().unwrap_or(Value::Null),
                            "sourceRef": manifest.get("sourceRef").cloned().unwrap_or_else(|| json!({})),
                            "allowedPackageSelectors": [manifest.get("packageId").cloned().unwrap_or(Value::Null)],
                            "grantCeiling": manifest.get("requiredGrants").cloned().unwrap_or_else(|| json!({})),
                            "expiresAt": "${input.expiresAt}",
                            "reason": "${input.reason}"
                        },
                        "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                        "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                        "requiredRisk": risk_label(&register_source.risk_level),
                        "approvalPolicy": {"required": register_source.required_authority.approval_required},
                        "targetRevision": register_source.revision.0,
                        "expiresAt": default_expires_at()
                    }));
                }
                if manifest
                    .get("signature")
                    .is_some_and(|value| !value.is_null())
                {
                    actions.push(json!({
                        "actionId": "register-ed25519-trust-root",
                        "label": "Register Trust Root",
                        "targetFunctionId": "module::register_source",
                        "inputSchema": {
                            "type": "object",
                            "required": ["publicKey", "keyId", "reason", "expiresAt"],
                            "additionalProperties": false,
                            "properties": {
                                "publicKey": {"type": "string"},
                                "keyId": {"type": "string"},
                                "reason": {"type": "string"},
                                "expiresAt": {"type": "string"}
                            }
                        },
                        "payloadTemplate": {
                            "sourceKind": "ed25519_trust_root",
                            "scope": "system",
                            "algorithm": "ed25519",
                            "publicKey": "${input.publicKey}",
                            "keyId": "${input.keyId}",
                            "allowedPackageSelectors": [manifest.get("packageId").cloned().unwrap_or(Value::Null)],
                            "trustTierCeiling": "signed_local",
                            "grantCeiling": manifest.get("requiredGrants").cloned().unwrap_or_else(|| json!({})),
                            "expiresAt": "${input.expiresAt}",
                            "reason": "${input.reason}"
                        },
                        "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                        "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                        "requiredRisk": risk_label(&register_source.risk_level),
                        "approvalPolicy": {"required": register_source.required_authority.approval_required},
                        "targetRevision": register_source.revision.0,
                        "expiresAt": default_expires_at()
                    }));
                }
            }
            if manifest
                .get("signature")
                .is_some_and(|value| !value.is_null())
                && let Some(verify_signature) = functions
                    .iter()
                    .find(|function| function.id.as_str() == "module::verify_signature")
            {
                actions.push(json!({
                    "actionId": "verify-package-signature",
                    "label": "Verify Signature",
                    "targetFunctionId": "module::verify_signature",
                    "inputSchema": {"type": "object", "additionalProperties": false, "properties": {}},
                    "payloadTemplate": {
                        "packageResourceId": resource_id,
                        "packageVersionId": version_id,
                        "expectedCurrentVersionId": version_id,
                        "scope": "system"
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&verify_signature.risk_level),
                    "approvalPolicy": {"required": verify_signature.required_authority.approval_required},
                    "targetRevision": verify_signature.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
            if let Some(audit_policy) = functions
                .iter()
                .find(|function| function.id.as_str() == "module::audit_policy")
            {
                actions.push(json!({
                    "actionId": "audit-package-policy",
                    "label": "Audit Policy",
                    "targetFunctionId": "module::audit_policy",
                    "inputSchema": {"type": "object", "additionalProperties": false, "properties": {}},
                    "payloadTemplate": {
                        "packageResourceId": resource_id,
                        "packageVersionId": version_id,
                        "scope": "system"
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&audit_policy.risk_level),
                    "approvalPolicy": {"required": audit_policy.required_authority.approval_required},
                    "targetRevision": audit_policy.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
            if let Some(record_policy_audit) = functions
                .iter()
                .find(|function| function.id.as_str() == "module::record_policy_audit")
            {
                actions.push(json!({
                    "actionId": "record-package-policy-audit",
                    "label": "Record Audit",
                    "targetFunctionId": "module::record_policy_audit",
                    "inputSchema": {"type": "object", "additionalProperties": false, "properties": {}},
                    "payloadTemplate": {
                        "packageResourceId": resource_id,
                        "packageVersionId": version_id,
                        "scope": "system"
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&record_policy_audit.risk_level),
                    "approvalPolicy": {"required": record_policy_audit.required_authority.approval_required},
                    "targetRevision": record_policy_audit.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
            if let Some(reconcile_trust) = functions
                .iter()
                .find(|function| function.id.as_str() == "module::reconcile_trust")
            {
                actions.push(json!({
                    "actionId": "reconcile-package-trust",
                    "label": "Reconcile Trust",
                    "targetFunctionId": "module::reconcile_trust",
                    "inputSchema": {
                        "type": "object",
                        "required": ["reason"],
                        "additionalProperties": false,
                        "properties": {"reason": {"type": "string"}}
                    },
                    "payloadTemplate": {
                        "scope": "system",
                        "packageResourceId": resource_id,
                        "reason": "${input.reason}"
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&reconcile_trust.risk_level),
                    "approvalPolicy": {"required": reconcile_trust.required_authority.approval_required},
                    "targetRevision": reconcile_trust.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
            if let Some(inspect_trust) = functions
                .iter()
                .find(|function| function.id.as_str() == "module::inspect_trust")
            {
                actions.push(json!({
                    "actionId": "inspect-package-trust",
                    "label": "Inspect Trust",
                    "targetFunctionId": "module::inspect_trust",
                    "inputSchema": {"type": "object", "additionalProperties": false, "properties": {}},
                    "payloadTemplate": {
                        "targetType": "package",
                        "targetResourceId": resource_id,
                        "includeEvidence": true,
                        "limit": 50
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&inspect_trust.risk_level),
                    "approvalPolicy": {"required": inspect_trust.required_authority.approval_required},
                    "targetRevision": inspect_trust.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
            if let Some(simulate_trust) = functions
                .iter()
                .find(|function| function.id.as_str() == "module::simulate_trust_change")
            {
                actions.push(json!({
                    "actionId": "simulate-package-trust",
                    "label": "Simulate Trust",
                    "targetFunctionId": "module::simulate_trust_change",
                    "inputSchema": trust_review_operation_input_schema(false),
                    "payloadTemplate": {
                        "targetType": "package",
                        "targetResourceId": resource_id,
                        "targetVersionId": version_id,
                        "operation": "${input.operation}",
                        "includeGeneratedUi": true,
                        "limit": 50
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&simulate_trust.risk_level),
                    "approvalPolicy": {"required": simulate_trust.required_authority.approval_required},
                    "targetRevision": simulate_trust.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
            if let Some(record_review) = functions
                .iter()
                .find(|function| function.id.as_str() == "module::record_trust_review")
            {
                actions.push(json!({
                    "actionId": "record-package-trust-review",
                    "label": "Record Review",
                    "targetFunctionId": "module::record_trust_review",
                    "inputSchema": trust_review_operation_input_schema(true),
                    "payloadTemplate": {
                        "targetType": "package",
                        "targetResourceId": resource_id,
                        "targetVersionId": version_id,
                        "operation": "${input.operation}",
                        "operatorNotes": "${input.operatorNotes}",
                        "limit": 50
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&record_review.risk_level),
                    "approvalPolicy": {"required": record_review.required_authority.approval_required},
                    "targetRevision": record_review.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
            if let Some(schedule_audit) = functions
                .iter()
                .find(|function| function.id.as_str() == "module::schedule_trust_audit")
            {
                actions.push(json!({
                    "actionId": "schedule-package-trust-audit",
                    "label": "Schedule Audit",
                    "targetFunctionId": "module::schedule_trust_audit",
                    "inputSchema": {
                        "type": "object",
                        "required": ["scheduleId", "cadence", "timezone", "wallClockTime", "expiresAt", "reason"],
                        "additionalProperties": false,
                        "properties": {
                            "scheduleId": {"type": "string"},
                            "cadence": {"type": "string", "enum": ["daily", "weekly"]},
                            "timezone": {"type": "string"},
                            "wallClockTime": {"type": "string"},
                            "dayOfWeek": {"type": "string"},
                            "expiresAt": {"type": "string"},
                            "reason": {"type": "string"}
                        }
                    },
                    "payloadTemplate": {
                        "scheduleId": "${input.scheduleId}",
                        "scope": "system",
                        "selectors": [manifest.get("packageId").cloned().unwrap_or_else(|| json!(resource_id))],
                        "cadence": "${input.cadence}",
                        "timezone": "${input.timezone}",
                        "wallClockTime": "${input.wallClockTime}",
                        "dayOfWeek": "${input.dayOfWeek}",
                        "expiresAt": "${input.expiresAt}",
                        "grantCeiling": manifest.get("requiredGrants").cloned().unwrap_or_else(|| json!({})),
                        "reason": "${input.reason}"
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&schedule_audit.risk_level),
                    "approvalPolicy": {"required": schedule_audit.required_authority.approval_required},
                    "targetRevision": schedule_audit.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
            if let Some(run_conformance) = functions
                .iter()
                .find(|function| function.id.as_str() == "module::run_conformance")
            {
                actions.push(json!({
                    "actionId": "run-package-conformance",
                    "label": "Run Conformance",
                    "targetFunctionId": "module::run_conformance",
                    "inputSchema": {"type": "object", "additionalProperties": false, "properties": {}},
                    "payloadTemplate": {
                        "targetType": "worker_package",
                        "resourceId": resource_id,
                        "resourceVersionId": version_id,
                        "expectedCurrentVersionId": version_id,
                        "mode": "static"
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&run_conformance.risk_level),
                    "approvalPolicy": {"required": run_conformance.required_authority.approval_required},
                    "targetRevision": run_conformance.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
            if manifest
                .get("sourceProvenance")
                .and_then(|source| source.get("kind"))
                .and_then(Value::as_str)
                == Some("local_digest_pinned")
                && manifest.get("sourceTrustStatus").and_then(Value::as_str) == Some("verified")
                && let Some(approve_source) = functions
                    .iter()
                    .find(|function| function.id.as_str() == "module::approve_source")
            {
                actions.push(json!({
                    "actionId": "approve-package-source",
                    "label": "Approve Source",
                    "targetFunctionId": "module::approve_source",
                    "inputSchema": {
                        "type": "object",
                        "required": ["reason", "expiresAt"],
                        "additionalProperties": false,
                        "properties": {
                            "reason": {"type": "string"},
                            "expiresAt": {"type": "string"}
                        }
                    },
                    "payloadTemplate": {
                        "packageResourceId": resource_id,
                        "packageVersionId": version_id,
                        "packageDigest": manifest.get("packageDigest").cloned().unwrap_or(Value::Null),
                        "packageId": manifest.get("packageId").cloned().unwrap_or(Value::Null),
                        "scope": "system",
                        "trustTierCeiling": "local_digest_pinned",
                        "grantCeiling": manifest.get("requiredGrants").cloned().unwrap_or_else(|| json!({})),
                        "expiresAt": "${input.expiresAt}",
                        "reason": "${input.reason}"
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&approve_source.risk_level),
                    "approvalPolicy": {"required": approve_source.required_authority.approval_required},
                    "targetRevision": approve_source.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
        }
    }
    if request.target_type == "decision" {
        let resource_id = request.target_id.clone();
        let inspection =
            host.inspect_resource(&resource_id)?
                .ok_or_else(|| EngineError::NotFound {
                    kind: "resource",
                    id: resource_id.clone(),
                })?;
        let version_id = inspection
            .resource
            .current_version_id
            .clone()
            .ok_or_else(|| EngineError::NotFound {
                kind: "resource_version",
                id: resource_id.clone(),
            })?;
        let decision_payload = current_payload(&inspection).unwrap_or_else(|| json!({}));
        let decision_metadata = decision_payload.get("metadata").and_then(Value::as_object);
        let is_trust_root = decision_metadata
            .and_then(|metadata| metadata.get("decisionType"))
            .and_then(Value::as_str)
            == Some("module_trust_root");
        let is_trust_audit_schedule = decision_metadata
            .and_then(|metadata| metadata.get("decisionType"))
            .and_then(Value::as_str)
            == Some("module_trust_audit_schedule");
        for (action_id, label, target_function, input_schema, payload) in [
            (
                "inspect-trust-decision",
                "Inspect Trust",
                "module::inspect_trust",
                json!({"type": "object", "additionalProperties": false, "properties": {}}),
                json!({
                    "targetType": "decision",
                    "targetResourceId": resource_id,
                    "targetVersionId": version_id,
                    "includeEvidence": true,
                    "limit": 50
                }),
            ),
            (
                "simulate-trust-decision",
                "Simulate",
                "module::simulate_trust_change",
                trust_review_operation_input_schema(false),
                json!({
                    "targetType": "decision",
                    "targetResourceId": resource_id,
                    "targetVersionId": version_id,
                    "operation": "${input.operation}",
                    "includeGeneratedUi": true,
                    "limit": 50
                }),
            ),
            (
                "record-trust-review",
                "Record Review",
                "module::record_trust_review",
                trust_review_operation_input_schema(true),
                json!({
                    "targetType": "decision",
                    "targetResourceId": resource_id,
                    "targetVersionId": version_id,
                    "operation": "${input.operation}",
                    "operatorNotes": "${input.operatorNotes}",
                    "limit": 50
                }),
            ),
            (
                "trust-audit-status",
                "Audit Status",
                "module::trust_audit_status",
                json!({"type": "object", "additionalProperties": false, "properties": {}}),
                json!({
                    "scheduleDecisionResourceId": resource_id,
                    "scheduleDecisionVersionId": version_id,
                    "includeEvidence": true,
                    "includeQueue": true,
                    "limit": 50
                }),
            ),
            (
                "renew-trust-root",
                "Renew",
                "module::renew_trust_root",
                json!({
                    "type": "object",
                    "required": ["expiresAt", "reason"],
                    "additionalProperties": false,
                    "properties": {
                        "expiresAt": {"type": "string"},
                        "reason": {"type": "string"}
                    }
                }),
                json!({
                    "trustRootDecisionResourceId": resource_id,
                    "trustRootDecisionVersionId": version_id,
                    "expectedCurrentVersionId": version_id,
                    "expiresAt": "${input.expiresAt}",
                    "allowedPackageSelectors": decision_metadata
                        .and_then(|metadata| metadata.get("allowedPackageSelectors"))
                        .cloned()
                        .unwrap_or_else(|| json!([])),
                    "grantCeiling": decision_metadata
                        .and_then(|metadata| metadata.get("grantCeiling"))
                        .cloned()
                        .unwrap_or_else(|| json!({})),
                    "trustTierCeiling": "signed_local",
                    "reason": "${input.reason}"
                }),
            ),
            (
                "rotate-signature-key",
                "Rotate",
                "module::rotate_signature_key",
                json!({
                    "type": "object",
                    "required": ["newTrustRootDecisionResourceId", "newTrustRootDecisionVersionId", "reason"],
                    "additionalProperties": false,
                    "properties": {
                        "newTrustRootDecisionResourceId": {"type": "string"},
                        "newTrustRootDecisionVersionId": {"type": "string"},
                        "reason": {"type": "string"}
                    }
                }),
                json!({
                    "oldTrustRootDecisionResourceId": resource_id,
                    "oldTrustRootDecisionVersionId": version_id,
                    "newTrustRootDecisionResourceId": "${input.newTrustRootDecisionResourceId}",
                    "newTrustRootDecisionVersionId": "${input.newTrustRootDecisionVersionId}",
                    "reason": "${input.reason}"
                }),
            ),
            (
                "expire-trust-decision",
                "Expire",
                "module::expire_trust_decision",
                json!({
                    "type": "object",
                    "required": ["reason"],
                    "additionalProperties": false,
                    "properties": {"reason": {"type": "string"}}
                }),
                json!({
                    "decisionResourceId": resource_id,
                    "decisionVersionId": version_id,
                    "expectedCurrentVersionId": version_id,
                    "reason": "${input.reason}"
                }),
            ),
            (
                "enforce-revocation",
                "Enforce",
                "module::enforce_revocation",
                json!({
                    "type": "object",
                    "required": ["mode", "activationResourceIds", "reason"],
                    "additionalProperties": false,
                    "properties": {
                        "mode": {"type": "string", "enum": ["disable", "quarantine"]},
                        "activationResourceIds": {"type": "array", "items": {"type": "string"}},
                        "reason": {"type": "string"}
                    }
                }),
                json!({
                    "trustDecisionResourceId": resource_id,
                    "expectedDecisionVersionId": version_id,
                    "mode": "${input.mode}",
                    "activationResourceIds": "${input.activationResourceIds}",
                    "reason": "${input.reason}"
                }),
            ),
            (
                "run-scheduled-trust-audit",
                "Run Audit",
                "module::run_scheduled_trust_audit",
                json!({
                    "type": "object",
                    "required": ["dueBucket"],
                    "additionalProperties": false,
                    "properties": {"dueBucket": {"type": "string"}}
                }),
                json!({
                    "scheduleDecisionResourceId": resource_id,
                    "scheduleDecisionVersionId": version_id,
                    "dueBucket": "${input.dueBucket}"
                }),
            ),
            (
                "record-trust-audit-retention",
                "Review Retention",
                "module::record_trust_audit_retention",
                json!({
                    "type": "object",
                    "required": ["olderThan", "reason"],
                    "additionalProperties": false,
                    "properties": {
                        "olderThan": {"type": "string"},
                        "reason": {"type": "string"}
                    }
                }),
                json!({
                    "scheduleDecisionResourceId": resource_id,
                    "scheduleDecisionVersionId": version_id,
                    "olderThan": "${input.olderThan}",
                    "reason": "${input.reason}"
                }),
            ),
        ] {
            if matches!(
                target_function,
                "module::renew_trust_root"
                    | "module::rotate_signature_key"
                    | "module::enforce_revocation"
            ) && !is_trust_root
            {
                continue;
            }
            if matches!(
                target_function,
                "module::trust_audit_status"
                    | "module::run_scheduled_trust_audit"
                    | "module::record_trust_audit_retention"
            ) && !is_trust_audit_schedule
            {
                continue;
            }
            if let Some(function) = functions
                .iter()
                .find(|function| function.id.as_str() == target_function)
            {
                actions.push(json!({
                    "actionId": action_id,
                    "label": label,
                    "targetFunctionId": target_function,
                    "inputSchema": input_schema,
                    "payloadTemplate": payload,
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&function.risk_level),
                    "approvalPolicy": {"required": function.required_authority.approval_required},
                    "targetRevision": function.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
        }
    }
    if request.target_type == "activation" {
        let resource_id = if request.target_id.starts_with("activation:") {
            request.target_id.clone()
        } else {
            format!("activation:{}", request.target_id)
        };
        let version_id = host
            .inspect_resource(&resource_id)?
            .and_then(|inspection| inspection.resource.current_version_id)
            .ok_or_else(|| EngineError::NotFound {
                kind: "resource_version",
                id: resource_id.clone(),
            })?;
        for (action_id, label, target_function, payload) in [
            (
                "check-activation-health",
                "Check Health",
                "module::check_health",
                json!({
                    "activationResourceId": resource_id,
                    "activationVersionId": version_id,
                    "expectedCurrentVersionId": version_id,
                    "mode": "on_demand"
                }),
            ),
            (
                "verify-activation-integrity",
                "Verify Integrity",
                "module::verify_integrity",
                json!({
                    "targetType": "activation_record",
                    "resourceId": resource_id,
                    "resourceVersionId": version_id,
                    "expectedCurrentVersionId": version_id
                }),
            ),
            (
                "recover-activation",
                "Recover",
                "module::recover_activation",
                json!({
                    "activationResourceId": resource_id,
                    "expectedCurrentVersionId": version_id,
                    "reason": "operator requested recovery from generated surface"
                }),
            ),
        ] {
            if let Some(target) = functions
                .iter()
                .find(|function| function.id.as_str() == target_function)
            {
                actions.push(json!({
                    "actionId": action_id,
                    "label": label,
                    "targetFunctionId": target_function,
                    "inputSchema": {"type": "object", "additionalProperties": false, "properties": {}},
                    "payloadTemplate": payload,
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&target.risk_level),
                    "approvalPolicy": {"required": target.required_authority.approval_required},
                    "targetRevision": target.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
        }
    }
    Ok(actions
        .into_iter()
        .map(with_stored_action_consequence)
        .collect())
}

fn resource_collection_actions(
    host: &dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
    request: &SurfaceAuthoringRequest,
    functions: &[FunctionDefinition],
) -> Result<Vec<Value>> {
    match (request.target_id.as_str(), request.layout_profile.as_str()) {
        (PROMPT_SNIPPET_COLLECTION_TARGET, PROMPT_SNIPPET_LAYOUT_PROFILE) => {
            prompt_snippet_collection_actions(host, invocation, functions)
        }
        (PROMPT_HISTORY_COLLECTION_TARGET, PROMPT_HISTORY_LAYOUT_PROFILE) => {
            prompt_history_collection_actions(host, invocation, functions)
        }
        (NOTIFICATION_COLLECTION_TARGET, NOTIFICATION_INBOX_LAYOUT_PROFILE) => {
            notification_collection_actions(host, invocation, functions)
        }
        (SUBAGENT_COLLECTION_TARGET, SUBAGENT_LINEAGE_LAYOUT_PROFILE) => {
            subagent_collection_actions(host, invocation, request, functions)
        }
        _ => Ok(Vec::new()),
    }
}

pub(in crate::engine::primitives::ui::authoring) fn push_optional_action(
    actions: &mut Vec<Value>,
    invocation: &crate::engine::Invocation,
    functions: &[FunctionDefinition],
    action_id: &str,
    label: &str,
    target_function: &str,
    input_schema: Value,
    payload_template: Value,
) -> Result<()> {
    if functions
        .iter()
        .any(|function| function.id.as_str() == target_function)
    {
        actions.push(prompt_collection_action(
            invocation,
            functions,
            action_id,
            label,
            target_function,
            input_schema,
            payload_template,
        )?);
    }
    Ok(())
}

fn capability_invocation_action(
    invocation: &crate::engine::Invocation,
    request: &SurfaceAuthoringRequest,
    functions: &[FunctionDefinition],
) -> Result<Option<Value>> {
    let Some(target) = functions
        .iter()
        .find(|function| function.id.as_str() == request.target_id)
    else {
        return Err(EngineError::NotFound {
            kind: "function",
            id: request.target_id.clone(),
        });
    };
    if target.id.as_str() == SUBMIT_ACTION_FUNCTION {
        return Ok(None);
    }
    let Some((input_schema, payload_template)) = capability_input_schema_and_template(target)
    else {
        return Ok(None);
    };
    Ok(Some(json!({
        "actionId": "invoke-capability",
        "label": "Invoke",
        "targetFunctionId": target.id.as_str(),
        "inputSchema": input_schema,
        "payloadTemplate": payload_template,
        "idempotencyKeyTemplate": "${submission.idempotencyKey}",
        "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
        "requiredRisk": risk_label(&target.risk_level),
        "approvalPolicy": {"required": target.required_authority.approval_required},
        "targetRevision": target.revision.0,
        "expiresAt": default_expires_at()
    })))
}

fn capability_input_schema_and_template(target: &FunctionDefinition) -> Option<(Value, Value)> {
    let Some(schema) = &target.request_schema else {
        return Some((
            json!({"type": "object", "additionalProperties": false, "properties": {}}),
            json!({}),
        ));
    };
    if !schema
        .get("type")
        .is_none_or(|schema_type| schema_type == "object")
    {
        return None;
    }
    let properties = schema
        .get("properties")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    let required = schema
        .get("required")
        .and_then(Value::as_array)
        .map(|fields| {
            fields
                .iter()
                .map(|field| field.as_str().map(ToOwned::to_owned))
                .collect::<Option<Vec<_>>>()
        })
        .unwrap_or_else(|| Some(Vec::new()))?;
    let mut input_properties = serde_json::Map::new();
    let mut payload_template = serde_json::Map::new();
    for field in &required {
        let property = properties.get(field)?;
        if !capability_schema_field_is_renderable(property) {
            return None;
        }
        input_properties.insert(field.clone(), property.clone());
        payload_template.insert(field.clone(), json!(format!("${{input.{field}}}")));
    }
    Some((
        json!({
            "type": "object",
            "required": required,
            "additionalProperties": false,
            "properties": input_properties
        }),
        Value::Object(payload_template),
    ))
}

fn capability_schema_field_is_renderable(schema: &Value) -> bool {
    let Some(kind) = schema.get("type").and_then(Value::as_str) else {
        return schema.get("enum").and_then(Value::as_array).is_some();
    };
    matches!(kind, "string" | "boolean" | "integer")
}

pub(in crate::engine::primitives::ui::authoring) fn prompt_collection_action(
    invocation: &crate::engine::Invocation,
    functions: &[FunctionDefinition],
    action_id: &str,
    label: &str,
    target_function: &str,
    input_schema: Value,
    payload_template: Value,
) -> Result<Value> {
    let target = functions
        .iter()
        .find(|function| function.id.as_str() == target_function)
        .ok_or_else(|| EngineError::NotFound {
            kind: "function",
            id: target_function.to_owned(),
        })?;
    Ok(json!({
        "actionId": action_id,
        "label": label,
        "targetFunctionId": target_function,
        "inputSchema": input_schema,
        "payloadTemplate": payload_template,
        "idempotencyKeyTemplate": "${submission.idempotencyKey}",
        "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
        "requiredRisk": risk_label(&target.risk_level),
        "approvalPolicy": {"required": target.required_authority.approval_required},
        "targetRevision": target.revision.0,
        "expiresAt": default_expires_at()
    }))
}
