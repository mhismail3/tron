//! Reusable-agent coordination schema installation.
//!
//! Schema versions stay isolated from operational reads and mutations.

use super::super::table_has_column;

pub(crate) fn install_schema_v19(connection: &rusqlite::Connection) -> Result<(), String> {
    connection
        .execute_batch(
            "CREATE TABLE IF NOT EXISTS agent_instances (
                agent_id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL UNIQUE,
                root_session_id TEXT NOT NULL,
                workspace_id TEXT NOT NULL,
                spawned_by_agent_id TEXT REFERENCES agent_instances(agent_id),
                management_owner_agent_id TEXT REFERENCES agent_instances(agent_id),
                kind TEXT NOT NULL CHECK(kind IN ('root','general','role','direct_worker')),
                role_id TEXT,
                role_version TEXT,
                name TEXT NOT NULL,
                visibility TEXT NOT NULL CHECK(visibility IN ('nested','visible')),
                state TEXT NOT NULL CHECK(state IN (
                    'provisioning','idle','active','waiting','closing','closed'
                )),
                default_model TEXT,
                default_reasoning_level TEXT,
                tool_grant_json TEXT NOT NULL,
                write_scopes_json TEXT NOT NULL,
                limits_json TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                closed_at TEXT,
                CHECK (
                    (kind='role' AND role_id IS NOT NULL AND role_version IS NOT NULL)
                    OR (kind!='role' AND role_id IS NULL AND role_version IS NULL)
                ),
                CHECK ((state='closed')=(closed_at IS NOT NULL))
             );
             CREATE INDEX IF NOT EXISTS agent_instances_directory
                ON agent_instances(state,visibility,updated_at DESC,agent_id);
             CREATE INDEX IF NOT EXISTS agent_instances_root
                ON agent_instances(root_session_id,state,created_at,agent_id);
             CREATE INDEX IF NOT EXISTS agent_instances_owner
                ON agent_instances(management_owner_agent_id,state,created_at,agent_id);

             CREATE TABLE IF NOT EXISTS execution_nodes (
                execution_id TEXT PRIMARY KEY,
                kind TEXT NOT NULL CHECK(kind IN ('worker','agent_assignment')),
                parent_execution_id TEXT REFERENCES execution_nodes(execution_id),
                owner_agent_id TEXT REFERENCES agent_instances(agent_id),
                root_session_id TEXT,
                trace_id TEXT NOT NULL,
                causal_depth INTEGER NOT NULL CHECK(causal_depth BETWEEN 0 AND 4294967295),
                child_slot INTEGER CHECK(child_slot IS NULL OR child_slot>=0),
                worker_invocation_id TEXT UNIQUE
                    REFERENCES worker_invocations(invocation_id) ON DELETE CASCADE,
                assignment_id TEXT UNIQUE,
                created_at TEXT NOT NULL,
                CHECK (
                    (kind='worker' AND worker_invocation_id IS NOT NULL AND assignment_id IS NULL)
                    OR
                    (kind='agent_assignment' AND worker_invocation_id IS NULL AND assignment_id IS NOT NULL)
                )
             );
             CREATE INDEX IF NOT EXISTS execution_nodes_parent
                ON execution_nodes(parent_execution_id,created_at,execution_id);
             CREATE INDEX IF NOT EXISTS execution_nodes_trace
                ON execution_nodes(trace_id,causal_depth,created_at,execution_id);
             DROP INDEX IF EXISTS execution_nodes_child_slot;
             CREATE INDEX IF NOT EXISTS execution_nodes_child_order
                ON execution_nodes(parent_execution_id,kind,child_slot,created_at,execution_id)
                WHERE parent_execution_id IS NOT NULL;

             CREATE TABLE IF NOT EXISTS coordination_trace_states (
                trace_id TEXT PRIMARY KEY,
                root_session_id TEXT NOT NULL,
                state TEXT NOT NULL CHECK(state IN ('active','paused')),
                reason TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                paused_at TEXT NOT NULL,
                resumed_at TEXT,
                CHECK ((state='paused')=(resumed_at IS NULL))
             );
             CREATE INDEX IF NOT EXISTS coordination_trace_states_paused
                ON coordination_trace_states(state,updated_at,trace_id);

             CREATE TABLE IF NOT EXISTS agent_assignments (
                assignment_id TEXT PRIMARY KEY,
                execution_id TEXT NOT NULL UNIQUE
                    REFERENCES execution_nodes(execution_id) ON DELETE CASCADE,
                agent_id TEXT NOT NULL REFERENCES agent_instances(agent_id),
                requester_agent_id TEXT REFERENCES agent_instances(agent_id),
                delegator_agent_id TEXT REFERENCES agent_instances(agent_id),
                kind TEXT NOT NULL CHECK(kind IN ('instruction','request','operator','direct_worker')),
                status TEXT NOT NULL CHECK(status IN (
                    'offered','accepted','queued','running','waiting','completed','declined',
                    'failed','cancelled','timed_out','expired'
                )),
                admission_key TEXT NOT NULL UNIQUE,
                queue_ordinal INTEGER NOT NULL CHECK(queue_ordinal>=0),
                task TEXT NOT NULL,
                context_json TEXT NOT NULL,
                model TEXT,
                reasoning_level TEXT,
                authority_snapshot_json TEXT NOT NULL,
                resource_snapshot_json TEXT NOT NULL,
                write_scopes_snapshot_json TEXT NOT NULL,
                limits_snapshot_json TEXT NOT NULL,
                retry_of_assignment_id TEXT REFERENCES agent_assignments(assignment_id),
                result_id TEXT UNIQUE,
                result_json TEXT,
                result_reference_json TEXT,
                error TEXT,
                deadline_at TEXT,
                created_at TEXT NOT NULL,
                accepted_at TEXT,
                started_at TEXT,
                completed_at TEXT,
                updated_at TEXT NOT NULL,
                CHECK(length(CAST(task AS BLOB)) BETWEEN 1 AND 40000),
                CHECK ((status IN ('completed','declined','failed','cancelled','timed_out','expired'))
                       =(completed_at IS NOT NULL)),
                CHECK ((result_id IS NULL)=(result_json IS NULL)),
                CHECK ((result_json IS NULL)=(result_reference_json IS NULL)),
                CHECK (status='completed' OR result_id IS NULL)
             );
             CREATE INDEX IF NOT EXISTS agent_assignments_agent_queue
                ON agent_assignments(agent_id,status,queue_ordinal,created_at,assignment_id);
             CREATE INDEX IF NOT EXISTS agent_assignments_requester
                ON agent_assignments(requester_agent_id,created_at DESC,assignment_id);
             CREATE INDEX IF NOT EXISTS agent_assignments_retry
                ON agent_assignments(retry_of_assignment_id,created_at,assignment_id);
             CREATE UNIQUE INDEX IF NOT EXISTS agent_assignments_one_active
                ON agent_assignments(agent_id)
                WHERE status IN ('running','waiting');

             CREATE TABLE IF NOT EXISTS direct_worker_agent_runs (
                worker_invocation_id TEXT PRIMARY KEY
                    REFERENCES worker_invocations(invocation_id) ON DELETE CASCADE,
                agent_id TEXT NOT NULL UNIQUE
                    REFERENCES agent_instances(agent_id) ON DELETE CASCADE,
                assignment_id TEXT NOT NULL UNIQUE
                    REFERENCES agent_assignments(assignment_id) ON DELETE CASCADE,
                created_at TEXT NOT NULL
             );

             CREATE TABLE IF NOT EXISTS agent_assignment_attempts (
                attempt_id TEXT PRIMARY KEY,
                assignment_id TEXT NOT NULL
                    REFERENCES agent_assignments(assignment_id) ON DELETE CASCADE,
                attempt_number INTEGER NOT NULL CHECK(attempt_number>0),
                status TEXT NOT NULL CHECK(status IN (
                    'running','waiting','completed','failed','interrupted'
                )),
                run_id TEXT,
                baseline_event_sequence INTEGER NOT NULL DEFAULT 0
                    CHECK(baseline_event_sequence>=0),
                started_at TEXT NOT NULL,
                completed_at TEXT,
                error TEXT,
                UNIQUE(assignment_id,attempt_number),
                CHECK ((status='running')=(completed_at IS NULL))
             );
             CREATE INDEX IF NOT EXISTS agent_assignment_attempts_assignment
                ON agent_assignment_attempts(assignment_id,attempt_number);

             CREATE TABLE IF NOT EXISTS agent_execution_events (
                event_id TEXT PRIMARY KEY,
                execution_id TEXT NOT NULL
                    REFERENCES execution_nodes(execution_id) ON DELETE CASCADE,
                sequence INTEGER NOT NULL CHECK(sequence>=0),
                kind TEXT NOT NULL,
                details_json TEXT NOT NULL,
                occurred_at TEXT NOT NULL,
                UNIQUE(execution_id,sequence)
             );
             CREATE INDEX IF NOT EXISTS agent_execution_events_execution
                ON agent_execution_events(execution_id,sequence);

             CREATE TABLE IF NOT EXISTS agent_outbox (
                outbox_id TEXT PRIMARY KEY,
                deduplication_key TEXT NOT NULL UNIQUE,
                kind TEXT NOT NULL CHECK(kind IN ('provision','message','result','projection')),
                agent_id TEXT REFERENCES agent_instances(agent_id) ON DELETE CASCADE,
                assignment_id TEXT REFERENCES agent_assignments(assignment_id) ON DELETE CASCADE,
                execution_id TEXT REFERENCES execution_nodes(execution_id) ON DELETE CASCADE,
                payload_json TEXT NOT NULL,
                disposition TEXT NOT NULL DEFAULT 'pending'
                    CHECK(disposition IN ('pending','importing','imported','rejected')),
                attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts>=0),
                last_error TEXT,
                created_at TEXT NOT NULL,
                processed_at TEXT
             );
             CREATE INDEX IF NOT EXISTS agent_outbox_pending
                ON agent_outbox(disposition,created_at,outbox_id);

             CREATE TABLE IF NOT EXISTS agent_management_grants (
                grant_id TEXT PRIMARY KEY,
                idempotency_key TEXT NOT NULL UNIQUE,
                target_agent_id TEXT NOT NULL REFERENCES agent_instances(agent_id),
                grantee_agent_id TEXT NOT NULL REFERENCES agent_instances(agent_id),
                granted_by_agent_id TEXT NOT NULL REFERENCES agent_instances(agent_id),
                capability TEXT NOT NULL CHECK(capability IN ('assign','cancel','configure','close')),
                transitive INTEGER NOT NULL DEFAULT 0 CHECK(transitive=0),
                created_at TEXT NOT NULL,
                revoked_at TEXT
             );
             CREATE INDEX IF NOT EXISTS agent_management_grants_grantee
                ON agent_management_grants(grantee_agent_id,revoked_at,target_agent_id);
             CREATE UNIQUE INDEX IF NOT EXISTS agent_management_grants_active
                ON agent_management_grants(target_agent_id,grantee_agent_id,capability)
                WHERE revoked_at IS NULL;

             CREATE TABLE IF NOT EXISTS agent_management_grant_batches (
                batch_id TEXT PRIMARY KEY,
                idempotency_key TEXT NOT NULL UNIQUE,
                target_agent_id TEXT NOT NULL REFERENCES agent_instances(agent_id),
                grantee_agent_id TEXT NOT NULL REFERENCES agent_instances(agent_id),
                granted_by_agent_id TEXT NOT NULL REFERENCES agent_instances(agent_id),
                capabilities_json TEXT NOT NULL,
                result_grant_ids_json TEXT NOT NULL,
                created_at TEXT NOT NULL
             );

             CREATE TABLE IF NOT EXISTS agent_write_claims (
                claim_id TEXT PRIMARY KEY,
                idempotency_key TEXT NOT NULL UNIQUE,
                execution_id TEXT REFERENCES execution_nodes(execution_id) ON DELETE CASCADE,
                agent_id TEXT REFERENCES agent_instances(agent_id),
                holder_session_id TEXT,
                workspace_id TEXT NOT NULL,
                kind TEXT NOT NULL CHECK(kind IN ('scoped_write','workspace_process')),
                canonical_scope TEXT NOT NULL,
                state TEXT NOT NULL DEFAULT 'queued'
                    CHECK(state IN ('queued','held','released','cancelled')),
                requested_at TEXT NOT NULL,
                acquired_at TEXT,
                released_at TEXT,
                process_id INTEGER CHECK(process_id IS NULL OR process_id>0),
                process_identity TEXT,
                CHECK (
                    (execution_id IS NOT NULL AND agent_id IS NOT NULL
                     AND holder_session_id IS NULL)
                    OR
                    (execution_id IS NULL AND agent_id IS NULL
                     AND holder_session_id IS NOT NULL)
                ),
                CHECK ((kind='workspace_process')=(canonical_scope='.')),
                CHECK (kind='workspace_process'
                       OR (process_id IS NULL AND process_identity IS NULL)),
                CHECK ((process_id IS NULL)=(process_identity IS NULL)),
                CHECK ((state='held')=(acquired_at IS NOT NULL AND released_at IS NULL)),
                CHECK ((state IN ('released','cancelled'))=(released_at IS NOT NULL))
             );
             CREATE INDEX IF NOT EXISTS agent_write_claims_schedule
                ON agent_write_claims(workspace_id,state,requested_at,claim_id);
             CREATE INDEX IF NOT EXISTS agent_write_claims_execution
                ON agent_write_claims(execution_id,state,requested_at,claim_id);
             CREATE INDEX IF NOT EXISTS agent_write_claims_session
                ON agent_write_claims(holder_session_id,state,requested_at,claim_id);

             INSERT OR IGNORE INTO execution_nodes(
                execution_id,kind,parent_execution_id,owner_agent_id,root_session_id,
                trace_id,causal_depth,child_slot,worker_invocation_id,assignment_id,created_at
             )
             SELECT 'execution_' || invocation_id,'worker',NULL,NULL,origin_session_id,
                    trace_id,causal_depth,parent_worker_tool_ordinal,invocation_id,NULL,created_at
             FROM worker_invocations
             WHERE NOT EXISTS(
                SELECT 1 FROM worker_schema WHERE version=19
             );
             UPDATE execution_nodes AS child
             SET parent_execution_id=(
                SELECT parent.execution_id
                FROM execution_nodes parent
                JOIN worker_invocations parent_invocation
                  ON parent_invocation.invocation_id=parent.worker_invocation_id
                JOIN worker_invocations child_invocation
                  ON child_invocation.invocation_id=child.worker_invocation_id
                WHERE parent_invocation.invocation_id=child_invocation.parent_worker_invocation_id
             )
             WHERE NOT EXISTS(
                    SELECT 1 FROM worker_schema WHERE version=19
                   )
               AND child.kind='worker' AND child.parent_execution_id IS NULL
               AND EXISTS (
                SELECT 1 FROM worker_invocations child_invocation
                WHERE child_invocation.invocation_id=child.worker_invocation_id
                  AND child_invocation.parent_worker_invocation_id IS NOT NULL
             );
             INSERT OR IGNORE INTO worker_schema(version,applied_at)
                VALUES(19,strftime('%Y-%m-%dT%H:%M:%fZ','now'));",
        )
        .map_err(|error| format!("initialize reusable-agent coordination schema v19: {error}"))?;
    if !table_has_column(
        connection,
        "agent_assignment_attempts",
        "baseline_event_sequence",
    )? {
        connection
            .execute(
                "ALTER TABLE agent_assignment_attempts
                 ADD COLUMN baseline_event_sequence INTEGER NOT NULL DEFAULT 0
                 CHECK(baseline_event_sequence>=0)",
                [],
            )
            .map_err(|error| format!("add agent attempt transcript baseline: {error}"))?;
    }
    Ok(())
}

