//! Transactional coordination outbox admission and retry state.
//!
//! Due-time retry, poison compensation, and import leasing remain one durable boundary.

use super::*;

impl WorkerStore {
    /// Queue a semantic agent message for idempotent import into Tron state.
    /// The target agent is validated here but intentionally is not a foreign
    /// key in `tron.sqlite`; the outbox envelope crosses stores by opaque IDs.
    pub(crate) fn enqueue_agent_message_outbox(
        &self,
        request: &NewAgentMessageOutbox,
    ) -> Result<(AgentOutboxRecord, bool), String> {
        validate_runtime_identifier(
            &request.deduplication_key,
            "agent message deduplication key",
            256,
        )?;
        let mut payload = request
            .payload
            .as_object()
            .cloned()
            .ok_or_else(|| "agent message outbox payload must be an object".to_owned())?;
        match payload.get("messagePurpose").and_then(Value::as_str) {
            None | Some("coordination") => {
                payload.insert(
                    "messagePurpose".to_owned(),
                    Value::String("coordination".to_owned()),
                );
            }
            Some(_) => {
                return Err(
                    "agent message payload purpose conflicts with coordination admission"
                        .to_owned(),
                );
            }
        }
        for (field, expected) in [
            ("sourceAgentId", request.source_agent_id.as_str()),
            ("targetAgentId", request.target_agent_id.as_str()),
        ] {
            if let Some(actual) = payload.get(field) {
                if actual.as_str() != Some(expected) {
                    return Err(format!(
                        "agent message payload {field} conflicts with admission"
                    ));
                }
            } else {
                payload.insert(field.to_owned(), Value::String(expected.to_owned()));
            }
        }
        for required in [
            "messageId",
            "channelId",
            "kind",
            "authority",
            "text",
            "sourceSessionId",
            "targetSessionId",
            "traceId",
        ] {
            if !payload
                .get(required)
                .is_some_and(|value| value.as_str().is_some_and(|value| !value.trim().is_empty()))
            {
                return Err(format!(
                    "agent message payload requires non-empty {required}"
                ));
            }
        }
        if !payload.get("autonomousHop").is_some_and(|value| {
            value
                .as_u64()
                .is_some_and(|value| value <= u64::from(u32::MAX))
        }) {
            return Err("agent message payload requires a u32 autonomousHop".to_owned());
        }
        for field in ["messageId", "channelId", "traceId"] {
            validate_runtime_identifier(
                payload
                    .get(field)
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
                field,
                256,
            )?;
        }
        let kind = serde_json::from_value::<AgentMessageKind>(
            payload.get("kind").cloned().unwrap_or(Value::Null),
        )
        .map_err(|_| "agent message payload kind is invalid".to_owned())?;
        let _authority = serde_json::from_value::<AgentMessageAuthority>(
            payload.get("authority").cloned().unwrap_or(Value::Null),
        )
        .map_err(|_| "agent message payload authority is invalid".to_owned())?;
        let has_reply = payload.get("replyTo").is_some_and(|value| !value.is_null());
        if (kind == AgentMessageKind::Answer) != has_reply {
            return Err("only agent answer messages require replyTo".to_owned());
        }
        if let Some(assignment_id) = request.assignment_id.as_deref() {
            payload
                .entry("assignmentId".to_owned())
                .or_insert_with(|| Value::String(assignment_id.to_owned()));
            if payload.get("assignmentId").and_then(Value::as_str) != Some(assignment_id) {
                return Err(
                    "agent message payload assignmentId conflicts with admission".to_owned(),
                );
            }
        }
        let payload = Value::Object(payload);
        if serde_json::to_vec(&payload)
            .map_err(|error| format!("encode agent message outbox payload: {error}"))?
            .len()
            > MAX_MESSAGE_ENVELOPE_BYTES
        {
            return Err(format!(
                "agent message outbox payload exceeds {MAX_MESSAGE_ENVELOPE_BYTES} bytes"
            ));
        }

        let mut connection = self.connection()?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| format!("start agent message outbox enqueue: {error}"))?;
        let source = require_agent(&transaction, &request.source_agent_id, "message source")?;
        let target = require_agent(&transaction, &request.target_agent_id, "message target")?;
        if payload["sourceSessionId"].as_str() != Some(&source.session_id)
            || payload["targetSessionId"].as_str() != Some(&target.session_id)
        {
            return Err("agent message participant session mismatch".to_owned());
        }
        let expected_channel =
            canonical_agent_channel_id(&request.source_agent_id, &request.target_agent_id);
        if payload["channelId"].as_str() != Some(expected_channel.as_str()) {
            return Err("agent message channel does not match its participants".to_owned());
        }
        if target.state == AgentInstanceState::Closed {
            return Err("agent message target is closed".to_owned());
        }
        let execution_id = if let Some(assignment_id) = request.assignment_id.as_deref() {
            let assignment = query_assignment(&transaction, assignment_id)?
                .ok_or_else(|| format!("agent assignment '{assignment_id}' was not found"))?;
            if assignment.agent_id != request.source_agent_id
                && assignment.agent_id != request.target_agent_id
                && assignment.requester_agent_id.as_deref() != Some(&request.source_agent_id)
            {
                return Err("agent message assignment is unrelated to its participants".to_owned());
            }
            Some(assignment.execution_id)
        } else {
            None
        };
        if let Some(existing) = query_outbox_by_key(&transaction, &request.deduplication_key)? {
            if existing.kind != AgentOutboxKind::Message
                || existing.agent_id.as_deref() != Some(&request.source_agent_id)
                || existing.assignment_id.as_deref() != request.assignment_id.as_deref()
                || existing.payload != payload
            {
                return Err("agent message outbox idempotency conflict".to_owned());
            }
            transaction
                .commit()
                .map_err(|error| format!("commit idempotent agent message outbox read: {error}"))?;
            return Ok((existing, false));
        }
        let now = chrono::Utc::now().to_rfc3339();
        let outbox_id = format!("agent_outbox_{}", uuid::Uuid::now_v7());
        transaction
            .execute(
                "INSERT INTO agent_outbox(
                    outbox_id,deduplication_key,kind,agent_id,assignment_id,
                    execution_id,payload_json,created_at
                 ) VALUES (?1,?2,'message',?3,?4,?5,?6,?7)",
                params![
                    outbox_id,
                    request.deduplication_key,
                    request.source_agent_id,
                    request.assignment_id,
                    execution_id,
                    encode_json(&payload)?,
                    now,
                ],
            )
            .map_err(|error| format!("enqueue agent message outbox: {error}"))?;
        let record = query_outbox(&transaction, &outbox_id)?
            .ok_or_else(|| "agent message outbox row disappeared".to_owned())?;
        transaction
            .commit()
            .map_err(|error| format!("commit agent message outbox enqueue: {error}"))?;
        Ok((record, true))
    }

    pub(crate) fn pending_agent_outbox(
        &self,
        limit: usize,
    ) -> Result<Vec<AgentOutboxRecord>, String> {
        self.pending_agent_outbox_due_at(&coordination_outbox_timestamp(chrono::Utc::now()), limit)
    }

    fn pending_agent_outbox_due_at(
        &self,
        due_at: &str,
        limit: usize,
    ) -> Result<Vec<AgentOutboxRecord>, String> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(&format!(
                "SELECT {OUTBOX_COLUMNS} FROM agent_outbox
                 WHERE disposition='pending'
                   AND next_attempt_at<=?1
                   AND NOT EXISTS(
                    SELECT 1 FROM coordination_trace_states trace_state
                    WHERE trace_state.state='paused'
                      AND trace_state.trace_id=COALESCE(
                        (SELECT node.trace_id FROM execution_nodes node
                         WHERE node.execution_id=agent_outbox.execution_id),
                        json_extract(agent_outbox.payload_json,'$.traceId')
                      )
                   )
                 ORDER BY next_attempt_at,created_at,outbox_id LIMIT ?2"
            ))
            .map_err(|error| format!("prepare pending agent outbox: {error}"))?;
        statement
            .query_map(
                params![due_at, i64::try_from(limit.clamp(1, 200)).unwrap_or(200)],
                map_outbox,
            )
            .map_err(|error| format!("query pending agent outbox: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode pending agent outbox: {error}"))
    }

    #[cfg(test)]
    pub(crate) fn pending_agent_outbox_at(
        &self,
        due_at: chrono::DateTime<chrono::Utc>,
        limit: usize,
    ) -> Result<Vec<AgentOutboxRecord>, String> {
        self.pending_agent_outbox_due_at(&coordination_outbox_timestamp(due_at), limit)
    }

    #[cfg(test)]
    pub(crate) fn agent_outbox_for_test(
        &self,
        outbox_id: &str,
    ) -> Result<Option<AgentOutboxRecord>, String> {
        query_outbox(&self.connection()?, outbox_id)
    }

    pub(crate) fn mark_agent_outbox_importing(&self, outbox_id: &str) -> Result<bool, String> {
        self.mark_agent_outbox_importing_at(
            outbox_id,
            &coordination_outbox_timestamp(chrono::Utc::now()),
        )
    }

    fn mark_agent_outbox_importing_at(&self, outbox_id: &str, now: &str) -> Result<bool, String> {
        let connection = self.connection()?;
        connection
            .execute(
                "UPDATE agent_outbox
                 SET disposition='importing',attempts=attempts+1
                 WHERE outbox_id=?1 AND disposition='pending'
                   AND next_attempt_at<=?2
                   AND NOT EXISTS(
                    SELECT 1 FROM coordination_trace_states trace_state
                    WHERE trace_state.state='paused'
                      AND trace_state.trace_id=COALESCE(
                        (SELECT node.trace_id FROM execution_nodes node
                         WHERE node.execution_id=agent_outbox.execution_id),
                        json_extract(agent_outbox.payload_json,'$.traceId')
                      )
                   )",
                params![outbox_id, now],
            )
            .map(|changed| changed == 1)
            .map_err(|error| format!("claim agent outbox row: {error}"))
    }

    #[cfg(test)]
    pub(crate) fn mark_agent_outbox_importing_for_test(
        &self,
        outbox_id: &str,
        now: chrono::DateTime<chrono::Utc>,
    ) -> Result<bool, String> {
        self.mark_agent_outbox_importing_at(outbox_id, &coordination_outbox_timestamp(now))
    }

    pub(crate) fn mark_agent_outbox_imported(&self, outbox_id: &str) -> Result<(), String> {
        let now = chrono::Utc::now().to_rfc3339();
        let connection = self.connection()?;
        let changed = connection
            .execute(
                "UPDATE agent_outbox
                 SET disposition='imported',processed_at=COALESCE(processed_at,?2),last_error=NULL
                 WHERE outbox_id=?1 AND disposition IN ('pending','importing','imported')",
                params![outbox_id, now],
            )
            .map_err(|error| format!("acknowledge agent outbox import: {error}"))?;
        if changed == 0 {
            return Err(format!("agent outbox row '{outbox_id}' is unavailable"));
        }
        Ok(())
    }

    /// Put a failed import back into the durable due-time queue without losing
    /// failure evidence. Claims increment `attempts`; the tenth failed claim
    /// terminally rejects the row so later effects remain independently
    /// runnable.
    pub(crate) fn retry_agent_outbox(
        &self,
        outbox_id: &str,
        error: &str,
    ) -> Result<AgentOutboxRetryOutcome, String> {
        self.retry_agent_outbox_at(outbox_id, error, chrono::Utc::now())
    }

    fn retry_agent_outbox_at(
        &self,
        outbox_id: &str,
        error: &str,
        now: chrono::DateTime<chrono::Utc>,
    ) -> Result<AgentOutboxRetryOutcome, String> {
        let error = bounded_agent_error(error);
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|cause| format!("start agent outbox retry: {cause}"))?;
        let row = query_outbox(&transaction, outbox_id)?
            .ok_or_else(|| format!("agent outbox row '{outbox_id}' was not found"))?;
        if row.disposition == AgentOutboxDisposition::Rejected {
            let processed_at = row.processed_at.ok_or_else(|| {
                format!("rejected agent outbox row '{outbox_id}' lost its terminal timestamp")
            })?;
            transaction
                .commit()
                .map_err(|cause| format!("commit idempotent agent outbox rejection: {cause}"))?;
            return Ok(AgentOutboxRetryOutcome::Rejected {
                attempts: row.attempts,
                processed_at,
            });
        }
        if row.disposition != AgentOutboxDisposition::Importing {
            return Err(format!("agent outbox row '{outbox_id}' is not claimed"));
        }
        let attempts = row.attempts;
        let now_text = coordination_outbox_timestamp(now);
        let outcome = if attempts >= MAX_AGENT_OUTBOX_ATTEMPTS {
            reject_agent_outbox_with_compensation_in_tx(
                &transaction,
                &row,
                &error,
                attempts,
                &now_text,
            )?;
            AgentOutboxRetryOutcome::Rejected {
                attempts,
                processed_at: now_text,
            }
        } else {
            let exponent = attempts.saturating_sub(1).min(30);
            let multiplier = 1_i64.checked_shl(exponent).unwrap_or(i64::MAX);
            let delay_seconds = AGENT_OUTBOX_RETRY_BASE_SECONDS
                .saturating_mul(multiplier)
                .min(AGENT_OUTBOX_RETRY_CAP_SECONDS);
            let next_attempt_at =
                coordination_outbox_timestamp(now + chrono::Duration::seconds(delay_seconds));
            transaction
                .execute(
                    "UPDATE agent_outbox
                     SET disposition='pending',processed_at=NULL,last_error=?2,
                         next_attempt_at=?3
                     WHERE outbox_id=?1 AND disposition='importing'",
                    params![outbox_id, error, next_attempt_at],
                )
                .map_err(|cause| format!("schedule agent outbox retry: {cause}"))?;
            AgentOutboxRetryOutcome::Scheduled {
                attempts,
                next_attempt_at,
            }
        };
        transaction
            .commit()
            .map_err(|cause| format!("commit agent outbox retry: {cause}"))?;
        Ok(outcome)
    }

    #[cfg(test)]
    pub(crate) fn retry_agent_outbox_for_test(
        &self,
        outbox_id: &str,
        error: &str,
        now: chrono::DateTime<chrono::Utc>,
    ) -> Result<AgentOutboxRetryOutcome, String> {
        self.retry_agent_outbox_at(outbox_id, error, now)
    }

    /// Recover every process-local import lease. Cross-store writes are
    /// idempotent, so an uncertain importer must replay rather than reject.
    pub(crate) fn reset_importing_agent_outbox(&self) -> Result<usize, String> {
        let now = coordination_outbox_timestamp(chrono::Utc::now());
        let connection = self.connection()?;
        connection
            .execute(
                "UPDATE agent_outbox
                 SET disposition='pending',processed_at=NULL,next_attempt_at=?1
                 WHERE disposition='importing'",
                [now],
            )
            .map_err(|error| format!("reset importing agent outbox rows: {error}"))
    }
}
