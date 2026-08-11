//! Agent-delivery mailbox curation, wait maintenance, wake admission, and outbox import.
//!
//! No worker transaction is held while EventStore state changes. A terminal
//! signal is acknowledged only after wait reconciliation and any automatic
//! origin-session delivery are durably committed.

use serde_json::Value;
use std::collections::BTreeSet;

use super::*;
use crate::domains::session::event_store::{
    AgentDeliveryIntent, AgentDeliverySourceKind, AgentMailboxScope, AgentWaitMode,
    MAX_DELIVERIES_PER_TURN, NewAgentWait, WorkerTerminalEvidence,
};

fn mailbox_candidate_projection(
    delivery_id: &str,
    source_kind: AgentDeliverySourceKind,
    intent: Option<AgentDeliveryIntent>,
    content: &str,
    created_at: &str,
    expires_at: Option<&str>,
) -> Value {
    let mut candidate = json!({
        "deliveryId":delivery_id,
        "sourceKind":source_kind,
        "intent":intent,
        "preview":crate::shared::foundation::redaction::redact_sensitive_content(
            content
        ).chars().take(512).collect::<String>(),
        "createdAt":created_at,
    });
    if let Some(expires_at) = expires_at {
        candidate["expiresAt"] = json!(expires_at);
    }
    candidate
}

impl WorkerRuntime {
    pub(crate) async fn curate_new_session_mailbox(
        self: &std::sync::Arc<Self>,
        invocation: &Invocation,
    ) -> Result<Value, String> {
        let session_id = invocation
            .payload
            .get("sessionId")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .ok_or_else(|| "mailbox curation requires sessionId".to_owned())?;
        if invocation.causal_context.session_id.as_deref() != Some(session_id) {
            return Err("mailbox curation session does not match engine provenance".to_owned());
        }
        let session = self
            .event_store
            .get_session(session_id)
            .map_err(|error| error.to_string())?
            .ok_or_else(|| format!("mailbox curation session '{session_id}' was not found"))?;
        if session.is_worker_session() || session.ended_at.is_some() {
            return Ok(json!({
                "handled":false,
                "candidateCount":0,
                "claimedDeliveryIds":[],
            }));
        }
        let candidates = self
            .event_store
            .list_agent_mailbox_candidates(session_id, 32)
            .map_err(|error| error.to_string())?;
        if candidates.is_empty() {
            return Ok(json!({
                "handled":false,
                "candidateCount":0,
                "claimedDeliveryIds":[],
            }));
        }
        let candidate_ids = candidates
            .iter()
            .map(|delivery| delivery.delivery_id.as_str())
            .collect::<BTreeSet<_>>();
        let input = json!({
            "sessionId":session_id,
            "candidates":candidates
                .iter()
                .map(|delivery| {
                    mailbox_candidate_projection(
                        &delivery.delivery_id,
                        delivery.source_kind,
                        delivery.intent,
                        &delivery.content,
                        &delivery.created_at,
                        delivery.expires_at.as_deref(),
                    )
                })
                .collect::<Vec<_>>(),
        });
        let Some(execution) = self
            .execute_engine_hook(
                super::super::types::WorkerEngineHook::MailboxCuration,
                input,
                None,
                invocation,
            )
            .await?
        else {
            return Ok(json!({
                "handled":false,
                "candidateCount":candidates.len(),
                "claimedDeliveryIds":[],
            }));
        };
        let Some(selected) = execution.output["selectedDeliveryIds"].as_array() else {
            let reason = self
                .reject_engine_hook_output(
                    &execution,
                    super::super::types::WorkerEngineHook::MailboxCuration,
                    "selectedDeliveryIds must be an array",
                )
                .await;
            return Err(reason);
        };
        let mut unique = BTreeSet::new();
        let mut selected_ids = Vec::new();
        for value in selected {
            let delivery_id = value.as_str().unwrap_or_default();
            if selected_ids.len() >= MAX_DELIVERIES_PER_TURN
                || !candidate_ids.contains(delivery_id)
                || !unique.insert(delivery_id)
            {
                let reason = self
                    .reject_engine_hook_output(
                        &execution,
                        super::super::types::WorkerEngineHook::MailboxCuration,
                        "selectedDeliveryIds must contain at most eight unique IDs from the supplied candidates",
                    )
                    .await;
                return Err(reason);
            }
            selected_ids.push(delivery_id.to_owned());
        }
        if !selected_ids.is_empty() {
            self.event_store
                .claim_agent_mailbox(session_id, &selected_ids)
                .map_err(|error| error.to_string())?;
        }
        Ok(json!({
            "handled":true,
            "candidateCount":candidates.len(),
            "workerId":execution.worker_id,
            "workerVersion":execution.worker_version,
            "invocationId":execution.invocation_id,
            "claimedDeliveryIds":selected_ids,
        }))
    }

