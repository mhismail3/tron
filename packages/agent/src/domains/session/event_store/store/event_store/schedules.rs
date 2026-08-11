//! Transactional schedule persistence facade.
//!
//! Recurrence computation happens in the schedule domain. This facade makes
//! admission durable: cursor advancement and occurrence inserts share one
//! immediate transaction, and exact deterministic keys make retries harmless.

use chrono::{DateTime, Duration, Utc};
use rusqlite::TransactionBehavior;

use super::EventStore;
use crate::domains::session::event_store::errors::{EventStoreError, Result};
use crate::domains::session::event_store::sqlite::repositories::schedule::{
    ScheduleRepo, StoredSchedule, StoredScheduleOccurrence,
};

/// Transactional reconciliation commit prepared by the schedule domain.
pub(crate) struct StoredScheduleReconciliation {
    pub(crate) schedule_id: String,
    pub(crate) expected_revision: i64,
    pub(crate) expected_cursor_at: String,
    pub(crate) cursor_at: String,
    pub(crate) next_due_at: Option<String>,
    pub(crate) admitted_at: String,
    pub(crate) skip_on_overlap: bool,
    pub(crate) occurrences: Vec<StoredScheduleOccurrence>,
}

impl EventStore {
    /// Insert a schedule, returning an exact idempotent replay when present.
    pub(crate) fn create_stored_schedule_idempotently(
        &self,
        row: &StoredSchedule,
    ) -> Result<StoredSchedule> {
        self.with_global_write_lock(|| {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            if let Some(existing) =
                ScheduleRepo::get_by_idempotency_key(&transaction, &row.idempotency_key)?
            {
                if existing.request_digest != row.request_digest {
                    return Err(EventStoreError::InvalidOperation(
                        "schedule create idempotency key was reused with different content"
                            .to_owned(),
                    ));
                }
                transaction.commit()?;
                return Ok(existing);
            }
            ScheduleRepo::insert(&transaction, row)?;
            transaction.commit()?;
            Ok(row.clone())
        })
    }

    /// Read one stored schedule.
    pub(crate) fn get_stored_schedule(&self, schedule_id: &str) -> Result<Option<StoredSchedule>> {
        let connection = self.conn()?;
        ScheduleRepo::get(&connection, schedule_id)
    }

    /// Read the canonical row admitted by a create idempotency key.
    pub(crate) fn get_stored_schedule_by_idempotency_key(
        &self,
        idempotency_key: &str,
    ) -> Result<Option<StoredSchedule>> {
        let connection = self.conn()?;
        ScheduleRepo::get_by_idempotency_key(&connection, idempotency_key)
    }

    /// Stable schedule list page.
    pub(crate) fn list_stored_schedules(
        &self,
        owner_agent_id: Option<&str>,
        include_deleted: bool,
        cursor: Option<(&str, &str)>,
        limit: u16,
    ) -> Result<Vec<StoredSchedule>> {
        let connection = self.conn()?;
        ScheduleRepo::list(&connection, owner_agent_id, include_deleted, cursor, limit)
    }

    /// Compare-and-set a canonical schedule row.
    pub(crate) fn update_stored_schedule_cas(
        &self,
        row: &StoredSchedule,
        expected_revision: i64,
    ) -> Result<bool> {
        self.with_global_write_lock(|| {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let changed = ScheduleRepo::update_cas(&transaction, row, expected_revision)?;
            if changed && row.state == "deleted" {
                let _ = transaction.execute(
                    "UPDATE schedule_occurrences SET
                       state='cancelled',skip_reason='schedule_deleted',finished_at=?2
                     WHERE schedule_id=?1 AND state='queued'",
                    rusqlite::params![row.schedule_id, row.updated_at],
                )?;
            }
            transaction.commit()?;
            Ok(changed)
        })
    }

    /// Active schedules currently due, ordered by the durable next-due hint.
    pub(crate) fn list_due_stored_schedules(
        &self,
        through: &str,
        limit: u16,
    ) -> Result<Vec<StoredSchedule>> {
        let connection = self.conn()?;
        ScheduleRepo::list_due(&connection, through, limit)
    }

