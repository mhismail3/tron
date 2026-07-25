//! Bounded invocation-history, attempt, success, and trace projections.
//!
//! These reads observe the canonical durable ledgers. Causal-tree and
//! structured stage reconstruction lives in `interaction`; inbox delivery
//! policy remains in `invocations`.

use super::*;

impl WorkerStore {
    #[cfg(test)]
    pub fn runs_filtered(
        &self,
        worker_id: Option<&str>,
        status: Option<&str>,
        limit: u32,
    ) -> Result<Vec<InvocationRecord>, String> {
        self.runs_filtered_page(worker_id, status, None, limit, 0)
    }

    #[cfg(test)]
    pub fn runs_filtered_page(
        &self,
        worker_id: Option<&str>,
        status: Option<&str>,
        origin_session_id: Option<&str>,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<InvocationRecord>, String> {
        self.runs_filtered_page_exact(
            worker_id,
            status,
            origin_session_id,
            None,
            None,
            limit,
            offset,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn runs_filtered_page_exact(
        &self,
        worker_id: Option<&str>,
        status: Option<&str>,
        origin_session_id: Option<&str>,
        invocation_id: Option<&str>,
        model_tool_invocation_id: Option<&str>,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<InvocationRecord>, String> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(&format!(
                "{} WHERE (?1 IS NULL OR worker_id=?1)
                    AND (?2 IS NULL OR status=?2)
                    AND (?3 IS NULL OR origin_session_id=?3)
                    AND (?4 IS NULL OR invocation_id=?4)
                    AND (?5 IS NULL OR model_tool_invocation_id=?5)
                    ORDER BY created_at DESC LIMIT ?6 OFFSET ?7",
                invocation_select_base()
            ))
            .map_err(|error| error.to_string())?;
        statement
            .query_map(
                params![
                    worker_id,
                    status,
                    origin_session_id,
                    invocation_id,
                    model_tool_invocation_id,
                    limit.min(500),
                    offset
                ],
                |row| row_invocation_reference(&connection, row),
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
}
