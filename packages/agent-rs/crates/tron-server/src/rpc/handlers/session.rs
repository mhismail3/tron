//! Session handlers: create, resume, list, delete, fork, getHead, getState, getHistory.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;
use tron_core::events::{BaseEvent, TronEvent};
use tron_runtime::agent::event_emitter::EventEmitter;

use crate::rpc::context::RpcContext;
use crate::rpc::errors::{self, RpcError};
use crate::rpc::handlers::require_string_param;
use crate::rpc::handlers::session_context::{RuleFileLevel, load_session_context_artifacts};
use crate::rpc::registry::MethodHandler;

/// Create a new session.
pub struct CreateSessionHandler;

#[async_trait]
impl MethodHandler for CreateSessionHandler {
    #[instrument(skip(self, ctx), fields(method = "session.create"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let working_dir = require_string_param(params.as_ref(), "workingDirectory")?;
        let model = params
            .as_ref()
            .and_then(|p| p.get("model"))
            .and_then(|v| v.as_str())
            .unwrap_or("claude-sonnet-4-20250514");
        let title = params
            .as_ref()
            .and_then(|p| p.get("title"))
            .and_then(|v| v.as_str());

        let session_id = ctx
            .session_manager
            .create_session(model, &working_dir, title)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?;

        let _ = ctx
            .orchestrator
            .broadcast()
            .emit(TronEvent::SessionCreated {
                base: BaseEvent::now(&session_id),
                model: model.to_string(),
                working_directory: working_dir.clone(),
            });

        // Optimistically discover rules and memory so iOS can display pills
        // immediately when a session opens (content is loaded later at prompt time).
        let event_store = ctx.event_store.clone();
        let broadcast = ctx.orchestrator.broadcast().clone();
        let session_id_for_task = session_id.clone();
        let working_dir_for_task = working_dir.clone();
        let join = tokio::task::spawn_blocking(move || {
            emit_optimistic_context_events(
                &event_store,
                &broadcast,
                &session_id_for_task,
                &working_dir_for_task,
            );
        })
        .await;
        if let Err(e) = join {
            tracing::warn!(error = %e, "optimistic context preload task panicked");
        }

        Ok(serde_json::json!({
            "sessionId": session_id,
            "model": model,
            "workingDirectory": working_dir,
            "createdAt": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
            "isActive": true,
            "isArchived": false,
            "messageCount": 0,
            "eventCount": 1,
            "inputTokens": 0,
            "outputTokens": 0,
            "cost": 0.0,
        }))
    }
}

/// Discover rules files and memory, then persist + broadcast notification events.
///
/// This runs at session.create time so iOS can show "Loaded N rules" / "Loaded memory"
/// pills immediately. The actual content is loaded later when the first prompt is sent.
fn emit_optimistic_context_events(
    event_store: &std::sync::Arc<tron_events::EventStore>,
    broadcast: &std::sync::Arc<EventEmitter>,
    session_id: &str,
    working_dir: &str,
) {
    let settings = tron_settings::get_settings();
    let artifacts = load_session_context_artifacts(event_store.as_ref(), working_dir, settings);

    let files_json: Vec<serde_json::Value> = artifacts
        .rules
        .files
        .iter()
        .map(|file| {
            let depth = if file.level == RuleFileLevel::Global {
                0
            } else {
                file.depth
            };
            serde_json::json!({
                "path": file.path.to_string_lossy(),
                "relativePath": file.relative_path,
                "level": file.level.as_str(),
                "depth": depth,
                "sizeBytes": file.size_bytes,
            })
        })
        .collect();

    if !files_json.is_empty() {
        #[allow(clippy::cast_possible_truncation)]
        let total = files_json.len() as u32;
        let merged_tokens = artifacts.rules.merged_tokens_estimate();
        let _ = event_store.append(&tron_events::AppendOptions {
            session_id,
            event_type: tron_events::EventType::RulesLoaded,
            payload: serde_json::json!({
                "files": files_json,
                "totalFiles": total,
                "mergedTokens": merged_tokens,
                "dynamicRulesCount": 0,
            }),
            parent_id: None,
        });
        let _ = broadcast.emit(TronEvent::RulesLoaded {
            base: BaseEvent::now(session_id),
            total_files: total,
            dynamic_rules_count: 0,
        });
    }

    if let Some(memory) = artifacts.memory {
        #[allow(clippy::cast_possible_truncation)]
        let count = memory.raw_event_count as u32;

        let _ = event_store.append(&tron_events::AppendOptions {
            session_id,
            event_type: tron_events::EventType::MemoryLoaded,
            payload: serde_json::json!({
                "count": count,
                "tokens": memory.raw_payload_tokens,
                "workspaceId": memory.workspace_id,
            }),
            parent_id: None,
        });
        let _ = broadcast.emit(TronEvent::MemoryLoaded {
            base: BaseEvent::now(session_id),
            count,
        });
    }
}

