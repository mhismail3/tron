//! Engine-owned grants.
//!
//! Grants are the durable authority model for the modular substrate. Callers
//! carry a grant id, but the engine resolves that id to stored policy before a
//! handler runs. Raw caller-supplied authority scope strings are audit context,
//! not permission truth.

use std::collections::BTreeMap;
use std::path::Path;

use chrono::{DateTime, Utc};
use rusqlite::{Connection, OptionalExtension, Row, params, types::Type};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use uuid::Uuid;

use super::errors::{EngineError, Result};
use super::ids::{ActorId, AuthorityGrantId, FunctionId, InvocationId, TraceId, WorkerId};
use super::invocation::Invocation;
use super::types::{FunctionDefinition, RiskLevel};

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
    fn as_str(&self) -> &'static str {
        match self {
            Self::Active => "active",
            Self::Revoked => "revoked",
        }
    }

    fn parse(value: &str) -> Result<Self> {
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

/// In-memory grant store.
#[derive(Clone, Debug)]
pub struct InMemoryEngineGrantStore {
    grants: BTreeMap<AuthorityGrantId, EngineGrant>,
    events: BTreeMap<AuthorityGrantId, Vec<EngineGrantEvent>>,
}

impl InMemoryEngineGrantStore {
    /// Create a grant store with first-party bootstrap grants.
    #[must_use]
    pub fn new() -> Self {
        let mut store = Self {
            grants: BTreeMap::new(),
            events: BTreeMap::new(),
        };
        store.seed_bootstrap_grants();
        store
    }

    /// Derive a child grant.
    pub fn derive(&mut self, request: DeriveGrant) -> Result<EngineGrant> {
        validate_derive_request(&request)?;
        let parent = self.require_grant(&request.parent_grant_id)?;
        ensure_parent_can_derive(&parent)?;
        ensure_child_narrows_parent(&parent, &request)?;
        let now = Utc::now();
        let grant_id = request
            .grant_id
            .clone()
            .unwrap_or_else(AuthorityGrantId::generate);
        if self.grants.contains_key(&grant_id) {
            return Err(EngineError::PolicyViolation(format!(
                "grant {grant_id} already exists"
            )));
        }
        let grant = grant_from_request(request, grant_id, now, 1);
        self.grants.insert(grant.grant_id.clone(), grant.clone());
        self.record_event(grant_event(
            &grant.grant_id,
            "grant.derived",
            json!({"parentGrantId": grant.parent_grant_id.as_ref().map(AuthorityGrantId::as_str)}),
            grant.trace_id.clone(),
        ));
        Ok(grant)
    }

    /// Inspect one grant.
    pub fn inspect(&self, grant_id: &AuthorityGrantId) -> Result<Option<EngineGrant>> {
        Ok(self.grants.get(grant_id).cloned())
    }

    /// List grants.
    pub fn list(&self, filter: ListGrants) -> Result<Vec<EngineGrant>> {
        validate_list_limit(filter.limit)?;
        Ok(self
            .grants
            .values()
            .filter(|grant| {
                filter
                    .parent_grant_id
                    .as_ref()
                    .is_none_or(|parent| grant.parent_grant_id.as_ref() == Some(parent))
                    && filter
                        .lifecycle
                        .as_ref()
                        .is_none_or(|lifecycle| &grant.lifecycle == lifecycle)
            })
            .take(filter.limit)
            .cloned()
            .collect())
    }

    /// Revoke one grant.
    pub fn revoke(
        &mut self,
        grant_id: &AuthorityGrantId,
        trace_id: TraceId,
    ) -> Result<EngineGrant> {
        let mut grant = self.require_grant(grant_id)?;
        if grant.lifecycle != EngineGrantLifecycle::Revoked {
            grant.lifecycle = EngineGrantLifecycle::Revoked;
            grant.revision += 1;
            grant.updated_at = Utc::now();
            self.grants.insert(grant_id.clone(), grant.clone());
            self.record_event(grant_event(grant_id, "grant.revoked", json!({}), trace_id));
        }
        Ok(grant)
    }

    /// Validate an invocation against its resolved grant.
    pub fn authorize_invocation(
        &self,
        function: &FunctionDefinition,
        invocation: &Invocation,
    ) -> Result<EngineGrant> {
        let grant = self.require_grant(&invocation.causal_context.authority_grant_id)?;
        authorize_with_grant(&grant, function, invocation)?;
        Ok(grant)
    }

    fn require_grant(&self, grant_id: &AuthorityGrantId) -> Result<EngineGrant> {
        self.grants.get(grant_id).cloned().ok_or_else(|| {
            EngineError::PolicyViolation(format!("authority grant {grant_id} not found"))
        })
    }

    fn record_event(&mut self, event: EngineGrantEvent) {
        self.events
            .entry(event.grant_id.clone())
            .or_default()
            .push(event);
    }

    fn seed_bootstrap_grants(&mut self) {
        for grant_id in BOOTSTRAP_GRANT_IDS {
            let grant = bootstrap_grant(grant_id);
            self.grants.insert(grant.grant_id.clone(), grant);
        }
        #[cfg(test)]
        for grant_id in TEST_BOOTSTRAP_GRANT_IDS {
            let grant = bootstrap_grant(grant_id);
            self.grants.insert(grant.grant_id.clone(), grant);
        }
    }
}

impl Default for InMemoryEngineGrantStore {
    fn default() -> Self {
        Self::new()
    }
}

/// SQLite grant store.
pub struct SqliteEngineGrantStore {
    conn: Connection,
}

impl SqliteEngineGrantStore {
    /// Open grant tables in the unified engine DB.
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let conn =
            Connection::open(path).map_err(|err| sqlite_err("grant.open", err.to_string()))?;
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS engine_grants (
                grant_id TEXT PRIMARY KEY,
                parent_grant_id TEXT,
                subject_actor_id TEXT,
                subject_worker_id TEXT,
                subject_invocation_id TEXT,
                lifecycle TEXT NOT NULL,
                allowed_capabilities_json TEXT NOT NULL,
                allowed_namespaces_json TEXT NOT NULL,
                allowed_authority_scopes_json TEXT NOT NULL,
                allowed_resource_kinds_json TEXT NOT NULL,
                resource_selectors_json TEXT NOT NULL,
                file_roots_json TEXT NOT NULL,
                network_policy TEXT NOT NULL,
                max_risk TEXT NOT NULL,
                budget_json TEXT NOT NULL,
                expires_at TEXT,
                can_delegate INTEGER NOT NULL,
                approval_required INTEGER NOT NULL,
                provenance_json TEXT NOT NULL,
                trace_id TEXT NOT NULL,
                revision INTEGER NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
             );
             CREATE INDEX IF NOT EXISTS idx_engine_grants_parent
               ON engine_grants(parent_grant_id);
             CREATE INDEX IF NOT EXISTS idx_engine_grants_lifecycle
               ON engine_grants(lifecycle);
             CREATE TABLE IF NOT EXISTS engine_grant_events (
                event_id TEXT PRIMARY KEY,
                grant_id TEXT NOT NULL REFERENCES engine_grants(grant_id),
                event_type TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                trace_id TEXT NOT NULL,
                occurred_at TEXT NOT NULL
             );
             CREATE INDEX IF NOT EXISTS idx_engine_grant_events_grant
               ON engine_grant_events(grant_id, occurred_at);",
        )
        .map_err(|err| sqlite_err("grant.init", err.to_string()))?;
        let store = Self { conn };
        store.seed_bootstrap_grants()?;
        Ok(store)
    }

    /// Derive a child grant.
    pub fn derive(&mut self, request: DeriveGrant) -> Result<EngineGrant> {
        validate_derive_request(&request)?;
        let parent = self.require_grant(&request.parent_grant_id)?;
        ensure_parent_can_derive(&parent)?;
        ensure_child_narrows_parent(&parent, &request)?;
        let now = Utc::now();
        let grant_id = request
            .grant_id
            .clone()
            .unwrap_or_else(AuthorityGrantId::generate);
        if self.inspect(&grant_id)?.is_some() {
            return Err(EngineError::PolicyViolation(format!(
                "grant {grant_id} already exists"
            )));
        }
        let grant = grant_from_request(request, grant_id, now, 1);
        self.insert_grant(&grant)?;
        self.record_event(&grant_event(
            &grant.grant_id,
            "grant.derived",
            json!({"parentGrantId": grant.parent_grant_id.as_ref().map(AuthorityGrantId::as_str)}),
            grant.trace_id.clone(),
        ))?;
        Ok(grant)
    }

    /// Inspect one grant.
    pub fn inspect(&self, grant_id: &AuthorityGrantId) -> Result<Option<EngineGrant>> {
        self.conn
            .query_row(
                "SELECT * FROM engine_grants WHERE grant_id = ?1",
                params![grant_id.as_str()],
                row_to_grant,
            )
            .optional()
            .map_err(|err| sqlite_err("grant.inspect", err.to_string()))
    }

    /// List grants.
    pub fn list(&self, filter: ListGrants) -> Result<Vec<EngineGrant>> {
        validate_list_limit(filter.limit)?;
        let mut stmt = self
            .conn
            .prepare("SELECT * FROM engine_grants ORDER BY created_at ASC")
            .map_err(|err| sqlite_err("grant.list.prepare", err.to_string()))?;
        let rows = stmt
            .query_map([], row_to_grant)
            .map_err(|err| sqlite_err("grant.list", err.to_string()))?;
        let mut grants = Vec::new();
        for row in rows {
            let grant = row.map_err(|err| sqlite_err("grant.list.row", err.to_string()))?;
            if filter
                .parent_grant_id
                .as_ref()
                .is_some_and(|parent| grant.parent_grant_id.as_ref() != Some(parent))
            {
                continue;
            }
            if filter
                .lifecycle
                .as_ref()
                .is_some_and(|lifecycle| &grant.lifecycle != lifecycle)
            {
                continue;
            }
            grants.push(grant);
            if grants.len() >= filter.limit {
                break;
            }
        }
        Ok(grants)
    }

    /// Revoke one grant.
    pub fn revoke(
        &mut self,
        grant_id: &AuthorityGrantId,
        trace_id: TraceId,
    ) -> Result<EngineGrant> {
        let mut grant = self.require_grant(grant_id)?;
        if grant.lifecycle != EngineGrantLifecycle::Revoked {
            grant.lifecycle = EngineGrantLifecycle::Revoked;
            grant.revision += 1;
            grant.updated_at = Utc::now();
            self.update_grant(&grant)?;
            self.record_event(&grant_event(grant_id, "grant.revoked", json!({}), trace_id))?;
        }
        Ok(grant)
    }

    /// Validate an invocation against its resolved grant.
    pub fn authorize_invocation(
        &self,
        function: &FunctionDefinition,
        invocation: &Invocation,
    ) -> Result<EngineGrant> {
        let grant = self.require_grant(&invocation.causal_context.authority_grant_id)?;
        authorize_with_grant(&grant, function, invocation)?;
        Ok(grant)
    }

    fn require_grant(&self, grant_id: &AuthorityGrantId) -> Result<EngineGrant> {
        self.inspect(grant_id)?.ok_or_else(|| {
            EngineError::PolicyViolation(format!("authority grant {grant_id} not found"))
        })
    }

    fn seed_bootstrap_grants(&self) -> Result<()> {
        for grant_id in BOOTSTRAP_GRANT_IDS {
            let id = AuthorityGrantId::new(*grant_id)?;
            if self.inspect(&id)?.is_none() {
                self.insert_grant(&bootstrap_grant(grant_id))?;
            }
        }
        #[cfg(test)]
        for grant_id in TEST_BOOTSTRAP_GRANT_IDS {
            let id = AuthorityGrantId::new(*grant_id)?;
            if self.inspect(&id)?.is_none() {
                self.insert_grant(&bootstrap_grant(grant_id))?;
            }
        }
        Ok(())
    }

    fn insert_grant(&self, grant: &EngineGrant) -> Result<()> {
        let parent_grant_id = grant.parent_grant_id.as_ref().map(AuthorityGrantId::as_str);
        let subject_actor_id = grant.subject_actor_id.as_ref().map(ActorId::as_str);
        let subject_worker_id = grant.subject_worker_id.as_ref().map(WorkerId::as_str);
        let subject_invocation_id = grant
            .subject_invocation_id
            .as_ref()
            .map(InvocationId::as_str);
        let allowed_capabilities = json_string(&grant.allowed_capabilities, "grant.capabilities")?;
        let allowed_namespaces = json_string(&grant.allowed_namespaces, "grant.namespaces")?;
        let allowed_authority_scopes =
            json_string(&grant.allowed_authority_scopes, "grant.authority_scopes")?;
        let allowed_resource_kinds =
            json_string(&grant.allowed_resource_kinds, "grant.resource_kinds")?;
        let resource_selectors = json_string(&grant.resource_selectors, "grant.selectors")?;
        let file_roots = json_string(&grant.file_roots, "grant.file_roots")?;
        let budget = json_string(&grant.budget, "grant.budget")?;
        let expires_at = grant.expires_at.map(|value| value.to_rfc3339());
        let provenance = json_string(&grant.provenance, "grant.provenance")?;
        self.conn
            .execute(
                "INSERT INTO engine_grants (
                    grant_id, parent_grant_id, subject_actor_id, subject_worker_id,
                    subject_invocation_id, lifecycle, allowed_capabilities_json,
                    allowed_namespaces_json, allowed_authority_scopes_json,
                    allowed_resource_kinds_json, resource_selectors_json, file_roots_json,
                    network_policy, max_risk, budget_json, expires_at, can_delegate,
                    approval_required, provenance_json, trace_id, revision, created_at, updated_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13,
                           ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23)",
                params![
                    grant.grant_id.as_str(),
                    parent_grant_id,
                    subject_actor_id,
                    subject_worker_id,
                    subject_invocation_id,
                    grant.lifecycle.as_str(),
                    allowed_capabilities,
                    allowed_namespaces,
                    allowed_authority_scopes,
                    allowed_resource_kinds,
                    resource_selectors,
                    file_roots,
                    grant.network_policy,
                    risk_as_str(grant.max_risk),
                    budget,
                    expires_at,
                    grant.can_delegate as i64,
                    grant.approval_required as i64,
                    provenance,
                    grant.trace_id.as_str(),
                    grant.revision as i64,
                    grant.created_at.to_rfc3339(),
                    grant.updated_at.to_rfc3339(),
                ],
            )
            .map_err(|err| sqlite_err("grant.insert", err.to_string()))?;
        Ok(())
    }

    fn update_grant(&self, grant: &EngineGrant) -> Result<()> {
        self.conn
            .execute(
                "UPDATE engine_grants SET
                    lifecycle = ?2, revision = ?3, updated_at = ?4
                 WHERE grant_id = ?1",
                params![
                    grant.grant_id.as_str(),
                    grant.lifecycle.as_str(),
                    grant.revision,
                    grant.updated_at.to_rfc3339(),
                ],
            )
            .map_err(|err| sqlite_err("grant.update", err.to_string()))?;
        Ok(())
    }

    fn record_event(&self, event: &EngineGrantEvent) -> Result<()> {
        self.conn
            .execute(
                "INSERT INTO engine_grant_events
                 (event_id, grant_id, event_type, payload_json, trace_id, occurred_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    event.event_id,
                    event.grant_id.as_str(),
                    event.event_type,
                    json_string(&event.payload, "grant.event.payload")?,
                    event.trace_id.as_str(),
                    event.occurred_at.to_rfc3339(),
                ],
            )
            .map_err(|err| sqlite_err("grant.event", err.to_string()))?;
        Ok(())
    }
}

