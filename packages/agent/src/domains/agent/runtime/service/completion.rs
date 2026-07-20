//! Prompt-run completion and recovery.

use std::sync::Arc;
use std::sync::atomic::AtomicI64;

use tracing::{info, warn};

use super::{
    PromptEngineCausality, PromptRunCleanup, load_session_update_event,
    publish_prompt_runtime_stream,
};
use crate::shared::protocol::events::{BaseEvent, TronEvent, error_event};
use crate::shared::server::failure::{
    FailureCategory, FailureEnvelope, FailureOrigin, RUNTIME_RUN_ERROR,
};

pub(super) struct PromptRunCompletion<'a> {
    pub(super) result: crate::domains::agent::r#loop::types::RunResult,
    pub(super) run_cleanup: &'a mut PromptRunCleanup,
    pub(super) event_store: Arc<crate::domains::session::event_store::EventStore>,
    pub(super) broadcast: Arc<crate::domains::agent::r#loop::EventEmitter>,
    pub(super) engine_host: crate::engine::EngineHostHandle,
    pub(super) engine_causality: Option<PromptEngineCausality>,
    pub(super) session_id: String,
    pub(super) run_id: String,
    pub(super) provider_type: String,
    pub(super) model_for_error: String,
    pub(super) sequence_counter: Option<Arc<AtomicI64>>,
}

pub(super) async fn finalize_prompt_run(args: PromptRunCompletion<'_>) {
    let PromptRunCompletion {
        result,
        run_cleanup,
        event_store,
        broadcast,
        engine_host,
        engine_causality,
        session_id,
        run_id,
        provider_type,
        model_for_error,
        sequence_counter,
    } = args;

    info!(
        component = "agent.runtime",
        agent_event = "prompt_run_finalizing",
        session_id = %session_id,
        run_id = %run_id,
        provider_type = %provider_type,
        turns_executed = result.turns_executed,
        interrupted = result.interrupted,
        stop_reason = ?result.stop_reason,
        has_error = result.error.is_some(),
        "agent prompt run finalizing"
    );
    // INVARIANT: the active-run slot owns every event that consumes its shared
    // sequence counter. Publish the final session metadata first. Terminal
    // error/idle/ready events and matching run release then share one registry
    // boundary, so event-triggered prompt admission cannot observe SessionBusy
    // and no old terminal event can race a replacement run.
    emit_session_update(
        &event_store,
        &broadcast,
        &session_id,
        sequence_counter.as_deref(),
    )
    .await;
    let terminal_failure =
        run_error_event_if_needed(&session_id, &provider_type, &model_for_error, &result);
    let _ = run_cleanup.release_with_terminal(|| {
        publish_terminal_lifecycle(
            &broadcast,
            &session_id,
            result.error.clone(),
            sequence_counter.as_deref(),
            terminal_failure,
        );
    });

    info!(
        component = "agent.runtime",
        agent_event = "prompt_run_completed",
        session_id = %session_id,
        run_id = %run_id,
        stop_reason = ?result.stop_reason,
        turns = result.turns_executed,
        interrupted = result.interrupted,
        has_error = result.error.is_some(),
        "prompt run completed"
    );
    publish_prompt_runtime_stream(
        &engine_host,
        engine_causality.as_ref(),
        &session_id,
        "completed",
        serde_json::json!({
            "runId": run_id,
            "turnsExecuted": result.turns_executed,
            "interrupted": result.interrupted,
            "stopReason": format!("{:?}", result.stop_reason),
            "error": result.error,
        }),
    )
    .await;
}

pub(super) fn publish_terminal_lifecycle(
    broadcast: &Arc<crate::domains::agent::r#loop::EventEmitter>,
    session_id: &str,
    error: Option<String>,
    sequence_counter: Option<&AtomicI64>,
    failure_event: Option<TronEvent>,
) {
    emit_maybe_sequenced(
        broadcast,
        TronEvent::AgentEnd {
            base: BaseEvent::now(session_id),
            error,
        },
        sequence_counter,
    );
    if let Some(event) = failure_event {
        emit_maybe_sequenced(broadcast, event, sequence_counter);
    }
    for event in [
        TronEvent::SessionProcessingChanged {
            base: BaseEvent::now(session_id),
            is_processing: false,
        },
        TronEvent::AgentReady {
            base: BaseEvent::now(session_id),
        },
    ] {
        emit_maybe_sequenced(broadcast, event, sequence_counter);
    }
}

