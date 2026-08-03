//! Durable interaction ownership, causal-subtree lookup, and latency evidence.
//!
//! These queries extend the canonical invocation ledger without introducing a
//! second job or prediction store. Detachment mutates only interaction
//! ownership; causal traversal and exact-version durations remain read-only
//! projections over the invocation rows.

use super::*;

impl WorkerStore {
    /// Append generic lifecycle evidence to the existing durable invocation.
    ///
    /// This ledger is observational. Invocation status and attempts remain the
    /// execution state machine.
    pub fn record_run_stage(
        &self,
        invocation_id: &str,
        stage: WorkerRunStage,
        summary: &str,
    ) -> Result<(), String> {
        validate_runtime_identifier(invocation_id, "invocation id", 256)?;
        let occurred_at = chrono::Utc::now().to_rfc3339();
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| format!("start worker stage evidence: {error}"))?;
        let exists = transaction
            .query_row(
                "SELECT 1 FROM worker_invocations WHERE invocation_id=?1",
                [invocation_id],
                |_| Ok(()),
            )
            .optional()
            .map_err(|error| format!("load worker invocation for stage evidence: {error}"))?
            .is_some();
        if !exists {
            return Err(format!("worker invocation '{invocation_id}' was not found"));
        }
        insert_run_event(&transaction, invocation_id, stage, summary, &occurred_at)?;
        transaction
            .commit()
            .map_err(|error| format!("commit worker stage evidence: {error}"))
    }

    /// Atomically release foreground ownership of the same durable invocation.
    /// Terminal work is returned unchanged; no replacement invocation exists.
    pub fn detach_invocation(&self, invocation_id: &str) -> Result<InvocationRecord, String> {
        validate_runtime_identifier(invocation_id, "invocation id", 256)?;
        let detached_at = chrono::Utc::now().to_rfc3339();
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| format!("start worker detachment: {error}"))?;
        let changed = transaction
            .execute(
                "UPDATE worker_invocations
                 SET interaction_mode='background',detached_at=COALESCE(detached_at,?2)
                 WHERE invocation_id=?1 AND status IN ('queued','running')
                   AND interaction_mode!='background'",
                params![invocation_id, detached_at],
            )
            .map_err(|error| format!("detach worker invocation: {error}"))?;
        if changed == 1 {
            insert_run_event(
                &transaction,
                invocation_id,
                WorkerRunStage::Detached,
                "Conversation released while durable work continues",
                &detached_at,
            )?;
        }
        transaction
            .commit()
            .map_err(|error| format!("commit worker detachment: {error}"))?;
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

    /// Resolve the canonical causal root for any invocation in the tree.
    pub fn invocation_tree_root(&self, invocation_id: &str) -> Result<String, String> {
        validate_runtime_identifier(invocation_id, "invocation id", 256)?;
        let connection = self.connection()?;
        connection
            .query_row(
                "WITH RECURSIVE ancestors(invocation_id,parent_id,depth) AS (
                    SELECT invocation_id,parent_worker_invocation_id,0
                    FROM worker_invocations WHERE invocation_id=?1
                    UNION ALL
                    SELECT parent.invocation_id,parent.parent_worker_invocation_id,
                           ancestors.depth+1
                    FROM worker_invocations parent
                    JOIN ancestors ON parent.invocation_id=ancestors.parent_id
                 )
                 SELECT invocation_id FROM ancestors
                 ORDER BY depth DESC LIMIT 1",
                [invocation_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(|error| format!("resolve worker invocation root: {error}"))?
            .ok_or_else(|| format!("worker invocation '{invocation_id}' was not found"))
    }

    /// Return one causal tree in deterministic parent-before-child order.
    pub fn invocation_tree(
        &self,
        root_invocation_id: &str,
        limit: u32,
    ) -> Result<Vec<InvocationRecord>, String> {
        validate_runtime_identifier(root_invocation_id, "invocation id", 256)?;
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(&format!(
                "{} JOIN (
                    WITH RECURSIVE tree(invocation_id,depth) AS (
                        SELECT invocation_id,0 FROM worker_invocations
                        WHERE invocation_id=?1
                        UNION ALL
                        SELECT child.invocation_id,tree.depth+1
                        FROM worker_invocations child
                        JOIN tree
                          ON child.parent_worker_invocation_id=tree.invocation_id
                    )
                    SELECT invocation_id,depth FROM tree
                 ) projected
                   ON projected.invocation_id=worker_invocations.invocation_id
                 ORDER BY projected.depth ASC,worker_invocations.created_at ASC,
                          worker_invocations.invocation_id ASC
                 LIMIT ?2",
                invocation_select_base()
            ))
            .map_err(|error| format!("prepare worker invocation tree: {error}"))?;
        statement
            .query_map(params![root_invocation_id, limit.min(1_000)], |row| {
                row_invocation_reference(&connection, row)
            })
            .map_err(|error| format!("query worker invocation tree: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode worker invocation tree: {error}"))
    }

    /// Load server-ordered generic stage evidence for a bounded run tree.
    pub fn run_events(&self, invocation_ids: &[String]) -> Result<Vec<WorkerRunEvent>, String> {
        if invocation_ids.is_empty() {
            return Ok(Vec::new());
        }
        if invocation_ids.len() > 256 {
            return Err("worker run graph exceeds 256 invocation nodes".to_owned());
        }
        let connection = self.connection()?;
        let mut events = Vec::new();
        for invocation_id in invocation_ids {
            validate_runtime_identifier(invocation_id, "invocation id", 256)?;
            let mut statement = connection
                .prepare(
                    "SELECT event_id,invocation_id,sequence,stage,summary,occurred_at
                     FROM worker_run_events WHERE invocation_id=?1
                     ORDER BY sequence",
                )
                .map_err(|error| format!("prepare worker run events: {error}"))?;
            let rows = statement
                .query_map([invocation_id], |row| {
                    let stage = match row.get::<_, String>(3)?.as_str() {
                        "queued" => WorkerRunStage::Queued,
                        "planning" => WorkerRunStage::Planning,
                        "specialist_execution" => WorkerRunStage::SpecialistExecution,
                        "retry_repair" => WorkerRunStage::RetryRepair,
                        "synthesis" => WorkerRunStage::Synthesis,
                        "validation" => WorkerRunStage::Validation,
                        "publication" => WorkerRunStage::Publication,
                        "detached" => WorkerRunStage::Detached,
                        "completed" => WorkerRunStage::Completed,
                        "failed" => WorkerRunStage::Failed,
                        "cancelled" => WorkerRunStage::Cancelled,
                        _ => WorkerRunStage::Interrupted,
                    };
                    Ok(WorkerRunEvent {
                        event_id: row.get(0)?,
                        invocation_id: row.get(1)?,
                        sequence: row.get(2)?,
                        stage,
                        summary: row.get(4)?,
                        occurred_at: row.get(5)?,
                    })
                })
                .map_err(|error| format!("query worker run events: {error}"))?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(|error| format!("decode worker run events: {error}"))?;
            events.extend(rows);
        }
        events.sort_by(|left, right| {
            left.occurred_at
                .cmp(&right.occurred_at)
                .then_with(|| left.invocation_id.cmp(&right.invocation_id))
                .then_with(|| left.sequence.cmp(&right.sequence))
        });
        Ok(events)
    }

    /// Page canonical causal roots. A worker filter admits roots containing a
    /// matching descendant so Session Context cannot be crowded out by many
    /// children from one trace.
    pub fn run_roots_filtered_page(
        &self,
        worker_id: Option<&str>,
        status: Option<&str>,
        origin_session_id: Option<&str>,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<InvocationRecord>, String> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(&format!(
                "{} WHERE parent_worker_invocation_id IS NULL
                    AND (?1 IS NULL OR status=?1)
                    AND (?2 IS NULL OR origin_session_id=?2)
                    AND (
                        ?3 IS NULL
                        OR worker_id=?3
                        OR EXISTS (
                            WITH RECURSIVE descendants(invocation_id) AS (
                                SELECT child.invocation_id
                                FROM worker_invocations child
                                WHERE child.parent_worker_invocation_id=
                                      worker_invocations.invocation_id
                                UNION ALL
                                SELECT nested.invocation_id
                                FROM worker_invocations nested
                                JOIN descendants
                                  ON nested.parent_worker_invocation_id=
                                     descendants.invocation_id
                            )
                            SELECT 1
                            FROM descendants
                            JOIN worker_invocations matched
                              ON matched.invocation_id=descendants.invocation_id
                            WHERE matched.worker_id=?3
                            LIMIT 1
                        )
                    )
                    ORDER BY created_at DESC LIMIT ?4 OFFSET ?5",
                invocation_select_base()
            ))
            .map_err(|error| format!("prepare worker causal roots: {error}"))?;
        statement
            .query_map(
                params![status, origin_session_id, worker_id, limit.min(500), offset],
                |row| row_invocation_reference(&connection, row),
            )
            .map_err(|error| format!("query worker causal roots: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode worker causal roots: {error}"))
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
