//! Safe-boundary semantic message, wait, result, and projection delivery.
//!
//! Durable custody remains in the source stores; this module materializes
//! each idempotent provider-facing effect and emits bounded invalidations.

use super::super::*;
use super::support::*;

use crate::domains::session::event_store::{
    AgentDeliveryBoundary, AgentDeliveryIntent, AgentDeliverySourceKind, AgentDeliveryTarget,
    AgentDeliveryWakePolicy, CoordinationTargetKind, CoordinationTerminalEvidence,
    CoordinationWaitResolution, CoordinationWaitTarget, NewAgentDelivery, NewAgentMessageMetadata,
};
use crate::domains::worker_kernel::persistence::{
    AgentAssignmentRecord, AgentInstanceRecord, AgentOutboxRecord,
};
use crate::shared::protocol::messages::{
    AgentMessageAuthority, AgentMessageContent, AgentMessageKind,
};

impl WorkerRuntime {
    pub(super) async fn deliver_agent_message(
        &self,
        deduplication_key: &str,
        source: &AgentInstanceRecord,
        target: &AgentInstanceRecord,
        content: AgentMessageContent,
        actionable: bool,
        supervisor_owns_wake: bool,
        expires_at: Option<&str>,
        execution_id: Option<&str>,
        trace_id: Option<&str>,
        causal_depth: u32,
        autonomous_hop: u32,
        channel_id: Option<&str>,
    ) -> Result<crate::domains::session::event_store::AgentMessageMetadataRecord, String> {
        let semantic_kind = content.kind.as_str();
        // Assignment-admission messages are permanently supervisor-owned,
        // independent of whichever assignment state the importer happens to
        // observe. They are persisted immediately as passive conversation
        // evidence; only the assignment supervisor may create the wake after
        // it has committed Running and the attempt baseline. Offered peer
        // requests and instructions linked to already-active work remain
        // ordinary actionable coordination messages.
        let source_session = self
            .event_store
            .get_session(&source.session_id)
            .map_err(|error| error.to_string())?
            .ok_or_else(|| {
                format!(
                    "message source session '{}' was not found",
                    source.session_id
                )
            })?;
        let execution = execution_id
            .map(|id| self.store.execution_node(id))
            .transpose()?
            .flatten();
        let trace_id = trace_id
            .map(ToOwned::to_owned)
            .or_else(|| execution.as_ref().map(|node| node.trace_id.clone()))
            .unwrap_or_else(|| format!("agent-message:{}", content.message_id));
        let fallback_channel;
        let channel_id = if let Some(channel_id) = channel_id {
            channel_id
        } else {
            let mut participants = [source.agent_id.as_str(), target.agent_id.as_str()];
            participants.sort_unstable();
            fallback_channel = format!("agent_channel:{}:{}", participants[0], participants[1]);
            &fallback_channel
        };
        let message = self
            .event_store
            .record_agent_message(&NewAgentMessageMetadata {
                idempotency_key: format!("agent-message:{deduplication_key}"),
                channel_id: channel_id.to_owned(),
                channel_sequence: None,
                source_session_id: Some(source.session_id.clone()),
                target_agent_id: target.agent_id.clone(),
                target_session_id: target.session_id.clone(),
                trace_id: trace_id.clone(),
                autonomous_hop,
                content,
            })
            .map_err(|error| error.to_string())?;
        let limits = &self.settings_runtime.current().settings.agent.coordination;
        let message_count = self
            .event_store
            .coordination_message_count(&trace_id)
            .map_err(|error| error.to_string())?;
        let pause_reason = if autonomous_hop > limits.max_autonomous_wake_hops {
            Some(format!(
                "autonomous coordination exceeded the {}-wake-hop ceiling",
                limits.max_autonomous_wake_hops
            ))
        } else if message_count > limits.max_coordination_messages {
            Some(format!(
                "coordination trace exceeded the {}-message ceiling",
                limits.max_coordination_messages
            ))
        } else {
            None
        };
        let autonomy_paused = pause_reason.is_some();
        if let Some(reason) = pause_reason.as_deref() {
            // The semantic message is durable before scheduling is stopped.
            // A trace without an execution node (for example a root-only peer
            // exchange) still suppresses this wake and records operator
            // attention; assignment/worker graphs additionally become
            // transactionally unrunnable until authenticated resumption.
            let pause_state = self.store.pause_coordination_trace_for_root(
                &trace_id,
                &source.root_session_id,
                reason,
            )?;
            let owner_root = pause_state.root_session_id.as_str();
            let _ = self.store.record_system_inbox_once(
                &format!("agent_autonomy_paused:{}", trace_id),
                "agent-coordination",
                "autonomy_paused",
                &json!({
                    "status":"attention",
                    "code":"AGENT_AUTONOMY_PAUSED",
                    "traceId":trace_id,
                    "rootSessionId":owner_root,
                    "sourceAgentId":source.agent_id,
                    "targetAgentId":target.agent_id,
                    "messageId":message.message_id,
                    "autonomousWakeHop":autonomous_hop,
                    "messageCount":message_count,
                    "reason":reason,
                }),
            );
            metrics::counter!("agent_coordination_autonomy_pauses_total").increment(1);
            self.publish_agent_invalidation(
                "agent.lifecycle",
                owner_root,
                json!({
                    "action":"autonomy_paused",
                    "code":"AGENT_AUTONOMY_PAUSED",
                    "traceId":trace_id,
                    "agentId":target.agent_id,
                    "reason":reason,
                }),
                &trace_id,
            )
            .await;
            if target.root_session_id != owner_root {
                self.publish_agent_invalidation(
                    "agent.lifecycle",
                    &target.root_session_id,
                    json!({
                        "action":"autonomy_paused",
                        "code":"AGENT_AUTONOMY_PAUSED",
                        "traceId":trace_id,
                        "agentId":target.agent_id,
                        "reason":reason,
                    }),
                    &trace_id,
                )
                .await;
            }
        }
        let depth = if causal_depth == 0 {
            execution.as_ref().map_or(0, |node| node.causal_depth)
        } else {
            causal_depth
        };
        let wake_policy = if supervisor_owns_wake {
            AgentDeliveryWakePolicy::Passive
        } else if actionable && !autonomy_paused {
            AgentDeliveryWakePolicy::Wake
        } else {
            AgentDeliveryWakePolicy::Passive
        };
        let supervisor_assignment_id = if supervisor_owns_wake {
            Some(message.assignment_id.clone().ok_or_else(|| {
                "supervisor-owned agent delivery requires an assignment handle".to_owned()
            })?)
        } else {
            None
        };
        let originating_run_id = self.orchestrator.active_run_id(&source.session_id);
        self.orchestrator
            .with_stable_active_run(&target.session_id, |active_run_id| {
                let delivery = NewAgentDelivery {
                    idempotency_key: format!("agent-message-delivery:{}", message.message_id),
                    source_kind: AgentDeliverySourceKind::AgentMessage,
                    intent: Some(if actionable {
                        AgentDeliveryIntent::Request
                    } else {
                        AgentDeliveryIntent::Information
                    }),
                    source_session_id: Some(source.session_id.clone()),
                    source_workspace_id: source_session.workspace_id.clone(),
                    source_invocation_id: None,
                    source_trace_id: Some(trace_id.clone()),
                    source_root_invocation_id: execution_id.map(ToOwned::to_owned),
                    causal_depth: depth,
                    target: AgentDeliveryTarget::Session {
                        session_id: target.session_id.clone(),
                    },
                    wake_policy,
                    boundary: AgentDeliveryBoundary::NextTurn,
                    originating_run_id: originating_run_id.clone(),
                    arrived_during_run_id: active_run_id.map(ToOwned::to_owned),
                    defer_until_run_id: None,
                    result_invocation_id: None,
                    content: json!({
                        "protocol":crate::domains::worker_kernel::AGENT_COORDINATION_CAPABILITY,
                        "messageId":message.message_id,
                    })
                    .to_string(),
                    not_before: None,
                    expires_at: expires_at.map(ToOwned::to_owned),
                };
                if let Some(assignment_id) = supervisor_assignment_id.as_deref() {
                    self.event_store
                        .create_held_agent_assignment_delivery(&delivery, assignment_id)
                } else {
                    self.event_store.create_agent_delivery(&delivery)
                }
            })
            .map_err(|error| error.to_string())?;
        metrics::counter!(
            "agent_coordination_messages_total",
            "kind" => semantic_kind,
            "delivery" => if autonomy_paused {
                "autonomy_paused"
            } else if supervisor_owns_wake {
                "supervisor_held"
            } else if actionable {
                "wake"
            } else {
                "passive"
            }
        )
        .increment(1);
        if actionable && !autonomy_paused {
            if supervisor_owns_wake {
                self.delivery_maintenance.notify_one();
            } else {
                self.request_agent_delivery_wake(&target.session_id, depth)
                    .await;
            }
        }
        Ok(message)
    }

