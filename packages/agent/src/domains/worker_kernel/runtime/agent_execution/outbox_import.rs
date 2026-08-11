//! Idempotent cross-store coordination outbox importer.
//!
//! Provisioning and semantic admission effects are acknowledged only after
//! their canonical EventStore mutation is durable.

use super::super::*;
use super::support::*;

use crate::domains::session::event_store::{
    CoordinationTargetKind, CoordinationTerminalEvidence, CoordinationWaitTarget, EventIdentity,
    SessionCreationIdentity, SessionIdentity, WorkspaceIdentity,
};
use crate::domains::worker_kernel::persistence::{
    AgentAssignmentRecord, AgentAssignmentStatus, AgentAssignmentTransition, AgentInstanceRecord,
    AgentOutboxKind, AgentOutboxRecord,
};
use crate::shared::protocol::messages::{AgentMessageContent, AgentMessageKind};

const MAX_AGENT_OUTBOX_BATCH: usize = 128;

impl WorkerRuntime {
    /// Import every currently pending coordination outbox effect. Callers may
    /// invoke this as a synchronous post-admission fast path; the dispatcher
    /// invokes the same method after restart and on every maintenance tick.
    pub(in crate::domains::worker_kernel::runtime) async fn import_agent_coordination_outbox(
        &self,
    ) -> Result<(), String> {
        let rows = self.store.pending_agent_outbox(MAX_AGENT_OUTBOX_BATCH)?;
        let mut first_error = None;
        for row in rows {
            if !self.store.mark_agent_outbox_importing(&row.outbox_id)? {
                continue;
            }
            let import_lag_seconds = elapsed_rfc3339_seconds(&row.created_at);
            if row.kind == AgentOutboxKind::Message {
                metrics::counter!(
                    "agent_coordination_message_delivery_attempts_total",
                    "attempt" => if row.attempts == 0 { "initial" } else { "redelivery" }
                )
                .increment(1);
            }
            let import = match self.import_agent_outbox_row(&row).await {
                Ok(()) => self.store.mark_agent_outbox_imported(&row.outbox_id),
                Err(error) => Err(error),
            };
            match import {
                Ok(()) => {
                    metrics::counter!(
                        "agent_coordination_outbox_imports_total",
                        "kind" => row.kind.as_str(),
                        "outcome" => "imported"
                    )
                    .increment(1);
                    metrics::histogram!(
                        "agent_coordination_outbox_import_lag_seconds",
                        "kind" => row.kind.as_str()
                    )
                    .record(import_lag_seconds);
                }
                Err(error) => {
                    match self.store.retry_agent_outbox(&row.outbox_id, &error) {
                        Ok(AgentOutboxRetryOutcome::Scheduled {
                            attempts,
                            next_attempt_at,
                        }) => {
                            metrics::counter!(
                                "agent_coordination_outbox_imports_total",
                                "kind" => row.kind.as_str(),
                                "outcome" => "retry_scheduled"
                            )
                            .increment(1);
                            metrics::histogram!(
                                "agent_coordination_outbox_retry_delay_seconds",
                                "kind" => row.kind.as_str()
                            )
                            .record(elapsed_until_rfc3339_seconds(&next_attempt_at));
                            tracing::warn!(
                                outbox_id = row.outbox_id,
                                kind = row.kind.as_str(),
                                attempts,
                                next_attempt_at,
                                error = %error,
                                "reusable-agent outbox import scheduled a retry"
                            );
                        }
                        Ok(AgentOutboxRetryOutcome::Rejected {
                            attempts,
                            processed_at: _,
                        }) => {
                            metrics::counter!(
                                "agent_coordination_outbox_imports_total",
                                "kind" => row.kind.as_str(),
                                "outcome" => "rejected"
                            )
                            .increment(1);
                            metrics::counter!(
                                "agent_coordination_outbox_poison_total",
                                "kind" => row.kind.as_str()
                            )
                            .increment(1);
                            metrics::histogram!(
                                "agent_coordination_outbox_import_lag_seconds",
                                "kind" => row.kind.as_str()
                            )
                            .record(import_lag_seconds);
                            tracing::error!(
                                outbox_id = row.outbox_id,
                                kind = row.kind.as_str(),
                                attempts,
                                error = %error,
                                "reusable-agent outbox import was terminally rejected"
                            );
                            // Provision/admission compensation may have
                            // enqueued the ordinary assignment-result effect
                            // in the same source transaction. Preserve the
                            // periodic reconciliation fallback while giving
                            // that newly visible failure a low-latency pass.
                            self.delivery_maintenance.notify_one();
                        }
                        Err(retry_error) => {
                            tracing::error!(
                                outbox_id = row.outbox_id,
                                kind = row.kind.as_str(),
                                error = %retry_error,
                                "failed to persist reusable-agent outbox retry outcome"
                            );
                            first_error.get_or_insert(retry_error);
                        }
                    }
                    first_error.get_or_insert(error);
                }
            }
        }
        if let Some(error) = first_error {
            Err(error)
        } else {
            Ok(())
        }
    }

