use serde_json::json;

use crate::engine::durability::streams::PublishStreamEvent;
use crate::engine::invocation::host::QueueTargetInvocation;
use crate::engine::kernel::types::VisibilityScope;
use crate::engine::{
    CausalContext, DeliveryMode, EngineHostHandle, Invocation, InvocationResult, Result,
};

use super::{EngineQueueAttemptRecord, EngineQueueItem, QueueAttemptOutcome, QueueItemStatus};

/// Queue drain runtime.
pub struct EngineQueueRuntime;

impl EngineQueueRuntime {
    /// Claim and execute one queue item, returning `Ok(None)` when no item is
    /// ready. Failed invocations are retried through the queue store.
    pub async fn drain_once(
        handle: &EngineHostHandle,
        queue: &str,
        lease_owner: &str,
    ) -> Result<Option<InvocationResult>> {
        let Some(item) = handle.claim_queue_item(queue, lease_owner, 30_000).await? else {
            return Ok(None);
        };
        publish_queue_lifecycle_event(handle, "claim", &item, None).await;
        Self::execute_claimed_item(handle, item).await.map(Some)
    }

    /// Claim and execute a specific receipt. Used by transport surfaces
    /// that must synchronously preserve an existing wire contract without
    /// racing unrelated queued work.
    pub async fn drain_receipt(
        handle: &EngineHostHandle,
        receipt_id: &str,
        lease_owner: &str,
    ) -> Result<Option<InvocationResult>> {
        let Some(item) = handle
            .claim_queue_item_by_receipt(receipt_id, lease_owner, 30_000)
            .await?
        else {
            return Ok(None);
        };
        publish_queue_lifecycle_event(handle, "claim", &item, None).await;
        Self::execute_claimed_item(handle, item).await.map(Some)
    }

    async fn execute_claimed_item(
        handle: &EngineHostHandle,
        item: EngineQueueItem,
    ) -> Result<InvocationResult> {
        let mut context = CausalContext::new(
            item.actor_id.clone(),
            item.actor_kind.clone(),
            item.authority_grant_id.clone(),
            item.trace_id.clone(),
        );
        for scope in &item.authority_scopes {
            context = context.with_scope(scope.clone());
        }
        for (key, value) in &item.runtime_metadata {
            context = context.with_runtime_metadata(key.clone(), value.clone());
        }
        if let Some(parent) = &item.parent_invocation_id {
            context = context.with_parent_invocation(parent.clone());
        }
        if let Some(trigger_id) = &item.trigger_id {
            context = context.with_trigger_id(trigger_id.clone());
        }
        if let Some(session_id) = &item.session_id {
            context = context.with_session_id(session_id.clone());
        }
        if let Some(workspace_id) = &item.workspace_id {
            context = context.with_workspace_id(workspace_id.clone());
        }
        if let Some(key) = &item.idempotency_key {
            let attempt_key = if item.attempts == 0 {
                key.clone()
            } else {
                format!("{key}:queue-retry:{}", item.attempts)
            };
            context = context.with_idempotency_key(attempt_key);
        }
        context.delivery_mode = DeliveryMode::Sync;
        let invocation =
            Invocation::new_sync(item.function_id.clone(), item.payload.clone(), context);
        let target = handle.invoke_queue_target(invocation).await;
        let attempt = queue_attempt_record(&item, &target);
        let recorded_invocation = target.recorded_invocation;
        let result = target.result;
        if result.error.is_some() {
            if handle
                .fail_queue_item_with_attempt(&item.receipt_id, 3, 1_000, attempt)
                .await?
            {
                let updated = handle
                    .get_queue_item(&item.receipt_id)
                    .await?
                    .unwrap_or_else(|| item.clone());
                publish_queue_lifecycle_event(
                    handle,
                    queue_failure_event_type(&updated),
                    &updated,
                    Some((&result, recorded_invocation)),
                )
                .await;
            }
        } else if handle
            .complete_queue_item_with_attempt(&item.receipt_id, attempt)
            .await?
        {
            let updated = handle
                .get_queue_item(&item.receipt_id)
                .await?
                .unwrap_or_else(|| item.clone());
            publish_queue_lifecycle_event(
                handle,
                "complete",
                &updated,
                Some((&result, recorded_invocation)),
            )
            .await;
        }
        Ok(result)
    }
}

