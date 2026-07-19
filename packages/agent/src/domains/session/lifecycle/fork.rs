use super::{BaseEvent, Deps, ForkSessionRequest, SessionLifecycleService, TronEvent};
use crate::domains::session::event_store::{
    EventIdentity, EventType, ForkOptions, ListEventsOptions, SessionForkIdentity, SessionIdentity,
};
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors;
use crate::shared::server::errors::CapabilityError;
use chrono::Utc;
use serde_json::Value;
use serde_json::json;
use sha2::{Digest, Sha256};

impl SessionLifecycleService {
    pub(crate) async fn fork(
        deps: &Deps,
        request: ForkSessionRequest,
    ) -> Result<Value, CapabilityError> {
        let ForkSessionRequest {
            session_id,
            from_event_id,
            expected_head_event_id,
            title,
            causal_session_id,
            causal_workspace_id,
            idempotency_key,
        } = request;
        if let Some(causal_session_id) = causal_session_id.as_deref()
            && causal_session_id != session_id
        {
            return Err(CapabilityError::InvalidParams {
                message: format!(
                    "sessionId '{session_id}' does not match the invoking session '{causal_session_id}'"
                ),
            });
        }
        let event_store = deps.event_store.clone();
        let session_id_for_fork = session_id.clone();
        let request_fingerprint = branch_request_fingerprint(
            &session_id,
            from_event_id.as_deref(),
            expected_head_event_id.as_deref(),
            title.as_deref(),
        );
        let (new_session_id, forked_from_event_id, root_event_id, replayed, child_max_sequence) =
            run_blocking_task("session.fork", move || {
                let session = event_store
                    .get_session(&session_id_for_fork)
                    .map_err(persistence_error)?
                    .ok_or_else(|| CapabilityError::NotFound {
                        code: errors::SESSION_NOT_FOUND.into(),
                        message: format!("Session not found: {session_id_for_fork}"),
                    })?;
                if let Some(causal_workspace_id) = causal_workspace_id.as_deref()
                    && causal_workspace_id != session.workspace_id
                {
                    return Err(CapabilityError::InvalidParams {
                        message: format!(
                            "session '{session_id_for_fork}' does not belong to the invoking workspace"
                        ),
                    });
                }

                // A committed branch must be recoverable before consulting
                // mutable source state. The response may have been lost and
                // the source may have advanced since the original commit.
                let identity = idempotency_key
                    .as_deref()
                    .map(|key| deterministic_fork_identity(&session_id_for_fork, key));
                if let Some(identity) = identity.as_ref()
                    && let Some(existing) = event_store
                        .get_session(&identity.session.id)
                        .map_err(persistence_error)?
                {
                    let bound_event = existing.fork_from_event_id.as_deref().ok_or_else(|| {
                        CapabilityError::Internal {
                            message: "Committed branch has no source boundary".into(),
                        }
                    })?;
                    let root_event = event_store
                        .get_event(&identity.fork_event.id)
                        .map_err(persistence_error)?
                        .ok_or_else(|| CapabilityError::Internal {
                            message: "Committed branch has no deterministic root event".into(),
                        })?;
                    let root_payload: Value = serde_json::from_str(&root_event.payload).map_err(
                        |error| CapabilityError::Internal {
                            message: format!("Committed branch root payload is invalid: {error}"),
                        },
                    )?;
                    let same_request = existing.parent_session_id.as_deref()
                        == Some(session_id_for_fork.as_str())
                        && root_event.session_id == existing.id
                        && root_event.parent_id.as_deref() == Some(bound_event)
                        && root_payload["requestFingerprint"].as_str()
                            == Some(request_fingerprint.as_str());
                    if !same_request {
                        return Err(CapabilityError::InvalidParams {
                            message: "idempotencyKey is already bound to a different branch request"
                                .into(),
                        });
                    }
                    let root_event_id = existing.root_event_id.clone().ok_or_else(|| {
                        CapabilityError::Internal {
                            message: "Committed branch has no root event".into(),
                        }
                    })?;
                    let child_max_sequence = event_store
                        .get_max_sequence(&existing.id)
                        .map_err(persistence_error)?;
                    return Ok((
                        existing.id,
                        bound_event.to_owned(),
                        root_event_id,
                        true,
                        child_max_sequence,
                    ));
                }
                if let Some(expected) = expected_head_event_id.as_deref()
                    && session.head_event_id.as_deref() != Some(expected)
                {
                    return Err(CapabilityError::Custom {
                        code: "SESSION_HEAD_CHANGED".into(),
                        message: "Session head changed before the branch could be created".into(),
                        details: Some(json!({
                            "expectedHeadEventId": expected,
                            "actualHeadEventId": session.head_event_id,
                        })),
                    });
                }

                let events = event_store
                    .get_events_by_session(&session_id_for_fork, &ListEventsOptions::default())
                    .map_err(persistence_error)?;
                let fork_event_id = resolve_fork_point(&events, from_event_id.as_deref())?;
                let result = event_store
                    .fork_with_identity(
                        &fork_event_id,
                        &ForkOptions {
                            model: None,
                            title: title.as_deref(),
                            expected_source_session_id: Some(&session_id_for_fork),
                            expected_head_event_id: expected_head_event_id.as_deref(),
                            request_fingerprint: Some(&request_fingerprint),
                        },
                        identity.unwrap_or_else(SessionForkIdentity::generate_current),
                    )
                    .map_err(fork_persistence_error)?;
                let child_max_sequence = event_store
                    .get_max_sequence(&result.session.id)
                    .map_err(persistence_error)?;
                Ok((
                    result.session.id,
                    fork_event_id,
                    result.fork_event.id,
                    result.replayed,
                    child_max_sequence,
                ))
            })
            .await?;

        deps.orchestrator
            .init_sequence_counter(&new_session_id, child_max_sequence);

        if !replayed {
            let _ = deps
                .orchestrator
                .broadcast()
                .emit(TronEvent::SessionForked {
                    base: BaseEvent::now(&session_id),
                    new_session_id: new_session_id.clone(),
                });
        }

        Ok(json!({
            "newSessionId": new_session_id,
            "forkedFromSessionId": session_id,
            "forkedFromEventId": forked_from_event_id,
            "rootEventId": root_event_id,
            "replayed": replayed,
        }))
    }
}

