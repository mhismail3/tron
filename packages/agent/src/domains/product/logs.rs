//! Authenticated client diagnostics ingestion and reads.
//!
//! This module owns the small logs namespace contract and handler binding.
//! Durable log storage is accessed through the event-store facade so request
//! translation stays separate from SQL/backend details. Recent-log reads are
//! bounded and may be narrowed by session, workspace, and trace identifiers;
//! the event-store owner applies those predicates before rows are returned.
//! Ingest accepts optional batch-level session/workspace/trace identifiers and
//! applies them only to entries that do not already carry entry-level scope.
//! Handlers borrow the shared event-store handle directly and own no parallel
//! dependency or storage-state container.

use crate::domains::registration::bindings::operation_bindings;
use crate::domains::registration::composition::{
    DomainFunctionRegistration, DomainRegistrationContext,
};
use crate::domains::registration::contract::FunctionContract;
use crate::domains::session::event_store::{
    ClientLogEntry, EventStore, LogEntry, LogSessionFilter, RecentLogQuery,
};
use crate::engine::{
    EffectClass, FunctionDefinition, IdempotencyContract, Result as EngineResult, RiskLevel,
};
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::error_mapping::map_event_store_error;
use crate::shared::server::errors::ToolError;
use crate::shared::server::errors::to_json_value;
use serde::Deserialize;
use serde::Serialize;
use serde_json::Value;
use serde_json::json;
use std::sync::Arc;

