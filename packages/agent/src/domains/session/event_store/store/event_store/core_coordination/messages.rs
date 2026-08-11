//! Semantic agent messaging and safe-boundary wake leasing.

use super::*;

impl EventStore {
    /// Persist semantic communication and its consequences in one transaction.
    /// Instruction/request messages create their assignment here; the caller
    /// cannot supply a wake policy or fabricate assignment identity.
    pub(crate) fn send_core_agent_message(
        &self,
        request: &SendMessage,
    ) -> Result<MessageAdmission> {
        validate_admission_key(&request.idempotency_key)?;
        validate_identifier("source agent id", &request.source_agent_id)?;
        validate_identifier("target agent id", &request.target_agent_id)?;
        validate_identifier("message trace id", &request.trace_id)?;
        validate_bounded_text("agent message", &request.content, MAX_MESSAGE_BYTES)?;
        self.with_global_write_lock(|| {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let source = require_open_agent(&transaction, &request.source_agent_id)?;
            let target = require_open_agent(&transaction, &request.target_agent_id)?;
            let trace_root =
                query_agent(&transaction, &source.root_agent_id)?.ok_or_else(|| {
                    EventStoreError::Internal("message source root agent disappeared".to_owned())
                })?;
            ensure_coordination_trace_in_tx(
                &transaction,
                &request.trace_id,
                &trace_root.agent_id,
                &trace_root.transcript_session_id,
            )?;
            let source_manages_target = source.agent_id != target.agent_id
                && agent_manages_in_tx(&transaction, &source.agent_id, &target.agent_id)?;
            if request.kind == MessageKind::Instruction && !source_manages_target {
                return Err(EventStoreError::InvalidOperation(
                    "peer agents may request work but cannot issue instructions".to_owned(),
                ));
            }
            match request.kind {
                MessageKind::Instruction | MessageKind::Request
                    if request.assignment_id.is_some() =>
                {
                    return Err(EventStoreError::InvalidOperation(
                        "instruction/request assignment identity is engine-authored".to_owned(),
                    ));
                }
                MessageKind::Answer if request.reply_to_message_id.is_none() => {
                    return Err(EventStoreError::InvalidOperation(
                        "agent answer requires an exact question handle".to_owned(),
                    ));
                }
                MessageKind::Question if request.reply_to_message_id.is_some() => {
                    return Err(EventStoreError::InvalidOperation(
                        "agent question cannot answer another message".to_owned(),
                    ));
                }
                MessageKind::Update if request.assignment_id.is_none() => {
                    return Err(EventStoreError::InvalidOperation(
                        "agent update requires an assignment handle".to_owned(),
                    ));
                }
                _ => {}
            }

            let message_id = stable_id("agent_message", &[&request.idempotency_key]);
            let assignment = if matches!(
                request.kind,
                MessageKind::Instruction | MessageKind::Request
            ) {
                Some(admit_assignment_in_tx(
                    &transaction,
                    &NewAssignment {
                        admission_key: stable_id(
                            "message_assignment_admission",
                            &[&request.idempotency_key],
                        ),
                        agent_id: target.agent_id.clone(),
                        requested_by_agent_id: Some(source.agent_id.clone()),
                        parent_assignment_id: request.parent_assignment_id.clone(),
                        retry_of_assignment_id: None,
                        kind: if request.kind == MessageKind::Instruction {
                            AssignmentKind::Instruction
                        } else {
                            AssignmentKind::Request
                        },
                        task: request.content.clone(),
                        context: serde_json::json!({"messageId":message_id}),
                        trace_id: Some(request.trace_id.clone()),
                        autonomous_hop: request.autonomous_hop,
                        model: None,
                        reasoning_level: None,
                        capability_grant: None,
                        write_scopes: None,
                        limits: None,
                        deadline_at: None,
                    },
                )?)
            } else {
                None
            };
            let assignment_id = assignment
                .as_ref()
                .map(|assignment| assignment.assignment_id.clone())
                .or_else(|| request.assignment_id.clone());
            if let Some(assignment_id) = assignment_id.as_deref()
                && !matches!(
                    request.kind,
                    MessageKind::Instruction | MessageKind::Request
                )
            {
                let referenced =
                    query_assignment(&transaction, assignment_id)?.ok_or_else(|| {
                        EventStoreError::InvalidOperation(format!(
                            "agent assignment '{assignment_id}' was not found"
                        ))
                    })?;
                if referenced.agent_id != target.agent_id {
                    return Err(EventStoreError::InvalidOperation(
                        "agent message assignment does not belong to its recipient".to_owned(),
                    ));
                }
                if request.kind == MessageKind::Update
                    && referenced.requested_by_agent_id.as_deref() != Some(source.agent_id.as_str())
                    && !source_manages_target
                {
                    return Err(EventStoreError::InvalidOperation(
                        "agent update sender is not the requester or manager".to_owned(),
                    ));
                }
            }
            let authority = if source_manages_target {
                AgentMessageAuthority::Owner
            } else {
                AgentMessageAuthority::Peer
            };
            let semantic_kind = match request.kind {
                MessageKind::Instruction => AgentMessageKind::Instruction,
                MessageKind::Request => AgentMessageKind::Request,
                MessageKind::Question => AgentMessageKind::Question,
                MessageKind::Answer => AgentMessageKind::Answer,
                MessageKind::Information => AgentMessageKind::Information,
                MessageKind::Update => AgentMessageKind::Update,
            };
            let metadata = record_agent_message_in_tx(
                &transaction,
                &NewAgentMessageMetadata {
                    idempotency_key: request.idempotency_key.clone(),
                    channel_id: canonical_agent_channel_id(&source.agent_id, &target.agent_id),
                    channel_sequence: None,
                    source_session_id: Some(source.transcript_session_id.clone()),
                    target_agent_id: target.agent_id.clone(),
                    target_session_id: target.transcript_session_id.clone(),
                    trace_id: request.trace_id.clone(),
                    autonomous_hop: request.autonomous_hop,
                    content: AgentMessageContent {
                        message_id,
                        source_agent_id: source.agent_id,
                        source_name: Some(source.name),
                        kind: semantic_kind,
                        authority,
                        text: request.content.clone(),
                        assignment_id: assignment_id.clone(),
                        reply_to: request.reply_to_message_id.clone(),
                    },
                },
            )?;
            let active_assignment_id = transaction
                .query_row(
                    "SELECT assignment_id FROM agent_assignments
                     WHERE agent_id=?1 AND status IN ('running','waiting')
                     LIMIT 1",
                    [&target.agent_id],
                    |row| row.get::<_, String>(0),
                )
                .optional()?;
            let wake_assignment_id = active_assignment_id.or_else(|| assignment_id.clone());
            let autonomy_paused = record_coordination_message_in_tx(
                &transaction,
                &request.trace_id,
                request.autonomous_hop,
                &target.agent_id,
                wake_assignment_id.as_deref(),
            )?;
            let wake = if request.kind.is_actionable() && !autonomy_paused {
                Some(insert_wake_in_tx(
                    &transaction,
                    &target.agent_id,
                    &target.transcript_session_id,
                    wake_assignment_id.as_deref(),
                    "message",
                    &metadata.message_id,
                    &request.trace_id,
                    request.autonomous_hop,
                    message_priority(authority, request.kind),
                    None,
                )?)
            } else {
                None
            };
            transaction.commit()?;
            Ok(MessageAdmission {
                message_id: metadata.message_id,
                assignment,
                wake,
                autonomy_paused,
            })
        })
    }
    pub(crate) fn pending_core_agent_wakes(&self, limit: usize) -> Result<Vec<WakeIntentRecord>> {
        let connection = self.conn()?;
        let mut statement = connection.prepare(&format!(
            "SELECT {WAKE_COLUMNS} FROM agent_wake_intents
             WHERE disposition='pending'
               AND NOT EXISTS(
                 SELECT 1 FROM agent_coordination_traces trace
                 WHERE trace.trace_id=agent_wake_intents.trace_id AND trace.state='paused'
               )
               AND (not_before IS NULL OR rfc3339_sort_key(not_before)<=rfc3339_sort_key(?1))
             ORDER BY priority,created_at,wake_id LIMIT ?2"
        ))?;
        statement
            .query_map(
                params![
                    chrono::Utc::now().to_rfc3339(),
                    i64::try_from(limit.clamp(1, 256)).unwrap_or(256)
                ],
                map_wake,
            )?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(EventStoreError::from)
    }

