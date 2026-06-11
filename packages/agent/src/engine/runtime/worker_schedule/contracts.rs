//! Worker schedule plan and tick contracts.

use chrono::{DateTime, Duration as ChronoDuration, Utc};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::{
    LAUNCH_FROM_TRIGGER_FUNCTION, MAX_INTERVAL_MS, MIN_INTERVAL_MS, STDIN_BUNDLE_DELIVERY_MODE,
};
use crate::engine::durability::resources::{
    EngineResource, EngineResourceInspection, EngineResourceScope,
};
use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::ids::{InvocationId, TraceId, TriggerId};
use crate::engine::kernel::types::VisibilityScope;
use crate::engine::runtime::worker_orchestration::contracts::{AutostartPlan, LaunchPlan};

/// Summary of one bounded worker schedule poll.
#[derive(Default, Debug, Clone, PartialEq, Eq)]
pub struct WorkerScheduleDispatchSummary {
    /// Reviewed schedule resources inspected.
    pub reviewed: usize,
    /// Due ticks dispatched or replayed.
    pub due: usize,
    /// Latest due ticks enqueued.
    pub enqueued: usize,
    /// Existing latest due ticks replayed.
    pub replayed: usize,
    /// Skipped-missed evidence records created or replayed.
    pub skipped_missed: usize,
    /// Overlap skips created or replayed.
    pub skipped_overlap: usize,
    /// Plans or tick dispatches that failed closed.
    pub failed: usize,
}

pub(super) struct TickDispatchOutcome {
    pub(super) summary_status: &'static str,
    pub(super) payload: Value,
}

pub(super) struct TriggerDispatchAudit {
    pub(super) invocation_id: InvocationId,
    pub(super) queue_receipt_id: Option<String>,
}

#[derive(Clone, Debug)]
pub(super) struct WorkerSchedulePlan {
    pub(super) schedule_id: String,
    pub(super) trigger_id: TriggerId,
    pub(super) autostart_plan_resource_id: String,
    pub(super) anchor_at_utc: DateTime<Utc>,
    pub(super) interval_ms: u64,
    pub(super) session_id: Option<String>,
    pub(super) workspace_id: Option<String>,
}

impl WorkerSchedulePlan {
    pub(super) fn from_payload(resource: &EngineResource, payload: &Value) -> Result<Self> {
        if payload_str(payload, "status")? != "reviewed" {
            return Err(EngineError::PolicyViolation(
                "worker schedule plan payload status must be reviewed".to_owned(),
            ));
        }
        require_literal(payload, "missedTickPolicy", "skip_missed_ticks_v1")?;
        require_literal(payload, "overlapPolicy", "single_active_tick_v1")?;
        require_literal(payload, "duplicatePolicy", "tick_idempotency_replay_v1")?;
        let schedule_id = non_empty_payload_string(payload, "scheduleId")?;
        if schedule_id != resource.resource_id {
            return Err(EngineError::PolicyViolation(
                "worker schedule plan scheduleId must match resource id".to_owned(),
            ));
        }
        let interval_ms = payload_u64(payload, "intervalMs")?;
        if !(MIN_INTERVAL_MS..=MAX_INTERVAL_MS).contains(&interval_ms) {
            return Err(EngineError::PolicyViolation(format!(
                "worker schedule intervalMs must be between {MIN_INTERVAL_MS} and {MAX_INTERVAL_MS}"
            )));
        }
        let (session_id, workspace_id) = match &resource.scope {
            EngineResourceScope::System => (None, None),
            EngineResourceScope::Workspace(workspace_id) => (None, Some(workspace_id.clone())),
            EngineResourceScope::Session(session_id) => (Some(session_id.clone()), None),
        };
        Ok(Self {
            schedule_id,
            trigger_id: TriggerId::new(payload_str(payload, "triggerId")?)?,
            autostart_plan_resource_id: non_empty_payload_string(
                payload,
                "autostartPlanResourceId",
            )?,
            anchor_at_utc: parse_utc_time(payload_str(payload, "anchorAtUtc")?, "anchorAtUtc")?,
            interval_ms,
            session_id,
            workspace_id,
        })
    }
}

