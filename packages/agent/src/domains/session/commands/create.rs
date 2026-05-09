use super::{
    BaseEvent, CreateSessionRequest, Deps, SessionCommandService, TronEvent,
    resolve_session_profile, spawn_optimistic_context_preload,
};
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;
use serde_json::Value;
use serde_json::json;

impl SessionCommandService {
    pub(crate) async fn create(
        deps: &Deps,
        request: CreateSessionRequest,
    ) -> Result<Value, CapabilityError> {
        let session_manager = deps.session_manager.clone();
        let working_directory = request.working_directory.clone();
        let model = request.model.clone();
        let title = request.title.clone();
        let source = request.source.clone();
        let profile = resolve_session_profile(
            deps,
            request.profile.as_deref(),
            request.model.as_str(),
            request.source.as_deref(),
        )?;
        let use_worktree = request.use_worktree;
        let profile_for_create = profile.clone();
        let session_id = run_blocking_task("session.create", move || {
            session_manager
                .create_session_with_profile_and_worktree_override(
                    &model,
                    &working_directory,
                    title.as_deref(),
                    source.as_deref(),
                    Some(profile_for_create.as_str()),
                    use_worktree,
                )
                .map_err(|error| CapabilityError::Internal {
                    message: error.to_string(),
                })
        })
        .await?;

        let _ = deps
            .orchestrator
            .broadcast()
            .emit(TronEvent::SessionCreated {
                base: BaseEvent::now(&session_id),
                model: request.model.clone(),
                working_directory: request.working_directory.clone(),
                source: request.source.clone(),
                profile: Some(profile.clone()),
                title: request.title.clone(),
            });

        deps.orchestrator.init_sequence_counter(&session_id, 0);

        // Skip optimistic context preload for chat sessions — they don't load context artifacts
        if profile.as_str() != crate::shared::profile::CHAT_PROFILE {
            spawn_optimistic_context_preload(deps, &session_id, &request.working_directory);
        }

        Ok(json!({
            "sessionId": session_id,
            "model": request.model,
            "workingDirectory": request.working_directory,
            "profile": profile,
            "createdAt": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
            "isActive": true,
            "isArchived": false,
            "messageCount": 0,
            "eventCount": 1,
            "inputTokens": 0,
            "outputTokens": 0,
            "cost": 0.0,
            "useWorktree": request.use_worktree,
        }))
    }
}
