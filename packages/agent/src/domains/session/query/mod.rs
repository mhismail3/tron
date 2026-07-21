//! Shared query-side services for session read tools.
//!
//! `session::list` clamps every page to 200 rows and returns an opaque cursor
//! over immutable creation/session-ID keys beneath one server-issued
//! `snapshotAsOf` boundary. Mutable activity cannot move a row between pages,
//! and clients can assemble a generous bounded snapshot without one unbounded
//! database read. Row lookups and bounded listing read `EventStore` directly;
//! within this query path, `SessionManager` remains only for resume/cache data.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::domains::session::Deps;
use crate::domains::session::event_store::ListSessionsOptions;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::{self, ToolError};

pub(crate) struct SessionQueryService;

const SESSION_LIST_DEFAULT_LIMIT: usize = 50;
const SESSION_LIST_MAX_LIMIT: usize = 200;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SessionListCursor {
    version: u8,
    snapshot_as_of: String,
    before_created_at: String,
    before_session_id: String,
    include_archived: bool,
    working_directory: Option<String>,
}

mod operations;

pub(crate) use operations::{
    session_export_value, session_get_head_value, session_get_history_value,
    session_get_state_value, session_list_value, session_replay_manifest_value,
    session_resume_value,
};

impl SessionQueryService {
    pub(crate) async fn resume(deps: &Deps, session_id: String) -> Result<Value, ToolError> {
        let session_manager = deps.session_manager.clone();
        let session_id_for_resume = session_id.clone();
        run_blocking_task("session.resume", move || {
            let state = session_manager
                .resume_session(&session_id_for_resume)
                .map_err(|error| ToolError::NotFound {
                    code: errors::SESSION_NOT_FOUND.into(),
                    message: error.to_string(),
                })?;

            Ok(json!({
                "sessionId": session_id_for_resume,
                "model": state.model,
                "messageCount": state.messages.len(),
                "lastActivity": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
            }))
        })
        .await
    }

    pub(crate) async fn list(
        deps: &Deps,
        include_archived: bool,
        limit: Option<usize>,
        working_directory: Option<String>,
        offset: Option<usize>,
        cursor: Option<SessionListCursor>,
    ) -> Result<Value, ToolError> {
        let limit = limit
            .unwrap_or(SESSION_LIST_DEFAULT_LIMIT)
            .clamp(1, SESSION_LIST_MAX_LIMIT);
        let fetch_limit = limit.saturating_add(1);
        let snapshot_as_of = cursor.as_ref().map_or_else(
            || chrono::Utc::now().to_rfc3339(),
            |cursor| cursor.snapshot_as_of.clone(),
        );
        let before_created_at = cursor
            .as_ref()
            .map(|cursor| cursor.before_created_at.clone());
        let before_session_id = cursor
            .as_ref()
            .map(|cursor| cursor.before_session_id.clone());
        let session_manager = deps.session_manager.clone();
        let event_store = deps.event_store.clone();
        let orchestrator = deps.orchestrator.clone();
        run_blocking_task("session.list", move || {
            let options = ListSessionsOptions {
                workspace_id: None,
                working_directory: working_directory.as_deref(),
                ended: if include_archived {
                    None
                } else {
                    Some(false)
                },
                #[allow(clippy::cast_possible_wrap)]
                limit: Some(fetch_limit as i64),
                #[allow(clippy::cast_possible_wrap)]
                offset: offset.map(|value| value as i64),
                snapshot_created_at: Some(&snapshot_as_of),
                before_created_at: before_created_at.as_deref(),
                before_session_id: before_session_id.as_deref(),
            };
            let mut sessions = event_store.list_sessions(&options).map_err(|error| {
                ToolError::Internal {
                    message: format!("Persistence error: {error}"),
                }
            })?;

            let has_more = sessions.len() > limit;
            sessions.truncate(limit);
            let next_cursor = if has_more {
                sessions.last().map(|session| {
                    serde_json::to_string(&SessionListCursor {
                        version: 1,
                        snapshot_as_of: snapshot_as_of.clone(),
                        before_created_at: session.created_at.clone(),
                        before_session_id: session.id.clone(),
                        include_archived,
                        working_directory: working_directory.clone(),
                    })
                    .expect("session list cursor serialization cannot fail")
                })
            } else {
                None
            };

            let session_ids: Vec<&str> = sessions.iter().map(|session| session.id.as_str()).collect();
            let previews = event_store
                .get_session_message_previews(&session_ids)
                .unwrap_or_default();

            let activity_summaries = event_store
                .get_session_activity_summaries_batch(&session_ids)
                .unwrap_or_default();

            let items: Vec<Value> = sessions
                .into_iter()
                .map(|session| {
                    let is_cached = session_manager.is_cached(&session.id);
                    let is_running = orchestrator.has_active_run(&session.id);
                    let preview = previews.get(&session.id);
                    json!({
                        "sessionId": session.id,
                        "model": session.latest_model,
                        "title": session.title,
                        "workingDirectory": session.working_directory,
                        "createdAt": session.created_at,
                        "lastActivity": session.last_activity_at,
                        "endedAt": session.ended_at,
                        // `isActive` reports session-cache residency.
                        "isActive": is_cached,
                        "isRunning": is_running,
                        "isArchived": session.ended_at.is_some(),
                        "eventCount": session.event_count,
                        "turnCount": session.turn_count,
                        "messageCount": session.message_count,
                        "inputTokens": session.total_input_tokens,
                        "outputTokens": session.total_output_tokens,
                        "lastTurnInputTokens": session.last_turn_input_tokens,
                        "cacheReadTokens": session.total_cache_read_tokens,
                        "cacheCreationTokens": session.total_cache_creation_tokens,
                        "cost": session.total_cost,
                        "parentSessionId": session.parent_session_id,
                        "lastUserPrompt": preview.and_then(|p| p.last_user_prompt.as_deref()),
                        "lastAssistantResponse": preview.and_then(|p| p.last_assistant_response.as_deref()),
                        "activityLines": activity_summaries.get(&session.id).cloned().unwrap_or_default(),
                    })
                })
                .collect();

            Ok(json!({
                "sessions": items,
                "hasMore": has_more,
                "nextCursor": next_cursor,
                "snapshotAsOf": snapshot_as_of,
                "snapshotCanReconcile": include_archived && working_directory.is_none() && offset.is_none(),
            }))
        })
        .await
    }

