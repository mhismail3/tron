//! Durable interaction ownership, causal-subtree lookup, and latency evidence.
//!
//! These queries extend the canonical invocation ledger without introducing a
//! second job or prediction store. Detachment mutates only interaction
//! ownership; causal traversal and exact-version durations remain read-only
//! projections over the invocation rows.

use super::*;

impl WorkerStore {
    /// Atomically release foreground ownership of the same durable invocation.
    /// Terminal work is returned unchanged; no replacement invocation exists.
    pub fn detach_invocation(&self, invocation_id: &str) -> Result<InvocationRecord, String> {
        validate_runtime_identifier(invocation_id, "invocation id", 256)?;
        let detached_at = chrono::Utc::now().to_rfc3339();
        self.connection()?
            .execute(
                "UPDATE worker_invocations
                 SET interaction_mode='background',detached_at=COALESCE(detached_at,?2)
                 WHERE invocation_id=?1 AND status IN ('queued','running')",
                params![invocation_id, detached_at],
            )
            .map_err(|error| format!("detach worker invocation: {error}"))?;
        self.invocation(invocation_id)?
            .ok_or_else(|| format!("worker invocation '{invocation_id}' was not found"))
    }

    /// Return descendants deepest-first so cancellation closes children before
    /// their selected causal root.
    pub fn invocation_subtree_ids(&self, invocation_id: &str) -> Result<Vec<String>, String> {
        validate_runtime_identifier(invocation_id, "invocation id", 256)?;
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(
                "WITH RECURSIVE subtree(invocation_id,depth) AS (
                    SELECT invocation_id,0 FROM worker_invocations
                    WHERE invocation_id=?1
                    UNION ALL
                    SELECT child.invocation_id,subtree.depth+1
                    FROM worker_invocations child
                    JOIN subtree
                      ON child.parent_worker_invocation_id=subtree.invocation_id
                 )
                 SELECT invocation_id FROM subtree ORDER BY depth DESC,invocation_id",
            )
            .map_err(|error| format!("prepare worker invocation subtree: {error}"))?;
        statement
            .query_map([invocation_id], |row| row.get::<_, String>(0))
            .map_err(|error| format!("query worker invocation subtree: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode worker invocation subtree: {error}"))
    }

    /// Recent completed wall durations for the exact immutable version.
    pub fn completed_wall_durations(
        &self,
        worker_id: &str,
        worker_version: &str,
        limit: u32,
    ) -> Result<Vec<Duration>, String> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(
                "SELECT created_at,completed_at FROM worker_invocations
                 WHERE worker_id=?1 AND worker_version=?2 AND status='completed'
                   AND completed_at IS NOT NULL
                 ORDER BY completed_at DESC LIMIT ?3",
            )
            .map_err(|error| format!("prepare worker latency history: {error}"))?;
        let timestamps = statement
            .query_map(params![worker_id, worker_version, limit.min(100)], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })
            .map_err(|error| format!("query worker latency history: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode worker latency history: {error}"))?;
        timestamps
            .into_iter()
            .map(|(created, completed)| {
                let created = chrono::DateTime::parse_from_rfc3339(&created)
                    .map_err(|error| format!("decode worker created time: {error}"))?;
                let completed = chrono::DateTime::parse_from_rfc3339(&completed)
                    .map_err(|error| format!("decode worker completed time: {error}"))?;
                completed
                    .signed_duration_since(created)
                    .to_std()
                    .map_err(|error| format!("decode worker wall duration: {error}"))
            })
            .collect()
    }
}
