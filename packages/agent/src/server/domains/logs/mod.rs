//! logs domain worker.
//!
//! This module owns canonical function execution for the logs namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.

pub(crate) mod contract;
pub(crate) mod spec;

use super::*;
#[derive(Clone)]
pub(crate) struct Deps {
    event_store: Arc<EventStore>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &EngineCapabilityDeps) -> Self {
        Self {
            event_store: deps.event_store.clone(),
        }
    }
}

pub(crate) mod client_logs;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let payload = &invocation.payload;
    match method {
        "logs::ingest" => ingest_logs_value(Some(payload), deps).await,
        "logs::recent" => recent_logs_value(Some(payload.clone()), deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("logs method {method} is not engine-owned"),
        }),
    }
}

const DEFAULT_RECENT_LIMIT: u32 = 200;
const MAX_RECENT_LIMIT: u32 = 1_000;

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
    origin: Option<String>,
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
                "SELECT id, timestamp, level, component, message, origin, session_id, error_message \
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
                    origin: row.get(5)?,
                    session_id: row.get(6)?,
                    error_message: row.get(7)?,
                })
            })
            .map_err(|error| CapabilityError::Internal {
                message: format!("Failed to read logs: {error}"),
            })?;

        let mut entries = rows
            .collect::<Result<Vec<_>, _>>()
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
