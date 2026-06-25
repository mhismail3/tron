use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use crate::engine::{
    AcquireResourceLease, CreateResource, EngineHostHandle, EngineResourceInspection,
    LinkResources, ListResources, UpdateResource, WorkerId,
};
use crate::shared::server::errors::CapabilityError;

use super::errors::{engine_error, invalid_params};
use super::planning::{due_plan, is_due};
use super::projection::{
    list_run_summaries, run_summary_from_parts, schedule_detail, schedule_summary,
};
use super::support::*;
use super::types::{
    CancellationRecord, MissedRunPolicyRecord, SCHEDULE_RUN_SCHEMA_VERSION,
    SCHEDULE_SCHEMA_VERSION, ScheduleRecord, ScheduleRunRecord, ScheduleRunState, ScheduleState,
    TimezonePolicyRecord, TriggerKind, TriggerRecord,
};
use super::{
    FIRE_SCOPE, SCHEDULE_KIND, SCHEDULE_RUN_KIND, SCHEDULE_RUN_SCHEMA_ID, SCHEDULE_SCHEMA_ID,
    WORKER, WRITE_SCOPE,
};

const SCHEDULE_LEASE_TTL_MS: i64 = 60_000;
const FIRE_BATCH_LIMIT: usize = 50;
const FIRE_CANDIDATE_LIMIT: usize = 100;
const PRODUCED_RUN_RELATION: &str = "produced_run";

pub(crate) trait Clock {
    fn now(&self) -> DateTime<Utc>;
}

#[derive(Clone, Copy, Debug)]
struct EvaluationClock {
    now: DateTime<Utc>,
}

impl Clock for EvaluationClock {
    fn now(&self) -> DateTime<Utc> {
        self.now
    }
}

