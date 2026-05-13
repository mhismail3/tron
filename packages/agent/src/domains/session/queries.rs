//! Shared query-side services for session capabilities.

use serde_json::{Value, json};

use crate::domains::session::Deps;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::{self, CapabilityError};

pub(crate) struct SessionQueryService;

impl SessionQueryService {
    pub(crate) async fn resume(deps: &Deps, session_id: String) -> Result<Value, CapabilityError> {
        let session_manager = deps.session_manager.clone();
        let session_id_for_resume = session_id.clone();
        run_blocking_task("session.resume", move || {
            let active = session_manager
                .resume_session(&session_id_for_resume)
                .map_err(|error| CapabilityError::NotFound {
                    code: errors::SESSION_NOT_FOUND.into(),
                    message: error.to_string(),
                })?;

            Ok(json!({
                "sessionId": session_id_for_resume,
                "model": active.state.model,
                "messageCount": active.state.messages.len(),
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
    ) -> Result<Value, CapabilityError> {
        let filter = crate::domains::agent::runner::SessionFilter {
            workspace_path: working_directory,
            include_archived,
            exclude_subagents: true,
            user_only: true,
            limit,
            offset,
            ..Default::default()
        };
        let session_manager = deps.session_manager.clone();
        let event_store = deps.event_store.clone();
        let orchestrator = deps.orchestrator.clone();
        run_blocking_task("session.list", move || {
            let sessions =
                session_manager
                    .list_sessions(&filter)
                    .map_err(|error| CapabilityError::Internal {
                        message: error.to_string(),
                    })?;

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
                    let is_active = session_manager.is_active(&session.id);
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
                        "isActive": is_active,
                        "isRunning": is_running,
                        "isArchived": session.ended_at.is_some(),
                        "source": session.source,
                        "profile": session.profile,
                        "eventCount": session.event_count,
                        "messageCount": session.message_count,
                        "inputTokens": session.total_input_tokens,
                        "outputTokens": session.total_output_tokens,
                        "lastTurnInputTokens": session.last_turn_input_tokens,
                        "cacheReadTokens": session.total_cache_read_tokens,
                        "cacheCreationTokens": session.total_cache_creation_tokens,
                        "cost": session.total_cost,
                        "parentSessionId": session.parent_session_id,
                        "useWorktree": session.use_worktree,
                        "lastUserPrompt": preview.and_then(|p| p.last_user_prompt.as_deref()),
                        "lastAssistantResponse": preview.and_then(|p| p.last_assistant_response.as_deref()),
                        "activityLines": activity_summaries.get(&session.id).cloned().unwrap_or_default(),
                    })
                })
                .collect();

            Ok(json!({ "sessions": items }))
        })
        .await
    }

    pub(crate) async fn get_head(
        deps: &Deps,
        session_id: String,
    ) -> Result<Value, CapabilityError> {
        let session_manager = deps.session_manager.clone();
        let session_id_for_head = session_id.clone();
        run_blocking_task("session.get_head", move || {
            let session = session_manager
                .get_session(&session_id_for_head)
                .map_err(|error| CapabilityError::Internal {
                    message: error.to_string(),
                })?
                .ok_or_else(|| CapabilityError::NotFound {
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

    pub(crate) async fn get_state(
        deps: &Deps,
        session_id: String,
    ) -> Result<Value, CapabilityError> {
        let session_manager = deps.session_manager.clone();
        let event_store = deps.event_store.clone();
        let session_id_for_state = session_id.clone();
        run_blocking_task("session.get_state", move || {
            let session = session_manager
                .get_session(&session_id_for_state)
                .map_err(|error| CapabilityError::Internal {
                    message: error.to_string(),
                })?
                .ok_or_else(|| CapabilityError::NotFound {
                    code: errors::SESSION_NOT_FOUND.into(),
                    message: format!("Session '{session_id_for_state}' not found"),
                })?;

            let active = session_manager
                .resume_session(&session_id_for_state)
                .map_err(|error| CapabilityError::NotFound {
                    code: errors::SESSION_NOT_FOUND.into(),
                    message: error.to_string(),
                })?;

            let event_count = event_store.count_events(&session_id_for_state).unwrap_or(0);

            Ok(json!({
                "sessionId": session_id_for_state,
                "headEventId": session.head_event_id,
                "model": active.state.model,
                "turnCount": active.state.turn_count,
                "isEnded": active.state.is_ended,
                "workingDirectory": active.state.working_directory,
                "workspaceId": session.working_directory,
                "eventCount": event_count,
                "lastTurnInputTokens": session.last_turn_input_tokens,
                "tokenUsage": {
                    "inputTokens": active.state.token_usage.input_tokens,
                    "outputTokens": active.state.token_usage.output_tokens,
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
    pub(crate) async fn export(deps: &Deps, session_id: String) -> Result<Value, CapabilityError> {
        let session_manager = deps.session_manager.clone();
        let event_store = deps.event_store.clone();
        let session_id_for_export = session_id.clone();
        run_blocking_task("session.export", move || {
            let session = session_manager
                .get_session(&session_id_for_export)
                .map_err(|error| CapabilityError::Internal {
                    message: error.to_string(),
                })?
                .ok_or_else(|| CapabilityError::NotFound {
                    code: errors::SESSION_NOT_FOUND.into(),
                    message: format!("Session '{session_id_for_export}' not found"),
                })?;

            let opts = crate::domains::session::event_store::sqlite::repositories::event::ListEventsOptions::default();
            let events = event_store
                .get_events_by_session(&session_id_for_export, &opts)
                .map_err(|error| CapabilityError::Internal {
                    message: error.to_string(),
                })?;

            let event_count = events.len();
            let session_value = serde_json::to_value(&session).map_err(|error| CapabilityError::Internal {
                message: format!("session serialization failed: {error}"),
            })?;
            let events_value = serde_json::to_value(&events).map_err(|error| CapabilityError::Internal {
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

    pub(crate) async fn get_history(
        deps: &Deps,
        session_id: String,
        limit: Option<usize>,
        before_id: Option<String>,
    ) -> Result<Value, CapabilityError> {
        let session_manager = deps.session_manager.clone();
        let event_store = deps.event_store.clone();
        let session_id_for_history = session_id.clone();
        run_blocking_task("session.get_history", move || {
            let _ = session_manager
                .get_session(&session_id_for_history)
                .map_err(|error| CapabilityError::Internal {
                    message: error.to_string(),
                })?
                .ok_or_else(|| CapabilityError::NotFound {
                    code: errors::SESSION_NOT_FOUND.into(),
                    message: format!("Session '{session_id_for_history}' not found"),
                })?;

            let message_types = [
                "message.user",
                "message.assistant",
                "capability.invocation.completed",
            ];
            let type_strs: Vec<&str> = message_types.to_vec();
            let events = event_store
                .get_events_by_type(&session_id_for_history, &type_strs, None)
                .map_err(|error| CapabilityError::Internal {
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

            let messages: Vec<Value> = events
                .iter()
                .map(|event| {
                    let role = match event.event_type.as_str() {
                        "message.user" => "user",
                        "message.assistant" => "assistant",
                        "capability.invocation.completed" => "capability",
                        _ => "unknown",
                    };
                    let content =
                        serde_json::from_str::<Value>(&event.payload).unwrap_or_else(|error| {
                            tracing::warn!(
                                event_id = %event.id,
                                error = %error,
                                "corrupt event payload"
                            );
                            Value::Null
                        });

                    let mut message = json!({
                        "id": event.id,
                        "role": role,
                        "content": content,
                        "timestamp": event.timestamp,
                    });
                    if let Some(ref model_primitive_name) = event.model_primitive_name {
                        message["capabilityInvocation"] = json!({ "name": model_primitive_name });
                    }
                    if event.event_type == "capability.invocation.completed" {
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
            .create_session("m", "/tmp", Some("t"), None)
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
    /// import or replay capability relies on this; shuffling by insertion order
    /// or ID would be a silent correctness bug.
    #[tokio::test]
    async fn export_events_are_ordered_by_sequence_asc() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"), None)
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

    /// `exportedAt` is an RFC3339 timestamp. Downstream capabilities parse it
    /// as-is — if this regresses to a raw `SystemTime` or a broken format,
    /// import tooling silently breaks.
    #[tokio::test]
    async fn export_exportedat_is_rfc3339() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"), None)
            .unwrap();

        let result = SessionQueryService::export(&Deps::from_test_context(&ctx), sid)
            .await
            .unwrap();
        let ts = result["exportedAt"].as_str().unwrap();
        chrono::DateTime::parse_from_rfc3339(ts).unwrap_or_else(|e| {
            panic!("exportedAt not RFC3339: value='{ts}' err={e}");
        });
    }

    /// Export of a subagent session succeeds — unlike `archive_older_than`,
    /// export does not filter by `source` or `spawning_session_id`. The
    /// caller (iOS) is trusted to pass a real session ID. This test guards
    /// against a future "helpful" filter hiding a child session's data
    /// from the user.
    #[tokio::test]
    async fn export_of_subagent_session_succeeds() {
        let ctx = make_test_context();
        let parent = ctx
            .session_manager
            .create_session("m", "/tmp", Some("parent"), None)
            .unwrap();
        let subagent = ctx
            .session_manager
            .create_session_for_subagent("m", "/tmp", Some("sub"), &parent, "task", "desc")
            .unwrap();

        let result = SessionQueryService::export(&Deps::from_test_context(&ctx), subagent.clone())
            .await
            .unwrap();
        assert_eq!(result["session"]["id"].as_str().unwrap(), subagent);
    }

    #[tokio::test]
    async fn list_accepts_ios_dashboard_pagination_payload() {
        let ctx = make_test_context();
        let first = ctx
            .session_manager
            .create_session("m", "/tmp/a", Some("a"), None)
            .unwrap();
        let second = ctx
            .session_manager
            .create_session("m", "/tmp/b", Some("b"), None)
            .unwrap();

        let result = SessionQueryService::list(
            &Deps::from_test_context(&ctx),
            false,
            Some(1),
            None,
            Some(0),
        )
        .await
        .unwrap();
        let sessions = result["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 1);

        let filtered = SessionQueryService::list(
            &Deps::from_test_context(&ctx),
            false,
            None,
            Some("/tmp/a".to_string()),
            Some(0),
        )
        .await
        .unwrap();
        let sessions = filtered["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0]["sessionId"].as_str().unwrap(), first);
        assert_ne!(sessions[0]["sessionId"].as_str().unwrap(), second);
    }
}
