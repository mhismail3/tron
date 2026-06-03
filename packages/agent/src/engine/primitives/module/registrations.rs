//! Module primitive function registration catalogue.

use super::*;

pub(in crate::engine::primitives) fn registrations(
    stores: &PrimitiveStores,
) -> Result<Vec<PrimitiveFunctionRegistration>> {
    let handler = Arc::new(ModulePrimitiveHandler {
        stores: stores.clone(),
    });
    Ok(vec![
        module_write(
            REGISTER_PACKAGE_FUNCTION,
            "register and validate a worker package manifest",
            register_package_schema(),
            module_resource_response_schema("worker_package"),
            RiskLevel::Medium,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            WORKER_PACKAGE_KIND,
        ])),
        module_read(
            INSPECT_PACKAGE_FUNCTION,
            "inspect one registered worker package and its activation state",
            inspect_package_schema(),
            json!({
                "type": "object",
                "required": ["package", "configs", "activations", "diagnostics", "availableActions"],
                "additionalProperties": false,
                "properties": {
                    "package": {"type": ["object", "null"]},
                    "configs": {"type": "array"},
                    "activations": {"type": "array"},
                    "diagnostics": {"type": "object"},
                    "availableActions": {"type": "array"}
                }
            }),
        ),
        module_write(
            CONFIGURE_FUNCTION,
            "validate and persist module configuration",
            configure_schema(),
            module_resource_response_schema("module_config"),
            RiskLevel::Medium,
        )
        .with_output_contract(DurableOutputContract::resource_backed([MODULE_CONFIG_KIND])),
        module_write(
            ACTIVATE_FUNCTION,
            "derive an activation grant and bind a package to a worker",
            activate_schema(),
            module_resource_response_schema("activation_record"),
            RiskLevel::High,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            ACTIVATION_RECORD_KIND,
        ])),
        module_write(
            DISABLE_FUNCTION,
            "disable an active package activation and revoke its grant",
            disable_schema(),
            module_resource_response_schema("activation_record"),
            RiskLevel::High,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            ACTIVATION_RECORD_KIND,
        ])),
        module_write(
            UPGRADE_FUNCTION,
            "replace an activation with a validated package/config pair",
            upgrade_schema(),
            module_resource_response_schema("activation_record"),
            RiskLevel::High,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            ACTIVATION_RECORD_KIND,
        ])),
        module_write(
            ROLLBACK_FUNCTION,
            "create a new activation version from a prior valid activation version",
            rollback_schema(),
            module_resource_response_schema("activation_record"),
            RiskLevel::High,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            ACTIVATION_RECORD_KIND,
        ])),
        module_write(
            QUARANTINE_FUNCTION,
            "quarantine a package or activation and revoke live authority",
            quarantine_schema(),
            module_resource_response_schema("activation_record"),
            RiskLevel::High,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            WORKER_PACKAGE_KIND,
            ACTIVATION_RECORD_KIND,
        ])),
        module_write(
            REMOVE_PACKAGE_FUNCTION,
            "remove a local pack after live activations are disabled",
            remove_package_schema(),
            module_resource_response_schema("worker_package"),
            RiskLevel::High,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            WORKER_PACKAGE_KIND,
            MODULE_CONFIG_KIND,
        ])),
        module_write(
            CHECK_HEALTH_FUNCTION,
            "record resource-backed module activation health evidence",
            check_health_schema(),
            module_resource_response_schema("activation_record"),
            RiskLevel::Medium,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            "evidence",
            ACTIVATION_RECORD_KIND,
        ])),
        module_write(
            VERIFY_INTEGRITY_FUNCTION,
            "record resource-backed package, config, or activation integrity evidence",
            verify_integrity_schema(),
            module_resource_response_schema("evidence"),
            RiskLevel::Medium,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            "evidence",
            ACTIVATION_RECORD_KIND,
        ])),
        module_write(
            RECOVER_ACTIVATION_FUNCTION,
            "materialize recovery evidence and clean unsafe activation authority",
            recover_activation_schema(),
            module_resource_response_schema("activation_record"),
            RiskLevel::High,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            "evidence",
            ACTIVATION_RECORD_KIND,
        ])),
        module_write(
            VERIFY_SOURCE_FUNCTION,
            "verify package source refs, digest, signature metadata, and trust evidence",
            verify_source_schema(),
            module_resource_response_schema("evidence"),
            RiskLevel::Medium,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            "evidence",
            WORKER_PACKAGE_KIND,
        ])),
        module_write(
            APPROVE_SOURCE_FUNCTION,
            "record a scoped operator source approval decision",
            approve_source_schema(),
            module_resource_response_schema("decision"),
            RiskLevel::High,
        )
        .with_output_contract(DurableOutputContract::resource_backed(["decision"])),
        module_write(
            REVOKE_SOURCE_APPROVAL_FUNCTION,
            "revoke a scoped operator source approval decision",
            revoke_source_approval_schema(),
            module_resource_response_schema("decision"),
            RiskLevel::High,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            "decision", "evidence",
        ])),
        module_read(
            POLICY_DECIDE_FUNCTION,
            "evaluate source and activation policy without mutating state",
            policy_decide_schema(),
            json!({
                "type": "object",
                "required": ["decision", "reasons", "missingPrerequisites", "sourceTrust", "approval", "conformance"],
                "additionalProperties": true,
                "properties": {
                    "decision": {"type": "string", "enum": ["allow", "deny", "quarantine_required"]},
                    "reasons": {"type": "array", "items": {"type": "string"}},
                    "missingPrerequisites": {"type": "array", "items": {"type": "string"}},
                    "sourceTrust": {"type": "object"},
                    "approval": {"type": "object"},
                    "conformance": {"type": "object"}
                }
            }),
        ),
        module_write(
            RUN_CONFORMANCE_FUNCTION,
            "record bounded package runtime conformance evidence",
            run_conformance_schema(),
            module_resource_response_schema("evidence"),
            RiskLevel::Medium,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            "evidence",
            WORKER_PACKAGE_KIND,
            ACTIVATION_RECORD_KIND,
        ])),
        module_write(
            REGISTER_SOURCE_FUNCTION,
            "register a local package source or trust root as resource-backed decisions and evidence",
            register_source_schema(),
            module_resource_response_schema("decision"),
            RiskLevel::High,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            "decision", "evidence",
        ])),
        module_write(
            VERIFY_SIGNATURE_FUNCTION,
            "verify a package Ed25519 signature against local trust-root decisions",
            verify_signature_schema(),
            module_resource_response_schema("evidence"),
            RiskLevel::Medium,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            "evidence",
            WORKER_PACKAGE_KIND,
        ])),
        module_read(
            AUDIT_POLICY_FUNCTION,
            "reconstruct package source policy from durable substrate truth",
            audit_policy_schema(),
            policy_audit_response_schema(),
        ),
        module_write(
            RECORD_POLICY_AUDIT_FUNCTION,
            "persist a bounded package source-policy audit evidence record",
            audit_policy_schema(),
            module_resource_response_schema("evidence"),
            RiskLevel::Medium,
        )
        .with_output_contract(DurableOutputContract::resource_backed(["evidence"])),
        module_write(
            RECONCILE_TRUST_FUNCTION,
            "record trust reconciliation evidence without mutating package runtime state",
            reconcile_trust_schema(),
            module_resource_response_schema("evidence"),
            RiskLevel::Medium,
        )
        .with_output_contract(DurableOutputContract::resource_backed(["evidence"])),
        module_read(
            INSPECT_TRUST_FUNCTION,
            "inspect package trust, source, approval, revocation, and activation dependencies",
            inspect_trust_schema(),
            json!({
                "type": "object",
                "required": ["target", "status", "dependencyGraph", "affectedPackages", "affectedActivations", "availableActions"],
                "additionalProperties": true,
                "properties": {
                    "target": {"type": "object"},
                    "status": {"type": "string"},
                    "dependencyGraph": {"type": "object"},
                    "affectedPackages": {"type": "array"},
                    "affectedActivations": {"type": "array"},
                    "availableActions": {"type": "array"}
                }
            }),
        ),
        module_write(
            RENEW_TRUST_ROOT_FUNCTION,
            "renew a same-key module trust-root decision with equal-or-narrower policy",
            renew_trust_root_schema(),
            module_resource_response_schema("decision"),
            RiskLevel::High,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            "decision", "evidence",
        ])),
        module_write(
            ROTATE_SIGNATURE_KEY_FUNCTION,
            "record signature-key rotation lineage between two active trust roots",
            rotate_signature_key_schema(),
            module_resource_response_schema("evidence"),
            RiskLevel::High,
        )
        .with_output_contract(DurableOutputContract::resource_backed(["evidence"])),
        module_write(
            EXPIRE_TRUST_DECISION_FUNCTION,
            "expire a module source, trust-root, or approval decision without deleting bytes",
            expire_trust_decision_schema(),
            module_resource_response_schema("decision"),
            RiskLevel::High,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            "decision", "evidence",
        ])),
        module_write(
            ENFORCE_REVOCATION_FUNCTION,
            "enforce revoked trust by composing canonical module disable or quarantine invocations",
            enforce_revocation_schema(),
            module_resource_response_schema("evidence"),
            RiskLevel::High,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            "evidence",
            ACTIVATION_RECORD_KIND,
        ])),
        module_read(
            SIMULATE_TRUST_CHANGE_FUNCTION,
            "simulate module trust changes without mutating package or activation state",
            simulate_trust_change_schema(),
            trust_review_response_schema(),
        ),
        module_write(
            RECORD_TRUST_REVIEW_FUNCTION,
            "persist bounded evidence for a recomputed module trust review",
            record_trust_review_schema(),
            module_resource_response_schema("evidence"),
            RiskLevel::Medium,
        )
        .with_output_contract(DurableOutputContract::resource_backed(["evidence"])),
        module_read(
            TRUST_AUDIT_STATUS_FUNCTION,
            "project status for a decision-backed module trust audit schedule",
            trust_audit_status_schema(),
            json!({
                "type": "object",
                "required": ["schedule", "due", "warnings", "retentionWarnings", "availableActions"],
                "additionalProperties": true,
                "properties": {
                    "schedule": {"type": "object"},
                    "due": {"type": "object"},
                    "warnings": {"type": "array"},
                    "retentionWarnings": {"type": "array"},
                    "availableActions": {"type": "array"}
                }
            }),
        ),
        module_write(
            SCHEDULE_TRUST_AUDIT_FUNCTION,
            "create or CAS-update a decision-backed module trust audit schedule",
            schedule_trust_audit_schema(),
            module_resource_response_schema("decision"),
            RiskLevel::Medium,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            "decision", "evidence",
        ])),
        module_write(
            RUN_SCHEDULED_TRUST_AUDIT_FUNCTION,
            "run a decision-backed module trust audit and persist bounded evidence",
            run_scheduled_trust_audit_schema(),
            module_resource_response_schema("evidence"),
            RiskLevel::Medium,
        )
        .with_output_contract(DurableOutputContract::resource_backed(["evidence"])),
        module_write(
            RECORD_TRUST_AUDIT_RETENTION_FUNCTION,
            "persist bounded retention-review evidence for scheduled trust audits",
            record_trust_audit_retention_schema(),
            module_resource_response_schema("evidence"),
            RiskLevel::Medium,
        )
        .with_output_contract(DurableOutputContract::resource_backed(["evidence"])),
    ]
    .into_iter()
    .map(|definition| handled_registration(definition, handler.clone()))
    .collect())
}