fn queue_attempt_record(
    item: &EngineQueueItem,
    target: &QueueTargetInvocation,
) -> EngineQueueAttemptRecord {
    let result = &target.result;
    EngineQueueAttemptRecord {
        attempt: item.attempts.saturating_add(1),
        outcome: if result.error.is_some() {
            QueueAttemptOutcome::Failed
        } else {
            QueueAttemptOutcome::Completed
        },
        lease_owner: item.lease_owner.clone(),
        delivery_invocation_id: Some(result.invocation_id.clone()),
        result_invocation_id: target
            .recorded_invocation
            .then(|| result.invocation_id.clone()),
        replayed_from_invocation_id: result.replayed_from.clone(),
        error: result.error.as_ref().map(ToString::to_string),
        recorded_invocation: target.recorded_invocation,
        resource_lease_ids: target.resource_lease_ids.clone(),
        compensation_status: target.compensation_status.clone(),
        compensation_id: target.compensation_id.clone(),
    }
}

/// Service-shaped queue drainer for production owners that want a named
/// boundary instead of calling the lower-level queue runtime directly.
pub struct EngineQueueDrainer;

impl EngineQueueDrainer {
    /// Claim and execute one queue item.
    pub async fn drain_once(
        handle: &EngineHostHandle,
        queue: &str,
        lease_owner: &str,
    ) -> Result<Option<InvocationResult>> {
        EngineQueueRuntime::drain_once(handle, queue, lease_owner).await
    }

    /// Claim and execute a specific queue receipt.
    pub async fn drain_receipt(
        handle: &EngineHostHandle,
        receipt_id: &str,
        lease_owner: &str,
    ) -> Result<Option<InvocationResult>> {
        EngineQueueRuntime::drain_receipt(handle, receipt_id, lease_owner).await
    }
}

/// Publish a queue lifecycle event to the engine stream primitive.
pub async fn publish_queue_lifecycle_event(
    handle: &EngineHostHandle,
    event_type: &str,
    item: &EngineQueueItem,
    result: Option<(&InvocationResult, bool)>,
) {
    let _ = handle
        .publish_stream_event(queue_lifecycle_stream_event(event_type, item, result))
        .await;
}

pub(in crate::engine) fn queue_failure_event_type(item: &EngineQueueItem) -> &'static str {
    if item.status == QueueItemStatus::DeadLettered {
        "dead_letter"
    } else {
        "fail"
    }
}

pub(in crate::engine) fn queue_lifecycle_stream_event(
    event_type: &str,
    item: &EngineQueueItem,
    result: Option<(&InvocationResult, bool)>,
) -> PublishStreamEvent {
    let status = match event_type {
        "enqueue" => "ready",
        "claim" => "leased",
        "complete" => "completed",
        "fail" => item.status.as_str(),
        "cancel" => "cancelled",
        "dead_letter" => "dead_lettered",
        _ => item.status.as_str(),
    };
    PublishStreamEvent {
        topic: "queue.lifecycle".to_owned(),
        payload: json!({
            "type": format!("queue.{event_type}"),
            "receiptId": &item.receipt_id,
            "queue": &item.queue,
            "functionId": &item.function_id,
            "status": status,
            "attempts": item.attempts,
            "deliveryInvocationId": result.map(|(value, _)| value.invocation_id.to_string()),
            "resultInvocationId": result.and_then(|(value, recorded)| {
                recorded.then(|| value.invocation_id.to_string())
            }),
            "error": result
                .and_then(|(value, _)| value.error.as_ref())
                .map(ToString::to_string),
            "attemptRecords": &item.attempt_records,
            "lastAttempt": item.attempt_records.last(),
        }),
        visibility: VisibilityScope::Session,
        session_id: item.session_id.clone(),
        workspace_id: item.workspace_id.clone(),
        producer: "queue".to_owned(),
        trace_id: Some(item.trace_id.clone()),
        parent_invocation_id: item.parent_invocation_id.clone(),
    }
}