/// Resume an existing session.
pub struct ResumeSessionHandler;

#[async_trait]
impl MethodHandler for ResumeSessionHandler {
    #[instrument(skip(self, ctx), fields(method = "session.resume", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        let active = ctx
            .session_manager
            .resume_session(&session_id)
            .map_err(|e| RpcError::NotFound {
                code: errors::SESSION_NOT_FOUND.into(),
                message: e.to_string(),
            })?;

        let message_count = active.state.messages.len();
        let last_activity = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true);

        Ok(serde_json::json!({
            "sessionId": session_id,
            "model": active.state.model,
            "messageCount": message_count,
            "lastActivity": last_activity,
        }))
    }
}

/// List sessions with optional filters.
pub struct ListSessionsHandler;

#[async_trait]
impl MethodHandler for ListSessionsHandler {
    #[instrument(skip(self, ctx), fields(method = "session.list"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let include_archived = params
            .as_ref()
            .and_then(|p| p.get("includeArchived"))
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false);

        #[allow(clippy::cast_possible_truncation)]
        let limit = params
            .as_ref()
            .and_then(|p| p.get("limit"))
            .and_then(serde_json::Value::as_u64)
            .map(|v| v as usize);

        let filter = tron_runtime::SessionFilter {
            include_archived,
            exclude_subagents: true,
            limit,
            ..Default::default()
        };

        let sessions =
            ctx.session_manager
                .list_sessions(&filter)
                .map_err(|e| RpcError::Internal {
                    message: e.to_string(),
                })?;

        // Get message previews for all sessions
        let session_ids: Vec<&str> = sessions.iter().map(|s| s.id.as_str()).collect();
        let previews = ctx
            .event_store
            .get_session_message_previews(&session_ids)
            .unwrap_or_default();

        let items: Vec<Value> = sessions
            .into_iter()
            .map(|s| {
                let is_active = ctx.session_manager.is_active(&s.id);
                let preview = previews.get(&s.id);
                serde_json::json!({
                    "sessionId": s.id,
                    "model": s.latest_model,
                    "title": s.title,
                    "workingDirectory": s.working_directory,
                    "createdAt": s.created_at,
                    "lastActivity": s.last_activity_at,
                    "endedAt": s.ended_at,
                    "isActive": is_active,
                    "isArchived": s.ended_at.is_some(),
                    "eventCount": s.event_count,
                    "messageCount": s.message_count,
                    "inputTokens": s.total_input_tokens,
                    "outputTokens": s.total_output_tokens,
                    "lastTurnInputTokens": s.last_turn_input_tokens,
                    "cacheReadTokens": s.total_cache_read_tokens,
                    "cacheCreationTokens": s.total_cache_creation_tokens,
                    "cost": 0.0,
                    "parentSessionId": s.parent_session_id,
                    "lastUserPrompt": preview.and_then(|p| p.last_user_prompt.as_deref()),
                    "lastAssistantResponse": preview.and_then(|p| p.last_assistant_response.as_deref()),
                })
            })
            .collect();

        Ok(serde_json::json!({ "sessions": items }))
    }
}

/// Delete a session.
pub struct DeleteSessionHandler;

#[async_trait]
impl MethodHandler for DeleteSessionHandler {
    #[instrument(skip(self, ctx), fields(method = "session.delete", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        ctx.session_manager
            .delete_session(&session_id)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?;