    pub(crate) async fn get_head(deps: &Deps, session_id: String) -> Result<Value, ToolError> {
        let event_store = deps.event_store.clone();
        let session_id_for_head = session_id.clone();
        run_blocking_task("session.get_head", move || {
            let session = event_store
                .get_session(&session_id_for_head)
                .map_err(|error| ToolError::Internal {
                    message: format!("Persistence error: {error}"),
                })?
                .ok_or_else(|| ToolError::NotFound {
                    code: errors::SESSION_NOT_FOUND.into(),
                    message: format!("Session '{session_id_for_head}' not found"),
                })?;

            Ok(json!({
                "sessionId": session.id,
                "headEventId": session.head_event_id,
            }))
        })
        .await
    }

    pub(crate) async fn get_state(deps: &Deps, session_id: String) -> Result<Value, ToolError> {
        let session_manager = deps.session_manager.clone();
        let event_store = deps.event_store.clone();
        let session_id_for_state = session_id.clone();
        run_blocking_task("session.get_state", move || {
            let session = event_store
                .get_session(&session_id_for_state)
                .map_err(|error| ToolError::Internal {
                    message: format!("Persistence error: {error}"),
                })?
                .ok_or_else(|| ToolError::NotFound {
                    code: errors::SESSION_NOT_FOUND.into(),
                    message: format!("Session '{session_id_for_state}' not found"),
                })?;

            let state = session_manager
                .resume_session(&session_id_for_state)
                .map_err(|error| ToolError::NotFound {
                    code: errors::SESSION_NOT_FOUND.into(),
                    message: error.to_string(),
                })?;

            let event_count = event_store.count_events(&session_id_for_state).unwrap_or(0);

            Ok(json!({
                "sessionId": session_id_for_state,
                "headEventId": session.head_event_id,
                "model": state.model,
                "turnCount": state.turn_count,
                "isEnded": state.is_ended,
                "workingDirectory": state.working_directory,
                "workspaceId": session.working_directory,
                "eventCount": event_count,
                "lastTurnInputTokens": session.last_turn_input_tokens,
                "tokenUsage": {
                    "inputTokens": state.token_usage.input_tokens,
                    "outputTokens": state.token_usage.output_tokens,
                    "cacheReadTokens": session.total_cache_read_tokens,
                    "cacheCreationTokens": session.total_cache_creation_tokens,
                },
            }))
        })
        .await
    }

