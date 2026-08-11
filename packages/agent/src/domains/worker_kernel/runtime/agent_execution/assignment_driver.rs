//! FIFO reusable-assignment dispatch, execution, recovery, and terminalization.
//!
//! Fresh work and recovery use independent bounded lanes while one agent
//! executes at most one assignment at a time.

use super::super::*;

use crate::domains::session::event_store::{
    AgentDeliveryBoundary, AgentDeliverySourceKind, AgentDeliveryTarget, AgentDeliveryWakePolicy,
    NewAgentDelivery,
};
use crate::domains::worker_kernel::persistence::{
    AgentAssignmentRecord, AgentAssignmentStatus, AgentAssignmentTransition, AgentInstanceRecord,
};
use crate::shared::protocol::events::TronEvent;

const MAX_AGENT_ASSIGNMENTS: usize = 128;

struct AssignmentTranscriptEvidence {
    result: Option<Value>,
    error: Option<String>,
}

impl WorkerRuntime {
    pub(in crate::domains::worker_kernel::runtime) async fn dispatch_agent_assignments(
        self: &Arc<Self>,
        runs: &mut JoinSet<()>,
    ) {
        // Fresh FIFO work and active recovery have independent bounded lanes.
        // A profile with many parked/running assignments must not make a later
        // queued head invisible to the dispatcher (or vice versa). Scan past
        // process-local owners rather than letting an in-flight first page
        // consume the durable selection budget.
        let mut runnable_offset = 0;
        let mut runnable_started = 0;
        loop {
            let Ok(page) = self
                .store
                .list_runnable_agent_assignments_page(MAX_AGENT_ASSIGNMENTS, runnable_offset)
            else {
                return;
            };
            let page_len = page.len();
            for assignment in page {
                runnable_started +=
                    usize::from(self.start_agent_assignment_driver(runs, assignment));
                if runnable_started >= MAX_AGENT_ASSIGNMENTS {
                    break;
                }
            }
            if runnable_started >= MAX_AGENT_ASSIGNMENTS || page_len < MAX_AGENT_ASSIGNMENTS {
                break;
            }
            runnable_offset = runnable_offset.saturating_add(page_len);
        }

        let mut recovery_offset = 0;
        let mut recoveries_started = 0;
        loop {
            let Ok(page) = self
                .store
                .list_recoverable_agent_assignments_page(MAX_AGENT_ASSIGNMENTS, recovery_offset)
            else {
                return;
            };
            let page_len = page.len();
            for assignment in page {
                recoveries_started +=
                    usize::from(self.start_agent_assignment_driver(runs, assignment));
                if recoveries_started >= MAX_AGENT_ASSIGNMENTS {
                    break;
                }
            }
            if recoveries_started >= MAX_AGENT_ASSIGNMENTS || page_len < MAX_AGENT_ASSIGNMENTS {
                break;
            }
            recovery_offset = recovery_offset.saturating_add(page_len);
        }
    }

    fn start_agent_assignment_driver(
        self: &Arc<Self>,
        runs: &mut JoinSet<()>,
        assignment: AgentAssignmentRecord,
    ) -> bool {
        if self
            .agent_assignment_inflight
            .contains(&assignment.assignment_id)
        {
            return false;
        }
        if matches!(
            assignment.status,
            AgentAssignmentStatus::Accepted
                | AgentAssignmentStatus::Queued
                | AgentAssignmentStatus::Waiting
        ) && self
            .store
            .agent_instance(&assignment.agent_id)
            .ok()
            .flatten()
            .is_some_and(|agent| self.orchestrator.has_active_run(&agent.session_id))
        {
            return false;
        }
        if assignment.status == AgentAssignmentStatus::Waiting {
            match self.assignment_has_pending_join(&assignment) {
                Ok(true) => return false,
                Ok(false) => {}
                Err(error) => {
                    tracing::warn!(
                        assignment_id = assignment.assignment_id,
                        error = %error,
                        "reusable-agent waiting assignment preflight will retry"
                    );
                    return false;
                }
            }
        }
        if matches!(
            assignment.status,
            AgentAssignmentStatus::Accepted | AgentAssignmentStatus::Queued
        ) && self
            .store
            .next_queued_agent_assignment(&assignment.agent_id)
            .ok()
            .flatten()
            .is_none_or(|next| next.assignment_id != assignment.assignment_id)
        {
            return false;
        }
        if !self
            .agent_assignment_inflight
            .insert(assignment.assignment_id.clone())
        {
            return false;
        }
        let runtime = Arc::clone(self);
        runs.spawn(async move {
            let assignment_id = assignment.assignment_id.clone();
            if let Err(error) = runtime.drive_agent_assignment(assignment).await {
                tracing::error!(assignment_id, error = %error, "reusable-agent assignment driver failed");
            }
            runtime.agent_assignment_inflight.remove(&assignment_id);
        });
        true
    }

