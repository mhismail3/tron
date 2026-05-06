use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU16, Ordering};
use std::time::Instant;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::engine::{ActorKind, EngineError, InProcessFunctionHandler, Invocation};
use crate::events::EventStore;
use crate::prompt_library::store;
use crate::runtime::orchestrator::orchestrator::Orchestrator;
use crate::runtime::orchestrator::session_manager::SessionManager;
use crate::runtime::profile_runtime::ProfileRuntime;
use crate::server::rpc::context::{RpcContext, run_blocking_task};
use crate::server::rpc::errors::{self, CLIENT_VERSION_UNSUPPORTED, RpcError, to_json_value};
use crate::server::rpc::filesystem_service;
use crate::server::rpc::handlers::{
    events, map_event_store_error, model, opt_array, opt_string, opt_u64, require_string_param,
    system,
};
use crate::server::rpc::validation::validate_string_param;
use crate::skills::registry::SkillRegistry;

use super::rpc_error_to_engine;

#[derive(Clone)]
pub(super) struct RpcEngineDeps {
    orchestrator: Arc<Orchestrator>,
    session_manager: Arc<SessionManager>,
    event_store: Arc<EventStore>,
    skill_registry: Arc<parking_lot::RwLock<SkillRegistry>>,
    profile_runtime: Arc<ProfileRuntime>,
    server_start_time: Instant,
    auth_path: PathBuf,
    ws_port: Arc<AtomicU16>,
    onboarded_marker_path: PathBuf,
}

impl RpcEngineDeps {
    pub(super) fn from_context(ctx: &RpcContext) -> Self {
        Self {
            orchestrator: Arc::clone(&ctx.orchestrator),
            session_manager: Arc::clone(&ctx.session_manager),
            event_store: Arc::clone(&ctx.event_store),
            skill_registry: Arc::clone(&ctx.skill_registry),
            profile_runtime: Arc::clone(&ctx.profile_runtime),
            server_start_time: ctx.server_start_time,
            auth_path: ctx.auth_path.clone(),
            ws_port: Arc::clone(&ctx.ws_port),
            onboarded_marker_path: ctx.onboarded_marker_path.clone(),
        }
    }
}

pub(super) struct RpcReadFunctionHandler {
    pub(super) method: &'static str,
    pub(super) deps: RpcEngineDeps,
}

#[async_trait]
impl InProcessFunctionHandler for RpcReadFunctionHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value, EngineError> {
        rpc_read_value(self.method, &invocation, &self.deps)
            .await
            .map_err(rpc_error_to_engine)
    }
}

async fn rpc_read_value(
    method: &str,
    invocation: &Invocation,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let payload = &invocation.payload;
    let allow_rpc_context = matches!(invocation.causal_context.actor_kind, ActorKind::Client);
    match method {
        "system.ping" => ping_value(Some(payload)),
        "system.getInfo" => Ok(system_info_value(payload, deps, allow_rpc_context)),
        "settings.get" => {
            serde_json::to_value(&deps.profile_runtime.current().settings).map_err(|error| {
                RpcError::Internal {
                    message: error.to_string(),
                }
            })
        }
        "model.list" => model_list_value(payload, deps, allow_rpc_context).await,
        "skill.list" => Ok(skill_list_value(Some(payload), deps)),
        "logs.recent" => recent_logs_value(Some(payload.clone()), deps).await,
        "events.getHistory" => events_get_history_value(Some(payload), deps).await,
        "events.getSince" => events_get_since_value(Some(payload), deps).await,
        "filesystem.getHome" => filesystem_get_home_value(deps).await,
        "promptHistory.list" => prompt_history_list_value(Some(payload), deps).await,
        "promptSnippet.list" => prompt_snippet_list_value(deps).await,
        "promptSnippet.get" => prompt_snippet_get_value(Some(payload), deps).await,
        _ => Err(RpcError::Internal {
            message: format!("RPC method {method} is not engine-owned"),
        }),
    }
}