    pub(crate) async fn agent_wait_for_workers(
        &self,
        invocation: &Invocation,
    ) -> Result<Value, String> {
        let session_id = invocation
            .causal_context
            .session_id
            .as_deref()
            .ok_or_else(|| "agent_wait_for_workers requires a source session".to_owned())?;
        let invocation_ids = invocation
            .payload
            .get("invocationIds")
            .and_then(Value::as_array)
            .ok_or_else(|| "agent_wait_for_workers invocationIds are required".to_owned())?
            .iter()
            .map(|value| {
                value
                    .as_str()
                    .map(ToOwned::to_owned)
                    .ok_or_else(|| "worker invocation ids must be strings".to_owned())
            })
            .collect::<Result<Vec<_>, _>>()?;
        let mode = match invocation
            .payload
            .get("mode")
            .and_then(Value::as_str)
            .unwrap_or("all")
        {
            "all" => AgentWaitMode::All,
            "any" => AgentWaitMode::Any,
            other => return Err(format!("unsupported wait mode '{other}'")),
        };
        for invocation_id in &invocation_ids {
            let record = self
                .store
                .invocation(invocation_id)?
                .ok_or_else(|| format!("worker invocation '{invocation_id}' was not found"))?;
            if record.origin_session_id.as_deref() != Some(session_id) {
                return Err(format!(
                    "worker invocation '{invocation_id}' is not owned by this session"
                ));
            }
            if record.parent_worker_invocation_id.is_some() {
                return Err(format!(
                    "worker invocation '{invocation_id}' is nested; waits accept only top-level invocations"
                ));
            }
            if record.trace_id != invocation.causal_context.trace_id.as_str() {
                return Err(format!(
                    "worker invocation '{invocation_id}' is outside this causal trace"
                ));
            }
        }
        let wait = self
            .event_store
            .create_agent_wait(&NewAgentWait {
                idempotency_key: format!("agent-wait:{}", invocation.id.as_str()),
                session_id: session_id.to_owned(),
                source_invocation_id: invocation.id.as_str().to_owned(),
                source_trace_id: invocation.causal_context.trace_id.as_str().to_owned(),
                source_root_invocation_id: invocation
                    .causal_context
                    .origin_worker_invocation_id()
                    .map(ToOwned::to_owned),
                causal_depth: invocation.causal_context.trigger_depth().saturating_add(1),
                mode,
                invocation_ids: invocation_ids.clone(),
            })
            .map_err(|error| error.to_string())?;
        let deliveries = self.reconcile_agent_wait_invocations(&invocation_ids)?;
        for delivery in &deliveries {
            if let Some(target) = delivery.target_session_id.as_deref() {
                self.request_agent_delivery_wake(target, delivery.causal_depth)
                    .await;
            }
        }
        let satisfied = wait.disposition == "satisfied" || !deliveries.is_empty();
        let delivery_ids = if deliveries.is_empty() {
            wait.delivery_id.into_iter().collect::<Vec<_>>()
        } else {
            deliveries
                .into_iter()
                .map(|delivery| delivery.delivery_id)
                .collect::<Vec<_>>()
        };
        Ok(json!({
            "waitId":wait.wait_id,
            "mode":if mode == AgentWaitMode::All {"all"} else {"any"},
            "invocationIds":invocation_ids,
            "status":if satisfied {"satisfied"} else {"pending"},
            "deliveryIds":delivery_ids,
        }))
    }

