//! One-assignment and auxiliary-wake drivers over the ordinary agent loop.
//!
//! Every provider call is admitted against one stable transcript and one
//! immutable authority snapshot. The driver rereads canonical assignment state
//! at each safe boundary; process-local cancellation and notifications are only
//! latency optimizations.

use std::collections::BTreeSet;
use std::sync::Arc;
use std::time::Duration;

use serde_json::{Value, json};

use super::{AgentExecutionService, AssignmentExecutionCandidate};
use crate::domains::agent::coordination::{
    AgentRecord, AssignmentRecord, AssignmentStatus, ClaimedAssignment, CompleteAssignment,
    TerminalAssignmentStatus, WakeIntentRecord,
};
use crate::domains::agent::r#loop::types::AgentRunTrigger;
use crate::domains::agent::runtime::service::{
    PromptEngineCausality, PromptRequest, PromptRuntimeDeps, spawn_prompt_run_with_model,
};
use crate::engine::{ActorId, ActorKind, CausalContext, TraceId};
use crate::shared::protocol::events::TronEvent;

struct TranscriptEvidence {
    result: Option<Value>,
    error: Option<String>,
}

enum RunBoundary {
    Ended(Option<String>),
    AssignmentTerminal,
    AssignmentWaiting,
    Deadline,
    RunDisappeared,
}

