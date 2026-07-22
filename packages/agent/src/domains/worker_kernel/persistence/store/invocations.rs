//! Durable invocation, attempt, trace, inbox, success, and audit ledgers.

use super::*;

const MAX_INBOX_CONTEXT_CANDIDATES: u32 = 200;
const MAX_INBOX_RESULT_PREVIEW_BYTES: usize = 4_096;

fn inbox_context_candidate(row: &rusqlite::Row<'_>) -> rusqlite::Result<Value> {
    let result_json = row.get::<_, String>(4)?;
    Ok(json!({
        "inboxId":row.get::<_, String>(0)?,
        "invocationId":row.get::<_, String>(1)?,
        "workerId":row.get::<_, String>(2)?,
        "severity":row.get::<_, String>(3)?,
        "resultPreview":crate::shared::foundation::text::truncate_with_suffix(
            &result_json,
            MAX_INBOX_RESULT_PREVIEW_BYTES,
            "...",
        ),
        "createdAt":row.get::<_, String>(5)?,
        "triggerKind":row.get::<_, String>(6)?,
        "workerName":row.get::<_, String>(7)?,
        "workerDescription":row.get::<_, String>(8)?,
    }))
}

impl WorkerStore {
    pub fn begin_invocation(
        &self,
        worker_id: &str,
        worker_version: &str,
        input: &Value,
        idempotency_key: &str,
        trace_id: &str,
        causal_depth: u32,
        trigger_kind: &str,
    ) -> Result<(InvocationRecord, bool), String> {
        validate_runtime_identifier(idempotency_key, "idempotency key", 256)?;
        validate_runtime_identifier(trace_id, "trace id", 256)?;
        validate_runtime_identifier(trigger_kind, "trigger kind", 64)?;
        if let Some(existing) = self.invocation_by_key(worker_id, idempotency_key)? {
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
        let insert = transaction.execute(
                "INSERT INTO worker_invocations(invocation_id,worker_id,worker_version,status,input_json,idempotency_key,trace_id,causal_depth,trigger_kind,created_at)
                 VALUES (?1,?2,?3,'queued',?4,?5,?6,?7,?8,?9)",
                params![
                    invocation_id,
                    worker_id,
                    worker_version,
                    serde_json::to_string(input).map_err(|error| error.to_string())?,
                    idempotency_key,
                    trace_id,
                    causal_depth,
                    trigger_kind,
                    created_at,
                ],
            );
        if let Err(error) = insert {
            drop(transaction);
            if let Some(existing) = self.invocation_by_key(worker_id, idempotency_key)? {
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
        }
        transaction
            .commit()
            .map_err(|error| format!("commit worker delivery attempt: {error}"))?;
        Ok(changed == 1)
    }

    pub fn complete_invocation(
        &self,
        invocation_id: &str,
        worker_id: &str,
        result: Result<&Value, &str>,
    ) -> Result<InvocationRecord, String> {
        let (status, output, error, severity, inbox_result) = match result {
            Ok(output) => (
                "completed",
                Some(serde_json::to_string(output).map_err(|error| error.to_string())?),
                None,
                "info",
                json!({"status":"completed","output":output}),
            ),
            Err(error) => (
                "failed",
                None,
                Some(error.to_owned()),
                "error",
                json!({"status":"failed","error":error}),
            ),
        };
        let mut connection = self.connection()?;
        let tx = connection
            .transaction()
            .map_err(|error| error.to_string())?;
        let completed_at = chrono::Utc::now().to_rfc3339();
        let changed = tx
            .execute(
                "UPDATE worker_invocations SET status=?2,output_json=?3,error=?4,completed_at=?5
                 WHERE invocation_id=?1 AND status='running'",
                params![invocation_id, status, output, error, completed_at],
            )
            .map_err(|error| format!("complete worker invocation: {error}"))?;
        if changed != 1 {
            return Err(format!(
                "worker invocation '{invocation_id}' was not in a running state"
            ));
        }
        tx.execute(
            "UPDATE worker_attempts SET status=?2,completed_at=?3,error=?4
             WHERE attempt_id=(SELECT attempt_id FROM worker_attempts
                WHERE invocation_id=?1 AND status='running' ORDER BY attempt_number DESC LIMIT 1)",
            params![invocation_id, status, completed_at, error],
        )
        .map_err(|error| format!("complete worker delivery attempt: {error}"))?;
        tx.execute(
            "INSERT INTO worker_inbox(inbox_id,invocation_id,worker_id,severity,result_json,created_at)
             VALUES (?1,?2,?3,?4,?5,?6)",
            params![
                format!("worker_inbox_{}", uuid::Uuid::now_v7()),
                invocation_id,
                worker_id,
                severity,
                serde_json::to_string(&inbox_result).map_err(|error| error.to_string())?,
                completed_at,
            ],
        )
        .map_err(|error| format!("record worker inbox result: {error}"))?;
        tx.commit().map_err(|error| error.to_string())?;
        self.invocation(invocation_id)?
            .ok_or_else(|| "completed worker invocation disappeared".to_owned())
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
        }
        transaction
            .commit()
            .map_err(|error| format!("commit worker invocation cancellation: {error}"))?;
        self.invocation(invocation_id)?
            .ok_or_else(|| "cancelled worker invocation disappeared".to_owned())
    }

    pub fn invocation(&self, invocation_id: &str) -> Result<Option<InvocationRecord>, String> {
        self.connection()?
            .query_row(
                invocation_select("WHERE invocation_id=?1").as_str(),
                [invocation_id],
                row_invocation,
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
            .query_map([limit.min(1_000)], row_invocation)
            .map_err(|error| error.to_string())?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| error.to_string())
    }

    #[cfg(test)]
    pub fn runs_filtered(
        &self,
        worker_id: Option<&str>,
        status: Option<&str>,
        limit: u32,
    ) -> Result<Vec<InvocationRecord>, String> {
        self.runs_filtered_page(worker_id, status, limit, 0)
    }

    pub fn runs_filtered_page(
        &self,
        worker_id: Option<&str>,
        status: Option<&str>,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<InvocationRecord>, String> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(&format!(
                "{} WHERE (?1 IS NULL OR worker_id=?1)
                    AND (?2 IS NULL OR status=?2)
                    ORDER BY created_at DESC LIMIT ?3 OFFSET ?4",
                invocation_select_base()
            ))
            .map_err(|error| error.to_string())?;
        statement
            .query_map(
                params![worker_id, status, limit.min(500), offset],
                row_invocation,
            )
            .map_err(|error| error.to_string())?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| error.to_string())
    }