    /// Commit one restart-safe cursor transition and all resulting audit rows.
    pub(crate) fn commit_schedule_reconciliation(
        &self,
        commit: &StoredScheduleReconciliation,
    ) -> Result<bool> {
        self.with_global_write_lock(|| {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let Some(mut schedule) = ScheduleRepo::get(&transaction, &commit.schedule_id)? else {
                transaction.commit()?;
                return Ok(false);
            };
            if schedule.state != "active"
                || schedule.revision != commit.expected_revision
                || schedule.cursor_at != commit.expected_cursor_at
            {
                transaction.commit()?;
                return Ok(false);
            }

            let mut overlap = commit.skip_on_overlap
                && ScheduleRepo::has_active_occurrence(&transaction, &commit.schedule_id)?;
            for candidate in &commit.occurrences {
                let mut occurrence = candidate.clone();
                if overlap && occurrence.state == "queued" {
                    occurrence.state = "skipped".to_owned();
                    occurrence.skip_reason = Some("overlap_policy".to_owned());
                    occurrence.finished_at = Some(commit.admitted_at.clone());
                }
                if let Some(existing) =
                    ScheduleRepo::get_occurrence_by_key(&transaction, &occurrence.occurrence_key)?
                {
                    if existing.schedule_id != occurrence.schedule_id
                        || existing.scheduled_for != occurrence.scheduled_for
                    {
                        return Err(EventStoreError::InvalidOperation(
                            "deterministic schedule occurrence key collision".to_owned(),
                        ));
                    }
                    continue;
                }
                ScheduleRepo::insert_occurrence(&transaction, &occurrence)?;
                if commit.skip_on_overlap && occurrence.state == "queued" {
                    overlap = true;
                }
            }

            schedule.cursor_at.clone_from(&commit.cursor_at);
            schedule.next_due_at.clone_from(&commit.next_due_at);
            schedule.last_error = None;
            schedule.updated_at.clone_from(&commit.admitted_at);
            let changed =
                ScheduleRepo::update_cas(&transaction, &schedule, commit.expected_revision)?;
            if !changed {
                return Err(EventStoreError::Internal(
                    "schedule reconciliation CAS changed beneath immediate transaction".to_owned(),
                ));
            }
            transaction.commit()?;
            Ok(true)
        })
    }

    /// Retain a bounded expansion failure without moving the cursor or changing
    /// the model/client CAS revision.
    pub(crate) fn record_schedule_reconciliation_error(
        &self,
        schedule_id: &str,
        expected_revision: i64,
        expected_cursor_at: &str,
        error: &str,
        updated_at: &str,
    ) -> Result<bool> {
        self.with_global_write_lock(|| {
            let connection = self.conn()?;
            Ok(connection.execute(
                "UPDATE schedules SET last_error=?4,updated_at=?5
                 WHERE schedule_id=?1 AND revision=?2 AND cursor_at=?3 AND state='active'",
                rusqlite::params![
                    schedule_id,
                    expected_revision,
                    expected_cursor_at,
                    error,
                    updated_at
                ],
            )? == 1)
        })
    }

    /// Insert a manual occurrence or return its exact idempotent replay.
    pub(crate) fn create_manual_schedule_occurrence_idempotently(
        &self,
        row: &StoredScheduleOccurrence,
        skip_on_overlap: bool,
    ) -> Result<StoredScheduleOccurrence> {
        self.with_global_write_lock(|| {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            if let Some(existing) =
                ScheduleRepo::get_occurrence_by_key(&transaction, &row.occurrence_key)?
            {
                if existing.schedule_id != row.schedule_id || existing.kind != "manual" {
                    return Err(EventStoreError::InvalidOperation(
                        "schedule run_now idempotency key was reused with different content"
                            .to_owned(),
                    ));
                }
                transaction.commit()?;
                return Ok(existing);
            }
            let Some(schedule) = ScheduleRepo::get(&transaction, &row.schedule_id)? else {
                return Err(EventStoreError::InvalidOperation(
                    "schedule not found".to_owned(),
                ));
            };
            if schedule.state == "deleted" {
                return Err(EventStoreError::InvalidOperation(
                    "deleted schedule cannot run".to_owned(),
                ));
            }
            let mut occurrence = row.clone();
            if skip_on_overlap
                && ScheduleRepo::has_active_occurrence(&transaction, &row.schedule_id)?
            {
                occurrence.state = "skipped".to_owned();
                occurrence.skip_reason = Some("overlap_policy".to_owned());
                occurrence.finished_at = Some(row.created_at.clone());
            }
            ScheduleRepo::insert_occurrence(&transaction, &occurrence)?;
            transaction.commit()?;
            Ok(occurrence)
        })
    }