    async fn import_agent_outbox_row(&self, row: &AgentOutboxRecord) -> Result<(), String> {
        match row.kind {
            AgentOutboxKind::Provision => self.import_agent_provision(row).await,
            AgentOutboxKind::Message => self.import_agent_message(row).await.map(|_| ()),
            AgentOutboxKind::Result => self.import_agent_result(row).await,
            AgentOutboxKind::Projection => self.import_agent_projection(row).await,
        }
    }

    async fn import_agent_provision(&self, row: &AgentOutboxRecord) -> Result<(), String> {
        let agent_id = required_outbox_id(row.agent_id.as_deref(), "provision agent")?;
        let assignment_id =
            required_outbox_id(row.assignment_id.as_deref(), "provision assignment")?;
        let agent = self
            .store
            .agent_instance(agent_id)?
            .ok_or_else(|| format!("provision agent '{agent_id}' was not found"))?;
        let assignment = self
            .store
            .agent_assignment(assignment_id)?
            .ok_or_else(|| format!("provision assignment '{assignment_id}' was not found"))?;
        if self
            .event_store
            .get_session(&agent.session_id)
            .map_err(|error| error.to_string())?
            .is_none()
        {
            let now = chrono::Utc::now().to_rfc3339();
            let (workspace_id, workspace_path, model, root_event) = if agent.kind
                == crate::domains::worker_kernel::persistence::AgentInstanceKind::DirectWorker
            {
                (
                    required_payload_string(&row.payload, "workspaceId")?,
                    required_payload_string(&row.payload, "workspacePath")?,
                    assignment
                        .model
                        .clone()
                        .ok_or_else(|| "direct worker assignment lost its model".to_owned())?,
                    EventIdentity::new(required_payload_string(&row.payload, "rootEventId")?, &now),
                )
            } else {
                let root = self
                    .event_store
                    .get_session(&agent.root_session_id)
                    .map_err(|error| error.to_string())?
                    .ok_or_else(|| {
                        format!(
                            "agent root session '{}' was not found",
                            agent.root_session_id
                        )
                    })?;
                (
                    root.workspace_id,
                    root.working_directory,
                    assignment.model.clone().unwrap_or(root.latest_model),
                    EventIdentity::generate_current(),
                )
            };
            self.session_manager
                .create_agent_session_with_identity(
                    &model,
                    &workspace_path,
                    Some(&agent.name),
                    SessionCreationIdentity::new(
                        WorkspaceIdentity::new(&workspace_id, &now),
                        SessionIdentity::new(&agent.session_id, &now),
                        root_event,
                    ),
                )
                .map_err(|error| error.to_string())?;
            crate::domains::session::lifecycle::project_created_session(
                &self.orchestrator,
                self.host.clone(),
                &agent.session_id,
                &model,
                &workspace_path,
                Some(agent.name.clone()),
            );
        }
        // Provisioning can race a durable deadline terminalization. Preserve
        // the exact initial message for audit, but only nonterminal admitted
        // work may create a wake. A terminal assignment must never execute
        // after its delayed provisioning effect is replayed.
        let actionable = matches!(
            assignment.status,
            AgentAssignmentStatus::Accepted | AgentAssignmentStatus::Queued
        );
        self.import_assignment_message(row, &agent, &assignment, actionable)
            .await?;
        self.store.mark_agent_provisioned(agent_id, assignment_id)?;
        self.publish_agent_invalidation(
            "agent.lifecycle",
            &agent.root_session_id,
            json!({"action":"provisioned","agentId":agent_id,"assignmentId":assignment_id}),
            &assignment.execution_id,
        )
        .await;
        Ok(())
    }

