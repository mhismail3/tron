//! Durable schedule and occurrence repository.
//!
//! This layer stores already-validated canonical JSON and enforces lifecycle,
//! revision, idempotency, and deterministic occurrence keys. RFC expansion and
//! policy decisions remain owned by the schedule domain.

use rusqlite::{Connection, OptionalExtension, Row, params};

use crate::domains::session::event_store::errors::Result;

/// Canonical persisted schedule row.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct StoredSchedule {
    pub(crate) schedule_id: String,
    pub(crate) idempotency_key: String,
    pub(crate) request_digest: String,
    pub(crate) owner_agent_id: String,
    pub(crate) name: String,
    pub(crate) target_kind: String,
    pub(crate) target_principal_agent_id: Option<String>,
    pub(crate) target_json: String,
    pub(crate) authority_json: String,
    pub(crate) timing_kind: String,
    pub(crate) timing_json: String,
    pub(crate) policy_json: String,
    pub(crate) state: String,
    pub(crate) revision: i64,
    pub(crate) cursor_at: String,
    pub(crate) next_due_at: Option<String>,
    pub(crate) last_error: Option<String>,
    pub(crate) created_at: String,
    pub(crate) updated_at: String,
    pub(crate) deleted_at: Option<String>,
}

/// Canonical persisted occurrence row.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct StoredScheduleOccurrence {
    pub(crate) occurrence_id: String,
    pub(crate) occurrence_key: String,
    pub(crate) schedule_id: String,
    pub(crate) schedule_revision: i64,
    pub(crate) kind: String,
    pub(crate) scheduled_for: String,
    pub(crate) state: String,
    pub(crate) target_json: String,
    pub(crate) authority_json: String,
    pub(crate) missed_count: i64,
    pub(crate) window_start: Option<String>,
    pub(crate) window_end: Option<String>,
    pub(crate) skip_reason: Option<String>,
    pub(crate) agent_id: Option<String>,
    pub(crate) assignment_id: Option<String>,
    pub(crate) invocation_id: Option<String>,
    pub(crate) output_ref: Option<String>,
    pub(crate) failure: Option<String>,
    pub(crate) claim_owner: Option<String>,
    pub(crate) lease_expires_at: Option<String>,
    pub(crate) attempt: i64,
    pub(crate) created_at: String,
    pub(crate) started_at: Option<String>,
    pub(crate) finished_at: Option<String>,
}

/// Stateless schedule repository.
pub(crate) struct ScheduleRepo;

