//! Revision-safe schedule commands and restart reconciliation.

use std::sync::Arc;

use base64::Engine as _;
use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;

use super::contract::{
    DEFAULT_SCHEDULE_PAGE_SIZE, MAX_CATCH_UP, MAX_SCHEDULE_PAGE_SIZE, MISFIRE_GRACE_SECONDS,
    MisfirePolicy, OccurrenceKind, OccurrenceState, OverlapPolicy, ScheduleAction,
    ScheduleAuthoritySnapshot, ScheduleDetail, ScheduleOccurrence, SchedulePage, SchedulePatch,
    SchedulePolicy, ScheduleRecord, ScheduleResponse, ScheduleState, ScheduleTarget,
    ScheduleTiming,
};
use super::recurrence::{
    Expansion, RecurrenceError, expand_window, utc_string, validate_policy, validate_timing,
};
use crate::domains::session::event_store::sqlite::repositories::schedule::{
    StoredSchedule, StoredScheduleOccurrence,
};
use crate::domains::session::event_store::store::StoredScheduleReconciliation;
use crate::domains::session::event_store::{EventStore, EventStoreError};

const MAX_NAME_BYTES: usize = 200;
const MAX_TASK_BYTES: usize = 40_000;
const MAX_IDENTIFIER_BYTES: usize = 512;
const MAX_RECENT_OCCURRENCES: u16 = 100;
const MAX_DUE_SCHEDULES_PER_RECONCILE: u16 = 100;

/// Scheduling domain failure.
#[derive(Debug, Error)]
pub(crate) enum ScheduleError {
    /// Closed contract or lifecycle violation.
    #[error("invalid schedule request: {0}")]
    Invalid(String),
    /// Stable schedule was not found.
    #[error("schedule not found: {0}")]
    NotFound(String),
    /// Mutation raced a newer canonical revision.
    #[error("schedule revision conflict: expected {expected}, current {current}")]
    RevisionConflict {
        /// Caller revision.
        expected: u64,
        /// Canonical revision.
        current: u64,
    },
    /// RFC 5545 or operational recurrence failure.
    #[error(transparent)]
    Recurrence(#[from] RecurrenceError),
    /// Durable storage failure.
    #[error(transparent)]
    Store(#[from] EventStoreError),
}

/// Outcome of one dispatcher reconciliation pass.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct ReconcileReport {
    /// Due schedules considered.
    pub(crate) schedules_considered: usize,
    /// Occurrence rows prepared and atomically admitted/audited.
    pub(crate) occurrences_recorded: usize,
    /// Schedules whose state changed during computation and were retried later.
    pub(crate) races: usize,
    /// Expansion failures retained without cursor movement.
    pub(crate) failures: usize,
}

/// Unadvertised scheduling service.
#[derive(Clone)]
pub(crate) struct ScheduleService {
    store: Arc<EventStore>,
}

impl ScheduleService {
    /// Build the service over canonical `tron.sqlite` custody.
    pub(crate) fn new(store: Arc<EventStore>) -> Self {
        Self { store }
    }

    /// Execute one closed action using the current Engine clock.
    pub(crate) fn execute(
        &self,
        action: ScheduleAction,
    ) -> Result<ScheduleResponse, ScheduleError> {
        self.execute_at(action, Utc::now())
    }

    /// Execute as one authenticated stable agent.
    ///
    /// Schedule ownership is immutable: neither update nor any lifecycle
    /// transition can change `owner_agent_id`. Validating it before dispatch is
    /// therefore race-safe and prevents an unauthorized mutation from being
    /// committed before the caller learns it was denied.
    pub(crate) fn execute_for_agent(
        &self,
        action: ScheduleAction,
        caller_agent_id: &str,
    ) -> Result<ScheduleResponse, ScheduleError> {
        validate_identifier("callerAgentId", caller_agent_id)?;
        match &action {
            ScheduleAction::Create { owner_agent_id, .. } => {
                if owner_agent_id != caller_agent_id {
                    return Err(ScheduleError::Invalid(
                        "schedule owner must be the authenticated current agent".to_owned(),
                    ));
                }
            }
            ScheduleAction::List { owner_agent_id, .. } => {
                if owner_agent_id.as_deref() != Some(caller_agent_id) {
                    return Err(ScheduleError::Invalid(
                        "agent schedule lists must be restricted to the current owner".to_owned(),
                    ));
                }
            }
            ScheduleAction::Get { schedule_id, .. }
            | ScheduleAction::Update { schedule_id, .. }
            | ScheduleAction::Pause { schedule_id, .. }
            | ScheduleAction::Resume { schedule_id, .. }
            | ScheduleAction::Delete { schedule_id, .. }
            | ScheduleAction::RunNow { schedule_id, .. } => {
                let schedule = self.required_schedule(schedule_id)?;
                if schedule.owner_agent_id != caller_agent_id {
                    return Err(ScheduleError::Invalid(
                        "schedule is not managed by the current agent".to_owned(),
                    ));
                }
            }
        }
        self.execute(action)
    }

