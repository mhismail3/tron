//! Grant records, requests, lifecycle values, and bootstrap/event builders.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use uuid::Uuid;

use crate::engine::errors::{EngineError, Result};
use crate::engine::ids::{ActorId, AuthorityGrantId, InvocationId, TraceId, WorkerId};
use crate::engine::types::RiskLevel;

/// Active or revoked grant state.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EngineGrantLifecycle {
    /// Grant can be used.
    Active,
    /// Grant has been revoked and cannot authorize new work.
    Revoked,
}

impl EngineGrantLifecycle {
    pub(super) fn as_str(&self) -> &'static str {
        match self {
            Self::Active => "active",
            Self::Revoked => "revoked",
        }
    }

    pub(super) fn parse(value: &str) -> Result<Self> {
        match value {
            "active" => Ok(Self::Active),
            "revoked" => Ok(Self::Revoked),
            _ => Err(EngineError::LedgerFailure {
                operation: "grant.lifecycle",
                message: format!("invalid grant lifecycle {value}"),
            }),
        }
    }
}

/// Durable grant record.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineGrant {
    /// Stable grant id.
    pub grant_id: AuthorityGrantId,
    /// Parent grant id when derived.
    pub parent_grant_id: Option<AuthorityGrantId>,
    /// Optional actor subject. `None` means any actor.
    pub subject_actor_id: Option<ActorId>,
    /// Optional worker subject. `None` means any worker.
    pub subject_worker_id: Option<WorkerId>,
    /// Optional invocation subject. `None` means any invocation.
    pub subject_invocation_id: Option<InvocationId>,
    /// Lifecycle state.
    pub lifecycle: EngineGrantLifecycle,
    /// Exact capability ids allowed. `*` allows all.
    pub allowed_capabilities: Vec<String>,
    /// Namespace prefixes allowed. `*` allows all.
    pub allowed_namespaces: Vec<String>,
    /// Authority labels that function contracts may require. `*` allows all.
    pub allowed_authority_scopes: Vec<String>,
    /// Resource kinds allowed. `*` allows all.
    pub allowed_resource_kinds: Vec<String>,
    /// Resource selector strings reserved for stricter future matching.
    pub resource_selectors: Vec<String>,
    /// Allowed file roots. `*` allows all.
    pub file_roots: Vec<String>,
    /// Network policy: `none`, `loopback`, `declared`, or `unrestricted`.
    pub network_policy: String,
    /// Maximum risk authorized.
    pub max_risk: RiskLevel,
    /// Budget envelope.
    pub budget: Value,
    /// Expiry time.
    pub expires_at: Option<DateTime<Utc>>,
    /// Whether this grant can derive child grants.
    pub can_delegate: bool,
    /// Whether this grant requires approval for derived/autonomous work.
    pub approval_required: bool,
    /// Provenance payload.
    pub provenance: Value,
    /// Trace that created the grant.
    pub trace_id: TraceId,
    /// Monotonic revision.
    pub revision: u64,
    /// Creation timestamp.
    pub created_at: DateTime<Utc>,
    /// Last update timestamp.
    pub updated_at: DateTime<Utc>,
}

/// Request to derive a child grant.
#[derive(Clone, Debug, PartialEq)]
pub struct DeriveGrant {
    /// Optional child id; generated when absent.
    pub grant_id: Option<AuthorityGrantId>,
    /// Parent grant id.
    pub parent_grant_id: AuthorityGrantId,
    /// Optional actor subject.
    pub subject_actor_id: Option<ActorId>,
    /// Optional worker subject.
    pub subject_worker_id: Option<WorkerId>,
    /// Optional invocation subject.
    pub subject_invocation_id: Option<InvocationId>,
    /// Exact capabilities.
    pub allowed_capabilities: Vec<String>,
    /// Namespaces.
    pub allowed_namespaces: Vec<String>,
    /// Authority labels.
    pub allowed_authority_scopes: Vec<String>,
    /// Resource kinds.
    pub allowed_resource_kinds: Vec<String>,
    /// Resource selectors.
    pub resource_selectors: Vec<String>,
    /// File roots.
    pub file_roots: Vec<String>,
    /// Network policy.
    pub network_policy: String,
    /// Max risk.
    pub max_risk: RiskLevel,
    /// Budget.
    pub budget: Value,
    /// Expiry.
    pub expires_at: Option<DateTime<Utc>>,
    /// Delegation.
    pub can_delegate: bool,
    /// Approval requirement.
    pub approval_required: bool,
    /// Provenance.
    pub provenance: Value,
    /// Trace id.
    pub trace_id: TraceId,
}

