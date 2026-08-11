use std::fs;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use chrono::Utc;
use rusqlite::hooks::{AuthAction, AuthContext, Authorization};
use rusqlite::types::{Value as SqlValue, ValueRef};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params, params_from_iter};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use thiserror::Error;

use super::compiler::digest;

const MAX_SQL_BYTES: usize = 64 * 1024;
const MAX_PARAMETERS: usize = 256;
const MAX_STATEMENTS: usize = 64;
const MAX_ROWS: usize = 1_000;

/// Bounded read query against one capability namespace.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StateQuery {
    /// One SQLite statement.
    pub sql: String,
    /// Positional JSON scalar parameters.
    #[serde(default)]
    pub parameters: Vec<Value>,
    /// Caller-requested row bound, capped by the engine.
    #[serde(default = "default_query_rows")]
    pub max_rows: usize,
}

fn default_query_rows() -> usize {
    100
}

/// One statement within an atomic idempotent state effect.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StateStatement {
    /// One SQLite statement. Multiple statements in one string are rejected.
    pub sql: String,
    /// Positional JSON scalar parameters.
    #[serde(default)]
    pub parameters: Vec<Value>,
}

/// Transactional, idempotent mutation against one capability namespace.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StateEffect {
    /// Stable outer broker/call idempotency key.
    pub idempotency_key: String,
    /// Ordered statements committed with the receipt.
    pub statements: Vec<StateStatement>,
}

/// Durable effect receipt.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StateEffectResult {
    /// Rows changed by each statement.
    pub changes: Vec<usize>,
    /// True when an exact existing receipt was returned.
    pub replayed: bool,
}

/// State namespace metadata.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StateInfo {
    /// Capability-owned namespace.
    pub namespace: String,
    /// Physical SQLite bytes.
    pub bytes: u64,
}

