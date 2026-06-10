//! Engine-owned grants.
//!
//! Grants are the durable authority model for the modular substrate. Callers
//! carry a grant id, but the engine resolves that id to stored policy before a
//! handler runs. Raw caller-supplied authority scope strings are audit context,
//! not permission truth.
//!
//! | Submodule | Role |
//! |---|---|
//! | `authorization` | Runtime invocation checks against resolved durable grants. |
//! | `derivation` | Parent-to-child narrowing validation before grant persistence. |
//! | `model` | Durable grant/request/event records and bootstrap root grants. |
//! | `paths` | Shared canonical containment helpers for file-root policy. |
//! | `policy_hash` | Deterministic policy hashes for scoped worker tokens. |
//! | `sqlite_codec` | SQLite row encoding and decoding for durable grants. |
//!
//! INVARIANT: derivation and invocation authorization use canonical path
//! containment for file roots. Raw string-prefix checks are not authority.
//! INVARIANT: when `remainingInvocations` is present, invocation execution
//! consumes one durable grant budget unit before the handler runs.

use std::collections::BTreeMap;
use std::path::Path;

use chrono::Utc;
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};

use crate::engine::invocation::model::Invocation;
use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::ids::{ActorId, AuthorityGrantId, InvocationId, TraceId, WorkerId};
use crate::engine::kernel::types::FunctionDefinition;

mod authorization;
mod derivation;
mod model;
mod paths;
mod policy_hash;
mod sqlite_codec;

pub use model::{
    BOOTSTRAP_GRANT_IDS, ConsumeGrantInvocationBudget, DeriveGrant, EngineGrant, EngineGrantEvent,
    EngineGrantLifecycle, ListGrants,
};
pub(crate) use policy_hash::{bootstrap_grant_policy_hash, grant_policy_hash};

