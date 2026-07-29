//! Durable worker inbox history, Attention, and transient-context claims.

use super::*;

const MAX_INBOX_CONTEXT_CANDIDATES: u32 = 200;

// Successful foreground manual calls already return their typed result to the
// caller. They remain immutable inbox history but are not eligible for a second
// delivery through automatic model context. Background manual work, non-manual
// results, and every actionable error remain eligible.
const INBOX_CONTEXT_ELIGIBLE_SQL: &str = "
    (
        i.severity!='info'
        OR COALESCE(r.trigger_kind,'system')!='manual'
        OR COALESCE(r.interaction_mode,'foreground')='background'
    )
";

// INVARIANT: Attention is a live projection of unresolved error evidence, not
// a second delivery state for successful background work. A successful
// activation or rollback is verified recovery; merely toggling an existing
// failed worker back on is not. Successful informational outcomes and resolved
// errors remain in the inbox audit and invocation ledger but cannot stay in
// operator Attention. Agent-context eligibility is a separate projection.
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
    AND (
        COALESCE(json_extract(i.result_json,'$.status'),'')!='artifact_storage_pressure'
        OR EXISTS (
            SELECT 1 FROM worker_artifact_storage_state artifact_pressure
            WHERE artifact_pressure.singleton=1
              AND artifact_pressure.state='attention'
              AND artifact_pressure.attention_inbox_id=i.inbox_id
        )
    )
";

// Optional relevance and inbox policies have deterministic, caller-owned
// fallback behavior. Only the exact immutable-version invocation timeout is
// non-actionable; malformed output and every other failure stay in Attention.
// This is transport/state evidence, not semantic ranking policy.
const OPTIONAL_FALLBACK_HOOK_TIMEOUT_SQL: &str = "
    r.status='failed'
    AND r.trigger_kind IN (
        'engine_hook:worker_relevance',
        'engine_hook:inbox_context'
    )
    AND COALESCE(json_extract(i.result_json,'$.error'),'')=COALESCE(r.error,'')
    AND EXISTS (
        SELECT 1
        FROM worker_versions timeout_version
        WHERE timeout_version.worker_id=r.worker_id
          AND timeout_version.version=r.worker_version
          AND json_type(
                timeout_version.manifest_json,
                '$.executionLimits.maxInvocationSeconds'
              )='integer'
          AND r.error=(
                'worker invocation exceeded '
                || CAST(json_extract(
                    timeout_version.manifest_json,
                    '$.executionLimits.maxInvocationSeconds'
                ) AS TEXT)
                || ' seconds'
              )
    )
";

fn actionable_inbox_error_sql() -> String {
    format!(
        "({UNRESOLVED_INBOX_ERROR_SQL})
         AND NOT ({OPTIONAL_FALLBACK_HOOK_TIMEOUT_SQL})"
    )
}

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
        let attention_sql = actionable_inbox_error_sql();
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
        let actionable_error_sql = actionable_inbox_error_sql();
        let eligible_context_sql = INBOX_CONTEXT_ELIGIBLE_SQL;
        let mut statement = connection
            .prepare(&format!(
                "SELECT i.inbox_id,i.invocation_id,i.worker_id,i.severity,i.result_json,
                        i.created_at,COALESCE(r.trigger_kind,'system'),w.name,w.description
                 FROM worker_inbox i
                 LEFT JOIN worker_invocations r ON r.invocation_id=i.invocation_id
                 JOIN workers w ON w.worker_id=i.worker_id
                 WHERE i.context_attached=0
                   AND ({eligible_context_sql})
                   AND (i.severity!='error' OR ({actionable_error_sql}))
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
        let actionable_error_sql = actionable_inbox_error_sql();
        let eligible_context_sql = INBOX_CONTEXT_ELIGIBLE_SQL;
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
                       AND ({eligible_context_sql})
                       AND (i.severity!='error' OR ({actionable_error_sql}))"
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
        let actionable_error_sql = actionable_inbox_error_sql();
        let eligible_context_sql = INBOX_CONTEXT_ELIGIBLE_SQL;
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
                        AND ({eligible_context_sql})
                        AND (i.severity!='error' OR ({actionable_error_sql}))
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
}