/// Shared grant backend.
pub enum EngineGrantStoreBackend {
    /// In-memory.
    InMemory(InMemoryEngineGrantStore),
    /// SQLite.
    Sqlite(SqliteEngineGrantStore),
}

impl EngineGrantStoreBackend {
    /// Derive a grant.
    pub fn derive(&mut self, request: DeriveGrant) -> Result<EngineGrant> {
        match self {
            Self::InMemory(store) => store.derive(request),
            Self::Sqlite(store) => store.derive(request),
        }
    }

    /// Inspect a grant.
    pub fn inspect(&self, grant_id: &AuthorityGrantId) -> Result<Option<EngineGrant>> {
        match self {
            Self::InMemory(store) => store.inspect(grant_id),
            Self::Sqlite(store) => store.inspect(grant_id),
        }
    }

    /// List grants.
    pub fn list(&self, filter: ListGrants) -> Result<Vec<EngineGrant>> {
        match self {
            Self::InMemory(store) => store.list(filter),
            Self::Sqlite(store) => store.list(filter),
        }
    }

    /// Revoke a grant.
    pub fn revoke(
        &mut self,
        grant_id: &AuthorityGrantId,
        trace_id: TraceId,
    ) -> Result<EngineGrant> {
        match self {
            Self::InMemory(store) => store.revoke(grant_id, trace_id),
            Self::Sqlite(store) => store.revoke(grant_id, trace_id),
        }
    }

