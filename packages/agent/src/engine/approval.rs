//! Engine approval primitive.
//!
//! Approvals are resumable authority records for high-risk agent-visible
//! invocations. A pending approval stores the original invocation intent,
//! idempotency key, trace, actor, authority scopes, target contract metadata,
//! and payload fingerprint so resolution can resume the same causal action
//! instead of creating a second, unrelated command path. Approval idempotency is
//! scoped by function, session, and workspace, matching the engine ledger
//! instead of treating model-chosen keys as globally unique across unrelated
//! sessions.

use std::collections::BTreeMap;
use std::path::Path;

use chrono::{DateTime, Utc};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};

use super::discovery::ActorKind;
use super::errors::{EngineError, Result};
use super::ids::{ActorId, AuthorityGrantId, FunctionId, InvocationId, TraceId, TriggerId};
use super::invocation::{CausalContext, InvocationResult};
use super::ledger::StoredEngineError;
use super::types::{
    AuthorityRequirement, CompensationContract, DeliveryMode, EffectClass, FunctionDefinition,
    IdempotencyContract, IdempotencyKeySource, LedgerKind, ReplayBehavior,
    ResourceLeaseRequirement, RiskLevel, VisibilityScope,
};

use sqlite_codec::{json_err, row_to_record, sqlite_err, storage_err};

mod sqlite_codec;

/// Approval lifecycle status.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ApprovalStatus {
    /// Approval is waiting for a decision.
    Pending,
    /// Approval was granted, but the target has not completed yet.
    Approved,
    /// Approval was denied.
    Denied,
    /// Approved target invocation completed successfully.
    Executed,
    /// Approved target invocation failed.
    Failed,
}

impl ApprovalStatus {
    /// Stable storage string.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Approved => "approved",
            Self::Denied => "denied",
            Self::Executed => "executed",
            Self::Failed => "failed",
        }
    }
}

/// Approval decision.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ApprovalDecision {
    /// Grant authority and resume the stored invocation.
    Approve,
    /// Deny the invocation.
    Deny,
}

/// Durable approval record.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineApprovalRecord {
    /// Stable approval id.
    pub approval_id: String,
    /// Target function.
    pub function_id: FunctionId,
    /// Original payload.
    pub payload: Value,
    /// Stable fingerprint of function + payload.
    pub payload_fingerprint: String,
    /// Actor that requested the original invocation.
    pub actor_id: ActorId,
    /// Actor kind.
    pub actor_kind: ActorKind,
    /// Authority grant used by the original invocation.
    pub authority_grant_id: AuthorityGrantId,
    /// Authority scopes present on the original invocation.
    pub authority_scopes: Vec<String>,
    /// Original trace id.
    pub trace_id: TraceId,
    /// Original parent invocation, if any.
    pub parent_invocation_id: Option<InvocationId>,
    /// Original trigger, if any.
    pub trigger_id: Option<TriggerId>,
    /// Optional session scope.
    pub session_id: Option<String>,
    /// Optional workspace scope.
    pub workspace_id: Option<String>,
    /// Original idempotency key.
    pub idempotency_key: Option<String>,
    /// Original delivery mode.
    pub delivery_mode: DeliveryMode,
    /// Server-owned target contract snapshot captured when the approval was
    /// created.
    pub target_metadata: Option<EngineApprovalTargetMetadata>,
    /// Current status.
    pub status: ApprovalStatus,
    /// Decision actor.
    pub decision_actor_id: Option<ActorId>,
    /// Decision timestamp.
    pub decided_at: Option<DateTime<Utc>>,
    /// Target result, once executed.
    pub result: Option<Value>,
    /// Target error, once failed.
    pub error: Option<StoredEngineError>,
    /// Creation timestamp.
    pub created_at: DateTime<Utc>,
    /// Last update timestamp.
    pub updated_at: DateTime<Utc>,
}

/// Server-owned target contract metadata captured on an approval record.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineApprovalTargetMetadata {
    /// Target side-effect class.
    pub effect_class: EffectClass,
    /// Target risk level.
    pub risk_level: RiskLevel,
    /// Authority requirement declared by the target function.
    pub required_authority: EngineApprovalAuthorityMetadata,
    /// Idempotency contract declared by the target function.
    pub idempotency: Option<EngineApprovalIdempotencyMetadata>,
    /// Resource lease requirement declared by the target function.
    pub resource_lease: Option<ResourceLeaseRequirement>,
    /// Compensation contract declared by the target function.
    pub compensation: Option<CompensationContract>,
}

