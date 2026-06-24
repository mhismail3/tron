use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Approval request resource payload schema version.
pub(crate) const REQUEST_SCHEMA_VERSION: &str = "tron.approval_request.v1";
/// Approval decision resource payload schema version.
pub(crate) const DECISION_SCHEMA_VERSION: &str = "tron.approval_decision.v1";
/// Approval check response schema version.
pub(crate) const CHECK_SCHEMA_VERSION: &str = "tron.approval_check.v1";

/// Durable approval request payload.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ApprovalRequestRecord {
    pub(crate) schema_version: String,
    pub(crate) state: ApprovalRequestState,
    pub(crate) requester: Value,
    pub(crate) action: Value,
    pub(crate) scope: Value,
    pub(crate) risk_class: String,
    pub(crate) created_at: DateTime<Utc>,
    pub(crate) expires_at: DateTime<Utc>,
    pub(crate) freshness: Value,
    pub(crate) evidence_refs: Vec<Value>,
    pub(crate) resource_selectors: Vec<Value>,
    pub(crate) trace_refs: Vec<Value>,
    pub(crate) replay_refs: Vec<Value>,
    pub(crate) denial_behavior: Value,
    pub(crate) idempotency: ApprovalIdempotency,
    pub(crate) revision: ApprovalRequestRevision,
}

/// Request lifecycle recorded in the request resource payload.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ApprovalRequestState {
    Pending,
    Decided,
    Expired,
    Revoked,
}

/// Durable approval decision payload.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ApprovalDecisionRecord {
    pub(crate) schema_version: String,
    pub(crate) request_resource_id: String,
    pub(crate) request_version_id: String,
    pub(crate) state: ApprovalDecisionState,
    pub(crate) decision_actor: Value,
    pub(crate) decided_at: DateTime<Utc>,
    pub(crate) expires_at: DateTime<Utc>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) freshness_until: Option<DateTime<Utc>>,
    pub(crate) action: Value,
    pub(crate) scope: Value,
    pub(crate) risk_class: String,
    pub(crate) evidence_refs: Vec<Value>,
    pub(crate) resource_selectors: Vec<Value>,
    pub(crate) trace_refs: Vec<Value>,
    pub(crate) replay_refs: Vec<Value>,
    pub(crate) denial_behavior: Value,
    pub(crate) idempotency: ApprovalIdempotency,
    pub(crate) revision: ApprovalDecisionRevision,
}

/// Decision state recorded in the decision resource payload.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ApprovalDecisionState {
    Approved,
    Denied,
    Revoked,
}

/// Idempotency metadata embedded in request and decision payloads.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ApprovalIdempotency {
    pub(crate) key: Option<String>,
    pub(crate) invocation_id: String,
    pub(crate) function_id: String,
}

/// Request resource revision metadata.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ApprovalRequestRevision {
    pub(crate) number: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) current_version_id: Option<String>,
}

/// Decision resource revision metadata.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ApprovalDecisionRevision {
    pub(crate) number: u64,
    pub(crate) expected_request_version_id: String,
    pub(crate) recorded_request_version_id: String,
}

/// Caller-supplied check requirement for a future package action.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct ApprovalCheckRequirement {
    pub(crate) request_resource_id: String,
    pub(crate) decision_resource_id: Option<String>,
    pub(crate) action: Value,
    pub(crate) scope: Value,
    pub(crate) risk_class: String,
    pub(crate) resource_selectors: Vec<Value>,
}

/// Fail-closed approval check outcome.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ApprovalCheckOutcome {
    Approved,
    Denied,
    Expired,
    Pending,
    Missing,
    Malformed,
    Stale,
    ScopeMismatch,
}

/// Structured approval check response.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ApprovalCheckResult {
    pub(crate) schema_version: String,
    pub(crate) allowed: bool,
    pub(crate) outcome: ApprovalCheckOutcome,
    pub(crate) reason: String,
    pub(crate) explanation: Value,
}