    /// Deterministic action execution used by the dispatcher and tests.
    pub(crate) fn execute_at(
        &self,
        action: ScheduleAction,
        now: DateTime<Utc>,
    ) -> Result<ScheduleResponse, ScheduleError> {
        match action {
            ScheduleAction::Create {
                idempotency_key,
                owner_agent_id,
                name,
                target,
                authority,
                timing,
                policy,
            } => self.create(
                idempotency_key,
                owner_agent_id,
                name,
                target,
                authority,
                timing,
                policy,
                now,
            ),
            ScheduleAction::List {
                owner_agent_id,
                include_deleted,
                cursor,
                limit,
            } => self.list(
                owner_agent_id.as_deref(),
                include_deleted,
                cursor.as_deref(),
                limit,
            ),
            ScheduleAction::Get {
                schedule_id,
                occurrence_limit,
            } => self.get(&schedule_id, occurrence_limit),
            ScheduleAction::Update {
                schedule_id,
                expected_revision,
                patch,
            } => self.update(&schedule_id, expected_revision, patch, now),
            ScheduleAction::Pause {
                schedule_id,
                expected_revision,
            } => self.transition(
                &schedule_id,
                expected_revision,
                ScheduleState::Paused,
                now,
                "pause",
            ),
            ScheduleAction::Resume {
                schedule_id,
                expected_revision,
            } => self.transition(
                &schedule_id,
                expected_revision,
                ScheduleState::Active,
                now,
                "resume",
            ),
            ScheduleAction::Delete {
                schedule_id,
                expected_revision,
            } => self.transition(
                &schedule_id,
                expected_revision,
                ScheduleState::Deleted,
                now,
                "delete",
            ),
            ScheduleAction::RunNow {
                schedule_id,
                idempotency_key,
            } => self.run_now(&schedule_id, &idempotency_key, now),
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn create(
        &self,
        idempotency_key: String,
        owner_agent_id: String,
        name: String,
        target: ScheduleTarget,
        authority: ScheduleAuthoritySnapshot,
        timing: ScheduleTiming,
        policy: SchedulePolicy,
        now: DateTime<Utc>,
    ) -> Result<ScheduleResponse, ScheduleError> {
        validate_identifier("idempotencyKey", &idempotency_key)?;
        validate_identifier("ownerAgentId", &owner_agent_id)?;
        validate_name(&name)?;
        validate_target(&target)?;
        validate_authority(&authority, &owner_agent_id)?;
        validate_policy(&policy)?;
        let timing = validate_timing(&timing)?.timing;
        let target_json = serde_json::to_string(&target)?;
        let authority_json = serde_json::to_string(&authority)?;
        let timing_json = serde_json::to_string(&timing)?;
        let policy_json = serde_json::to_string(&policy)?;
        let request_digest = digest_json(&serde_json::json!({
            "ownerAgentId": owner_agent_id,
            "name": name,
            "target": target,
            "authority": authority,
            "timing": timing,
            "policy": policy,
        }))?;
        if let Some(existing) = self
            .store
            .get_stored_schedule_by_idempotency_key(&idempotency_key)?
        {
            if existing.request_digest != request_digest {
                return Err(ScheduleError::Invalid(
                    "schedule create idempotency key was reused with different content".to_owned(),
                ));
            }
            return Ok(ScheduleResponse::Create {
                schedule: decode_schedule(existing)?,
            });
        }
        let initial = expand_window(&timing, now, now)?;
        if initial.next.is_none() {
            return Err(ScheduleError::Invalid(
                "schedule timing has no occurrence after creation".to_owned(),
            ));
        }
        let now_string = utc_string(now);
        let row = StoredSchedule {
            schedule_id: format!("schedule_{}", uuid::Uuid::now_v7()),
            idempotency_key,
            request_digest,
            owner_agent_id,
            name,
            target_kind: target_kind(&target).to_owned(),
            target_principal_agent_id: target_principal_agent_id(&target).map(ToOwned::to_owned),
            target_json,
            authority_json,
            timing_kind: timing_kind(&timing).to_owned(),
            timing_json,
            policy_json,
            state: "active".to_owned(),
            revision: 1,
            cursor_at: now_string.clone(),
            next_due_at: initial.next.map(utc_string),
            last_error: None,
            created_at: now_string.clone(),
            updated_at: now_string,
            deleted_at: None,
        };
        let row = self.store.create_stored_schedule_idempotently(&row)?;
        Ok(ScheduleResponse::Create {
            schedule: decode_schedule(row)?,
        })
    }

    fn list(
        &self,
        owner_agent_id: Option<&str>,
        include_deleted: bool,
        cursor: Option<&str>,
        limit: Option<u16>,
    ) -> Result<ScheduleResponse, ScheduleError> {
        if let Some(owner) = owner_agent_id {
            validate_identifier("ownerAgentId", owner)?;
        }
        let limit = limit
            .unwrap_or(DEFAULT_SCHEDULE_PAGE_SIZE)
            .clamp(1, MAX_SCHEDULE_PAGE_SIZE);
        let cursor = cursor.map(decode_cursor).transpose()?;
        let rows = self.store.list_stored_schedules(
            owner_agent_id,
            include_deleted,
            cursor
                .as_ref()
                .map(|cursor| (cursor.created_at.as_str(), cursor.schedule_id.as_str())),
            limit.saturating_add(1),
        )?;
        let has_more = rows.len() > usize::from(limit);
        let mut schedules = rows
            .into_iter()
            .take(usize::from(limit))
            .map(decode_schedule)
            .collect::<Result<Vec<_>, _>>()?;
        let next_cursor = if has_more {
            schedules
                .last()
                .map(|schedule| {
                    encode_cursor(&ScheduleCursor {
                        created_at: schedule.created_at.clone(),
                        schedule_id: schedule.schedule_id.clone(),
                    })
                })
                .transpose()?
        } else {
            None
        };
        Ok(ScheduleResponse::List {
            page: SchedulePage {
                schedules: std::mem::take(&mut schedules),
                next_cursor,
            },
        })
    }

    fn get(
        &self,
        schedule_id: &str,
        occurrence_limit: Option<u16>,
    ) -> Result<ScheduleResponse, ScheduleError> {
        validate_identifier("scheduleId", schedule_id)?;
        let schedule = self.required_schedule(schedule_id)?;
        let occurrences = self
            .store
            .list_stored_schedule_occurrences(
                schedule_id,
                occurrence_limit
                    .unwrap_or(25)
                    .clamp(1, MAX_RECENT_OCCURRENCES),
            )?
            .into_iter()
            .map(decode_occurrence)
            .collect::<Result<Vec<_>, _>>()?;
        Ok(ScheduleResponse::Get {
            detail: ScheduleDetail {
                schedule: decode_schedule(schedule)?,
                occurrences,
            },
        })
    }

    fn update(
        &self,
        schedule_id: &str,
        expected_revision: u64,
        patch: SchedulePatch,
        now: DateTime<Utc>,
    ) -> Result<ScheduleResponse, ScheduleError> {
        if patch == SchedulePatch::default() {
            return Err(ScheduleError::Invalid(
                "update patch must change at least one field".to_owned(),
            ));
        }
        let mut row = self.required_schedule_for_mutation(schedule_id, expected_revision)?;
        let SchedulePatch {
            name,
            target,
            authority,
            timing,
            policy,
        } = patch;
        if let Some(name) = name {
            validate_name(&name)?;
            row.name = name;
        }
        match (target, authority) {
            (Some(target), Some(authority)) => {
                validate_target(&target)?;
                validate_authority(&authority, &row.owner_agent_id)?;
                row.target_kind = target_kind(&target).to_owned();
                row.target_principal_agent_id =
                    target_principal_agent_id(&target).map(ToOwned::to_owned);
                row.target_json = serde_json::to_string(&target)?;
                row.authority_json = serde_json::to_string(&authority)?;
            }
            (None, None) => {}
            _ => {
                return Err(ScheduleError::Invalid(
                    "target and authority must be updated together".to_owned(),
                ));
            }
        }
        if let Some(policy) = policy {
            validate_policy(&policy)?;
            row.policy_json = serde_json::to_string(&policy)?;
        }
        if let Some(timing) = timing {
            let timing = validate_timing(&timing)?.timing;
            let expansion = expand_window(&timing, now, now)?;
            if expansion.next.is_none() {
                return Err(ScheduleError::Invalid(
                    "updated timing has no future occurrence".to_owned(),
                ));
            }
            row.timing_kind = timing_kind(&timing).to_owned();
            row.timing_json = serde_json::to_string(&timing)?;
            row.cursor_at = utc_string(now);
            row.next_due_at = expansion.next.map(utc_string);
        }
        row.revision = next_revision(row.revision)?;
        row.updated_at = utc_string(now);
        row.last_error = None;
        if !self
            .store
            .update_stored_schedule_cas(&row, expected_revision_i64(expected_revision)?)?
        {
            return self.revision_conflict(schedule_id, expected_revision);
        }
        Ok(ScheduleResponse::Update {
            schedule: decode_schedule(row)?,
        })
    }

    fn transition(
        &self,
        schedule_id: &str,
        expected_revision: u64,
        target_state: ScheduleState,
        now: DateTime<Utc>,
        action: &'static str,
    ) -> Result<ScheduleResponse, ScheduleError> {
        let mut row = self.required_schedule_for_mutation(schedule_id, expected_revision)?;
        let current = parse_schedule_state(&row.state)?;
        match (current, target_state) {
            (ScheduleState::Active, ScheduleState::Paused)
            | (ScheduleState::Paused, ScheduleState::Active)
            | (ScheduleState::Active | ScheduleState::Paused, ScheduleState::Deleted) => {}
            _ => {
                return Err(ScheduleError::Invalid(format!(
                    "cannot {action} schedule in {current:?} state"
                )));
            }
        }
        if target_state == ScheduleState::Active && row.next_due_at.is_none() {
            return Err(ScheduleError::Invalid(
                "exhausted schedule cannot be resumed".to_owned(),
            ));
        }
        row.state = schedule_state_string(target_state).to_owned();
        row.revision = next_revision(row.revision)?;
        row.updated_at = utc_string(now);
        row.deleted_at = (target_state == ScheduleState::Deleted).then(|| utc_string(now));
        if !self
            .store
            .update_stored_schedule_cas(&row, expected_revision_i64(expected_revision)?)?
        {
            return self.revision_conflict(schedule_id, expected_revision);
        }
        let schedule = decode_schedule(row)?;
        Ok(match target_state {
            ScheduleState::Paused => ScheduleResponse::Pause { schedule },
            ScheduleState::Active => ScheduleResponse::Resume { schedule },
            ScheduleState::Deleted => ScheduleResponse::Delete { schedule },
        })
    }

    fn run_now(
        &self,
        schedule_id: &str,
        idempotency_key: &str,
        now: DateTime<Utc>,
    ) -> Result<ScheduleResponse, ScheduleError> {
        validate_identifier("scheduleId", schedule_id)?;
        validate_identifier("idempotencyKey", idempotency_key)?;
        let schedule = self.required_schedule(schedule_id)?;
        if schedule.state == "deleted" {
            return Err(ScheduleError::Invalid(
                "deleted schedule cannot run".to_owned(),
            ));
        }
        let policy = decode_policy(&schedule.policy_json)?;
        let now_string = utc_string(now);
        let occurrence_key = manual_occurrence_key(schedule_id, idempotency_key);
        let occurrence = StoredScheduleOccurrence {
            occurrence_id: deterministic_occurrence_id(&occurrence_key),
            occurrence_key,
            schedule_id: schedule_id.to_owned(),
            schedule_revision: schedule.revision,
            kind: "manual".to_owned(),
            scheduled_for: now_string.clone(),
            state: "queued".to_owned(),
            target_json: schedule.target_json,
            authority_json: schedule.authority_json,
            missed_count: 0,
            window_start: None,
            window_end: None,
            skip_reason: None,
            agent_id: None,
            assignment_id: None,
            invocation_id: None,
            output_ref: None,
            failure: None,
            claim_owner: None,
            lease_expires_at: None,
            attempt: 0,
            created_at: now_string,
            started_at: None,
            finished_at: None,
        };
        let occurrence = self.store.create_manual_schedule_occurrence_idempotently(
            &occurrence,
            policy.overlap == OverlapPolicy::Skip,
        )?;
        Ok(ScheduleResponse::RunNow {
            occurrence: decode_occurrence(occurrence)?,
        })
    }

    /// Reconcile every currently due schedule in bounded next-due order.
    ///
    /// Expansion errors retain evidence but never advance the cursor. A later
    /// update can repair the rule; a transient crash simply retries the exact
    /// same deterministic occurrence keys.
    pub(crate) fn reconcile_due(
        &self,
        now: DateTime<Utc>,
    ) -> Result<ReconcileReport, ScheduleError> {
        let now_string = utc_string(now);
        let due = self
            .store
            .list_due_stored_schedules(&now_string, MAX_DUE_SCHEDULES_PER_RECONCILE)?;
        let mut report = ReconcileReport {
            schedules_considered: due.len(),
            ..ReconcileReport::default()
        };
        for schedule in due {
            let timing = decode_timing(&schedule.timing_json)?;
            let policy = decode_policy(&schedule.policy_json)?;
            let cursor = parse_utc(&schedule.cursor_at, "cursorAt")?;
            let expansion = match expand_window(&timing, cursor, now) {
                Ok(expansion) => expansion,
                Err(error) => {
                    let _ = self.store.record_schedule_reconciliation_error(
                        &schedule.schedule_id,
                        schedule.revision,
                        &schedule.cursor_at,
                        &error.to_string(),
                        &now_string,
                    )?;
                    report.failures += 1;
                    continue;
                }
            };
            let occurrences = occurrence_rows(&schedule, &policy, &expansion, now)?;
            let count = occurrences.len();
            let committed =
                self.store
                    .commit_schedule_reconciliation(&StoredScheduleReconciliation {
                        schedule_id: schedule.schedule_id.clone(),
                        expected_revision: schedule.revision,
                        expected_cursor_at: schedule.cursor_at.clone(),
                        cursor_at: now_string.clone(),
                        next_due_at: expansion.next.map(utc_string),
                        admitted_at: now_string.clone(),
                        skip_on_overlap: policy.overlap == OverlapPolicy::Skip,
                        occurrences,
                    })?;
            if committed {
                report.occurrences_recorded += count;
            } else {
                report.races += 1;
            }
        }
        Ok(report)
    }

    /// Claim the global earliest queued occurrence with a durable lease.
    pub(crate) fn claim_next(
        &self,
        claim_owner: &str,
        now: DateTime<Utc>,
        lease_duration: Duration,
    ) -> Result<Option<ScheduleOccurrence>, ScheduleError> {
        validate_identifier("claimOwner", claim_owner)?;
        self.store
            .claim_next_schedule_occurrence(claim_owner, now, lease_duration)?
            .map(decode_occurrence)
            .transpose()
    }

    /// Bind the durable assignment created for a claimed occurrence.
    pub(crate) fn bind_agent_assignment(
        &self,
        occurrence_id: &str,
        claim_owner: &str,
        agent_id: &str,
        assignment_id: &str,
    ) -> Result<bool, ScheduleError> {
        for (field, value) in [
            ("occurrenceId", occurrence_id),
            ("claimOwner", claim_owner),
            ("agentId", agent_id),
            ("assignmentId", assignment_id),
        ] {
            validate_identifier(field, value)?;
        }
        Ok(self.store.bind_schedule_occurrence_agent_assignment(
            occurrence_id,
            claim_owner,
            agent_id,
            assignment_id,
        )?)
    }

    /// Bind the namespaced registry invocation created for a capability target.
    pub(crate) fn bind_capability_invocation(
        &self,
        occurrence_id: &str,
        claim_owner: &str,
        invocation_id: &str,
    ) -> Result<bool, ScheduleError> {
        for (field, value) in [
            ("occurrenceId", occurrence_id),
            ("claimOwner", claim_owner),
            ("invocationId", invocation_id),
        ] {
            validate_identifier(field, value)?;
        }
        Ok(self.store.bind_schedule_occurrence_capability_invocation(
            occurrence_id,
            claim_owner,
            invocation_id,
        )?)
    }

    /// Renew a claimed occurrence lease.
    pub(crate) fn renew_lease(
        &self,
        occurrence_id: &str,
        claim_owner: &str,
        lease_expires_at: DateTime<Utc>,
    ) -> Result<bool, ScheduleError> {
        Ok(self.store.renew_schedule_occurrence_lease(
            occurrence_id,
            claim_owner,
            &utc_string(lease_expires_at),
        )?)
    }

    /// Commit terminal execution evidence for one claimed occurrence.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn terminalize(
        &self,
        occurrence_id: &str,
        claim_owner: &str,
        succeeded: bool,
        output_ref: Option<&str>,
        failure: Option<&str>,
        finished_at: DateTime<Utc>,
    ) -> Result<bool, ScheduleError> {
        Ok(self.store.terminalize_schedule_occurrence(
            occurrence_id,
            claim_owner,
            succeeded,
            output_ref,
            failure,
            &utc_string(finished_at),
        )?)
    }

    fn required_schedule(&self, schedule_id: &str) -> Result<StoredSchedule, ScheduleError> {
        self.store
            .get_stored_schedule(schedule_id)?
            .ok_or_else(|| ScheduleError::NotFound(schedule_id.to_owned()))
    }

    fn required_schedule_for_mutation(
        &self,
        schedule_id: &str,
        expected_revision: u64,
    ) -> Result<StoredSchedule, ScheduleError> {
        validate_identifier("scheduleId", schedule_id)?;
        let schedule = self.required_schedule(schedule_id)?;
        let current = revision_u64(schedule.revision)?;
        if current != expected_revision {
            return Err(ScheduleError::RevisionConflict {
                expected: expected_revision,
                current,
            });
        }
        if schedule.state == "deleted" {
            return Err(ScheduleError::Invalid(
                "deleted schedule is immutable".to_owned(),
            ));
        }
        Ok(schedule)
    }

    fn revision_conflict<T>(&self, schedule_id: &str, expected: u64) -> Result<T, ScheduleError> {
        let current = self
            .required_schedule(schedule_id)
            .and_then(|row| revision_u64(row.revision))?;
        Err(ScheduleError::RevisionConflict { expected, current })
    }
}

fn occurrence_rows(
    schedule: &StoredSchedule,
    policy: &SchedulePolicy,
    expansion: &Expansion,
    now: DateTime<Utc>,
) -> Result<Vec<StoredScheduleOccurrence>, ScheduleError> {
    let cutoff = now - Duration::seconds(MISFIRE_GRACE_SECONDS);
    let split = expansion.due.partition_point(|date| *date < cutoff);
    let missed = &expansion.due[..split];
    let on_time = &expansion.due[split..];
    let mut queued = Vec::new();
    let mut summary = None;
    match policy.misfire {
        MisfirePolicy::Skip => {
            summary = summary_for(schedule, missed, "misfire_skip", now)?;
        }
        MisfirePolicy::RunOnce => {
            if let Some((latest, older)) = missed.split_last() {
                summary = summary_for(schedule, older, "misfire_run_once", now)?;
                queued.push(*latest);
            }
        }
        MisfirePolicy::CatchUp => {
            let keep = usize::from(policy.max_catch_up.min(MAX_CATCH_UP));
            let skipped = missed.len().saturating_sub(keep);
            summary = summary_for(schedule, &missed[..skipped], "misfire_catch_up_bound", now)?;
            queued.extend_from_slice(&missed[skipped..]);
        }
    }
    queued.extend_from_slice(on_time);
    let mut rows = Vec::with_capacity(queued.len() + usize::from(summary.is_some()));
    if let Some(summary) = summary {
        rows.push(summary);
    }
    rows.extend(
        queued
            .into_iter()
            .map(|at| scheduled_occurrence(schedule, at, now))
            .collect::<Result<Vec<_>, _>>()?,
    );
    Ok(rows)
}

fn scheduled_occurrence(
    schedule: &StoredSchedule,
    at: DateTime<Utc>,
    now: DateTime<Utc>,
) -> Result<StoredScheduleOccurrence, ScheduleError> {
    let scheduled_for = utc_string(at);
    let occurrence_key = scheduled_occurrence_key(&schedule.schedule_id, &scheduled_for);
    Ok(StoredScheduleOccurrence {
        occurrence_id: deterministic_occurrence_id(&occurrence_key),
        occurrence_key,
        schedule_id: schedule.schedule_id.clone(),
        schedule_revision: schedule.revision,
        kind: "scheduled".to_owned(),
        scheduled_for,
        state: "queued".to_owned(),
        target_json: schedule.target_json.clone(),
        authority_json: schedule.authority_json.clone(),
        missed_count: 0,
        window_start: None,
        window_end: None,
        skip_reason: None,
        agent_id: None,
        assignment_id: None,
        invocation_id: None,
        output_ref: None,
        failure: None,
        claim_owner: None,
        lease_expires_at: None,
        attempt: 0,
        created_at: utc_string(now),
        started_at: None,
        finished_at: None,
    })
}

fn summary_for(
    schedule: &StoredSchedule,
    missed: &[DateTime<Utc>],
    reason: &str,
    now: DateTime<Utc>,
) -> Result<Option<StoredScheduleOccurrence>, ScheduleError> {
    let (Some(first), Some(last)) = (missed.first(), missed.last()) else {
        return Ok(None);
    };
    let window_start = utc_string(*first);
    let window_end = utc_string(*last);
    let occurrence_key =
        summary_occurrence_key(&schedule.schedule_id, &window_start, &window_end, reason);
    Ok(Some(StoredScheduleOccurrence {
        occurrence_id: deterministic_occurrence_id(&occurrence_key),
        occurrence_key,
        schedule_id: schedule.schedule_id.clone(),
        schedule_revision: schedule.revision,
        kind: "misfire_summary".to_owned(),
        scheduled_for: window_end.clone(),
        state: "skipped".to_owned(),
        target_json: schedule.target_json.clone(),
        authority_json: schedule.authority_json.clone(),
        missed_count: i64::try_from(missed.len())
            .map_err(|_| ScheduleError::Invalid("misfire count overflow".to_owned()))?,
        window_start: Some(window_start),
        window_end: Some(window_end),
        skip_reason: Some(reason.to_owned()),
        agent_id: None,
        assignment_id: None,
        invocation_id: None,
        output_ref: None,
        failure: None,
        claim_owner: None,
        lease_expires_at: None,
        attempt: 0,
        created_at: utc_string(now),
        started_at: None,
        finished_at: Some(utc_string(now)),
    }))
}

fn decode_schedule(row: StoredSchedule) -> Result<ScheduleRecord, ScheduleError> {
    Ok(ScheduleRecord {
        schedule_id: row.schedule_id,
        owner_agent_id: row.owner_agent_id,
        name: row.name,
        target: serde_json::from_str(&row.target_json)?,
        authority: serde_json::from_str(&row.authority_json)?,
        timing: decode_timing(&row.timing_json)?,
        policy: decode_policy(&row.policy_json)?,
        state: parse_schedule_state(&row.state)?,
        revision: revision_u64(row.revision)?,
        cursor_at: row.cursor_at,
        next_due_at: row.next_due_at,
        last_error: row.last_error,
        created_at: row.created_at,
        updated_at: row.updated_at,
        deleted_at: row.deleted_at,
    })
}

fn decode_occurrence(row: StoredScheduleOccurrence) -> Result<ScheduleOccurrence, ScheduleError> {
    Ok(ScheduleOccurrence {
        occurrence_id: row.occurrence_id,
        occurrence_key: row.occurrence_key,
        schedule_id: row.schedule_id,
        schedule_revision: revision_u64(row.schedule_revision)?,
        kind: match row.kind.as_str() {
            "scheduled" => OccurrenceKind::Scheduled,
            "manual" => OccurrenceKind::Manual,
            "misfire_summary" => OccurrenceKind::MisfireSummary,
            value => return Err(corrupt(format!("unknown occurrence kind {value}"))),
        },
        scheduled_for: row.scheduled_for,
        state: match row.state.as_str() {
            "queued" => OccurrenceState::Queued,
            "running" => OccurrenceState::Running,
            "completed" => OccurrenceState::Completed,
            "failed" => OccurrenceState::Failed,
            "skipped" => OccurrenceState::Skipped,
            "cancelled" => OccurrenceState::Cancelled,
            value => return Err(corrupt(format!("unknown occurrence state {value}"))),
        },
        target: serde_json::from_str(&row.target_json)?,
        authority: serde_json::from_str(&row.authority_json)?,
        missed_count: u64::try_from(row.missed_count)
            .map_err(|_| corrupt("negative occurrence missed count".to_owned()))?,
        window_start: row.window_start,
        window_end: row.window_end,
        skip_reason: row.skip_reason,
        agent_id: row.agent_id,
        assignment_id: row.assignment_id,
        invocation_id: row.invocation_id,
        output_ref: row.output_ref,
        failure: row.failure,
        created_at: row.created_at,
        started_at: row.started_at,
        finished_at: row.finished_at,
    })
}

fn decode_timing(value: &str) -> Result<ScheduleTiming, ScheduleError> {
    Ok(serde_json::from_str(value)?)
}

fn decode_policy(value: &str) -> Result<SchedulePolicy, ScheduleError> {
    Ok(serde_json::from_str(value)?)
}

fn validate_name(name: &str) -> Result<(), ScheduleError> {
    if name.trim().is_empty() || name.len() > MAX_NAME_BYTES {
        return Err(ScheduleError::Invalid(format!(
            "name must contain 1..={MAX_NAME_BYTES} bytes"
        )));
    }
    Ok(())
}

fn validate_assignment(
    assignment: &super::contract::ScheduledAssignment,
) -> Result<(), ScheduleError> {
    let task = &assignment.task;
    if task.trim().is_empty() || task.len() > MAX_TASK_BYTES {
        return Err(ScheduleError::Invalid(format!(
            "task must contain 1..={MAX_TASK_BYTES} bytes"
        )));
    }
    validate_json("assignment.context", &assignment.context)
}

fn validate_authority(
    authority: &ScheduleAuthoritySnapshot,
    owner_agent_id: &str,
) -> Result<(), ScheduleError> {
    validate_identifier("authority.principalAgentId", &authority.principal_agent_id)?;
    if authority.principal_agent_id != owner_agent_id {
        return Err(ScheduleError::Invalid(
            "authority principal must equal the schedule owner".to_owned(),
        ));
    }
    if !authority.grant.is_object() {
        return Err(ScheduleError::Invalid(
            "authority.grant must be an Engine-authored object snapshot".to_owned(),
        ));
    }
    validate_json("authority.grant", &authority.grant)
}

fn validate_json(field: &str, value: &serde_json::Value) -> Result<(), ScheduleError> {
    const MAX_JSON_BYTES: usize = 65_536;
    const MAX_JSON_DEPTH: usize = 32;
    let bytes = serde_json::to_vec(value)?;
    if bytes.len() > MAX_JSON_BYTES {
        return Err(ScheduleError::Invalid(format!(
            "{field} exceeds {MAX_JSON_BYTES} bytes"
        )));
    }
    fn depth(value: &serde_json::Value, current: usize) -> usize {
        match value {
            serde_json::Value::Array(values) => values
                .iter()
                .map(|value| depth(value, current + 1))
                .max()
                .unwrap_or(current + 1),
            serde_json::Value::Object(values) => values
                .values()
                .map(|value| depth(value, current + 1))
                .max()
                .unwrap_or(current + 1),
            _ => current,
        }
    }
    if depth(value, 0) > MAX_JSON_DEPTH {
        return Err(ScheduleError::Invalid(format!(
            "{field} exceeds nesting depth {MAX_JSON_DEPTH}"
        )));
    }
    Ok(())
}

fn validate_target(target: &ScheduleTarget) -> Result<(), ScheduleError> {
    match target {
        ScheduleTarget::ReusableAgent {
            agent_id,
            assignment,
        } => {
            validate_identifier("agentId", agent_id)?;
            validate_assignment(assignment)
        }
        ScheduleTarget::FreshAgent {
            parent_agent_id,
            name,
            defaults,
            assignment,
        } => {
            validate_identifier("parentAgentId", parent_agent_id)?;
            if let Some(name) = name {
                validate_name(name)?;
            }
            if let Some(defaults) = defaults {
                if let Some(model) = defaults.model.as_deref() {
                    validate_identifier("freshAgent.defaults.model", model)?;
                }
                if let Some(reasoning_level) = defaults.reasoning_level.as_deref() {
                    validate_identifier("freshAgent.defaults.reasoningLevel", reasoning_level)?;
                }
            }
            validate_assignment(assignment)
        }
        ScheduleTarget::Capability {
            capability_id,
            capability_version,
            input,
        } => {
            validate_capability_id(capability_id)?;
            if let Some(version) = capability_version {
                validate_identifier("capabilityVersion", version)?;
            }
            validate_json("capability.input", input)
        }
    }
}

fn validate_capability_id(value: &str) -> Result<(), ScheduleError> {
    validate_identifier("capabilityId", value)?;
    let namespaced = value
        .split_once(':')
        .or_else(|| value.split_once('/'))
        .is_some_and(|(namespace, entrypoint)| {
            !namespace.is_empty() && !entrypoint.is_empty() && !value.contains("..")
        });
    let safe = value.bytes().all(|byte| {
        byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-' | b':' | b'/' | b'@')
    });
    if namespaced && safe {
        Ok(())
    } else {
        Err(ScheduleError::Invalid(
            "capabilityId must be a safe namespaced registry/package entrypoint".to_owned(),
        ))
    }
}

fn validate_identifier(field: &str, value: &str) -> Result<(), ScheduleError> {
    if value.trim().is_empty()
        || value.len() > MAX_IDENTIFIER_BYTES
        || value.contains(['\r', '\n', '\0'])
    {
        Err(ScheduleError::Invalid(format!(
            "{field} must contain 1..={MAX_IDENTIFIER_BYTES} safe bytes"
        )))
    } else {
        Ok(())
    }
}

fn target_kind(target: &ScheduleTarget) -> &'static str {
    match target {
        ScheduleTarget::ReusableAgent { .. } => "reusable_agent",
        ScheduleTarget::FreshAgent { .. } => "fresh_agent",
        ScheduleTarget::Capability { .. } => "capability",
    }
}

fn target_principal_agent_id(target: &ScheduleTarget) -> Option<&str> {
    match target {
        ScheduleTarget::ReusableAgent { agent_id, .. } => Some(agent_id),
        ScheduleTarget::FreshAgent {
            parent_agent_id, ..
        } => Some(parent_agent_id),
        ScheduleTarget::Capability { .. } => None,
    }
}

fn timing_kind(timing: &ScheduleTiming) -> &'static str {
    match timing {
        ScheduleTiming::Once { .. } => "once",
        ScheduleTiming::Recurring { .. } => "recurring",
    }
}

