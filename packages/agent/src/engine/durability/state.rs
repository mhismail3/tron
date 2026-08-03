//! Engine state primitive.
//!
//! State is profile-global or session-scoped projection data for workers and
//! agents. Durable session truth remains the event store; state entries are
//! cache/projection records with revisions and owner namespaces.

use std::collections::BTreeMap;
use std::path::Path;

use chrono::{DateTime, Utc};
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::Value;

use crate::engine::kernel::errors::{EngineError, Result};

/// Engine state scope.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum EngineStateScope {
    /// Profile-global state.
    Profile,
    /// Session-scoped state.
    Session(String),
}

impl EngineStateScope {
    fn kind(&self) -> &'static str {
        match self {
            Self::Profile => "profile",
            Self::Session(_) => "session",
        }
    }

    fn value(&self) -> &str {
        match self {
            Self::Profile => "profile",
            Self::Session(value) => value,
        }
    }
}

/// State entry.
#[derive(Clone, Debug, PartialEq)]
pub struct EngineStateEntry {
    /// Scope.
    pub scope: EngineStateScope,
    /// Owner namespace.
    pub namespace: String,
    /// Entry key.
    pub key: String,
    /// JSON value.
    pub value: Value,
    /// Monotonic entry revision.
    pub revision: u64,
    /// Last write timestamp.
    pub updated_at: DateTime<Utc>,
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
struct StateKey {
    scope: EngineStateScope,
    namespace: String,
    key: String,
}

/// In-memory state store.
#[derive(Default)]
pub struct InMemoryEngineStateStore {
    entries: BTreeMap<StateKey, EngineStateEntry>,
}

impl InMemoryEngineStateStore {
    /// Create an empty store.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Read one entry.
    pub fn get(
        &self,
        scope: EngineStateScope,
        namespace: &str,
        key: &str,
    ) -> Result<Option<EngineStateEntry>> {
        Ok(self
            .entries
            .get(&state_key(scope, namespace, key)?)
            .cloned())
    }

    /// Set one entry and return the new record.
    pub fn set(
        &mut self,
        scope: EngineStateScope,
        namespace: String,
        key: String,
        value: Value,
    ) -> Result<EngineStateEntry> {
        let id = state_key(scope.clone(), &namespace, &key)?;
        let revision = self
            .entries
            .get(&id)
            .map_or(1, |entry| entry.revision.saturating_add(1));
        let entry = EngineStateEntry {
            scope,
            namespace,
            key,
            value,
            revision,
            updated_at: Utc::now(),
        };
        self.entries.insert(id, entry.clone());
        Ok(entry)
    }

    /// Delete one entry.
    pub fn delete(&mut self, scope: EngineStateScope, namespace: &str, key: &str) -> Result<bool> {
        Ok(self
            .entries
            .remove(&state_key(scope, namespace, key)?)
            .is_some())
    }

    /// List entries under a namespace and optional key prefix.
    pub fn list(
        &self,
        scope: EngineStateScope,
        namespace: &str,
        key_prefix: Option<&str>,
        limit: usize,
    ) -> Result<Vec<EngineStateEntry>> {
        if limit == 0 {
            return Err(EngineError::PolicyViolation(
                "state list limit must be greater than zero".to_owned(),
            ));
        }
        let prefix = key_prefix.unwrap_or("");
        Ok(self
            .entries
            .values()
            .filter(|entry| {
                entry.scope == scope
                    && entry.namespace == namespace
                    && entry.key.starts_with(prefix)
            })
            .take(limit.min(500))
            .cloned()
            .collect())
    }
}

/// SQLite state store.
pub struct SqliteEngineStateStore {
    conn: Connection,
}

impl SqliteEngineStateStore {
    /// Open a state store in the engine ledger database.
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let conn =
            Connection::open(path).map_err(|err| sqlite_err("state.open", err.to_string()))?;
        let store = Self { conn };
        store.init()?;
        Ok(store)
    }

    fn init(&self) -> Result<()> {
        crate::shared::storage::apply_runtime_pragmas(&self.conn)
            .map_err(|err| sqlite_err("state.storage_pragmas", err.to_string()))?;
        crate::shared::storage::ensure_storage_schema(&self.conn)
            .map_err(|err| sqlite_err("state.storage_schema", err.to_string()))?;
        self.conn
            .execute_batch(
                r#"
CREATE TABLE IF NOT EXISTS engine_state_entries (
  scope_kind TEXT NOT NULL,
  scope_value TEXT NOT NULL,
  namespace TEXT NOT NULL,
  key TEXT NOT NULL,
  value_json TEXT NOT NULL,
  revision INTEGER NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (scope_kind, scope_value, namespace, key)
);
"#,
            )
            .map_err(|err| sqlite_err("state.init", err.to_string()))
    }

