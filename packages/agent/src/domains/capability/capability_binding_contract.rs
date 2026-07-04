//! Provider schema additions for capability binding policy operations.
//!
//! These fields describe metadata-only binding requests, decisions, policies,
//! and the first governed shadow-trial records. They never authorize runtime
//! routing, module hot-swapping, module activation, dispatch mutation,
//! package-manager execution, dependency restoration, network access, or raw
//! local material exposure.

use serde_json::{Map, Value, json};

#[cfg(test)]
pub(super) const CAPABILITY_BINDING_SCHEMA_FIELDS: &[&str] = &[
    "capabilityBindingRequestResourceId",
    "capabilityBindingDecisionResourceId",
    "capabilityBindingPolicyResourceId",
    "capabilityShadowTrialRequestResourceId",
    "capabilityShadowTrialDecisionResourceId",
    "capabilityShadowTrialEvidenceResourceId",
    "capabilityBindingRequestId",
    "capabilityBindingDecisionId",
    "capabilityBindingPolicyId",
    "capabilityShadowTrialRequestId",
    "capabilityShadowTrialDecisionId",
    "capabilityShadowTrialRunId",
    "capabilityShadowTrialEvidenceId",
    "targetOperation",
    "currentBuiltInOwner",
    "replacementTarget",
    "ownershipClass",
    "bindingMode",
    "candidateAdapter",
    "builtInProjection",
    "candidateProjection",
    "trialRunOutcome",
    "targetRef",
    "actorScope",
    "authorityConstraints",
    "contractEvidenceRefs",
    "evidenceRequirements",
    "staleVersionGuard",
    "rollbackRef",
    "disableRef",
    "abortRef",
    "auditRefs",
    "expectedCapabilityBindingRequestVersionId",
    "expectedCapabilityBindingDecisionVersionId",
    "expectedCapabilityShadowTrialRequestVersionId",
    "expectedCapabilityShadowTrialDecisionVersionId",
    "expectedCapabilityShadowTrialEvidenceVersionId",
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
            "capabilityShadowTrialRequestResourceId",
            "Durable capability_shadow_trial_request resource id for decision record.",
        ),
        (
            "capabilityShadowTrialDecisionResourceId",
            "Durable capability_shadow_trial_decision resource id for run record.",
        ),
        (
            "capabilityShadowTrialEvidenceResourceId",
            "Durable capability_shadow_trial_evidence resource id for exact-selector inspection.",
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
            "capabilityShadowTrialRequestId",
            "Optional caller-visible capability shadow trial request id.",
        ),
        (
            "capabilityShadowTrialDecisionId",
            "Optional caller-visible capability shadow trial decision id.",
        ),
        (
            "capabilityShadowTrialRunId",
            "Optional caller-visible capability shadow trial run id.",
        ),
        (
            "capabilityShadowTrialEvidenceId",
            "Optional caller-visible capability shadow trial evidence id.",
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
            "trialRunOutcome",
            "Capability shadow trial run outcome: completed, aborted, or disabled.",
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
        (
            "expectedCapabilityShadowTrialRequestVersionId",
            "Expected current capability_shadow_trial_request version id for decision freshness.",
        ),
        (
            "expectedCapabilityShadowTrialDecisionVersionId",
            "Expected current capability_shadow_trial_decision version id for run freshness.",
        ),
        (
            "expectedCapabilityShadowTrialEvidenceVersionId",
            "Expected current capability_shadow_trial_evidence version id for stale-evidence rejection during inspect.",
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
            "Optional bounded disable or emergency-off reference; required for replace requests.",
        ),
        (
            "abortRef",
            "Bounded abort reference required for capability shadow trial request and run semantics.",
        ),
        (
            "candidateAdapter",
            "Bounded deterministic metadata-only candidate adapter description for the git_status shadow trial.",
        ),
        (
            "builtInProjection",
            "Bounded provider-safe built-in git_status projection for metadata-only shadow comparison.",
        ),
        (
            "candidateProjection",
            "Bounded provider-safe candidate git_status projection for metadata-only shadow comparison.",
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