/// Approval-facing authority metadata with stable transport keys.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineApprovalAuthorityMetadata {
    /// Required authority scopes.
    pub scopes: Vec<String>,
    /// Whether explicit approval is required.
    pub approval_required: bool,
}

impl From<&AuthorityRequirement> for EngineApprovalAuthorityMetadata {
    fn from(requirement: &AuthorityRequirement) -> Self {
        Self {
            scopes: requirement.scopes.clone(),
            approval_required: requirement.approval_required,
        }
    }
}

/// Approval-facing idempotency metadata with stable transport keys.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineApprovalIdempotencyMetadata {
    /// Key source.
    pub key_source: IdempotencyKeySource,
    /// Dedupe scope.
    pub dedupe_scope: VisibilityScope,
    /// Duplicate replay behavior.
    pub replay_behavior: ReplayBehavior,
    /// Ledger kind.
    pub ledger_kind: LedgerKind,
}

impl From<&IdempotencyContract> for EngineApprovalIdempotencyMetadata {
    fn from(contract: &IdempotencyContract) -> Self {
        Self {
            key_source: contract.key_source.clone(),
            dedupe_scope: contract.dedupe_scope.clone(),
            replay_behavior: contract.replay_behavior.clone(),
            ledger_kind: contract.ledger_kind.clone(),
        }
    }
}

impl EngineApprovalTargetMetadata {
    /// Snapshot target metadata from the function catalog definition.
    #[must_use]
    pub fn from_function(function: &FunctionDefinition) -> Self {
        Self {
            effect_class: function.effect_class,
            risk_level: function.risk_level,
            required_authority: EngineApprovalAuthorityMetadata::from(&function.required_authority),
            idempotency: function
                .idempotency
                .as_ref()
                .map(EngineApprovalIdempotencyMetadata::from),
            resource_lease: function.resource_lease.clone(),
            compensation: function.compensation.clone(),
        }
    }
}

impl EngineApprovalRecord {
    /// Rebuild the stored target causal context.
    #[must_use]
    pub fn causal_context(&self) -> CausalContext {
        let mut context = CausalContext::new(
            self.actor_id.clone(),
            self.actor_kind.clone(),
            self.authority_grant_id.clone(),
            self.trace_id.clone(),
        );
        for scope in &self.authority_scopes {
            context = context.with_scope(scope.clone());
        }
        context = context.with_scope("approval.granted");
        if let Some(parent) = &self.parent_invocation_id {
            context = context.with_parent_invocation(parent.clone());
        }
        if let Some(trigger_id) = &self.trigger_id {
            context = context.with_trigger_id(trigger_id.clone());
        }
        if let Some(session_id) = &self.session_id {
            context = context.with_session_id(session_id.clone());
        }
        if let Some(workspace_id) = &self.workspace_id {
            context = context.with_workspace_id(workspace_id.clone());
        }
        if let Some(key) = &self.idempotency_key {
            context = context.with_idempotency_key(key.clone());
        }
        context.delivery_mode = self.delivery_mode;
        context
    }
}

/// Request used to create an approval record.
#[derive(Clone, Debug, PartialEq)]
pub struct EngineApprovalRequest {
    /// Target function id.
    pub function_id: FunctionId,
    /// Target payload.
    pub payload: Value,
    /// Causal context to preserve.
    pub causal_context: CausalContext,
    /// Original delivery mode.
    pub delivery_mode: DeliveryMode,
    /// Optional target contract metadata snapshot.
    pub target_metadata: Option<EngineApprovalTargetMetadata>,
}

/// Result of creating or replaying an approval request.
#[derive(Clone, Debug, PartialEq)]
pub struct EngineApprovalRequestOutcome {
    /// Approval record returned for the request.
    pub record: EngineApprovalRecord,
    /// Whether this request created a fresh pending approval.
    pub created: bool,
}

/// Result of an engine-owned auto-approval execution.
#[derive(Clone, Debug, PartialEq)]
pub struct EngineAutoApprovalOutcome {
    /// Final approval record after the child invocation completed.
    pub record: EngineApprovalRecord,
    /// Child invocation result.
    pub child_result: InvocationResult,
    /// Whether this path created a new approval audit record.
    pub created: bool,
}

