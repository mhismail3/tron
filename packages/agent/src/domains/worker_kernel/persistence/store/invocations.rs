//! Durable invocation, attempt, trace, inbox, success, and audit ledgers.

use super::*;

const MAX_INBOX_CONTEXT_CANDIDATES: u32 = 200;

// INVARIANT: attention is a live projection over immutable evidence. A
// successful activation or rollback is verified recovery; merely toggling an
// existing failed worker back on is not. Resolved errors remain in the inbox
// audit and invocation ledger but cannot stay in operator Attention or be
// injected into a later agent context.
const UNRESOLVED_INBOX_ERROR_SQL: &str = "
    i.severity='error'
    AND NOT EXISTS (
        SELECT 1
        FROM worker_health recovery
        WHERE recovery.worker_id=i.worker_id
          AND recovery.status='healthy'
          AND recovery.source IN ('activation','rollback')
          AND recovery.recorded_at>i.created_at
    )
";

// INVARIANT: a successful engine hook is synchronously consumed by the engine
// boundary that invoked it. Its inbox row remains immutable audit evidence, but
// it is born attached so the same policy output cannot later surface as
// unrelated background context. Hook failures remain pending Attention.
pub(super) const COMPLETED_ENGINE_HOOK_CONTEXT_ATTACHED_SQL: &str = "
    CASE
        WHEN ?4='info'
         AND COALESCE(
            (SELECT trigger_kind FROM worker_invocations WHERE invocation_id=?2),
            ''
         ) LIKE 'engine_hook:%'
        THEN 1
        ELSE 0
    END
