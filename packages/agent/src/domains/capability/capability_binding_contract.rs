//! Provider schema additions for capability binding policy operations.
//!
//! These fields describe metadata-only binding requests, decisions, and policy
//! records. They never authorize runtime routing, module hot-swapping, module
//! activation, dispatch mutation, package-manager execution, dependency
//! restoration, network access, or raw local material exposure.

use serde_json::{Map, Value, json};

#[cfg(test)]
pub(super) const CAPABILITY_BINDING_SCHEMA_FIELDS: &[&str] = &[
    "capabilityBindingRequestResourceId",
    "capabilityBindingDecisionResourceId",
    "capabilityBindingPolicyResourceId",
    "capabilityBindingRequestId",
    "capabilityBindingDecisionId",
    "capabilityBindingPolicyId",
    "targetOperation",
    "currentBuiltInOwner",
    "replacementTarget",
    "ownershipClass",
    "bindingMode",
    "targetRef",
    "actorScope",
    "authorityConstraints",
    "contractEvidenceRefs",
    "evidenceRequirements",
    "staleVersionGuard",
    "rollbackRef",
    "disableRef",
    "auditRefs",
    "expectedCapabilityBindingRequestVersionId",
    "expectedCapabilityBindingDecisionVersionId",
];

pub(super) fn append_schema_properties(properties: &mut Map<String, Value>) {
    for (name, description) in [
        (
            "capabilityBindingRequestResourceId",
            "Durable capability_binding_request resource id for inspect or decision record.",
        ),
        (
            "capabilityBindingDecisionResourceId",
            "Durable capability_binding_decision resource id for inspect or policy activation.",
        ),
        (
            "capabilityBindingPolicyResourceId",
            "Durable capability_binding_policy resource id for inspect.",
        ),
        (
            "capabilityBindingRequestId",
            "Optional caller-visible capability binding request id.",
        ),
        (
            "capabilityBindingDecisionId",
            "Optional caller-visible capability binding decision id.",
        ),
        (
            "capabilityBindingPolicyId",
            "Optional caller-visible capability binding policy id.",
        ),
        (
            "targetOperation",
            "Exact supported capability::execute operation name covered by the binding request; unknown operations are rejected.",
        ),
        (
            "currentBuiltInOwner",
            "Caller assertion for the current built-in owner; the server verifies it against execute-registry metadata.",
        ),
        (
            "replacementTarget",
            "Caller assertion for the replacement or extension target label; the server verifies it against execute-registry metadata.",
        ),
        (
            "ownershipClass",
            "Caller assertion for the capability modularity ownership class; the server verifies it against execute-registry metadata before replacement eligibility.",
        ),
        (
            "bindingMode",
            "Requested metadata binding mode: shadow, extend, or replace where allowed.",
        ),
        (
            "actorScope",
            "Requester/actor scope for binding governance: session or workspace.",
        ),
        (
            "evidenceRequirements",
            "Bounded summary of contract/evidence requirements for the binding request.",
        ),
        (
            "expectedCapabilityBindingRequestVersionId",
            "Expected current capability_binding_request version id for decision freshness.",
        ),
        (
            "expectedCapabilityBindingDecisionVersionId",
            "Expected current capability_binding_decision version id for policy activation freshness.",
        ),
    ] {
        insert_string(properties, name, description);
    }
    for (name, description) in [
        (
            "targetRef",
            "Bounded resource ref for the requested replacement/extension/shadow target.",
        ),
        (
            "authorityConstraints",
            "Bounded authority constraints with networkPolicy none, exact scopes/kinds/selectors, no wildcard selectors, and no agent_state inheritance.",
        ),
        (
            "staleVersionGuard",
            "Expected inventory and binding policy version guard for request freshness.",
        ),
        (
            "rollbackRef",
            "Optional bounded rollback reference; required for replace requests.",
        ),
        (
            "disableRef",
            "Optional bounded disable or emergency-off reference.",
        ),
    ] {
        properties.insert(
            name.to_owned(),
            json!({"type": "object", "description": description}),
        );
    }
    properties.insert(
        "contractEvidenceRefs".to_owned(),
        json!({"type": "array", "description": "Bounded refs proving contract requirements for a binding request."}),
    );
    properties.insert(
        "auditRefs".to_owned(),
        json!({"type": "array", "description": "Bounded safe audit refs for binding request, decision, or policy records."}),
    );
}

fn insert_string(properties: &mut Map<String, Value>, name: &str, description: &str) {
    properties.insert(
        name.to_owned(),
        json!({"type": "string", "description": description}),
    );
}