fn schedule_state_string(state: ScheduleState) -> &'static str {
    match state {
        ScheduleState::Active => "active",
        ScheduleState::Paused => "paused",
        ScheduleState::Deleted => "deleted",
    }
}

fn parse_schedule_state(value: &str) -> Result<ScheduleState, ScheduleError> {
    match value {
        "active" => Ok(ScheduleState::Active),
        "paused" => Ok(ScheduleState::Paused),
        "deleted" => Ok(ScheduleState::Deleted),
        value => Err(corrupt(format!("unknown schedule state {value}"))),
    }
}

fn parse_utc(value: &str, field: &str) -> Result<DateTime<Utc>, ScheduleError> {
    DateTime::parse_from_rfc3339(value)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|error| corrupt(format!("invalid stored {field}: {error}")))
}

fn next_revision(value: i64) -> Result<i64, ScheduleError> {
    value
        .checked_add(1)
        .filter(|value| *value > 1)
        .ok_or_else(|| ScheduleError::Invalid("schedule revision exhausted".to_owned()))
}

fn revision_u64(value: i64) -> Result<u64, ScheduleError> {
    u64::try_from(value).map_err(|_| corrupt("negative schedule revision".to_owned()))
}

fn expected_revision_i64(value: u64) -> Result<i64, ScheduleError> {
    i64::try_from(value)
        .map_err(|_| ScheduleError::Invalid("expectedRevision exceeds storage range".to_owned()))
}