    pub(crate) fn agent_mailbox_list(&self, invocation: &Invocation) -> Result<Value, String> {
        let session_id = invocation
            .causal_context
            .session_id
            .as_deref()
            .ok_or_else(|| "agent_mailbox_list requires a source session".to_owned())?;
        let scope = mailbox_scope(&invocation.payload)?;
        let name = required_payload_string(&invocation.payload, "name")?;
        let limit = invocation
            .payload
            .get("limit")
            .and_then(Value::as_u64)
            .and_then(|value| usize::try_from(value).ok())
            .unwrap_or(20);
        let records = self
            .event_store
            .list_agent_mailbox(session_id, scope, &name, limit)
            .map_err(|error| error.to_string())?;
        let items = records
            .into_iter()
            .map(|record| {
                let preview =
                    crate::shared::foundation::redaction::redact_sensitive_content(&record.content)
                        .chars()
                        .take(512)
                        .collect::<String>();
                json!({
                    "deliveryId":record.delivery_id,
                    "sourceKind":record.source_kind,
                    "intent":record.intent,
                    "createdAt":record.created_at,
                    "expiresAt":record.expires_at,
                    "preview":preview,
                })
            })
            .collect::<Vec<_>>();
        Ok(json!({"items":items,"returned":items.len()}))
    }

    pub(crate) fn agent_mailbox_claim(&self, invocation: &Invocation) -> Result<Value, String> {
        let session_id = invocation
            .causal_context
            .session_id
            .as_deref()
            .ok_or_else(|| "agent_mailbox_claim requires a target session".to_owned())?;
        let delivery_ids = invocation
            .payload
            .get("deliveryIds")
            .and_then(Value::as_array)
            .ok_or_else(|| "agent_mailbox_claim deliveryIds are required".to_owned())?
            .iter()
            .map(|value| {
                value
                    .as_str()
                    .map(ToOwned::to_owned)
                    .ok_or_else(|| "delivery ids must be strings".to_owned())
            })
            .collect::<Result<Vec<_>, _>>()?;
        let claimed = self
            .event_store
            .claim_agent_mailbox(session_id, &delivery_ids)
            .map_err(|error| error.to_string())?;
        Ok(json!({
            "claimed":claimed.len(),
            "deliveryIds":claimed.into_iter().map(|delivery| delivery.delivery_id).collect::<Vec<_>>(),
            "boundary":"next_turn",
            "wakePolicy":"passive",
        }))
    }

    fn reconcile_agent_wait_invocations(
        &self,
        invocation_ids: &[String],
    ) -> Result<Vec<crate::domains::session::event_store::AgentDeliveryRecord>, String> {
        let mut terminals = Vec::new();
        for invocation_id in invocation_ids {
            let Some(record) = self.store.invocation(invocation_id)? else {
                continue;
            };
            if !matches!(record.status.as_str(), "completed" | "failed" | "cancelled") {
                continue;
            }
            terminals.push(WorkerTerminalEvidence {
                invocation_id: record.invocation_id.clone(),
                status: record.status.clone(),
                evidence: serde_json::to_string(&json!({
                    "workerId":record.worker_id,
                    "invocationId":record.invocation_id,
                    "status":record.status,
                    "error":record.error,
                    "hasResult":record.output.is_some(),
                }))
                .map_err(|error| error.to_string())?,
            });
        }
        self.event_store
            .reconcile_agent_waits(&terminals)
            .map_err(|error| error.to_string())
    }