    /// Enforce immutable wall-clock deadlines independently of runnable/paused
    /// scheduling. Descendants are cancelled first, then the exact transcript
    /// run is aborted and the due assignment terminalizes through the ordinary
    /// result-outbox path.
    pub(in crate::domains::worker_kernel::runtime) async fn expire_due_agent_assignments(
        &self,
    ) -> Result<usize, String> {
        let due = self
            .store
            .list_due_agent_assignments(&chrono::Utc::now().to_rfc3339(), MAX_AGENT_ASSIGNMENTS)?;
        let mut expired = 0;
        for due_assignment in due {
            let Some(current) = self.store.agent_assignment(&due_assignment.assignment_id)? else {
                continue;
            };
            if current.status.is_terminal() {
                continue;
            }
            let subtree = self.store.execution_subtree(&current.execution_id)?;
            let direct_children = subtree
                .iter()
                .filter(|node| node.parent_execution_id.as_deref() == Some(&current.execution_id))
                .map(|node| node.execution_id.clone())
                .collect::<Vec<_>>();
            for child_execution_id in direct_children {
                self.cancel_execution_tree(&child_execution_id).await?;
            }
            if matches!(
                current.status,
                AgentAssignmentStatus::Running | AgentAssignmentStatus::Waiting
            ) && let Some(agent) = self.store.agent_instance(&current.agent_id)?
            {
                let _ = self.orchestrator.abort(&agent.session_id);
                self.event_store
                    .cancel_coordination_waits_for_assignment(&current.assignment_id)
                    .map_err(|error| error.to_string())?;
                if let Some(attempt) = self
                    .store
                    .list_agent_assignment_attempts(&current.assignment_id, 1)?
                    .into_iter()
                    .find(|attempt| attempt.status == "running")
                {
                    self.store.finish_agent_assignment_attempt(
                        &attempt.attempt_id,
                        "interrupted",
                        Some("assignment deadline exceeded"),
                    )?;
                }
            }
            let Some(current) = self.store.agent_assignment(&current.assignment_id)? else {
                continue;
            };
            if current.status.is_terminal() {
                continue;
            }
            let target_status = if current.status == AgentAssignmentStatus::Offered {
                AgentAssignmentStatus::Expired
            } else {
                AgentAssignmentStatus::TimedOut
            };
            self.store
                .transition_agent_assignment(&AgentAssignmentTransition {
                    assignment_id: current.assignment_id,
                    expected_status: current.status,
                    target_status,
                    result: None,
                    error: Some("assignment deadline exceeded".to_owned()),
                })?;
            expired += 1;
        }
        Ok(expired)
    }

