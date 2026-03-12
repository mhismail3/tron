//! Shared query-side services for session RPC handlers.

use serde_json::{Value, json};

use crate::rpc::context::RpcContext;
use crate::rpc::errors::{self, RpcError};

pub(crate) struct SessionQueryService;

impl SessionQueryService {
    pub(crate) async fn resume(ctx: &RpcContext, session_id: String) -> Result<Value, RpcError> {
        let session_manager = ctx.session_manager.clone();
        let session_id_for_resume = session_id.clone();
        ctx.run_blocking("session.resume", move || {
            let active = session_manager
                .resume_session(&session_id_for_resume)
                .map_err(|error| RpcError::NotFound {
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
        ctx: &RpcContext,
        include_archived: bool,
        limit: Option<usize>,
    ) -> Result<Value, RpcError> {
        let filter = tron_runtime::SessionFilter {
            include_archived,
            exclude_subagents: true,
            user_only: true,
            limit,
            ..Default::default()
        };
        let session_manager = ctx.session_manager.clone();
        let event_store = ctx.event_store.clone();
        ctx.run_blocking("session.list", move || {
            let sessions =
                session_manager
                    .list_sessions(&filter)
                    .map_err(|error| RpcError::Internal {
                        message: error.to_string(),
                    })?;

            let session_ids: Vec<&str> = sessions.iter().map(|session| session.id.as_str()).collect();
            let previews = event_store
                .get_session_message_previews(&session_ids)
                .unwrap_or_default();

            let items: Vec<Value> = sessions
                .into_iter()
                .map(|session| {
                    let is_active = session_manager.is_active(&session.id);
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
                        "isArchived": session.ended_at.is_some(),
                        "isChat": session.source.as_deref() == Some("chat"),
                        "source": session.source,
                        "eventCount": session.event_count,
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
                    })
                })
                .collect();

            Ok(json!({ "sessions": items }))
        })
        .await
    }

    pub(crate) async fn get_head(ctx: &RpcContext, session_id: String) -> Result<Value, RpcError> {
        let session_manager = ctx.session_manager.clone();
        let session_id_for_head = session_id.clone();
        ctx.run_blocking("session.get_head", move || {
            let session = session_manager
                .get_session(&session_id_for_head)
                .map_err(|error| RpcError::Internal {
                    message: error.to_string(),
                })?
                .ok_or_else(|| RpcError::NotFound {
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

    pub(crate) async fn get_state(ctx: &RpcContext, session_id: String) -> Result<Value, RpcError> {
        let session_manager = ctx.session_manager.clone();
        let event_store = ctx.event_store.clone();
        let session_id_for_state = session_id.clone();
        ctx.run_blocking("session.get_state", move || {
            let session = session_manager
                .get_session(&session_id_for_state)
                .map_err(|error| RpcError::Internal {
                    message: error.to_string(),
                })?
                .ok_or_else(|| RpcError::NotFound {
                    code: errors::SESSION_NOT_FOUND.into(),
                    message: format!("Session '{session_id_for_state}' not found"),
                })?;

            let active = session_manager
                .resume_session(&session_id_for_state)
                .map_err(|error| RpcError::NotFound {
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

    pub(crate) async fn get_history(
        ctx: &RpcContext,
        session_id: String,
        limit: Option<usize>,
        before_id: Option<String>,
    ) -> Result<Value, RpcError> {
        let session_manager = ctx.session_manager.clone();
        let event_store = ctx.event_store.clone();
        let session_id_for_history = session_id.clone();
        ctx.run_blocking("session.get_history", move || {
            let _ = session_manager
                .get_session(&session_id_for_history)
                .map_err(|error| RpcError::Internal {
                    message: error.to_string(),
                })?
                .ok_or_else(|| RpcError::NotFound {
                    code: errors::SESSION_NOT_FOUND.into(),
                    message: format!("Session '{session_id_for_history}' not found"),
                })?;

            let message_types = ["message.user", "message.assistant", "tool.result"];
            let type_strs: Vec<&str> = message_types.to_vec();
            let events = event_store
                .get_events_by_type(&session_id_for_history, &type_strs, None)
                .map_err(|error| RpcError::Internal {
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
                        "tool.result" => "tool",
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
                    if let Some(ref tool_name) = event.tool_name {
                        message["toolUse"] = json!({ "name": tool_name });
                    }
                    if event.event_type == "tool.result" {
                        if let Some(tool_call_id) = content.get("toolCallId") {
                            message["toolCallId"] = tool_call_id.clone();
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