    async fn exact_agent_function_grant(
        &self,
        agent_id: &str,
        allowed_tools: &BTreeSet<String>,
        allow_workspace_mutations: bool,
    ) -> Result<Vec<String>, String> {
        let actor_id = ActorId::new(format!("agent:{agent_id}"))
            .map_err(|error| format!("invalid durable agent identity: {error}"))?;
        // Use the engine-authored System catalog view only to resolve hidden
        // delegable contracts into exact function IDs. The provider turn and
        // every eventual tool invocation remain Agent-scoped and are checked
        // against this immutable list.
        let actor = crate::engine::ActorContext::new(actor_id, ActorKind::System);
        let (_, functions) = self.host.visible_functions_with_revision(&actor).await;
        Ok(functions
            .into_iter()
            .filter(|function| function.delegation_policy != crate::engine::DelegationPolicy::Never)
            .filter(|function| {
                allow_workspace_mutations
                    || matches!(
                        function.workspace_effect,
                        crate::engine::WorkspaceEffect::None | crate::engine::WorkspaceEffect::Read
                    )
            })
            .filter(|function| {
                let canonical_name_allowed = function
                    .model_tool
                    .as_ref()
                    .is_some_and(|tool| allowed_tools.contains(tool.name.as_str()));
                let retained_alias_allowed = allowed_tools.iter().any(|tool_name| {
                    crate::domains::worker_kernel::surface::retained_worker_agent_tool_alias_target(
                        tool_name,
                    )
                    .is_some_and(|target| target == function.id.as_str())
                });
                canonical_name_allowed || retained_alias_allowed
            })
            .map(|function| function.id.as_str().to_owned())
            .collect())
    }