impl AgentExecutionService {
    pub(super) async fn drive_assignment(
        &self,
        candidate: AssignmentExecutionCandidate,
    ) -> Result<(), String> {
        let Some(mut assignment) = self
            .event_store
            .core_assignment_record(&candidate.assignment.assignment_id)
            .map_err(|error| error.to_string())?
        else {
            return Ok(());
        };
        if assignment.status.is_terminal() {
            return Ok(());
        }
        let agent = self
            .event_store
            .core_agent_record(&assignment.agent_id)
            .map_err(|error| error.to_string())?
            .ok_or_else(|| format!("assignment agent '{}' disappeared", assignment.agent_id))?;
        self.ensure_assignment_message(&assignment)?;

        // Recovery first reconciles the exact interrupted attempt against the
        // durable transcript. A valid assistant result is never paid for twice.
        if assignment.status != AssignmentStatus::Waiting
            && let Some(evidence) = self.assignment_transcript_evidence(&agent, &assignment)?
        {
            return self
                .terminalize_from_evidence(&assignment, evidence, candidate.latest_attempt.as_ref())
                .await;
        }
        if self
            .event_store
            .core_assignment_has_active_descendants(&assignment.assignment_id)
            .map_err(|error| error.to_string())?
        {
            return Ok(());
        }
        if self.assignment_turn_count(&agent, &assignment)?
            >= u32::from(assignment.limits_snapshot.max_turns)
        {
            self.fail_assignment(
                &assignment,
                TerminalAssignmentStatus::TimedOut,
                format!(
                    "assignment exhausted its maximum of {} provider turns",
                    assignment.limits_snapshot.max_turns
                ),
            )?;
            return Ok(());
        }

        let run_id = format!(
            "core-agent:{}:{}",
            assignment.assignment_id,
            uuid::Uuid::now_v7()
        );
        let Some(_reservation) = self
            .orchestrator
            .try_reserve_auxiliary_run(&agent.transcript_session_id, &run_id)
        else {
            return Ok(());
        };
        // Cancellation/offer/close may commit while the dispatcher was
        // obtaining its reservation. Storage, not the reservation, decides.
        assignment = match self
            .event_store
            .core_assignment_record(&assignment.assignment_id)
            .map_err(|error| error.to_string())?
        {
            Some(current) if !current.status.is_terminal() => current,
            _ => return Ok(()),
        };
        if assignment.status == AssignmentStatus::Waiting {
            assignment = self
                .coordination
                .reconcile_parking(&assignment.assignment_id)
                .map_err(|error| error.to_string())?;
            if assignment.status == AssignmentStatus::Waiting {
                return Ok(());
            }
        }
        let baseline = self
            .event_store
            .get_max_sequence(&agent.transcript_session_id)
            .map_err(|error| error.to_string())?;
        let claimed = match assignment.status {
            AssignmentStatus::Queued => self
                .event_store
                .claim_exact_core_assignment(&assignment.assignment_id, &run_id, baseline)
                .map_err(|error| error.to_string())?,
            AssignmentStatus::Running => self
                .event_store
                .begin_core_assignment_resume(&assignment.assignment_id, &run_id, baseline)
                .map_err(|error| error.to_string())?,
            _ => None,
        };
        let Some(claimed) = claimed else {
            return Ok(());
        };
        assignment = claimed.assignment.clone();
        if assignment.status.is_terminal() {
            return Ok(());
        }
        let session = self
            .event_store
            .get_session(&agent.transcript_session_id)
            .map_err(|error| error.to_string())?
            .ok_or_else(|| "core agent transcript disappeared".to_owned())?;
        if session.ended_at.is_some() {
            self.fail_assignment(
                &assignment,
                TerminalAssignmentStatus::Failed,
                "core agent transcript was archived".to_owned(),
            )?;
            return Ok(());
        }
        let started = match self.orchestrator.begin_run_with_admission_key(
            &agent.transcript_session_id,
            &run_id,
            Some(&run_id),
        ) {
            Ok(started) => started,
            Err(error) => {
                let _ = self.event_store.finish_core_assignment_attempt(
                    &claimed.attempt.attempt_id,
                    "interrupted",
                    Some(&format!("provider admission deferred: {error}")),
                );
                return Ok(());
            }
        };
        let mut events = self.orchestrator.subscribe();
        let causality = assignment_causality(&agent, &assignment, &session, &run_id)?;
        self.spawn_run(
            &session,
            started,
            &run_id,
            assignment.model.clone(),
            assignment.reasoning_level.clone(),
            causality,
        )?;

        let boundary = self
            .await_run_boundary(&agent, Some(&assignment), &mut events)
            .await?;
        match boundary {
            RunBoundary::AssignmentTerminal => Ok(()),
            RunBoundary::AssignmentWaiting => {
                let _ = self.event_store.finish_core_assignment_attempt(
                    &claimed.attempt.attempt_id,
                    "interrupted",
                    Some("assignment parked on a durable coordination wait"),
                );
                Ok(())
            }
            RunBoundary::Deadline => {
                let _ = self.orchestrator.abort(&agent.transcript_session_id);
                self.fail_assignment(
                    &assignment,
                    TerminalAssignmentStatus::TimedOut,
                    "assignment deadline exceeded".to_owned(),
                )
                .map(|_| ())
            }
            RunBoundary::Ended(run_error) => {
                let current = self
                    .event_store
                    .core_assignment_record(&assignment.assignment_id)
                    .map_err(|error| error.to_string())?;
                if current
                    .as_ref()
                    .is_none_or(|current| current.status.is_terminal())
                {
                    return Ok(());
                }
                if current
                    .as_ref()
                    .is_some_and(|current| current.status == AssignmentStatus::Waiting)
                {
                    let _ = self.event_store.finish_core_assignment_attempt(
                        &claimed.attempt.attempt_id,
                        "interrupted",
                        Some("assignment parked on a durable coordination wait"),
                    );
                    return Ok(());
                }
                if let Some(error) = run_error {
                    self.fail_assignment(&assignment, TerminalAssignmentStatus::Failed, error)?;
                    return Ok(());
                }
                let evidence = self
                    .assignment_transcript_evidence(&agent, &assignment)?
                    .unwrap_or(TranscriptEvidence {
                        result: None,
                        error: Some(
                            "agent run ended without a durable assistant result".to_owned(),
                        ),
                    });
                self.terminalize_from_evidence(&assignment, evidence, Some(&claimed.attempt))
                    .await
            }
            RunBoundary::RunDisappeared => {
                if let Some(evidence) = self.assignment_transcript_evidence(&agent, &assignment)? {
                    self.terminalize_from_evidence(&assignment, evidence, Some(&claimed.attempt))
                        .await
                } else {
                    let _ = self.event_store.finish_core_assignment_attempt(
                        &claimed.attempt.attempt_id,
                        "interrupted",
                        Some("agent run ended before durable terminal evidence"),
                    );
                    Ok(())
                }
            }
        }
    }