    /// Newest-first bounded occurrence audit.
    pub(crate) fn list_stored_schedule_occurrences(
        &self,
        schedule_id: &str,
        limit: u16,
    ) -> Result<Vec<StoredScheduleOccurrence>> {
        let connection = self.conn()?;
        ScheduleRepo::list_occurrences(&connection, schedule_id, limit)
    }

    /// Recover expired work and lease the earliest queued occurrence.
    pub(crate) fn claim_next_schedule_occurrence(
        &self,
        claim_owner: &str,
        now: DateTime<Utc>,
        lease_duration: Duration,
    ) -> Result<Option<StoredScheduleOccurrence>> {
        if claim_owner.is_empty() || lease_duration <= Duration::zero() {
            return Err(EventStoreError::InvalidOperation(
                "schedule claim requires an owner and positive lease".to_owned(),
            ));
        }
        self.with_global_write_lock(|| {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let now = now.to_rfc3339();
            let _ = ScheduleRepo::recover_expired_leases(&transaction, &now)?;
            let Some(candidate) = ScheduleRepo::next_queued(&transaction)? else {
                transaction.commit()?;
                return Ok(None);
            };
            let lease_expires_at = (DateTime::parse_from_rfc3339(&now)
                .map_err(|error| EventStoreError::Internal(error.to_string()))?
                + lease_duration)
                .to_rfc3339();
            if !ScheduleRepo::claim(
                &transaction,
                &candidate.occurrence_id,
                claim_owner,
                &now,
                &lease_expires_at,
            )? {
                return Err(EventStoreError::Internal(
                    "queued schedule occurrence changed beneath immediate transaction".to_owned(),
                ));
            }
            let claimed = ScheduleRepo::get_occurrence(&transaction, &candidate.occurrence_id)?
                .ok_or_else(|| {
                    EventStoreError::Internal("claimed schedule occurrence disappeared".to_owned())
                })?;
            transaction.commit()?;
            Ok(Some(claimed))
        })
    }

    /// Renew an exact schedule occurrence lease.
    pub(crate) fn renew_schedule_occurrence_lease(
        &self,
        occurrence_id: &str,
        claim_owner: &str,
        lease_expires_at: &str,
    ) -> Result<bool> {
        self.with_global_write_lock(|| {
            let connection = self.conn()?;
            ScheduleRepo::renew_lease(&connection, occurrence_id, claim_owner, lease_expires_at)
        })
    }

    /// Bind the agent and assignment created for one running occurrence.
    pub(crate) fn bind_schedule_occurrence_agent_assignment(
        &self,
        occurrence_id: &str,
        claim_owner: &str,
        agent_id: &str,
        assignment_id: &str,
    ) -> Result<bool> {
        self.with_global_write_lock(|| {
            let connection = self.conn()?;
            ScheduleRepo::bind_agent_assignment(
                &connection,
                occurrence_id,
                claim_owner,
                agent_id,
                assignment_id,
            )
        })
    }

    /// Bind the registry invocation created for one capability occurrence.
    pub(crate) fn bind_schedule_occurrence_capability_invocation(
        &self,
        occurrence_id: &str,
        claim_owner: &str,
        invocation_id: &str,
    ) -> Result<bool> {
        self.with_global_write_lock(|| {
            let connection = self.conn()?;
            ScheduleRepo::bind_capability_invocation(
                &connection,
                occurrence_id,
                claim_owner,
                invocation_id,
            )
        })
    }

    /// Terminalize one exact running occurrence.
    pub(crate) fn terminalize_schedule_occurrence(
        &self,
        occurrence_id: &str,
        claim_owner: &str,
        succeeded: bool,
        output_ref: Option<&str>,
        failure: Option<&str>,
        finished_at: &str,
    ) -> Result<bool> {
        self.with_global_write_lock(|| {
            let connection = self.conn()?;
            ScheduleRepo::terminalize(
                &connection,
                occurrence_id,
                claim_owner,
                if succeeded { "completed" } else { "failed" },
                output_ref,
                failure,
                finished_at,
            )
        })
    }
}