impl EngineApprovalRequestOutcome {
    fn created(record: EngineApprovalRecord) -> Self {
        Self {
            record,
            created: true,
        }
    }

    fn replayed(record: EngineApprovalRecord) -> Self {
        Self {
            record,
            created: false,
        }
    }
}

/// In-memory approval store.
#[derive(Default)]
pub struct InMemoryEngineApprovalStore {
    records: BTreeMap<String, EngineApprovalRecord>,
    by_idempotency: BTreeMap<String, String>,
}

impl InMemoryEngineApprovalStore {
    /// Create an empty approval store.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Create or replay an approval request.
    pub fn request(
        &mut self,
        request: EngineApprovalRequest,
    ) -> Result<EngineApprovalRequestOutcome> {
        let fingerprint = approval_fingerprint(&request.function_id, &request.payload);
        if let Some(key) = request.causal_context.idempotency_key.as_deref() {
            let scoped_key = approval_idempotency_scope_for_context(
                &request.function_id,
                &request.causal_context,
                key,
            );
            if let Some(existing_id) = self.by_idempotency.get(&scoped_key) {
                let existing = self.records.get(existing_id).cloned().ok_or_else(|| {
                    EngineError::LedgerFailure {
                        operation: "approval.request",
                        message: "idempotency index points to a missing approval".to_owned(),
                    }
                })?;
                if existing.payload_fingerprint != fingerprint {
                    return Err(EngineError::IdempotencyConflict {
                        function_id: request.function_id.to_string(),
                        key: key.to_owned(),
                        reason: "approval request payload fingerprint differs".to_owned(),
                    });
                }
                return Ok(EngineApprovalRequestOutcome::replayed(existing));
            }
        }

        let now = Utc::now();
        let approval_id = InvocationId::generate().to_string();
        let record = EngineApprovalRecord {
            approval_id: approval_id.clone(),
            function_id: request.function_id,
            payload: request.payload,
            payload_fingerprint: fingerprint,
            actor_id: request.causal_context.actor_id,
            actor_kind: request.causal_context.actor_kind,
            authority_grant_id: request.causal_context.authority_grant_id,
            authority_scopes: request.causal_context.authority_scopes,
            trace_id: request.causal_context.trace_id,
            parent_invocation_id: request.causal_context.parent_invocation_id,
            trigger_id: request.causal_context.trigger_id,
            session_id: request.causal_context.session_id,
            workspace_id: request.causal_context.workspace_id,
            idempotency_key: request.causal_context.idempotency_key,
            delivery_mode: request.delivery_mode,
            target_metadata: request.target_metadata,
            status: ApprovalStatus::Pending,
            decision_actor_id: None,
            decided_at: None,
            result: None,
            error: None,
            created_at: now,
            updated_at: now,
        };
        if let Some(scoped_key) = approval_idempotency_scope_for_record(&record) {
            self.by_idempotency.insert(scoped_key, approval_id.clone());
        }
        self.records.insert(approval_id, record.clone());
        Ok(EngineApprovalRequestOutcome::created(record))
    }

    /// Get one approval.
    pub fn get(&self, approval_id: &str) -> Result<Option<EngineApprovalRecord>> {
        Ok(self.records.get(approval_id).cloned())
    }

    /// List approvals.
    pub fn list(
        &self,
        status: Option<ApprovalStatus>,
        session_id: Option<&str>,
        limit: usize,
    ) -> Result<Vec<EngineApprovalRecord>> {
        if limit == 0 {
            return Err(EngineError::PolicyViolation(
                "approval list limit must be greater than zero".to_owned(),
            ));
        }
        Ok(self
            .records
            .values()
            .filter(|record| status.is_none_or(|status| record.status == status))
            .filter(|record| {
                session_id
                    .map(|session_id| record.session_id.as_deref() == Some(session_id))
                    .unwrap_or(true)
            })
            .take(limit.min(500))
            .cloned()
            .collect())
    }