fn ping_value(params: Option<&Value>) -> Result<Value, RpcError> {
    let client_protocol_raw = params
        .and_then(|p| p.get("protocolVersion"))
        .and_then(Value::as_u64)
        .ok_or_else(|| RpcError::InvalidParams {
            message: "system.ping requires numeric protocolVersion".into(),
        })?;
    let client_protocol =
        u32::try_from(client_protocol_raw).map_err(|_| RpcError::InvalidParams {
            message: "system.ping protocolVersion is too large".into(),
        })?;
    let client_version = params
        .and_then(|p| p.get("clientVersion"))
        .and_then(Value::as_str)
        .map(String::from);

    if client_protocol < system::MIN_CLIENT_PROTOCOL_VERSION {
        return Err(RpcError::Custom {
            code: CLIENT_VERSION_UNSUPPORTED.to_string(),
            message: format!(
                "Client protocol version {client_protocol} is below the minimum supported version \
                 {}. Please upgrade the Tron client.",
                system::MIN_CLIENT_PROTOCOL_VERSION
            ),
            details: Some(json!({
                "clientProtocolVersion": client_protocol,
                "minClientProtocolVersion": system::MIN_CLIENT_PROTOCOL_VERSION,
                "serverProtocolVersion": system::CURRENT_PROTOCOL_VERSION,
                "serverVersion": env!("CARGO_PKG_VERSION"),
                "clientVersion": client_version,
            })),
        });
    }

    Ok(json!({
        "pong": true,
        "timestamp": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
        "serverVersion": env!("CARGO_PKG_VERSION"),
        "serverProtocolVersion": system::CURRENT_PROTOCOL_VERSION,
        "minClientProtocolVersion": system::MIN_CLIENT_PROTOCOL_VERSION,
        "compatible": true,
    }))
}

fn system_info_value(payload: &Value, deps: &RpcEngineDeps, allow_rpc_context: bool) -> Value {
    let marker_path = allow_rpc_context
        .then(|| {
            payload
                .pointer("/__rpcContext/onboardedMarkerPath")
                .and_then(Value::as_str)
                .map(PathBuf::from)
        })
        .flatten()
        .unwrap_or_else(|| deps.onboarded_marker_path.clone());
    json!({
        "version": env!("CARGO_PKG_VERSION"),
        "uptime": deps.server_start_time.elapsed().as_secs(),
        "activeSessions": deps.orchestrator.active_session_count(),
        "platform": std::env::consts::OS,
        "arch": std::env::consts::ARCH,
        "runtime": "agent",
        "port": deps.ws_port.load(Ordering::SeqCst),
        "tailscaleIp": deps.profile_runtime.current().settings.server.tailscale_ip,
        "paired": crate::server::onboarding::is_onboarded(&marker_path),
    })
}

async fn model_list_value(
    payload: &Value,
    deps: &RpcEngineDeps,
    allow_rpc_context: bool,
) -> Result<Value, RpcError> {
    let auth_json_path = allow_rpc_context
        .then(|| {
            payload
                .pointer("/__rpcContext/authPath")
                .and_then(Value::as_str)
                .map(PathBuf::from)
        })
        .flatten()
        .unwrap_or_else(|| deps.auth_path.clone());
    let auth_path = crate::llm::auth::openai::infer_auth_path(&auth_json_path, None)
        .unwrap_or(crate::llm::openai::types::OpenAIAuthPath::ChatGptCodex);
    Ok(json!({ "models": model::known_models(auth_path).await }))
}

fn skill_list_value(params: Option<&Value>, deps: &RpcEngineDeps) -> Value {
    let working_dir = resolve_skill_working_dir(params, deps);
    let mut registry = deps.skill_registry.write();
    let _ = registry.refresh_if_stale(&working_dir);
    let skills = registry.list(None);
    json!({ "skills": skills })
}

