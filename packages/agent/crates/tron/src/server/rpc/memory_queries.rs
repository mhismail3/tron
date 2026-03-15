//! Shared read-side memory query logic used by the RPC handlers.

use std::collections::HashMap;

use serde_json::Value;
use crate::events::EventStore;
use crate::events::sqlite::row_types::EventRow;
use crate::runtime::SessionFilter;
use crate::runtime::orchestrator::session_manager::SessionManager;

use crate::server::rpc::errors::RpcError;

const MEMORY_LEDGER_TYPE: &str = "memory.ledger";
const SEARCH_SESSION_LEDGER_CAP: usize = 100;

/// Shared synchronous service for memory ledger queries.
pub(crate) struct MemoryQueryService;

impl MemoryQueryService {
    pub(crate) fn get_ledger(
        event_store: &EventStore,
        working_dir: Option<&str>,
        limit: i64,
        offset: i64,
        tags_filter: Option<&[String]>,
    ) -> Result<Value, RpcError> {
        let (all_events_for_tags, count_and_page) = if let Some(dir) = working_dir {
            let workspaces = event_store
                .find_workspaces_by_path_prefix(dir)
                .unwrap_or_default();

            if workspaces.is_empty() {
                return Ok(serde_json::json!({
                    "entries": [],
                    "hasMore": false,
                    "totalCount": 0,
                }));
            }

            let workspace_ids: Vec<&str> = workspaces
                .iter()
                .map(|workspace| workspace.id.as_str())
                .collect();

            if tags_filter.is_some() {
                let events = event_store
                    .get_events_by_workspaces_and_types(
                        &workspace_ids,
                        &[MEMORY_LEDGER_TYPE],
                        None,
                        None,
                    )
                    .unwrap_or_default();
                (Some(events), None)
            } else {
                let total_count = event_store
                    .count_events_by_workspaces_and_types(&workspace_ids, &[MEMORY_LEDGER_TYPE])
                    .unwrap_or(0);
                let events = event_store
                    .get_events_by_workspaces_and_types(
                        &workspace_ids,
                        &[MEMORY_LEDGER_TYPE],
                        Some(limit),
                        Some(offset),
                    )
                    .unwrap_or_default();
                (None, Some((events, total_count)))
            }
        } else if tags_filter.is_some() {
            let events = event_store
                .get_all_events_by_types(&[MEMORY_LEDGER_TYPE], None, None)
                .unwrap_or_default();
            (Some(events), None)
        } else {
            let total_count = event_store
                .count_all_events_by_types(&[MEMORY_LEDGER_TYPE])
                .unwrap_or(0);
            let events = event_store
                .get_all_events_by_types(&[MEMORY_LEDGER_TYPE], Some(limit), Some(offset))
                .unwrap_or_default();
            (None, Some((events, total_count)))
        };

        if let Some(all_events) = all_events_for_tags {
            let tags = tags_filter.ok_or_else(|| RpcError::Internal {
                message: "memory tag filter state was inconsistent".into(),
            })?;
            let filtered: Vec<Value> = all_events
                .iter()
                .map(ledger_event_to_dto)
                .filter(|dto| {
                    let entry_tags = dto["tags"]
                        .as_array()
                        .map(|arr| {
                            arr.iter()
                                .filter_map(Value::as_str)
                                .map(String::from)
                                .collect::<Vec<_>>()
                        })
                        .unwrap_or_default();
                    tags.iter().any(|tag| entry_tags.contains(tag))
                })
                .collect();

            let total_count = filtered.len();
            let offset_usize = usize::try_from(offset).unwrap_or(0);
            let limit_usize = usize::try_from(limit).unwrap_or(usize::MAX);
            let entries: Vec<Value> = filtered
                .into_iter()
                .skip(offset_usize)
                .take(limit_usize)
                .collect();
            let has_more = offset_usize + limit_usize < total_count;

            return Ok(serde_json::json!({
                "entries": entries,
                "hasMore": has_more,
                "totalCount": total_count,
            }));
        }

        let (events, total_count) = count_and_page.ok_or_else(|| RpcError::Internal {
            message: "memory ledger pagination state was inconsistent".into(),
        })?;
        let entries: Vec<Value> = events.iter().map(ledger_event_to_dto).collect();
        #[allow(clippy::cast_possible_wrap)]
        let has_more = (offset + limit) < total_count;

        Ok(serde_json::json!({
            "entries": entries,
            "hasMore": has_more,
            "totalCount": total_count,
        }))
    }