pub(crate) async fn create_schedule_value(
    engine_host: &EngineHostHandle,
    invocation: &crate::engine::Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    require_scope(invocation, WRITE_SCOPE)?;
    let title = bounded_text(
        "title",
        &required_string(payload, "title")?,
        TITLE_MAX_CHARS,
    )?;
    let schedule_kind = parse_schedule_kind(optional_string(payload, "scheduleKind")?)?;
    let trigger_kind = parse_trigger_kind(optional_string(payload, "triggerType")?)?;
    let start_at = parse_datetime(&required_string(payload, "startAt")?)?;
    let now = optional_datetime(payload, "createdAt")?.unwrap_or(start_at);
    let interval_seconds = match trigger_kind {
        TriggerKind::Once => None,
        TriggerKind::Interval => {
            let value = optional_u64(payload, "intervalSeconds")?.ok_or_else(|| {
                invalid_params("intervalSeconds is required for interval schedules")
            })?;
            if !(MIN_INTERVAL_SECONDS..=MAX_INTERVAL_SECONDS).contains(&value) {
                return Err(invalid_params(format!(
                    "intervalSeconds must be between {MIN_INTERVAL_SECONDS} and {MAX_INTERVAL_SECONDS}"
                )));
            }
            Some(value)
        }
    };
    let timezone = optional_string(payload, "timezone")?.unwrap_or_else(|| "UTC".to_owned());
    let timezone = bounded_text("timezone", &timezone, 64)?;
    let missed_run_policy = MissedRunPolicyRecord {
        mode: parse_missed_run_mode(optional_string(payload, "missedRunPolicy")?)?,
        max_catch_up_runs: optional_u64(payload, "maxCatchUpRuns")?
            .map(|value| value as u32)
            .unwrap_or(DEFAULT_MAX_CATCH_UP_RUNS)
            .clamp(1, MAX_CATCH_UP_RUNS),
    };
    let target = parse_target(
        optional_object(payload, "target")?.ok_or_else(|| invalid_params("target is required"))?,
    )?;
    let retention = retention(payload)?;
    let record = ScheduleRecord {
        schema_version: SCHEDULE_SCHEMA_VERSION.to_owned(),
        state: ScheduleState::Active,
        title,
        schedule_kind,
        trigger: TriggerRecord {
            kind: trigger_kind,
            start_at,
            interval_seconds,
        },
        timezone_policy: TimezonePolicyRecord {
            timezone,
            resolution: "utc_instant".to_owned(),
            dst_policy: "preserve_instant".to_owned(),
        },
        missed_run_policy,
        target,
        authority: authority_record(invocation),
        retention,
        created_at: now,
        updated_at: now,
        next_fire_at: Some(start_at),
        last_evaluated_at: None,
        last_run_at: None,
        cancellation: None,
        trace_refs: trace_refs(invocation),
        replay_refs: replay_refs(invocation),
        revision: 1,
    };
    let resource = engine_host
        .create_resource(CreateResource {
            resource_id: Some(format!("{SCHEDULE_KIND}:{}", invocation.id.as_str())),
            kind: SCHEDULE_KIND.to_owned(),
            schema_id: Some(SCHEDULE_SCHEMA_ID.to_owned()),
            scope: resource_scope(invocation)?,
            owner_worker_id: WorkerId::new(WORKER).map_err(engine_error)?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(ScheduleState::Active.as_str().to_owned()),
            policy: resource_policy("schedule"),
            initial_payload: Some(to_value(&record, "schedule")?),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let cursor = publish_lifecycle_event(
        engine_host,
        invocation,
        "schedule.created",
        json!({
            "scheduleResourceId": resource.resource_id,
            "scheduleVersionId": resource.current_version_id,
            "state": ScheduleState::Active.as_str(),
            "nextFireAt": record.next_fire_at,
            "resourceRefs": [resource_ref(&resource, "schedule")]
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": SCHEDULE_SCHEMA_VERSION,
        "status": ScheduleState::Active.as_str(),
        "scheduleResourceId": resource.resource_id,
        "scheduleVersionId": resource.current_version_id,
        "nextFireAt": record.next_fire_at,
        "streamCursor": cursor.0,
        "resourceRefs": [resource_ref(&resource, "schedule")]
    }))
}

pub(crate) async fn list_schedules_value(
    engine_host: &EngineHostHandle,
    invocation: &crate::engine::Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    require_read_scope(invocation)?;
    let limit = list_limit(payload)?;
    let requested = limit.saturating_add(1);
    let resources = engine_host
        .list_resources(ListResources {
            kind: Some(SCHEDULE_KIND.to_owned()),
            scope: Some(resource_scope(invocation)?),
            lifecycle: optional_string(payload, "state")?,
            limit: requested,
        })
        .await
        .map_err(engine_error)?;
    let truncated = resources.len() > limit;
    let mut schedules = Vec::new();
    for resource in resources.into_iter().take(limit) {
        let inspection = engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
            .ok_or_else(|| invalid_params("listed schedule disappeared before inspection"))?;
        let (_, record) = schedule_record(&inspection)?;
        schedules.push(schedule_summary(&inspection, &record));
    }
    Ok(json!({
        "schemaVersion": SCHEDULE_SCHEMA_VERSION,
        "status": "ok",
        "schedules": schedules,
        "truncated": truncated,
        "limit": limit
    }))
}

pub(crate) async fn inspect_schedule_value(
    engine_host: &EngineHostHandle,
    invocation: &crate::engine::Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    require_read_scope(invocation)?;
    let inspection = require_schedule(engine_host, invocation, payload).await?;
    let (version_id, record) = schedule_record(&inspection)?;
    let run_limit = list_limit(payload)?.min(25);
    let runs = list_run_summaries(engine_host, &inspection.resource.resource_id, run_limit).await?;
    Ok(json!({
        "schemaVersion": SCHEDULE_SCHEMA_VERSION,
        "status": record.state.as_str(),
        "schedule": schedule_detail(&inspection, &version_id, &record),
        "runs": runs,
        "runLimit": run_limit,
        "resourceRefs": [resource_ref(&inspection.resource, "schedule")]
    }))
}

pub(crate) async fn cancel_schedule_value(
    engine_host: &EngineHostHandle,
    invocation: &crate::engine::Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    require_scope(invocation, WRITE_SCOPE)?;
    let mut inspection = require_schedule(engine_host, invocation, payload).await?;
    let (current_version_id, mut record) = schedule_record(&inspection)?;
    if record.state == ScheduleState::Cancelled {
        return Ok(json!({
            "schemaVersion": SCHEDULE_SCHEMA_VERSION,
            "status": "already_cancelled",
            "scheduleResourceId": inspection.resource.resource_id,
            "scheduleVersionId": current_version_id,
            "idempotent": true,
            "resourceRefs": [resource_ref(&inspection.resource, "schedule")]
        }));
    }
    if record.state.is_terminal() {
        return Err(invalid_params("schedule is already terminal"));
    }
    let now = optional_datetime(payload, "cancelledAt")?.unwrap_or(record.updated_at);
    let reason = bounded_text(
        "reason",
        &required_string(payload, "reason")?,
        REASON_MAX_CHARS,
    )?;
    record.state = ScheduleState::Cancelled;
    record.updated_at = now;
    record.next_fire_at = None;
    record.cancellation = Some(CancellationRecord {
        reason,
        cancelled_at: now,
        actor_id: invocation.causal_context.actor_id.as_str().to_owned(),
        idempotency: idempotency(invocation),
    });
    record.revision = record.revision.saturating_add(1);
    let version = engine_host
        .update_resource(UpdateResource {
            resource_id: inspection.resource.resource_id.clone(),
            expected_current_version_id: Some(current_version_id),
            lifecycle: Some(ScheduleState::Cancelled.as_str().to_owned()),
            payload: to_value(&record, "schedule cancellation")?,
            state: None,
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    inspection.resource.lifecycle = ScheduleState::Cancelled.as_str().to_owned();
    inspection.resource.current_version_id = Some(version.version_id.clone());
    let cursor = publish_lifecycle_event(
        engine_host,
        invocation,
        "schedule.cancelled",
        json!({
            "scheduleResourceId": inspection.resource.resource_id,
            "scheduleVersionId": version.version_id,
            "state": ScheduleState::Cancelled.as_str(),
            "resourceRefs": [version_ref(&inspection.resource, &version, "schedule")]
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": SCHEDULE_SCHEMA_VERSION,
        "status": ScheduleState::Cancelled.as_str(),
        "scheduleResourceId": inspection.resource.resource_id,
        "scheduleVersionId": version.version_id,
        "streamCursor": cursor.0,
        "idempotent": false,
        "resourceRefs": [version_ref(&inspection.resource, &version, "schedule")]
    }))
}

pub(crate) async fn fire_due_schedules_value(
    engine_host: &EngineHostHandle,
    invocation: &crate::engine::Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let evaluation_at = parse_datetime(&required_string(payload, "evaluationAt")?)?;
    fire_due_schedules_with_clock(
        engine_host,
        invocation,
        payload,
        &EvaluationClock { now: evaluation_at },
    )
    .await
}

pub(crate) async fn fire_due_schedules_with_clock<C: Clock>(
    engine_host: &EngineHostHandle,
    invocation: &crate::engine::Invocation,
    payload: &Value,
    clock: &C,
) -> Result<Value, CapabilityError> {
    require_scope(invocation, FIRE_SCOPE)?;
    require_scope(invocation, WRITE_SCOPE)?;
    let now = clock.now();
    let limit = list_limit(payload)?.min(FIRE_BATCH_LIMIT);
    let resources = engine_host
        .list_resources(ListResources {
            kind: Some(SCHEDULE_KIND.to_owned()),
            scope: Some(resource_scope(invocation)?),
            lifecycle: Some(ScheduleState::Active.as_str().to_owned()),
            limit: FIRE_CANDIDATE_LIMIT,
        })
        .await
        .map_err(engine_error)?;
    let candidate_count = resources.len();
    let mut evaluated = 0usize;
    let mut fired = Vec::new();
    for resource in resources {
        let Some(inspection) = engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
        else {
            continue;
        };
        let (_, record) = schedule_record(&inspection)?;
        if !is_due(&record, now) {
            continue;
        }
        if evaluated >= limit {
            break;
        }
        evaluated = evaluated.saturating_add(1);
        let due = fire_schedule_locked(
            engine_host,
            invocation,
            &inspection.resource.resource_id,
            now,
        )
        .await?;
        fired.extend(due);
    }
    let cursor = publish_lifecycle_event(
        engine_host,
        invocation,
        "schedule.fire_due.completed",
        json!({
            "evaluatedSchedules": evaluated,
            "runRecordCount": fired.len(),
            "evaluatedAt": now,
            "runRefs": fired,
            "candidateScheduleCount": candidate_count,
            "candidateLimit": FIRE_CANDIDATE_LIMIT
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": SCHEDULE_RUN_SCHEMA_VERSION,
        "status": "ok",
        "evaluatedAt": now,
        "evaluatedSchedules": evaluated,
        "runRecordCount": fired.len(),
        "runs": fired,
        "candidateScheduleCount": candidate_count,
        "candidateLimit": FIRE_CANDIDATE_LIMIT,
        "streamCursor": cursor.0
    }))
}

async fn fire_schedule_locked(
    engine_host: &EngineHostHandle,
    invocation: &crate::engine::Invocation,
    schedule_resource_id: &str,
    now: DateTime<Utc>,
) -> Result<Vec<Value>, CapabilityError> {
    let lease = engine_host
        .acquire_resource_lease(AcquireResourceLease {
            resource_kind: SCHEDULE_KIND.to_owned(),
            resource_id: schedule_resource_id.to_owned(),
            holder_invocation_id: invocation.id.clone(),
            function_id: invocation.function_id.clone(),
            actor_id: invocation.causal_context.actor_id.clone(),
            authority_grant_id: invocation.causal_context.authority_grant_id.clone(),
            trace_id: invocation.causal_context.trace_id.clone(),
            parent_invocation_id: invocation.causal_context.parent_invocation_id.clone(),
            idempotency_key: invocation.causal_context.idempotency_key.clone(),
            ttl_ms: SCHEDULE_LEASE_TTL_MS,
        })
        .await
        .map_err(engine_error)?;
    let result =
        fire_schedule_after_lease(engine_host, invocation, schedule_resource_id, now).await;
    let release_result = engine_host
        .release_resource_lease(&lease.lease_id)
        .await
        .map_err(engine_error);
    match (result, release_result) {
        (Ok(value), Ok(_)) => Ok(value),
        (Ok(_), Err(error)) => Err(error),
        (Err(error), _) => Err(error),
    }
}

async fn fire_schedule_after_lease(
    engine_host: &EngineHostHandle,
    invocation: &crate::engine::Invocation,
    schedule_resource_id: &str,
    now: DateTime<Utc>,
) -> Result<Vec<Value>, CapabilityError> {
    let mut inspection = inspect_schedule_id(engine_host, invocation, schedule_resource_id).await?;
    let (current_version_id, mut record) = schedule_record(&inspection)?;
    if !is_due(&record, now) {
        return Ok(Vec::new());
    }
    let plan = due_plan(&record, now)?;
    let mut run_refs = Vec::new();
    for (index, due) in plan.runs.iter().enumerate() {
        let run = create_run_record(
            engine_host,
            invocation,
            &inspection,
            &current_version_id,
            &record,
            due,
            now,
            index,
        )
        .await?;
        run_refs.push(run);
    }
    if let Some(skip) = plan.skipped {
        let run = create_skipped_run_record(
            engine_host,
            invocation,
            &inspection,
            &current_version_id,
            &record,
            skip.scheduled_for,
            now,
            skip.skipped_count,
            plan.runs.len(),
        )
        .await?;
        run_refs.push(run);
    }
    record.last_evaluated_at = Some(now);
    if !plan.runs.is_empty() {
        record.last_run_at = Some(now);
    }
    record.next_fire_at = plan.next_fire_at;
    if record.trigger.kind == TriggerKind::Once {
        record.state = ScheduleState::Completed;
    }
    record.updated_at = now;
    record.revision = record.revision.saturating_add(1);
    let version = engine_host
        .update_resource(UpdateResource {
            resource_id: inspection.resource.resource_id.clone(),
            expected_current_version_id: Some(current_version_id),
            lifecycle: Some(record.state.as_str().to_owned()),
            payload: to_value(&record, "schedule fire update")?,
            state: None,
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    inspection.resource.lifecycle = record.state.as_str().to_owned();
    inspection.resource.current_version_id = Some(version.version_id.clone());
    let _ = publish_lifecycle_event(
        engine_host,
        invocation,
        "schedule.fired",
        json!({
            "scheduleResourceId": inspection.resource.resource_id,
            "scheduleVersionId": version.version_id,
            "state": record.state.as_str(),
            "nextFireAt": record.next_fire_at,
            "runRefs": run_refs,
            "resourceRefs": [version_ref(&inspection.resource, &version, "schedule")]
        }),
    )
    .await?;
    Ok(run_refs)
}

async fn create_run_record(
    engine_host: &EngineHostHandle,
    invocation: &crate::engine::Invocation,
    inspection: &EngineResourceInspection,
    schedule_version_id: &str,
    record: &ScheduleRecord,
    scheduled_for: &DateTime<Utc>,
    evaluated_at: DateTime<Utc>,
    index: usize,
) -> Result<Value, CapabilityError> {
    create_run_resource(
        engine_host,
        invocation,
        inspection,
        schedule_version_id,
        record,
        scheduled_for,
        evaluated_at,
        index,
        ScheduleRunState::Recorded,
        json!({
            "isMissed": scheduled_for < &evaluated_at,
            "policy": record.missed_run_policy.mode.as_str(),
            "occurrencesRepresented": 1
        }),
    )
    .await
}

async fn create_skipped_run_record(
    engine_host: &EngineHostHandle,
    invocation: &crate::engine::Invocation,
    inspection: &EngineResourceInspection,
    schedule_version_id: &str,
    record: &ScheduleRecord,
    scheduled_for: DateTime<Utc>,
    evaluated_at: DateTime<Utc>,
    skipped_count: u32,
    index: usize,
) -> Result<Value, CapabilityError> {
    create_run_resource(
        engine_host,
        invocation,
        inspection,
        schedule_version_id,
        record,
        &scheduled_for,
        evaluated_at,
        index,
        ScheduleRunState::SkippedMissed,
        json!({
            "isMissed": true,
            "policy": record.missed_run_policy.mode.as_str(),
            "occurrencesRepresented": skipped_count
        }),
    )
    .await
}

async fn create_run_resource(
    engine_host: &EngineHostHandle,
    invocation: &crate::engine::Invocation,
    inspection: &EngineResourceInspection,
    schedule_version_id: &str,
    record: &ScheduleRecord,
    scheduled_for: &DateTime<Utc>,
    evaluated_at: DateTime<Utc>,
    index: usize,
    state: ScheduleRunState,
    missed: Value,
) -> Result<Value, CapabilityError> {
    let run = ScheduleRunRecord {
        schema_version: SCHEDULE_RUN_SCHEMA_VERSION.to_owned(),
        state: state.clone(),
        schedule_resource_id: inspection.resource.resource_id.clone(),
        schedule_version_id: schedule_version_id.to_owned(),
        schedule_kind: record.schedule_kind.clone(),
        scheduled_for: *scheduled_for,
        evaluated_at,
        trigger: record.trigger.clone(),
        target: record.target.clone(),
        authority: authority_record(invocation),
        missed,
        background_result: json!({
            "dispatch": record.target.dispatch,
            "status": state.as_str(),
            "featureExecution": "owned_by_target_domain",
            "notificationDelivery": "not_implemented_in_slice_12"
        }),
        idempotency: idempotency(invocation),
        retention: record.retention.clone(),
        trace_refs: trace_refs(invocation),
        replay_refs: replay_refs(invocation),
        revision: 1,
    };
    let resource = engine_host
        .create_resource(CreateResource {
            resource_id: Some(schedule_run_resource_id(
                &inspection.resource.resource_id,
                invocation,
                index,
            )),
            kind: SCHEDULE_RUN_KIND.to_owned(),
            schema_id: Some(SCHEDULE_RUN_SCHEMA_ID.to_owned()),
            scope: inspection.resource.scope.clone(),
            owner_worker_id: WorkerId::new(WORKER).map_err(engine_error)?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(state.as_str().to_owned()),
            policy: resource_policy("schedule_run"),
            initial_payload: Some(to_value(&run, "schedule run")?),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let _ = engine_host
        .link_resources(LinkResources {
            source_resource_id: inspection.resource.resource_id.clone(),
            target_resource_id: resource.resource_id.clone(),
            relation: PRODUCED_RUN_RELATION.to_owned(),
            metadata: json!({
                "scheduledFor": scheduled_for,
                "evaluatedAt": evaluated_at,
                "state": state.as_str()
            }),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    Ok(run_summary_from_parts(&resource, &run))
}

fn schedule_run_resource_id(
    schedule_resource_id: &str,
    invocation: &crate::engine::Invocation,
    index: usize,
) -> String {
    let schedule_key = schedule_resource_id
        .strip_prefix("schedule:")
        .unwrap_or(schedule_resource_id)
        .replace(':', ".");
    format!(
        "{SCHEDULE_RUN_KIND}:{schedule_key}:{}:{index}",
        invocation.id.as_str()
    )
}

async fn require_schedule(
    engine_host: &EngineHostHandle,
    invocation: &crate::engine::Invocation,
    payload: &Value,
) -> Result<EngineResourceInspection, CapabilityError> {
    let id = required_string(payload, "scheduleResourceId")?;
    validate_resource_id("scheduleResourceId", &id, "schedule:")?;
    inspect_schedule_id(engine_host, invocation, &id).await
}

async fn inspect_schedule_id(
    engine_host: &EngineHostHandle,
    invocation: &crate::engine::Invocation,
    id: &str,
) -> Result<EngineResourceInspection, CapabilityError> {
    let inspection = engine_host
        .inspect_resource(id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid_params(format!("schedule resource {id} was not found")))?;
    if inspection.resource.kind != SCHEDULE_KIND {
        return Err(invalid_params(format!(
            "resource {id} is not a schedule resource"
        )));
    }
    ensure_scope(invocation, &inspection.resource.scope)?;
    Ok(inspection)
}

fn schedule_record(
    inspection: &EngineResourceInspection,
) -> Result<(String, ScheduleRecord), CapabilityError> {
    let (version_id, payload) = current_payload(inspection)
        .ok_or_else(|| invalid_params("schedule resource has no version"))?;
    let record = serde_json::from_value(payload)
        .map_err(|error| invalid_params(format!("malformed schedule payload: {error}")))?;
    Ok((version_id, record))
}
