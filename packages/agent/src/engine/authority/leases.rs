//! Engine resource leases.
//!
//! Leases are short-lived ownership records for high-risk capabilities that
//! mutate shared local state. They are intentionally separate from queue item
//! leases: a queue lease owns one delivery attempt, while a resource lease owns
//! a domain resource such as a session model setting, memory-retain slot, or
//! import source for the duration of one invocation.

use std::collections::BTreeMap;
use std::path::Path;

use chrono::{DateTime, Duration, Utc};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};

use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::ids::{ActorId, AuthorityGrantId, FunctionId, InvocationId, TraceId};

/// Lifecycle state for a resource lease.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EngineResourceLeaseStatus {
    /// Lease is still active.
    Active,
    /// Lease was explicitly released.
    Released,
    /// Lease expired and may be superseded by a newer active lease.
    Expired,
}

impl EngineResourceLeaseStatus {
    fn as_str(&self) -> &'static str {
        match self {
            Self::Active => "active",
            Self::Released => "released",
            Self::Expired => "expired",
        }
    }

    fn parse(value: &str) -> Result<Self> {
        match value {
            "active" => Ok(Self::Active),
            "released" => Ok(Self::Released),
            "expired" => Ok(Self::Expired),
            other => Err(EngineError::LedgerFailure {
                operation: "resource_lease.status",
                message: format!("unknown resource lease status {other}"),
            }),
        }
    }
}

/// Durable resource lease record.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineResourceLease {
    /// Stable lease id.
    pub lease_id: String,
    /// Domain resource kind, for example `session` or `import`.
    pub resource_kind: String,
    /// Domain resource id.
    pub resource_id: String,
    /// Invocation that acquired the lease.
    pub holder_invocation_id: InvocationId,
    /// Function that requested the lease.
    pub function_id: FunctionId,
    /// Actor that requested the lease.
    pub actor_id: ActorId,
    /// Authority grant used for the request.
    pub authority_grant_id: AuthorityGrantId,
    /// Trace propagated from the caller.
    pub trace_id: TraceId,
    /// Parent invocation, if any.
    pub parent_invocation_id: Option<InvocationId>,
    /// Idempotency key, if one was present.
    pub idempotency_key: Option<String>,
    /// Current lease state.
    pub status: EngineResourceLeaseStatus,
    /// Acquisition timestamp.
    pub acquired_at: DateTime<Utc>,
    /// Expiration timestamp.
    pub expires_at: DateTime<Utc>,
    /// Explicit release timestamp.
    pub released_at: Option<DateTime<Utc>>,
}

impl EngineResourceLease {
    /// Whether this lease is still active at `now`.
    #[must_use]
    pub fn active_at(&self, now: DateTime<Utc>) -> bool {
        self.status == EngineResourceLeaseStatus::Active && self.expires_at > now
    }
}

/// Request to acquire a resource lease.
#[derive(Clone, Debug, PartialEq)]
pub struct AcquireResourceLease {
    /// Domain resource kind.
    pub resource_kind: String,
    /// Domain resource id.
    pub resource_id: String,
    /// Invocation acquiring the lease.
    pub holder_invocation_id: InvocationId,
    /// Function acquiring the lease.
    pub function_id: FunctionId,
    /// Actor acquiring the lease.
    pub actor_id: ActorId,
    /// Authority grant used.
    pub authority_grant_id: AuthorityGrantId,
    /// Trace id.
    pub trace_id: TraceId,
    /// Optional parent invocation.
    pub parent_invocation_id: Option<InvocationId>,
    /// Optional idempotency key.
    pub idempotency_key: Option<String>,
    /// Lease TTL in milliseconds.
    pub ttl_ms: i64,
}

/// In-memory resource lease store.
#[derive(Default)]
pub struct InMemoryEngineResourceLeaseStore {
    by_resource: BTreeMap<(String, String), String>,
    leases: BTreeMap<String, EngineResourceLease>,
}

impl InMemoryEngineResourceLeaseStore {
    /// Create an empty store.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Acquire an exclusive resource lease.
    pub fn acquire(&mut self, request: AcquireResourceLease) -> Result<EngineResourceLease> {
        validate_request(&request)?;
        let now = Utc::now();
        let resource_key = (request.resource_kind.clone(), request.resource_id.clone());
        if let Some(existing_id) = self.by_resource.get(&resource_key).cloned()
            && let Some(existing) = self.leases.get_mut(&existing_id)
        {
            if existing.active_at(now) {
                return Err(resource_conflict(existing));
            }
            if existing.status == EngineResourceLeaseStatus::Active {
                existing.status = EngineResourceLeaseStatus::Expired;
            }
        }

        let lease = lease_from_request(request, now);
        let lease_id = lease.lease_id.clone();
        self.by_resource.insert(resource_key, lease_id.clone());
        self.leases.insert(lease_id, lease.clone());
        Ok(lease)
    }

