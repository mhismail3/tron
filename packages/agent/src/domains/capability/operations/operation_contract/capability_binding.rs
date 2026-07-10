//! Closed structural contracts for capability binding, shadow, and route governance.
//!
//! The capability-binding domain remains the semantic owner for policy,
//! lifecycle, stale-version, authority, and evidence validation. These schemas
//! are the single provider-visible top-level field contracts consumed by both
//! catalog inspection and the pre-authority runtime gate.

use serde_json::{Value, json};

use super::{
    bounded_integer_schema, closed_schema, idempotency_schema, network_policy_none_schema,
    string_schema,
};

pub(super) fn input_schema(operation: &str) -> Option<Value> {
    let (required, fields) = match operation {
        "capability_binding_request_record" => (
            vec![
                "operation",
                "title",
                "targetOperation",
                "currentBuiltInOwner",
                "ownershipClass",
                "replacementTarget",
                "bindingMode",
                "targetRef",
                "actorScope",
                "rationale",
                "contractRequirements",
                "authorityConstraints",
                "staleVersionGuard",
                "idempotencyKey",
            ],
            binding_request_fields(),
        ),
        "capability_binding_request_list"
        | "capability_binding_decision_list"
        | "capability_binding_policy_list"
        | "capability_replacement_candidate_list"
        | "capability_route_binding_list"
        | "capability_route_event_list" => (vec!["operation"], list_fields()),
        "capability_binding_request_inspect" => (
            vec!["operation", "capabilityBindingRequestResourceId"],
            inspect_fields("capabilityBindingRequestResourceId"),
        ),
        "capability_binding_decision_record" => (
            vec![
                "operation",
                "capabilityBindingRequestResourceId",
                "expectedCapabilityBindingRequestVersionId",
                "decision",
                "reason",
                "idempotencyKey",
            ],
            binding_decision_fields(),
        ),
        "capability_binding_decision_inspect" => (
            vec!["operation", "capabilityBindingDecisionResourceId"],
            inspect_fields("capabilityBindingDecisionResourceId"),
        ),
        "capability_binding_policy_activate" => (
            vec![
                "operation",
                "capabilityBindingDecisionResourceId",
                "expectedCapabilityBindingDecisionVersionId",
                "reason",
                "idempotencyKey",
            ],
            binding_policy_fields(),
        ),
        "capability_binding_policy_inspect" => (
            vec!["operation", "capabilityBindingPolicyResourceId"],
            inspect_fields("capabilityBindingPolicyResourceId"),
        ),
        "capability_binding_cockpit_overview" => (
            vec!["operation"],
            vec![
                (
                    "targetOperation",
                    string_schema(
                        "Optional exact provider-visible operation name. Supply it to return one compact cockpit row with owner, binding, shadow, route, verification, and rollback state.",
                    ),
                ),
                (
                    "limit",
                    bounded_integer_schema(
                        1,
                        crate::domains::capability_binding::contract::COCKPIT_OVERVIEW_MAX_LIMIT
                            as u64,
                        "Maximum broad cockpit operation rows.",
                    ),
                ),
            ],
        ),
        "capability_shadow_trial_request_record" => (
            vec![
                "operation",
                "title",
                "targetOperation",
                "currentBuiltInOwner",
                "ownershipClass",
                "replacementTarget",
                "bindingMode",
                "candidateAdapter",
                "authorityConstraints",
                "contractEvidenceRefs",
                "evidenceRefs",
                "staleVersionGuard",
                "rollbackRef",
                "disableRef",
                "abortRef",
                "rationale",
                "idempotencyKey",
            ],
            shadow_request_fields(),
        ),
        "capability_shadow_trial_decision_record" => (
            vec![
                "operation",
                "capabilityShadowTrialRequestResourceId",
                "expectedCapabilityShadowTrialRequestVersionId",
                "decision",
                "reason",
                "idempotencyKey",
            ],
            shadow_decision_fields(),
        ),
        "capability_shadow_trial_run_record" => (
            vec![
                "operation",
                "capabilityShadowTrialDecisionResourceId",
                "expectedCapabilityShadowTrialDecisionVersionId",
                "builtInProjection",
                "candidateProjection",
                "idempotencyKey",
            ],
            shadow_run_fields(),
        ),
        "capability_shadow_trial_evidence_inspect" => (
            vec!["operation", "capabilityShadowTrialEvidenceResourceId"],
            vec![
                (
                    "capabilityShadowTrialEvidenceResourceId",
                    resource_id_schema(),
                ),
                (
                    "expectedCapabilityShadowTrialEvidenceVersionId",
                    version_id_schema(),
                ),
            ],
        ),
        "capability_replacement_candidate_record" => (
            vec![
                "operation",
                "targetOperation",
                "currentBuiltInOwner",
                "ownershipClass",
                "replacementTarget",
                "candidateLabel",
                "candidateOwner",
                "moduleRef",
                "moduleLifecycleRef",
                "moduleRuntimeRef",
                "shadowEvidenceRef",
                "contractEvidenceRefs",
                "authorityConstraints",
                "rollbackRef",
                "disableRef",
                "idempotencyKey",
            ],
            replacement_candidate_fields(),
        ),
        "capability_replacement_candidate_inspect" => (
            vec!["operation", "capabilityReplacementCandidateResourceId"],
            inspect_fields("capabilityReplacementCandidateResourceId"),
        ),
        "capability_route_binding_record" => (
            vec![
                "operation",
                "capabilityReplacementCandidateResourceId",
                "expectedCapabilityReplacementCandidateVersionId",
                "routeVersion",
                "idempotencyKey",
            ],
            route_binding_fields(),
        ),
        "capability_route_binding_inspect" => (
            vec!["operation", "capabilityRouteBindingResourceId"],
            inspect_fields("capabilityRouteBindingResourceId"),
        ),
        "capability_route_activate" => (
            vec![
                "operation",
                "capabilityRouteBindingResourceId",
                "expectedCapabilityRouteBindingVersionId",
                "reason",
                "approvalRefs",
                "idempotencyKey",
            ],
            route_control_fields(false),
        ),
        "capability_route_disable" | "capability_route_rollback" => (
            vec![
                "operation",
                "capabilityRouteBindingResourceId",
                "expectedCapabilityRouteBindingVersionId",
                "capabilityRouteActivationResourceId",
                "expectedCapabilityRouteActivationVersionId",
                "reason",
                "idempotencyKey",
            ],
            route_control_fields(true),
        ),
        "capability_route_event_inspect" => (
            vec!["operation", "capabilityRouteEventResourceId"],
            inspect_fields("capabilityRouteEventResourceId"),
        ),
        _ => return None,
    };
    Some(closed_schema(operation, &required, fields))
}

