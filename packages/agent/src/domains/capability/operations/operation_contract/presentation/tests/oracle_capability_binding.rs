//! Frozen capability binding-family provider-visible presentation rows.

use super::OracleRow;

pub(super) const ROWS: [OracleRow; 25] = [
    (
        "capability_binding_request_record",
        "capability_binding",
        "Request Capability Binding",
        "Record a governed proposal to extend, shadow, or replace an operation.",
    ),
    (
        "capability_binding_request_list",
        "capability_binding",
        "List Capability Binding Requests",
        "List capability binding proposals with bounded governance summaries.",
    ),
    (
        "capability_binding_request_inspect",
        "capability_binding",
        "Inspect Capability Binding Request",
        "Inspect one capability binding proposal and its requirements.",
    ),
    (
        "capability_binding_decision_record",
        "capability_binding",
        "Record Capability Binding Decision",
        "Record a governance decision for one capability binding proposal.",
    ),
    (
        "capability_binding_decision_list",
        "capability_binding",
        "List Capability Binding Decisions",
        "List capability binding decisions with bounded policy summaries.",
    ),
    (
        "capability_binding_decision_inspect",
        "capability_binding",
        "Inspect Capability Binding Decision",
        "Inspect one capability binding decision and its governance evidence.",
    ),
    (
        "capability_binding_policy_activate",
        "capability_binding",
        "Activate Capability Binding Policy",
        "Activate approved binding policy metadata without changing runtime routing.",
    ),
    (
        "capability_binding_policy_list",
        "capability_binding",
        "List Capability Binding Policies",
        "List active capability binding policies with bounded evidence summaries.",
    ),
    (
        "capability_binding_policy_inspect",
        "capability_binding",
        "Inspect Capability Binding Policy",
        "Inspect one capability binding policy and its rollback controls.",
    ),
    (
        "capability_binding_cockpit_overview",
        "capability_binding",
        "View Capability Dashboard",
        "Show operation ownership, replacement readiness, and route evidence for the current scope.",
    ),
    (
        "capability_shadow_trial_request_record",
        "capability_binding",
        "Request Capability Shadow Trial",
        "Record a governed request to compare built-in and candidate behavior.",
    ),
    (
        "capability_shadow_trial_decision_record",
        "capability_binding",
        "Record Shadow Trial Decision",
        "Record approval, rejection, disablement, or cancellation of a shadow trial.",
    ),
    (
        "capability_shadow_trial_run_record",
        "capability_binding",
        "Record Shadow Trial Run",
        "Compare bounded built-in and candidate projections without changing live routing.",
    ),
    (
        "capability_shadow_trial_evidence_inspect",
        "capability_binding",
        "Inspect Shadow Trial Evidence",
        "Inspect one shadow comparison and its rollback and disable controls.",
    ),
    (
        "capability_replacement_candidate_record",
        "capability_binding",
        "Record Replacement Candidate",
        "Record a governed operation replacement candidate and its safety evidence.",
    ),
    (
        "capability_replacement_candidate_list",
        "capability_binding",
        "List Replacement Candidates",
        "List operation replacement candidates with bounded lifecycle summaries.",
    ),
    (
        "capability_replacement_candidate_inspect",
        "capability_binding",
        "Inspect Replacement Candidate",
        "Inspect one operation replacement candidate and its rollback evidence.",
    ),
    (
        "capability_route_binding_record",
        "capability_binding",
        "Record Capability Route",
        "Record a governed route between an operation and a validated candidate.",
    ),
    (
        "capability_route_binding_list",
        "capability_binding",
        "List Capability Routes",
        "List governed operation routes with bounded readiness summaries.",
    ),
    (
        "capability_route_binding_inspect",
        "capability_binding",
        "Inspect Capability Route",
        "Inspect one governed operation route and its activation gates.",
    ),
    (
        "capability_route_activate",
        "capability_binding",
        "Activate Capability Route",
        "Activate a governed replacement route after approval and rollback checks.",
    ),
    (
        "capability_route_disable",
        "capability_binding",
        "Disable Capability Route",
        "Disable an active replacement route and restore built-in ownership.",
    ),
    (
        "capability_route_rollback",
        "capability_binding",
        "Roll Back Capability Route",
        "Record rollback of an active route and restore built-in ownership.",
    ),
    (
        "capability_route_event_list",
        "capability_binding",
        "List Capability Route Events",
        "List bounded activation, invocation, disablement, and rollback history.",
    ),
    (
        "capability_route_event_inspect",
        "capability_binding",
        "Inspect Capability Route Event",
        "Inspect one route event and its bounded outcome evidence.",
    ),
];
