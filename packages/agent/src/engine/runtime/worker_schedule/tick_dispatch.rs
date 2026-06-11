//! Trigger enqueue and tick resource mutation helpers for worker schedules.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::contracts::{TriggerDispatchAudit, WorkerSchedulePlan, short_hash};
use super::{
    EngineWorkerScheduleRuntime, TRIGGER_DISPATCH_FUNCTION, WORKER_SCHEDULE_TICK_KIND,
    WORKER_SCHEDULE_TICK_SCHEMA_ID,
};
use crate::engine::catalog::discovery::ActorKind;
use crate::engine::durability::resources::{
    CreateResource, EngineResourceInspection, EngineResourceVersion, UpdateResource,
};
use crate::engine::invocation::model::{CausalContext, Invocation};
use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::ids::{
    ActorId, AuthorityGrantId, FunctionId, InvocationId, TraceId, WorkerId,
};
use crate::engine::primitives::WORKER_WORKER_ID;

impl EngineWorkerScheduleRuntime {
    pub(super) async fn dispatch_trigger(
        &self,
        plan: &WorkerSchedulePlan,
        nominal_tick_at_utc: DateTime<Utc>,
        target_key: &str,
        trace_id: &TraceId,
    ) -> Result<TriggerDispatchAudit> {
        let mut context = CausalContext::new(
            ActorId::new("worker-scheduler")?,
            ActorKind::System,
            AuthorityGrantId::new("engine-system")?,
            trace_id.clone(),
        )
        .with_scope(crate::engine::ENGINE_INTERNAL_INVOKE_SCOPE)
        .with_scope("worker.schedule")
        .with_scope("trigger.dispatch")
        .with_scope("worker.activate")
        .with_scope("worker.launch")
        .with_idempotency_key(format!(
            "saawsd:dispatch:{}:{}",
            short_hash(&plan.schedule_id),
            short_hash(&nominal_tick_at_utc.to_rfc3339())
        ));
        if let Some(session_id) = plan.session_id.as_deref() {
            context = context.with_session_id(session_id.to_owned());
        }
        if let Some(workspace_id) = plan.workspace_id.as_deref() {
            context = context.with_workspace_id(workspace_id.to_owned());
        }

        let result = self
            .host
            .invoke(Invocation::new_sync(
                FunctionId::new(TRIGGER_DISPATCH_FUNCTION)?,
                json!({
                    "triggerId": plan.trigger_id.as_str(),
                    "payload": {
                        "autostartPlanResourceId": plan.autostart_plan_resource_id,
                        "launchReason": "scheduled worker tick"
                    },
                    "deliveryMode": "enqueue",
                    "targetIdempotencyKey": target_key,
                }),
                context,
            ))
            .await;
        if let Some(error) = result.error {
            return Err(error);
        }
        let value = result.value.unwrap_or(Value::Null);
        if value.get("queued").and_then(Value::as_bool) != Some(true) {
            return Err(EngineError::HandlerFailed(
                "scheduled trigger dispatch did not enqueue".to_owned(),
            ));
        }
        Ok(TriggerDispatchAudit {
            invocation_id: result.invocation_id,
            queue_receipt_id: value
                .get("receiptId")
                .and_then(Value::as_str)
                .map(str::to_owned),
        })
    }

    pub(super) async fn create_tick(
        &self,
        tick_id: &str,
        schedule_inspection: &EngineResourceInspection,
        lifecycle: &str,
        payload: Value,
        trace_id: &TraceId,
        invocation_id: Option<InvocationId>,
    ) -> Result<()> {
        match self
            .host
            .create_resource(CreateResource {
                resource_id: Some(tick_id.to_owned()),
                kind: WORKER_SCHEDULE_TICK_KIND.to_owned(),
                schema_id: Some(WORKER_SCHEDULE_TICK_SCHEMA_ID.to_owned()),
                scope: schedule_inspection.resource.scope.clone(),
                owner_worker_id: WorkerId::new(WORKER_WORKER_ID)?,
                owner_actor_id: ActorId::new("worker-scheduler")?,
                lifecycle: Some(lifecycle.to_owned()),
                policy: json!({
                    "deliveryMode": "enqueue",
                    "tickIdempotency": "schedule_id_nominal_utc_v1",
                    "duplicatePolicy": "tick_idempotency_replay_v1",
                    "secretStorage": "no_activation_bundle_or_stdin_payload"
                }),
                initial_payload: Some(payload),
                locations: Vec::new(),
                trace_id: trace_id.clone(),
                invocation_id,
            })
            .await
        {
            Ok(_) => Ok(()),
            Err(error) if error.to_string().contains("already exists") => Ok(()),
            Err(error) => Err(error),
        }
    }

    pub(super) async fn update_tick(
        &self,
        tick_id: &str,
        lifecycle: &str,
        payload: Value,
        trace_id: &TraceId,
    ) -> Result<EngineResourceVersion> {
        let inspection =
            self.host
                .inspect_resource(tick_id)
                .await?
                .ok_or_else(|| EngineError::NotFound {
                    kind: WORKER_SCHEDULE_TICK_KIND,
                    id: tick_id.to_owned(),
                })?;
        self.host
            .update_resource(UpdateResource {
                resource_id: tick_id.to_owned(),
                expected_current_version_id: inspection.resource.current_version_id,
                lifecycle: Some(lifecycle.to_owned()),
                payload,
                state: None,
                locations: Vec::new(),
                trace_id: trace_id.clone(),
                invocation_id: None,
            })
            .await
    }
}