    pub(in crate::domains::worker_kernel::runtime) async fn drive_agent_assignment(
        &self,
        mut assignment: AgentAssignmentRecord,
    ) -> Result<(), String> {
        let agent = self
            .store
            .agent_instance(&assignment.agent_id)?
            .ok_or_else(|| format!("assignment agent '{}' was not found", assignment.agent_id))?;
        if matches!(
            assignment.status,
            AgentAssignmentStatus::Accepted
                | AgentAssignmentStatus::Queued
                | AgentAssignmentStatus::Waiting
        ) && self.orchestrator.has_active_run(&agent.session_id)
        {
            // An operator instruction, peer question, or the tail of the
            // parking tool run can own this transcript temporarily. Starting
            // the next assignment attempt now would let that auxiliary
            // AgentEnd/result masquerade as assignment evidence. Retry after
            // the safe run boundary so the new attempt baseline excludes it.
            return Ok(());
        }
        if matches!(
            assignment.status,
            AgentAssignmentStatus::Accepted | AgentAssignmentStatus::Queued
        ) && self
            .event_store
            .agent_assignment_admission_message_id(&agent.session_id, &assignment.assignment_id)
            .map_err(|error| error.to_string())?
            .is_none()
        {
            // The workers.sqlite admission and its outbox are durable, but the
            // cross-store semantic message has not imported yet. Keeping the
            // assignment queued lets the importer finish without ever opening
            // a provider turn that lacks its canonical task instruction.
            return Ok(());
        }
        if let Some(evidence) = self.assignment_transcript_evidence(&agent, &assignment)?
            && evidence.result.is_some()
        {
            if assignment.status == AgentAssignmentStatus::Waiting {
                assignment =
                    self.store
                        .transition_agent_assignment(&AgentAssignmentTransition {
                            assignment_id: assignment.assignment_id.clone(),
                            expected_status: AgentAssignmentStatus::Waiting,
                            target_status: AgentAssignmentStatus::Running,
                            result: None,
                            error: None,
                        })?;
            } else if matches!(
                assignment.status,
                AgentAssignmentStatus::Accepted | AgentAssignmentStatus::Queued
            ) {
                assignment =
                    self.store
                        .transition_agent_assignment(&AgentAssignmentTransition {
                            assignment_id: assignment.assignment_id.clone(),
                            expected_status: assignment.status,
                            target_status: AgentAssignmentStatus::Running,
                            result: None,
                            error: None,
                        })?;
            }
            return self
                .terminalize_agent_assignment(&agent, &assignment, evidence)
                .await;
        }
        if assignment.status == AgentAssignmentStatus::Waiting {
            if self.assignment_has_pending_join(&assignment)? {
                return Ok(());
            }
            assignment = self
                .store
                .transition_agent_assignment(&AgentAssignmentTransition {
                    assignment_id: assignment.assignment_id.clone(),
                    expected_status: AgentAssignmentStatus::Waiting,
                    target_status: AgentAssignmentStatus::Running,
                    result: None,
                    error: None,
                })?;
        } else if matches!(
            assignment.status,
            AgentAssignmentStatus::Accepted | AgentAssignmentStatus::Queued
        ) {
            let active_other = self
                .store
                .list_agent_assignments(&assignment.agent_id, MAX_AGENT_ASSIGNMENTS)?
                .into_iter()
                .any(|candidate| {
                    candidate.assignment_id != assignment.assignment_id
                        && matches!(
                            candidate.status,
                            AgentAssignmentStatus::Running | AgentAssignmentStatus::Waiting
                        )
                });
            if active_other {
                return Ok(());
            }
            assignment = self
                .store
                .transition_agent_assignment(&AgentAssignmentTransition {
                    assignment_id: assignment.assignment_id.clone(),
                    expected_status: assignment.status,
                    target_status: AgentAssignmentStatus::Running,
                    result: None,
                    error: None,
                })?;
        }
        if assignment.status != AgentAssignmentStatus::Running {
            return Ok(());
        }
        let max_turns = assignment
            .limits_snapshot
            .get("maxAssignmentTurns")
            .and_then(Value::as_u64)
            .and_then(|value| u32::try_from(value).ok())
            .unwrap_or(32);
        if self.assignment_turn_count(&agent, &assignment)? >= max_turns {
            self.store
                .transition_agent_assignment(&AgentAssignmentTransition {
                    assignment_id: assignment.assignment_id.clone(),
                    expected_status: AgentAssignmentStatus::Running,
                    target_status: AgentAssignmentStatus::TimedOut,
                    result: None,
                    error: Some(format!(
                        "assignment exhausted its maximum of {max_turns} provider turns"
                    )),
                })?;
            return Ok(());
        }
        let baseline_event_sequence = self
            .event_store
            .get_latest_events(&agent.session_id, Some(1))
            .map_err(|error| error.to_string())?
            .last()
            .map_or(0, |event| event.sequence);
        let attempt = self.store.begin_agent_assignment_attempt(
            &assignment.assignment_id,
            None,
            baseline_event_sequence,
        )?;
        let mut events = self.orchestrator.subscribe();
        self.ensure_assignment_wake(&agent, &assignment, attempt.attempt_number)
            .await?;
        let progress_worker_invocation_id = (agent.kind
            == crate::domains::worker_kernel::persistence::AgentInstanceKind::DirectWorker)
            .then(|| self.store.execution_node(&assignment.execution_id))
            .transpose()?
            .flatten()
            .and_then(|node| node.worker_invocation_id);
        let deadline = assignment
            .deadline_at
            .as_deref()
            .and_then(|value| chrono::DateTime::parse_from_rfc3339(value).ok())
            .map(|value| value.with_timezone(&chrono::Utc));
        loop {
            if self
                .store
                .agent_assignment(&assignment.assignment_id)?
                .is_none_or(|record| record.status.is_terminal())
            {
                return Ok(());
            }
            if deadline.is_some_and(|value| chrono::Utc::now() >= value) {
                let _ = self.orchestrator.abort(&agent.session_id);
                self.store.finish_agent_assignment_attempt(
                    &attempt.attempt_id,
                    "failed",
                    Some("assignment deadline exceeded"),
                )?;
                self.store
                    .transition_agent_assignment(&AgentAssignmentTransition {
                        assignment_id: assignment.assignment_id.clone(),
                        expected_status: AgentAssignmentStatus::Running,
                        target_status: AgentAssignmentStatus::TimedOut,
                        result: None,
                        error: Some("assignment deadline exceeded".to_owned()),
                    })?;
                return Ok(());
            }
            let received = tokio::time::timeout(Duration::from_secs(1), events.recv()).await;
            if let Ok(Ok(event)) = &received
                && event.session_id() == agent.session_id
                && let Some(worker_invocation_id) = progress_worker_invocation_id.as_deref()
            {
                self.observe_agent_model_tool_progress(worker_invocation_id, event);
            }
            match received {
                Ok(Ok(TronEvent::AgentEnd { base, error, .. }))
                    if base.session_id == agent.session_id =>
                {
                    let Some(current) = self.store.agent_assignment(&assignment.assignment_id)?
                    else {
                        return Ok(());
                    };
                    // `agent_wait` parks by committing Running -> Waiting
                    // before its tool result ends the provider run. AgentEnd is
                    // therefore attempt suspension, not assignment completion.
                    if current.status == AgentAssignmentStatus::Waiting {
                        self.store.finish_agent_assignment_attempt(
                            &attempt.attempt_id,
                            "waiting",
                            None,
                        )?;
                        return Ok(());
                    }
                    if current.status.is_terminal() {
                        let attempt_status = match current.status {
                            AgentAssignmentStatus::Completed => "completed",
                            AgentAssignmentStatus::Cancelled => "interrupted",
                            _ => "failed",
                        };
                        self.store.finish_agent_assignment_attempt(
                            &attempt.attempt_id,
                            attempt_status,
                            current.error.as_deref(),
                        )?;
                        return Ok(());
                    }
                    if let Some(error) = error {
                        let exhausted =
                            self.assignment_turn_count(&agent, &assignment)? >= max_turns;
                        self.store.finish_agent_assignment_attempt(
                            &attempt.attempt_id,
                            "failed",
                            Some(&error),
                        )?;
                        self.store
                            .transition_agent_assignment(&AgentAssignmentTransition {
                                assignment_id: assignment.assignment_id.clone(),
                                expected_status: AgentAssignmentStatus::Running,
                                target_status: if exhausted {
                                    AgentAssignmentStatus::TimedOut
                                } else {
                                    AgentAssignmentStatus::Failed
                                },
                                result: None,
                                error: Some(error),
                            })?;
                        return Ok(());
                    }
                    let evidence = self
                        .assignment_transcript_evidence(&agent, &assignment)?
                        .unwrap_or(AssignmentTranscriptEvidence {
                            result: None,
                            error: Some(
                                "agent run ended without a durable assistant result".to_owned(),
                            ),
                        });
                    self.store.finish_agent_assignment_attempt(
                        &attempt.attempt_id,
                        if evidence.error.is_some() {
                            "failed"
                        } else {
                            "completed"
                        },
                        evidence.error.as_deref(),
                    )?;
                    return self
                        .terminalize_agent_assignment(&agent, &assignment, evidence)
                        .await;
                }
                Ok(Ok(_)) | Err(_) => {
                    if !self.orchestrator.has_active_run(&agent.session_id) {
                        if self
                            .store
                            .agent_assignment(&assignment.assignment_id)?
                            .is_some_and(|current| current.status == AgentAssignmentStatus::Waiting)
                        {
                            self.store.finish_agent_assignment_attempt(
                                &attempt.attempt_id,
                                "waiting",
                                None,
                            )?;
                            return Ok(());
                        }
                    }
                    if !self.orchestrator.has_active_run(&agent.session_id)
                        && let Some(evidence) =
                            self.assignment_transcript_evidence(&agent, &assignment)?
                    {
                        self.store.finish_agent_assignment_attempt(
                            &attempt.attempt_id,
                            if evidence.error.is_some() {
                                "failed"
                            } else {
                                "completed"
                            },
                            evidence.error.as_deref(),
                        )?;
                        return self
                            .terminalize_agent_assignment(&agent, &assignment, evidence)
                            .await;
                    }
                }
                Ok(Err(tokio::sync::broadcast::error::RecvError::Lagged(_))) => {}
                Ok(Err(tokio::sync::broadcast::error::RecvError::Closed)) => {
                    return Err("agent event stream closed during assignment".to_owned());
                }
            }
        }
    }