        let _ = ctx
            .orchestrator
            .broadcast()
            .emit(TronEvent::SessionDeleted {
                base: BaseEvent::now(&session_id),
            });

        Ok(serde_json::json!({ "deleted": true }))
    }
}

/// Fork a session at the current head (or a specific event).
pub struct ForkSessionHandler;

#[async_trait]
impl MethodHandler for ForkSessionHandler {
    #[instrument(skip(self, ctx), fields(method = "session.fork", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let title = params
            .as_ref()
            .and_then(|p| p.get("title"))
            .and_then(|v| v.as_str());

        let fork_result = ctx
            .session_manager
            .fork_session(&session_id, None, title)
            .map_err(|e| RpcError::NotFound {
                code: errors::SESSION_NOT_FOUND.into(),
                message: e.to_string(),
            })?;

        let _ = ctx.orchestrator.broadcast().emit(TronEvent::SessionForked {
            base: BaseEvent::now(&session_id),
            new_session_id: fork_result.new_session_id.clone(),
        });

        Ok(serde_json::json!({
            "newSessionId": fork_result.new_session_id,
            "forkedFromSessionId": session_id,
            "forkedFromEventId": fork_result.forked_from_event_id,
            "rootEventId": fork_result.root_event_id,
        }))
    }
}

/// Get the head event ID for a session.
pub struct GetHeadHandler;

#[async_trait]
impl MethodHandler for GetHeadHandler {
    #[instrument(skip(self, ctx), fields(method = "session.getHead", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        let session = ctx
            .session_manager
            .get_session(&session_id)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?
            .ok_or_else(|| RpcError::NotFound {
                code: errors::SESSION_NOT_FOUND.into(),
                message: format!("Session '{session_id}' not found"),
            })?;

        Ok(serde_json::json!({
            "sessionId": session.id,
            "headEventId": session.head_event_id,
        }))
    }
}

/// Get reconstructed state for a session.
pub struct GetStateHandler;

#[async_trait]
impl MethodHandler for GetStateHandler {
    #[instrument(skip(self, ctx), fields(method = "session.getState", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        // Get session row for metadata
        let session = ctx
            .session_manager
            .get_session(&session_id)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?
            .ok_or_else(|| RpcError::NotFound {
                code: errors::SESSION_NOT_FOUND.into(),
                message: format!("Session '{session_id}' not found"),
            })?;

        let active = ctx
            .session_manager
            .resume_session(&session_id)
            .map_err(|e| RpcError::NotFound {
                code: errors::SESSION_NOT_FOUND.into(),
                message: e.to_string(),
            })?;

        let event_count = ctx.event_store.count_events(&session_id).unwrap_or(0);

        Ok(serde_json::json!({
            "sessionId": session_id,
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
    }
}

/// Archive a session.
pub struct ArchiveSessionHandler;

#[async_trait]
impl MethodHandler for ArchiveSessionHandler {
    #[instrument(skip(self, ctx), fields(method = "session.archive", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        ctx.session_manager
            .archive_session(&session_id)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?;

        let _ = ctx
            .orchestrator
            .broadcast()
            .emit(TronEvent::SessionArchived {
                base: BaseEvent::now(&session_id),
            });

        Ok(serde_json::json!({ "archived": true }))
    }
}

/// Get conversation history for a session (reconstructed messages).
pub struct GetHistoryHandler;

#[async_trait]
impl MethodHandler for GetHistoryHandler {
    #[instrument(skip(self, ctx), fields(method = "session.getHistory", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        #[allow(clippy::cast_possible_truncation)]
        let limit = params
            .as_ref()
            .and_then(|p| p.get("limit"))
            .and_then(serde_json::Value::as_u64)
            .map(|v| v as usize);

        let before_id = params
            .as_ref()
            .and_then(|p| p.get("beforeId"))
            .and_then(serde_json::Value::as_str);

        // Verify session exists
        let _ = ctx
            .session_manager
            .get_session(&session_id)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?
            .ok_or_else(|| RpcError::NotFound {
                code: errors::SESSION_NOT_FOUND.into(),
                message: format!("Session '{session_id}' not found"),
            })?;