impl ScheduleRepo {
    /// Insert one canonical schedule.
    pub(crate) fn insert(conn: &Connection, row: &StoredSchedule) -> Result<()> {
        let _ = conn.execute(
            "INSERT INTO schedules (
               schedule_id,idempotency_key,request_digest,owner_agent_id,name,
               target_kind,target_principal_agent_id,target_json,authority_json,
               timing_kind,timing_json,policy_json,
               state,revision,cursor_at,next_due_at,last_error,created_at,updated_at,deleted_at
             ) VALUES (
               ?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20
             )",
            params![
                row.schedule_id,
                row.idempotency_key,
                row.request_digest,
                row.owner_agent_id,
                row.name,
                row.target_kind,
                row.target_principal_agent_id,
                row.target_json,
                row.authority_json,
                row.timing_kind,
                row.timing_json,
                row.policy_json,
                row.state,
                row.revision,
                row.cursor_at,
                row.next_due_at,
                row.last_error,
                row.created_at,
                row.updated_at,
                row.deleted_at,
            ],
        )?;
        Ok(())
    }

    /// Read by stable ID.
    pub(crate) fn get(conn: &Connection, schedule_id: &str) -> Result<Option<StoredSchedule>> {
        Ok(conn
            .query_row(
                &format!("{} WHERE schedule_id=?1", schedule_select()),
                [schedule_id],
                map_schedule,
            )
            .optional()?)
    }

    /// Read an idempotent create admission.
    pub(crate) fn get_by_idempotency_key(
        conn: &Connection,
        idempotency_key: &str,
    ) -> Result<Option<StoredSchedule>> {
        Ok(conn
            .query_row(
                &format!("{} WHERE idempotency_key=?1", schedule_select()),
                [idempotency_key],
                map_schedule,
            )
            .optional()?)
    }

    /// Stable ascending keyset list.
    pub(crate) fn list(
        conn: &Connection,
        owner_agent_id: Option<&str>,
        include_deleted: bool,
        cursor: Option<(&str, &str)>,
        limit: u16,
    ) -> Result<Vec<StoredSchedule>> {
        let (cursor_created_at, cursor_id) = cursor.unzip();
        let mut statement = conn.prepare(&format!(
            "{} WHERE (?1 IS NULL OR owner_agent_id=?1)
               AND (?2 OR state!='deleted')
               AND (?3 IS NULL OR created_at>?3 OR (created_at=?3 AND schedule_id>?4))
             ORDER BY created_at,schedule_id LIMIT ?5",
            schedule_select()
        ))?;
        Ok(statement
            .query_map(
                params![
                    owner_agent_id,
                    include_deleted,
                    cursor_created_at,
                    cursor_id,
                    limit
                ],
                map_schedule,
            )?
            .collect::<std::result::Result<Vec<_>, _>>()?)
    }

    /// Replace all canonical mutable fields if the revision still matches.
    pub(crate) fn update_cas(
        conn: &Connection,
        row: &StoredSchedule,
        expected_revision: i64,
    ) -> Result<bool> {
        let changed = conn.execute(
            "UPDATE schedules SET
               name=?3,target_kind=?4,target_principal_agent_id=?5,target_json=?6,
               authority_json=?7,timing_kind=?8,timing_json=?9,policy_json=?10,
               state=?11,revision=?12,cursor_at=?13,next_due_at=?14,last_error=?15,
               updated_at=?16,deleted_at=?17
             WHERE schedule_id=?1 AND revision=?2",
            params![
                row.schedule_id,
                expected_revision,
                row.name,
                row.target_kind,
                row.target_principal_agent_id,
                row.target_json,
                row.authority_json,
                row.timing_kind,
                row.timing_json,
                row.policy_json,
                row.state,
                row.revision,
                row.cursor_at,
                row.next_due_at,
                row.last_error,
                row.updated_at,
                row.deleted_at,
            ],
        )?;
        Ok(changed == 1)
    }

    /// Active schedules whose next occurrence is due.
    pub(crate) fn list_due(
        conn: &Connection,
        through: &str,
        limit: u16,
    ) -> Result<Vec<StoredSchedule>> {
        let mut statement = conn.prepare(&format!(
            "{} WHERE state='active' AND next_due_at IS NOT NULL
               AND rfc3339_sort_key(next_due_at)<=rfc3339_sort_key(?1)
             ORDER BY rfc3339_sort_key(next_due_at),schedule_id LIMIT ?2",
            schedule_select()
        ))?;
        Ok(statement
            .query_map(params![through, limit], map_schedule)?
            .collect::<std::result::Result<Vec<_>, _>>()?)
    }

    /// Insert an immutable occurrence admission/audit row.
    pub(crate) fn insert_occurrence(
        conn: &Connection,
        row: &StoredScheduleOccurrence,
    ) -> Result<()> {
        let _ = conn.execute(
            "INSERT INTO schedule_occurrences (
               occurrence_id,occurrence_key,schedule_id,schedule_revision,kind,scheduled_for,
               state,target_json,authority_json,missed_count,window_start,window_end,skip_reason,
               agent_id,assignment_id,invocation_id,output_ref,failure,claim_owner,lease_expires_at,
               attempt,created_at,started_at,finished_at
             ) VALUES (
               ?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,
               ?18,?19,?20,?21,?22,?23,?24
             )",
            params![
                row.occurrence_id,
                row.occurrence_key,
                row.schedule_id,
                row.schedule_revision,
                row.kind,
                row.scheduled_for,
                row.state,
                row.target_json,
                row.authority_json,
                row.missed_count,
                row.window_start,
                row.window_end,
                row.skip_reason,
                row.agent_id,
                row.assignment_id,
                row.invocation_id,
                row.output_ref,
                row.failure,
                row.claim_owner,
                row.lease_expires_at,
                row.attempt,
                row.created_at,
                row.started_at,
                row.finished_at,
            ],
        )?;
        Ok(())
    }

    /// Read an occurrence by deterministic key.
    pub(crate) fn get_occurrence_by_key(
        conn: &Connection,
        occurrence_key: &str,
    ) -> Result<Option<StoredScheduleOccurrence>> {
        Ok(conn
            .query_row(
                &format!("{} WHERE occurrence_key=?1", occurrence_select()),
                [occurrence_key],
                map_occurrence,
            )
            .optional()?)
    }

    /// Read one occurrence by ID.
    pub(crate) fn get_occurrence(
        conn: &Connection,
        occurrence_id: &str,
    ) -> Result<Option<StoredScheduleOccurrence>> {
        Ok(conn
            .query_row(
                &format!("{} WHERE occurrence_id=?1", occurrence_select()),
                [occurrence_id],
                map_occurrence,
            )
            .optional()?)
    }

    /// Newest-first bounded audit for one schedule.
    pub(crate) fn list_occurrences(
        conn: &Connection,
        schedule_id: &str,
        limit: u16,
    ) -> Result<Vec<StoredScheduleOccurrence>> {
        let mut statement = conn.prepare(&format!(
            "{} WHERE schedule_id=?1 ORDER BY created_at DESC,occurrence_id DESC LIMIT ?2",
            occurrence_select()
        ))?;
        Ok(statement
            .query_map(params![schedule_id, limit], map_occurrence)?
            .collect::<std::result::Result<Vec<_>, _>>()?)
    }

    /// Whether queued/running work already exists for overlap decisions.
    pub(crate) fn has_active_occurrence(conn: &Connection, schedule_id: &str) -> Result<bool> {
        Ok(conn.query_row(
            "SELECT EXISTS(
               SELECT 1 FROM schedule_occurrences
               WHERE schedule_id=?1 AND state IN ('queued','running')
             )",
            [schedule_id],
            |row| row.get(0),
        )?)
    }

    /// Return expired running work to its queue after restart/lease loss.
    pub(crate) fn recover_expired_leases(conn: &Connection, now: &str) -> Result<usize> {
        Ok(conn.execute(
            "UPDATE schedule_occurrences SET
               state='queued',claim_owner=NULL,lease_expires_at=NULL,started_at=NULL
             WHERE state='running'
               AND rfc3339_sort_key(lease_expires_at)<=rfc3339_sort_key(?1)",
            [now],
        )?)
    }

    /// Read the earliest queued occurrence.
    pub(crate) fn next_queued(conn: &Connection) -> Result<Option<StoredScheduleOccurrence>> {
        Ok(conn
            .query_row(
                &format!(
                    "{} WHERE state='queued'
                     ORDER BY rfc3339_sort_key(scheduled_for),created_at,occurrence_id LIMIT 1",
                    occurrence_select()
                ),
                [],
                map_occurrence,
            )
            .optional()?)
    }

    /// Lease one queued occurrence by exact state compare-and-set.
    pub(crate) fn claim(
        conn: &Connection,
        occurrence_id: &str,
        claim_owner: &str,
        started_at: &str,
        lease_expires_at: &str,
    ) -> Result<bool> {
        Ok(conn.execute(
            "UPDATE schedule_occurrences SET
               state='running',claim_owner=?2,lease_expires_at=?3,started_at=?4,
               attempt=attempt+1
             WHERE occurrence_id=?1 AND state='queued'",
            params![occurrence_id, claim_owner, lease_expires_at, started_at],
        )? == 1)
    }

    /// Renew an exact running lease.
    pub(crate) fn renew_lease(
        conn: &Connection,
        occurrence_id: &str,
        claim_owner: &str,
        lease_expires_at: &str,
    ) -> Result<bool> {
        Ok(conn.execute(
            "UPDATE schedule_occurrences SET lease_expires_at=?3
             WHERE occurrence_id=?1 AND state='running' AND claim_owner=?2",
            params![occurrence_id, claim_owner, lease_expires_at],
        )? == 1)
    }

    /// Attach the agent/assignment created by a running execution boundary.
    pub(crate) fn bind_agent_assignment(
        conn: &Connection,
        occurrence_id: &str,
        claim_owner: &str,
        agent_id: &str,
        assignment_id: &str,
    ) -> Result<bool> {
        Ok(conn.execute(
            "UPDATE schedule_occurrences SET agent_id=?3,assignment_id=?4
             WHERE occurrence_id=?1 AND state='running' AND claim_owner=?2",
            params![occurrence_id, claim_owner, agent_id, assignment_id],
        )? == 1)
    }

    /// Attach the direct/service/script invocation created for a capability.
    pub(crate) fn bind_capability_invocation(
        conn: &Connection,
        occurrence_id: &str,
        claim_owner: &str,
        invocation_id: &str,
    ) -> Result<bool> {
        Ok(conn.execute(
            "UPDATE schedule_occurrences SET invocation_id=?3
             WHERE occurrence_id=?1 AND state='running' AND claim_owner=?2",
            params![occurrence_id, claim_owner, invocation_id],
        )? == 1)
    }

    /// Terminalize one exact running occurrence.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn terminalize(
        conn: &Connection,
        occurrence_id: &str,
        claim_owner: &str,
        state: &str,
        output_ref: Option<&str>,
        failure: Option<&str>,
        finished_at: &str,
    ) -> Result<bool> {
        Ok(conn.execute(
            "UPDATE schedule_occurrences SET
               state=?3,output_ref=?4,failure=?5,finished_at=?6,
               claim_owner=NULL,lease_expires_at=NULL
             WHERE occurrence_id=?1 AND state='running' AND claim_owner=?2",
            params![
                occurrence_id,
                claim_owner,
                state,
                output_ref,
                failure,
                finished_at
            ],
        )? == 1)
    }
}