#[derive(Clone, Copy)]
pub(super) struct DueTick {
    pub(super) nominal_tick_at_utc: DateTime<Utc>,
    pub(super) missed_tick_count: i64,
    pub(super) skipped_nominal_tick_at_utc: Option<DateTime<Utc>>,
}

pub(super) fn due_tick(plan: &WorkerSchedulePlan, now: DateTime<Utc>) -> Result<Option<DueTick>> {
    if now < plan.anchor_at_utc {
        return Ok(None);
    }
    let elapsed_ms = now
        .signed_duration_since(plan.anchor_at_utc)
        .num_milliseconds();
    if elapsed_ms < 0 {
        return Ok(None);
    }
    let interval_ms = i64::try_from(plan.interval_ms).map_err(|_| {
        EngineError::PolicyViolation("worker schedule intervalMs is too large".to_owned())
    })?;
    let intervals_elapsed = elapsed_ms / interval_ms;
    let nominal_tick_at_utc =
        plan.anchor_at_utc + ChronoDuration::milliseconds(intervals_elapsed * interval_ms);
    let missed_tick_count = intervals_elapsed.max(0);
    let skipped_nominal_tick_at_utc = if missed_tick_count > 0 {
        Some(nominal_tick_at_utc - ChronoDuration::milliseconds(interval_ms))
    } else {
        None
    };
    Ok(Some(DueTick {
        nominal_tick_at_utc,
        missed_tick_count,
        skipped_nominal_tick_at_utc,
    }))
}

#[derive(Clone, Debug)]
pub(super) struct ScheduleTickPayload {
    pub(super) tick_resource_id: String,
    pub(super) status: String,
    pub(super) nominal_tick_at_utc: DateTime<Utc>,
    pub(super) queue_receipt_id: Option<String>,
}

impl ScheduleTickPayload {
    pub(super) fn from_payload(resource_id: &str, payload: &Value) -> Result<Option<Self>> {
        let Some(status) = payload.get("status").and_then(Value::as_str) else {
            return Ok(None);
        };
        let Some(nominal) = payload.get("nominalTickAtUtc").and_then(Value::as_str) else {
            return Ok(None);
        };
        Ok(Some(Self {
            tick_resource_id: resource_id.to_owned(),
            status: status.to_owned(),
            nominal_tick_at_utc: parse_utc_time(nominal, "nominalTickAtUtc")?,
            queue_receipt_id: payload
                .pointer("/dispatch/queueReceiptId")
                .and_then(Value::as_str)
                .map(str::to_owned),
        }))
    }
}

pub(super) struct ActiveTickEvidence {
    pub(super) tick_resource_id: String,
    pub(super) nominal_tick_at_utc: DateTime<Utc>,
    pub(super) evidence: Value,
}

pub(super) struct TickPayloadInput<'a> {
    pub(super) status: &'a str,
    pub(super) tick_id: &'a str,
    pub(super) plan: &'a WorkerSchedulePlan,
    pub(super) nominal_tick_at_utc: DateTime<Utc>,
    pub(super) trace_id: &'a TraceId,
    pub(super) queue_receipt_id: Option<&'a str>,
    pub(super) trigger_dispatch_invocation_id: Option<&'a str>,
    pub(super) target_idempotency_key: &'a str,
    pub(super) lease_id: Option<&'a str>,
    pub(super) missed: Option<Value>,
    pub(super) overlap: Option<Value>,
    pub(super) error: Option<&'a EngineError>,
}