        // Get message-type events.
        // Tool calls are embedded as tool_use content blocks inside message.assistant events.
        // Tool results are persisted as "tool.result" events (NOT "message.tool_result").
        let message_types = ["message.user", "message.assistant", "tool.result"];
        let type_strs: Vec<&str> = message_types.to_vec();
        let events = ctx
            .event_store
            .get_events_by_type(&session_id, &type_strs, None)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?;

        // Apply beforeId pagination
        let events = if let Some(bid) = before_id {
            events
                .into_iter()
                .take_while(|e| e.id != bid)
                .collect::<Vec<_>>()
        } else {
            events
        };

        // Apply limit and determine hasMore
        let has_more = limit.is_some_and(|l| events.len() > l);
        let events = if let Some(l) = limit {
            events.into_iter().take(l).collect::<Vec<_>>()
        } else {
            events
        };

        // Convert to message shape
        let messages: Vec<Value> = events
            .iter()
            .map(|e| {
                let role = match e.event_type.as_str() {
                    "message.user" => "user",
                    "message.assistant" => "assistant",
                    "tool.result" => "tool",
                    _ => "unknown",
                };
                let content = serde_json::from_str::<Value>(&e.payload).unwrap_or(Value::Null);

                let mut msg = serde_json::json!({
                    "id": e.id,
                    "role": role,
                    "content": content,
                    "timestamp": e.timestamp,
                });
                if let Some(ref tool_name) = e.tool_name {
                    msg["toolUse"] = serde_json::json!({ "name": tool_name });
                }
                // Hoist toolCallId and isError from content to message level
                // for tool.result messages (iOS expects them at top level)
                if e.event_type == "tool.result" {
                    if let Some(tc_id) = content.get("toolCallId") {
                        msg["toolCallId"] = tc_id.clone();
                    }
                    if let Some(is_err) = content.get("isError") {
                        msg["isError"] = is_err.clone();
                    }
                }
                msg
            })
            .collect();

        Ok(serde_json::json!({
            "messages": messages,
            "hasMore": has_more,
        }))
    }
}

/// Unarchive a session.
pub struct UnarchiveSessionHandler;

#[async_trait]
impl MethodHandler for UnarchiveSessionHandler {
    #[instrument(skip(self, ctx), fields(method = "session.unarchive", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        ctx.session_manager
            .unarchive_session(&session_id)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?;

        let _ = ctx
            .orchestrator
            .broadcast()
            .emit(TronEvent::SessionUnarchived {
                base: BaseEvent::now(&session_id),
            });

