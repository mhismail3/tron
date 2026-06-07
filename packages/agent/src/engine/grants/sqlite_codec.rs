//! SQLite row codecs and scalar serialization helpers for engine grants.

use chrono::{DateTime, Utc};
use rusqlite::{Row, types::Type};
use serde::Serialize;
use serde_json::Value;

use super::{EngineGrant, EngineGrantLifecycle};
use crate::engine::errors::{EngineError, Result};
use crate::engine::ids::{ActorId, AuthorityGrantId, InvocationId, TraceId, WorkerId};
use crate::engine::types::RiskLevel;

pub(super) fn risk_as_str(risk: RiskLevel) -> &'static str {
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

pub(super) fn row_to_grant(row: &Row<'_>) -> rusqlite::Result<EngineGrant> {
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

pub(super) fn json_string<T: Serialize>(value: &T, operation: &'static str) -> Result<String> {
    serde_json::to_string(value).map_err(|error| EngineError::LedgerFailure {
        operation,
        message: error.to_string(),
    })
}

fn sql_from_engine(error: EngineError) -> rusqlite::Error {
    rusqlite::Error::FromSqlConversionFailure(0, Type::Text, Box::new(error))
}

pub(super) fn sqlite_err(operation: &'static str, message: String) -> EngineError {
    EngineError::LedgerFailure { operation, message }
}