    /// Deliver one engine-authored aggregate continuation for each resolved
    /// durable fan-in. Deterministic message and delivery keys make importer
    /// replay harmless across either database boundary.
    pub(in crate::domains::worker_kernel::runtime) async fn deliver_coordination_wait_resolutions(
        &self,
        resolutions: Vec<CoordinationWaitResolution>,
        source: Option<&AgentInstanceRecord>,
    ) -> Result<(), String> {
        for resolution in resolutions {
            let Some(target_agent) = self.store.agent_instance(&resolution.wait.owner_agent_id)?
            else {
                continue;
            };
            let source_agent = source.cloned().unwrap_or_else(|| target_agent.clone());
            let owner_execution = resolution
                .wait
                .owner_assignment_id
                .as_deref()
                .map(|assignment_id| self.store.agent_assignment(assignment_id))
                .transpose()?
                .flatten()
                .map(|assignment| assignment.execution_id);
            let causal_depth = owner_execution
                .as_deref()
                .map(|execution_id| self.store.execution_node(execution_id))
                .transpose()?
                .flatten()
                .map_or(0, |execution| execution.causal_depth);
            // Assignment-owned waits resume through the assignment supervisor,
            // after any auxiliary question/operator run reaches its safe
            // boundary. Visible-root waits have no supervisor and therefore
            // retain the ordinary direct wake.
            let direct_wake = resolution.wait.owner_assignment_id.is_none();
            let message = self
                .deliver_agent_message(
                    &format!("coordination-wait:{}", resolution.wait.wait_id),
                    &source_agent,
                    &target_agent,
                    AgentMessageContent {
                        message_id: deterministic_message_id(&format!(
                            "coordination-wait:{}",
                            resolution.wait.wait_id
                        )),
                        source_agent_id: source_agent.agent_id.clone(),
                        source_name: Some(
                            source.map_or_else(
                                || "Tron Engine".to_owned(),
                                |agent| agent.name.clone(),
                            ),
                        ),
                        kind: AgentMessageKind::Result,
                        authority: AgentMessageAuthority::Engine,
                        text: serde_json::to_string(&json!({
                            "waitId":resolution.wait.wait_id,
                            "mode":resolution.wait.mode,
                            "completed":resolution.satisfied,
                        }))
                        .map_err(|error| error.to_string())?,
                        assignment_id: resolution.wait.owner_assignment_id.clone(),
                        reply_to: None,
                    },
                    direct_wake,
                    false,
                    None,
                    owner_execution.as_deref(),
                    Some(&resolution.wait.trace_id),
                    causal_depth,
                    resolution.wait.autonomous_hop.saturating_add(1),
                    None,
                )
                .await?;
            let newly_bound = self
                .event_store
                .bind_coordination_wait_message(&resolution.wait.wait_id, &message.message_id)
                .map_err(|error| error.to_string())?;
            if newly_bound {
                let mode = match resolution.wait.mode {
                    crate::domains::session::event_store::CoordinationWaitMode::All => "all",
                    crate::domains::session::event_store::CoordinationWaitMode::Any => "any",
                };
                metrics::counter!(
                    "agent_coordination_wait_resolutions_total",
                    "mode" => mode,
                    "delivery" => "aggregate"
                )
                .increment(1);
                metrics::histogram!(
                    "agent_coordination_wait_resolution_seconds",
                    "mode" => mode
                )
                .record(elapsed_rfc3339_seconds(&resolution.wait.created_at));
            }
            if !direct_wake {
                self.delivery_maintenance.notify_one();
            }
        }
        Ok(())
    }