/// Add durable retry scheduling to the reusable-agent coordination outbox.
///
/// Existing rows become immediately due. `processed_at` remains the canonical
/// terminal timestamp for imported and rejected rows; `last_error` remains the
/// bounded durable poison/retry evidence.
pub(crate) fn install_schema_v21(connection: &rusqlite::Connection) -> Result<(), String> {
    if !table_has_column(connection, "agent_outbox", "next_attempt_at")? {
        connection
            .execute(
                "ALTER TABLE agent_outbox
                 ADD COLUMN next_attempt_at TEXT NOT NULL
                 DEFAULT '1970-01-01T00:00:00.000Z'",
                [],
            )
            .map_err(|error| format!("add agent outbox retry schedule: {error}"))?;
    }
    connection
        .execute_batch(
            "DROP INDEX IF EXISTS agent_outbox_pending;
             CREATE INDEX IF NOT EXISTS agent_outbox_due
                ON agent_outbox(
                    disposition,next_attempt_at,created_at,outbox_id
                );
             INSERT OR IGNORE INTO worker_schema(version,applied_at)
                VALUES(21,strftime('%Y-%m-%dT%H:%M:%fZ','now'));",
        )
        .map_err(|error| format!("initialize agent outbox scheduling schema v21: {error}"))
}