fn module_read(
    id: &str,
    description: &str,
    request_schema: Value,
    response_schema: Value,
) -> FunctionDefinition {
    let mut definition = primitive_function(
        id,
        MODULE_WORKER_ID,
        description,
        EffectClass::PureRead,
        "module.read",
    )
    .with_request_schema(request_schema)
    .with_response_schema(response_schema);
    definition.visibility = VisibilityScope::System;
    definition
}

fn module_write(
    id: &str,
    description: &str,
    request_schema: Value,
    response_schema: Value,
    risk: RiskLevel,
) -> FunctionDefinition {
    let resource_id_template = module_write_lease_template(id);
    let mut definition = primitive_function(
        id,
        MODULE_WORKER_ID,
        description,
        EffectClass::IdempotentWrite,
        "module.write",
    )
    .with_idempotency(IdempotencyContract::caller_system_engine_ledger())
    .with_resource_lease(ResourceLeaseRequirement::exclusive_template(
        "module",
        resource_id_template,
        600000,
    ))
    .with_compensation(primitive_compensation(
        CompensationKind::ManualOnly,
        "module lifecycle writes are recovered through explicit disable, rollback, quarantine, trust revocation, or evidence review capabilities",
    ))
    .with_request_schema(request_schema)
    .with_response_schema(response_schema)
    .with_risk(risk);
    if risk >= RiskLevel::High {
        definition.required_authority = definition.required_authority.with_approval_required();
    }
    definition.visibility = VisibilityScope::System;
    definition
}