    /// Resolve a pending approval.
    pub fn resolve(
        &mut self,
        approval_id: &str,
        decision: ApprovalDecision,
        actor_id: ActorId,
    ) -> Result<EngineApprovalRecord> {
        let record = self
            .records
            .get_mut(approval_id)
            .ok_or_else(|| EngineError::NotFound {
                kind: "approval",
                id: approval_id.to_owned(),
            })?;
        if matches!(
            record.status,
            ApprovalStatus::Executed | ApprovalStatus::Failed | ApprovalStatus::Denied
        ) {
            return Ok(record.clone());
        }
        let now = Utc::now();
        record.status = match decision {
            ApprovalDecision::Approve => ApprovalStatus::Approved,
            ApprovalDecision::Deny => ApprovalStatus::Denied,
        };
        record.decision_actor_id = Some(actor_id);
        record.decided_at = Some(now);
        record.updated_at = now;
        Ok(record.clone())
    }

    /// Complete an approved invocation.
    pub fn complete(
        &mut self,
        approval_id: &str,
        result: &InvocationResult,
    ) -> Result<EngineApprovalRecord> {
        let record = self
            .records
            .get_mut(approval_id)
            .ok_or_else(|| EngineError::NotFound {
                kind: "approval",
                id: approval_id.to_owned(),
            })?;
        record.status = if result.error.is_some() {
            ApprovalStatus::Failed
        } else {
            ApprovalStatus::Executed
        };
        record.result = result.value.clone();
        record.error = result
            .error
            .as_ref()
            .map(StoredEngineError::from_engine_error);
        record.updated_at = Utc::now();
        Ok(record.clone())
    }
}

/// SQLite approval store.
pub struct SqliteEngineApprovalStore {
    conn: Connection,
}

