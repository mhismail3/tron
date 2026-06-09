//! logs domain worker.
//!
//! This module owns the small logs namespace contract/deps/handler binding.
//! Durable log storage is accessed through the event-store facade so request
//! translation stays separate from SQL/backend details.

use crate::domains::registration::bindings::operation_bindings;
use crate::domains::registration::catalog::CapabilitySpec;
use crate::domains::registration::contract::CapabilityContract;
use crate::domains::registration::worker::DomainRegistrationContext;
use crate::domains::registration::worker::DomainWorkerModule;
use crate::domains::session::event_store::{ClientLogEntry, EventStore, LogEntry, RecentLogQuery};
use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    Result as EngineResult, RiskLevel,
};
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::error_mapping::map_event_store_error;
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
        crate::domains::registration::worker::domain_worker_module(
            "logs",
            STREAM_TOPICS,
            function_registrations(capabilities()?, domain_deps)?,
        )
    }
}

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

    let event_store = deps.event_store.clone();
    let result = run_blocking_task("logs::ingest", move || {
        event_store
            .ingest_client_logs(&entries)
            .map_err(map_event_store_error)
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

    let query = RecentLogQuery::all(i64::from(params.limit));
    let event_store = deps.event_store.clone();
    let result = run_blocking_task("logs::recent", move || {
        let entries = event_store
            .list_recent_logs(query)
            .map_err(map_event_store_error)?
            .into_iter()
            .map(RecentLogEntry::from)
            .collect::<Vec<_>>();
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

impl From<LogEntry> for RecentLogEntry {
    fn from(entry: LogEntry) -> Self {
        Self {
            id: entry.id,
            timestamp: entry.timestamp,
            level: entry.level,
            component: entry.component,
            message: entry.message,
            session_id: entry.session_id,
            error_message: entry.error_message,
        }
    }
}