fn module_write_lease_template(function_id: &str) -> &'static str {
    match function_id {
        REGISTER_PACKAGE_FUNCTION => "module:package:{manifest.packageId}",
        CONFIGURE_FUNCTION => "module:config:{scope}:{packageResourceId}",
        ACTIVATE_FUNCTION => "module:activation:{scope}:{packageResourceId}",
        DISABLE_FUNCTION | UPGRADE_FUNCTION | ROLLBACK_FUNCTION | CHECK_HEALTH_FUNCTION => {
            "module:activation:{activationResourceId}"
        }
        REMOVE_PACKAGE_FUNCTION => "module:package:{packageResourceId}",
        QUARANTINE_FUNCTION | VERIFY_INTEGRITY_FUNCTION | RUN_CONFORMANCE_FUNCTION => {
            "module:resource:{resourceId}"
        }
        RECOVER_ACTIVATION_FUNCTION
        | REGISTER_SOURCE_FUNCTION
        | RECONCILE_TRUST_FUNCTION
        | ENFORCE_REVOCATION_FUNCTION
        | SCHEDULE_TRUST_AUDIT_FUNCTION => "module:operation:{idempotencyKey}",
        VERIFY_SOURCE_FUNCTION | VERIFY_SIGNATURE_FUNCTION | RECORD_POLICY_AUDIT_FUNCTION => {
            "module:package:{packageResourceId}"
        }
        APPROVE_SOURCE_FUNCTION => "module:source-approval:{scope}:{packageResourceId}",
        REVOKE_SOURCE_APPROVAL_FUNCTION | EXPIRE_TRUST_DECISION_FUNCTION => {
            "module:decision:{decisionResourceId}"
        }
        RENEW_TRUST_ROOT_FUNCTION => "module:decision:{trustRootDecisionResourceId}",
        ROTATE_SIGNATURE_KEY_FUNCTION => "module:decision:{oldTrustRootDecisionResourceId}",
        RUN_SCHEDULED_TRUST_AUDIT_FUNCTION | RECORD_TRUST_AUDIT_RETENTION_FUNCTION => {
            "module:decision:{scheduleDecisionResourceId}"
        }
        _ => "module:operation:{idempotencyKey}",
    }
}