fn resolve_skill_working_dir(params: Option<&Value>, deps: &RpcEngineDeps) -> String {
    if let Some(wd) = params
        .and_then(|value| value.get("workingDirectory"))
        .and_then(Value::as_str)
    {
        return wd.to_owned();
    }
    if let Some(session_id) = params
        .and_then(|value| value.get("sessionId"))
        .and_then(Value::as_str)
    {
        if let Ok(Some(session)) = deps.session_manager.get_session(session_id) {
            return session.working_directory;
        }
    }
    "/tmp".to_owned()
}

async fn events_get_history_value(
    params: Option<&Value>,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let session_id = require_string_param(params, "sessionId")?;
    deps.event_store
        .get_session(&session_id)
        .map_err(map_event_store_error)?
        .ok_or_else(|| RpcError::NotFound {
            code: errors::SESSION_NOT_FOUND.into(),
            message: format!("Session '{session_id}' not found"),
        })?;

    let limit = params.and_then(|p| p.get("limit")).and_then(Value::as_i64);
    let type_filter: Option<Vec<String>> = opt_array(params, "types").map(|arr| {
        arr.iter()
            .filter_map(|v| v.as_str().map(String::from))
            .collect()
    });
    let before_event_id = opt_string(params, "beforeEventId");

    let events = if let Some(ref types) = type_filter {
        let type_strs: Vec<&str> = types.iter().map(String::as_str).collect();
        deps.event_store
            .get_events_by_type(&session_id, &type_strs, limit)
            .map_err(map_event_store_error)?
    } else {
        let opts = crate::events::sqlite::repositories::event::ListEventsOptions {
            limit,
            offset: None,
        };
        deps.event_store
            .get_events_by_session(&session_id, &opts)
            .map_err(map_event_store_error)?
    };

    let events = if let Some(before_id) = before_event_id {
        events
            .into_iter()
            .take_while(|e| e.id != before_id)
            .collect::<Vec<_>>()
    } else {
        events
    };

    let has_more = limit.is_some_and(|l| i64::try_from(events.len()).unwrap_or(0) >= l);
    let oldest_event_id = events.first().map(|e| e.id.clone());
    let mut wire_events: Vec<Value> = events.iter().map(events::event_row_to_wire).collect();
    crate::server::rpc::interactive_tool_enrichment::enrich_interactive_tool_statuses(
        &mut wire_events,
    );

    Ok(json!({
        "sessionId": session_id,
        "events": wire_events,
        "hasMore": has_more,
        "oldestEventId": oldest_event_id,
    }))
}

async fn events_get_since_value(
    params: Option<&Value>,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let session_id = require_string_param(params, "sessionId")?;
    let after_sequence = if let Some(event_id) = opt_string(params, "afterEventId") {
        deps.event_store
            .get_event(&event_id)
            .map_err(map_event_store_error)?
            .map_or(-1, |row| row.sequence)
    } else {
        params
            .and_then(|p| p.get("afterSequence"))
            .and_then(Value::as_i64)
            .unwrap_or(-1)
    };
    let limit = params.and_then(|p| p.get("limit")).and_then(Value::as_i64);
    let mut events = deps
        .event_store
        .get_events_since(&session_id, after_sequence)
        .map_err(map_event_store_error)?;
    let has_more = limit.is_some_and(|l| i64::try_from(events.len()).unwrap_or(0) >= l);
    if let Some(l) = limit {
        events.truncate(usize::try_from(l).unwrap_or(usize::MAX));
    }
    let mut wire_events: Vec<Value> = events.iter().map(events::event_row_to_wire).collect();
    crate::server::rpc::interactive_tool_enrichment::enrich_interactive_tool_statuses(
        &mut wire_events,
    );
    let next_cursor = events.last().map(|r| r.id.clone());
    Ok(json!({
        "events": wire_events,
        "hasMore": has_more,
        "nextCursor": next_cursor,
    }))
}

async fn filesystem_get_home_value(_deps: &RpcEngineDeps) -> Result<Value, RpcError> {
    let home = crate::core::paths::home_dir();
    run_blocking_task("filesystem.getHome", move || {
        Ok(filesystem_service::get_home(&home))
    })
    .await
}

