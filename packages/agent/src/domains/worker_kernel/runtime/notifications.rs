//! Durable APNs target and quiet-refresh dispatch.

use super::*;
use crate::domains::worker_kernel::notifications::{
    NotificationAcknowledgeRequest, NotificationDeliveriesRequest,
    NotificationDeliveryStatusRequest, NotificationDeviceDisableRequest,
    NotificationDeviceUpsertRequest,
};
use crate::domains::worker_kernel::persistence::NotificationDispatchOutcome;
use serde::Serialize;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct NotificationResponseEvent {
    event_type: &'static str,
    delivery_id: String,
    worker_id: String,
    source_record_id: Option<String>,
    acknowledgement: String,
    occurred_at: String,
    causal_depth: u32,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct NotificationDeliveryLifecycleEvent {
    event_type: &'static str,
    delivery_id: String,
    worker_id: String,
    source_record_id: Option<String>,
    installation_id: String,
    state: &'static str,
    error_code: Option<String>,
    causal_depth: u32,
}

impl WorkerRuntime {
    pub(in crate::domains::worker_kernel) fn notification_device_upsert(
        &self,
        request: NotificationDeviceUpsertRequest,
    ) -> Result<Value, String> {
        let mut response = self.store.notification_device_upsert(request)?;
        response["transport"] = serde_json::to_value(self.notification_transport.readiness())
            .expect("notification transport readiness serializes");
        Ok(response)
    }

    pub(in crate::domains::worker_kernel) fn notification_device_disable(
        &self,
        request: NotificationDeviceDisableRequest,
    ) -> Result<Value, String> {
        self.store.notification_device_disable(request)
    }

    pub(in crate::domains::worker_kernel) fn notification_deliveries(
        &self,
        request: NotificationDeliveriesRequest,
    ) -> Result<Value, String> {
        let mut response = self.store.notification_deliveries(request)?;
        let mode = self.notification_transport.readiness().mode.as_str();
        if let Some(deliveries) = response["deliveries"].as_array_mut() {
            for delivery in deliveries {
                delivery["transportMode"] = Value::String(mode.to_owned());
            }
        }
        Ok(response)
    }

    pub(in crate::domains::worker_kernel) fn notification_delivery_status(
        &self,
        request: NotificationDeliveryStatusRequest,
    ) -> Result<Value, String> {
        let mut response = self.store.notification_delivery_status(request)?;
        response["delivery"]["transportMode"] = Value::String(
            self.notification_transport
                .readiness()
                .mode
                .as_str()
                .to_owned(),
        );
        Ok(response)
    }

    pub(in crate::domains::worker_kernel) fn acknowledge_notification_delivery(
        &self,
        request: NotificationAcknowledgeRequest,
    ) -> Result<Value, String> {
        self.store.acknowledge_notification_delivery(request)
    }

    pub(in crate::domains::worker_kernel) async fn publish_notification_acknowledgement(
        &self,
        response: &Value,
    ) {
        if response["eventRequired"].as_bool().unwrap_or(false) {
            let event = notification_response_event(response);
            self.publish_event(
                "notification.responses",
                serde_json::to_value(event).expect("notification response event serializes"),
                response["traceId"]
                    .as_str()
                    .and_then(|trace_id| TraceId::new(trace_id.to_owned()).ok()),
            )
            .await;
        }
    }

    pub(super) async fn dispatch_notifications(self: &Arc<Self>, runs: &mut JoinSet<()>) {
        let current_revision = self.notification_transport.configuration_revision();
        let mut prior_revision = self.notification_configuration_revision.lock().await;
        if prior_revision.as_deref() != Some(current_revision.as_str()) {
            let _ = self.store.requeue_notification_configuration_blocks();
            *prior_revision = Some(current_revision);
        }
        drop(prior_revision);
        if let Ok(targets) = self.store.claim_notification_targets(32) {
            for target in targets {
                let runtime = Arc::clone(self);
                runs.spawn(async move {
                    let result = runtime.notification_transport.send_alert(&target).await;
                    let transport_kind = result.kind.as_str();
                    let (state, error_code) = outcome_projection(&result.outcome);
                    if let Err(error) = runtime.store.record_notification_target_outcome(
                        &target,
                        transport_kind,
                        result.outcome,
                    ) {
                        tracing::warn!(
                            target_id = %target.target_id,
                            %error,
                            "failed to persist notification target outcome"
                        );
                        return;
                    }
                    runtime
                        .publish_event(
                            "notification.deliveries",
                            serde_json::to_value(NotificationDeliveryLifecycleEvent {
                                event_type: "transport_updated",
                                delivery_id: target.delivery_id,
                                worker_id: target.worker_id,
                                source_record_id: target.source_record_id,
                                installation_id: target.installation_id,
                                state,
                                error_code,
                                causal_depth: 1,
                            })
                            .map(|mut value| {
                                value["transport"] = Value::String(transport_kind.to_owned());
                                value
                            })
                            .expect("notification delivery event serializes"),
                            TraceId::new(target.trace_id).ok(),
                        )
                        .await;
                });
            }
        }
        if let Ok(refreshes) = self.store.claim_notification_refreshes(16) {
            for refresh in refreshes {
                let runtime = Arc::clone(self);
                runs.spawn(async move {
                    let result = runtime.notification_transport.send_refresh(&refresh).await;
                    let transport_kind = result.kind.as_str();
                    if let Err(error) = runtime.store.record_notification_refresh_outcome(
                        &refresh,
                        transport_kind,
                        result.outcome,
                    ) {
                        tracing::warn!(
                            refresh_id = %refresh.refresh_id,
                            %error,
                            "failed to persist notification refresh outcome"
                        );
                    }
                });
            }
        }
        let tick = self
            .notification_maintenance_ticks
            .fetch_add(1, Ordering::Relaxed);
        if tick.is_multiple_of(60) {
            let _ = self.store.maintain_notification_history();
        }
    }
}

fn notification_response_event(response: &Value) -> NotificationResponseEvent {
    NotificationResponseEvent {
        event_type: "terminal_response",
        delivery_id: response["deliveryId"]
            .as_str()
            .unwrap_or_default()
            .to_owned(),
        worker_id: response["workerId"].as_str().unwrap_or_default().to_owned(),
        source_record_id: response["sourceRecordId"].as_str().map(ToOwned::to_owned),
        acknowledgement: response["acknowledgement"]
            .as_str()
            .unwrap_or_default()
            .to_owned(),
        occurred_at: response["occurredAt"]
            .as_str()
            .unwrap_or_default()
            .to_owned(),
        causal_depth: 1,
    }
}

fn outcome_projection(outcome: &NotificationDispatchOutcome) -> (&'static str, Option<String>) {
    match outcome {
        NotificationDispatchOutcome::Accepted { .. } => ("accepted_by_apns", None),
        NotificationDispatchOutcome::Retryable { code, .. } => ("retry_wait", Some(code.clone())),
        NotificationDispatchOutcome::Permanent { code, .. } => {
            ("permanent_failure", Some(code.clone()))
        }
        NotificationDispatchOutcome::Blocked { code, .. } => ("blocked", Some(code.clone())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn apns_acceptance_is_not_projected_as_human_delivery() {
        let outcome = NotificationDispatchOutcome::Accepted {
            apns_id: "provider-id".to_owned(),
        };
        assert_eq!(outcome_projection(&outcome), ("accepted_by_apns", None));
    }

    #[test]
    fn response_event_preserves_the_worker_trigger_action_default() {
        let payload = serde_json::to_value(notification_response_event(&json!({
            "deliveryId":"notification_1",
            "workerId":"automation-reminders",
            "sourceRecordId":"occurrence_1",
            "acknowledgement":"opened",
            "occurredAt":"2026-07-25T12:00:00Z",
        })))
        .unwrap();
        assert!(payload.get("action").is_none());
        let projected = materialize_engine_event_input(
            &json!({"action":"notification_response"}),
            &payload,
            &json!({
                "type":"object",
                "properties":{
                    "action":{"type":"string"},
                    "acknowledgement":{"type":"string"},
                    "sourceRecordId":{"type":"string"}
                }
            }),
        );
        assert_eq!(projected["action"], "notification_response");
        assert_eq!(projected["acknowledgement"], "opened");
        assert_eq!(projected["sourceRecordId"], "occurrence_1");
    }
}