impl SqliteEngineApprovalStore {
    /// Open an approval store in the isolated engine ledger DB.
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let conn =
            Connection::open(path).map_err(|err| sqlite_err("approval.open", err.to_string()))?;
        let store = Self { conn };
        store.init()?;
        Ok(store)
    }

    fn init(&self) -> Result<()> {
        self.conn
            .execute_batch(
                r#"
CREATE TABLE IF NOT EXISTS engine_approvals (
  approval_id TEXT PRIMARY KEY,
  function_id TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  payload_fingerprint TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  actor_kind TEXT NOT NULL,
  authority_grant_id TEXT NOT NULL,
  authority_scopes_json TEXT NOT NULL,
  trace_id TEXT NOT NULL,
  parent_invocation_id TEXT,
  trigger_id TEXT,
  session_id TEXT,
  workspace_id TEXT,
  idempotency_key TEXT,
  delivery_mode TEXT NOT NULL,
  target_metadata_json TEXT,
  status TEXT NOT NULL,
  decision_actor_id TEXT,
  decided_at TEXT,
  result_json TEXT,
  error_json TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
"#,
            )
            .map_err(|err| sqlite_err("approval.init", err.to_string()))?;
        self.migrate_approval_idempotency_scope()?;
        self.migrate_target_metadata_column()?;
        self.conn
            .execute_batch(
                r#"
CREATE UNIQUE INDEX IF NOT EXISTS idx_engine_approvals_idempotency_scope
ON engine_approvals (
  function_id,
  COALESCE(session_id, ''),
  COALESCE(workspace_id, ''),
  idempotency_key
)
WHERE idempotency_key IS NOT NULL;
"#,
            )
            .map_err(|err| sqlite_err("approval.init.indexes", err.to_string()))
    }

    fn migrate_approval_idempotency_scope(&self) -> Result<()> {
        let table_sql: Option<String> = self
            .conn
            .query_row(
                "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'engine_approvals'",
                [],
                |row| row.get(0),
            )
            .optional()
            .map_err(|err| sqlite_err("approval.migrate.inspect", err.to_string()))?;
        if !table_sql
            .as_deref()
            .is_some_and(|sql| sql.contains("idempotency_key TEXT UNIQUE"))
        {
            return Ok(());
        }

        self.conn
            .execute_batch(
                r#"
ALTER TABLE engine_approvals RENAME TO engine_approvals_global_idempotency_migration;
CREATE TABLE engine_approvals (
  approval_id TEXT PRIMARY KEY,
  function_id TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  payload_fingerprint TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  actor_kind TEXT NOT NULL,
  authority_grant_id TEXT NOT NULL,
  authority_scopes_json TEXT NOT NULL,
  trace_id TEXT NOT NULL,
  parent_invocation_id TEXT,
  trigger_id TEXT,
  session_id TEXT,
  workspace_id TEXT,
  idempotency_key TEXT,
  delivery_mode TEXT NOT NULL,
  target_metadata_json TEXT,
  status TEXT NOT NULL,
  decision_actor_id TEXT,
  decided_at TEXT,
  result_json TEXT,
  error_json TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
INSERT INTO engine_approvals (
  approval_id, function_id, payload_json, payload_fingerprint,
  actor_id, actor_kind, authority_grant_id, authority_scopes_json,
  trace_id, parent_invocation_id, trigger_id, session_id, workspace_id,
  idempotency_key, delivery_mode, target_metadata_json, status, decision_actor_id, decided_at,
  result_json, error_json, created_at, updated_at
)
SELECT
  approval_id, function_id, payload_json, payload_fingerprint,
  actor_id, actor_kind, authority_grant_id, authority_scopes_json,
  trace_id, parent_invocation_id, trigger_id, session_id, workspace_id,
  idempotency_key, delivery_mode, NULL, status, decision_actor_id, decided_at,
  result_json, error_json, created_at, updated_at
FROM engine_approvals_global_idempotency_migration;
DROP TABLE engine_approvals_global_idempotency_migration;
"#,
            )
            .map_err(|err| sqlite_err("approval.migrate.scope", err.to_string()))
    }

    fn migrate_target_metadata_column(&self) -> Result<()> {
        let has_column = {
            let mut stmt = self
                .conn
                .prepare("PRAGMA table_info(engine_approvals)")
                .map_err(|err| sqlite_err("approval.migrate.metadata.inspect", err.to_string()))?;
            let columns = stmt
                .query_map([], |row| row.get::<_, String>(1))
                .map_err(|err| sqlite_err("approval.migrate.metadata.columns", err.to_string()))?;
            let mut found = false;
            for column in columns {
                if column.map_err(|err| {
                    sqlite_err("approval.migrate.metadata.column", err.to_string())
                })? == "target_metadata_json"
                {
                    found = true;
                    break;
                }
            }
            found
        };
        if has_column {
            return Ok(());
        }
        self.conn
            .execute(
                "ALTER TABLE engine_approvals ADD COLUMN target_metadata_json TEXT",
                [],
            )
            .map_err(|err| sqlite_err("approval.migrate.metadata", err.to_string()))?;
        Ok(())
    }

    /// Create or replay an approval request.
    pub fn request(
        &mut self,
        request: EngineApprovalRequest,
    ) -> Result<EngineApprovalRequestOutcome> {
        let fingerprint = approval_fingerprint(&request.function_id, &request.payload);
        if let Some(key) = request.causal_context.idempotency_key.as_deref()
            && let Some(existing) = self.get_by_idempotency_key(
                &request.function_id,
                request.causal_context.session_id.as_deref(),
                request.causal_context.workspace_id.as_deref(),
                key,
            )?
        {
            if existing.payload_fingerprint != fingerprint {
                return Err(EngineError::IdempotencyConflict {
                    function_id: request.function_id.to_string(),
                    key: key.to_owned(),
                    reason: "approval request payload fingerprint differs".to_owned(),
                });
            }
            return Ok(EngineApprovalRequestOutcome::replayed(existing));
        }
        let now = Utc::now();
        let record = EngineApprovalRecord {
            approval_id: InvocationId::generate().to_string(),
            function_id: request.function_id,
            payload: request.payload,
            payload_fingerprint: fingerprint,
            actor_id: request.causal_context.actor_id,
            actor_kind: request.causal_context.actor_kind,
            authority_grant_id: request.causal_context.authority_grant_id,
            authority_scopes: request.causal_context.authority_scopes,
            trace_id: request.causal_context.trace_id,
            parent_invocation_id: request.causal_context.parent_invocation_id,
            trigger_id: request.causal_context.trigger_id,
            session_id: request.causal_context.session_id,
            workspace_id: request.causal_context.workspace_id,
            idempotency_key: request.causal_context.idempotency_key,
            delivery_mode: request.delivery_mode,
            target_metadata: request.target_metadata,
            status: ApprovalStatus::Pending,
            decision_actor_id: None,
            decided_at: None,
            result: None,
            error: None,
            created_at: now,
            updated_at: now,
        };
        self.insert_or_replace(&record)?;
        Ok(EngineApprovalRequestOutcome::created(record))
    }

    /// Get one approval.
    pub fn get(&self, approval_id: &str) -> Result<Option<EngineApprovalRecord>> {
        self.conn
            .query_row(
                "SELECT * FROM engine_approvals WHERE approval_id = ?1",
                params![approval_id],
                |row| row_to_record(&self.conn, row),
            )
            .optional()
            .map_err(|err| sqlite_err("approval.get", err.to_string()))
    }

    fn get_by_idempotency_key(
        &self,
        function_id: &FunctionId,
        session_id: Option<&str>,
        workspace_id: Option<&str>,
        key: &str,
    ) -> Result<Option<EngineApprovalRecord>> {
        self.conn
            .query_row(
                "SELECT * FROM engine_approvals
                 WHERE function_id = ?1
                   AND COALESCE(session_id, '') = ?2
                   AND COALESCE(workspace_id, '') = ?3
                   AND idempotency_key = ?4
                 ORDER BY created_at ASC
                 LIMIT 1",
                params![
                    function_id.as_str(),
                    session_id.unwrap_or_default(),
                    workspace_id.unwrap_or_default(),
                    key
                ],
                |row| row_to_record(&self.conn, row),
            )
            .optional()
            .map_err(|err| sqlite_err("approval.get_by_key", err.to_string()))
    }

    /// List approvals.
    pub fn list(
        &self,
        status: Option<ApprovalStatus>,
        session_id: Option<&str>,
        limit: usize,
    ) -> Result<Vec<EngineApprovalRecord>> {
        if limit == 0 {
            return Err(EngineError::PolicyViolation(
                "approval list limit must be greater than zero".to_owned(),
            ));
        }
        let mut stmt = self
            .conn
            .prepare("SELECT * FROM engine_approvals ORDER BY created_at ASC")
            .map_err(|err| sqlite_err("approval.list.prepare", err.to_string()))?;
        let rows = stmt
            .query_map([], |row| row_to_record(&self.conn, row))
            .map_err(|err| sqlite_err("approval.list", err.to_string()))?;
        let mut out = Vec::new();
        for row in rows {
            let record = row.map_err(|err| sqlite_err("approval.list.row", err.to_string()))?;
            if status.is_some_and(|status| record.status != status) {
                continue;
            }
            if session_id.is_some_and(|session| record.session_id.as_deref() != Some(session)) {
                continue;
            }
            out.push(record);
            if out.len() >= limit.min(500) {
                break;
            }
        }
        Ok(out)
    }

    /// Resolve a pending approval.
    pub fn resolve(
        &mut self,
        approval_id: &str,
        decision: ApprovalDecision,
        actor_id: ActorId,
    ) -> Result<EngineApprovalRecord> {
        let mut record = self
            .get(approval_id)?
            .ok_or_else(|| EngineError::NotFound {
                kind: "approval",
                id: approval_id.to_owned(),
            })?;
        if matches!(
            record.status,
            ApprovalStatus::Executed | ApprovalStatus::Failed | ApprovalStatus::Denied
        ) {
            return Ok(record);
        }
        let now = Utc::now();
        record.status = match decision {
            ApprovalDecision::Approve => ApprovalStatus::Approved,
            ApprovalDecision::Deny => ApprovalStatus::Denied,
        };
        record.decision_actor_id = Some(actor_id);
        record.decided_at = Some(now);
        record.updated_at = now;
        self.insert_or_replace(&record)?;
        Ok(record)
    }

    /// Complete an approved invocation.
    pub fn complete(
        &mut self,
        approval_id: &str,
        result: &InvocationResult,
    ) -> Result<EngineApprovalRecord> {
        let mut record = self
            .get(approval_id)?
            .ok_or_else(|| EngineError::NotFound {
                kind: "approval",
                id: approval_id.to_owned(),
            })?;
        record.status = if result.error.is_some() {
            ApprovalStatus::Failed
        } else {
            ApprovalStatus::Executed
        };
        record.result = result.value.clone();
        record.error = result
            .error
            .as_ref()
            .map(StoredEngineError::from_engine_error);
        record.updated_at = Utc::now();
        self.insert_or_replace(&record)?;
        Ok(record)
    }

    fn insert_or_replace(&mut self, record: &EngineApprovalRecord) -> Result<()> {
        self.conn
            .execute(
                "INSERT OR REPLACE INTO engine_approvals (
                    approval_id, function_id, payload_json, payload_fingerprint,
                    actor_id, actor_kind, authority_grant_id, authority_scopes_json,
                    trace_id, parent_invocation_id, trigger_id, session_id, workspace_id,
                    idempotency_key, delivery_mode, target_metadata_json, status, decision_actor_id, decided_at,
                    result_json, error_json, created_at, updated_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23)",
                params![
                    record.approval_id.as_str(),
                    record.function_id.as_str(),
                    crate::shared::storage::store_json_value(
                        &self.conn,
                        &record.payload,
                        &crate::shared::storage::StorePayloadOptions::new(
                            "engine_approval",
                            record.approval_id.clone(),
                            "payload",
                            "audit",
                        )
                        .with_scope(
                            Some(record.trace_id.to_string()),
                            record.session_id.clone(),
                            record.workspace_id.clone(),
                        ),
                    )
                    .map_err(storage_err)?,
                    record.payload_fingerprint.as_str(),
                    record.actor_id.as_str(),
                    format!("{:?}", record.actor_kind),
                    record.authority_grant_id.as_str(),
                    serde_json::to_string(&record.authority_scopes).map_err(json_err)?,
                    record.trace_id.as_str(),
                    record.parent_invocation_id.as_ref().map(InvocationId::as_str),
                    record.trigger_id.as_ref().map(TriggerId::as_str),
                    record.session_id.as_deref(),
                    record.workspace_id.as_deref(),
                    record.idempotency_key.as_deref(),
                    record.delivery_mode.as_str(),
                    record
                        .target_metadata
                        .as_ref()
                        .map(serde_json::to_string)
                        .transpose()
                        .map_err(json_err)?,
                    record.status.as_str(),
                    record.decision_actor_id.as_ref().map(ActorId::as_str),
                    record.decided_at.as_ref().map(DateTime::to_rfc3339),
                    record
                        .result
                        .as_ref()
                        .map(|value| {
                            crate::shared::storage::store_json_value(
                                &self.conn,
                                value,
                                &crate::shared::storage::StorePayloadOptions::new(
                                    "engine_approval",
                                    record.approval_id.clone(),
                                    "result",
                                    "audit",
                                )
                                .with_scope(
                                    Some(record.trace_id.to_string()),
                                    record.session_id.clone(),
                                    record.workspace_id.clone(),
                                ),
                            )
                            .map_err(storage_err)
                        })
                        .transpose()
                        ?,
                    record
                        .error
                        .as_ref()
                        .map(|value| {
                            let json = serde_json::to_value(value).map_err(json_err)?;
                            crate::shared::storage::store_json_value(
                                &self.conn,
                                &json,
                                &crate::shared::storage::StorePayloadOptions::new(
                                    "engine_approval",
                                    record.approval_id.clone(),
                                    "error",
                                    "audit",
                                )
                                .with_scope(
                                    Some(record.trace_id.to_string()),
                                    record.session_id.clone(),
                                    record.workspace_id.clone(),
                                ),
                            )
                            .map_err(storage_err)
                        })
                        .transpose()
                        ?,
                    record.created_at.to_rfc3339(),
                    record.updated_at.to_rfc3339(),
                ],
            )
            .map_err(|err| sqlite_err("approval.insert", err.to_string()))?;
        Ok(())
    }
}