fn emit_maybe_sequenced(
    broadcast: &Arc<crate::domains::agent::r#loop::EventEmitter>,
    event: TronEvent,
    sequence_counter: Option<&AtomicI64>,
) {
    if let Some(counter) = sequence_counter {
        let _ = broadcast.emit_sequenced(event, counter);
    } else {
        let _ = broadcast.emit(event);
    }
}

fn run_error_event_if_needed(
    session_id: &str,
    provider_type: &str,
    model_for_error: &str,
    result: &crate::domains::agent::r#loop::types::RunResult,
) -> Option<TronEvent> {
    let Some(ref error_message) = result.error else {
        return None;
    };
    let failure = FailureEnvelope::new(
        RUNTIME_RUN_ERROR,
        FailureCategory::Unknown,
        error_message.clone(),
        false,
        false,
        FailureOrigin::AgentRuntime,
    )
    .with_provider_model(provider_type, model_for_error)
    .with_details(Some(serde_json::json!({ "source": "run_result" })));
    Some(error_event(BaseEvent::now(session_id), &failure, None))
}

async fn emit_session_update(
    event_store: &Arc<crate::domains::session::event_store::EventStore>,
    broadcast: &Arc<crate::domains::agent::r#loop::EventEmitter>,
    session_id: &str,
    sequence_counter: Option<&AtomicI64>,
) {
    match load_session_update_event(event_store.clone(), session_id.to_owned()).await {
        Ok(Some(event)) => {
            if let Some(counter) = sequence_counter {
                let _ = broadcast.emit_sequenced(event, counter);
            } else {
                let _ = broadcast.emit(event);
            }
        }
        Ok(None) => {}
        Err(error) => {
            warn!(
                session_id = %session_id,
                error = %error,
                "failed to load session update event"
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn completion_does_not_recreate_superseded_result_resources() {
        let source = include_str!("completion.rs");
        let create_operation = ["resource", "::", "create"].concat();
        let obsolete_kind = ["agent", "_", "result"].concat();
        let obsolete_refs = ["resource", "Refs"].concat();
        assert!(!source.contains(&create_operation));
        assert!(!source.contains(&obsolete_kind));
        assert!(!source.contains(&obsolete_refs));
    }

    #[tokio::test]
    async fn terminal_lifecycle_is_contiguous_and_ready_is_last() {
        let broadcast = Arc::new(crate::domains::agent::r#loop::EventEmitter::new());
        let mut events = broadcast.subscribe();
        let sequence = AtomicI64::new(10);
        let failure = FailureEnvelope::new(
            RUNTIME_RUN_ERROR,
            FailureCategory::Unknown,
            "provider stopped",
            false,
            false,
            FailureOrigin::AgentRuntime,
        );

        publish_terminal_lifecycle(
            &broadcast,
            "session-a",
            Some("provider stopped".to_owned()),
            Some(&sequence),
            Some(error_event(BaseEvent::now("session-a"), &failure, None)),
        );

        let received = [
            events.recv().await.unwrap(),
            events.recv().await.unwrap(),
            events.recv().await.unwrap(),
            events.recv().await.unwrap(),
        ];
        assert!(matches!(&received[0], TronEvent::AgentEnd { .. }));
        assert!(matches!(&received[1], TronEvent::Error { .. }));
        assert!(matches!(
            &received[2],
            TronEvent::SessionProcessingChanged {
                is_processing: false,
                ..
            }
        ));
        assert!(matches!(&received[3], TronEvent::AgentReady { .. }));
        assert_eq!(
            received.iter().map(TronEvent::sequence).collect::<Vec<_>>(),
            vec![Some(11), Some(12), Some(13), Some(14)]
        );
    }
}