    /// Authorize invocation.
    pub fn authorize_invocation(
        &self,
        function: &FunctionDefinition,
        invocation: &Invocation,
    ) -> Result<EngineGrant> {
        match self {
            Self::InMemory(store) => store.authorize_invocation(function, invocation),
            Self::Sqlite(store) => store.authorize_invocation(function, invocation),
        }
    }
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
    "agent-capability-primer",
    "capability-grant",
    "prompt-runtime",
    "mcp-catalog-refresh",
    "cron-scheduler",
    "test-grant",
    "grant:test",
];

#[cfg(test)]
const TEST_BOOTSTRAP_GRANT_IDS: &[&str] = &[
    "system-grant",
    "manual-grant",
    "external-grant",
    "agent-grant",
    "approval-agent",
    "approval-admin",
    "admin-grant",
];

fn bootstrap_grant(grant_id: &str) -> EngineGrant {
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

fn grant_from_request(
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

fn authorize_with_grant(
    grant: &EngineGrant,
    function: &FunctionDefinition,
    invocation: &Invocation,
) -> Result<()> {
    if grant.lifecycle != EngineGrantLifecycle::Active {
        return Err(EngineError::PolicyViolation(format!(
            "authority grant {} is not active",
            grant.grant_id
        )));
    }
    if let Some(expires_at) = grant.expires_at
        && expires_at <= Utc::now()
    {
        return Err(EngineError::PolicyViolation(format!(
            "authority grant {} is expired",
            grant.grant_id
        )));
    }
    if grant
        .subject_actor_id
        .as_ref()
        .is_some_and(|actor| actor != &invocation.causal_context.actor_id)
    {
        return Err(EngineError::PolicyViolation(format!(
            "authority grant {} subject actor mismatch",
            grant.grant_id
        )));
    }
    if grant.subject_invocation_id.as_ref().is_some_and(|parent| {
        invocation.causal_context.parent_invocation_id.as_ref() != Some(parent)
    }) {
        return Err(EngineError::PolicyViolation(format!(
            "authority grant {} subject invocation mismatch",
            grant.grant_id
        )));
    }
    if grant
        .subject_worker_id
        .as_ref()
        .is_some_and(|worker| worker != &function.owner_worker)
    {
        return Err(EngineError::PolicyViolation(format!(
            "authority grant {} subject worker mismatch",
            grant.grant_id
        )));
    }
    if function.risk_level > grant.max_risk {
        return Err(EngineError::PolicyViolation(format!(
            "function {} risk {:?} exceeds grant {} max risk {:?}",
            function.id, function.risk_level, grant.grant_id, grant.max_risk
        )));
    }
    if !allows_function(grant, &function.id) {
        return Err(EngineError::PolicyViolation(format!(
            "authority grant {} does not allow function {}",
            grant.grant_id, function.id
        )));
    }
    for scope in &function.required_authority.scopes {
        if !allows_item(&grant.allowed_authority_scopes, scope) {
            return Err(EngineError::PolicyViolation(format!(
                "authority grant {} does not allow required authority {scope}",
                grant.grant_id
            )));
        }
    }
    if let Some(kind) = resource_kind_from_invocation(invocation)
        && !allows_item(&grant.allowed_resource_kinds, &kind)
    {
        return Err(EngineError::PolicyViolation(format!(
            "authority grant {} does not allow resource kind {kind}",
            grant.grant_id
        )));
    }
    ensure_resource_selectors(grant, invocation)?;
    Ok(())
}

fn ensure_resource_selectors(grant: &EngineGrant, invocation: &Invocation) -> Result<()> {
    if allows_item(&grant.resource_selectors, "*") {
        return Ok(());
    }
    for resource_id in resource_ids_from_invocation(invocation) {
        if !allows_resource_id(grant, &resource_id) {
            return Err(EngineError::PolicyViolation(format!(
                "authority grant {} does not allow resource {resource_id}",
                grant.grant_id
            )));
        }
    }
    if resource_ids_from_invocation(invocation).is_empty()
        && let Some(kind) = resource_kind_from_invocation(invocation)
        && !allows_item(&grant.resource_selectors, &format!("kind:{kind}"))
    {
        return Err(EngineError::PolicyViolation(format!(
            "authority grant {} does not allow new resource kind {kind}",
            grant.grant_id
        )));
    }
    Ok(())
}

fn allows_resource_id(grant: &EngineGrant, resource_id: &str) -> bool {
    allows_item(&grant.resource_selectors, resource_id)
        || allows_item(
            &grant.resource_selectors,
            &format!("resource:{resource_id}"),
        )
}

fn resource_ids_from_invocation(invocation: &Invocation) -> Vec<String> {
    [
        "resourceId",
        "sourceResourceId",
        "targetResourceId",
        "goalResourceId",
    ]
    .into_iter()
    .filter_map(|field| invocation.payload.get(field).and_then(Value::as_str))
    .map(str::to_owned)
    .collect()
}

fn resource_kind_from_invocation(invocation: &Invocation) -> Option<String> {
    match invocation.function_id.as_str() {
        "resource::create" | "artifact::create" | "goal::create" | "claim::attach"
        | "evidence::attach" | "decision::create" => invocation
            .payload
            .get("kind")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .or_else(|| wrapper_resource_kind(invocation.function_id.as_str()).map(str::to_owned)),
        _ => wrapper_resource_kind(invocation.function_id.as_str()).map(str::to_owned),
    }
}

fn wrapper_resource_kind(function_id: &str) -> Option<&'static str> {
    match function_id {
        id if id.starts_with("artifact::") => Some("artifact"),
        id if id.starts_with("goal::") => Some("goal"),
        id if id.starts_with("claim::") => Some("claim"),
        id if id.starts_with("evidence::") => Some("evidence"),
        id if id.starts_with("decision::") => Some("decision"),
        _ => None,
    }
}

fn ensure_parent_can_derive(parent: &EngineGrant) -> Result<()> {
    authorize_active(parent)?;
    if !parent.can_delegate {
        return Err(EngineError::PolicyViolation(format!(
            "authority grant {} cannot delegate",
            parent.grant_id
        )));
    }
    Ok(())
}

fn ensure_child_narrows_parent(parent: &EngineGrant, child: &DeriveGrant) -> Result<()> {
    ensure_list_narrows(
        "capabilities",
        &parent.allowed_capabilities,
        &child.allowed_capabilities,
    )?;
    ensure_list_narrows(
        "namespaces",
        &parent.allowed_namespaces,
        &child.allowed_namespaces,
    )?;
    ensure_list_narrows(
        "authority scopes",
        &parent.allowed_authority_scopes,
        &child.allowed_authority_scopes,
    )?;
    ensure_list_narrows(
        "resource kinds",
        &parent.allowed_resource_kinds,
        &child.allowed_resource_kinds,
    )?;
    ensure_list_narrows(
        "resource selectors",
        &parent.resource_selectors,
        &child.resource_selectors,
    )?;
    ensure_file_roots_narrow(&parent.file_roots, &child.file_roots)?;
    if network_rank(&child.network_policy)? > network_rank(&parent.network_policy)? {
        return Err(EngineError::PolicyViolation(
            "child grant network policy exceeds parent".to_owned(),
        ));
    }
    if child.max_risk > parent.max_risk {
        return Err(EngineError::PolicyViolation(
            "child grant risk exceeds parent".to_owned(),
        ));
    }
    if let (Some(parent_expiry), Some(child_expiry)) = (parent.expires_at, child.expires_at)
        && child_expiry > parent_expiry
    {
        return Err(EngineError::PolicyViolation(
            "child grant expiry exceeds parent".to_owned(),
        ));
    }
    if parent.expires_at.is_some() && child.expires_at.is_none() {
        return Err(EngineError::PolicyViolation(
            "child grant cannot remove parent expiry".to_owned(),
        ));
    }
    if child.can_delegate && !parent.can_delegate {
        return Err(EngineError::PolicyViolation(
            "child grant delegation exceeds parent".to_owned(),
        ));
    }
    if parent.approval_required && !child.approval_required {
        return Err(EngineError::PolicyViolation(
            "child grant cannot relax approval requirement".to_owned(),
        ));
    }
    Ok(())
}

fn authorize_active(grant: &EngineGrant) -> Result<()> {
    if grant.lifecycle != EngineGrantLifecycle::Active {
        return Err(EngineError::PolicyViolation(format!(
            "authority grant {} is not active",
            grant.grant_id
        )));
    }
    if let Some(expires_at) = grant.expires_at
        && expires_at <= Utc::now()
    {
        return Err(EngineError::PolicyViolation(format!(
            "authority grant {} is expired",
            grant.grant_id
        )));
    }
    Ok(())
}

fn allows_function(grant: &EngineGrant, function_id: &FunctionId) -> bool {
    allows_item(&grant.allowed_capabilities, function_id.as_str())
        || allows_item(&grant.allowed_namespaces, function_id.namespace())
}

fn allows_item(allowed: &[String], value: &str) -> bool {
    allowed.iter().any(|item| item == "*" || item == value)
}

fn ensure_list_narrows(label: &str, parent: &[String], child: &[String]) -> Result<()> {
    if child.is_empty() {
        return Err(EngineError::PolicyViolation(format!(
            "child grant {label} must not be empty"
        )));
    }
    if parent.iter().any(|item| item == "*") {
        return Ok(());
    }
    for item in child {
        if item == "*" || !parent.iter().any(|parent| parent == item) {
            return Err(EngineError::PolicyViolation(format!(
                "child grant {label} exceeds parent"
            )));
        }
    }
    Ok(())
}

fn ensure_file_roots_narrow(parent: &[String], child: &[String]) -> Result<()> {
    if child.is_empty() {
        return Err(EngineError::PolicyViolation(
            "child grant file roots must not be empty".to_owned(),
        ));
    }
    if parent.iter().any(|item| item == "*") {
        return Ok(());
    }
    for root in child {
        if root == "*" {
            return Err(EngineError::PolicyViolation(
                "child grant file roots exceed parent".to_owned(),
            ));
        }
        if !parent.iter().any(|parent| root.starts_with(parent)) {
            return Err(EngineError::PolicyViolation(
                "child grant file roots exceed parent".to_owned(),
            ));
        }
    }
    Ok(())
}

fn network_rank(value: &str) -> Result<u8> {
    match value {
        "none" => Ok(0),
        "loopback" => Ok(1),
        "declared" => Ok(2),
        "unrestricted" => Ok(3),
        _ => Err(EngineError::PolicyViolation(format!(
            "unsupported network policy {value}"
        ))),
    }
}

fn validate_derive_request(request: &DeriveGrant) -> Result<()> {
    validate_non_empty_list("allowedCapabilities", &request.allowed_capabilities)?;
    validate_non_empty_list("allowedNamespaces", &request.allowed_namespaces)?;
    validate_non_empty_list("allowedAuthorityScopes", &request.allowed_authority_scopes)?;
    validate_non_empty_list("allowedResourceKinds", &request.allowed_resource_kinds)?;
    validate_non_empty_list("resourceSelectors", &request.resource_selectors)?;
    validate_non_empty_list("fileRoots", &request.file_roots)?;
    let _ = network_rank(&request.network_policy)?;
    if let Some(expires_at) = request.expires_at
        && expires_at <= Utc::now()
    {
        return Err(EngineError::PolicyViolation(
            "child grant expiry must be in the future".to_owned(),
        ));
    }
    Ok(())
}

fn validate_non_empty_list(field: &str, values: &[String]) -> Result<()> {
    if values.is_empty() || values.iter().any(|value| value.trim().is_empty()) {
        return Err(EngineError::PolicyViolation(format!(
            "{field} must contain non-empty values"
        )));
    }
    Ok(())
}

fn validate_list_limit(limit: usize) -> Result<()> {
    if limit == 0 {
        return Err(EngineError::PolicyViolation(
            "grant list limit must be greater than zero".to_owned(),
        ));
    }
    Ok(())
}

fn grant_event(
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

fn risk_as_str(risk: RiskLevel) -> &'static str {
    match risk {
        RiskLevel::Low => "low",
        RiskLevel::Medium => "medium",
        RiskLevel::High => "high",
        RiskLevel::Critical => "critical",
    }
}

fn parse_risk(value: &str) -> Result<RiskLevel> {
    match value {
        "low" => Ok(RiskLevel::Low),
        "medium" => Ok(RiskLevel::Medium),
        "high" => Ok(RiskLevel::High),
        "critical" => Ok(RiskLevel::Critical),
        _ => Err(EngineError::LedgerFailure {
            operation: "grant.risk",
            message: format!("invalid grant risk {value}"),
        }),
    }
}

fn row_to_grant(row: &Row<'_>) -> rusqlite::Result<EngineGrant> {
    let lifecycle: String = row.get("lifecycle")?;
    let max_risk: String = row.get("max_risk")?;
    let expires_at: Option<String> = row.get("expires_at")?;
    let created_at: String = row.get("created_at")?;
    let updated_at: String = row.get("updated_at")?;
    Ok(EngineGrant {
        grant_id: AuthorityGrantId::new(row.get::<_, String>("grant_id")?)
            .map_err(sql_from_engine)?,
        parent_grant_id: row
            .get::<_, Option<String>>("parent_grant_id")?
            .map(AuthorityGrantId::new)
            .transpose()
            .map_err(sql_from_engine)?,
        subject_actor_id: row
            .get::<_, Option<String>>("subject_actor_id")?
            .map(ActorId::new)
            .transpose()
            .map_err(sql_from_engine)?,
        subject_worker_id: row
            .get::<_, Option<String>>("subject_worker_id")?
            .map(WorkerId::new)
            .transpose()
            .map_err(sql_from_engine)?,
        subject_invocation_id: row
            .get::<_, Option<String>>("subject_invocation_id")?
            .map(InvocationId::new)
            .transpose()
            .map_err(sql_from_engine)?,
        lifecycle: EngineGrantLifecycle::parse(&lifecycle).map_err(sql_from_engine)?,
        allowed_capabilities: json_array(row, "allowed_capabilities_json")?,
        allowed_namespaces: json_array(row, "allowed_namespaces_json")?,
        allowed_authority_scopes: json_array(row, "allowed_authority_scopes_json")?,
        allowed_resource_kinds: json_array(row, "allowed_resource_kinds_json")?,
        resource_selectors: json_array(row, "resource_selectors_json")?,
        file_roots: json_array(row, "file_roots_json")?,
        network_policy: row.get("network_policy")?,
        max_risk: parse_risk(&max_risk).map_err(sql_from_engine)?,
        budget: json_value(row, "budget_json")?,
        expires_at: expires_at
            .map(|value| parse_datetime(&value, "expires_at"))
            .transpose()?,
        can_delegate: row.get::<_, i64>("can_delegate")? != 0,
        approval_required: row.get::<_, i64>("approval_required")? != 0,
        provenance: json_value(row, "provenance_json")?,
        trace_id: TraceId::new(row.get::<_, String>("trace_id")?).map_err(sql_from_engine)?,
        revision: row.get::<_, i64>("revision")? as u64,
        created_at: parse_datetime(&created_at, "created_at")?,
        updated_at: parse_datetime(&updated_at, "updated_at")?,
    })
}

fn json_array(row: &Row<'_>, field: &str) -> rusqlite::Result<Vec<String>> {
    let raw: String = row.get(field)?;
    serde_json::from_str(&raw)
        .map_err(|error| rusqlite::Error::FromSqlConversionFailure(0, Type::Text, Box::new(error)))
}

fn json_value(row: &Row<'_>, field: &str) -> rusqlite::Result<Value> {
    let raw: String = row.get(field)?;
    serde_json::from_str(&raw)
        .map_err(|error| rusqlite::Error::FromSqlConversionFailure(0, Type::Text, Box::new(error)))
}

fn parse_datetime(value: &str, field: &'static str) -> rusqlite::Result<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|error| {
            rusqlite::Error::FromSqlConversionFailure(field.len(), Type::Text, Box::new(error))
        })
}

fn json_string<T: Serialize>(value: &T, operation: &'static str) -> Result<String> {
    serde_json::to_string(value).map_err(|error| EngineError::LedgerFailure {
        operation,
        message: error.to_string(),
    })
}

fn sql_from_engine(error: EngineError) -> rusqlite::Error {
    rusqlite::Error::FromSqlConversionFailure(0, Type::Text, Box::new(error))
}

fn sqlite_err(operation: &'static str, message: String) -> EngineError {
    EngineError::LedgerFailure { operation, message }
}