    pub(super) async fn drive_idle_wake(
        &self,
        agent: AgentRecord,
        candidate: WakeIntentRecord,
    ) -> Result<(), String> {
        let run_id = format!("core-wake:{}:{}", candidate.wake_id, uuid::Uuid::now_v7());
        let Some(_reservation) = self
            .orchestrator
            .try_reserve_auxiliary_run(&agent.transcript_session_id, &run_id)
        else {
            return Ok(());
        };
        let Some(wake) = self
            .coordination
            .lease_wake(&agent.agent_id, &run_id)
            .map_err(|error| error.to_string())?
        else {
            return Ok(());
        };
        let message_id = match self.ensure_wake_message(&wake) {
            Ok(message_id) => message_id,
            Err(error) => {
                let _ = self
                    .coordination
                    .finish_wake(&wake.wake_id, &run_id, false, Some(&error));
                return Err(error);
            }
        };
        self.event_store
            .bind_core_wake_message(&wake.wake_id, &message_id)
            .map_err(|error| error.to_string())?;
        let session = self
            .event_store
            .get_session(&agent.transcript_session_id)
            .map_err(|error| error.to_string())?
            .ok_or_else(|| "core wake transcript disappeared".to_owned())?;
        if session.ended_at.is_some() {
            let _ = self.coordination.finish_wake(
                &wake.wake_id,
                &run_id,
                false,
                Some("target transcript is archived"),
            );
            return Ok(());
        }
        let assignment = wake
            .target_assignment_id
            .as_deref()
            .map(|id| self.event_store.core_assignment_record(id))
            .transpose()
            .map_err(|error| error.to_string())?
            .flatten();
        let started = match self.orchestrator.begin_run_with_admission_key(
            &agent.transcript_session_id,
            &run_id,
            Some(&run_id),
        ) {
            Ok(started) => started,
            Err(error) => {
                let _ = self.coordination.finish_wake(
                    &wake.wake_id,
                    &run_id,
                    false,
                    Some(&error.to_string()),
                );
                return Ok(());
            }
        };
        let mut events = self.orchestrator.subscribe();
        let causality = wake_causality(&agent, assignment.as_ref(), &wake, &session, &run_id)?;
        self.spawn_run(
            &session,
            started,
            &run_id,
            assignment
                .as_ref()
                .and_then(|assignment| assignment.model.clone())
                .or_else(|| agent.defaults.model.clone()),
            assignment
                .as_ref()
                .and_then(|assignment| assignment.reasoning_level.clone())
                .or_else(|| agent.defaults.reasoning_level.clone()),
            causality,
        )?;
        let boundary = self
            .await_run_boundary(&agent, assignment.as_ref(), &mut events)
            .await?;
        let delivered = matches!(
            boundary,
            RunBoundary::Ended(None)
                | RunBoundary::AssignmentWaiting
                | RunBoundary::AssignmentTerminal
                | RunBoundary::RunDisappeared
        );
        let finish_error = (!delivered).then(|| match boundary {
            RunBoundary::Ended(Some(error)) => error,
            RunBoundary::Deadline => "assignment deadline exceeded".to_owned(),
            _ => "wake run ended before a safe provider boundary".to_owned(),
        });
        if let Err(error) = self.coordination.finish_wake(
            &wake.wake_id,
            &run_id,
            delivered,
            finish_error.as_deref(),
        ) {
            // Provider-boundary observation may have won the exact same lease
            // and committed delivery first. Only canonical delivered state is
            // accepted as that idempotent success.
            let current = self
                .event_store
                .core_wake_record(&wake.wake_id)
                .map_err(|read_error| read_error.to_string())?;
            if current
                .as_ref()
                .is_none_or(|current| current.disposition != "delivered")
            {
                return Err(error.to_string());
            }
        }
        if let Some(assignment_id) = wake.target_assignment_id.as_deref() {
            let _ = self.coordination.reconcile_parking(assignment_id);
        }
        Ok(())
    }

