use std::collections::BTreeSet;

use serde_json::{Value, json};

use super::TraceComponents;
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
        "status": if failed_invocations > 0 {
            "error"
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
