//! logs domain worker.
//!
//! This module owns the small logs namespace contract/deps/handler binding.
//! Client log ingestion stays in `client_logs` because it is a real service
//! boundary with parsing, dedupe, and storage behavior.

use crate::domains::bindings::operation_bindings;
use crate::domains::catalog::CapabilitySpec;
use crate::domains::contract::CapabilityContract;
use crate::domains::logs::client_logs::ClientLogEntry;
use crate::domains::logs::client_logs::ClientLogsService;
use crate::domains::session::event_store::EventStore;
use crate::domains::worker::DomainRegistrationContext;
use crate::domains::worker::DomainWorkerModule;
use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    Result as EngineResult, RiskLevel,
};
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::errors::to_json_value;
use serde::Deserialize;
use serde::Serialize;
use serde_json::Value;
use serde_json::json;
use std::sync::Arc;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        crate::domains::worker::domain_worker_module(
            "logs",
            STREAM_TOPICS,
            function_registrations(capabilities()?, domain_deps)?,
        )
    }
}

pub(crate) mod client_logs;

const STREAM_TOPICS: &[&str] = &["logs.ingest"];
const DEFAULT_RECENT_LIMIT: u32 = 200;
const MAX_RECENT_LIMIT: u32 = 1_000;

#[derive(Clone)]
pub(crate) struct Deps {
    event_store: Arc<EventStore>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            event_store: deps.event_store.clone(),
        }
    }
}

pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new(
            "logs::ingest",
            "logs",
            EffectClass::AppendOnlyEvent,
            RiskLevel::Medium,
            Some("logs.write"),
        )
        .request_schema(json!({"additionalProperties":false,"properties":{"entries":{"items":{"additionalProperties":false,"properties":{"category":{"type":"string"},"level":{"type":"string"},"message":{"type":"string"},"timestamp":{"type":"string"}},"required":["timestamp","level","category","message"],"type":"object"},"maxItems":10000,"type":"array"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["entries"],"type":"object"}))
        .response_schema(json!({"additionalProperties":false,"properties":{"inserted":{"type":"integer"},"success":{"type":"boolean"}},"required":["success","inserted"],"type":"object"}))
        .idempotency(IdempotencyContract::caller_system_engine_ledger())
        .compensation(CompensationContract::new(
            CompensationKind::EventSourced,
            "domain-specific tests preserve current rollback, no-op, or replay behavior",
        ))
        .build()?,
        CapabilityContract::new(
            "logs::recent",
            "logs",
            EffectClass::PureRead,
            RiskLevel::Low,
            Some("logs.read"),
        )
        .request_schema(json!({"additionalProperties":false,"properties":{"limit":{"type":"integer"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
        .response_schema(json!({"additionalProperties":false,"properties":{"count":{"type":"integer"},"entries":{"items":{"additionalProperties":true,"type":"object"},"type":"array"}},"required":["entries","count"],"type":"object"}))
        .build()?,
    ])
}

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "ingest" => |invocation, deps| {
            ingest_logs_value(Some(&invocation.payload), deps).await
        },
        "recent" => |invocation, deps| {
            recent_logs_value(Some(invocation.payload.clone()), deps).await
        },
    ];
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RecentLogsParams {
    #[serde(default = "default_recent_limit")]
    limit: u32,
}

fn default_recent_limit() -> u32 {
    DEFAULT_RECENT_LIMIT
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RecentLogsResult {
    entries: Vec<RecentLogEntry>,
    count: usize,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RecentLogEntry {
    id: i64,
    timestamp: String,
    level: String,
    component: String,
    message: String,
    session_id: Option<String>,
    error_message: Option<String>,
}

async fn ingest_logs_value(params: Option<&Value>, deps: &Deps) -> Result<Value, CapabilityError> {
    let entries_value = params
        .and_then(|value| value.get("entries"))
        .ok_or_else(|| CapabilityError::InvalidParams {
            message: "Missing required parameter: entries".to_owned(),
        })?;
    let entries: Vec<ClientLogEntry> =
        serde_json::from_value(entries_value.clone()).map_err(|error| {
            CapabilityError::InvalidParams {
                message: format!("Invalid entries: {error}"),
            }
        })?;

    let pool = deps.event_store.pool().clone();
    let result = run_blocking_task("logs::ingest", move || {
        let mut conn = pool.get().map_err(|error| CapabilityError::Internal {
            message: format!("Failed to get DB connection: {error}"),
        })?;
        ClientLogsService::ingest(&mut conn, &entries)
    })
    .await?;

    to_json_value(&result)
}

async fn recent_logs_value(params: Option<Value>, deps: &Deps) -> Result<Value, CapabilityError> {
    let params: RecentLogsParams = match params {
        Some(value) => {
            serde_json::from_value(value).map_err(|error| CapabilityError::InvalidParams {
                message: format!("Invalid params: {error}"),
            })?
        }
        None => RecentLogsParams {
            limit: DEFAULT_RECENT_LIMIT,
        },
    };

    if params.limit > MAX_RECENT_LIMIT {
        return Err(CapabilityError::InvalidParams {
            message: format!("limit must be <= {MAX_RECENT_LIMIT}"),
        });
    }

    let limit = i64::from(params.limit);
    let pool = deps.event_store.pool().clone();
    let result = run_blocking_task("logs::recent", move || {
        let conn = pool.get().map_err(|error| CapabilityError::Internal {
            message: format!("Failed to get DB connection: {error}"),
        })?;
        let mut stmt = conn
            .prepare(
                "SELECT id, timestamp, level, component, message, session_id, error_message \
                 FROM logs ORDER BY id DESC LIMIT ?1",
            )
            .map_err(|error| CapabilityError::Internal {
                message: format!("Failed to prepare logs query: {error}"),
            })?;
        let rows = stmt
            .query_map([limit], |row| {
                Ok(RecentLogEntry {
                    id: row.get(0)?,
                    timestamp: row.get(1)?,
                    level: row.get(2)?,
                    component: row.get(3)?,
                    message: row.get(4)?,
                    session_id: row.get(5)?,
                    error_message: row.get(6)?,
                })
            })
            .map_err(|error| CapabilityError::Internal {
                message: format!("Failed to read logs: {error}"),
            })?;

        let mut entries =
            rows.collect::<Result<Vec<_>, _>>()
                .map_err(|error| CapabilityError::Internal {
                    message: format!("Failed to decode logs: {error}"),
                })?;
        entries.reverse();
        Ok(RecentLogsResult {
            count: entries.len(),
            entries,
        })
    })
    .await?;
    serde_json::to_value(result).map_err(|error| CapabilityError::Internal {
        message: error.to_string(),
    })
}