    /// Full session dump for backup / inspection / offline analysis.
    ///
    /// Returns the `sessions` row and every `events` row belonging to the
    /// session, ordered by sequence ascending, under a stable
    /// `format: "tron.session.v1"` envelope. Blob references in events stay
    /// as-is — callers resolve them via `blob.get`. The format version is
    /// the schema contract: additions are additive, removals bump the version.
    ///
    /// This is a single round-trip snapshot with no pagination. For
    /// sessions larger than ~50k events the export is large but not
    /// unbounded — the payload is serialized in memory before being
    /// returned, which matches how `session.reconstruct` already behaves.
    pub(crate) async fn export(deps: &Deps, session_id: String) -> Result<Value, ToolError> {
        let event_store = deps.event_store.clone();
        let session_id_for_export = session_id.clone();
        run_blocking_task("session.export", move || {
            let session = event_store
                .get_session(&session_id_for_export)
                .map_err(|error| ToolError::Internal {
                    message: format!("Persistence error: {error}"),
                })?
                .ok_or_else(|| ToolError::NotFound {
                    code: errors::SESSION_NOT_FOUND.into(),
                    message: format!("Session '{session_id_for_export}' not found"),
                })?;

            let opts = crate::domains::session::event_store::ListEventsOptions::default();
            let events = event_store
                .get_events_by_session(&session_id_for_export, &opts)
                .map_err(|error| ToolError::Internal {
                    message: error.to_string(),
                })?;

            let event_count = events.len();
            let session_value = serde_json::to_value(&session).map_err(|error| ToolError::Internal {
                message: format!("session serialization failed: {error}"),
            })?;
            let events_value = serde_json::to_value(&events).map_err(|error| ToolError::Internal {
                message: format!("events serialization failed: {error}"),
            })?;

            Ok(json!({
                "format": "tron.session.v1",
                "exportedAt": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
                "session": session_value,
                "events": events_value,
                "eventCount": event_count,
            }))
        })
        .await
    }

    /// Canonical deterministic replay manifest for audit/reconstruction.
    pub(crate) async fn replay_manifest(
        deps: &Deps,
        session_id: String,
    ) -> Result<Value, ToolError> {
        crate::domains::session::replay::replay_manifest_value(
            crate::domains::session::replay::ReplayDeps::new(
                deps.event_store.clone(),
                deps.engine_host.clone(),
            ),
            session_id,
        )
        .await
    }

    pub(crate) async fn get_history(
        deps: &Deps,
        session_id: String,
        limit: Option<usize>,
        before_id: Option<String>,
    ) -> Result<Value, ToolError> {
        let event_store = deps.event_store.clone();
        let session_id_for_history = session_id.clone();
        run_blocking_task("session.get_history", move || {
            let _ = event_store
                .get_session(&session_id_for_history)
                .map_err(|error| ToolError::Internal {
                    message: format!("Persistence error: {error}"),
                })?
                .ok_or_else(|| ToolError::NotFound {
                    code: errors::SESSION_NOT_FOUND.into(),
                    message: format!("Session '{session_id_for_history}' not found"),
                })?;

            let message_types = [
                "message.user",
                "message.assistant",
                "tool.invocation.completed",
            ];
            let type_strs: Vec<&str> = message_types.to_vec();
            let events = event_store
                .get_events_by_type(&session_id_for_history, &type_strs, None)
                .map_err(|error| ToolError::Internal {
                    message: error.to_string(),
                })?;

            let events = if let Some(before_id) = before_id {
                events
                    .into_iter()
                    .take_while(|event| event.id != before_id)
                    .collect::<Vec<_>>()
            } else {
                events
            };

            let has_more = limit.is_some_and(|value| events.len() > value);
            let events = if let Some(limit) = limit {
                events.into_iter().take(limit).collect::<Vec<_>>()
            } else {
                events
            };

            let resolved_payloads =
                event_store
                    .resolve_event_payloads(&events)
                    .map_err(|error| ToolError::Internal {
                        message: format!("Failed to resolve event payloads: {error}"),
                    })?;

            let messages: Vec<Value> = events
                .iter()
                .zip(resolved_payloads)
                .map(|(event, content)| {
                    let role = match event.event_type.as_str() {
                        "message.user" => "user",
                        "message.assistant" => "assistant",
                        "tool.invocation.completed" => "tool",
                        _ => "unknown",
                    };
                    let mut message = json!({
                        "id": event.id,
                        "role": role,
                        "content": content,
                        "timestamp": event.timestamp,
                    });
                    if let Some(ref tool_name) = event.tool_name {
                        message["toolInvocation"] = json!({ "name": tool_name });
                    }
                    if event.event_type == "tool.invocation.completed" {
                        if let Some(invocation_id) = content.get("invocationId") {
                            message["invocationId"] = invocation_id.clone();
                        }
                        if let Some(is_error) = content.get("isError") {
                            message["isError"] = is_error.clone();
                        }
                    }
                    message
                })
                .collect();

            Ok(json!({
                "messages": messages,
                "hasMore": has_more,
            }))
        })
        .await
    }
}