    /// Release a lease. Releasing an already released/expired lease is
    /// idempotent and returns the stored record.
    pub fn release(&mut self, lease_id: &str) -> Result<Option<EngineResourceLease>> {
        let Some(lease) = self.leases.get_mut(lease_id) else {
            return Ok(None);
        };
        if lease.status == EngineResourceLeaseStatus::Active {
            lease.status = EngineResourceLeaseStatus::Released;
            lease.released_at = Some(Utc::now());
        }
        Ok(Some(lease.clone()))
    }

    /// Get one lease.
    pub fn get(&self, lease_id: &str) -> Result<Option<EngineResourceLease>> {
        Ok(self.leases.get(lease_id).cloned())
    }
}

/// SQLite-backed resource lease store.
pub struct SqliteEngineResourceLeaseStore {
    conn: Connection,
}

impl SqliteEngineResourceLeaseStore {
    /// Open a resource lease store in the isolated engine ledger DB.
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let conn = Connection::open(path).map_err(|err| sqlite_err("lease.open", err))?;
        let store = Self { conn };
        store.init()?;
        Ok(store)
    }

    fn init(&self) -> Result<()> {
        crate::shared::storage::apply_runtime_pragmas(&self.conn)
            .map_err(|err| sqlite_err_message("lease.storage_pragmas", err.to_string()))?;
        crate::shared::storage::ensure_storage_schema(&self.conn)
            .map_err(|err| sqlite_err_message("lease.storage_schema", err.to_string()))?;
        self.conn
            .execute_batch(
                r#"
CREATE TABLE IF NOT EXISTS engine_resource_leases (
  lease_id TEXT PRIMARY KEY,
  resource_kind TEXT NOT NULL,
  resource_id TEXT NOT NULL,
  holder_invocation_id TEXT NOT NULL,
  function_id TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  authority_grant_id TEXT NOT NULL,
  trace_id TEXT NOT NULL,
  parent_invocation_id TEXT,
  idempotency_key TEXT,
  status TEXT NOT NULL,
  acquired_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  released_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_engine_resource_leases_resource
  ON engine_resource_leases(resource_kind, resource_id, status, expires_at);
CREATE INDEX IF NOT EXISTS idx_engine_resource_leases_trace
  ON engine_resource_leases(trace_id, acquired_at);
"#,
            )
            .map_err(|err| sqlite_err("lease.init", err))
    }

    /// Acquire an exclusive resource lease.
    pub fn acquire(&mut self, request: AcquireResourceLease) -> Result<EngineResourceLease> {
        validate_request(&request)?;
        let now = Utc::now();
        if let Some(mut existing) =
            self.active_for_resource(&request.resource_kind, &request.resource_id)?
        {
            if existing.active_at(now) {
                return Err(resource_conflict(&existing));
            }
            existing.status = EngineResourceLeaseStatus::Expired;
            self.update(&existing)?;
        }

        let lease = lease_from_request(request, now);
        self.insert(&lease)?;
        Ok(lease)
    }

    /// Release a lease. Releasing an already released/expired lease is
    /// idempotent and returns the stored record.
    pub fn release(&mut self, lease_id: &str) -> Result<Option<EngineResourceLease>> {
        let Some(mut lease) = self.get(lease_id)? else {
            return Ok(None);
        };
        if lease.status == EngineResourceLeaseStatus::Active {
            lease.status = EngineResourceLeaseStatus::Released;
            lease.released_at = Some(Utc::now());
            self.update(&lease)?;
        }
        Ok(Some(lease))
    }

    /// Get one lease.
    pub fn get(&self, lease_id: &str) -> Result<Option<EngineResourceLease>> {
        self.conn
            .query_row(
                "SELECT * FROM engine_resource_leases WHERE lease_id = ?1",
                params![lease_id],
                row_to_lease,
            )
            .optional()
            .map_err(|err| sqlite_err("lease.get", err))
    }

    fn active_for_resource(
        &self,
        resource_kind: &str,
        resource_id: &str,
    ) -> Result<Option<EngineResourceLease>> {
        self.conn
            .query_row(
                "SELECT * FROM engine_resource_leases
                 WHERE resource_kind = ?1 AND resource_id = ?2 AND status = 'active'
                 ORDER BY acquired_at DESC LIMIT 1",
                params![resource_kind, resource_id],
                row_to_lease,
            )
            .optional()
            .map_err(|err| sqlite_err("lease.active_for_resource", err))
    }

    fn insert(&self, lease: &EngineResourceLease) -> Result<()> {
        self.conn
            .execute(
                "INSERT INTO engine_resource_leases (
                    lease_id, resource_kind, resource_id, holder_invocation_id,
                    function_id, actor_id, authority_grant_id, trace_id,
                    parent_invocation_id, idempotency_key, status, acquired_at,
                    expires_at, released_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)",
                params![
                    lease.lease_id,
                    lease.resource_kind,
                    lease.resource_id,
                    lease.holder_invocation_id.as_str(),
                    lease.function_id.as_str(),
                    lease.actor_id.as_str(),
                    lease.authority_grant_id.as_str(),
                    lease.trace_id.as_str(),
                    lease.parent_invocation_id.as_ref().map(|id| id.as_str()),
                    lease.idempotency_key,
                    lease.status.as_str(),
                    lease.acquired_at.to_rfc3339(),
                    lease.expires_at.to_rfc3339(),
                    lease.released_at.map(|ts| ts.to_rfc3339()),
                ],
            )
            .map_err(|err| sqlite_err("lease.insert", err))?;
        Ok(())
    }

    fn update(&self, lease: &EngineResourceLease) -> Result<()> {
        self.conn
            .execute(
                "UPDATE engine_resource_leases
                 SET status = ?2, expires_at = ?3, released_at = ?4
                 WHERE lease_id = ?1",
                params![
                    lease.lease_id,
                    lease.status.as_str(),
                    lease.expires_at.to_rfc3339(),
                    lease.released_at.map(|ts| ts.to_rfc3339()),
                ],
            )
            .map_err(|err| sqlite_err("lease.update", err))?;
        Ok(())
    }
}