    /// Read one entry.
    pub fn get(
        &self,
        scope: EngineStateScope,
        namespace: &str,
        key: &str,
    ) -> Result<Option<EngineStateEntry>> {
        validate_namespace_key(namespace, key)?;
        self.conn
            .query_row(
                "SELECT scope_kind, scope_value, namespace, key, value_json, revision, updated_at
                 FROM engine_state_entries
                 WHERE scope_kind = ?1 AND scope_value = ?2 AND namespace = ?3 AND key = ?4",
                params![scope.kind(), scope.value(), namespace, key],
                |row| row_to_state_entry(&self.conn, row),
            )
            .optional()
            .map_err(|err| sqlite_err("state.get", err.to_string()))
    }

    /// Set one entry and return the new record.
    pub fn set(
        &mut self,
        scope: EngineStateScope,
        namespace: String,
        key: String,
        value: Value,
    ) -> Result<EngineStateEntry> {
        validate_namespace_key(&namespace, &key)?;
        let existing = self.get(scope.clone(), &namespace, &key)?;
        let revision = existing.map_or(1, |entry| entry.revision.saturating_add(1));
        let updated_at = Utc::now();
        let owner_id = format!("{}:{}:{}", scope.kind(), scope.value(), namespace);
        let value_json = crate::shared::storage::store_json_value(
            &self.conn,
            &value,
            &crate::shared::storage::StorePayloadOptions::new(
                "engine_state_entry",
                owner_id,
                key.clone(),
                "runtime",
            ),
        )
        .map_err(|err| sqlite_err("state.value", err.to_string()))?;
        self.conn
            .execute(
                "INSERT INTO engine_state_entries
                 (scope_kind, scope_value, namespace, key, value_json, revision, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                 ON CONFLICT(scope_kind, scope_value, namespace, key) DO UPDATE SET
                   value_json = excluded.value_json,
                   revision = excluded.revision,
                   updated_at = excluded.updated_at",
                params![
                    scope.kind(),
                    scope.value(),
                    namespace,
                    key,
                    value_json,
                    revision as i64,
                    updated_at.to_rfc3339(),
                ],
            )
            .map_err(|err| sqlite_err("state.set", err.to_string()))?;
        Ok(EngineStateEntry {
            scope,
            namespace,
            key,
            value,
            revision,
            updated_at,
        })
    }

    /// Delete one entry.
    pub fn delete(&mut self, scope: EngineStateScope, namespace: &str, key: &str) -> Result<bool> {
        validate_namespace_key(namespace, key)?;
        let changed = self
            .conn
            .execute(
                "DELETE FROM engine_state_entries
                 WHERE scope_kind = ?1 AND scope_value = ?2 AND namespace = ?3 AND key = ?4",
                params![scope.kind(), scope.value(), namespace, key],
            )
            .map_err(|err| sqlite_err("state.delete", err.to_string()))?;
        Ok(changed > 0)
    }

    /// List entries under a namespace and optional key prefix.
    pub fn list(
        &self,
        scope: EngineStateScope,
        namespace: &str,
        key_prefix: Option<&str>,
        limit: usize,
    ) -> Result<Vec<EngineStateEntry>> {
        if limit == 0 {
            return Err(EngineError::PolicyViolation(
                "state list limit must be greater than zero".to_owned(),
            ));
        }
        if namespace.trim().is_empty() {
            return Err(EngineError::PolicyViolation(
                "state namespace must not be empty".to_owned(),
            ));
        }
        let pattern = format!("{}%", key_prefix.unwrap_or(""));
        let mut stmt = self
            .conn
            .prepare(
                "SELECT scope_kind, scope_value, namespace, key, value_json, revision, updated_at
                 FROM engine_state_entries
                 WHERE scope_kind = ?1 AND scope_value = ?2 AND namespace = ?3 AND key LIKE ?4
                 ORDER BY key ASC
                 LIMIT ?5",
            )
            .map_err(|err| sqlite_err("state.list.prepare", err.to_string()))?;
        let rows = stmt
            .query_map(
                params![
                    scope.kind(),
                    scope.value(),
                    namespace,
                    pattern,
                    limit.min(500) as i64
                ],
                |row| row_to_state_entry(&self.conn, row),
            )
            .map_err(|err| sqlite_err("state.list.query", err.to_string()))?;
        rows.map(|row| row.map_err(|err| sqlite_err("state.list.row", err.to_string())))
            .collect()
    }
}

fn state_key(scope: EngineStateScope, namespace: &str, key: &str) -> Result<StateKey> {
    validate_namespace_key(namespace, key)?;
    Ok(StateKey {
        scope,
        namespace: namespace.to_owned(),
        key: key.to_owned(),
    })
}

fn validate_namespace_key(namespace: &str, key: &str) -> Result<()> {
    if namespace.trim().is_empty() {
        return Err(EngineError::PolicyViolation(
            "state namespace must not be empty".to_owned(),
        ));
    }
    if key.trim().is_empty() {
        return Err(EngineError::PolicyViolation(
            "state key must not be empty".to_owned(),
        ));
    }
    Ok(())
}

fn row_to_state_entry(
    conn: &Connection,
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<EngineStateEntry> {
    let scope_kind: String = row.get(0)?;
    let scope_value: String = row.get(1)?;
    let value_json: String = row.get(4)?;
    let scope = match (scope_kind.as_str(), scope_value.as_str()) {
        ("profile", "profile") => EngineStateScope::Profile,
        ("session", value) if !value.trim().is_empty() => {
            EngineStateScope::Session(value.to_owned())
        }
        _ => {
            return Err(rusqlite::Error::FromSqlConversionFailure(
                0,
                rusqlite::types::Type::Text,
                format!("invalid engine state scope {scope_kind}:{scope_value}").into(),
            ));
        }
    };
    Ok(EngineStateEntry {
        scope,
        namespace: row.get(2)?,
        key: row.get(3)?,
        value: crate::shared::storage::resolve_stored_json_value(conn, &value_json)
            .unwrap_or(Value::Null),
        revision: row.get::<_, i64>(5)? as u64,
        updated_at: DateTime::parse_from_rfc3339(&row.get::<_, String>(6)?)
            .map(|dt| dt.with_timezone(&Utc))
            .unwrap_or_else(|_| Utc::now()),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sqlite_round_trips_the_two_runtime_state_scopes() {
        let dir = tempfile::tempdir().expect("temp dir");
        let path = dir.path().join("state.sqlite");
        let mut store = SqliteEngineStateStore::open(&path).expect("open state store");

        let session = EngineStateScope::Session("session-a".to_owned());
        store
            .set(
                session.clone(),
                "routing".to_owned(),
                "worker-a".to_owned(),
                serde_json::json!({"promoted": true}),
            )
            .expect("write session state");
        store
            .set(
                EngineStateScope::Profile,
                "evidence".to_owned(),
                "worker-a".to_owned(),
                serde_json::json!({"completedRuns": 4}),
            )
            .expect("write profile state");

        assert_eq!(
            store
                .get(session, "routing", "worker-a")
                .expect("read session state")
                .expect("session state")
                .scope,
            EngineStateScope::Session("session-a".to_owned())
        );
        assert_eq!(
            store
                .get(EngineStateScope::Profile, "evidence", "worker-a")
                .expect("read profile state")
                .expect("profile state")
                .scope,
            EngineStateScope::Profile
        );
    }

    #[test]
    fn sqlite_rejects_unknown_or_malformed_scope_rows() {
        let dir = tempfile::tempdir().expect("temp dir");
        let path = dir.path().join("state.sqlite");
        let store = SqliteEngineStateStore::open(&path).expect("open state store");
        store
            .conn
            .execute(
                "INSERT INTO engine_state_entries
                 (scope_kind, scope_value, namespace, key, value_json, revision, updated_at)
                 VALUES ('workspace', 'invalid', 'routing', 'worker-a', '{}', 1, ?1)",
                [Utc::now().to_rfc3339()],
            )
            .expect("insert malformed row");

        let row_error = store
            .conn
            .query_row(
                "SELECT scope_kind, scope_value, namespace, key, value_json, revision, updated_at
                 FROM engine_state_entries WHERE scope_kind = 'workspace'",
                [],
                |row| row_to_state_entry(&store.conn, row),
            )
            .expect_err("unknown scope must fail closed");
        assert!(row_error.to_string().contains("invalid engine state scope"));
    }
}

fn sqlite_err(operation: &'static str, message: impl Into<String>) -> EngineError {
    EngineError::LedgerFailure {
        operation,
        message: message.into(),
    }
}