    async fn ensure_assignment_wake(
        &self,
        agent: &AgentInstanceRecord,
        assignment: &AgentAssignmentRecord,
        attempt_number: u32,
    ) -> Result<(), String> {
        let admission_message_id = self
            .event_store
            .agent_assignment_admission_message_id(&agent.session_id, &assignment.assignment_id)
            .map_err(|error| error.to_string())?
            .ok_or_else(|| {
                format!(
                    "assignment '{}' has no imported admission message",
                    assignment.assignment_id
                )
            })?;
        let activated_admission = self
            .event_store
            .activate_agent_assignment_message_delivery(
                &agent.session_id,
                &assignment.assignment_id,
                &admission_message_id,
            )
            .map_err(|error| error.to_string())?;
        if !self.orchestrator.has_active_run(&agent.session_id)
            && activated_admission.is_none()
            && self
                .event_store
                .pending_agent_wakes_for_session(&agent.session_id, 1)
                .map_err(|error| error.to_string())?
                .is_empty()
        {
            let source = assignment
                .requester_agent_id
                .as_deref()
                .and_then(|id| self.store.agent_instance(id).ok().flatten())
                .unwrap_or_else(|| agent.clone());
            let source_session = self
                .event_store
                .get_session(&source.session_id)
                .map_err(|error| error.to_string())?
                .ok_or_else(|| "assignment resume source session disappeared".to_owned())?;
            self.event_store
                .create_agent_delivery(&NewAgentDelivery {
                    idempotency_key: format!(
                        "agent-assignment-resume:{}:{attempt_number}",
                        assignment.assignment_id
                    ),
                    source_kind: AgentDeliverySourceKind::Continuity,
                    intent: None,
                    source_session_id: Some(source.session_id),
                    source_workspace_id: source_session.workspace_id,
                    source_invocation_id: None,
                    source_trace_id: self
                        .store
                        .execution_node(&assignment.execution_id)?
                        .map(|node| node.trace_id),
                    source_root_invocation_id: Some(assignment.execution_id.clone()),
                    causal_depth: self
                        .store
                        .execution_node(&assignment.execution_id)?
                        .map_or(0, |node| node.causal_depth),
                    target: AgentDeliveryTarget::Session {
                        session_id: agent.session_id.clone(),
                    },
                    wake_policy: AgentDeliveryWakePolicy::Wake,
                    boundary: AgentDeliveryBoundary::NextTurn,
                    originating_run_id: None,
                    arrived_during_run_id: None,
                    defer_until_run_id: None,
                    result_invocation_id: None,
                    content: json!({
                        "kind":"agent_assignment_resume",
                        "assignmentId":assignment.assignment_id,
                        "attempt":attempt_number,
                    })
                    .to_string(),
                    not_before: None,
                    expires_at: assignment.deadline_at.clone(),
                })
                .map_err(|error| error.to_string())?;
        }
        self.request_agent_delivery_wake(
            &agent.session_id,
            self.store
                .execution_node(&assignment.execution_id)?
                .map_or(0, |node| node.causal_depth),
        )
        .await;
        Ok(())
    }