fn schedule_select() -> &'static str {
    "SELECT schedule_id,idempotency_key,request_digest,owner_agent_id,name,
            target_kind,target_principal_agent_id,target_json,authority_json,
            timing_kind,timing_json,policy_json,
            state,revision,cursor_at,next_due_at,last_error,created_at,updated_at,deleted_at
     FROM schedules"
}

fn occurrence_select() -> &'static str {
    "SELECT occurrence_id,occurrence_key,schedule_id,schedule_revision,kind,scheduled_for,
            state,target_json,authority_json,missed_count,window_start,window_end,skip_reason,
            agent_id,assignment_id,invocation_id,output_ref,failure,claim_owner,lease_expires_at,
            attempt,created_at,started_at,finished_at
     FROM schedule_occurrences"
}

fn map_schedule(row: &Row<'_>) -> rusqlite::Result<StoredSchedule> {
    Ok(StoredSchedule {
        schedule_id: row.get(0)?,
        idempotency_key: row.get(1)?,
        request_digest: row.get(2)?,
        owner_agent_id: row.get(3)?,
        name: row.get(4)?,
        target_kind: row.get(5)?,
        target_principal_agent_id: row.get(6)?,
        target_json: row.get(7)?,
        authority_json: row.get(8)?,
        timing_kind: row.get(9)?,
        timing_json: row.get(10)?,
        policy_json: row.get(11)?,
        state: row.get(12)?,
        revision: row.get(13)?,
        cursor_at: row.get(14)?,
        next_due_at: row.get(15)?,
        last_error: row.get(16)?,
        created_at: row.get(17)?,
        updated_at: row.get(18)?,
        deleted_at: row.get(19)?,
    })
}

fn map_occurrence(row: &Row<'_>) -> rusqlite::Result<StoredScheduleOccurrence> {
    Ok(StoredScheduleOccurrence {
        occurrence_id: row.get(0)?,
        occurrence_key: row.get(1)?,
        schedule_id: row.get(2)?,
        schedule_revision: row.get(3)?,
        kind: row.get(4)?,
        scheduled_for: row.get(5)?,
        state: row.get(6)?,
        target_json: row.get(7)?,
        authority_json: row.get(8)?,
        missed_count: row.get(9)?,
        window_start: row.get(10)?,
        window_end: row.get(11)?,
        skip_reason: row.get(12)?,
        agent_id: row.get(13)?,
        assignment_id: row.get(14)?,
        invocation_id: row.get(15)?,
        output_ref: row.get(16)?,
        failure: row.get(17)?,
        claim_owner: row.get(18)?,
        lease_expires_at: row.get(19)?,
        attempt: row.get(20)?,
        created_at: row.get(21)?,
        started_at: row.get(22)?,
        finished_at: row.get(23)?,
    })
}