fn binding_request_fields() -> Vec<(&'static str, Value)> {
    let mut fields = target_metadata_fields();
    fields.extend([
        ("title", string_schema("Provider-safe request title.")),
        ("bindingMode", enum_string(&["shadow", "extend", "replace"])),
        ("targetRef", reference_schema()),
        ("actorScope", enum_string(&["session", "workspace"])),
        (
            "rationale",
            string_schema("Provider-safe binding rationale."),
        ),
        ("contractRequirements", object_schema()),
        ("authorityConstraints", authority_schema()),
        ("staleVersionGuard", object_schema()),
        ("rollbackRef", reference_schema()),
        ("disableRef", reference_schema()),
        ("auditRefs", refs_schema()),
        (
            "capabilityBindingRequestId",
            string_schema("Optional stable request id."),
        ),
        (
            "lifecycleState",
            enum_string(&["pending_review", "disabled", "archived"]),
        ),
        ("idempotencyKey", idempotency_schema()),
    ]);
    fields
}

fn binding_decision_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("capabilityBindingRequestResourceId", resource_id_schema()),
        (
            "expectedCapabilityBindingRequestVersionId",
            version_id_schema(),
        ),
        ("decision", enum_string(&["approved", "rejected", "denied"])),
        (
            "reason",
            string_schema("Provider-safe governance decision reason."),
        ),
        ("denialEvidence", refs_schema()),
        (
            "capabilityBindingDecisionId",
            string_schema("Optional stable decision id."),
        ),
        (
            "lifecycleState",
            enum_string(&["approved_policy", "rejected", "archived"]),
        ),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn binding_policy_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("capabilityBindingDecisionResourceId", resource_id_schema()),
        (
            "expectedCapabilityBindingDecisionVersionId",
            version_id_schema(),
        ),
        ("reason", string_schema("Provider-safe activation reason.")),
        (
            "capabilityBindingPolicyId",
            string_schema("Optional stable policy id."),
        ),
        (
            "lifecycleState",
            enum_string(&["active", "disabled", "superseded", "archived"]),
        ),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn shadow_request_fields() -> Vec<(&'static str, Value)> {
    let mut fields = target_metadata_fields();
    fields.extend([
        ("title", string_schema("Provider-safe trial title.")),
        ("bindingMode", enum_string(&["shadow"])),
        ("candidateAdapter", object_schema()),
        ("authorityConstraints", authority_schema()),
        ("contractEvidenceRefs", refs_schema()),
        ("evidenceRefs", refs_schema()),
        ("staleVersionGuard", object_schema()),
        ("rollbackRef", reference_schema()),
        ("disableRef", reference_schema()),
        ("abortRef", reference_schema()),
        (
            "rationale",
            string_schema("Provider-safe shadow rationale."),
        ),
        ("auditRefs", refs_schema()),
        (
            "capabilityShadowTrialRequestId",
            string_schema("Optional stable request id."),
        ),
        (
            "lifecycleState",
            enum_string(&["pending_review", "disabled", "aborted"]),
        ),
        ("idempotencyKey", idempotency_schema()),
    ]);
    fields
}

