//! Dispatch of durable closed session-organization intents.

use super::*;
use crate::domains::session::event_store::{
    EventStoreError, SessionOrganizationArchiveAction as StoreArchiveAction,
    SessionOrganizationMutation as StoreMutation, SessionRow,
};
use crate::domains::worker_kernel::dispatches::PreparedWorkerDispatch;
use crate::domains::worker_kernel::persistence::SessionOrganizationDispatch;
use crate::domains::worker_kernel::session_organization::SessionOrganizationArchiveAction;
use crate::domains::worker_kernel::types::WorkerDispatchResponseOwner;
use crate::shared::protocol::events::{BaseEvent, TronEvent};

pub(super) const SESSION_ORGANIZATION_AFTER_TITLE_ROUTE: &str = "session-organization-after-title";

impl WorkerRuntime {
    /// Prepare the active organization policy as an ordinary durable handoff.
    ///
    /// The caller commits this handoff in the same workers.sqlite transaction
    /// as the successful title-policy result. A failed completion transaction
    /// therefore leaves the title invocation running for the existing
    /// finalization/recovery path instead of dropping organization work after
    /// the canonical title compare-and-set has already succeeded.
    pub(super) fn prepare_session_organization_after_title(
        &self,
        invocation: &InvocationRecord,
        session: SessionRow,
    ) -> Result<Option<PreparedWorkerDispatch>, String> {
        if session.is_worker_session() {
            return Ok(None);
        }
        let (labels, organization_group) =
            crate::domains::session::event_store::session_organization_from_tags(&session.tags);
        let input = json!({
            "action":"session_organization",
            "session":{
                "sessionId":session.id,
                "title":session.title,
                "workingDirectory":session.working_directory,
                "labels":labels,
                "group":organization_group,
                "isArchived":session.ended_at.is_some(),
            },
            "userPrompt":truncate_organization_context(
                invocation.input["userPrompt"].as_str().unwrap_or_default()
            ),
            "assistantResponse":truncate_organization_context(
                invocation.input["assistantResponse"].as_str().unwrap_or_default()
            ),
        });
        let Some(worker) = self.active_engine_hook(
            WorkerEngineHook::SessionOrganization,
            Some(&invocation.worker_id),
        )?
        else {
            return Ok(None);
        };
        let function_id = FunctionId::new(format!(
            "worker_kernel::dynamic_{}",
            worker.summary.worker_id
        ))
        .map_err(|error| error.to_string())?;
        crate::engine::validate_engine_schema_payload(
            &function_id,
            "request",
            &worker.bundle.input_schema,
            &input,
        )
        .map_err(|error| {
            format!(
                "session organization input does not match worker '{}' version '{}': {error}",
                worker.summary.worker_id, worker.summary.active_version
            )
        })?;
        let deduplication_key = hex::encode(Sha256::digest(invocation.invocation_id.as_bytes()));
        Ok(Some(PreparedWorkerDispatch {
            route: SESSION_ORGANIZATION_AFTER_TITLE_ROUTE.to_owned(),
            deduplication_key,
            input,
            target_worker_id: worker.summary.worker_id,
            target_worker_version: worker.summary.active_version,
            response_owner: WorkerDispatchResponseOwner::Target,
        }))
    }

    pub(super) async fn dispatch_session_organization(self: &Arc<Self>, runs: &mut JoinSet<()>) {
        if self
            .session_organization_maintenance_ticks
            .fetch_add(1, Ordering::Relaxed)
            % 30
            == 0
        {
            let _ = self.store.recover_stale_session_organization_intents();
        }
        let Ok(intents) = self.store.pending_session_organization_intents(16) else {
            return;
        };
        for intent in intents {
            let Ok(true) = self
                .store
                .claim_session_organization_intent(&intent.intent_id)
            else {
                continue;
            };
            let runtime = Arc::clone(self);
            runs.spawn(async move {
                runtime.apply_session_organization_intent(intent).await;
            });
        }
    }