    pub(super) async fn request_agent_delivery_wake(&self, session_id: &str, _causal_depth: u32) {
        if self.orchestrator.has_active_run(session_id) {
            return;
        }
        let Ok(records) = self
            .event_store
            .pending_agent_wake_batch_for_session(session_id, MAX_DELIVERIES_PER_TURN)
        else {
            return;
        };
        let Some(first_delivery) = records.first() else {
            return;
        };
        let delivery_ids = records
            .iter()
            .map(|record| record.delivery_id.clone())
            .collect::<Vec<_>>();
        let provenance = {
            let trace_id = first_delivery
                .source_trace_id
                .as_deref()
                .and_then(|value| TraceId::new(value.to_owned()).ok());
            let autonomous_wake_hop =
                match self.event_store.agent_wake_batch_autonomous_hop(&records) {
                    Ok(hop) => hop,
                    Err(error) => {
                        tracing::warn!(
                            session_id,
                            error = %error,
                            "could not recover persisted autonomy provenance for agent wake"
                        );
                        return;
                    }
                };
            Some((
                trace_id,
                first_delivery.source_invocation_id.clone(),
                autonomous_wake_hop,
            ))
        };
        let Ok(function_id) = FunctionId::new("agent::delivery_wake") else {
            return;
        };
        let Ok(actor_id) = ActorId::new("system:agent-delivery") else {
            return;
        };
        let wake_admission_key =
            format!("agent-delivery-wake:{session_id}:{}", uuid::Uuid::now_v7());
        let trace_id = provenance
            .as_ref()
            .and_then(|(trace_id, _, _)| trace_id.clone())
            .unwrap_or_else(TraceId::generate);
        let autonomous_wake_hop = provenance
            .as_ref()
            .map_or(0, |(_, _, autonomous_wake_hop)| *autonomous_wake_hop);
        let mut causal = CausalContext::new(actor_id, ActorKind::System, trace_id)
            .with_session_id(session_id.to_owned())
            .with_trigger_depth(first_delivery.causal_depth)
            .with_autonomous_wake_hop(autonomous_wake_hop)
            .with_idempotency_key(wake_admission_key.clone());
        let mut wake_reasoning_level = None;
        if let Ok(Some(session)) = self.event_store.get_session(session_id) {
            causal = causal
                .with_workspace_id(session.workspace_id)
                .with_working_directory(session.working_directory);
        }
        let mut session_agent = match self.store.agent_instance_for_session(session_id) {
            Ok(agent) => agent,
            Err(error) => {
                tracing::warn!(
                    session_id,
                    error,
                    "could not resolve durable agent identity for delivery wake"
                );
                return;
            }
        };
        // Reserve a hidden agent's run boundary before reading its mutable
        // lifecycle/configuration projection. Lifecycle mutations consult the
        // same orchestrator registry, so either this exact wake runs with one
        // coherent snapshot or the mutation wins and the wake is reconsidered.
        let mut _auxiliary_run_reservation = None;
        if session_agent.as_ref().is_some_and(|agent| {
            agent.visibility == crate::domains::worker_kernel::persistence::AgentVisibility::Nested
        }) {
            let Some(reservation) = self
                .orchestrator
                .try_reserve_auxiliary_run(session_id, &wake_admission_key)
            else {
                if self
                    .store
                    .agent_instance_for_session(session_id)
                    .ok()
                    .flatten()
                    .is_some_and(|agent| {
                        agent.state
                            == crate::domains::worker_kernel::persistence::AgentInstanceState::Closed
                    })
                {
                    let _ = self
                        .event_store
                        .demote_agent_wakes(session_id, &delivery_ids);
                }
                return;
            };
            _auxiliary_run_reservation = Some(reservation);
            session_agent = match self.store.agent_instance_for_session(session_id) {
                Ok(agent) => agent,
                Err(error) => {
                    tracing::warn!(
                        session_id,
                        error,
                        "could not revalidate durable agent identity after wake reservation"
                    );
                    return;
                }
            };
        }
        if session_agent.as_ref().is_some_and(|agent| {
            agent.state == crate::domains::worker_kernel::persistence::AgentInstanceState::Closed
        }) {
            if let Err(error) = self
                .event_store
                .demote_agent_wakes(session_id, &delivery_ids)
            {
                tracing::warn!(
                    session_id,
                    error = %error,
                    "could not make a closed agent's pending wakes passive"
                );
            }
            return;
        }
        if let Some(agent) = session_agent {
            let assignment = self
                .store
                .list_agent_assignments(&agent.agent_id, 32)
                .ok()
                .and_then(|assignments| {
                    assignments
                        .into_iter()
                        .filter(|assignment| {
                            matches!(
                                assignment.status,
                                crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Running
                                    | crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Waiting
                            )
                        })
                        .min_by_key(|assignment| assignment.queue_ordinal)
                });
            if let Some(assignment) = assignment {
                wake_reasoning_level = assignment.reasoning_level.clone();
                let mut assignment_limits = assignment.limits_snapshot.clone();
                if let Some(max_turns) = assignment_limits
                    .get("maxAssignmentTurns")
                    .and_then(Value::as_u64)
                    .and_then(|value| u32::try_from(value).ok())
                    && let Ok(used_turns) = self.assignment_turn_count(&agent, &assignment)
                    && let Some(object) = assignment_limits.as_object_mut()
                {
                    object.insert(
                        "maxAssignmentTurns".to_owned(),
                        Value::from(max_turns.saturating_sub(used_turns).max(1)),
                    );
                }
                if let Ok(Some(execution)) = self.store.execution_node(&assignment.execution_id) {
                    causal = causal.with_trigger_depth(execution.causal_depth.saturating_add(1));
                }
                let allowed_tools = assignment
                    .authority_snapshot
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(Value::as_str)
                    .map(ToOwned::to_owned)
                    .collect::<BTreeSet<_>>();
                let exact_grant = match self
                    .exact_agent_function_grant(&agent.agent_id, &allowed_tools, true)
                    .await
                {
                    Ok(grant) => grant,
                    Err(error) => {
                        tracing::warn!(
                            session_id,
                            error,
                            "could not resolve assignment agent grant for delivery wake"
                        );
                        return;
                    }
                };
                let direct_worker_id = (agent.kind.as_str() == "direct_worker")
                    .then(|| {
                        assignment
                            .resource_snapshot
                            .get("workerId")
                            .and_then(Value::as_str)
                            .map(ToOwned::to_owned)
                    })
                    .flatten();
                causal = causal
                    .with_agent_execution(
                        agent.agent_id,
                        assignment.assignment_id,
                        assignment.execution_id,
                    )
                    .with_delegated_function_grant(exact_grant)
                    .with_agent_limits(assignment_limits)
                    .with_agent_write_scopes(
                        assignment
                            .write_scopes_snapshot
                            .as_array()
                            .into_iter()
                            .flatten()
                            .filter_map(Value::as_str)
                            .map(ToOwned::to_owned)
                            .collect(),
                    );
                if let Some(worker_id) = direct_worker_id {
                    causal = causal
                        .with_origin_worker_id(worker_id)
                        .with_worker_agent_tools(allowed_tools.into_iter().collect());
                }
            } else if agent.visibility
                == crate::domains::worker_kernel::persistence::AgentVisibility::Nested
            {
                let allowed_tools = agent
                    .tool_grant
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(Value::as_str)
                    .map(ToOwned::to_owned)
                    .collect::<BTreeSet<_>>();
                let exact_grant = match self
                    .exact_agent_function_grant(&agent.agent_id, &allowed_tools, false)
                    .await
                {
                    Ok(grant) => grant,
                    Err(error) => {
                        tracing::warn!(
                            session_id,
                            error,
                            "could not resolve auxiliary agent grant for delivery wake"
                        );
                        return;
                    }
                };
                wake_reasoning_level = agent.default_reasoning_level.clone();
                causal = causal
                    .with_agent_identity(agent.agent_id)
                    .with_delegated_function_grant(exact_grant)
                    .with_agent_limits(agent.limits);
            }
        }
        if let Some(parent_id) = provenance
            .and_then(|(_, parent_id, _)| parent_id)
            .and_then(|value| crate::engine::InvocationId::new(value).ok())
        {
            causal = causal.with_parent_invocation(parent_id);
        }
        let outcome = self
            .host
            .invoke(Invocation::new_sync(
                function_id,
                match wake_reasoning_level {
                    Some(reasoning_level) => json!({
                        "sessionId":session_id,
                        "reasoningLevel":reasoning_level,
                        "deliveryIds":delivery_ids,
                    }),
                    None => json!({
                        "sessionId":session_id,
                        "deliveryIds":delivery_ids,
                    }),
                },
                causal,
            ))
            .await;
        if let Some(error) = outcome.error {
            let deferred =
                agent_wake_admission_is_deferred(&error, self.shutting_down.load(Ordering::SeqCst));
            if !deferred
                && self
                    .event_store
                    .record_agent_wake_failure(session_id, &delivery_ids, &error.to_string())
                    .unwrap_or(false)
            {
                tracing::error!(
                    session_id,
                    "agent delivery wake exhausted setup retries and was demoted to passive"
                );
            }
            tracing::warn!(
                session_id,
                error = %error,
                deferred,
                "failed to admit pending agent-delivery wake"
            );
        }
    }

