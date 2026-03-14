//! Shared command-side services for session RPC handlers.

use std::time::Instant;

use metrics::{counter, histogram};
use serde_json::{Value, json};
use tron_core::events::{BaseEvent, TronEvent};
use tron_runtime::agent::event_emitter::EventEmitter;

use crate::rpc::context::{RpcContext, run_blocking_task};
use crate::rpc::errors::{self, RpcError};
use crate::rpc::session_context::{ContextArtifactsService, RuleFileLevel};

pub(crate) struct CreateSessionRequest {
    pub(crate) working_directory: String,
    pub(crate) model: String,
    pub(crate) title: Option<String>,
}

pub(crate) struct SessionCommandService;

impl SessionCommandService {
    pub(crate) async fn create(
        ctx: &RpcContext,
        request: CreateSessionRequest,
    ) -> Result<Value, RpcError> {
        let session_manager = ctx.session_manager.clone();
        let working_directory = request.working_directory.clone();
        let model = request.model.clone();
        let title = request.title.clone();
        let session_id = ctx
            .run_blocking("session.create", move || {
                session_manager
                    .create_session(&model, &working_directory, title.as_deref())
                    .map_err(|error| RpcError::Internal {
                        message: error.to_string(),
                    })
            })
            .await?;

        let _ = ctx
            .orchestrator
            .broadcast()
            .emit(TronEvent::SessionCreated {
                base: BaseEvent::now(&session_id),
                model: request.model.clone(),
                working_directory: request.working_directory.clone(),
                source: None,
            });

        spawn_optimistic_context_preload(ctx, &session_id, &request.working_directory);

        Ok(json!({
            "sessionId": session_id,
            "model": request.model,
            "workingDirectory": request.working_directory,
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

    pub(crate) async fn delete(ctx: &RpcContext, session_id: String) -> Result<Value, RpcError> {
        let session_manager = ctx.session_manager.clone();
        let session_id_for_delete = session_id.clone();
        ctx.run_blocking("session.delete", move || {
            ensure_not_chat_session(session_manager.as_ref(), &session_id_for_delete, "deleted")?;
            session_manager
                .delete_session(&session_id_for_delete)
                .map_err(|error| RpcError::Internal {
                    message: error.to_string(),
                })?;
            Ok(())
        })
        .await?;

        let _ = ctx
            .orchestrator
            .broadcast()
            .emit(TronEvent::SessionDeleted {
                base: BaseEvent::now(&session_id),
            });

        Ok(json!({ "deleted": true }))
    }

    pub(crate) async fn fork(
        ctx: &RpcContext,
        session_id: String,
        from_event_id: Option<String>,
        title: Option<String>,
    ) -> Result<Value, RpcError> {
        let session_manager = ctx.session_manager.clone();
        let session_id_for_fork = session_id.clone();
        let title_for_fork = title.clone();
        let (new_session_id, forked_from_event_id, root_event_id) = ctx
            .run_blocking("session.fork", move || {
                let result = session_manager
                    .fork_session(
                        &session_id_for_fork,
                        from_event_id.as_deref(),
                        None,
                        title_for_fork.as_deref(),
                    )
                    .map_err(|error| RpcError::NotFound {
                        code: errors::SESSION_NOT_FOUND.into(),
                        message: error.to_string(),
                    })?;
                Ok((
                    result.new_session_id,
                    result.forked_from_event_id,
                    result.root_event_id,
                ))
            })
            .await?;

        let _ = ctx.orchestrator.broadcast().emit(TronEvent::SessionForked {
            base: BaseEvent::now(&session_id),
            new_session_id: new_session_id.clone(),
        });

        Ok(json!({
            "newSessionId": new_session_id,
            "forkedFromSessionId": session_id,
            "forkedFromEventId": forked_from_event_id,
            "rootEventId": root_event_id,
        }))
    }

    pub(crate) async fn archive(ctx: &RpcContext, session_id: String) -> Result<Value, RpcError> {
        let session_manager = ctx.session_manager.clone();
        let session_id_for_archive = session_id.clone();
        ctx.run_blocking("session.archive", move || {
            ensure_not_chat_session(
                session_manager.as_ref(),
                &session_id_for_archive,
                "archived",
            )?;
            session_manager
                .archive_session(&session_id_for_archive)
                .map_err(|error| RpcError::Internal {
                    message: error.to_string(),
                })?;
            Ok(())
        })
        .await?;

        let _ = ctx
            .orchestrator
            .broadcast()
            .emit(TronEvent::SessionArchived {
                base: BaseEvent::now(&session_id),
            });

        Ok(json!({ "archived": true }))
    }

    pub(crate) async fn unarchive(ctx: &RpcContext, session_id: String) -> Result<Value, RpcError> {
        let session_manager = ctx.session_manager.clone();
        let session_id_for_unarchive = session_id.clone();
        ctx.run_blocking("session.unarchive", move || {
            session_manager
                .unarchive_session(&session_id_for_unarchive)
                .map_err(|error| RpcError::Internal {
                    message: error.to_string(),
                })?;
            Ok(())
        })
        .await?;

        let _ = ctx
            .orchestrator
            .broadcast()
            .emit(TronEvent::SessionUnarchived {
                base: BaseEvent::now(&session_id),
            });

        Ok(json!({ "unarchived": true }))
    }

    pub(crate) async fn get_chat(ctx: &RpcContext) -> Result<Value, RpcError> {
        let settings = tron_settings::get_settings();
        if !settings.session.chat.enabled {
            return Err(RpcError::Custom {
                code: "CHAT_DISABLED".into(),
                message: "Default chat mode is disabled".into(),
                details: None,
            });
        }

        let model = settings.server.default_model.clone();
        let working_directory = settings.session.chat.working_directory.clone();
        let session_manager = ctx.session_manager.clone();
        let model_for_lookup = model.clone();
        let working_directory_for_lookup = working_directory.clone();
        let (session_id, created, session) = ctx
            .run_blocking("session.get_chat", move || {
                let (session_id, created) = session_manager
                    .get_or_create_chat_session(&model_for_lookup, &working_directory_for_lookup)
                    .map_err(|error| RpcError::Internal {
                        message: error.to_string(),
                    })?;
                let session = session_manager
                    .get_session(&session_id)
                    .map_err(|error| RpcError::Internal {
                        message: error.to_string(),
                    })?
                    .ok_or_else(|| RpcError::Internal {
                        message: "Chat session disappeared after creation".into(),
                    })?;
                Ok((session_id, created, session))
            })
            .await?;

        if created {
            let _ = ctx
                .orchestrator
                .broadcast()
                .emit(TronEvent::SessionCreated {
                    base: BaseEvent::now(&session_id),
                    model: model.clone(),
                    working_directory: working_directory.clone(),
                    source: Some("chat".into()),
                });
        }

        Ok(json!({
            "sessionId": session_id,
            "created": created,
            "model": session.latest_model,
            "workingDirectory": session.working_directory,
            "createdAt": session.created_at,
            "isActive": true,
            "isArchived": false,
            "isChat": true,
            "messageCount": session.message_count,
            "eventCount": session.event_count,
        }))
    }

    pub(crate) async fn reset_chat(ctx: &RpcContext) -> Result<Value, RpcError> {
        let settings = tron_settings::get_settings();
        if !settings.session.chat.enabled {
            return Err(RpcError::Custom {
                code: "CHAT_DISABLED".into(),
                message: "Default chat mode is disabled".into(),
                details: None,
            });
        }

        let model = settings.server.default_model.clone();
        let working_directory = settings.session.chat.working_directory.clone();
        let session_manager = ctx.session_manager.clone();
        let model_for_reset = model.clone();
        let working_directory_for_reset = working_directory.clone();
        let (new_id, old_id, session) = ctx
            .run_blocking("session.reset_chat", move || {
                let (new_id, old_id) = session_manager
                    .reset_chat_session(&model_for_reset, &working_directory_for_reset)
                    .map_err(|error| RpcError::Internal {
                        message: error.to_string(),
                    })?;
                let session = session_manager
                    .get_session(&new_id)
                    .map_err(|error| RpcError::Internal {
                        message: error.to_string(),
                    })?
                    .ok_or_else(|| RpcError::Internal {
                        message: "New chat session disappeared after creation".into(),
                    })?;
                Ok((new_id, old_id, session))
            })
            .await?;

        let _ = ctx
            .orchestrator
            .broadcast()
            .emit(TronEvent::SessionArchived {
                base: BaseEvent::now(&old_id),
            });
        let _ = ctx
            .orchestrator
            .broadcast()
            .emit(TronEvent::SessionCreated {
                base: BaseEvent::now(&new_id),
                model: model.clone(),
                working_directory: working_directory.clone(),
                source: Some("chat".into()),
            });

        Ok(json!({
            "sessionId": new_id,
            "previousSessionId": old_id,
            "model": session.latest_model,
            "workingDirectory": session.working_directory,
            "createdAt": session.created_at,
            "isActive": true,
            "isArchived": false,
            "isChat": true,
            "messageCount": 0,
            "eventCount": session.event_count,
        }))
    }
}

fn ensure_not_chat_session(
    session_manager: &tron_runtime::orchestrator::session_manager::SessionManager,
    session_id: &str,
    operation: &str,
) -> Result<(), RpcError> {
    if session_manager.is_chat_session(session_id) {
        return Err(RpcError::Custom {
            code: "CHAT_SESSION_PROTECTED".into(),
            message: format!("The default chat session cannot be {operation}"),
            details: None,
        });
    }
    Ok(())
}

fn spawn_optimistic_context_preload(ctx: &RpcContext, session_id: &str, working_dir: &str) {
    let event_store = ctx.event_store.clone();
    let context_artifacts = ctx.context_artifacts.clone();
    let broadcast = ctx.orchestrator.broadcast().clone();
    let shutdown_coordinator = ctx.shutdown_coordinator.clone();
    let session_id_for_task = session_id.to_owned();
    let working_dir_for_task = working_dir.to_owned();
    let handle = tokio::spawn(async move {
        let start = Instant::now();
        let result = run_blocking_task("session.optimistic_context_preload", move || {
            let summary = emit_optimistic_context_events(
                &event_store,
                context_artifacts.as_ref(),
                &broadcast,
                &session_id_for_task,
                &working_dir_for_task,
            );
            Ok::<_, RpcError>(summary)
        })
        .await;
        match result {
            Ok(summary) => {
                histogram!("session_context_warmup_seconds").record(start.elapsed().as_secs_f64());
                if summary.loaded_rules {
                    counter!("session_context_warmups_total", "kind" => "rules").increment(1);
                }
                if summary.loaded_memory {
                    counter!("session_context_warmups_total", "kind" => "memory").increment(1);
                }
            }
            Err(error) => {
                counter!("session_context_warmup_failures_total").increment(1);
                tracing::warn!(error = %error, "optimistic context preload task failed");
            }
        }
    });
    if let Some(coord) = shutdown_coordinator {
        coord.register_task(handle);
    }
}

/// Discover rules files and memory, then persist + broadcast notification events.
fn emit_optimistic_context_events(
    event_store: &std::sync::Arc<tron_events::EventStore>,
    context_artifacts: &ContextArtifactsService,
    broadcast: &std::sync::Arc<EventEmitter>,
    session_id: &str,
    working_dir: &str,
) -> OptimisticContextSummary {
    let settings = tron_settings::get_settings();
    let artifacts = context_artifacts.load(event_store.as_ref(), working_dir, &settings, false);
    let mut summary = OptimisticContextSummary::default();

    let files_json: Vec<serde_json::Value> = artifacts
        .session
        .rules
        .files
        .iter()
        .map(|file| {
            let depth = if file.level == RuleFileLevel::Global {
                0
            } else {
                file.depth
            };
            json!({
                "path": file.path.to_string_lossy(),
                "relativePath": file.relative_path,
                "level": file.level.as_str(),
                "depth": depth,
                "sizeBytes": file.size_bytes,
            })
        })
        .collect();

    if !files_json.is_empty() {
        summary.loaded_rules = true;
        #[allow(clippy::cast_possible_truncation)]
        let total = files_json.len() as u32;
        let merged_tokens = artifacts.session.rules.merged_tokens_estimate();
        let _ = event_store.append(&tron_events::AppendOptions {
            session_id,
            event_type: tron_events::EventType::RulesLoaded,
            payload: json!({
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

    if let Some(memory) = artifacts.session.memory {
        summary.loaded_memory = true;
        #[allow(clippy::cast_possible_truncation)]
        let count = memory.raw_event_count as u32;

        let _ = event_store.append(&tron_events::AppendOptions {
            session_id,
            event_type: tron_events::EventType::MemoryLoaded,
            payload: json!({
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

    summary
}

#[derive(Default)]
struct OptimisticContextSummary {
    loaded_rules: bool,
    loaded_memory: bool,
}