    async fn import_agent_message(
        &self,
        row: &AgentOutboxRecord,
    ) -> Result<crate::domains::session::event_store::AgentMessageMetadataRecord, String> {
        if row.payload.get("messagePurpose").and_then(Value::as_str) == Some("assignment_admission")
            && let Some(assignment_id) = row.assignment_id.as_deref()
        {
            let assignment = self
                .store
                .agent_assignment(assignment_id)?
                .ok_or_else(|| format!("message assignment '{assignment_id}' was not found"))?;
            let target = self
                .store
                .agent_instance(&assignment.agent_id)?
                .ok_or_else(|| format!("message target '{}' was not found", assignment.agent_id))?;
            let actionable = !matches!(assignment.status, AgentAssignmentStatus::Declined);
            let message = self
                .import_assignment_message(row, &target, &assignment, actionable)
                .await?;
            if assignment.status == AgentAssignmentStatus::Accepted
                && target.state
                    != crate::domains::worker_kernel::persistence::AgentInstanceState::Provisioning
            {
                self.store
                    .transition_agent_assignment(&AgentAssignmentTransition {
                        assignment_id: assignment.assignment_id.clone(),
                        expected_status: AgentAssignmentStatus::Accepted,
                        target_status: AgentAssignmentStatus::Queued,
                        result: None,
                        error: None,
                    })?;
            }
            let source_root_session_id = assignment
                .requester_agent_id
                .as_deref()
                .or(assignment.delegator_agent_id.as_deref())
                .or((assignment.kind
                    == crate::domains::worker_kernel::persistence::AgentAssignmentKind::DirectWorker)
                    .then_some(assignment.agent_id.as_str()))
                .map(|source_agent_id| self.store.agent_instance(source_agent_id))
                .transpose()?
                .flatten()
                .map(|source| source.root_session_id);
            self.publish_agent_invalidation_for_roots(
                "agent.assignment",
                source_root_session_id.as_deref(),
                &target.root_session_id,
                json!({
                    "action":"message_imported",
                    "agentId":target.agent_id,
                    "assignmentId":assignment.assignment_id,
                }),
                &assignment.execution_id,
            )
            .await;
            return Ok(message);
        }
        let source_id = required_payload_string(&row.payload, "sourceAgentId")?;
        let target_id = required_payload_string(&row.payload, "targetAgentId")?;
        let source = self
            .store
            .agent_instance(&source_id)?
            .ok_or_else(|| format!("message source '{source_id}' was not found"))?;
        let target = self
            .store
            .agent_instance(&target_id)?
            .ok_or_else(|| format!("message target '{target_id}' was not found"))?;
        let kind = parse_outbox_message_kind(&required_payload_string(&row.payload, "kind")?)?;
        let authority =
            parse_outbox_message_authority(&required_payload_string(&row.payload, "authority")?)?;
        let reply_target = (kind == AgentMessageKind::Answer)
            .then(|| {
                row.payload
                    .get("replyTo")
                    .and_then(Value::as_str)
                    .map(|id| CoordinationWaitTarget {
                        kind: CoordinationTargetKind::Reply,
                        id: id.to_owned(),
                    })
            })
            .flatten();
        // A fan-in registered by the answer recipient owns only that
        // recipient's completion wake. Another authorized observer may wait on
        // the same question, but cannot make this answer passive for its actual
        // recipient.
        let reply_is_waited = reply_target
            .as_ref()
            .map(|wait_target| {
                self.event_store
                    .coordination_wait_owns_automatic_delivery(
                        wait_target,
                        &target.session_id,
                        Some(&target.agent_id),
                    )
                    .map_err(|error| error.to_string())
            })
            .transpose()?
            .unwrap_or(false);
        let content = AgentMessageContent {
            message_id: required_payload_string(&row.payload, "messageId")?,
            source_agent_id: source.agent_id.clone(),
            source_name: Some(source.name.clone()),
            kind,
            authority,
            text: required_payload_string(&row.payload, "text")?,
            assignment_id: row
                .payload
                .get("assignmentId")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned),
            reply_to: row
                .payload
                .get("replyTo")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned),
        };
        let requested_actionable = row
            .payload
            .get("actionable")
            .and_then(Value::as_bool)
            .unwrap_or(!matches!(kind, AgentMessageKind::Information));
        let linked_information_actionable =
            if kind == AgentMessageKind::Information && requested_actionable {
                let assignment_id = content.assignment_id.as_deref();
                assignment_id
                    .map(|assignment_id| self.store.agent_assignment(assignment_id))
                    .transpose()?
                    .flatten()
                    .is_some_and(|assignment| {
                        assignment.agent_id == target.agent_id && !assignment.status.is_terminal()
                    })
            } else {
                false
            };
        let actionable =
            !matches!(kind, AgentMessageKind::Information) || linked_information_actionable;
        let message = self
            .deliver_agent_message(
                &row.deduplication_key,
                &source,
                &target,
                content,
                actionable && !reply_is_waited,
                false,
                None,
                row.execution_id.as_deref(),
                Some(&required_payload_string(&row.payload, "traceId")?),
                payload_u32(&row.payload, "causalDepth")?,
                payload_u32(&row.payload, "autonomousHop")?,
                Some(&required_payload_string(&row.payload, "channelId")?),
            )
            .await?;
        if let Some(reply_target) = reply_target {
            let resolutions = self
                .event_store
                .reconcile_coordination_waits(&[CoordinationTerminalEvidence {
                    target: reply_target,
                    status: "answered".to_owned(),
                    evidence_reference: json!({"messageId":message.message_id}),
                }])
                .map_err(|error| error.to_string())?;
            self.deliver_coordination_wait_resolutions(resolutions, Some(&source))
                .await?;
        }
        self.publish_agent_invalidation_for_roots(
            "agent.message",
            Some(&source.root_session_id),
            &target.root_session_id,
            json!({"action":"delivered","agentId":target.agent_id,"messageId":message.message_id}),
            row.execution_id.as_deref().unwrap_or(&row.outbox_id),
        )
        .await;
        Ok(message)
    }

    async fn import_assignment_message(
        &self,
        row: &AgentOutboxRecord,
        target: &AgentInstanceRecord,
        assignment: &AgentAssignmentRecord,
        actionable: bool,
    ) -> Result<crate::domains::session::event_store::AgentMessageMetadataRecord, String> {
        let source_id = assignment
            .requester_agent_id
            .as_deref()
            .or(assignment.delegator_agent_id.as_deref())
            .or((assignment.kind
                == crate::domains::worker_kernel::persistence::AgentAssignmentKind::DirectWorker)
                .then_some(assignment.agent_id.as_str()))
            .ok_or_else(|| {
                format!(
                    "assignment '{}' has no requester for its semantic message",
                    assignment.assignment_id
                )
            })?;
        let source = self
            .store
            .agent_instance(source_id)?
            .ok_or_else(|| format!("assignment requester '{source_id}' was not found"))?;
        let kind = parse_outbox_message_kind(&required_payload_string(&row.payload, "kind")?)?;
        let authority =
            parse_outbox_message_authority(&required_payload_string(&row.payload, "authority")?)?;
        // An unaccepted peer offer is an auxiliary coordination turn so the
        // recipient can accept, decline, or negotiate it. Once work is
        // accepted (including an accept/import race), the FIFO supervisor is
        // the only owner allowed to wake the transcript for that assignment.
        let supervisor_owns_wake = assignment.status != AgentAssignmentStatus::Offered;
        self.deliver_agent_message(
            &row.deduplication_key,
            &source,
            target,
            AgentMessageContent {
                message_id: row
                    .payload
                    .get("messageId")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned)
                    .unwrap_or_else(|| deterministic_message_id(&row.deduplication_key)),
                source_agent_id: source.agent_id.clone(),
                source_name: row
                    .payload
                    .get("sourceName")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned)
                    .or_else(|| Some(source.name.clone())),
                kind,
                authority,
                text: required_payload_string(&row.payload, "text")?,
                assignment_id: Some(assignment.assignment_id.clone()),
                reply_to: row
                    .payload
                    .get("replyTo")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned),
            },
            actionable,
            supervisor_owns_wake,
            assignment.deadline_at.as_deref(),
            Some(&assignment.execution_id),
            row.payload.get("traceId").and_then(Value::as_str),
            row.payload
                .get("causalDepth")
                .and_then(Value::as_u64)
                .and_then(|value| u32::try_from(value).ok())
                .unwrap_or_else(|| {
                    self.store
                        .execution_node(&assignment.execution_id)
                        .ok()
                        .flatten()
                        .map_or(0, |node| node.causal_depth)
                }),
            row.payload
                .get("autonomousHop")
                .and_then(Value::as_u64)
                .and_then(|value| u32::try_from(value).ok())
                // Old outboxes predate the dedicated autonomy counter. Causal
                // topology depth is deliberately not a substitute: messages
                // do not create execution nodes and operator input resets only
                // autonomous continuation, not lineage.
                .unwrap_or(0),
            Some(&required_payload_string(&row.payload, "channelId")?),
        )
        .await
    }
}