pub(crate) fn function_registrations(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<Vec<DomainFunctionRegistration>> {
    bind_functions(function_definitions()?, Arc::clone(&deps.event_store))
}

const DEFAULT_RECENT_LIMIT: u32 = 200;
const MAX_RECENT_LIMIT: u32 = 1_000;

pub(crate) fn function_definitions() -> EngineResult<Vec<FunctionDefinition>> {
    Ok(vec![
        FunctionContract::new(
            "logs::ingest",
            "logs",
            EffectClass::AppendOnlyEvent,
            RiskLevel::Medium)
        .request_schema(json!({"additionalProperties":false,"properties":{"entries":{"items":{"additionalProperties":false,"properties":{"category":{"type":"string"},"level":{"type":"string"},"message":{"type":"string"},"sessionId":{"type":"string"},"timestamp":{"type":"string"},"traceId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["timestamp","level","category","message"],"type":"object"},"maxItems":10000,"type":"array"},"sessionId":{"type":"string"},"traceId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["entries"],"type":"object"}))
        .response_schema(json!({"additionalProperties":false,"properties":{"inserted":{"type":"integer"},"success":{"type":"boolean"}},"required":["success","inserted"],"type":"object"}))
        .idempotency(IdempotencyContract::profile())
        .build()?,
        FunctionContract::new(
            "logs::recent",
            "logs",
            EffectClass::PureRead,
            RiskLevel::Low)
        .request_schema(json!({"additionalProperties":false,"properties":{"limit":{"type":"integer"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"},"traceId":{"type":"string"}},"type":"object"}))
        .response_schema(json!({"additionalProperties":false,"properties":{"count":{"type":"integer"},"entries":{"items":{"additionalProperties":true,"type":"object"},"type":"array"}},"required":["entries","count"],"type":"object"}))
        .build()?,
    ])
}

operation_bindings! {
    deps = Arc<EventStore>;
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
    #[serde(default)]
    session_id: Option<String>,
    #[serde(default)]
    workspace_id: Option<String>,
    #[serde(default)]
    trace_id: Option<String>,
}

fn default_recent_limit() -> u32 {
    DEFAULT_RECENT_LIMIT
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct IngestLogsParams {
    entries: Vec<ClientLogEntry>,
    #[serde(default)]
    session_id: Option<String>,
    #[serde(default)]
    workspace_id: Option<String>,
    #[serde(default)]
    trace_id: Option<String>,
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
    workspace_id: Option<String>,
    trace_id: Option<String>,
    error_message: Option<String>,
}

async fn ingest_logs_value(
    params: Option<&Value>,
    event_store: &Arc<EventStore>,
) -> Result<Value, ToolError> {
    let params_value = params.ok_or_else(|| ToolError::InvalidParams {
        message: "Missing required parameter: entries".to_owned(),
    })?;
    let mut params: IngestLogsParams =
        serde_json::from_value(params_value.clone()).map_err(|error| ToolError::InvalidParams {
            message: format!("Invalid params: {error}"),
        })?;

    for entry in &mut params.entries {
        if entry.session_id.is_none() {
            entry.session_id.clone_from(&params.session_id);
        }
        if entry.workspace_id.is_none() {
            entry.workspace_id.clone_from(&params.workspace_id);
        }
        if entry.trace_id.is_none() {
            entry.trace_id.clone_from(&params.trace_id);
        }
    }

    let event_store = Arc::clone(event_store);
    let result = run_blocking_task("logs::ingest", move || {
        event_store
            .ingest_client_logs(&params.entries)
            .map_err(map_event_store_error)
    })
    .await?;

    to_json_value(&result)
}

async fn recent_logs_value(
    params: Option<Value>,
    event_store: &Arc<EventStore>,
) -> Result<Value, ToolError> {
    let params: RecentLogsParams = match params {
        Some(value) => serde_json::from_value(value).map_err(|error| ToolError::InvalidParams {
            message: format!("Invalid params: {error}"),
        })?,
        None => RecentLogsParams {
            limit: DEFAULT_RECENT_LIMIT,
            session_id: None,
            workspace_id: None,
            trace_id: None,
        },
    };

    if params.limit > MAX_RECENT_LIMIT {
        return Err(ToolError::InvalidParams {
            message: format!("limit must be <= {MAX_RECENT_LIMIT}"),
        });
    }

    let limit = i64::from(params.limit);
    let session_id = params.session_id;
    let workspace_id = params.workspace_id;
    let trace_id = params.trace_id;
    let event_store = Arc::clone(event_store);
    let result = run_blocking_task("logs::recent", move || {
        let session_filter = session_id
            .as_deref()
            .map(LogSessionFilter::OnlySession)
            .unwrap_or(LogSessionFilter::All);
        let query = RecentLogQuery {
            limit,
            trace_id: trace_id.as_deref(),
            workspace_id: workspace_id.as_deref(),
            session_filter,
        };
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
    serde_json::to_value(result).map_err(|error| ToolError::Internal {
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
            workspace_id: entry.workspace_id,
            trace_id: entry.trace_id,
            error_message: entry.error_message,
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::*;
    use crate::domains::session::event_store::{
        ConnectionConfig, EventStore, ensure_schema, new_in_memory,
    };

    fn make_event_store() -> Arc<EventStore> {
        let pool = new_in_memory(&ConnectionConfig::default()).expect("pool");
        {
            let conn = pool.get().expect("conn");
            ensure_schema(&conn).expect("schema");
        }
        Arc::new(EventStore::new(pool))
    }

    #[tokio::test]
    async fn recent_logs_honors_session_workspace_and_trace_filters() {
        let event_store = make_event_store();
        let mut current =
            ClientLogEntry::new("2026-03-03T14:30:05.100Z", "info", "Engine", "current");
        current.session_id = Some("sess_current".to_owned());
        current.workspace_id = Some("workspace_current".to_owned());
        current.trace_id = Some("trace_current".to_owned());
        let mut other_session = ClientLogEntry::new(
            "2026-03-03T14:30:05.200Z",
            "warn",
            "Engine",
            "other session",
        );
        other_session.session_id = Some("sess_other".to_owned());
        other_session.workspace_id = Some("workspace_current".to_owned());
        other_session.trace_id = Some("trace_current".to_owned());
        let mut other_workspace = ClientLogEntry::new(
            "2026-03-03T14:30:05.300Z",
            "error",
            "Engine",
            "other workspace",
        );
        other_workspace.session_id = Some("sess_current".to_owned());
        other_workspace.workspace_id = Some("workspace_other".to_owned());
        other_workspace.trace_id = Some("trace_current".to_owned());

        event_store
            .ingest_client_logs(&[current, other_session, other_workspace])
            .expect("ingest");

        let value = recent_logs_value(
            Some(json!({
                "limit": 10,
                "sessionId": "sess_current",
                "workspaceId": "workspace_current",
                "traceId": "trace_current"
            })),
            &event_store,
        )
        .await
        .expect("recent logs");

        assert_eq!(value["count"], 1);
        assert_eq!(value["entries"][0]["message"], "current");
        assert_eq!(value["entries"][0]["sessionId"], "sess_current");
        assert_eq!(value["entries"][0]["workspaceId"], "workspace_current");
        assert_eq!(value["entries"][0]["traceId"], "trace_current");
    }

    #[tokio::test]
    async fn ingest_logs_applies_batch_scope_to_unscoped_entries() {
        let event_store = make_event_store();

        let value = ingest_logs_value(
            Some(&json!({
                "sessionId": "sess_current",
                "workspaceId": "workspace_current",
                "traceId": "trace_current",
                "entries": [{
                    "timestamp": "2026-03-03T14:30:05.100Z",
                    "level": "info",
                    "category": "Engine",
                    "message": "current"
                }]
            })),
            &event_store,
        )
        .await
        .expect("ingest logs");

        assert_eq!(value["inserted"], 1);

        let recent = recent_logs_value(
            Some(json!({
                "limit": 10,
                "sessionId": "sess_current",
                "workspaceId": "workspace_current",
                "traceId": "trace_current"
            })),
            &event_store,
        )
        .await
        .expect("recent logs");

        assert_eq!(recent["count"], 1);
        assert_eq!(recent["entries"][0]["message"], "current");
        assert_eq!(recent["entries"][0]["sessionId"], "sess_current");
        assert_eq!(recent["entries"][0]["workspaceId"], "workspace_current");
        assert_eq!(recent["entries"][0]["traceId"], "trace_current");
    }

    #[tokio::test]
    async fn ingest_logs_keeps_entry_scope_when_batch_scope_differs() {
        let event_store = make_event_store();

        ingest_logs_value(
            Some(&json!({
                "sessionId": "sess_batch",
                "workspaceId": "workspace_batch",
                "traceId": "trace_batch",
                "entries": [{
                    "timestamp": "2026-03-03T14:30:05.100Z",
                    "level": "info",
                    "category": "Engine",
                    "message": "entry scoped",
                    "sessionId": "sess_entry",
                    "workspaceId": "workspace_entry",
                    "traceId": "trace_entry"
                }]
            })),
            &event_store,
        )
        .await
        .expect("ingest logs");

        let recent = recent_logs_value(
            Some(json!({
                "limit": 10,
                "sessionId": "sess_entry",
                "workspaceId": "workspace_entry",
                "traceId": "trace_entry"
            })),
            &event_store,
        )
        .await
        .expect("recent logs");

        assert_eq!(recent["count"], 1);
        assert_eq!(recent["entries"][0]["message"], "entry scoped");
    }
}
