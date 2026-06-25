use chrono::{DateTime, Duration, Utc};

use crate::shared::server::errors::CapabilityError;

use super::errors::invalid_params;
use super::support::MAX_CATCH_UP_RUNS;
use super::types::{MissedRunMode, ScheduleRecord, ScheduleState, TriggerKind};

pub(super) struct DuePlan {
    pub(super) runs: Vec<DateTime<Utc>>,
    pub(super) skipped: Option<SkippedPlan>,
    pub(super) next_fire_at: Option<DateTime<Utc>>,
}

pub(super) struct SkippedPlan {
    pub(super) scheduled_for: DateTime<Utc>,
    pub(super) skipped_count: u32,
}

pub(super) fn due_plan(
    record: &ScheduleRecord,
    now: DateTime<Utc>,
) -> Result<DuePlan, CapabilityError> {
    let Some(first_due) = record.next_fire_at else {
        return Ok(DuePlan {
            runs: Vec::new(),
            skipped: None,
            next_fire_at: None,
        });
    };
    if first_due > now {
        return Ok(DuePlan {
            runs: Vec::new(),
            skipped: None,
            next_fire_at: Some(first_due),
        });
    }
    let occurrences = due_occurrences(record, now)?;
    let occurrence_count = due_count(record, first_due, now)?;
    let next_fire_at = next_after(record, now)?;
    let plan = match record.missed_run_policy.mode {
        MissedRunMode::Skip => DuePlan {
            runs: Vec::new(),
            skipped: Some(SkippedPlan {
                scheduled_for: first_due,
                skipped_count: occurrence_count,
            }),
            next_fire_at,
        },
        MissedRunMode::FireOnce => DuePlan {
            runs: latest_due(record, first_due, now)?.into_iter().collect(),
            skipped: None,
            next_fire_at,
        },
        MissedRunMode::CatchUp => {
            let max = record.missed_run_policy.max_catch_up_runs as usize;
            let runs = occurrences.iter().copied().take(max).collect::<Vec<_>>();
            let skipped = (occurrences.len() > runs.len()).then(|| SkippedPlan {
                scheduled_for: occurrences[runs.len()],
                skipped_count: occurrence_count.saturating_sub(runs.len() as u32),
            });
            DuePlan {
                runs,
                skipped,
                next_fire_at,
            }
        }
    };
    Ok(plan)
}

fn due_occurrences(
    record: &ScheduleRecord,
    now: DateTime<Utc>,
) -> Result<Vec<DateTime<Utc>>, CapabilityError> {
    let Some(mut current) = record.next_fire_at else {
        return Ok(Vec::new());
    };
    let mut out = Vec::new();
    let cap = match record.missed_run_policy.mode {
        MissedRunMode::CatchUp => record.missed_run_policy.max_catch_up_runs.saturating_add(1),
        _ => 1_000,
    }
    .min(MAX_CATCH_UP_RUNS.saturating_add(1));
    while current <= now && out.len() < cap as usize {
        out.push(current);
        let Some(next) = next_occurrence(record, current)? else {
            break;
        };
        current = next;
    }
    Ok(out)
}

fn due_count(
    record: &ScheduleRecord,
    first_due: DateTime<Utc>,
    now: DateTime<Utc>,
) -> Result<u32, CapabilityError> {
    if first_due > now {
        return Ok(0);
    }
    match record.trigger.kind {
        TriggerKind::Once => Ok(1),
        TriggerKind::Interval => {
            let seconds = record
                .trigger
                .interval_seconds
                .ok_or_else(|| invalid_params("interval schedule is missing intervalSeconds"))?;
            let elapsed = now.signed_duration_since(first_due).num_seconds().max(0) as u64;
            Ok(elapsed
                .saturating_div(seconds)
                .saturating_add(1)
                .min(u32::MAX as u64) as u32)
        }
    }
}

fn latest_due(
    record: &ScheduleRecord,
    first_due: DateTime<Utc>,
    now: DateTime<Utc>,
) -> Result<Option<DateTime<Utc>>, CapabilityError> {
    if first_due > now {
        return Ok(None);
    }
    match record.trigger.kind {
        TriggerKind::Once => Ok(Some(first_due)),
        TriggerKind::Interval => {
            let seconds = record
                .trigger
                .interval_seconds
                .ok_or_else(|| invalid_params("interval schedule is missing intervalSeconds"))?;
            let elapsed = now.signed_duration_since(first_due).num_seconds().max(0);
            let steps = elapsed / seconds as i64;
            Ok(Some(
                first_due + Duration::seconds((seconds as i64) * steps),
            ))
        }
    }
}

fn next_after(
    record: &ScheduleRecord,
    now: DateTime<Utc>,
) -> Result<Option<DateTime<Utc>>, CapabilityError> {
    let Some(mut current) = record.next_fire_at else {
        return Ok(None);
    };
    if current > now {
        return Ok(Some(current));
    }
    if record.trigger.kind == TriggerKind::Interval {
        let seconds = record
            .trigger
            .interval_seconds
            .ok_or_else(|| invalid_params("interval schedule is missing intervalSeconds"))?;
        let elapsed = now.signed_duration_since(current).num_seconds().max(0);
        let steps = elapsed / seconds as i64 + 1;
        return Ok(Some(current + Duration::seconds((seconds as i64) * steps)));
    }
    while current <= now {
        let Some(next) = next_occurrence(record, current)? else {
            return Ok(None);
        };
        current = next;
    }
    Ok(Some(current))
}

fn next_occurrence(
    record: &ScheduleRecord,
    current: DateTime<Utc>,
) -> Result<Option<DateTime<Utc>>, CapabilityError> {
    match record.trigger.kind {
        TriggerKind::Once => Ok(None),
        TriggerKind::Interval => {
            let seconds = record
                .trigger
                .interval_seconds
                .ok_or_else(|| invalid_params("interval schedule is missing intervalSeconds"))?;
            Ok(Some(current + Duration::seconds(seconds as i64)))
        }
    }
}

pub(super) fn is_due(record: &ScheduleRecord, now: DateTime<Utc>) -> bool {
    record.state == ScheduleState::Active
        && record
            .next_fire_at
            .is_some_and(|next_fire_at| next_fire_at <= now)
}