    pub(super) async fn import_agent_delivery_outbox(&self) {
        let Ok(rows) = self.store.pending_agent_delivery_outbox(128) else {
            return;
        };
        for row in rows {
            let import_lag_seconds = chrono::DateTime::parse_from_rfc3339(&row.created_at)
                .ok()
                .and_then(|created_at| {
                    (chrono::Utc::now() - created_at.with_timezone(&chrono::Utc))
                        .to_std()
                        .ok()
                })
                .map_or(0.0, |duration| duration.as_secs_f64());
            let result = match row.kind.as_str() {
                "terminal" => self.import_terminal_signal(&row).await,
                "delivery" => self.import_delivery_effect(&row).await,
                other => Err(ImportFailure::Permanent(format!(
                    "unsupported agent delivery outbox kind '{other}'"
                ))),
            };
            match result {
                Ok(()) => {
                    let _ = self
                        .store
                        .mark_agent_delivery_outbox_imported(&row.outbox_id);
                    metrics::counter!(
                        "agent_delivery_outbox_imports_total",
                        "disposition" => "imported"
                    )
                    .increment(1);
                    metrics::histogram!("agent_delivery_outbox_import_lag_seconds")
                        .record(import_lag_seconds);
                }
                Err(ImportFailure::Transient(error)) => {
                    let _ = self
                        .store
                        .retry_agent_delivery_outbox(&row.outbox_id, &error);
                    metrics::counter!(
                        "agent_delivery_outbox_imports_total",
                        "disposition" => "retry"
                    )
                    .increment(1);
                }
                Err(ImportFailure::Permanent(error)) => {
                    if self
                        .store
                        .reject_agent_delivery_outbox(&row.outbox_id, &error)
                        .unwrap_or(false)
                    {
                        metrics::counter!(
                            "agent_delivery_outbox_imports_total",
                            "disposition" => "rejected"
                        )
                        .increment(1);
                        metrics::histogram!("agent_delivery_outbox_import_lag_seconds")
                            .record(import_lag_seconds);
                    }
                }
            }
        }
        if let Ok(invocation_ids) = self.event_store.pending_wait_invocation_ids() {
            let _ = self.reconcile_agent_wait_invocations(&invocation_ids);
        }
        if let Ok(exhausted) = self.event_store.retry_exhausted_agent_deliveries(128) {
            for (delivery_id, session_id, error) in exhausted {
                let _ = self.store.record_system_inbox_once(
                    &format!("agent_delivery_attention_{delivery_id}"),
                    "agent-delivery",
                    "wake_retry_exhausted",
                    &json!({
                        "status":"failed",
                        "phase":"agent_delivery_wake",
                        "deliveryId":delivery_id,
                        "sessionId":session_id,
                        "error":error,
                    }),
                );
            }
        }
        self.dispatch_pending_agent_wakes().await;
    }

