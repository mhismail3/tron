//! Durable invocation, attempt, trace, success, and audit ledgers.

use super::*;

impl WorkerStore {
    #[cfg(test)]
    pub fn begin_invocation(
        &self,
        worker_id: &str,
        worker_version: &str,
        input: &Value,
        idempotency_key: &str,
        trace_id: &str,
        causal_depth: u32,
        trigger_kind: &str,
        origin_session_id: Option<&str>,
    ) -> Result<(InvocationRecord, bool), String> {
        self.begin_invocation_with_context(
            worker_id,
            worker_version,
            input,
            idempotency_key,
            trace_id,
            causal_depth,
            trigger_kind,
            origin_session_id,
            WorkerInteractionMode::Foreground,
            None,
            None,
            None,
            None,
            None,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn begin_invocation_with_context(
        &self,
        worker_id: &str,
        worker_version: &str,
        input: &Value,
        idempotency_key: &str,
        trace_id: &str,
        causal_depth: u32,
        trigger_kind: &str,
        origin_session_id: Option<&str>,
        interaction_mode: WorkerInteractionMode,
        model_tool_invocation_id: Option<&str>,
        parent_worker_invocation_id: Option<&str>,
        parent_worker_tool_ordinal: Option<u32>,
        retry_of_invocation_id: Option<&str>,
        max_sibling_invocations: Option<u32>,
    ) -> Result<(InvocationRecord, bool), String> {
        validate_runtime_identifier(idempotency_key, "idempotency key", 256)?;
        validate_runtime_identifier(trace_id, "trace id", 256)?;
        validate_runtime_identifier(trigger_kind, "trigger kind", 64)?;
        if let Some(session_id) = origin_session_id {
            validate_runtime_identifier(session_id, "origin session id", 256)?;
        }
        if let Some(invocation_id) = model_tool_invocation_id {
            validate_runtime_identifier(invocation_id, "model tool invocation id", 256)?;
        }
        if let Some(invocation_id) = parent_worker_invocation_id {
            validate_runtime_identifier(invocation_id, "parent worker invocation id", 256)?;
        }
        if let Some(invocation_id) = retry_of_invocation_id {
            validate_runtime_identifier(invocation_id, "retry invocation id", 256)?;
        }
        if let (Some(parent_id), Some(ordinal)) =
            (parent_worker_invocation_id, parent_worker_tool_ordinal)
            && let Some(existing) =
                self.invocation_by_parent_tool_slot(parent_id, worker_id, ordinal)?
        {
            self.record_result_association(&existing.invocation_id, model_tool_invocation_id)?;
            self.record_suppressed_delivery(
                trace_id,
                worker_id,
                trigger_kind,
                idempotency_key,
                causal_depth,
            )?;
            return Ok((existing, true));
        }
        if let Some(existing) = self.invocation_by_key(worker_id, idempotency_key)? {
            self.record_result_association(&existing.invocation_id, model_tool_invocation_id)?;
            self.record_suppressed_delivery(
                trace_id,
                worker_id,
                trigger_kind,
                idempotency_key,
                causal_depth,
            )?;
            return Ok((existing, true));
        }
        let invocation_id = format!("worker_run_{}", uuid::Uuid::now_v7());
        let created_at = chrono::Utc::now().to_rfc3339();
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| format!("start worker invocation queue transaction: {error}"))?;
        // INVARIANT: a causal trace keeps the root session that admitted it.
        // Nested agent workers execute in child sessions, but they must remain
        // attributable to the user session that began the trace.
        let inherited_origin = transaction
            .query_row(
                "SELECT origin_session_id FROM worker_invocations
                 WHERE trace_id=?1
                 ORDER BY causal_depth ASC, created_at ASC
                 LIMIT 1",
                [trace_id],
                |row| row.get::<_, Option<String>>(0),
            )
            .optional()
            .map_err(|error| format!("load worker trace origin session: {error}"))?;
        let effective_origin = match inherited_origin {
            Some(origin) => origin,
            None => origin_session_id.map(ToOwned::to_owned),
        };
        if let Some(parent_id) = parent_worker_invocation_id {
            let parent = transaction
                .query_row(
                    "SELECT trace_id,causal_depth FROM worker_invocations
                     WHERE invocation_id=?1",
                    [parent_id],
                    |row| Ok((row.get::<_, String>(0)?, row.get::<_, u32>(1)?)),
                )
                .optional()
                .map_err(|error| format!("load parent worker invocation: {error}"))?
                .ok_or_else(|| format!("parent worker invocation '{parent_id}' was not found"))?;
            if parent.0 != trace_id || causal_depth != parent.1.saturating_add(1) {
                return Err(format!(
                    "parent worker invocation '{parent_id}' does not match this causal trace"
                ));
            }
            if let Some(limit) = max_sibling_invocations {
                let admitted = transaction
                    .query_row(
                        "SELECT COUNT(*) FROM worker_invocations
                         WHERE parent_worker_invocation_id=?1",
                        [parent_id],
                        |row| row.get::<_, u32>(0),
                    )
                    .map_err(|error| format!("count child worker invocations: {error}"))?;
                if admitted >= limit {
                    return Err(format!(
                        "worker child invocation ceiling ({limit}) reached for '{parent_id}'"
                    ));
                }
            }
        }
        let detached_at =
            (interaction_mode == WorkerInteractionMode::Background).then(|| created_at.clone());
        let insert = transaction.execute(
            "INSERT INTO worker_invocations(
                    invocation_id,worker_id,worker_version,status,input_json,
                    idempotency_key,trace_id,causal_depth,trigger_kind,
                    origin_session_id,interaction_mode,detached_at,
                    model_tool_invocation_id,parent_worker_invocation_id,
                    parent_worker_tool_ordinal,retry_of_invocation_id,created_at
                 )
                 VALUES (?1,?2,?3,'queued',?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16)",
            params![
                invocation_id,
                worker_id,
                worker_version,
                serde_json::to_string(input).map_err(|error| error.to_string())?,
                idempotency_key,
                trace_id,
                causal_depth,
                trigger_kind,
                effective_origin,
                interaction_mode.as_str(),
                detached_at,
                model_tool_invocation_id,
                parent_worker_invocation_id,
                parent_worker_tool_ordinal,
                retry_of_invocation_id,
                created_at,
            ],
        );
        if let Err(error) = insert {
            drop(transaction);
            if let (Some(parent_id), Some(ordinal)) =
                (parent_worker_invocation_id, parent_worker_tool_ordinal)
                && let Some(existing) =
                    self.invocation_by_parent_tool_slot(parent_id, worker_id, ordinal)?
            {
                self.record_result_association(&existing.invocation_id, model_tool_invocation_id)?;
                self.record_suppressed_delivery(
                    trace_id,
                    worker_id,
                    trigger_kind,
                    idempotency_key,
                    causal_depth,
                )?;
                return Ok((existing, true));
            }
            if let Some(existing) = self.invocation_by_key(worker_id, idempotency_key)? {
                self.record_result_association(&existing.invocation_id, model_tool_invocation_id)?;
                self.record_suppressed_delivery(
                    trace_id,
                    worker_id,
                    trigger_kind,
                    idempotency_key,
                    causal_depth,
                )?;
                return Ok((existing, true));
            }
            return Err(format!("queue worker invocation: {error}"));
        }
        if let Some(model_tool_invocation_id) = model_tool_invocation_id {
            transaction
                .execute(
                    "INSERT INTO worker_model_tool_result_associations(
                        model_tool_invocation_id,
                        worker_invocation_id,
                        created_at
                     )
                     VALUES (?1,?2,?3)",
                    params![model_tool_invocation_id, invocation_id, created_at],
                )
                .map_err(|error| format!("record worker result association: {error}"))?;
        }
        upsert_causal_trace(
            &transaction,
            trace_id,
            Some(&invocation_id),
            causal_depth,
            false,
        )?;
        transaction
            .execute(
                "INSERT INTO worker_trace_deliveries(trace_id,worker_id,trigger_kind,idempotency_key,invocation_id,created_at)
                 VALUES (?1,?2,?3,?4,?5,?6)",
                params![
                    trace_id,
                    worker_id,
                    trigger_kind,
                    idempotency_key,
                    invocation_id,
                    created_at,
                ],
            )
            .map_err(|error| format!("record worker trace delivery: {error}"))?;
        insert_run_event(
            &transaction,
            &invocation_id,
            WorkerRunStage::Queued,
            "Queued for durable worker execution",
            &created_at,
        )?;
        if interaction_mode == WorkerInteractionMode::Background {
            insert_run_event(
                &transaction,
                &invocation_id,
                WorkerRunStage::Detached,
                "Conversation released while durable work continues",
                &created_at,
            )?;
        }
        transaction
            .commit()
            .map_err(|error| format!("commit queued worker invocation: {error}"))?;
        let record = self
            .invocation(&invocation_id)?
            .ok_or_else(|| "queued worker invocation disappeared".to_owned())?;
        Ok((record, false))
    }

    pub fn claim_running(&self, invocation_id: &str) -> Result<bool, String> {
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| format!("start worker delivery attempt: {error}"))?;
        let started_at = chrono::Utc::now().to_rfc3339();
        let changed = transaction
            .execute(
                "UPDATE worker_invocations SET status='running',started_at=?2
                 WHERE invocation_id=?1 AND status='queued'",
                params![invocation_id, started_at],
            )
            .map_err(|error| format!("mark worker invocation running: {error}"))?;
        if changed == 1 {
            transaction
                .execute(
                    "UPDATE worker_dispatches SET state='running'
                     WHERE target_invocation_id=?1 AND state='queued'",
                    [invocation_id],
                )
                .map_err(|error| format!("mark inbound worker dispatch running: {error}"))?;
            let attempt_number = transaction
                .query_row(
                    "SELECT COALESCE(MAX(attempt_number),0)+1 FROM worker_attempts WHERE invocation_id=?1",
                    [invocation_id],
                    |row| row.get::<_, u32>(0),
                )
                .map_err(|error| format!("number worker delivery attempt: {error}"))?;
            transaction
                .execute(
                    "INSERT INTO worker_attempts(attempt_id,invocation_id,attempt_number,status,started_at)
                     VALUES (?1,?2,?3,'running',?4)",
                    params![
                        format!("worker_attempt_{}", uuid::Uuid::now_v7()),
                        invocation_id,
                        attempt_number,
                        started_at,
                    ],
                )
                .map_err(|error| format!("record worker delivery attempt: {error}"))?;
            let manifest = transaction
                .query_row(
                    "SELECT version.manifest_json
                     FROM worker_invocations invocation
                     JOIN worker_versions version
                       ON version.worker_id=invocation.worker_id
                      AND version.version=invocation.worker_version
                     WHERE invocation.invocation_id=?1",
                    [invocation_id],
                    |row| row.get::<_, String>(0),
                )
                .map_err(|error| format!("load worker runner for stage evidence: {error}"))?;
            let bundle = serde_json::from_str::<WorkerBundle>(&manifest)
                .map_err(|error| format!("decode worker runner for stage evidence: {error}"))?;
            let (stage, summary) = if attempt_number > 1 {
                (
                    WorkerRunStage::RetryRepair,
                    "Retrying interrupted durable delivery",
                )
            } else if matches!(bundle.runner, WorkerRunner::Agent { .. }) {
                (WorkerRunStage::Planning, "Planning worker execution")
            } else {
                (
                    WorkerRunStage::SpecialistExecution,
                    "Executing the worker runner",
                )
            };
            insert_run_event(&transaction, invocation_id, stage, summary, &started_at)?;
        }
        transaction
            .commit()
            .map_err(|error| format!("commit worker delivery attempt: {error}"))?;
        Ok(changed == 1)
    }

    /// Terminalize the current delivery attempt and return the same invocation
    /// to the durable queue.
    ///
    /// This is used only when runtime ownership disappears before a typed
    /// result can be committed. Domain retry policy remains inside the worker;
    /// the kernel merely preserves at-least-once delivery evidence.
    pub fn interrupt_running_invocation(
        &self,
        invocation_id: &str,
        reason: &str,
    ) -> Result<InvocationRecord, String> {
        validate_runtime_identifier(invocation_id, "invocation id", 256)?;
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| format!("start worker interruption recovery: {error}"))?;
        let current = transaction
            .query_row(
                "SELECT worker_id,status FROM worker_invocations WHERE invocation_id=?1",
                [invocation_id],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )
            .optional()
            .map_err(|error| format!("load interrupted worker invocation: {error}"))?
            .ok_or_else(|| format!("worker invocation '{invocation_id}' was not found"))?;
        if current.1 != "running" {
            drop(transaction);
            return self
                .invocation(invocation_id)?
                .ok_or_else(|| "worker invocation disappeared during interruption".to_owned());
        }
        let interrupted_at = chrono::Utc::now().to_rfc3339();
        transaction
            .execute(
                "UPDATE worker_attempts
                 SET status='interrupted',completed_at=?2,error=?3
                 WHERE invocation_id=?1 AND status='running'",
                params![invocation_id, interrupted_at, reason],
            )
            .map_err(|error| format!("interrupt worker delivery attempt: {error}"))?;
        transaction
            .execute(
                "UPDATE worker_invocations
                 SET status='queued',started_at=NULL,agent_session_id=NULL
                 WHERE invocation_id=?1 AND status='running'",
                [invocation_id],
            )
            .map_err(|error| format!("requeue interrupted worker invocation: {error}"))?;
        transaction
            .execute(
                "UPDATE worker_dispatches SET state='queued'
                 WHERE target_invocation_id=?1 AND state='running'",
                [invocation_id],
            )
            .map_err(|error| format!("requeue interrupted worker dispatch: {error}"))?;
        insert_run_event(
            &transaction,
            invocation_id,
            WorkerRunStage::Interrupted,
            "Delivery ownership ended before a durable terminal result",
            &interrupted_at,
        )?;
        insert_run_event(
            &transaction,
            invocation_id,
            WorkerRunStage::Queued,
            "Queued for durable redelivery after interruption",
            &interrupted_at,
        )?;
        insert_audit(
            &transaction,
            &current.0,
            "invocation_interrupted",
            &json!({"invocationId":invocation_id,"reason":reason}),
        )?;
        transaction
            .commit()
            .map_err(|error| format!("commit worker interruption recovery: {error}"))?;
        self.invocation(invocation_id)?
            .ok_or_else(|| "requeued worker invocation disappeared".to_owned())
    }

    /// Count immutable interrupted-attempt evidence for one worker and reason.
    ///
    /// Runtime recovery uses this instead of process-local counters so repeated
    /// ownership loss remains visible across engine restarts.
    pub fn interrupted_attempt_count(&self, worker_id: &str, reason: &str) -> Result<u32, String> {
        validate_runtime_identifier(worker_id, "worker id", 256)?;
        self.connection()?
            .query_row(
                "SELECT COUNT(*)
                 FROM worker_attempts attempt
                 JOIN worker_invocations invocation
                   ON invocation.invocation_id=attempt.invocation_id
                 WHERE invocation.worker_id=?1
                   AND attempt.status='interrupted'
                   AND attempt.error=?2",
                params![worker_id, reason],
                |row| row.get::<_, u32>(0),
            )
            .map_err(|error| format!("count interrupted worker attempts: {error}"))
    }

    pub fn set_agent_session_id(
        &self,
        invocation_id: &str,
        session_id: &str,
    ) -> Result<(), String> {
        validate_runtime_identifier(session_id, "agent session id", 256)?;
        let changed = self
            .connection()?
            .execute(
                "UPDATE worker_invocations SET agent_session_id=?2
                 WHERE invocation_id=?1 AND status='running' AND agent_session_id IS NULL",
                params![invocation_id, session_id],
            )
            .map_err(|error| format!("link agent session to worker invocation: {error}"))?;
        if changed != 1 {
            return Err(format!(
                "worker invocation '{invocation_id}' was not running or already had an agent session"
            ));
        }
        Ok(())
    }

    pub fn cancel_invocation(&self, invocation_id: &str) -> Result<InvocationRecord, String> {
        validate_runtime_identifier(invocation_id, "invocation id", 256)?;
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| format!("start worker invocation cancellation: {error}"))?;
        let current = transaction
            .query_row(
                "SELECT worker_id,status FROM worker_invocations WHERE invocation_id=?1",
                [invocation_id],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )
            .optional()
            .map_err(|error| format!("load worker invocation for cancellation: {error}"))?
            .ok_or_else(|| format!("worker invocation '{invocation_id}' was not found"))?;
        if matches!(current.1.as_str(), "completed" | "failed" | "cancelled") {
            drop(transaction);
            return self
                .invocation(invocation_id)?
                .ok_or_else(|| "terminal worker invocation disappeared".to_owned());
        }
        let completed_at = chrono::Utc::now().to_rfc3339();
        let reason = "worker invocation cancelled explicitly";
        let changed = transaction
            .execute(
                "UPDATE worker_invocations SET status='cancelled',error=?2,completed_at=?3
                 WHERE invocation_id=?1 AND status IN ('queued','running')",
                params![invocation_id, reason, completed_at],
            )
            .map_err(|error| format!("cancel worker invocation: {error}"))?;
        if changed == 1 {
            transaction
                .execute(
                    "UPDATE worker_attempts SET status='cancelled',completed_at=?2,error=?3
                     WHERE invocation_id=?1 AND status='running'",
                    params![invocation_id, completed_at, reason],
                )
                .map_err(|error| format!("cancel worker delivery attempt: {error}"))?;
            transaction
                .execute(
                    "UPDATE worker_dispatches
                     SET state='cancelled',completed_at=?2
                     WHERE target_invocation_id=?1 AND state IN ('queued','running')",
                    params![invocation_id, completed_at],
                )
                .map_err(|error| format!("cancel inbound worker dispatch evidence: {error}"))?;
            transaction
                .execute(
                    "INSERT INTO worker_inbox(inbox_id,invocation_id,worker_id,severity,result_json,created_at)
                     VALUES (?1,?2,?3,'info',?4,?5)",
                    params![
                        format!("worker_inbox_{}", uuid::Uuid::now_v7()),
                        invocation_id,
                        current.0,
                        serde_json::to_string(&json!({"status":"cancelled","reason":reason}))
                            .map_err(|error| error.to_string())?,
                        completed_at,
                    ],
                )
                .map_err(|error| format!("record worker cancellation inbox result: {error}"))?;
            insert_audit(
                &transaction,
                &current.0,
                "invocation_cancelled",
                &json!({"invocationId":invocation_id}),
            )?;
            insert_run_event(
                &transaction,
                invocation_id,
                WorkerRunStage::Cancelled,
                "Worker invocation cancelled",
                &completed_at,
            )?;
        }
        transaction
            .commit()
            .map_err(|error| format!("commit worker invocation cancellation: {error}"))?;
        self.invocation(invocation_id)?
            .ok_or_else(|| "cancelled worker invocation disappeared".to_owned())
    }

    pub fn invocation(&self, invocation_id: &str) -> Result<Option<InvocationRecord>, String> {
        let connection = self.connection()?;
        connection
            .query_row(
                invocation_select("WHERE invocation_id=?1").as_str(),
                [invocation_id],
                |row| row_invocation(&connection, row),
            )
            .optional()
            .map_err(|error| format!("load worker invocation: {error}"))
    }

    pub fn queued_invocations(&self, limit: u32) -> Result<Vec<InvocationRecord>, String> {
        let now = chrono::Utc::now().to_rfc3339();
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(&format!(
                "{} JOIN workers w ON w.worker_id=worker_invocations.worker_id
                     WHERE worker_invocations.status='queued' AND w.enabled=1 AND w.retired=0
                       AND (
                         worker_invocations.not_before IS NULL
                         OR worker_invocations.not_before<=?1
                       )
                     ORDER BY worker_invocations.created_at LIMIT ?2",
                invocation_select_base()
            ))
            .map_err(|error| error.to_string())?;
        statement
            .query_map(params![now, limit.min(1_000)], |row| {
                row_invocation(&connection, row)
            })
            .map_err(|error| error.to_string())?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| error.to_string())
    }

    pub(super) fn invocation_by_key(
        &self,
        worker_id: &str,
        key: &str,
    ) -> Result<Option<InvocationRecord>, String> {
        let connection = self.connection()?;
        connection
            .query_row(
                invocation_select("WHERE worker_id=?1 AND idempotency_key=?2").as_str(),
                params![worker_id, key],
                |row| row_invocation(&connection, row),
            )
            .optional()
            .map_err(|error| format!("load idempotent worker invocation: {error}"))
    }

    fn invocation_by_parent_tool_slot(
        &self,
        parent_invocation_id: &str,
        worker_id: &str,
        ordinal: u32,
    ) -> Result<Option<InvocationRecord>, String> {
        let connection = self.connection()?;
        connection
            .query_row(
                invocation_select(
                    "WHERE parent_worker_invocation_id=?1
                       AND worker_id=?2
                       AND parent_worker_tool_ordinal=?3",
                )
                .as_str(),
                params![parent_invocation_id, worker_id, ordinal],
                |row| row_invocation(&connection, row),
            )
            .optional()
            .map_err(|error| format!("load nested worker call slot: {error}"))
    }

    pub(super) fn record_suppressed_delivery(
        &self,
        trace_id: &str,
        worker_id: &str,
        trigger_kind: &str,
        idempotency_key: &str,
        causal_depth: u32,
    ) -> Result<(), String> {
        self.record_trigger_suppression(
            trace_id,
            worker_id,
            trigger_kind,
            idempotency_key,
            causal_depth,
            "duplicate_delivery",
        )
    }

    pub fn record_trigger_suppression(
        &self,
        trace_id: &str,
        worker_id: &str,
        trigger_kind: &str,
        idempotency_key: &str,
        causal_depth: u32,
        reason: &str,
    ) -> Result<(), String> {
        validate_runtime_identifier(trace_id, "trace id", 256)?;
        validate_runtime_identifier(trigger_kind, "trigger kind", 64)?;
        validate_runtime_identifier(idempotency_key, "idempotency key", 256)?;
        validate_runtime_identifier(reason, "suppression reason", 64)?;
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| format!("start worker loop-suppression record: {error}"))?;
        upsert_causal_trace(&transaction, trace_id, None, causal_depth, true)?;
        insert_audit(
            &transaction,
            worker_id,
            "delivery_suppressed",
            &json!({
                "traceId":trace_id,
                "triggerKind":trigger_kind,
                "idempotencyKey":idempotency_key,
                "reason":reason,
                "causalDepth":causal_depth,
            }),
        )?;
        transaction
            .commit()
            .map_err(|error| format!("commit worker loop suppression: {error}"))
    }

    pub fn audit(&self, worker_id: Option<&str>, limit: u32) -> Result<Vec<Value>, String> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(
                "SELECT audit_id,worker_id,action,details_json,created_at
                 FROM worker_audit WHERE (?1 IS NULL OR worker_id=?1)
                 ORDER BY created_at DESC LIMIT ?2",
            )
            .map_err(|error| error.to_string())?;
        statement
            .query_map(params![worker_id, limit.min(500)], |row| {
                let details: String = row.get(3)?;
                Ok(json!({
                    "auditId": row.get::<_, String>(0)?,
                    "workerId": row.get::<_, String>(1)?,
                    "action": row.get::<_, String>(2)?,
                    "details": serde_json::from_str::<Value>(&details).unwrap_or(Value::Null),
                    "createdAt": row.get::<_, String>(4)?,
                }))
            })
            .map_err(|error| error.to_string())?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| error.to_string())
    }
}