";

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
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(&format!(
                "{} JOIN workers w ON w.worker_id=worker_invocations.worker_id
                     WHERE worker_invocations.status='queued' AND w.enabled=1 AND w.retired=0
                     ORDER BY worker_invocations.created_at LIMIT ?1",
                invocation_select_base()
            ))
            .map_err(|error| error.to_string())?;
        statement
            .query_map([limit.min(1_000)], |row| row_invocation(&connection, row))
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

    #[cfg(test)]
    pub fn inbox_filtered(
        &self,
        worker_id: Option<&str>,
        context_attached: Option<bool>,
        severity: Option<&str>,
        limit: u32,
    ) -> Result<Vec<Value>, String> {
        self.inbox_filtered_page(worker_id, context_attached, severity, false, limit, 0)
    }

    pub fn inbox_filtered_page(
        &self,
        worker_id: Option<&str>,
        context_attached: Option<bool>,
        severity: Option<&str>,
        attention_only: bool,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<Value>, String> {
        let connection = self.connection()?;
        let attention_sql = format!(
            "({UNRESOLVED_INBOX_ERROR_SQL})
             OR (i.severity!='error'
                 AND i.context_attached=0
                 AND (
                    COALESCE(r.trigger_kind,'system')!='manual'
                    OR COALESCE(r.interaction_mode,'foreground')='background'
                 ))"
        );
        let mut statement = connection
            .prepare(&format!(
                "SELECT i.inbox_id,i.invocation_id,i.worker_id,i.severity,i.result_json,
                        i.context_attached,i.created_at,COALESCE(r.trigger_kind,'system'),
                        CASE WHEN r.invocation_id IS NULL THEN 0 ELSE 1 END,
                        CASE WHEN {attention_sql} THEN 1 ELSE 0 END
                 FROM worker_inbox i
                 LEFT JOIN worker_invocations r ON r.invocation_id=i.invocation_id
                 WHERE (?1 IS NULL OR i.worker_id=?1)
                    AND (?2 IS NULL OR i.context_attached=?2)
                    AND (?3 IS NULL OR i.severity=?3)
                    AND (?4=0 OR {attention_sql})
                 ORDER BY i.created_at DESC LIMIT ?5 OFFSET ?6"
            ))
            .map_err(|error| error.to_string())?;
        statement
            .query_map(
                params![
                    worker_id,
                    context_attached.map(i64::from),
                    severity,
                    i64::from(attention_only),
                    limit.min(500),
                    offset
                ],
                |row| {
                    let result: String = row.get(4)?;
                    Ok(json!({
                        "inboxId": row.get::<_, String>(0)?,
                        "invocationId": row.get::<_, String>(1)?,
                        "workerId": row.get::<_, String>(2)?,
                        "severity": row.get::<_, String>(3)?,
                        "result": serde_json::from_str::<Value>(&result).unwrap_or(Value::Null),
                        "contextAttached": row.get::<_, i64>(5)? != 0,
                        "createdAt": row.get::<_, String>(6)?,
                        "triggerKind": row.get::<_, String>(7)?,
                        "hasInvocation": row.get::<_, i64>(8)? != 0,
                        "requiresAttention": row.get::<_, i64>(9)? != 0,
                    }))
                },
            )
            .map_err(|error| error.to_string())?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| error.to_string())
    }

    pub fn record_system_inbox(
        &self,
        worker_id: &str,
        phase: &str,
        result: &Value,
    ) -> Result<(), String> {
        validate_runtime_identifier(phase, "system inbox phase", 64)?;
        self.connection()?
            .execute(
                "INSERT INTO worker_inbox(inbox_id,invocation_id,worker_id,severity,result_json,created_at)
                 VALUES (?1,?2,?3,'error',?4,?5)",
                params![
                    format!("worker_inbox_{}", uuid::Uuid::now_v7()),
                    format!("worker_system_{phase}_{}", uuid::Uuid::now_v7()),
                    worker_id,
                    serde_json::to_string(result).map_err(|error| error.to_string())?,
                    chrono::Utc::now().to_rfc3339(),
                ],
            )
            .map_err(|error| format!("record worker system inbox result: {error}"))?;
        Ok(())
    }

    /// Return a bounded newest-first projection for worker-owned transient
    /// context policy. Reading candidates never changes delivery state.
    pub fn pending_inbox_context_candidates(&self, limit: u32) -> Result<Vec<Value>, String> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(&format!(
                "SELECT i.inbox_id,i.invocation_id,i.worker_id,i.severity,i.result_json,
                        i.created_at,COALESCE(r.trigger_kind,'system'),w.name,w.description
                 FROM worker_inbox i
                 LEFT JOIN worker_invocations r ON r.invocation_id=i.invocation_id
                 JOIN workers w ON w.worker_id=i.worker_id
                 WHERE i.context_attached=0
                   AND (i.severity!='error' OR ({UNRESOLVED_INBOX_ERROR_SQL}))
                 ORDER BY i.created_at DESC LIMIT ?1"
            ))
            .map_err(|error| error.to_string())?;
        statement
            .query_map(
                [limit.min(MAX_INBOX_CONTEXT_CANDIDATES)],
                inbox_context_candidate,
            )
            .map_err(|error| error.to_string())?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| error.to_string())
    }

    /// Atomically attach still-pending policy-selected observations and return
    /// only rows this claimant actually won. Input order is preserved.
    pub fn attach_pending_inbox_context(&self, inbox_ids: &[String]) -> Result<Vec<Value>, String> {
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| error.to_string())?;
        let mut candidates = Vec::new();
        for inbox_id in inbox_ids {
            let candidate = transaction
                .query_row(
                    &format!(
                        "SELECT i.inbox_id,i.invocation_id,i.worker_id,i.severity,i.result_json,
                            i.created_at,COALESCE(r.trigger_kind,'system'),w.name,w.description
                     FROM worker_inbox i
                     LEFT JOIN worker_invocations r ON r.invocation_id=i.invocation_id
                     JOIN workers w ON w.worker_id=i.worker_id
                     WHERE i.inbox_id=?1
                       AND i.context_attached=0
                       AND (i.severity!='error' OR ({UNRESOLVED_INBOX_ERROR_SQL}))"
                    ),
                    [inbox_id],
                    inbox_context_candidate,
                )
                .optional()
                .map_err(|error| error.to_string())?;
            let Some(candidate) = candidate else {
                return Ok(Vec::new());
            };
            candidates.push(candidate);
        }
        for inbox_id in inbox_ids {
            let updated = transaction
                .execute(
                    "UPDATE worker_inbox SET context_attached=1
                     WHERE inbox_id=?1 AND context_attached=0",
                    [inbox_id],
                )
                .map_err(|error| format!("claim worker inbox context: {error}"))?;
            if updated != 1 {
                return Ok(Vec::new());
            }
        }
        transaction.commit().map_err(|error| error.to_string())?;
        Ok(candidates)
    }

    /// Claim notable pending background results for transient prompt attachment.
    /// Unresolved errors are always notable; verified recovery removes them
    /// from transient context without deleting their audit evidence. Successful
    /// foreground manual calls are already visible to their caller and are
    /// intentionally omitted. Detached or predicted-background manual results
    /// remain notable because no foreground caller received the typed output.
    pub fn take_notable_pending(
        &self,
        relevance_query: Option<&str>,
        limit: u32,
    ) -> Result<Vec<Value>, String> {
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| error.to_string())?;
        let query_terms = relevance_query.map(terms).unwrap_or_default();
        let candidates = {
            let mut statement = transaction
                .prepare(&format!(
                    "SELECT i.inbox_id,i.invocation_id,i.worker_id,i.severity,i.result_json,
                            i.created_at,COALESCE(r.trigger_kind,'system'),w.name,w.description
                     FROM worker_inbox i
                     LEFT JOIN worker_invocations r ON r.invocation_id=i.invocation_id
                     JOIN workers w ON w.worker_id=i.worker_id
                     WHERE i.context_attached=0
                        AND (
                            i.severity!='info'
                            OR COALESCE(r.trigger_kind,'system')!='manual'
                            OR COALESCE(r.interaction_mode,'foreground')='background'
                        )
                        AND (i.severity!='error' OR ({UNRESOLVED_INBOX_ERROR_SQL}))
                     ORDER BY i.created_at DESC LIMIT 200"
                ))
                .map_err(|error| error.to_string())?;
            statement
                .query_map([], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, String>(3)?,
                        row.get::<_, String>(4)?,
                        row.get::<_, String>(5)?,
                        row.get::<_, String>(6)?,
                        row.get::<_, String>(7)?,
                        row.get::<_, String>(8)?,
                    ))
                })
                .map_err(|error| error.to_string())?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(|error| error.to_string())?
        };
        let mut selected = Vec::new();
        for (
            inbox_id,
            invocation_id,
            worker_id,
            severity,
            result,
            created_at,
            trigger,
            name,
            description,
        ) in candidates
        {
            let worker_terms = terms(&format!("{name} {description}"));
            let relevant = severity == "error"
                || query_terms.is_empty()
                || !query_terms.is_disjoint(&worker_terms);
            if !relevant {
                continue;
            }
            selected.push(json!({
                "inboxId":inbox_id,
                "invocationId":invocation_id,
                "workerId":worker_id,
                "workerName":name,
                "severity":severity,
                "triggerKind":trigger,
                "result":serde_json::from_str::<Value>(&result).unwrap_or(Value::Null),
                "contextAttached":false,
                "createdAt":created_at,
            }));
            if selected.len() >= limit.min(32) as usize {
                break;
            }
        }
        for item in &selected {
            transaction
                .execute(
                    "UPDATE worker_inbox SET context_attached=1
                     WHERE inbox_id=?1 AND context_attached=0",
                    [item["inboxId"].as_str().unwrap_or_default()],
                )
                .map_err(|error| format!("mark worker inbox context attached: {error}"))?;
        }
        transaction.commit().map_err(|error| error.to_string())?;
        Ok(selected)
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
