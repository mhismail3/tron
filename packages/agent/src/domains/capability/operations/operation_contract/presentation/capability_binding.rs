//! Capability-binding and route provider-visible presentation literals.

use super::OperationPresentation;

const fn presented(display_name: &'static str, description: &'static str) -> OperationPresentation {
    OperationPresentation {
        display_name,
        description,
    }
}

pub(super) const CAPABILITY_BINDING_REQUEST_RECORD: OperationPresentation = presented(
    "Request Capability Binding",
    "Record a governed proposal to extend, shadow, or replace an operation.",
);
pub(super) const CAPABILITY_BINDING_REQUEST_LIST: OperationPresentation = presented(
    "List Capability Binding Requests",
    "List capability binding proposals with bounded governance summaries.",
);
pub(super) const CAPABILITY_BINDING_REQUEST_INSPECT: OperationPresentation = presented(
    "Inspect Capability Binding Request",
    "Inspect one capability binding proposal and its requirements.",
);
pub(super) const CAPABILITY_BINDING_DECISION_RECORD: OperationPresentation = presented(
    "Record Capability Binding Decision",
    "Record a governance decision for one capability binding proposal.",
);
pub(super) const CAPABILITY_BINDING_DECISION_LIST: OperationPresentation = presented(
    "List Capability Binding Decisions",
    "List capability binding decisions with bounded policy summaries.",
);
pub(super) const CAPABILITY_BINDING_DECISION_INSPECT: OperationPresentation = presented(
    "Inspect Capability Binding Decision",
    "Inspect one capability binding decision and its governance evidence.",
);
pub(super) const CAPABILITY_BINDING_POLICY_ACTIVATE: OperationPresentation = presented(
    "Activate Capability Binding Policy",
    "Activate approved binding policy metadata without changing runtime routing.",
);
pub(super) const CAPABILITY_BINDING_POLICY_LIST: OperationPresentation = presented(
    "List Capability Binding Policies",
    "List active capability binding policies with bounded evidence summaries.",
);
pub(super) const CAPABILITY_BINDING_POLICY_INSPECT: OperationPresentation = presented(
    "Inspect Capability Binding Policy",
    "Inspect one capability binding policy and its rollback controls.",
);
pub(super) const CAPABILITY_BINDING_COCKPIT_OVERVIEW: OperationPresentation = presented(
    "View Capability Dashboard",
    "Show operation ownership, replacement readiness, and route evidence for the current scope.",
);
pub(super) const CAPABILITY_SHADOW_TRIAL_REQUEST_RECORD: OperationPresentation = presented(
    "Request Capability Shadow Trial",
    "Record a governed request to compare built-in and candidate behavior.",
);
pub(super) const CAPABILITY_SHADOW_TRIAL_DECISION_RECORD: OperationPresentation = presented(
    "Record Shadow Trial Decision",
    "Record approval, rejection, disablement, or cancellation of a shadow trial.",
);
pub(super) const CAPABILITY_SHADOW_TRIAL_RUN_RECORD: OperationPresentation = presented(
    "Record Shadow Trial Run",
    "Compare bounded built-in and candidate projections without changing live routing.",
);
pub(super) const CAPABILITY_SHADOW_TRIAL_EVIDENCE_INSPECT: OperationPresentation = presented(
    "Inspect Shadow Trial Evidence",
    "Inspect one shadow comparison and its rollback and disable controls.",
);
pub(super) const CAPABILITY_REPLACEMENT_CANDIDATE_RECORD: OperationPresentation = presented(
    "Record Replacement Candidate",
    "Record a governed operation replacement candidate and its safety evidence.",
);
pub(super) const CAPABILITY_REPLACEMENT_CANDIDATE_LIST: OperationPresentation = presented(
    "List Replacement Candidates",
    "List operation replacement candidates with bounded lifecycle summaries.",
);
pub(super) const CAPABILITY_REPLACEMENT_CANDIDATE_INSPECT: OperationPresentation = presented(
    "Inspect Replacement Candidate",
    "Inspect one operation replacement candidate and its rollback evidence.",
);
pub(super) const CAPABILITY_ROUTE_BINDING_RECORD: OperationPresentation = presented(
    "Record Capability Route",
    "Record a governed route between an operation and a validated candidate.",
);
pub(super) const CAPABILITY_ROUTE_BINDING_LIST: OperationPresentation = presented(
    "List Capability Routes",
    "List governed operation routes with bounded readiness summaries.",
);
pub(super) const CAPABILITY_ROUTE_BINDING_INSPECT: OperationPresentation = presented(
    "Inspect Capability Route",
    "Inspect one governed operation route and its activation gates.",
);
pub(super) const CAPABILITY_ROUTE_ACTIVATE: OperationPresentation = presented(
    "Activate Capability Route",
    "Activate a governed replacement route after approval and rollback checks.",
);
pub(super) const CAPABILITY_ROUTE_DISABLE: OperationPresentation = presented(
    "Disable Capability Route",
    "Disable an active replacement route and restore built-in ownership.",
);
pub(super) const CAPABILITY_ROUTE_ROLLBACK: OperationPresentation = presented(
    "Roll Back Capability Route",
    "Record rollback of an active route and restore built-in ownership.",
);
pub(super) const CAPABILITY_ROUTE_EVENT_LIST: OperationPresentation = presented(
    "List Capability Route Events",
    "List bounded activation, invocation, disablement, and rollback history.",
);
pub(super) const CAPABILITY_ROUTE_EVENT_INSPECT: OperationPresentation = presented(
    "Inspect Capability Route Event",
    "Inspect one route event and its bounded outcome evidence.",
);