    pub(super) async fn import_agent_result(&self, row: &AgentOutboxRecord) -> Result<(), String> {
        let assignment_id = required_outbox_id(row.assignment_id.as_deref(), "result assignment")?;
        let assignment = self
            .store
            .agent_assignment(assignment_id)?
            .ok_or_else(|| format!("result assignment '{assignment_id}' was not found"))?;
        if !assignment.status.is_terminal() {
            return Err(format!(
                "result assignment '{assignment_id}' is not terminal"
            ));
        }
        let result_hop = self
            .assignment_autonomous_hop(&assignment)?
            .saturating_add(1);
        let target = CoordinationWaitTarget {
            kind: CoordinationTargetKind::AgentAssignment,
            id: assignment.assignment_id.clone(),
        };
        let requester = assignment
            .requester_agent_id
            .as_deref()
            .map(|requester_id| self.store.agent_instance(requester_id))
            .transpose()?
            .flatten();
        let requester_wait_owns_delivery = requester
            .as_ref()
            .map(|requester| {
                self.event_store.coordination_wait_owns_automatic_delivery(
                    &target,
                    &requester.session_id,
                    Some(&requester.agent_id),
                )
            })
            .transpose()
            .map_err(|error| error.to_string())?
            .unwrap_or(false);
        let resolutions = self
            .event_store
            .reconcile_coordination_waits(&[CoordinationTerminalEvidence {
                target,
                status: assignment.status.as_str().to_owned(),
                evidence_reference: json!({
                    "assignmentId":assignment.assignment_id,
                    "agentId":assignment.agent_id,
                    "result":assignment.result_reference,
                    "error":assignment.error,
                }),
            }])
            .map_err(|error| error.to_string())?;
        let source = self
            .store
            .agent_instance(&assignment.agent_id)?
            .ok_or_else(|| "completed assignment agent disappeared".to_owned())?;
        self.deliver_coordination_wait_resolutions(resolutions, Some(&source))
            .await?;
        if !requester_wait_owns_delivery && let Some(requester) = requester {
            let result_delivery = self.assignment_result_delivery(&assignment)?;
            let source = self
                .store
                .agent_instance(&assignment.agent_id)?
                .ok_or_else(|| "completed assignment agent disappeared".to_owned())?;
            self.deliver_agent_message(
                &format!("assignment-result:{assignment_id}"),
                &source,
                &requester,
                AgentMessageContent {
                    message_id: deterministic_message_id(&format!(
                        "assignment-result:{assignment_id}"
                    )),
                    source_agent_id: source.agent_id.clone(),
                    source_name: Some(source.name.clone()),
                    kind: AgentMessageKind::Result,
                    authority: AgentMessageAuthority::Engine,
                    text: serde_json::to_string(&result_delivery)
                        .map_err(|error| error.to_string())?,
                    assignment_id: Some(assignment.assignment_id.clone()),
                    reply_to: None,
                },
                true,
                false,
                None,
                Some(&assignment.execution_id),
                None,
                0,
                result_hop,
                None,
            )
            .await?;
        }
        self.publish_agent_invalidation(
            "agent.assignment",
            &self
                .store
                .agent_instance(&assignment.agent_id)?
                .ok_or_else(|| "completed assignment agent disappeared".to_owned())?
                .root_session_id,
            json!({
                "action":"terminal",
                "agentId":assignment.agent_id,
                "assignmentId":assignment.assignment_id,
                "status":assignment.status.as_str(),
            }),
            &assignment.execution_id,
        )
        .await;
        Ok(())
    }

