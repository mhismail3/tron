use super::{BaseEvent, CreateSessionRequest, Deps, SessionLifecycleService, TronEvent};
use crate::domains::session::event_store::identity::SessionCreationIdentity;
use crate::engine::{ActorId, ActorKind, CausalContext, FunctionId, Invocation, TraceId};
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::ToolError;
use serde_json::Value;
use serde_json::json;

pub(crate) fn project_created_session(
    orchestrator: &std::sync::Arc<crate::domains::agent::r#loop::orchestrator::core::Orchestrator>,
    engine_host: crate::engine::EngineHostHandle,
    session_id: &str,
    model: &str,
    working_directory: &str,
    title: Option<String>,
) {
    let _ = orchestrator.broadcast().emit(TronEvent::SessionCreated {
        base: BaseEvent::now(session_id),
        model: model.to_owned(),
        working_directory: working_directory.to_owned(),
        title,
    });
    orchestrator.init_sequence_counter(session_id, 0);

    // Mailbox semantics are optional policy. Admission is detached from
    // session creation so neither a missing curator nor a slow worker can
    // delay the first user prompt.
    let mailbox_session_id = session_id.to_owned();
    drop(tokio::spawn(async move {
        let Ok(function_id) = FunctionId::new("worker_kernel::mailbox_curate") else {
            return;
        };
        let Ok(actor_id) = ActorId::new("system:session-mailbox-curation") else {
            return;
        };
        let causal = CausalContext::new(actor_id, ActorKind::System, TraceId::generate())
            .with_session_id(mailbox_session_id.clone())
            .with_idempotency_key(format!("mailbox-curation:{mailbox_session_id}"));
        let outcome = engine_host
            .invoke(Invocation::new_sync(
                function_id,
                json!({"sessionId":mailbox_session_id}),
                causal,
            ))
            .await;
        if let Some(error) = outcome.error {
            tracing::warn!(
                session_id = mailbox_session_id,
                error = %error,
                "asynchronous new-session mailbox curation failed"
            );
        }
    }));
}

impl SessionLifecycleService {
    pub(crate) async fn create(
        deps: &Deps,
        request: CreateSessionRequest,
    ) -> Result<Value, ToolError> {
        let session_manager = deps.session_manager.clone();
        let working_directory = crate::shared::foundation::paths::normalize_working_directory(
            &request.working_directory,
        )
        .map_err(|message| ToolError::InvalidParams { message })?
        .display()
        .to_string();
        let (working_directory, session_id) = if let Some(source_control) = request.source_control {
            let _creation_guard =
                crate::domains::filesystem::source_control::creation_guard().await;
            let identity = SessionCreationIdentity::generate_current();
            let prepared = crate::domains::filesystem::source_control::prepare_session_checkout(
                std::path::Path::new(&working_directory),
                source_control,
                &identity.session.id,
                &crate::shared::foundation::paths::session_worktrees_dir(),
            )
            .await?;
            let prepared_working_directory = prepared.working_directory.display().to_string();
            let model = request.model.clone();
            let title = request.title.clone();
            let stored_working_directory = prepared_working_directory.clone();
            let create_result = run_blocking_task("session.create", move || {
                session_manager
                    .create_session_with_identity(
                        &model,
                        &stored_working_directory,
                        title.as_deref(),
                        identity,
                    )
                    .map_err(|error| ToolError::Internal {
                        message: error.to_string(),
                    })
            })
            .await;
            match create_result {
                Ok(session_id) => (prepared_working_directory, session_id),
                Err(create_error) => {
                    if let Err(rollback_error) = prepared.rollback().await {
                        return Err(ToolError::Internal {
                            message: format!(
                                "Session creation failed ({create_error}); source-control rollback also failed ({rollback_error})."
                            ),
                        });
                    }
                    return Err(create_error);
                }
            }
        } else {
            let model = request.model.clone();
            let title = request.title.clone();
            let stored_working_directory = working_directory.clone();
            let session_id = run_blocking_task("session.create", move || {
                session_manager
                    .create_session(&model, &stored_working_directory, title.as_deref())
                    .map_err(|error| ToolError::Internal {
                        message: error.to_string(),
                    })
            })
            .await?;
            (working_directory, session_id)
        };

        project_created_session(
            &deps.orchestrator,
            deps.engine_host.clone(),
            &session_id,
            &request.model,
            &working_directory,
            request.title.clone(),
        );

        Ok(json!({
            "sessionId": session_id,
            "model": request.model,
            "workingDirectory": working_directory,
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