    fn spawn_run(
        &self,
        session: &crate::domains::session::event_store::SessionRow,
        started: crate::domains::agent::r#loop::orchestrator::core::StartedRun,
        run_id: &str,
        model: Option<String>,
        reasoning_level: Option<String>,
        causality: CausalContext,
    ) -> Result<(), String> {
        let responder_factory = self
            .responder_factory
            .clone()
            .ok_or_else(|| "agent execution has no model responder factory".to_owned())?;
        spawn_prompt_run_with_model(
            &PromptRuntimeDeps {
                orchestrator: Arc::clone(&self.orchestrator),
                session_manager: Arc::clone(&self.session_manager),
                event_store: Arc::clone(&self.event_store),
                settings: self.settings_runtime.current().settings.clone(),
                shutdown_coordinator: self.shutdown_coordinator.clone(),
                engine_host: self.engine_host.clone(),
                origin: self.origin.clone(),
            },
            responder_factory,
            session,
            started,
            run_id.to_owned(),
            model,
            PromptRequest {
                session_id: session.id.clone(),
                trigger: AgentRunTrigger::DeliveryWake {
                    delivery_ids: Vec::new(),
                },
                reasoning_level,
                attachments: None,
                user_event_metadata: None,
                engine_causality: Some(PromptEngineCausality::core_agent(causality, run_id)),
            },
        );
        Ok(())
    }

    async fn await_run_boundary(
        &self,
        agent: &AgentRecord,
        assignment: Option<&AssignmentRecord>,
        events: &mut tokio::sync::broadcast::Receiver<TronEvent>,
    ) -> Result<RunBoundary, String> {
        loop {
            if let Some(assignment) = assignment {
                let current = self
                    .event_store
                    .core_assignment_record(&assignment.assignment_id)
                    .map_err(|error| error.to_string())?;
                let Some(current) = current else {
                    let _ = self.orchestrator.abort(&agent.transcript_session_id);
                    return Ok(RunBoundary::AssignmentTerminal);
                };
                if current.status.is_terminal() {
                    let _ = self.orchestrator.abort(&agent.transcript_session_id);
                    return Ok(RunBoundary::AssignmentTerminal);
                }
                if current.status == AssignmentStatus::Waiting {
                    return Ok(RunBoundary::AssignmentWaiting);
                }
                if deadline_reached(current.deadline_at.as_deref()) {
                    return Ok(RunBoundary::Deadline);
                }
            }
            match tokio::time::timeout(Duration::from_millis(500), events.recv()).await {
                Ok(Ok(TronEvent::AgentEnd { base, error, .. }))
                    if base.session_id == agent.transcript_session_id =>
                {
                    return Ok(RunBoundary::Ended(error));
                }
                Ok(Ok(_))
                | Err(_)
                | Ok(Err(tokio::sync::broadcast::error::RecvError::Lagged(_))) => {
                    if !self
                        .orchestrator
                        .has_pending_or_active_run(&agent.transcript_session_id)
                    {
                        return Ok(RunBoundary::RunDisappeared);
                    }
                }
                Ok(Err(tokio::sync::broadcast::error::RecvError::Closed)) => {
                    return Err("agent event stream closed during core execution".to_owned());
                }
            }
        }
    }

