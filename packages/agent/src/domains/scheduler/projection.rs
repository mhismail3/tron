use serde_json::{Value, json};

use crate::engine::{EngineHostHandle, EngineResource, EngineResourceInspection};
use crate::shared::server::errors::CapabilityError;

use super::errors::{engine_error, invalid_params};
use super::support::{current_payload, resource_ref};
use super::types::{ScheduleRecord, ScheduleRunRecord, TargetRecord};

const PRODUCED_RUN_RELATION: &str = "produced_run";

pub(super) async fn list_run_summaries(
    engine_host: &EngineHostHandle,
    schedule_resource_id: &str,
    limit: usize,
) -> Result<Vec<Value>, CapabilityError> {
    let links = engine_host
        .list_resource_links_for_source(schedule_resource_id, PRODUCED_RUN_RELATION, limit)
        .await
        .map_err(engine_error)?;
    let mut runs = Vec::new();
    for link in links {
        let inspection = engine_host
            .inspect_resource(&link.target_resource_id)
            .await
            .map_err(engine_error)?
            .ok_or_else(|| invalid_params("listed schedule_run disappeared before inspection"))?;
        let (_, run) = run_record(&inspection)?;
        if run.schedule_resource_id == schedule_resource_id {
            runs.push(run_summary(&inspection, &run));
        }
    }
    Ok(runs)
}

pub(super) fn schedule_summary(
    inspection: &EngineResourceInspection,
    record: &ScheduleRecord,
) -> Value {
    json!({
        "scheduleResourceId": inspection.resource.resource_id,
        "scheduleVersionId": inspection.resource.current_version_id,
        "state": record.state.as_str(),
        "title": record.title,
        "scheduleKind": record.schedule_kind.as_str(),
        "triggerType": record.trigger.kind.as_str(),
        "timezone": record.timezone_policy.timezone,
        "missedRunPolicy": record.missed_run_policy.mode.as_str(),
        "target": target_summary(&record.target),
        "nextFireAt": record.next_fire_at,
        "lastRunAt": record.last_run_at,
        "revision": record.revision,
        "resourceRefs": [resource_ref(&inspection.resource, "schedule")]
    })
}

pub(super) fn schedule_detail(
    inspection: &EngineResourceInspection,
    version_id: &str,
    record: &ScheduleRecord,
) -> Value {
    json!({
        "schemaVersion": record.schema_version,
        "scheduleResourceId": inspection.resource.resource_id,
        "scheduleVersionId": version_id,
        "state": record.state.as_str(),
        "title": record.title,
        "scheduleKind": record.schedule_kind.as_str(),
        "trigger": {
            "kind": record.trigger.kind.as_str(),
            "startAt": record.trigger.start_at,
            "intervalSeconds": record.trigger.interval_seconds
        },
        "timezonePolicy": {
            "timezone": record.timezone_policy.timezone,
            "resolution": record.timezone_policy.resolution,
            "dstPolicy": record.timezone_policy.dst_policy
        },
        "missedRunPolicy": {
            "mode": record.missed_run_policy.mode.as_str(),
            "maxCatchUpRuns": record.missed_run_policy.max_catch_up_runs
        },
        "target": target_detail(&record.target),
        "retention": {
            "maxRunRecords": record.retention.max_run_records,
            "maxAgeDays": record.retention.max_age_days
        },
        "createdAt": record.created_at,
        "updatedAt": record.updated_at,
        "nextFireAt": record.next_fire_at,
        "lastEvaluatedAt": record.last_evaluated_at,
        "lastRunAt": record.last_run_at,
        "cancellation": record.cancellation.as_ref().map(|cancellation| json!({
            "reason": cancellation.reason,
            "cancelledAt": cancellation.cancelled_at,
            "actorId": cancellation.actor_id
        })),
        "traceRefs": record.trace_refs,
        "replayRefs": record.replay_refs,
        "revision": record.revision,
        "resourceRefs": [resource_ref(&inspection.resource, "schedule")]
    })
}

pub(super) fn run_summary_from_parts(
    resource: &EngineResource,
    record: &ScheduleRunRecord,
) -> Value {
    json!({
        "scheduleRunResourceId": resource.resource_id,
        "scheduleRunVersionId": resource.current_version_id,
        "state": record.state.as_str(),
        "scheduleResourceId": record.schedule_resource_id,
        "scheduledFor": record.scheduled_for,
        "evaluatedAt": record.evaluated_at,
        "missed": record.missed,
        "target": target_summary(&record.target),
        "backgroundResult": record.background_result,
        "resourceRefs": [resource_ref(resource, "schedule_run")]
    })
}

fn run_summary(inspection: &EngineResourceInspection, record: &ScheduleRunRecord) -> Value {
    json!({
        "scheduleRunResourceId": inspection.resource.resource_id,
        "scheduleRunVersionId": inspection.resource.current_version_id,
        "state": record.state.as_str(),
        "scheduleResourceId": record.schedule_resource_id,
        "scheduledFor": record.scheduled_for,
        "evaluatedAt": record.evaluated_at,
        "missed": record.missed,
        "target": target_summary(&record.target),
        "backgroundResult": record.background_result,
        "resourceRefs": [resource_ref(&inspection.resource, "schedule_run")]
    })
}

fn run_record(
    inspection: &EngineResourceInspection,
) -> Result<(String, ScheduleRunRecord), CapabilityError> {
    let (version_id, payload) = current_payload(inspection)
        .ok_or_else(|| invalid_params("schedule_run resource has no version"))?;
    let record = serde_json::from_value(payload)
        .map_err(|error| invalid_params(format!("malformed schedule_run payload: {error}")))?;
    Ok((version_id, record))
}

fn target_summary(target: &TargetRecord) -> Value {
    json!({
        "resourceKind": target.resource_kind,
        "action": target.action,
        "selectorBound": target.selector_bound,
        "dispatch": target.dispatch
    })
}

fn target_detail(target: &TargetRecord) -> Value {
    json!({
        "resourceKind": target.resource_kind,
        "action": target.action,
        "resourceIds": target.resource_ids,
        "selectorBound": target.selector_bound,
        "dispatch": target.dispatch
    })
}