fn digest_json(value: &serde_json::Value) -> Result<String, ScheduleError> {
    let encoded = serde_json::to_vec(value)?;
    Ok(format!("sha256:{:x}", Sha256::digest(encoded)))
}

fn scheduled_occurrence_key(schedule_id: &str, scheduled_for: &str) -> String {
    digest_key(&format!("scheduled\0{schedule_id}\0{scheduled_for}"))
}

fn manual_occurrence_key(schedule_id: &str, idempotency_key: &str) -> String {
    digest_key(&format!("manual\0{schedule_id}\0{idempotency_key}"))
}

fn summary_occurrence_key(
    schedule_id: &str,
    window_start: &str,
    window_end: &str,
    reason: &str,
) -> String {
    digest_key(&format!(
        "misfire\0{schedule_id}\0{window_start}\0{window_end}\0{reason}"
    ))
}

fn digest_key(material: &str) -> String {
    format!(
        "schedule_occurrence:{:x}",
        Sha256::digest(material.as_bytes())
    )
}

fn deterministic_occurrence_id(key: &str) -> String {
    format!("occurrence_{:x}", Sha256::digest(key.as_bytes()))
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct ScheduleCursor {
    created_at: String,
    schedule_id: String,
}

fn encode_cursor(cursor: &ScheduleCursor) -> Result<String, ScheduleError> {
    Ok(base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(serde_json::to_vec(cursor)?))
}

fn decode_cursor(value: &str) -> Result<ScheduleCursor, ScheduleError> {
    let decoded = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| ScheduleError::Invalid("invalid schedule cursor".to_owned()))?;
    let cursor: ScheduleCursor = serde_json::from_slice(&decoded)
        .map_err(|_| ScheduleError::Invalid("invalid schedule cursor".to_owned()))?;
    parse_utc(&cursor.created_at, "schedule cursor")?;
    validate_identifier("schedule cursor id", &cursor.schedule_id)?;
    Ok(cursor)
}

fn corrupt(message: String) -> ScheduleError {
    ScheduleError::Store(EventStoreError::Internal(format!(
        "corrupt schedule storage: {message}"
    )))
}

impl From<serde_json::Error> for ScheduleError {
    fn from(error: serde_json::Error) -> Self {
        Self::Store(EventStoreError::Serde(error))
    }
}