    pub(crate) fn search(
        event_store: &EventStore,
        session_manager: &SessionManager,
        search_text: &str,
        type_filter: Option<&str>,
        limit: usize,
    ) -> Result<Value, RpcError> {
        let sessions = session_manager
            .list_sessions(&SessionFilter {
                include_archived: true,
                ..Default::default()
            })
            .unwrap_or_default();
        if sessions.is_empty() {
            return Ok(serde_json::json!({
                "entries": [],
                "totalCount": 0,
            }));
        }

        let session_ids: Vec<&str> = sessions.iter().map(|session| session.id.as_str()).collect();
        let events = event_store
            .get_events_by_sessions_and_types(&session_ids, &[MEMORY_LEDGER_TYPE])
            .map_err(|error| RpcError::Internal {
                message: format!("Failed to load memory ledger events: {error}"),
            })?;

        let mut events_by_session: HashMap<String, Vec<EventRow>> = HashMap::new();
        for event in events {
            events_by_session
                .entry(event.session_id.clone())
                .or_default()
                .push(event);
        }

        let search_lower = search_text.to_lowercase();
        let mut entries = Vec::new();

        for session in sessions {
            let Some(session_events) = events_by_session.get(&session.id) else {
                continue;
            };

            for event in session_events.iter().take(SEARCH_SESSION_LEDGER_CAP) {
                let payload: Value = match serde_json::from_str(&event.payload) {
                    Ok(value) => value,
                    Err(_) => continue,
                };

                if !search_lower.is_empty()
                    && !payload.to_string().to_lowercase().contains(&search_lower)
                {
                    continue;
                }

                if let Some(type_filter) = type_filter {
                    let entry_type = payload
                        .get("entryType")
                        .and_then(Value::as_str)
                        .unwrap_or("");
                    if entry_type != type_filter {
                        continue;
                    }
                }

                entries.push(search_event_to_dto(event, &payload));

                if entries.len() >= limit {
                    break;
                }
            }

            if entries.len() >= limit {
                break;
            }
        }

        let total_count = entries.len();
        Ok(serde_json::json!({
            "entries": entries,
            "totalCount": total_count,
        }))
    }
}

fn ledger_event_to_dto(event: &EventRow) -> Value {
    let payload: Value = serde_json::from_str(&event.payload).unwrap_or_default();
    serde_json::json!({
        "id": event.id,
        "sessionId": event.session_id,
        "timestamp": event.timestamp,
        "title": payload.get("title"),
        "entryType": payload.get("entryType"),
        "input": payload.get("input"),
        "actions": payload.get("actions").unwrap_or(&serde_json::json!([])),
        "decisions": payload.get("decisions").unwrap_or(&serde_json::json!([])),
        "lessons": payload.get("lessons").unwrap_or(&serde_json::json!([])),
        "insights": payload.get("thinkingInsights").unwrap_or(&serde_json::json!([])),
        "tags": payload.get("tags").unwrap_or(&serde_json::json!([])),
        "files": payload.get("files").unwrap_or(&serde_json::json!([])),
        "model": payload.get("model"),
        "tokenCost": payload.get("tokenCost"),
    })
}

fn search_event_to_dto(event: &EventRow, payload: &Value) -> Value {
    let content = payload
        .get("input")
        .and_then(Value::as_str)
        .or_else(|| payload.get("title").and_then(Value::as_str))
        .unwrap_or("");
    let entry_type = payload
        .get("entryType")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let source = payload
        .get("source")
        .and_then(Value::as_str)
        .unwrap_or("ledger");
    serde_json::json!({
        "id": event.id,
        "type": entry_type,
        "content": content,
        "source": source,
        "relevance": null,
        "timestamp": event.timestamp,
        "sessionId": event.session_id,
    })
}