/// Isolated state failure.
#[derive(Debug, Error)]
pub enum StateError {
    /// State-root/database filesystem access failed.
    #[error("capability state filesystem failed: {0}")]
    Io(#[from] std::io::Error),
    /// SQLite rejected an authorized statement or transaction.
    #[error("capability state SQL failed: {0}")]
    Sql(#[from] rusqlite::Error),
    /// Namespace, bounds, parameters, or statement shape is invalid.
    #[error("invalid capability state request: {0}")]
    Invalid(String),
    /// An effect key was reused with a different canonical statement payload.
    #[error("state effect idempotency key was reused with different statements")]
    IdempotencyConflict,
}

/// Per-capability SQLite custody rooted in an engine-owned profile or project
/// directory. Each namespace maps to a distinct database; SQLite attachment,
/// temp schema, extension loading, and access to receipt tables are denied by
/// the authorizer rather than by string matching.
#[derive(Debug, Clone)]
pub struct CapabilityState {
    root: PathBuf,
}

impl CapabilityState {
    /// Open an explicit state root. No namespace database is created until use.
    pub fn open(root: impl Into<PathBuf>) -> Result<Self, StateError> {
        let root = root.into();
        fs::create_dir_all(&root)?;
        Ok(Self { root })
    }

    /// Execute a bounded read and return rows as JSON objects.
    pub fn query(&self, namespace: &str, query: &StateQuery) -> Result<Vec<Value>, StateError> {
        validate_namespace(namespace)?;
        validate_statement(&query.sql, &query.parameters)?;
        let conn = self.connect(namespace)?;
        let internal = install_authorizer(&conn);
        internal.store(false, Ordering::SeqCst);
        let mut statement = conn.prepare(&query.sql)?;
        if !statement.readonly() {
            return Err(StateError::Invalid(
                "state.query accepts only read-only statements".to_owned(),
            ));
        }
        let names = statement
            .column_names()
            .into_iter()
            .map(str::to_owned)
            .collect::<Vec<_>>();
        let parameters = sql_parameters(&query.parameters)?;
        let max_rows = query.max_rows.clamp(1, MAX_ROWS);
        let mut rows = statement.query(params_from_iter(parameters))?;
        let mut output = Vec::new();
        while output.len() < max_rows {
            let Some(row) = rows.next()? else {
                break;
            };
            let mut object = Map::new();
            for (index, name) in names.iter().enumerate() {
                object.insert(name.clone(), json_value(row.get_ref(index)?));
            }
            output.push(Value::Object(object));
        }
        Ok(output)
    }

    /// Execute statements and their idempotency receipt in one transaction.
    pub fn execute(
        &self,
        namespace: &str,
        effect: &StateEffect,
    ) -> Result<StateEffectResult, StateError> {
        validate_namespace(namespace)?;
        if effect.idempotency_key.trim().is_empty() || effect.idempotency_key.len() > 200 {
            return Err(StateError::Invalid(
                "idempotencyKey must contain 1..=200 bytes".to_owned(),
            ));
        }
        if effect.statements.is_empty() || effect.statements.len() > MAX_STATEMENTS {
            return Err(StateError::Invalid(format!(
                "an effect must contain 1..={MAX_STATEMENTS} statements"
            )));
        }
        for statement in &effect.statements {
            validate_statement(&statement.sql, &statement.parameters)?;
        }
        let payload = serde_json::to_vec(&effect.statements)
            .map_err(|error| StateError::Invalid(error.to_string()))?;
        let payload_digest = digest(&payload);

        let mut conn = self.connect(namespace)?;
        let internal = install_authorizer(&conn);
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        internal.store(true, Ordering::SeqCst);
        let receipt: Option<(String, String)> = tx
            .query_row(
                "SELECT payload_digest, result_json FROM _tron_effects
                 WHERE idempotency_key = ?1",
                [&effect.idempotency_key],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        if let Some((existing_digest, result_json)) = receipt {
            if existing_digest != payload_digest {
                return Err(StateError::IdempotencyConflict);
            }
            let mut result: StateEffectResult = serde_json::from_str(&result_json)
                .map_err(|error| StateError::Invalid(error.to_string()))?;
            result.replayed = true;
            tx.commit()?;
            return Ok(result);
        }

        internal.store(false, Ordering::SeqCst);
        let mut changes = Vec::with_capacity(effect.statements.len());
        for statement in &effect.statements {
            let parameters = sql_parameters(&statement.parameters)?;
            changes.push(tx.execute(&statement.sql, params_from_iter(parameters))?);
        }
        let result = StateEffectResult {
            changes,
            replayed: false,
        };
        let result_json = serde_json::to_string(&result)
            .map_err(|error| StateError::Invalid(error.to_string()))?;
        internal.store(true, Ordering::SeqCst);
        tx.execute(
            "INSERT INTO _tron_effects (
                idempotency_key, payload_digest, result_json, created_at
             ) VALUES (?1, ?2, ?3, ?4)",
            params![
                effect.idempotency_key,
                payload_digest,
                result_json,
                Utc::now().to_rfc3339(),
            ],
        )?;
        tx.commit()?;
        Ok(result)
    }

    /// Inspect one namespace without exposing its physical path.
    pub fn info(&self, namespace: &str) -> Result<StateInfo, StateError> {
        validate_namespace(namespace)?;
        let path = self.database_path(namespace);
        Ok(StateInfo {
            namespace: namespace.to_owned(),
            bytes: fs::metadata(path).map_or(0, |metadata| metadata.len()),
        })
    }

    fn connect(&self, namespace: &str) -> Result<Connection, StateError> {
        let path = self.database_path(namespace);
        let conn = Connection::open(path)?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        conn.pragma_update(None, "busy_timeout", 5_000_i64)?;
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS _tron_effects (
                idempotency_key TEXT PRIMARY KEY NOT NULL,
                payload_digest TEXT NOT NULL,
                result_json TEXT NOT NULL,
                created_at TEXT NOT NULL
             );",
        )?;
        Ok(conn)
    }

    fn database_path(&self, namespace: &str) -> PathBuf {
        self.root
            .join(format!("{}.sqlite", digest(namespace.as_bytes())))
    }
}

fn install_authorizer(conn: &Connection) -> Arc<AtomicBool> {
    let internal = Arc::new(AtomicBool::new(true));
    let hook_internal = internal.clone();
    conn.authorizer(Some(move |context: AuthContext<'_>| {
        if hook_internal.load(Ordering::SeqCst) {
            return Authorization::Allow;
        }
        authorize_user_sql(context)
    }));
    internal
}