pub(super) fn tick_payload(input: TickPayloadInput<'_>) -> Value {
    json!({
        "status": input.status,
        "tickId": input.tick_id,
        "scheduleId": input.plan.schedule_id,
        "triggerId": input.plan.trigger_id.as_str(),
        "autostartPlanResourceId": input.plan.autostart_plan_resource_id,
        "nominalTickAtUtc": input.nominal_tick_at_utc.to_rfc3339(),
        "dispatch": {
            "deliveryMode": "enqueue",
            "queueReceiptId": input.queue_receipt_id,
            "triggerDispatchInvocationId": input.trigger_dispatch_invocation_id,
            "targetFunction": LAUNCH_FROM_TRIGGER_FUNCTION,
        },
        "idempotency": {
            "targetKeyFingerprint": short_hash(input.target_idempotency_key),
            "targetKeyFormat": "worker_schedule_v1",
            "duplicatePolicy": "tick_idempotency_replay_v1",
        },
        "trace": {
            "traceId": input.trace_id.as_str(),
        },
        "missed": input.missed,
        "overlap": input.overlap,
        "error": input.error.map(|error| json!({
            "redacted": true,
            "message": redact_text(&error.to_string(), 4096),
        })),
        "metadata": {
            "source": "worker_schedule_dispatch",
            "updatedAt": Utc::now().to_rfc3339(),
            "leaseId": input.lease_id,
        }
    })
}

pub(super) fn validate_autostart_launch_plan(
    autostart: &AutostartPlan,
    launch_plan: &LaunchPlan,
    schedule_scope: &EngineResourceScope,
) -> Result<()> {
    if launch_plan.activation_delivery_mode != STDIN_BUNDLE_DELIVERY_MODE {
        return Err(EngineError::PolicyViolation(
            "worker schedule dispatch requires stdin_activation_bundle_v1 launch plan".to_owned(),
        ));
    }
    if launch_plan.expected_function_id != autostart.function_id {
        return Err(EngineError::PolicyViolation(
            "worker schedule autostart functionId must match launch plan".to_owned(),
        ));
    }
    if launch_plan.target_visibility != autostart.target_visibility {
        return Err(EngineError::PolicyViolation(
            "worker schedule autostart visibility must match launch plan".to_owned(),
        ));
    }
    if launch_plan.namespace != autostart.function_id.namespace() {
        return Err(EngineError::PolicyViolation(
            "worker schedule autostart namespace must match launch plan".to_owned(),
        ));
    }
    let expected_scope = match autostart.target_visibility {
        VisibilityScope::Session => match schedule_scope {
            EngineResourceScope::Session(session_id) => (Some(session_id.clone()), None),
            _ => {
                return Err(EngineError::PolicyViolation(
                    "session worker schedule requires session scope".to_owned(),
                ));
            }
        },
        VisibilityScope::Workspace => {
            let workspace_id = autostart
                .workspace_id
                .clone()
                .or_else(|| match schedule_scope {
                    EngineResourceScope::Workspace(workspace_id) => Some(workspace_id.clone()),
                    _ => None,
                });
            (None, workspace_id)
        }
        _ => (None, None),
    };
    if (
        launch_plan.scope.session_id.clone(),
        launch_plan.scope.workspace_id.clone(),
    ) != expected_scope
    {
        return Err(EngineError::PolicyViolation(
            "worker schedule autostart scope must match launch plan".to_owned(),
        ));
    }
    Ok(())
}

pub(super) fn ensure_resource_kind(
    inspection: &EngineResourceInspection,
    expected: &str,
) -> Result<()> {
    if inspection.resource.kind != expected {
        return Err(EngineError::PolicyViolation(format!(
            "resource {} must be kind {expected}",
            inspection.resource.resource_id
        )));
    }
    Ok(())
}

pub(super) fn current_payload(inspection: &EngineResourceInspection) -> Result<&Value> {
    let current = inspection
        .resource
        .current_version_id
        .as_ref()
        .ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "resource {} has no current payload",
                inspection.resource.resource_id
            ))
        })?;
    inspection
        .versions
        .iter()
        .find(|version| &version.version_id == current)
        .map(|version| &version.payload)
        .ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "resource {} current version is missing",
                inspection.resource.resource_id
            ))
        })
}

pub(super) fn target_idempotency_key(
    schedule_id: &str,
    nominal_tick_at_utc: DateTime<Utc>,
) -> String {
    format!(
        "saawsd:target:{schedule_id}:{}",
        nominal_tick_at_utc.to_rfc3339()
    )
}

pub(super) fn tick_id(schedule_id: &str, nominal_tick_at_utc: DateTime<Utc>) -> String {
    format!(
        "worker_schedule_tick:{}",
        short_hash(&format!(
            "{schedule_id}:{}",
            nominal_tick_at_utc.to_rfc3339()
        ))
    )
}