    /// Build automatic assignment-result evidence without sacrificing durable
    /// custody. Context-safe results are included directly, while every
    /// successful result also carries its integrity-bound reference/hash.
    /// Larger results remain reference-only and are read through `result_read`.
    fn assignment_result_delivery(
        &self,
        assignment: &AgentAssignmentRecord,
    ) -> Result<Value, String> {
        let inline_result = match assignment.result_id.as_deref() {
            Some(result_id) => {
                let result = self.store.resolve_agent_result(result_id)?.ok_or_else(|| {
                    format!(
                        "terminal assignment '{}' lost result '{}'",
                        assignment.assignment_id, result_id
                    )
                })?;
                let serialized = serde_json::to_vec(&result).map_err(|error| error.to_string())?;
                (serialized.len()
                    <= crate::shared::protocol::model_tools::DEFAULT_MAX_INLINE_MODEL_TOOL_RESULT_BYTES)
                    .then_some(result)
            }
            None => None,
        };
        Ok(json!({
            "assignmentId":assignment.assignment_id,
            "status":assignment.status.as_str(),
            "result":inline_result,
            "resultReference":assignment.result_reference,
            "error":assignment.error,
        }))
    }

    pub(super) async fn import_agent_projection(
        &self,
        row: &AgentOutboxRecord,
    ) -> Result<(), String> {
        if row.payload.get("kind").and_then(Value::as_str) == Some("promote_agent_session") {
            let session_id = required_payload_string(&row.payload, "sessionId")?;
            self.session_manager
                .promote_agent_session(&session_id)
                .map_err(|error| error.to_string())?;
        }
        if let Some(agent_id) = row.agent_id.as_deref()
            && let Some(agent) = self.store.agent_instance(agent_id)?
        {
            self.publish_agent_invalidation(
                "agent.lifecycle",
                &agent.root_session_id,
                row.payload.clone(),
                row.execution_id.as_deref().unwrap_or(&row.outbox_id),
            )
            .await;
        }
        Ok(())
    }
}