#[cfg(test)]
mod tests {
    //! Query-service unit tests. Handler-level coverage lives in
    //! `handlers/session_tests.rs`; here we exercise the service methods
    //! directly so invariants like "events ordered by sequence" and
    //! "format: tron.session.v1" aren't tied to the handler wire-up.

    use super::*;
    use crate::domains::session::event_store::{AppendOptions, EventType};
    use crate::shared::server::test_support::make_test_context;

    /// A freshly-created session always has exactly one event — the
    /// `session.start` event inserted inside the create transaction.
    /// Export includes it, so the minimum payload is `eventCount: 1`.
    /// If this ever regresses to 0 (or 2+), something has changed about
    /// session creation and the export contract needs to be re-verified.
    #[tokio::test]
    async fn export_of_fresh_session_returns_session_start_event() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let result = SessionQueryService::export(&Deps::from_test_context(&ctx), sid.clone())
            .await
            .unwrap();

        assert_eq!(result["format"].as_str().unwrap(), "tron.session.v1");
        assert_eq!(result["eventCount"].as_u64().unwrap(), 1);
        let events = result["events"].as_array().unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["type"].as_str().unwrap(), "session.start");
        assert_eq!(events[0]["sequence"].as_i64().unwrap(), 0);
        assert_eq!(result["session"]["id"].as_str().unwrap(), sid);
    }

    /// Missing session → NotFound with SESSION_NOT_FOUND code. Downstream
    /// iOS maps this to "session was deleted" rather than a retry loop.
    #[tokio::test]
    async fn export_of_nonexistent_session_is_not_found() {
        let ctx = make_test_context();
        let err = SessionQueryService::export(
            &Deps::from_test_context(&ctx),
            "sess_does_not_exist".to_string(),
        )
        .await
        .unwrap_err();
        assert_eq!(err.code(), "SESSION_NOT_FOUND");
    }

    /// Events in the export are ordered by sequence ASC. A downstream
    /// import or replay tool relies on this; shuffling by insertion order
    /// or ID would be a silent correctness bug.
    #[tokio::test]
    async fn export_events_are_ordered_by_sequence_asc() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        // Append three user messages. Sequence auto-increments starting
        // from 1 (the create transaction already claimed 0 for session.start).
        for i in 0..3 {
            ctx.event_store
                .append(&AppendOptions {
                    session_id: &sid,
                    event_type: EventType::MessageUser,
                    payload: serde_json::json!({ "content": format!("msg-{i}"), "turn": i }),
                    parent_id: None,
                    sequence: None,
                })
                .unwrap();
        }

        let result = SessionQueryService::export(&Deps::from_test_context(&ctx), sid)
            .await
            .unwrap();

        let events = result["events"].as_array().unwrap();
        // session.start (seq 0) + 3 user messages (seq 1..=3) = 4.
        assert_eq!(events.len(), 4);
        let seqs: Vec<i64> = events
            .iter()
            .map(|e| e["sequence"].as_i64().unwrap())
            .collect();
        let mut sorted = seqs.clone();
        sorted.sort_unstable();
        assert_eq!(
            seqs, sorted,
            "export events must be sequence-ASC — export was {seqs:?}"
        );
        assert_eq!(seqs, vec![0, 1, 2, 3]);
        assert_eq!(result["eventCount"].as_u64().unwrap(), 4);
    }

    /// `exportedAt` is an RFC3339 timestamp. Downstream tools parse it
    /// as-is — if this regresses to a raw `SystemTime` or a broken format,
    /// import tooling silently breaks.
    #[tokio::test]
    async fn export_exportedat_is_rfc3339() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let result = SessionQueryService::export(&Deps::from_test_context(&ctx), sid)
            .await
            .unwrap();
        let ts = result["exportedAt"].as_str().unwrap();
        chrono::DateTime::parse_from_rfc3339(ts).unwrap_or_else(|e| {
            panic!("exportedAt not RFC3339: value='{ts}' err={e}");
        });
    }

    #[tokio::test]
    async fn list_accepts_ios_session_pagination_payload() {
        let ctx = make_test_context();
        let first = ctx
            .session_manager
            .create_session("m", "/tmp/a", Some("a"))
            .unwrap();
        let second = ctx
            .session_manager
            .create_session("m", "/tmp/b", Some("b"))
            .unwrap();

        let result = SessionQueryService::list(
            &Deps::from_test_context(&ctx),
            false,
            Some(1),
            None,
            Some(0),
            None,
        )
        .await
        .unwrap();
        let sessions = result["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(result["hasMore"].as_bool(), Some(true));
        assert_eq!(result["snapshotCanReconcile"].as_bool(), Some(false));
        let snapshot_as_of = result["snapshotAsOf"].as_str().unwrap().to_owned();
        let cursor: SessionListCursor =
            serde_json::from_str(result["nextCursor"].as_str().unwrap()).unwrap();

        let next = SessionQueryService::list(
            &Deps::from_test_context(&ctx),
            false,
            Some(1),
            None,
            None,
            Some(cursor),
        )
        .await
        .unwrap();
        let next_sessions = next["sessions"].as_array().unwrap();
        assert_eq!(next_sessions.len(), 1);
        assert_ne!(
            sessions[0]["sessionId"].as_str(),
            next_sessions[0]["sessionId"].as_str()
        );
        assert_eq!(next["hasMore"].as_bool(), Some(false));
        assert_eq!(next["snapshotAsOf"].as_str(), Some(snapshot_as_of.as_str()));

        let filtered = SessionQueryService::list(
            &Deps::from_test_context(&ctx),
            false,
            None,
            Some("/tmp/a".to_string()),
            Some(0),
            None,
        )
        .await
        .unwrap();
        let sessions = filtered["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0]["sessionId"].as_str().unwrap(), first);
        assert_ne!(sessions[0]["sessionId"].as_str().unwrap(), second);
    }

    #[tokio::test]
    async fn list_rejects_mixed_cursor_and_offset_pagination() {
        let ctx = make_test_context();
        let cursor = serde_json::to_string(&SessionListCursor {
            version: 1,
            snapshot_as_of: "2026-07-01T12:00:01Z".into(),
            before_created_at: "2026-07-01T12:00:00Z".into(),
            before_session_id: "sess_cursor".into(),
            include_archived: false,
            working_directory: None,
        })
        .unwrap();
        let params = json!({
            "limit": 20,
            "offset": 0,
            "cursor": cursor,
        });

        let error = session_list_value(Some(&params), &Deps::from_test_context(&ctx))
            .await
            .unwrap_err();
        assert!(matches!(error, ToolError::InvalidParams { .. }));
    }

    #[tokio::test]
    async fn list_rejects_reusing_a_cursor_with_different_filters() {
        let ctx = make_test_context();
        let cursor = serde_json::to_string(&SessionListCursor {
            version: 1,
            snapshot_as_of: "2026-07-01T12:00:01Z".into(),
            before_created_at: "2026-07-01T12:00:00Z".into(),
            before_session_id: "sess_cursor".into(),
            include_archived: true,
            working_directory: None,
        })
        .unwrap();

        let error = session_list_value(
            Some(&json!({
                "cursor": cursor,
                "includeArchived": false,
                "limit": 20
            })),
            &Deps::from_test_context(&ctx),
        )
        .await
        .unwrap_err();
        assert!(matches!(error, ToolError::InvalidParams { .. }));
    }
}
