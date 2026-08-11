//! Assignment admission for an existing reusable agent.
//!
//! Queue limits, authority snapshots, execution topology, and semantic delivery commit atomically.

use super::*;

impl WorkerStore {
    /// Enqueue an assignment on an existing reusable agent. Accepted work and
    /// peer offers share one FIFO; only the status differs.
    pub(crate) fn enqueue_agent_assignment(
        &self,
        request: &NewAgentAssignment,
    ) -> Result<(AgentAssignmentRecord, bool), String> {
        validate_existing_assignment(request)?;
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| format!("start reusable agent assignment enqueue: {error}"))?;
        if let Some(existing) =
            query_assignment_by_admission_key(&transaction, &request.admission_key)?
        {
            if existing.agent_id != request.agent_id
                || existing.task != request.task
                || existing.kind != request.kind
                || existing.requester_agent_id != request.requester_agent_id
                || existing.delegator_agent_id != request.delegator_agent_id
                || existing.context != request.context
                || existing.model != request.model
                || existing.reasoning_level != request.reasoning_level
                || existing.authority_snapshot != request.authority_snapshot
                || existing.resource_snapshot != request.resource_snapshot
                || existing.write_scopes_snapshot != request.write_scopes_snapshot
                || existing.limits_snapshot != request.limits_snapshot
                || existing.retry_of_assignment_id != request.retry_of_assignment_id
            {
                return Err("agent assignment idempotency conflict".to_owned());
            }
            let execution = query_execution(&transaction, &existing.execution_id)?
                .ok_or_else(|| "idempotent agent assignment lost its execution".to_owned())?;
            if execution.parent_execution_id != request.parent_execution_id
                || execution.trace_id != request.trace_id
                || execution.causal_depth != request.causal_depth
                || execution.child_slot != request.child_slot
            {
                return Err("agent assignment idempotency conflict".to_owned());
            }
            let mut expected_payload = assignment_message_payload(
                request,
                &existing.assignment_id,
                &existing.execution_id,
            )?;
            expected_payload["expiresAt"] = serde_json::to_value(&existing.deadline_at)
                .map_err(|error| format!("encode durable assignment deadline: {error}"))?;
            let message_outbox =
                query_outbox_by_key(&transaction, &request.message.deduplication_key)?.ok_or_else(
                    || "idempotent agent assignment lost its message outbox".to_owned(),
                )?;
            if message_outbox.kind != AgentOutboxKind::Message
                || message_outbox.agent_id.as_deref()
                    != Some(request.message.source_agent_id.as_str())
                || message_outbox.assignment_id.as_deref() != Some(existing.assignment_id.as_str())
                || message_outbox.execution_id.as_deref() != Some(existing.execution_id.as_str())
                || message_outbox.payload != expected_payload
            {
                return Err("agent assignment message idempotency conflict".to_owned());
            }
            transaction
                .commit()
                .map_err(|error| format!("commit idempotent assignment read: {error}"))?;
            return Ok((existing, false));
        }
        let agent = require_agent(&transaction, &request.agent_id, "assignment target")?;
        if agent.kind == AgentInstanceKind::DirectWorker {
            return Err(
                "direct worker agents own exactly one invocation assignment and cannot be reused"
                    .to_owned(),
            );
        }
        if matches!(
            agent.state,
            AgentInstanceState::Provisioning
                | AgentInstanceState::Closing
                | AgentInstanceState::Closed
        ) {
            return Err(format!(
                "agent '{}' cannot accept work while {}",
                request.agent_id,
                agent.state.as_str()
            ));
        }
        if agent.state == AgentInstanceState::Idle {
            enforce_active_agent_ceiling(
                &transaction,
                &agent.root_session_id,
                Some(&agent.agent_id),
                request.max_active_children,
            )?;
        }
        let effective_queue_ceiling = agent
            .limits
            .get("maxQueuedAssignments")
            .and_then(Value::as_u64)
            .and_then(|value| u32::try_from(value).ok())
            .unwrap_or(request.max_queued_assignments)
            .min(request.max_queued_assignments);
        let queued = transaction
            .query_row(
                "SELECT COUNT(*) FROM agent_assignments
                 WHERE agent_id=?1 AND status IN ('offered','accepted','queued')",
                [&request.agent_id],
                |row| row.get::<_, u32>(0),
            )
            .map_err(|error| format!("count reusable agent queue: {error}"))?;
        if queued >= effective_queue_ceiling {
            return Err(format!(
                "agent assignment queue ceiling ({}) reached",
                effective_queue_ceiling
            ));
        }
        let message_source = require_agent(
            &transaction,
            &request.message.source_agent_id,
            "assignment message source",
        )?;
        if message_source.session_id != request.message.source_session_id {
            return Err("assignment message source session mismatch".to_owned());
        }
        if let Some(requester) = request.requester_agent_id.as_deref() {
            if requester != message_source.agent_id {
                return Err("assignment message source identity/session mismatch".to_owned());
            }
        }
        if agent.session_id != request.message.target_session_id {
            return Err("assignment message target session mismatch".to_owned());
        }
        if let Some(delegator) = request.delegator_agent_id.as_deref() {
            require_agent(&transaction, delegator, "assignment delegator")?;
        }
        let execution_root_session_id = if let Some(parent_execution_id) =
            request.parent_execution_id.as_deref()
        {
            let parent = query_execution(&transaction, parent_execution_id)?
                .ok_or_else(|| format!("parent execution '{parent_execution_id}' was not found"))?;
            if parent.trace_id != request.trace_id
                || request.causal_depth != parent.causal_depth.saturating_add(1)
            {
                return Err("agent assignment parent does not match its causal trace".to_owned());
            }
            if parent.owner_agent_id.as_deref() != Some(message_source.agent_id.as_str()) {
                return Err(
                    "agent assignment parent execution is outside the requester's causal ownership"
                        .to_owned(),
                );
            }
            parent
                .root_session_id
                .unwrap_or_else(|| message_source.root_session_id.clone())
        } else {
            if request.causal_depth != 1 {
                return Err("a root-level agent assignment must begin at causal depth 1".to_owned());
            }
            message_source.root_session_id.clone()
        };
        if let Some(retry_of) = request.retry_of_assignment_id.as_deref() {
            let original = query_assignment(&transaction, retry_of)?
                .ok_or_else(|| format!("retry assignment '{retry_of}' was not found"))?;
            if original.agent_id != request.agent_id || !original.status.is_terminal() {
                return Err(
                    "an assignment retry must target the same agent after terminal state"
                        .to_owned(),
                );
            }
        }
        if request.causal_depth > request.max_causal_depth {
            return Err("agent causal depth exceeds the configured ceiling".to_owned());
        }
        enforce_execution_node_ceiling(
            &transaction,
            &request.trace_id,
            request.max_execution_nodes,
        )?;
        enforce_direct_child_execution_ceiling(
            &transaction,
            &request.trace_id,
            request.parent_execution_id.as_deref(),
            request.max_child_executions,
        )?;
        let assignment_id = format!("assignment_{}", uuid::Uuid::now_v7());
        let execution_id = format!("execution_{}", uuid::Uuid::now_v7());
        let now = chrono::Utc::now().to_rfc3339();
        let queue_ordinal = transaction
            .query_row(
                "SELECT COALESCE(MAX(queue_ordinal),-1)+1
                 FROM agent_assignments WHERE agent_id=?1",
                [&request.agent_id],
                |row| row.get::<_, u64>(0),
            )
            .map_err(|error| format!("allocate reusable agent queue ordinal: {error}"))?;
        let status = if request.offered {
            "offered"
        } else {
            "accepted"
        };
        transaction
            .execute(
                "INSERT INTO execution_nodes(
                    execution_id,kind,parent_execution_id,owner_agent_id,root_session_id,
                    trace_id,causal_depth,child_slot,worker_invocation_id,assignment_id,created_at
                 ) VALUES (?1,'agent_assignment',?2,?3,?4,?5,?6,?7,NULL,?8,?9)",
                params![
                    execution_id,
                    request.parent_execution_id,
                    request.agent_id,
                    execution_root_session_id,
                    request.trace_id,
                    request.causal_depth,
                    request.child_slot,
                    assignment_id,
                    now,
                ],
            )
            .map_err(|error| format!("insert reusable assignment execution: {error}"))?;
        transaction
            .execute(
                "INSERT INTO agent_assignments(
                    assignment_id,execution_id,agent_id,requester_agent_id,delegator_agent_id,
                    kind,status,admission_key,queue_ordinal,task,context_json,model,
                    reasoning_level,authority_snapshot_json,resource_snapshot_json,
                    write_scopes_snapshot_json,limits_snapshot_json,retry_of_assignment_id,
                    deadline_at,created_at,accepted_at,updated_at
                 ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,
                           ?15,?16,?17,?18,?19,?20,?21,?20)",
                params![
                    assignment_id,
                    execution_id,
                    request.agent_id,
                    request.requester_agent_id,
                    request.delegator_agent_id,
                    request.kind.as_str(),
                    status,
                    request.admission_key,
                    queue_ordinal,
                    request.task,
                    encode_json(&request.context)?,
                    request.model.as_ref().or(agent.default_model.as_ref()),
                    request
                        .reasoning_level
                        .as_ref()
                        .or(agent.default_reasoning_level.as_ref()),
                    encode_json(&request.authority_snapshot)?,
                    encode_json(&request.resource_snapshot)?,
                    encode_json(&request.write_scopes_snapshot)?,
                    encode_json(&request.limits_snapshot)?,
                    request.retry_of_assignment_id,
                    request.deadline_at,
                    now,
                    (!request.offered).then_some(now.as_str()),
                ],
            )
            .map_err(|error| format!("insert reusable agent assignment: {error}"))?;
        append_execution_event_in_tx(
            &transaction,
            &execution_id,
            status,
            &json!({"status":status}),
            &now,
        )?;
        let message_payload = assignment_message_payload(request, &assignment_id, &execution_id)?;
        transaction
            .execute(
                "INSERT INTO agent_outbox(
                    outbox_id,deduplication_key,kind,agent_id,assignment_id,
                    execution_id,payload_json,created_at
                 ) VALUES (?1,?2,'message',?3,?4,?5,?6,?7)",
                params![
                    format!("agent_outbox_{}", uuid::Uuid::now_v7()),
                    request.message.deduplication_key,
                    request.message.source_agent_id,
                    assignment_id,
                    execution_id,
                    encode_json(&message_payload)?,
                    now,
                ],
            )
            .map_err(|error| format!("enqueue reusable agent assignment delivery: {error}"))?;
        transaction
            .execute(
                "UPDATE agent_instances SET state='active',updated_at=?2
                 WHERE agent_id=?1 AND state='idle'",
                params![request.agent_id, now],
            )
            .map_err(|error| format!("activate reusable agent queue: {error}"))?;
        let record = query_assignment(&transaction, &assignment_id)?
            .ok_or_else(|| "enqueued reusable assignment disappeared".to_owned())?;
        transaction
            .commit()
            .map_err(|error| format!("commit reusable agent assignment: {error}"))?;
        record_agent_assignment_admission_metrics(&record);
        Ok((record, true))
    }
}
