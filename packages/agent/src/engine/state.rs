//! Engine state primitive.
//!
//! State is scoped projection data for workers and agents. Durable session
//! truth remains the event store; state entries are cache/projection records
//! with revisions and owner namespaces.

use std::collections::BTreeMap;
use std::path::Path;

use chrono::{DateTime, Utc};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::errors::{EngineError, Result};

/// Engine state scope.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EngineStateScope {
    /// Global local system state.
    System,
    /// Workspace-scoped state.
    Workspace(String),
    /// Session-scoped state.
    Session(String),
}

impl EngineStateScope {
    fn kind(&self) -> &'static str {
        match self {
            Self::System => "system",
            Self::Workspace(_) => "workspace",
            Self::Session(_) => "session",
        }
    }

    fn value(&self) -> &str {
        match self {
            Self::System => "system",
            Self::Workspace(value) | Self::Session(value) => value,
        }
    }
}

/// State entry.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
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

    /// Compare-and-set one entry.
    pub fn compare_and_set(
        &mut self,
        scope: EngineStateScope,
        namespace: String,
        key: String,
        expected_revision: Option<u64>,
        value: Value,
    ) -> Result<EngineStateEntry> {
        let existing = self.get(scope.clone(), &namespace, &key)?;
        let actual = existing.as_ref().map(|entry| entry.revision);
        if actual != expected_revision {
            return Err(EngineError::PolicyViolation(format!(
                "state revision conflict for {namespace}/{key}: expected {:?}, actual {:?}",
                expected_revision, actual
            )));
        }
        self.set(scope, namespace, key, value)
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
                row_to_state_entry,
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
        let value_json = serde_json::to_string(&value)
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

    /// Compare-and-set one entry.
    pub fn compare_and_set(
        &mut self,
        scope: EngineStateScope,
        namespace: String,
        key: String,
        expected_revision: Option<u64>,
        value: Value,
    ) -> Result<EngineStateEntry> {
        let existing = self.get(scope.clone(), &namespace, &key)?;
        let actual = existing.as_ref().map(|entry| entry.revision);
        if actual != expected_revision {
            return Err(EngineError::PolicyViolation(format!(
                "state revision conflict for {namespace}/{key}: expected {:?}, actual {:?}",
                expected_revision, actual
            )));
        }
        self.set(scope, namespace, key, value)
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
                row_to_state_entry,
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

fn row_to_state_entry(row: &rusqlite::Row<'_>) -> rusqlite::Result<EngineStateEntry> {
    let scope_kind: String = row.get(0)?;
    let scope_value: String = row.get(1)?;
    let value_json: String = row.get(4)?;
    Ok(EngineStateEntry {
        scope: match scope_kind.as_str() {
            "workspace" => EngineStateScope::Workspace(scope_value),
            "session" => EngineStateScope::Session(scope_value),
            _ => EngineStateScope::System,
        },
        namespace: row.get(2)?,
        key: row.get(3)?,
        value: serde_json::from_str(&value_json).unwrap_or(Value::Null),
        revision: row.get::<_, i64>(5)? as u64,
        updated_at: DateTime::parse_from_rfc3339(&row.get::<_, String>(6)?)
            .map(|dt| dt.with_timezone(&Utc))
            .unwrap_or_else(|_| Utc::now()),
    })
}

fn sqlite_err(operation: &'static str, message: impl Into<String>) -> EngineError {
    EngineError::LedgerFailure {
        operation,
        message: message.into(),
    }
}