    pub fn success_evidence(&self, worker_id: &str) -> Result<Value, String> {
        self.connection()?
            .query_row(
                "SELECT COUNT(*),MAX(completed_at) FROM worker_invocations
                 WHERE worker_id=?1 AND status='completed'",
                [worker_id],
                |row| {
                    Ok(json!({
                        "completedRuns": row.get::<_, u64>(0)?,
                        "lastCompletedAt": row.get::<_, Option<String>>(1)?,
                    }))
                },
            )
            .map_err(|error| format!("load worker success evidence: {error}"))
    }

    pub(super) fn invocation_by_key(
        &self,
        worker_id: &str,
        key: &str,
    ) -> Result<Option<InvocationRecord>, String> {
        self.connection()?
            .query_row(
                invocation_select("WHERE worker_id=?1 AND idempotency_key=?2").as_str(),
                params![worker_id, key],
                row_invocation,
            )
            .optional()
            .map_err(|error| format!("load idempotent worker invocation: {error}"))
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

    pub fn attempts(&self, invocation_id: &str) -> Result<Vec<Value>, String> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(
                "SELECT attempt_id,attempt_number,status,started_at,completed_at,error
                 FROM worker_attempts WHERE invocation_id=?1 ORDER BY attempt_number",
            )
            .map_err(|error| error.to_string())?;
        statement
            .query_map([invocation_id], |row| {
                Ok(json!({
                    "attemptId":row.get::<_, String>(0)?,
                    "attemptNumber":row.get::<_, u32>(1)?,
                    "status":row.get::<_, String>(2)?,
                    "startedAt":row.get::<_, String>(3)?,
                    "completedAt":row.get::<_, Option<String>>(4)?,
                    "error":row.get::<_, Option<String>>(5)?,
                }))
            })
            .map_err(|error| error.to_string())?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| error.to_string())
    }

    pub fn trace(&self, trace_id: &str) -> Result<Option<Value>, String> {
        self.connection()?
            .query_row(
                "SELECT trace_id,root_invocation_id,max_causal_depth,invocation_count,
                        suppressed_count,first_seen_at,last_seen_at
                 FROM worker_causal_traces WHERE trace_id=?1",
                [trace_id],
                |row| {
                    Ok(json!({
                        "traceId":row.get::<_, String>(0)?,
                        "rootInvocationId":row.get::<_, Option<String>>(1)?,
                        "maxCausalDepth":row.get::<_, u32>(2)?,
                        "invocationCount":row.get::<_, u32>(3)?,
                        "suppressedCount":row.get::<_, u32>(4)?,
                        "firstSeenAt":row.get::<_, String>(5)?,
                        "lastSeenAt":row.get::<_, String>(6)?,
                    }))
                },
            )
            .optional()
            .map_err(|error| format!("load worker causal trace: {error}"))
    }

    #[cfg(test)]
    pub fn inbox_filtered(
        &self,
        worker_id: Option<&str>,
        seen: Option<bool>,
        severity: Option<&str>,
        limit: u32,
    ) -> Result<Vec<Value>, String> {
        self.inbox_filtered_page(worker_id, seen, severity, limit, 0)
    }

    pub fn inbox_filtered_page(
        &self,
        worker_id: Option<&str>,
        seen: Option<bool>,
        severity: Option<&str>,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<Value>, String> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(
                "SELECT inbox_id,invocation_id,worker_id,severity,result_json,seen,created_at
                 FROM worker_inbox WHERE (?1 IS NULL OR worker_id=?1)
                    AND (?2 IS NULL OR seen=?2)
                    AND (?3 IS NULL OR severity=?3)
                 ORDER BY created_at DESC LIMIT ?4 OFFSET ?5",
            )
            .map_err(|error| error.to_string())?;
        statement
            .query_map(
                params![
                    worker_id,
                    seen.map(i64::from),
                    severity,
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
                        "seen": row.get::<_, i64>(5)? != 0,
                        "createdAt": row.get::<_, String>(6)?,
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
    pub fn unseen_inbox_context_candidates(&self, limit: u32) -> Result<Vec<Value>, String> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(
                "SELECT i.inbox_id,i.invocation_id,i.worker_id,i.severity,i.result_json,
                        i.created_at,COALESCE(r.trigger_kind,'system'),w.name,w.description
                 FROM worker_inbox i
                 LEFT JOIN worker_invocations r ON r.invocation_id=i.invocation_id
                 JOIN workers w ON w.worker_id=i.worker_id
                 WHERE i.seen=0
                 ORDER BY i.created_at DESC LIMIT ?1",
            )
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

    /// Atomically mark still-unseen policy-selected observations and return
    /// only rows this claimant actually won. Input order is preserved.
    pub fn claim_unseen_inbox_context(&self, inbox_ids: &[String]) -> Result<Vec<Value>, String> {
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| error.to_string())?;
        let mut candidates = Vec::new();
        for inbox_id in inbox_ids {
            let candidate = transaction
                .query_row(
                    "SELECT i.inbox_id,i.invocation_id,i.worker_id,i.severity,i.result_json,
                            i.created_at,COALESCE(r.trigger_kind,'system'),w.name,w.description
                     FROM worker_inbox i
                     LEFT JOIN worker_invocations r ON r.invocation_id=i.invocation_id
                     JOIN workers w ON w.worker_id=i.worker_id
                     WHERE i.inbox_id=?1 AND i.seen=0",
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
                    "UPDATE worker_inbox SET seen=1 WHERE inbox_id=?1 AND seen=0",
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

    /// Claim notable unseen background results for transient prompt attachment.
    /// Errors are always notable; successful manual calls are already visible
    /// to their caller and are intentionally omitted.
    pub fn take_notable_unseen(
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
                .prepare(
                    "SELECT i.inbox_id,i.invocation_id,i.worker_id,i.severity,i.result_json,
                            i.created_at,COALESCE(r.trigger_kind,'system'),w.name,w.description
                     FROM worker_inbox i
                     LEFT JOIN worker_invocations r ON r.invocation_id=i.invocation_id
                     JOIN workers w ON w.worker_id=i.worker_id
                     WHERE i.seen=0
                        AND (i.severity!='info' OR COALESCE(r.trigger_kind,'system')!='manual')
                     ORDER BY i.created_at DESC LIMIT 200",
                )
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
                "seen":false,
                "createdAt":created_at,
            }));
            if selected.len() >= limit.min(32) as usize {
                break;
            }
        }
        for item in &selected {
            transaction
                .execute(
                    "UPDATE worker_inbox SET seen=1 WHERE inbox_id=?1 AND seen=0",
                    [item["inboxId"].as_str().unwrap_or_default()],
                )
                .map_err(|error| format!("mark worker inbox attachment seen: {error}"))?;
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