async fn prompt_history_list_value(
    params: Option<&Value>,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let limit_raw = opt_u64(params, "limit", store::DEFAULT_LIST_LIMIT as u64);
    if limit_raw > store::MAX_LIST_LIMIT as u64 {
        return Err(RpcError::InvalidParams {
            message: format!(
                "'limit' must be ≤ {} (got {limit_raw})",
                store::MAX_LIST_LIMIT
            ),
        });
    }
    let limit = limit_raw as u32;
    let cursor = opt_string(params, "cursor");
    let query = opt_string(params, "query");
    if let Some(ref query) = query {
        validate_string_param(query, "query", MAX_SEARCH_QUERY_LEN)?;
    }

    let page = store::list_history(deps.event_store.pool(), limit, cursor, query)
        .map_err(map_store_err)?;
    Ok(json!({
        "items": to_json_value(&page.items)?,
        "nextCursor": page.next_cursor,
    }))
}

async fn prompt_snippet_list_value(deps: &RpcEngineDeps) -> Result<Value, RpcError> {
    let items = store::list_snippets(deps.event_store.pool()).map_err(map_store_err)?;
    Ok(json!({ "items": to_json_value(&items)? }))
}

async fn prompt_snippet_get_value(
    params: Option<&Value>,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let id = require_string_param(params, "id")?;
    let snippet = store::get_snippet(deps.event_store.pool(), &id)
        .map_err(map_store_err)?
        .ok_or_else(|| RpcError::NotFound {
            code: "SNIPPET_NOT_FOUND".into(),
            message: format!("Snippet not found: {id}"),
        })?;
    Ok(json!({ "snippet": to_json_value(&snippet)? }))
}

const DEFAULT_RECENT_LIMIT: u32 = 200;
const MAX_RECENT_LIMIT: u32 = 1_000;
const MAX_SEARCH_QUERY_LEN: usize = 200;

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

async fn recent_logs_value(params: Option<Value>, deps: &RpcEngineDeps) -> Result<Value, RpcError> {
    let params: RecentLogsParams = match params {
        Some(value) => serde_json::from_value(value).map_err(|error| RpcError::InvalidParams {
            message: format!("Invalid params: {error}"),
        })?,
        None => RecentLogsParams {
            limit: DEFAULT_RECENT_LIMIT,
        },
    };

    if params.limit > MAX_RECENT_LIMIT {
        return Err(RpcError::InvalidParams {
            message: format!("limit must be <= {MAX_RECENT_LIMIT}"),
        });
    }

    let limit = i64::from(params.limit);
    let pool = deps.event_store.pool().clone();
    let result = run_blocking_task("logs.recent", move || {
        let conn = pool.get().map_err(|error| RpcError::Internal {
            message: format!("Failed to get DB connection: {error}"),
        })?;
        let mut stmt = conn
            .prepare(
                "SELECT id, timestamp, level, component, message, origin, session_id, error_message \
                 FROM logs ORDER BY id DESC LIMIT ?1",
            )
            .map_err(|error| RpcError::Internal {
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
            .map_err(|error| RpcError::Internal {
                message: format!("Failed to read logs: {error}"),
            })?;

        let mut entries = rows
            .collect::<Result<Vec<_>, _>>()
            .map_err(|error| RpcError::Internal {
                message: format!("Failed to decode logs: {error}"),
            })?;
        entries.reverse();
        Ok(RecentLogsResult {
            count: entries.len(),
            entries,
        })
    })
    .await?;
    serde_json::to_value(result).map_err(|error| RpcError::Internal {
        message: error.to_string(),
    })
}

fn map_store_err(e: crate::events::EventStoreError) -> RpcError {
    match e {
        crate::events::EventStoreError::Sqlite(err) => RpcError::Internal {
            message: format!("Database error: {err}"),
        },
        crate::events::EventStoreError::Internal(msg) => RpcError::Internal { message: msg },
        other => map_event_store_error(other),
    }
}