fn authorize_user_sql(context: AuthContext<'_>) -> Authorization {
    use AuthAction::{
        AlterTable, Attach, CreateIndex, CreateTable, CreateTempIndex, CreateTempTable,
        CreateTempTrigger, CreateTempView, CreateTrigger, CreateView, CreateVtable, Delete, Detach,
        DropIndex, DropTable, DropTempIndex, DropTempTable, DropTempTrigger, DropTempView,
        DropTrigger, DropView, DropVtable, Function, Insert, Pragma, Read, Update,
    };
    match context.action {
        Attach { .. }
        | Detach { .. }
        | Pragma { .. }
        | CreateTempIndex { .. }
        | CreateTempTable { .. }
        | CreateTempTrigger { .. }
        | CreateTempView { .. }
        | DropTempIndex { .. }
        | DropTempTable { .. }
        | DropTempTrigger { .. }
        | DropTempView { .. } => Authorization::Deny,
        CreateTable { table_name }
        | DropTable { table_name }
        | CreateVtable { table_name, .. }
        | DropVtable { table_name, .. }
            if table_name.starts_with("_tron_") =>
        {
            Authorization::Deny
        }
        CreateIndex {
            index_name,
            table_name,
        }
        | DropIndex {
            index_name,
            table_name,
        } if index_name.starts_with("_tron_") || table_name.starts_with("_tron_") => {
            Authorization::Deny
        }
        CreateTrigger {
            trigger_name,
            table_name,
        }
        | DropTrigger {
            trigger_name,
            table_name,
        } if trigger_name.starts_with("_tron_") || table_name.starts_with("_tron_") => {
            Authorization::Deny
        }
        CreateView { view_name } | DropView { view_name } if view_name.starts_with("_tron_") => {
            Authorization::Deny
        }
        CreateVtable { module_name, .. }
            if !matches!(module_name.to_ascii_lowercase().as_str(), "fts5") =>
        {
            Authorization::Deny
        }
        Function { function_name }
            if matches!(
                function_name.to_ascii_lowercase().as_str(),
                "load_extension" | "readfile" | "writefile" | "edit"
            ) =>
        {
            Authorization::Deny
        }
        Read { table_name, .. }
        | Insert { table_name }
        | Update { table_name, .. }
        | Delete { table_name }
        | AlterTable { table_name, .. }
            if table_name.starts_with("_tron_") =>
        {
            Authorization::Deny
        }
        _ if context.database_name.is_some_and(|name| name != "main") => Authorization::Deny,
        _ => Authorization::Allow,
    }
}

fn validate_namespace(namespace: &str) -> Result<(), StateError> {
    if namespace.is_empty()
        || namespace.len() > 160
        || !namespace
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b':'))
    {
        return Err(StateError::Invalid(
            "namespace contains unsupported characters".to_owned(),
        ));
    }
    Ok(())
}

fn validate_statement(sql: &str, parameters: &[Value]) -> Result<(), StateError> {
    if sql.trim().is_empty() || sql.len() > MAX_SQL_BYTES {
        return Err(StateError::Invalid(format!(
            "SQL must contain 1..={MAX_SQL_BYTES} bytes"
        )));
    }
    if parameters.len() > MAX_PARAMETERS {
        return Err(StateError::Invalid(format!(
            "SQL accepts at most {MAX_PARAMETERS} parameters"
        )));
    }
    Ok(())
}

fn sql_parameters(values: &[Value]) -> Result<Vec<SqlValue>, StateError> {
    values
        .iter()
        .map(|value| match value {
            Value::Null => Ok(SqlValue::Null),
            Value::Bool(value) => Ok(SqlValue::Integer(i64::from(*value))),
            Value::Number(value) => value
                .as_i64()
                .map(SqlValue::Integer)
                .or_else(|| value.as_f64().map(SqlValue::Real))
                .ok_or_else(|| StateError::Invalid("unsupported JSON number".to_owned())),
            Value::String(value) => Ok(SqlValue::Text(value.clone())),
            Value::Array(_) | Value::Object(_) => serde_json::to_string(value)
                .map(SqlValue::Text)
                .map_err(|error| StateError::Invalid(error.to_string())),
        })
        .collect()
}

fn json_value(value: ValueRef<'_>) -> Value {
    match value {
        ValueRef::Null => Value::Null,
        ValueRef::Integer(value) => Value::from(value),
        ValueRef::Real(value) => Value::from(value),
        ValueRef::Text(value) => Value::String(String::from_utf8_lossy(value).into_owned()),
        ValueRef::Blob(value) => Value::String(base64::Engine::encode(
            &base64::engine::general_purpose::STANDARD,
            value,
        )),
    }
}
