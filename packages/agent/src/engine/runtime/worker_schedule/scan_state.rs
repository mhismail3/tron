//! Safe scan-state payload helpers for the worker schedule scanner.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::contracts::{WorkerScheduleDispatchSummary, short_hash};
use super::{SCHEDULE_SCAN_MAX_PER_POLL, SCHEDULE_SCAN_PAGE_SIZE};
use crate::engine::durability::resources::ResourceListCursor;
use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::ids::TraceId;

pub(super) struct ScanStatePersist<'a> {
    pub(super) cursor: Option<ResourceListCursor>,
    pub(super) started_at: DateTime<Utc>,
    pub(super) finished_at: DateTime<Utc>,
    pub(super) scanned_count: usize,
    pub(super) wrapped: bool,
    pub(super) budget_exhausted: bool,
    pub(super) cancelled: bool,
    pub(super) summary: &'a WorkerScheduleDispatchSummary,
    pub(super) trace_id: &'a TraceId,
    pub(super) error: Option<&'a EngineError>,
}

pub(super) fn schedule_scan_trace_id(started_at: DateTime<Utc>) -> Result<TraceId> {
    TraceId::new(format!(
        "worker-schedule-scan:{}",
        short_hash(&started_at.to_rfc3339())
    ))
}

pub(super) fn scan_state_payload(input: &ScanStatePersist<'_>) -> Value {
    let status = if input.error.is_some() {
        "failed"
    } else if input.cancelled {
        "cancelled"
    } else {
        "completed"
    };
    json!({
        "scannerId": "default",
        "status": status,
        "cursor": input.cursor.as_ref().map(|cursor| json!({
            "updatedAt": cursor.updated_at.to_rfc3339(),
            "resourceId": cursor.resource_id,
        })),
        "pageSize": SCHEDULE_SCAN_PAGE_SIZE,
        "maxPerPoll": SCHEDULE_SCAN_MAX_PER_POLL,
        "lastScannedCount": input.scanned_count,
        "wrapped": input.wrapped,
        "budgetExhausted": input.budget_exhausted,
        "lastPoll": {
            "startedAtUtc": input.started_at.to_rfc3339(),
            "finishedAtUtc": input.finished_at.to_rfc3339(),
        },
        "summary": {
            "reviewed": input.summary.reviewed,
            "due": input.summary.due,
            "enqueued": input.summary.enqueued,
            "replayed": input.summary.replayed,
            "skippedMissed": input.summary.skipped_missed,
            "skippedOverlap": input.summary.skipped_overlap,
            "failed": input.summary.failed,
        },
        "trace": {
            "traceId": input.trace_id.as_str(),
        },
        "error": input.error.map(|_| json!({
            "redacted": true,
            "message": "worker schedule scan failed",
        })),
        "metadata": {
            "source": "worker_schedule_capacity",
            "cursorOrder": "updated_at_desc_resource_id_desc",
            "secretStorage": "scanner_metadata_only",
            "updatedAt": Utc::now().to_rfc3339(),
        }
    })
}

pub(super) fn scan_cursor_from_payload(payload: &Value) -> Result<Option<ResourceListCursor>> {
    let Some(cursor) = payload.get("cursor") else {
        return Ok(None);
    };
    if cursor.is_null() {
        return Ok(None);
    }
    let updated_at = cursor
        .get("updatedAt")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            EngineError::PolicyViolation(
                "worker schedule scan cursor updatedAt must be a string".to_owned(),
            )
        })?;
    let resource_id = cursor
        .get("resourceId")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            EngineError::PolicyViolation(
                "worker schedule scan cursor resourceId must be a string".to_owned(),
            )
        })?;
    let parsed = DateTime::parse_from_rfc3339(updated_at)
        .map_err(|err| {
            EngineError::PolicyViolation(format!(
                "worker schedule scan cursor updatedAt must be UTC RFC3339: {err}"
            ))
        })?
        .with_timezone(&Utc);
    Ok(Some(ResourceListCursor {
        updated_at: parsed,
        resource_id: resource_id.to_owned(),
    }))
}