/// Stable fingerprint for an approval target.
#[must_use]
pub fn approval_fingerprint(function_id: &FunctionId, payload: &Value) -> String {
    let mut hasher = Sha256::new();
    hasher.update(function_id.as_str().as_bytes());
    hasher.update(b"\0");
    let encoded = serde_json::to_vec(payload).unwrap_or_default();
    hasher.update(encoded);
    hex::encode(hasher.finalize())
}

fn approval_idempotency_scope_for_context(
    function_id: &FunctionId,
    context: &CausalContext,
    key: &str,
) -> String {
    approval_idempotency_scope(
        function_id,
        context.session_id.as_deref(),
        context.workspace_id.as_deref(),
        key,
    )
}

fn approval_idempotency_scope_for_record(record: &EngineApprovalRecord) -> Option<String> {
    record.idempotency_key.as_deref().map(|key| {
        approval_idempotency_scope(
            &record.function_id,
            record.session_id.as_deref(),
            record.workspace_id.as_deref(),
            key,
        )
    })
}

fn approval_idempotency_scope(
    function_id: &FunctionId,
    session_id: Option<&str>,
    workspace_id: Option<&str>,
    key: &str,
) -> String {
    [
        function_id.as_str(),
        session_id.unwrap_or_default(),
        workspace_id.unwrap_or_default(),
        key,
    ]
    .join("\u{0}")
}

#[cfg(test)]
mod tests;