fn validate_request(request: &AcquireResourceLease) -> Result<()> {
    if request.resource_kind.trim().is_empty() {
        return Err(EngineError::PolicyViolation(
            "resource lease kind must not be empty".to_owned(),
        ));
    }
    if request.resource_id.trim().is_empty() {
        return Err(EngineError::PolicyViolation(
            "resource lease id must not be empty".to_owned(),
        ));
    }
    if request.ttl_ms <= 0 {
        return Err(EngineError::PolicyViolation(
            "resource lease ttl must be greater than zero".to_owned(),
        ));
    }
    Ok(())
}

fn lease_from_request(request: AcquireResourceLease, now: DateTime<Utc>) -> EngineResourceLease {
    EngineResourceLease {
        lease_id: InvocationId::generate().to_string(),
        resource_kind: request.resource_kind,
        resource_id: request.resource_id,
        holder_invocation_id: request.holder_invocation_id,
        function_id: request.function_id,
        actor_id: request.actor_id,
        authority_grant_id: request.authority_grant_id,
        trace_id: request.trace_id,
        parent_invocation_id: request.parent_invocation_id,
        idempotency_key: request.idempotency_key,
        status: EngineResourceLeaseStatus::Active,
        acquired_at: now,
        expires_at: now + Duration::milliseconds(request.ttl_ms),
        released_at: None,
    }
}

fn resource_conflict(existing: &EngineResourceLease) -> EngineError {
    EngineError::PolicyViolation(format!(
        "resource lease conflict for {}:{} held by invocation {}",
        existing.resource_kind, existing.resource_id, existing.holder_invocation_id
    ))
}

fn row_to_lease(row: &rusqlite::Row<'_>) -> rusqlite::Result<EngineResourceLease> {
    let parent: Option<String> = row.get("parent_invocation_id")?;
    let acquired_at: String = row.get("acquired_at")?;
    let expires_at: String = row.get("expires_at")?;
    let released_at: Option<String> = row.get("released_at")?;
    Ok(EngineResourceLease {
        lease_id: row.get("lease_id")?,
        resource_kind: row.get("resource_kind")?,
        resource_id: row.get("resource_id")?,
        holder_invocation_id: InvocationId::new(row.get::<_, String>("holder_invocation_id")?)
            .map_err(to_sql_err)?,
        function_id: FunctionId::new(row.get::<_, String>("function_id")?).map_err(to_sql_err)?,
        actor_id: ActorId::new(row.get::<_, String>("actor_id")?).map_err(to_sql_err)?,
        authority_grant_id: AuthorityGrantId::new(row.get::<_, String>("authority_grant_id")?)
            .map_err(to_sql_err)?,
        trace_id: TraceId::new(row.get::<_, String>("trace_id")?).map_err(to_sql_err)?,
        parent_invocation_id: parent
            .map(InvocationId::new)
            .transpose()
            .map_err(to_sql_err)?,
        idempotency_key: row.get("idempotency_key")?,
        status: EngineResourceLeaseStatus::parse(&row.get::<_, String>("status")?)
            .map_err(to_sql_err)?,
        acquired_at: parse_time(&acquired_at).map_err(to_sql_err)?,
        expires_at: parse_time(&expires_at).map_err(to_sql_err)?,
        released_at: released_at
            .as_deref()
            .map(parse_time)
            .transpose()
            .map_err(to_sql_err)?,
    })
}

fn parse_time(value: &str) -> Result<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|err| EngineError::LedgerFailure {
            operation: "resource_lease.parse_time",
            message: err.to_string(),
        })
}

fn sqlite_err(operation: &'static str, err: rusqlite::Error) -> EngineError {
    EngineError::LedgerFailure {
        operation,
        message: err.to_string(),
    }
}

fn sqlite_err_message(operation: &'static str, message: impl Into<String>) -> EngineError {
    EngineError::LedgerFailure {
        operation,
        message: message.into(),
    }
}

fn to_sql_err(error: EngineError) -> rusqlite::Error {
    rusqlite::Error::ToSqlConversionFailure(Box::new(error))
}