/// List grants.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ListGrants {
    /// Parent filter.
    pub parent_grant_id: Option<AuthorityGrantId>,
    /// Lifecycle filter.
    pub lifecycle: Option<EngineGrantLifecycle>,
    /// Limit.
    pub limit: usize,
}

/// Grant event.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineGrantEvent {
    /// Stable event id.
    pub event_id: String,
    /// Grant id.
    pub grant_id: AuthorityGrantId,
    /// Event type.
    pub event_type: String,
    /// Payload.
    pub payload: Value,
    /// Trace id.
    pub trace_id: TraceId,
    /// Timestamp.
    pub occurred_at: DateTime<Utc>,
}

/// Bootstrap grants for current first-party runtime actors. These are explicit
/// root grants for the new model, not caller-supplied permission data.
pub const BOOTSTRAP_GRANT_IDS: &[&str] = &[
    "grant",
    "engine-system",
    "engine-transport",
    "worker-runtime",
    "sandbox-lifecycle",
    "sandbox-spawn-worker",
    "agent-runtime",
    "agent-capability-runtime",
    "agent-worker-guide",
    "capability-grant",
    "prompt-runtime",
    "mcp-catalog-refresh",
    "cron-scheduler",
    "test-grant",
    "grant:test",
];

#[cfg(test)]
pub(super) const TEST_BOOTSTRAP_GRANT_IDS: &[&str] = &[
    "system-grant",
    "manual-grant",
    "external-grant",
    "agent-grant",
    "approval-agent",
    "approval-admin",
    "admin-grant",
];

pub(super) fn bootstrap_grant(grant_id: &str) -> EngineGrant {
    let now = Utc::now();
    EngineGrant {
        grant_id: AuthorityGrantId::new(grant_id).expect("valid bootstrap grant id"),
        parent_grant_id: None,
        subject_actor_id: None,
        subject_worker_id: None,
        subject_invocation_id: None,
        lifecycle: EngineGrantLifecycle::Active,
        allowed_capabilities: vec!["*".to_owned()],
        allowed_namespaces: vec!["*".to_owned()],
        allowed_authority_scopes: vec!["*".to_owned()],
        allowed_resource_kinds: vec!["*".to_owned()],
        resource_selectors: vec!["*".to_owned()],
        file_roots: vec!["*".to_owned()],
        network_policy: "unrestricted".to_owned(),
        max_risk: RiskLevel::Critical,
        budget: json!({"class": "bootstrap"}),
        expires_at: None,
        can_delegate: true,
        approval_required: false,
        provenance: json!({"source": "engine.bootstrap"}),
        trace_id: TraceId::new("bootstrap").expect("valid bootstrap trace id"),
        revision: 1,
        created_at: now,
        updated_at: now,
    }
}

pub(super) fn grant_from_request(
    request: DeriveGrant,
    grant_id: AuthorityGrantId,
    now: DateTime<Utc>,
    revision: u64,
) -> EngineGrant {
    EngineGrant {
        grant_id,
        parent_grant_id: Some(request.parent_grant_id),
        subject_actor_id: request.subject_actor_id,
        subject_worker_id: request.subject_worker_id,
        subject_invocation_id: request.subject_invocation_id,
        lifecycle: EngineGrantLifecycle::Active,
        allowed_capabilities: request.allowed_capabilities,
        allowed_namespaces: request.allowed_namespaces,
        allowed_authority_scopes: request.allowed_authority_scopes,
        allowed_resource_kinds: request.allowed_resource_kinds,
        resource_selectors: request.resource_selectors,
        file_roots: request.file_roots,
        network_policy: request.network_policy,
        max_risk: request.max_risk,
        budget: request.budget,
        expires_at: request.expires_at,
        can_delegate: request.can_delegate,
        approval_required: request.approval_required,
        provenance: request.provenance,
        trace_id: request.trace_id,
        revision,
        created_at: now,
        updated_at: now,
    }
}

pub(super) fn grant_event(
    grant_id: &AuthorityGrantId,
    event_type: &str,
    payload: Value,
    trace_id: TraceId,
) -> EngineGrantEvent {
    EngineGrantEvent {
        event_id: format!("grant_event_{}", Uuid::now_v7()),
        grant_id: grant_id.clone(),
        event_type: event_type.to_owned(),
        payload,
        trace_id,
        occurred_at: Utc::now(),
    }
}
