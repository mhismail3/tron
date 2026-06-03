use std::collections::BTreeSet;

use serde_json::{Value, json};

use super::TraceComponents;
use crate::engine::ids::InvocationId;
use crate::engine::queue::{EngineQueueItem, QueueItemStatus};
use crate::engine::resources::EngineResourceEvent;
use crate::engine::types::CatalogChange;

pub(in crate::engine::primitives) fn catalog_change_belongs_to_trace(
    change: &CatalogChange,
    trace_id: &str,
    function_ids: &BTreeSet<String>,
    worker_ids: &BTreeSet<String>,
) -> bool {
    change.id.contains(trace_id)
        || change.subject_id.as_str() == trace_id
        || function_ids.contains(change.subject_id.as_str())
        || worker_ids.contains(change.subject_id.as_str())
        || change
            .owner_worker
            .as_ref()
            .is_some_and(|worker| worker_ids.contains(worker.as_str()))
}

pub(in crate::engine::primitives) fn trace_summary(
    trace_id: &str,
    trace: &TraceComponents,
) -> Value {
    let failed_invocations = trace
        .invocations
        .iter()
        .filter(|record| !record.succeeded)
        .count();
    let pending_approvals = trace
        .approvals
        .iter()
        .filter(|record| matches!(record.status.as_str(), "pending" | "approved"))
        .count();
    let failed_approvals = trace
        .approvals
        .iter()
        .filter(|record| matches!(record.status.as_str(), "denied" | "failed"))
        .count();
    let mut timestamps = trace_timestamps(trace);
    timestamps.sort();
    let root_invocation_id = trace
        .invocations
        .iter()
        .find(|record| record.parent_invocation_id.is_none())
        .or_else(|| trace.invocations.first())
        .map(|record| record.invocation_id.as_str());
    json!({
        "traceId": trace_id,
        "status": if failed_invocations > 0 || failed_approvals > 0 {
            "error"
        } else if pending_approvals > 0 {
            "pending"
        } else {
            "ok"
        },
        "rootInvocationId": root_invocation_id,
        "invocationCount": trace.invocations.len(),
        "failedInvocations": failed_invocations,
        "catalogChangeCount": trace.catalog_changes.len(),
        "streamCount": trace.streams.len(),
        "queueItemCount": trace.queue_items.len(),
        "resourceEventCount": trace.resource_events.len(),
        "approvalCount": trace.approvals.len(),
        "pendingApprovalCount": pending_approvals,
        "leaseCount": trace.leases.len(),
        "compensationCount": trace.compensation.len(),
        "firstTimestamp": timestamps.first(),
        "lastTimestamp": timestamps.last(),
    })
}

fn trace_timestamps(trace: &TraceComponents) -> Vec<String> {
    let mut timestamps = Vec::new();
    timestamps.extend(
        trace
            .invocations
            .iter()
            .map(|record| record.timestamp.to_rfc3339()),
    );
    timestamps.extend(
        trace
            .catalog_changes
            .iter()
            .map(|record| record.timestamp.to_rfc3339()),
    );
    timestamps.extend(
        trace
            .streams
            .iter()
            .map(|record| record.created_at.to_rfc3339()),
    );
    timestamps.extend(
        trace
            .queue_items
            .iter()
            .map(|record| record.created_at.to_rfc3339()),
    );
    timestamps.extend(
        trace
            .resource_events
            .iter()
            .map(|record| record.occurred_at.to_rfc3339()),
    );
    timestamps.extend(
        trace
            .approvals
            .iter()
            .map(|record| record.updated_at.to_rfc3339()),
    );
    timestamps.extend(
        trace
            .leases
            .iter()
            .map(|record| record.acquired_at.to_rfc3339()),
    );
    timestamps.extend(trace.compensation.iter().filter_map(|record| {
        record
            .get("createdAt")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned)
    }));
    timestamps
}

pub(in crate::engine::primitives) fn queue_item_log_value(record: &EngineQueueItem) -> Value {
    json!({
        "timestamp": record.updated_at.to_rfc3339(),
        "traceId": record.trace_id.as_str(),
        "kind": "queue_item",
        "level": if matches!(record.status, QueueItemStatus::DeadLettered) { "error" } else { "info" },
        "receiptId": record.receipt_id,
        "queue": record.queue,
        "functionId": record.function_id.as_str(),
        "status": &record.status,
        "message": "engine queue item recorded",
    })
}

pub(in crate::engine::primitives) fn resource_event_log_value(
    record: &EngineResourceEvent,
) -> Value {
    json!({
        "timestamp": record.occurred_at.to_rfc3339(),
        "traceId": record.trace_id.as_str(),
        "kind": "resource_event",
        "level": "info",
        "resourceId": record.resource_id,
        "eventType": record.event_type,
        "invocationId": record.invocation_id.as_ref().map(InvocationId::as_str),
        "message": "engine resource event recorded",
    })
}