    fn assignment_transcript_evidence(
        &self,
        agent: &AgentInstanceRecord,
        assignment: &AgentAssignmentRecord,
    ) -> Result<Option<AssignmentTranscriptEvidence>, String> {
        let latest_attempt = self
            .store
            .list_agent_assignment_attempts(&assignment.assignment_id, 1)?
            .into_iter()
            .next();
        let Some(attempt) = latest_attempt.filter(|attempt| {
            matches!(
                attempt.status.as_str(),
                "running" | "interrupted" | "completed"
            )
        }) else {
            return Ok(None);
        };
        let rows = self
            .event_store
            .get_events_since(&agent.session_id, attempt.baseline_event_sequence)
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
            }
            if row.event_type == "message.assistant"
                && payload.get("stopReason").and_then(Value::as_str) != Some("tool_invocation")
            {
                assistant = Some(normalize_agent_output(
                    payload.get("content").cloned().unwrap_or(payload),
                ));
                failure = None;
            }
        }
        if let Some(error) = failure {
            Ok(Some(AssignmentTranscriptEvidence {
                result: None,
                error: Some(error),
            }))
        } else if let Some(result) = assistant {
            Ok(Some(AssignmentTranscriptEvidence {
                result: Some(result),
                error: None,
            }))
        } else {
            Ok(None)
        }
    }

    pub(in crate::domains::worker_kernel::runtime) fn assignment_turn_count(
        &self,
        agent: &AgentInstanceRecord,
        assignment: &AgentAssignmentRecord,
    ) -> Result<u32, String> {
        let rows = self
            .event_store
            .get_events_since(&agent.session_id, 0)
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

    pub(super) fn assignment_autonomous_hop(
        &self,
        assignment: &AgentAssignmentRecord,
    ) -> Result<u32, String> {
        self.event_store
            .max_agent_message_autonomous_hop(&assignment.assignment_id)
            .map_err(|error| error.to_string())
    }

    fn assignment_has_pending_join(
        &self,
        assignment: &AgentAssignmentRecord,
    ) -> Result<bool, String> {
        let wait_pending = self
            .event_store
            .has_pending_coordination_wait_for_assignment(&assignment.assignment_id)
            .map_err(|error| error.to_string())?;
        if wait_pending {
            return Ok(true);
        }
        Ok(self
            .store
            .execution_subtree(&assignment.execution_id)?
            .into_iter()
            .skip(1)
            .any(|node| {
                node.assignment_id
                    .as_deref()
                    .and_then(|id| self.store.agent_assignment(id).ok().flatten())
                    .is_some_and(|child| !child.status.is_terminal())
                    || node
                        .worker_invocation_id
                        .as_deref()
                        .and_then(|id| self.store.invocation(id).ok().flatten())
                        .is_some_and(|child| matches!(child.status.as_str(), "queued" | "running"))
            }))
    }

    async fn terminalize_agent_assignment(
        &self,
        agent: &AgentInstanceRecord,
        assignment: &AgentAssignmentRecord,
        evidence: AssignmentTranscriptEvidence,
    ) -> Result<(), String> {
        if self.assignment_has_pending_join(assignment)? {
            self.store
                .transition_agent_assignment(&AgentAssignmentTransition {
                    assignment_id: assignment.assignment_id.clone(),
                    expected_status: AgentAssignmentStatus::Running,
                    target_status: AgentAssignmentStatus::Waiting,
                    result: None,
                    error: None,
                })?;
            return Ok(());
        }
        let (mut status, mut result, mut error) = if let Some(error) = evidence.error {
            (AgentAssignmentStatus::Failed, None, Some(error))
        } else if let Some(result) = evidence.result {
            (AgentAssignmentStatus::Completed, Some(result), None)
        } else {
            (
                AgentAssignmentStatus::Failed,
                None,
                Some("agent assignment ended without a durable result".to_owned()),
            )
        };
        if status == AgentAssignmentStatus::Completed
            && assignment
                .context
                .get("roleResult")
                .and_then(|value| value.get("mode"))
                .and_then(Value::as_str)
                == Some("schema")
        {
            let schema = assignment
                .context
                .get("roleResult")
                .and_then(|value| value.get("schema"))
                .ok_or_else(|| {
                    "schema-mode agent role lost its immutable result schema".to_owned()
                })?;
            let function_id = FunctionId::new("worker_kernel::agent_role_result")
                .map_err(|failure| failure.to_string())?;
            if let Some(candidate) = result.as_ref()
                && let Err(failure) = crate::engine::validate_engine_schema_payload(
                    &function_id,
                    "response",
                    schema,
                    candidate,
                )
            {
                status = AgentAssignmentStatus::Failed;
                result = None;
                error = Some(format!(
                    "agent role result did not match its pinned immutable schema: {failure}"
                ));
            }
        }
        self.store
            .transition_agent_assignment(&AgentAssignmentTransition {
                assignment_id: assignment.assignment_id.clone(),
                expected_status: AgentAssignmentStatus::Running,
                target_status: status,
                result,
                error,
            })?;
        self.delivery_maintenance.notify_one();
        self.publish_agent_invalidation(
            "agent.assignment",
            &agent.root_session_id,
            json!({
                "action":"terminal",
                "agentId":agent.agent_id,
                "assignmentId":assignment.assignment_id,
                "status":status.as_str(),
            }),
            &assignment.execution_id,
        )
        .await;
        Ok(())
    }
}