    fn assignment_transcript_evidence(
        &self,
        agent: &AgentRecord,
        assignment: &AssignmentRecord,
    ) -> Result<Option<TranscriptEvidence>, String> {
        let Some(attempt) = self
            .event_store
            .latest_core_assignment_attempt(&assignment.assignment_id)
            .map_err(|error| error.to_string())?
        else {
            return Ok(None);
        };
        let rows = self
            .event_store
            .get_events_since(
                &agent.transcript_session_id,
                attempt.baseline_event_sequence,
            )
            .map_err(|error| error.to_string())?;
        let payloads = self
            .event_store
            .resolve_event_payloads(&rows)
            .map_err(|error| error.to_string())?;
        let mut failure = None;
        let mut assistant = None;
        for (row, payload) in rows.iter().zip(payloads) {
            if matches!(row.event_type.as_str(), "turn.failed" | "message.assistant")
                && payload.get("agentAssignmentId").and_then(Value::as_str)
                    != Some(assignment.assignment_id.as_str())
            {
                continue;
            }
            if row.event_type == "turn.failed" {
                failure = Some(
                    payload
                        .get("failure")
                        .and_then(|value| value.get("message"))
                        .and_then(Value::as_str)
                        .unwrap_or("agent assignment turn failed")
                        .to_owned(),
                );
            } else if row.event_type == "message.assistant"
                && payload.get("stopReason").and_then(Value::as_str) != Some("tool_invocation")
            {
                assistant = Some(normalize_agent_output(
                    payload.get("content").cloned().unwrap_or(payload),
                ));
                failure = None;
            }
        }
        Ok(if let Some(error) = failure {
            Some(TranscriptEvidence {
                result: None,
                error: Some(error),
            })
        } else {
            assistant.map(|result| TranscriptEvidence {
                result: Some(result),
                error: None,
            })
        })
    }

    fn assignment_turn_count(
        &self,
        agent: &AgentRecord,
        assignment: &AssignmentRecord,
    ) -> Result<u32, String> {
        let rows = self
            .event_store
            .get_events_since(&agent.transcript_session_id, 0)
            .map_err(|error| error.to_string())?;
        let payloads = self
            .event_store
            .resolve_event_payloads(&rows)
            .map_err(|error| error.to_string())?;
        Ok(u32::try_from(
            rows.iter()
                .zip(payloads)
                .filter(|(row, payload)| {
                    row.event_type == "message.assistant"
                        && payload.get("agentAssignmentId").and_then(Value::as_str)
                            == Some(assignment.assignment_id.as_str())
                })
                .count(),
        )
        .unwrap_or(u32::MAX))
    }

    async fn terminalize_from_evidence(
        &self,
        assignment: &AssignmentRecord,
        evidence: TranscriptEvidence,
        attempt: Option<&crate::domains::agent::coordination::AssignmentAttemptRecord>,
    ) -> Result<(), String> {
        if self
            .event_store
            .core_assignment_has_active_descendants(&assignment.assignment_id)
            .map_err(|error| error.to_string())?
        {
            if let Some(attempt) = attempt {
                let _ = self.event_store.finish_core_assignment_attempt(
                    &attempt.attempt_id,
                    "interrupted",
                    Some("structured join is waiting for active descendants"),
                );
            }
            return Ok(());
        }
        if let Some(error) = evidence.error {
            self.fail_assignment(assignment, TerminalAssignmentStatus::Failed, error)?;
        } else if let Some(result) = evidence.result {
            self.coordination
                .complete(&CompleteAssignment {
                    assignment_id: assignment.assignment_id.clone(),
                    terminal_status: TerminalAssignmentStatus::Completed,
                    payload: Some(result),
                    error: None,
                })
                .map_err(|error| error.to_string())?;
        } else {
            self.fail_assignment(
                assignment,
                TerminalAssignmentStatus::Failed,
                "agent assignment ended without a durable result".to_owned(),
            )?;
        }
        self.notify();
        Ok(())
    }

    fn fail_assignment(
        &self,
        assignment: &AssignmentRecord,
        status: TerminalAssignmentStatus,
        error: String,
    ) -> Result<(), String> {
        self.coordination
            .complete(&CompleteAssignment {
                assignment_id: assignment.assignment_id.clone(),
                terminal_status: status,
                payload: None,
                error: Some(error),
            })
            .map_err(|failure| failure.to_string())?;
        self.notify();
        Ok(())
    }
}