fn shadow_decision_fields() -> Vec<(&'static str, Value)> {
    vec![
        (
            "capabilityShadowTrialRequestResourceId",
            resource_id_schema(),
        ),
        (
            "expectedCapabilityShadowTrialRequestVersionId",
            version_id_schema(),
        ),
        (
            "decision",
            enum_string(&["approved", "rejected", "denied", "disabled", "aborted"]),
        ),
        (
            "reason",
            string_schema("Provider-safe trial decision reason."),
        ),
        ("decisionEvidence", refs_schema()),
        ("denialEvidence", refs_schema()),
        (
            "capabilityShadowTrialDecisionId",
            string_schema("Optional stable decision id."),
        ),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn shadow_run_fields() -> Vec<(&'static str, Value)> {
    vec![
        (
            "capabilityShadowTrialDecisionResourceId",
            resource_id_schema(),
        ),
        (
            "expectedCapabilityShadowTrialDecisionVersionId",
            version_id_schema(),
        ),
        (
            "builtInProjection",
            shadow_git_status_projection_schema("builtInProjection"),
        ),
        (
            "candidateProjection",
            shadow_git_status_projection_schema("candidateProjection"),
        ),
        (
            "trialRunOutcome",
            enum_string(&["completed", "aborted", "disabled"]),
        ),
        (
            "capabilityShadowTrialRunId",
            string_schema("Optional stable run id."),
        ),
        (
            "capabilityShadowTrialEvidenceId",
            string_schema("Optional stable evidence id."),
        ),
        ("auditRefs", refs_schema()),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn shadow_git_status_projection_schema(field: &str) -> Value {
    json!({
        "type": "object",
        "description": format!(
            "{field} is a bounded provider-safe git_status projection for a metadata-only shadow comparison; never include raw commands, raw paths, logs, file contents, grants, or authority ids."
        ),
        "required": [
            "operation",
            "status",
            "headState",
            "indexState",
            "worktreeState",
            "evidenceRef"
        ],
        "properties": {
            "operation": {"const": "git_status"},
            "status": {"type": "string", "enum": ["clean", "dirty", "unavailable", "unknown"]},
            "headState": {"type": "string", "enum": ["known", "unknown"]},
            "indexState": {"type": "string", "enum": ["known", "unknown"]},
            "worktreeState": {"type": "string", "enum": ["clean", "dirty", "unknown"]},
            "truncation": {"type": "string", "enum": ["none", "bounded", "truncated", "unknown"]},
            "evidenceRef": {
                "type": "object",
                "description": "Concrete bounded evidence ref for this shadow projection; placeholder evidence:none is rejected.",
                "required": ["kind", "resourceId", "role"],
                "properties": {
                    "kind": {"type": "string"},
                    "resourceId": {"type": "string"},
                    "role": {"type": "string"}
                },
                "additionalProperties": false
            }
        },
        "additionalProperties": false
    })
}

fn replacement_candidate_fields() -> Vec<(&'static str, Value)> {
    let mut fields = target_metadata_fields();
    fields.extend([
        (
            "candidateLabel",
            string_schema("Provider-safe candidate label."),
        ),
        (
            "candidateOwner",
            string_schema("Exact candidate module owner."),
        ),
        ("moduleRef", reference_schema()),
        ("moduleLifecycleRef", versioned_reference_schema()),
        ("moduleRuntimeRef", versioned_reference_schema()),
        ("shadowEvidenceRef", versioned_reference_schema()),
        ("contractEvidenceRefs", refs_schema()),
        ("authorityConstraints", authority_schema()),
        ("rollbackRef", reference_schema()),
        ("disableRef", reference_schema()),
        ("auditRefs", refs_schema()),
        (
            "capabilityReplacementCandidateId",
            string_schema("Optional stable candidate id."),
        ),
        (
            "lifecycleState",
            enum_string(&["validated", "rejected", "disabled"]),
        ),
        ("idempotencyKey", idempotency_schema()),
    ]);
    fields
}

fn route_binding_fields() -> Vec<(&'static str, Value)> {
    vec![
        (
            "capabilityReplacementCandidateResourceId",
            resource_id_schema(),
        ),
        (
            "expectedCapabilityReplacementCandidateVersionId",
            version_id_schema(),
        ),
        ("routeVersion", string_schema("Exact route version.")),
        (
            "capabilityRouteBindingId",
            string_schema("Optional stable route binding id."),
        ),
        ("lifecycleState", enum_string(&["ready", "disabled"])),
        ("auditRefs", refs_schema()),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn route_control_fields(include_activation: bool) -> Vec<(&'static str, Value)> {
    let mut fields = vec![
        ("capabilityRouteBindingResourceId", resource_id_schema()),
        (
            "expectedCapabilityRouteBindingVersionId",
            version_id_schema(),
        ),
        (
            "reason",
            string_schema("Provider-safe route control reason."),
        ),
        ("approvalRefs", refs_schema()),
        ("auditRefs", refs_schema()),
        (
            "capabilityRouteActivationId",
            string_schema("Optional stable activation id."),
        ),
        (
            "capabilityRouteRollbackId",
            string_schema("Optional stable rollback id."),
        ),
        ("idempotencyKey", idempotency_schema()),
    ];
    if include_activation {
        fields.extend([
            ("capabilityRouteActivationResourceId", resource_id_schema()),
            (
                "expectedCapabilityRouteActivationVersionId",
                version_id_schema(),
            ),
        ]);
    }
    fields
}

fn list_fields() -> Vec<(&'static str, Value)> {
    vec![
        (
            "limit",
            bounded_integer_schema(1, 500, "Maximum records returned."),
        ),
        ("includeArchived", json!({"type": "boolean"})),
        ("lifecycle", string_schema("Optional lifecycle filter.")),
    ]
}

fn inspect_fields(field: &'static str) -> Vec<(&'static str, Value)> {
    vec![(field, resource_id_schema())]
}

fn target_metadata_fields() -> Vec<(&'static str, Value)> {
    vec![
        (
            "targetOperation",
            string_schema("Exact provider-visible target operation."),
        ),
        (
            "currentBuiltInOwner",
            string_schema("Exact current owner from the capability registry."),
        ),
        (
            "ownershipClass",
            enum_string(&[
                "kernel_locked",
                "governance_locked",
                "record_plane",
                "adapter_replaceable",
                "module_owned",
                "deferred",
            ]),
        ),
        (
            "replacementTarget",
            string_schema("Exact replacement target from the capability registry."),
        ),
    ]
}

fn resource_id_schema() -> Value {
    string_schema(
        "Exact current-scope resource id returned by the corresponding record or list operation.",
    )
}

fn version_id_schema() -> Value {
    string_schema("Exact current resource version id; stale versions fail closed.")
}

fn object_schema() -> Value {
    json!({"type": "object"})
}

fn reference_schema() -> Value {
    json!({
        "type": "object",
        "required": ["kind", "resourceId"],
        "properties": {
            "kind": {"type": "string"},
            "resourceId": {"type": "string"},
            "role": {"type": "string"}
        }
    })
}

fn versioned_reference_schema() -> Value {
    json!({
        "type": "object",
        "required": ["kind", "resourceId", "versionId"],
        "properties": {
            "kind": {"type": "string"},
            "resourceId": {"type": "string"},
            "versionId": {"type": "string"},
            "role": {"type": "string"}
        }
    })
}

fn authority_schema() -> Value {
    json!({
        "type": "object",
        "required": ["networkPolicy", "authorityScopes", "resourceKinds", "resourceSelectors"],
        "properties": {
            "networkPolicy": network_policy_none_schema(),
            "authorityScopes": {"type": "array", "items": {"type": "string"}},
            "resourceKinds": {"type": "array", "items": {"type": "string"}},
            "resourceSelectors": {"type": "array", "items": {"type": "string"}},
            "agentStateInherited": {"type": "boolean"}
        }
    })
}

fn refs_schema() -> Value {
    json!({"type": "array", "maxItems": 25, "items": {"type": "object"}})
}

fn enum_string(values: &[&str]) -> Value {
    json!({"type": "string", "enum": values})
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::super::validate_payload;

    #[test]
    fn binding_request_contract_rejects_missing_governance_preflight() {
        let error = validate_payload(&json!({
            "operation": "capability_binding_request_record",
            "title": "candidate"
        }))
        .expect_err("binding request must expose its complete preflight contract");
        assert!(error.to_string().contains("$.targetOperation"));
    }

    #[test]
    fn route_activation_contract_requires_approval_refs() {
        let error = validate_payload(&json!({
            "operation": "capability_route_activate",
            "capabilityRouteBindingResourceId": "capability_route_binding:example",
            "expectedCapabilityRouteBindingVersionId": "version-1",
            "reason": "approved"
        }))
        .expect_err("activation must require approval refs before authority derivation");
        assert!(error.to_string().contains("$.approvalRefs"));
    }

    #[test]
    fn governance_contracts_reject_cross_operation_fields() {
        let error = validate_payload(&json!({
            "operation": "capability_route_event_list",
            "command": "not a route list field"
        }))
        .expect_err("governance schemas must be closed");
        assert!(error.to_string().contains("$.command"));
    }
}
