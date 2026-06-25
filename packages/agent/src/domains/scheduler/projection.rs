use serde_json::{Value, json};

use crate::engine::{EngineHostHandle, EngineResource, EngineResourceInspection, ListResources};
use crate::shared::server::errors::CapabilityError;

use super::SCHEDULE_RUN_KIND;
use super::errors::{engine_error, invalid_params};
use super::support::{current_payload, resource_ref, resource_scope, to_value};
use super::types::{ScheduleRecord, ScheduleRunRecord, TargetRecord};

pub(super) async fn list_run_summaries(
    engine_host: &EngineHostHandle,
    invocation: &crate::engine::Invocation,
    schedule_resource_id: &str,
    limit: usize,
) -> Result<Vec<Value>, CapabilityError> {
    let resources = engine_host
        .scan_resources_internal(ListResources {
            kind: Some(SCHEDULE_RUN_KIND.to_owned()),
            scope: Some(resource_scope(invocation)),
            lifecycle: None,
            limit: usize::MAX,
        })
        .await
        .map_err(engine_error)?;
    let mut runs = Vec::new();
    for resource in resources {
        let inspection = engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
            .ok_or_else(|| invalid_params("listed schedule_run disappeared before inspection"))?;
        let (_, run) = run_record(&inspection)?;
        if run.schedule_resource_id == schedule_resource_id {
            runs.push(run_summary(&inspection, &run));
            if runs.len() >= limit {
                break;
            }
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
    let mut value = to_value(record, "schedule detail").expect("schedule detail serialization");
    value["scheduleResourceId"] = json!(inspection.resource.resource_id);
    value["scheduleVersionId"] = json!(version_id);
    value["resourceRefs"] = json!([resource_ref(&inspection.resource, "schedule")]);
    value
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