        Ok(serde_json::json!({ "unarchived": true }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn create_session_success() {
        let ctx = make_test_context();
        let result = CreateSessionHandler
            .handle(Some(json!({"workingDirectory": "/tmp"})), &ctx)
            .await
            .unwrap();
        assert!(result["sessionId"].is_string());
    }

    #[tokio::test]
    async fn create_session_missing_working_dir() {
        let ctx = make_test_context();
        let err = CreateSessionHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn create_session_with_model_and_title() {
        let ctx = make_test_context();
        let result = CreateSessionHandler
            .handle(
                Some(json!({
                    "workingDirectory": "/tmp",
                    "model": "claude-opus-4-20250514",
                    "title": "my session"
                })),
                &ctx,
            )
            .await
            .unwrap();
        assert!(result["sessionId"].is_string());
    }

    #[tokio::test]
    async fn resume_session_success() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("model", "/tmp", Some("test"))
            .unwrap();

        let result = ResumeSessionHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["model"], "model");
    }

    #[tokio::test]
    async fn resume_session_not_found() {
        let ctx = make_test_context();
        let err = ResumeSessionHandler
            .handle(Some(json!({"sessionId": "nonexistent"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "SESSION_NOT_FOUND");
    }

    #[tokio::test]
    async fn list_sessions_empty() {
        let ctx = make_test_context();
        let result = ListSessionsHandler.handle(None, &ctx).await.unwrap();
        assert!(result["sessions"].as_array().unwrap().is_empty());
    }

    #[tokio::test]
    async fn list_sessions_populated() {
        let ctx = make_test_context();
        let _ = ctx
            .session_manager
            .create_session("m", "/a", Some("s1"))
            .unwrap();
        let _ = ctx
            .session_manager
            .create_session("m", "/b", Some("s2"))
            .unwrap();

        let result = ListSessionsHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(result["sessions"].as_array().unwrap().len(), 2);
    }

    #[tokio::test]
    async fn list_sessions_has_cache_tokens() {
        let ctx = make_test_context();
        let _ = ctx
            .session_manager
            .create_session("m", "/a", Some("s1"))
            .unwrap();

        let result = ListSessionsHandler.handle(None, &ctx).await.unwrap();
        let session = &result["sessions"][0];
        assert!(session.get("cacheReadTokens").is_some());
        assert!(session.get("cacheCreationTokens").is_some());
        assert!(session["cacheReadTokens"].is_number());
        assert!(session["cacheCreationTokens"].is_number());
    }

    #[tokio::test]
    async fn list_sessions_has_last_turn_input_tokens() {
        let ctx = make_test_context();
        let _ = ctx
            .session_manager
            .create_session("m", "/a", Some("s1"))
            .unwrap();

        let result = ListSessionsHandler.handle(None, &ctx).await.unwrap();
        let session = &result["sessions"][0];
        assert!(session.get("lastTurnInputTokens").is_some());
        assert!(session["lastTurnInputTokens"].is_number());
    }

    #[tokio::test]
    async fn list_sessions_has_message_previews() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/a", Some("s1"))
            .unwrap();

        // Add a user message
        let _ = ctx
            .event_store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::MessageUser,
                payload: json!({"text": "hello user"}),
                parent_id: None,
            })
            .unwrap();

        let result = ListSessionsHandler.handle(None, &ctx).await.unwrap();
        let session = &result["sessions"][0];
        assert!(session.get("lastUserPrompt").is_some());
        assert!(session.get("lastAssistantResponse").is_some());
    }

    #[tokio::test]
    async fn list_sessions_empty_previews() {
        let ctx = make_test_context();
        let _ = ctx
            .session_manager
            .create_session("m", "/a", Some("s1"))
            .unwrap();

        let result = ListSessionsHandler.handle(None, &ctx).await.unwrap();
        let session = &result["sessions"][0];
        // No messages → null previews
        assert!(session["lastUserPrompt"].is_null());
        assert!(session["lastAssistantResponse"].is_null());
    }

    #[tokio::test]
    async fn list_sessions_cost_field() {
        let ctx = make_test_context();
        let _ = ctx
            .session_manager
            .create_session("m", "/a", Some("s1"))
            .unwrap();

        let result = ListSessionsHandler.handle(None, &ctx).await.unwrap();
        let session = &result["sessions"][0];
        assert!(session["cost"].is_number());
    }

    #[tokio::test]
    async fn delete_session_success() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let result = DeleteSessionHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["deleted"], true);
    }

    #[tokio::test]
    async fn delete_session_missing_param() {
        let ctx = make_test_context();
        let err = DeleteSessionHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn fork_returns_new_session_id() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let result = ForkSessionHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert!(result["newSessionId"].is_string());
        let fork_id = result["newSessionId"].as_str().unwrap();
        assert_ne!(fork_id, sid);
    }

    #[tokio::test]
    async fn fork_returns_forked_from_session_id() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let result = ForkSessionHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["forkedFromSessionId"].as_str().unwrap(), sid);
    }

    #[tokio::test]
    async fn fork_returns_event_ids() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let result = ForkSessionHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        // forkedFromEventId and rootEventId should be real strings, not null
        assert!(
            result["forkedFromEventId"].is_string(),
            "forkedFromEventId should be a string, got: {}",
            result["forkedFromEventId"]
        );
        assert!(
            result["rootEventId"].is_string(),
            "rootEventId should be a string, got: {}",
            result["rootEventId"]
        );
        assert!(!result["forkedFromEventId"].as_str().unwrap().is_empty());
        assert!(!result["rootEventId"].as_str().unwrap().is_empty());
    }

    #[tokio::test]
    async fn get_head_success() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let result = GetHeadHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["sessionId"].as_str().unwrap(), sid);
    }

    #[tokio::test]
    async fn get_head_not_found() {
        let ctx = make_test_context();
        let err = GetHeadHandler
            .handle(Some(json!({"sessionId": "nope"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "SESSION_NOT_FOUND");
    }

    #[tokio::test]
    async fn get_state_success() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("my-model", "/tmp", Some("t"))
            .unwrap();

        let result = GetStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["model"], "my-model");
        assert_eq!(result["turnCount"], 0);
    }

    #[tokio::test]
    async fn get_state_has_workspace_id() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp/workspace", Some("t"))
            .unwrap();

        let result = GetStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["workspaceId"], "/tmp/workspace");
    }

    #[tokio::test]
    async fn get_state_has_cache_read_tokens() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let result = GetStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert!(result["tokenUsage"]["cacheReadTokens"].is_number());
    }

    #[tokio::test]
    async fn get_state_has_cache_creation_tokens() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let result = GetStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert!(result["tokenUsage"]["cacheCreationTokens"].is_number());
    }

    #[tokio::test]
    async fn get_state_token_usage_complete() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let result = GetStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let tu = &result["tokenUsage"];
        assert!(tu["inputTokens"].is_number());
        assert!(tu["outputTokens"].is_number());
        assert!(tu["cacheReadTokens"].is_number());
        assert!(tu["cacheCreationTokens"].is_number());
    }

    #[tokio::test]
    async fn get_state_not_found() {
        let ctx = make_test_context();
        let err = GetStateHandler
            .handle(Some(json!({"sessionId": "missing"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "SESSION_NOT_FOUND");
    }

    // ── Session lifecycle events ──

    #[tokio::test]
    async fn create_session_emits_event() {
        let ctx = make_test_context();
        let mut rx = ctx.orchestrator.subscribe();

        let _ = CreateSessionHandler
            .handle(Some(json!({"workingDirectory": "/tmp"})), &ctx)
            .await
            .unwrap();

        let event = rx.try_recv().unwrap();
        assert_eq!(event.event_type(), "session_created");
    }

    #[tokio::test]
    async fn archive_session_emits_event() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let mut rx = ctx.orchestrator.subscribe();

        let _ = ArchiveSessionHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();

        let event = rx.try_recv().unwrap();
        assert_eq!(event.event_type(), "session_archived");
    }

    #[tokio::test]
    async fn unarchive_session_emits_event() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();
        ctx.session_manager.archive_session(&sid).unwrap();

        let mut rx = ctx.orchestrator.subscribe();

        let _ = UnarchiveSessionHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();

        let event = rx.try_recv().unwrap();
        assert_eq!(event.event_type(), "session_unarchived");
    }

    #[tokio::test]
    async fn fork_session_emits_event() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let mut rx = ctx.orchestrator.subscribe();

        let result = ForkSessionHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();

        let event = rx.try_recv().unwrap();
        assert_eq!(event.event_type(), "session_forked");
        // Verify forked event has newSessionId
        let new_id = result["newSessionId"].as_str().unwrap();
        assert!(!new_id.is_empty());
    }

    #[tokio::test]
    async fn delete_session_emits_event() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let mut rx = ctx.orchestrator.subscribe();

        let _ = DeleteSessionHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();

        let event = rx.try_recv().unwrap();
        assert_eq!(event.event_type(), "session_deleted");
    }

    // ── session.getHistory tests ──

    #[tokio::test]
    async fn get_history_empty_session() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let result = GetHistoryHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert!(result["messages"].as_array().unwrap().is_empty());
        assert_eq!(result["hasMore"], false);
    }

    #[tokio::test]
    async fn get_history_with_messages() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let _ = ctx
            .event_store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::MessageUser,
                payload: json!({"text": "hello"}),
                parent_id: None,
            })
            .unwrap();
        let _ = ctx
            .event_store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::MessageAssistant,
                payload: json!({"text": "world"}),
                parent_id: None,
            })
            .unwrap();

        let result = GetHistoryHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let messages = result["messages"].as_array().unwrap();
        assert_eq!(messages.len(), 2);
    }

    #[tokio::test]
    async fn get_history_returns_has_more() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        for _ in 0..5 {
            let _ = ctx
                .event_store
                .append(&tron_events::AppendOptions {
                    session_id: &sid,
                    event_type: tron_events::EventType::MessageUser,
                    payload: json!({"text": "msg"}),
                    parent_id: None,
                })
                .unwrap();
        }

        let result = GetHistoryHandler
            .handle(Some(json!({"sessionId": sid, "limit": 3})), &ctx)
            .await
            .unwrap();
        let messages = result["messages"].as_array().unwrap();
        assert_eq!(messages.len(), 3);
        assert_eq!(result["hasMore"], true);
    }

    #[tokio::test]
    async fn get_history_before_id_pagination() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let e1 = ctx
            .event_store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::MessageUser,
                payload: json!({"text": "first"}),
                parent_id: None,
            })
            .unwrap();
        let _ = ctx
            .event_store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::MessageUser,
                payload: json!({"text": "second"}),
                parent_id: None,
            })
            .unwrap();

        // Get history before the second message
        let result = GetHistoryHandler
            .handle(Some(json!({"sessionId": sid, "beforeId": e1.id})), &ctx)
            .await
            .unwrap();
        let messages = result["messages"].as_array().unwrap();
        // beforeId cuts off at (but not including) e1
        assert!(messages.is_empty());
    }

    #[tokio::test]
    async fn get_history_missing_session() {
        let ctx = make_test_context();
        let err = GetHistoryHandler
            .handle(Some(json!({"sessionId": "nope"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "SESSION_NOT_FOUND");
    }

    #[tokio::test]
    async fn get_history_message_shape() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let _ = ctx
            .event_store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::MessageUser,
                payload: json!({"text": "hello"}),
                parent_id: None,
            })
            .unwrap();

        let result = GetHistoryHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let msg = &result["messages"][0];
        assert!(msg["id"].is_string());
        assert_eq!(msg["role"], "user");
        assert!(msg["content"].is_object());
        assert!(msg["timestamp"].is_string());
    }

    #[tokio::test]
    async fn get_history_tool_result_has_tool_call_id_at_top() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let _ = ctx
            .event_store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::ToolResult,
                payload: json!({"toolCallId": "tc1", "content": "result data", "isError": false}),
                parent_id: None,
            })
            .unwrap();

        let result = GetHistoryHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let msg = &result["messages"][0];
        assert_eq!(
            msg["toolCallId"], "tc1",
            "toolCallId should be hoisted to message level"
        );
    }

    #[tokio::test]
    async fn get_history_tool_result_content_preserved() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let _ = ctx
            .event_store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::ToolResult,
                payload: json!({"toolCallId": "tc1", "content": "file contents", "isError": false}),
                parent_id: None,
            })
            .unwrap();

        let result = GetHistoryHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let msg = &result["messages"][0];
        assert_eq!(msg["content"]["content"], "file contents");
    }

    #[tokio::test]
    async fn get_history_tool_result_has_is_error() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let _ = ctx
            .event_store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::ToolResult,
                payload: json!({"toolCallId": "tc1", "content": "error msg", "isError": true}),
                parent_id: None,
            })
            .unwrap();

        let result = GetHistoryHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let msg = &result["messages"][0];
        assert_eq!(
            msg["isError"], true,
            "isError should be hoisted to message level"
        );
    }

    #[tokio::test]
    async fn get_history_assistant_latency_preserved() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let _ = ctx
            .event_store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::MessageAssistant,
                payload: json!({
                    "content": [{"type": "text", "text": "hello"}],
                    "latency": 1234
                }),
                parent_id: None,
            })
            .unwrap();

        let result = GetHistoryHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let msg = &result["messages"][0];
        assert_eq!(
            msg["content"]["latency"], 1234,
            "latency should be preserved in content"
        );
    }

    #[tokio::test]
    async fn get_history_includes_tool_results() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        // User message
        let _ = ctx
            .event_store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::MessageUser,
                payload: json!({"content": "read a file"}),
                parent_id: None,
            })
            .unwrap();

        // Assistant message with tool_use block
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({"content": [{"type": "tool_use", "id": "tc1", "name": "Read", "arguments": {"path": "/tmp/test"}}]}),
            parent_id: None,
        }).unwrap();

        // Tool result (persisted as tool.result)
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::ToolResult,
            payload: json!({"toolCallId": "tc1", "content": "file contents here", "isError": false}),
            parent_id: None,
        }).unwrap();

        let result = GetHistoryHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let messages = result["messages"].as_array().unwrap();
        assert_eq!(
            messages.len(),
            3,
            "should include user, assistant, and tool result"
        );
        assert_eq!(messages[0]["role"], "user");
        assert_eq!(messages[1]["role"], "assistant");
        assert_eq!(messages[2]["role"], "tool");
        assert_eq!(messages[2]["content"]["toolCallId"], "tc1");
        assert_eq!(messages[2]["content"]["content"], "file contents here");
    }

    // ── Optimistic context event tests ──

    #[tokio::test]
    async fn create_session_emits_rules_loaded_when_rules_exist() {
        // Set up a temp dir with a CLAUDE.md file
        let tmp =
            std::env::temp_dir().join(format!("tron-session-test-rules-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(tmp.join(".claude")).unwrap();
        std::fs::write(tmp.join(".claude").join("CLAUDE.md"), "# Rules").unwrap();

        let ctx = make_test_context();
        let mut rx = ctx.orchestrator.subscribe();

        let result = CreateSessionHandler
            .handle(
                Some(json!({"workingDirectory": tmp.to_string_lossy()})),
                &ctx,
            )
            .await
            .unwrap();

        let sid = result["sessionId"].as_str().unwrap();

        // Check persisted rules.loaded event
        let rules_events = ctx
            .event_store
            .get_events_by_type(sid, &["rules.loaded"], Some(10))
            .unwrap();
        assert_eq!(
            rules_events.len(),
            1,
            "rules.loaded should be persisted once"
        );

        // Check broadcast events: session_created then rules_loaded
        let e1 = rx.try_recv().unwrap();
        assert_eq!(e1.event_type(), "session_created");
        let e2 = rx.try_recv().unwrap();
        assert_eq!(e2.event_type(), "rules_loaded");

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test]
    async fn create_session_no_rules_event_when_no_rules() {
        let tmp = std::env::temp_dir().join(format!(
            "tron-session-test-norules-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&tmp).unwrap();

        let ctx = make_test_context();

        let result = CreateSessionHandler
            .handle(
                Some(json!({"workingDirectory": tmp.to_string_lossy()})),
                &ctx,
            )
            .await
            .unwrap();

        let sid = result["sessionId"].as_str().unwrap();

        let rules_events = ctx
            .event_store
            .get_events_by_type(sid, &["rules.loaded"], Some(10))
            .unwrap();
        assert!(
            rules_events.is_empty(),
            "no rules.loaded event when no rules files exist"
        );

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test]
    async fn create_session_rules_loaded_has_correct_total_files() {
        let tmp =
            std::env::temp_dir().join(format!("tron-session-test-rcount-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(tmp.join(".claude")).unwrap();
        std::fs::write(tmp.join(".claude").join("CLAUDE.md"), "# Rules").unwrap();

        let ctx = make_test_context();

        let result = CreateSessionHandler
            .handle(
                Some(json!({"workingDirectory": tmp.to_string_lossy()})),
                &ctx,
            )
            .await
            .unwrap();

        let sid = result["sessionId"].as_str().unwrap();
        let rules_events = ctx
            .event_store
            .get_events_by_type(sid, &["rules.loaded"], Some(1))
            .unwrap();
        let payload: serde_json::Value = serde_json::from_str(&rules_events[0].payload).unwrap();
        // At least 1 file (the project rules); may also have global rules
        assert!(
            payload["totalFiles"].as_u64().unwrap() >= 1,
            "totalFiles should be >= 1, got: {}",
            payload["totalFiles"]
        );

        let _ = std::fs::remove_dir_all(&tmp);
    }
}