    async fn apply_session_organization_intent(&self, intent: SessionOrganizationDispatch) {
        let intent_id = intent.intent_id.clone();
        let mutations = intent
            .mutations
            .iter()
            .map(|mutation| StoreMutation {
                session_id: mutation.session_id.clone(),
                labels: mutation.labels.clone(),
                group: mutation.group.clone(),
                archive_action: match mutation.archive_action {
                    SessionOrganizationArchiveAction::Preserve => StoreArchiveAction::Preserve,
                    SessionOrganizationArchiveAction::Archive => StoreArchiveAction::Archive,
                    SessionOrganizationArchiveAction::Restore => StoreArchiveAction::Restore,
                },
            })
            .collect::<Vec<_>>();
        let event_store = self.event_store.clone();
        let result =
            tokio::task::spawn_blocking(move || event_store.apply_session_organization(&mutations))
                .await;
        match result {
            Ok(Ok(snapshots)) => {
                for snapshot in snapshots {
                    self.session_manager
                        .invalidate_session(&snapshot.session_id);
                    let base = BaseEvent::now(&snapshot.session_id);
                    if snapshot.archive_changed {
                        let event = if snapshot.is_archived {
                            TronEvent::SessionArchived { base: base.clone() }
                        } else {
                            TronEvent::SessionUnarchived { base: base.clone() }
                        };
                        let _ = self.orchestrator.broadcast().emit(event);
                    }
                    let _ = self
                        .orchestrator
                        .broadcast()
                        .emit(TronEvent::SessionUpdated {
                            base,
                            title: None,
                            model: None,
                            event_count: None,
                            turn_count: None,
                            message_count: None,
                            input_tokens: None,
                            output_tokens: None,
                            last_turn_input_tokens: None,
                            cache_read_tokens: None,
                            cache_creation_tokens: None,
                            cost: None,
                            last_activity: chrono::Utc::now().to_rfc3339(),
                            is_active: false,
                            last_user_prompt: None,
                            last_assistant_response: None,
                            parent_session_id: None,
                            activity_lines: None,
                            labels: Some(snapshot.labels),
                            organization_group: snapshot.group,
                            organization_changed: Some(true),
                            is_archived: Some(snapshot.is_archived),
                        });
                }
                let _ = self.store.complete_session_organization_intent(&intent_id);
                self.publish_event(
                    "worker.session_organization",
                    json!({
                        "action":"applied",
                        "intentId":intent_id,
                        "sourceInvocationId":intent.source_invocation_id,
                        "workerId":intent.worker_id,
                    }),
                    TraceId::new(intent.trace_id).ok(),
                )
                .await;
            }
            Ok(Err(error)) => {
                let permanent = matches!(error, EventStoreError::SessionNotFound(_));
                let sanitized = match &error {
                    EventStoreError::SessionNotFound(_) => {
                        "target session was not found".to_owned()
                    }
                    _ => "canonical session mutation is temporarily unavailable".to_owned(),
                };
                let attempts = self
                    .store
                    .release_session_organization_intent(&intent_id, &sanitized, permanent)
                    .unwrap_or_default();
                if !permanent && attempts == 3 {
                    let _ = self.store.record_system_inbox(
                        &intent.worker_id,
                        "session_organization_retry",
                        &json!({
                            "status":"attention",
                            "phase":"session_organization",
                            "intentId":intent_id,
                            "error":"Canonical session mutation remains temporarily unavailable",
                            "attemptCount":attempts,
                        }),
                    );
                }
                self.publish_event(
                    "worker.session_organization",
                    json!({
                        "action":if permanent {"failed"} else {"queued"},
                        "intentId":intent_id,
                        "sourceInvocationId":intent.source_invocation_id,
                        "workerId":intent.worker_id,
                        "error":sanitized,
                    }),
                    TraceId::new(intent.trace_id).ok(),
                )
                .await;
            }
            Err(_) => {
                let _ = self.store.release_session_organization_intent(
                    &intent_id,
                    "canonical session mutation task was interrupted",
                    false,
                );
            }
        }
    }
}

fn truncate_organization_context(value: &str) -> String {
    value.chars().take(4_096).collect()
}