fn resolve_fork_point(
    events: &[crate::domains::session::event_store::EventRow],
    requested_event_id: Option<&str>,
) -> Result<String, CapabilityError> {
    let requested_index = requested_event_id
        .map(|id| {
            events
                .iter()
                .position(|event| event.id == id)
                .ok_or_else(|| CapabilityError::NotFound {
                    code: errors::EVENT_NOT_FOUND.into(),
                    message: format!("Event not found in source session: {id}"),
                })
        })
        .transpose()?;

    let boundary = match requested_index {
        None => events
            .iter()
            .rev()
            .find(|event| event.event_type == EventType::StreamTurnEnd.as_str()),
        Some(index) if events[index].event_type == EventType::StreamTurnEnd.as_str() => {
            Some(&events[index])
        }
        // Preserve message-oriented callers while making the stored fork point
        // the provider-valid terminal boundary that follows that response.
        Some(index) if events[index].event_type == EventType::MessageAssistant.as_str() => {
            let turn = events[index].turn;
            events[index + 1..].iter().find(|event| {
                event.event_type == EventType::StreamTurnEnd.as_str() && event.turn == turn
            })
        }
        Some(_) => None,
    };

    boundary
        .map(|event| event.id.clone())
        .ok_or_else(|| CapabilityError::InvalidParams {
            message: "A branch must start at a completed assistant turn".into(),
        })
}

fn deterministic_fork_identity(session_id: &str, idempotency_key: &str) -> SessionForkIdentity {
    let timestamp = Utc::now().to_rfc3339();
    let session_digest = Sha256::digest(
        format!("tron.session.fork.session.v1\0{session_id}\0{idempotency_key}").as_bytes(),
    );
    let event_digest = Sha256::digest(
        format!("tron.session.fork.event.v1\0{session_id}\0{idempotency_key}").as_bytes(),
    );
    SessionForkIdentity::new(
        SessionIdentity::new(format!("sess_{}", hex::encode(session_digest)), &timestamp),
        EventIdentity::new(format!("evt_{}", hex::encode(event_digest)), timestamp),
    )
}

fn branch_request_fingerprint(
    session_id: &str,
    from_event_id: Option<&str>,
    expected_head_event_id: Option<&str>,
    title: Option<&str>,
) -> String {
    let encoded = serde_json::to_vec(&json!({
        "sessionId": session_id,
        "fromEventId": from_event_id,
        "expectedHeadEventId": expected_head_event_id,
        "title": title,
    }))
    .expect("branch request fingerprint JSON is serializable");
    format!("sha256:{}", hex::encode(Sha256::digest(encoded)))
}

fn persistence_error(error: impl std::fmt::Display) -> CapabilityError {
    CapabilityError::Internal {
        message: format!("Persistence error: {error}"),
    }
}

fn fork_persistence_error(
    error: crate::domains::session::event_store::EventStoreError,
) -> CapabilityError {
    let message = error.to_string();
    if message.contains("session head changed before fork commit") {
        return CapabilityError::Custom {
            code: "SESSION_HEAD_CHANGED".into(),
            message: "Session head changed before the branch could be created".into(),
            details: None,
        };
    }
    if message.contains("fork point does not belong to the requested source session") {
        return CapabilityError::InvalidParams {
            message: "Fork point does not belong to the requested source session".into(),
        };
    }
    persistence_error(error)
}