    async fn dispatch_pending_agent_wakes(&self) {
        let Ok(wakes) = self.event_store.pending_agent_wakes(128) else {
            return;
        };
        for (session_id, delivery_ids) in wakes {
            let causal_depth = self
                .event_store
                .agent_deliveries_by_ids(&delivery_ids)
                .map(|records| {
                    records
                        .into_iter()
                        .map(|delivery| delivery.causal_depth)
                        .max()
                        .unwrap_or_default()
                })
                .unwrap_or_default();
            self.request_agent_delivery_wake(&session_id, causal_depth)
                .await;
        }
    }
}

pub(super) enum ImportFailure {
    Transient(String),
    Permanent(String),
}

fn agent_wake_admission_is_deferred(
    error: &crate::engine::EngineError,
    shutting_down: bool,
) -> bool {
    matches!(
        error,
        crate::engine::EngineError::InvocationCancelled if shutting_down
    ) || matches!(
        error,
        crate::engine::EngineError::DomainFailure { code, .. }
            if matches!(
                code.as_str(),
                "SESSION_BUSY" | "SERVER_BUSY" | "RUNTIME_SERVER_BUSY" | "EVENT_STORE_BUSY"
            )
    )
}

fn mailbox_scope(payload: &Value) -> Result<AgentMailboxScope, String> {
    match payload
        .get("scope")
        .and_then(Value::as_str)
        .unwrap_or("workspace")
    {
        "workspace" => Ok(AgentMailboxScope::Workspace),
        "profile" => Ok(AgentMailboxScope::Profile),
        other => Err(format!("unsupported mailbox scope '{other}'")),
    }
}

fn required_payload_string(payload: &Value, field: &str) -> Result<String, String> {
    payload
        .get(field)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .ok_or_else(|| format!("{field} is required"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mailbox_candidate_omits_an_absent_optional_expiry() {
        let candidate = mailbox_candidate_projection(
            "delivery-test",
            AgentDeliverySourceKind::AgentMessage,
            Some(AgentDeliveryIntent::Information),
            "Reference context",
            "2026-07-28T00:00:00Z",
            None,
        );
        assert!(candidate.get("expiresAt").is_none());

        let expiring = mailbox_candidate_projection(
            "delivery-expiring",
            AgentDeliverySourceKind::AgentMessage,
            Some(AgentDeliveryIntent::Information),
            "Reference context",
            "2026-07-28T00:00:00Z",
            Some("2026-07-29T00:00:00Z"),
        );
        assert_eq!(
            expiring["expiresAt"],
            Value::String("2026-07-29T00:00:00Z".to_owned())
        );
    }

    #[test]
    fn wake_admission_counts_setup_failures_but_not_capacity_or_shutdown_deferrals() {
        let domain = |code: &str| crate::engine::EngineError::DomainFailure {
            domain: "agent".to_owned(),
            code: code.to_owned(),
            message: "test".to_owned(),
            details: None,
        };
        assert!(agent_wake_admission_is_deferred(
            &domain("SESSION_BUSY"),
            false
        ));
        assert!(agent_wake_admission_is_deferred(
            &domain("RUNTIME_SERVER_BUSY"),
            false
        ));
        assert!(agent_wake_admission_is_deferred(
            &crate::engine::EngineError::InvocationCancelled,
            true
        ));
        assert!(!agent_wake_admission_is_deferred(
            &domain("INTERNAL_ERROR"),
            false
        ));
        assert!(!agent_wake_admission_is_deferred(
            &crate::engine::EngineError::InvocationCancelled,
            false
        ));
    }
}