pub(super) fn schedule_trace_id(
    schedule_id: &str,
    nominal_tick_at_utc: DateTime<Utc>,
) -> Result<TraceId> {
    TraceId::new(format!(
        "worker-schedule:{}",
        short_hash(&format!(
            "{schedule_id}:{}",
            nominal_tick_at_utc.to_rfc3339()
        ))
    ))
}

pub(super) fn trigger_launch_attempt_id(
    autostart_plan_resource_id: &str,
    trigger_id: &TriggerId,
    target_idempotency_key: &str,
) -> String {
    format!(
        "worker_trigger_launch_attempt:{}",
        short_hash(&format!(
            "{}:{}:{}",
            autostart_plan_resource_id, trigger_id, target_idempotency_key
        ))
    )
}

pub(super) fn short_hash(value: &str) -> String {
    let hash = hex::encode(Sha256::digest(value.as_bytes()));
    hash.chars().take(16).collect()
}

pub(super) fn reject_secret_material_in_value(label: &str, value: &Value) -> Result<()> {
    match value {
        Value::String(value) => reject_secret_material(label, value),
        Value::Array(items) => {
            for item in items {
                reject_secret_material_in_value(label, item)?;
            }
            Ok(())
        }
        Value::Object(object) => {
            for (key, value) in object {
                reject_secret_material(label, key)?;
                reject_secret_material_in_value(key, value)?;
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

pub(super) fn is_terminal_process_status(status: &str) -> bool {
    matches!(
        status,
        "stopped" | "failed" | "killed" | "expired" | "revoked" | "archived"
    )
}

fn payload_str<'a>(payload: &'a Value, field: &str) -> Result<&'a str> {
    payload.get(field).and_then(Value::as_str).ok_or_else(|| {
        EngineError::PolicyViolation(format!("required field {field} must be a string"))
    })
}

fn non_empty_payload_string(payload: &Value, field: &str) -> Result<String> {
    let value = payload_str(payload, field)?;
    if value.trim().is_empty() {
        return Err(EngineError::PolicyViolation(format!(
            "{field} must be non-empty"
        )));
    }
    Ok(value.to_owned())
}

fn payload_u64(payload: &Value, field: &str) -> Result<u64> {
    payload.get(field).and_then(Value::as_u64).ok_or_else(|| {
        EngineError::PolicyViolation(format!(
            "required field {field} must be an unsigned integer"
        ))
    })
}

fn require_literal(payload: &Value, field: &str, expected: &str) -> Result<()> {
    let actual = payload_str(payload, field)?;
    if actual != expected {
        return Err(EngineError::PolicyViolation(format!(
            "worker schedule plan {field} must be {expected}"
        )));
    }
    Ok(())
}

fn parse_utc_time(value: &str, label: &str) -> Result<DateTime<Utc>> {
    let parsed = DateTime::parse_from_rfc3339(value)
        .map_err(|error| EngineError::PolicyViolation(format!("invalid {label}: {error}")))?;
    if parsed.offset().local_minus_utc() != 0 {
        return Err(EngineError::PolicyViolation(format!(
            "{label} must be a UTC timestamp"
        )));
    }
    Ok(parsed.with_timezone(&Utc))
}

fn redact_text(value: &str, max_len: usize) -> String {
    let mut redacted = value
        .replace("token", "[redacted]")
        .replace("secret", "[redacted]")
        .replace("password", "[redacted]");
    if redacted.len() > max_len {
        redacted.truncate(max_len);
    }
    redacted
}

fn reject_secret_material(label: &str, value: &str) -> Result<()> {
    if contains_secret_material(value) {
        return Err(EngineError::PolicyViolation(format!(
            "worker schedule {label} appears secret-bearing"
        )));
    }
    Ok(())
}

fn contains_secret_material(value: &str) -> bool {
    let lower = value.to_ascii_lowercase();
    [
        "token",
        "secret",
        "password",
        "passwd",
        "bearer",
        "authorization",
        "api_key",
    ]
    .iter()
    .any(|needle| lower.contains(needle))
}
