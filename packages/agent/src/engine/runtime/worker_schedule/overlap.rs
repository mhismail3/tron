//! Active tick evidence helpers for worker schedule dispatch.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::contracts::{
    ActiveTickEvidence, ScheduleTickPayload, current_payload, ensure_resource_kind,
    is_terminal_process_status, target_idempotency_key, trigger_launch_attempt_id,
};
use super::{
    EngineWorkerScheduleRuntime, SCHEDULE_LIST_LIMIT, WORKER_SCHEDULE_TICK_KIND, WorkerSchedulePlan,
};
use crate::engine::durability::queue::QueueItemStatus;
use crate::engine::durability::resources::ListResources;
use crate::engine::kernel::errors::Result;
use crate::engine::runtime::worker_orchestration::{
    WORKER_PROCESS_KIND, WORKER_TRIGGER_LAUNCH_ATTEMPT_KIND,
};

impl EngineWorkerScheduleRuntime {
    pub(super) async fn active_prior_tick(
        &self,
        plan: &WorkerSchedulePlan,
        current_nominal: DateTime<Utc>,
    ) -> Result<Option<ActiveTickEvidence>> {
        let mut latest_active = None;
        for tick in self.tick_payloads_for_schedule(&plan.schedule_id).await? {
            if tick.nominal_tick_at_utc >= current_nominal {
                continue;
            }
            if let Some(evidence) = self.tick_is_active(plan, &tick).await? {
                latest_active = Some(ActiveTickEvidence {
                    tick_resource_id: tick.tick_resource_id,
                    nominal_tick_at_utc: tick.nominal_tick_at_utc,
                    evidence,
                });
            }
        }
        Ok(latest_active)
    }

    async fn tick_is_active(
        &self,
        plan: &WorkerSchedulePlan,
        tick: &ScheduleTickPayload,
    ) -> Result<Option<Value>> {
        match tick.status.as_str() {
            "requested" => {
                return Ok(Some(
                    json!({"source": "tick_status", "status": tick.status}),
                ));
            }
            "enqueued" => {}
            _ => return Ok(None),
        }

        let Some(receipt_id) = tick.queue_receipt_id.as_deref() else {
            return Ok(Some(json!({"source": "missing_queue_receipt"})));
        };
        let Some(queue_item) = self.host.get_queue_item(receipt_id).await? else {
            return Ok(Some(
                json!({"source": "missing_queue_item", "receiptId": receipt_id}),
            ));
        };
        if matches!(
            queue_item.status,
            QueueItemStatus::Ready | QueueItemStatus::Leased
        ) {
            return Ok(Some(json!({
                "source": "queue",
                "receiptId": receipt_id,
                "queueStatus": format!("{:?}", queue_item.status),
            })));
        }
        if queue_item.status != QueueItemStatus::Completed {
            return Ok(None);
        }

        let target_key = target_idempotency_key(&plan.schedule_id, tick.nominal_tick_at_utc);
        let attempt_id = trigger_launch_attempt_id(
            &plan.autostart_plan_resource_id,
            &plan.trigger_id,
            &target_key,
        );
        let Some(attempt) = self.host.inspect_resource(&attempt_id).await? else {
            return Ok(Some(json!({
                "source": "completed_queue_missing_attempt",
                "receiptId": receipt_id,
            })));
        };
        ensure_resource_kind(&attempt, WORKER_TRIGGER_LAUNCH_ATTEMPT_KIND)?;
        let attempt_payload = current_payload(&attempt)?;
        let Some(process_id) = attempt_payload
            .get("workerProcessResourceId")
            .and_then(Value::as_str)
        else {
            return Ok(Some(json!({
                "source": "attempt_without_process",
                "attemptResourceId": attempt_id,
            })));
        };
        let Some(process) = self.host.inspect_resource(process_id).await? else {
            return Ok(Some(json!({
                "source": "missing_process",
                "workerProcessResourceId": process_id,
            })));
        };
        ensure_resource_kind(&process, WORKER_PROCESS_KIND)?;
        if is_terminal_process_status(&process.resource.lifecycle) {
            Ok(None)
        } else {
            Ok(Some(json!({
                "source": "process",
                "workerProcessResourceId": process_id,
                "processStatus": process.resource.lifecycle,
            })))
        }
    }

    async fn tick_payloads_for_schedule(
        &self,
        schedule_id: &str,
    ) -> Result<Vec<ScheduleTickPayload>> {
        let resources = self
            .host
            .list_resources(ListResources {
                kind: Some(WORKER_SCHEDULE_TICK_KIND.to_owned()),
                limit: SCHEDULE_LIST_LIMIT,
                ..ListResources::default()
            })
            .await?;
        let mut ticks = Vec::new();
        for resource in resources {
            let Some(inspection) = self.host.inspect_resource(&resource.resource_id).await? else {
                continue;
            };
            let payload = current_payload(&inspection)?;
            if payload.get("scheduleId").and_then(Value::as_str) != Some(schedule_id) {
                continue;
            }
            if let Some(tick) = ScheduleTickPayload::from_payload(&resource.resource_id, payload)? {
                ticks.push(tick);
            }
        }
        ticks.sort_by_key(|tick| tick.nominal_tick_at_utc);
        Ok(ticks)
    }
}