    pub(crate) fn core_wake_record(&self, wake_id: &str) -> Result<Option<WakeIntentRecord>> {
        validate_identifier("wake id", wake_id)?;
        let connection = self.conn()?;
        query_wake(&connection, wake_id)
    }

    /// Bind the exact transcript message materialized for one wake. Replay is
    /// a CAS on the same message; a different binding is a hard audit conflict.
    pub(crate) fn bind_core_wake_message(&self, wake_id: &str, message_id: &str) -> Result<bool> {
        validate_identifier("wake id", wake_id)?;
        validate_identifier("wake materialized message id", message_id)?;
        self.with_global_write_lock(|| {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let wake = query_wake(&transaction, wake_id)?.ok_or_else(|| {
                EventStoreError::InvalidOperation(format!("agent wake '{wake_id}' was not found"))
            })?;
            let message_target = transaction
                .query_row(
                    "SELECT target_session_id FROM agent_message_metadata WHERE message_id=?1",
                    [message_id],
                    |row| row.get::<_, String>(0),
                )
                .optional()?
                .ok_or_else(|| {
                    EventStoreError::InvalidOperation(format!(
                        "agent message '{message_id}' was not found"
                    ))
                })?;
            if message_target != wake.target_session_id
                || (wake.cause_kind == "message" && wake.cause_id != message_id)
            {
                return Err(EventStoreError::InvalidOperation(
                    "wake materialized message provenance conflict".to_owned(),
                ));
            }
            let changed = transaction.execute(
                "UPDATE agent_wake_intents SET materialized_message_id=?2
                 WHERE wake_id=?1 AND materialized_message_id IS NULL",
                params![wake_id, message_id],
            )?;
            let bound = query_wake(&transaction, wake_id)?
                .ok_or_else(|| EventStoreError::Internal("bound wake disappeared".to_owned()))?;
            if bound.materialized_message_id.as_deref() != Some(message_id) {
                return Err(EventStoreError::InvalidOperation(
                    "wake is already bound to a different materialized message".to_owned(),
                ));
            }
            transaction.commit()?;
            Ok(changed == 1)
        })
    }

