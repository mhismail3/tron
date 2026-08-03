//! Durable worker inbox history and operator Attention.

use super::*;

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

// Relevance timeout and historical inbox-context timeout evidence had
// deterministic, caller-owned fallback behavior. Only that exact
// immutable-version timeout is non-actionable; malformed output and every
// other failure stay in Attention. `inbox_context` remains here solely so
// historical rows retain their original Attention semantics.
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

    pub fn record_system_inbox_once(
        &self,
        inbox_id: &str,
        worker_id: &str,
        phase: &str,
        result: &Value,
    ) -> Result<bool, String> {
        validate_runtime_identifier(inbox_id, "system inbox id", 256)?;
        validate_runtime_identifier(worker_id, "system inbox worker id", 256)?;
        validate_runtime_identifier(phase, "system inbox phase", 64)?;
        self.connection()?
            .execute(
                "INSERT OR IGNORE INTO worker_inbox(
                    inbox_id,invocation_id,worker_id,severity,result_json,created_at
                 ) VALUES (?1,?2,?3,'error',?4,?5)",
                params![
                    inbox_id,
                    format!("worker_system_{phase}_{inbox_id}"),
                    worker_id,
                    serde_json::to_string(result).map_err(|error| error.to_string())?,
                    chrono::Utc::now().to_rfc3339(),
                ],
            )
            .map(|changed| changed == 1)
            .map_err(|error| format!("record idempotent worker system inbox result: {error}"))
    }
}