use authorization::authorize_with_grant;
use derivation::{ensure_child_narrows_parent, ensure_parent_can_derive, validate_derive_request};
#[cfg(test)]
use model::TEST_BOOTSTRAP_GRANT_IDS;
use model::{bootstrap_grant, grant_event, grant_from_request};
use sqlite_codec::{json_string, risk_as_str, row_to_grant, sqlite_err};

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

    /// Consume one invocation unit from a grant budget immediately before
    /// handler execution. Grants without `remainingInvocations` are unlimited.
    pub fn consume_invocation_budget(
        &mut self,
        request: ConsumeGrantInvocationBudget,
    ) -> Result<EngineGrant> {
        let mut grant = self.require_grant(&request.grant_id)?;
        ensure_grant_can_consume(&grant)?;
        let Some(remaining) = remaining_invocations(&grant.budget) else {
            return Ok(grant);
        };
        if remaining == 0 {
            return Err(exhausted_invocation_budget(&grant));
        }
        set_remaining_invocations(&mut grant.budget, remaining - 1)?;
        let previous_revision = grant.revision;
        grant.revision += 1;
        grant.updated_at = Utc::now();
        self.grants.insert(request.grant_id.clone(), grant.clone());
        self.record_event(grant_event(
            &request.grant_id,
            "grant.budget_consumed",
            json!({
                "invocationId": request.invocation_id.as_str(),
                "functionId": request.function_id.as_str(),
                "budgetField": "remainingInvocations",
                "consumed": 1,
                "remainingInvocations": remaining - 1,
                "previousRevision": previous_revision,
                "revision": grant.revision
            }),
            request.trace_id,
        ));
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

    /// Consume one invocation unit from a grant budget immediately before
    /// handler execution. Grants without `remainingInvocations` are unlimited.
    pub fn consume_invocation_budget(
        &mut self,
        request: ConsumeGrantInvocationBudget,
    ) -> Result<EngineGrant> {
        let mut grant = self.require_grant(&request.grant_id)?;
        ensure_grant_can_consume(&grant)?;
        let Some(remaining) = remaining_invocations(&grant.budget) else {
            return Ok(grant);
        };
        if remaining == 0 {
            return Err(exhausted_invocation_budget(&grant));
        }

        let previous_revision = grant.revision;
        let mut budget = grant.budget.clone();
        set_remaining_invocations(&mut budget, remaining - 1)?;
        let now = Utc::now();
        let next_revision = previous_revision + 1;
        let budget_json = json_string(&budget, "grant.budget.consume")?;
        let event = grant_event(
            &request.grant_id,
            "grant.budget_consumed",
            json!({
                "invocationId": request.invocation_id.as_str(),
                "functionId": request.function_id.as_str(),
                "budgetField": "remainingInvocations",
                "consumed": 1,
                "remainingInvocations": remaining - 1,
                "previousRevision": previous_revision,
                "revision": next_revision
            }),
            request.trace_id,
        );
        let payload_json = json_string(&event.payload, "grant.event.payload")?;
        let tx = self
            .conn
            .unchecked_transaction()
            .map_err(|err| sqlite_err("grant.consume.transaction", err.to_string()))?;
        let updated = tx
            .execute(
                "UPDATE engine_grants SET
                    budget_json = ?2, revision = ?3, updated_at = ?4
                 WHERE grant_id = ?1
                   AND lifecycle = 'active'
                   AND revision = ?5",
                params![
                    request.grant_id.as_str(),
                    budget_json,
                    next_revision as i64,
                    now.to_rfc3339(),
                    previous_revision as i64,
                ],
            )
            .map_err(|err| sqlite_err("grant.consume.update", err.to_string()))?;
        if updated != 1 {
            return Err(EngineError::PolicyViolation(format!(
                "authority grant {} budget could not be consumed",
                request.grant_id
            )));
        }
        tx.execute(
            "INSERT INTO engine_grant_events
             (event_id, grant_id, event_type, payload_json, trace_id, occurred_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                event.event_id,
                event.grant_id.as_str(),
                event.event_type,
                payload_json,
                event.trace_id.as_str(),
                event.occurred_at.to_rfc3339(),
            ],
        )
        .map_err(|err| sqlite_err("grant.consume.event", err.to_string()))?;
        tx.commit()
            .map_err(|err| sqlite_err("grant.consume.commit", err.to_string()))?;

        grant.budget = budget;
        grant.revision = next_revision;
        grant.updated_at = now;
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
                    provenance_json, trace_id, revision, created_at, updated_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13,
                           ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22)",
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

    /// Consume one invocation budget unit.
    pub fn consume_invocation_budget(
        &mut self,
        request: ConsumeGrantInvocationBudget,
    ) -> Result<EngineGrant> {
        match self {
            Self::InMemory(store) => store.consume_invocation_budget(request),
            Self::Sqlite(store) => store.consume_invocation_budget(request),
        }
    }
}

fn validate_list_limit(limit: usize) -> Result<()> {
    if limit == 0 {
        return Err(EngineError::PolicyViolation(
            "grant list limit must be greater than zero".to_owned(),
        ));
    }
    Ok(())
}

fn ensure_grant_can_consume(grant: &EngineGrant) -> Result<()> {
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

fn remaining_invocations(budget: &Value) -> Option<u64> {
    budget.get("remainingInvocations").and_then(Value::as_u64)
}

fn set_remaining_invocations(budget: &mut Value, remaining: u64) -> Result<()> {
    let Some(object) = budget.as_object_mut() else {
        return Err(EngineError::PolicyViolation(
            "grant budget must be an object".to_owned(),
        ));
    };
    object.insert("remainingInvocations".to_owned(), json!(remaining));
    Ok(())
}

fn exhausted_invocation_budget(grant: &EngineGrant) -> EngineError {
    EngineError::PolicyViolation(format!(
        "authority grant {} budget remainingInvocations is exhausted",
        grant.grant_id
    ))
}