    /// Lease one due wake for delivery at an Agent Execution safe boundary.
    pub(crate) fn lease_next_core_agent_wake(
        &self,
        agent_id: &str,
        lease_id: &str,
    ) -> Result<Option<WakeIntentRecord>> {
        validate_identifier("wake agent id", agent_id)?;
        validate_identifier("wake lease id", lease_id)?;
        self.with_global_write_lock(|| {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let now = chrono::Utc::now().to_rfc3339();
            let wake_id = transaction
                .query_row(
                    "SELECT wake_id FROM agent_wake_intents
                     WHERE target_agent_id=?1 AND disposition='pending'
                       AND NOT EXISTS(
                         SELECT 1 FROM agent_coordination_traces trace
                         WHERE trace.trace_id=agent_wake_intents.trace_id
                           AND trace.state='paused'
                       )
                       AND (not_before IS NULL
                         OR rfc3339_sort_key(not_before)<=rfc3339_sort_key(?2))
                     ORDER BY priority,created_at,wake_id LIMIT 1",
                    params![agent_id, now],
                    |row| row.get::<_, String>(0),
                )
                .optional()?;
            let Some(wake_id) = wake_id else {
                transaction.commit()?;
                return Ok(None);
            };
            transaction.execute(
                "UPDATE agent_wake_intents
                 SET disposition='leased',lease_id=?2,lease_count=lease_count+1,
                     leased_at=?3,last_error=NULL
                 WHERE wake_id=?1 AND disposition='pending'",
                params![wake_id, lease_id, now],
            )?;
            let wake = query_wake(&transaction, &wake_id)?;
            transaction.commit()?;
            Ok(wake)
        })
    }

    pub(crate) fn finish_core_agent_wake(
        &self,
        wake_id: &str,
        lease_id: &str,
        delivered: bool,
        error: Option<&str>,
    ) -> Result<WakeIntentRecord> {
        validate_identifier("wake id", wake_id)?;
        validate_identifier("wake lease id", lease_id)?;
        if let Some(error) = error {
            validate_bounded_text("wake error", error, MAX_MESSAGE_BYTES)?;
        }
        self.with_global_write_lock(|| {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let wake = query_wake(&transaction, wake_id)?.ok_or_else(|| {
                EventStoreError::InvalidOperation(format!("agent wake '{wake_id}' was not found"))
            })?;
            if delivered
                && wake.disposition == "delivered"
                && wake.delivered_by_lease_id.as_deref() == Some(lease_id)
            {
                transaction.commit()?;
                return Ok(wake);
            }
            let now = chrono::Utc::now().to_rfc3339();
            let changed = if delivered {
                transaction.execute(
                    "UPDATE agent_wake_intents
                     SET disposition='delivered',lease_id=NULL,delivered_by_lease_id=?2,
                         delivered_at=?3,last_error=NULL
                     WHERE wake_id=?1 AND disposition='leased' AND lease_id=?2",
                    params![wake_id, lease_id, now],
                )?
            } else {
                transaction.execute(
                    "UPDATE agent_wake_intents
                     SET disposition='pending',lease_id=NULL,leased_at=NULL,last_error=?3
                     WHERE wake_id=?1 AND disposition='leased' AND lease_id=?2",
                    params![wake_id, lease_id, error],
                )?
            };
            if changed != 1 {
                return Err(EventStoreError::InvalidOperation(
                    "wake lease no longer belongs to this delivery".to_owned(),
                ));
            }
            if delivered
                && let Some(assignment_id) = wake.target_assignment_id.as_deref()
                && let Some(assignment) = query_assignment(&transaction, assignment_id)?
                && assignment.status == AssignmentStatus::Waiting
            {
                set_active_assignment_state_in_tx(
                    &transaction,
                    &assignment,
                    AssignmentStatus::Running,
                    &now,
                )?;
            }
            let finished = query_wake(&transaction, wake_id)?
                .ok_or_else(|| EventStoreError::Internal("finished wake disappeared".to_owned()))?;
            transaction.commit()?;
            Ok(finished)
        })
    }

    /// Startup recovery: provider/tool work cannot survive process restart, so
    /// every unacknowledged lease becomes pending with the same durable cause.
    pub(crate) fn recover_core_agent_wake_leases(&self) -> Result<usize> {
        self.with_global_write_lock(|| {
            let connection = self.conn()?;
            connection
                .execute(
                    "UPDATE agent_wake_intents
                     SET disposition='pending',lease_id=NULL,leased_at=NULL,
                         last_error=COALESCE(last_error,'interrupted before safe-boundary delivery')
                     WHERE disposition='leased'",
                    [],
                )
                .map_err(EventStoreError::from)
        })
    }
}