fn assignment_causality(
    agent: &AgentRecord,
    assignment: &AssignmentRecord,
    session: &crate::domains::session::event_store::SessionRow,
    run_id: &str,
) -> Result<CausalContext, String> {
    base_causality(
        agent,
        session,
        &assignment.trace_id,
        assignment.autonomous_hop,
        run_id,
    )
    .map(|context| {
        context
            .with_agent_assignment(&agent.agent_id, &assignment.assignment_id)
            .with_delegated_function_grant(function_grant(&assignment.capability_snapshot))
            .with_agent_limits(json!({
                "maxTurns":assignment.limits_snapshot.max_turns,
                "timeoutSeconds":assignment.limits_snapshot.timeout_seconds,
                "maxQueuedAssignments":assignment.limits_snapshot.max_queued_assignments,
            }))
            .with_agent_write_scopes(assignment.write_scopes_snapshot.clone())
            .with_trigger_depth(u32::from(assignment.causal_depth))
    })
}

fn wake_causality(
    agent: &AgentRecord,
    assignment: Option<&AssignmentRecord>,
    wake: &WakeIntentRecord,
    session: &crate::domains::session::event_store::SessionRow,
    run_id: &str,
) -> Result<CausalContext, String> {
    let context = base_causality(agent, session, &wake.trace_id, wake.autonomous_hop, run_id)?;
    Ok(if let Some(assignment) = assignment {
        context
            .with_agent_assignment(&agent.agent_id, &assignment.assignment_id)
            .with_delegated_function_grant(function_grant(&assignment.capability_snapshot))
            .with_agent_limits(json!({
                "maxTurns":assignment.limits_snapshot.max_turns,
                "timeoutSeconds":assignment.limits_snapshot.timeout_seconds,
                "maxQueuedAssignments":assignment.limits_snapshot.max_queued_assignments,
            }))
            .with_agent_write_scopes(assignment.write_scopes_snapshot.clone())
            .with_trigger_depth(u32::from(assignment.causal_depth))
    } else {
        context
            .with_agent_identity(&agent.agent_id)
            .with_delegated_function_grant(function_grant(&agent.defaults.capability_grant))
            .with_agent_limits(json!({
                "maxTurns":agent.defaults.limits.max_turns,
                "timeoutSeconds":agent.defaults.limits.timeout_seconds,
                "maxQueuedAssignments":agent.defaults.limits.max_queued_assignments,
            }))
            .with_agent_write_scopes(agent.defaults.write_scopes.clone())
    })
}

fn base_causality(
    agent: &AgentRecord,
    session: &crate::domains::session::event_store::SessionRow,
    trace_id: &str,
    autonomous_hop: u32,
    run_id: &str,
) -> Result<CausalContext, String> {
    Ok(CausalContext::new(
        ActorId::new(format!("agent:{}", agent.agent_id)).map_err(|error| error.to_string())?,
        ActorKind::Agent,
        TraceId::new(trace_id.to_owned()).map_err(|error| error.to_string())?,
    )
    .with_session_id(session.id.clone())
    .with_workspace_id(session.workspace_id.clone())
    .with_working_directory(session.working_directory.clone())
    .with_autonomous_wake_hop(autonomous_hop)
    .with_idempotency_key(format!("core-agent-run:{run_id}")))
}

fn function_grant(snapshot: &Value) -> Vec<String> {
    let values = snapshot.as_array().or_else(|| {
        snapshot
            .as_object()
            .and_then(|object| object.get("functions"))
            .and_then(Value::as_array)
    });
    values
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(ToOwned::to_owned)
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect()
}

fn deadline_reached(deadline: Option<&str>) -> bool {
    deadline
        .and_then(|value| chrono::DateTime::parse_from_rfc3339(value).ok())
        .is_some_and(|deadline| chrono::Utc::now() >= deadline.with_timezone(&chrono::Utc))
}

fn normalize_agent_output(value: Value) -> Value {
    match value {
        Value::Array(items) => {
            let text = items
                .iter()
                .filter_map(|item| item.get("text").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join("\n");
            if text.is_empty() {
                Value::Array(items)
            } else {
                Value::String(text)
            }
        }
        other => other,
    }
}
