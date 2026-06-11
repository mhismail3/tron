//! Governed worker schedule dispatch runtime module.
//!
//! Schedules do not launch workers. They compute due UTC fixed-interval ticks,
//! persist a safe tick audit resource, and invoke the trusted `trigger::dispatch`
//! primitive with enqueue delivery and deterministic target idempotency.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::worker_orchestration::WORKER_AUTOSTART_PLAN_SCHEMA_ID;
use super::worker_orchestration::contracts::{AutostartPlan, LaunchPlan};
use crate::engine::catalog::discovery::ActorKind;
use crate::engine::durability::resources::{
    CreateResource, EngineResource, EngineResourceInspection, EngineResourceVersion, ListResources,
    UpdateResource,
};
use crate::engine::invocation::host::EngineHostHandle;
use crate::engine::invocation::model::CausalContext;
use crate::engine::invocation::model::Invocation;
use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::ids::{
    ActorId, AuthorityGrantId, FunctionId, InvocationId, TraceId, WorkerId,
};
use crate::engine::kernel::types::DeliveryMode;
use crate::engine::primitives::WORKER_WORKER_ID;
use crate::engine::runtime::worker_orchestration::{
    WORKER_AUTOSTART_PLAN_KIND, WORKER_LAUNCH_PLAN_KIND, WORKER_LAUNCH_PLAN_SCHEMA_ID,
};
use crate::engine::{AcquireResourceLease, EngineGrantLifecycle, EngineResourceLease};

mod contracts;
mod overlap;

pub use contracts::WorkerScheduleDispatchSummary;
use contracts::*;

/// Built-in resource kind for reviewed worker schedule plans.
pub const WORKER_SCHEDULE_PLAN_KIND: &str = "worker_schedule_plan";
/// Schema id for reviewed worker schedule plans.
pub const WORKER_SCHEDULE_PLAN_SCHEMA_ID: &str = "tron.resource.worker_schedule_plan.v1";
/// Built-in resource kind for schedule tick audit records.
pub const WORKER_SCHEDULE_TICK_KIND: &str = "worker_schedule_tick";
/// Schema id for schedule tick audit records.
pub const WORKER_SCHEDULE_TICK_SCHEMA_ID: &str = "tron.resource.worker_schedule_tick.v1";

const LAUNCH_FROM_TRIGGER_FUNCTION: &str = "worker::launch_from_trigger";
const TRIGGER_DISPATCH_FUNCTION: &str = "trigger::dispatch";
const STDIN_BUNDLE_DELIVERY_MODE: &str = "stdin_activation_bundle_v1";
const MIN_INTERVAL_MS: u64 = 60_000;
const MAX_INTERVAL_MS: u64 = 86_400_000;
const SCHEDULE_LIST_LIMIT: usize = 500;
const SCHEDULER_LEASE_TTL_MS: i64 = 55_000;

/// Engine-owned schedule dispatcher.
#[derive(Clone)]
pub struct EngineWorkerScheduleRuntime {
    host: EngineHostHandle,
}

impl EngineWorkerScheduleRuntime {
    /// Create a schedule runtime over an engine host.
    #[must_use]
    pub fn new(host: EngineHostHandle) -> Self {
        Self { host }
    }

    /// Dispatch every reviewed schedule that has a due tick at `now`.
    pub async fn dispatch_due_once(
        &self,
        now: DateTime<Utc>,
    ) -> Result<WorkerScheduleDispatchSummary> {
        let resources = self
            .host
            .list_resources(ListResources {
                kind: Some(WORKER_SCHEDULE_PLAN_KIND.to_owned()),
                lifecycle: Some("reviewed".to_owned()),
                limit: SCHEDULE_LIST_LIMIT,
                ..ListResources::default()
            })
            .await?;
        let mut summary = WorkerScheduleDispatchSummary::default();
        for resource in resources {
            summary.reviewed += 1;
            match self.dispatch_resource_due_tick(&resource, now).await {
                Ok(Some(outcome)) => {
                    summary.due += 1;
                    match outcome {
                        "enqueued" => summary.enqueued += 1,
                        "replayed" => summary.replayed += 1,
                        "skipped_missed" => summary.skipped_missed += 1,
                        "skipped_overlap" => summary.skipped_overlap += 1,
                        "failed" => summary.failed += 1,
                        _ => {}
                    }
                }
                Ok(None) => {}
                Err(error) => {
                    summary.failed += 1;
                    tracing::warn!(
                        schedule_resource_id = %resource.resource_id,
                        error = %error,
                        "worker schedule dispatch failed closed"
                    );
                }
            }
        }
        Ok(summary)
    }

    /// Dispatch one schedule resource if it has a due tick at `now`.
    pub async fn dispatch_due_for_schedule(
        &self,
        schedule_resource_id: &str,
        now: DateTime<Utc>,
    ) -> Result<Option<Value>> {
        let inspection = self
            .host
            .inspect_resource(schedule_resource_id)
            .await?
            .ok_or_else(|| EngineError::NotFound {
                kind: WORKER_SCHEDULE_PLAN_KIND,
                id: schedule_resource_id.to_owned(),
            })?;
        let Some(outcome) = self
            .dispatch_inspected_schedule_due_tick(&inspection, now)
            .await?
        else {
            return Ok(None);
        };
        Ok(Some(outcome.payload))
    }

    async fn dispatch_resource_due_tick(
        &self,
        resource: &EngineResource,
        now: DateTime<Utc>,
    ) -> Result<Option<&'static str>> {
        let inspection = self
            .host
            .inspect_resource(&resource.resource_id)
            .await?
            .ok_or_else(|| EngineError::NotFound {
                kind: WORKER_SCHEDULE_PLAN_KIND,
                id: resource.resource_id.clone(),
            })?;
        Ok(self
            .dispatch_inspected_schedule_due_tick(&inspection, now)
            .await?
            .map(|outcome| outcome.summary_status))
    }

    async fn dispatch_inspected_schedule_due_tick(
        &self,
        inspection: &EngineResourceInspection,
        now: DateTime<Utc>,
    ) -> Result<Option<TickDispatchOutcome>> {
        let plan = self.load_schedule_plan(inspection).await?;
        let Some(due) = due_tick(&plan, now)? else {
            return Ok(None);
        };
        let latest_tick_id = tick_id(&plan.schedule_id, due.nominal_tick_at_utc);
        if let Some(existing) = self.host.inspect_resource(&latest_tick_id).await? {
            ensure_resource_kind(&existing, WORKER_SCHEDULE_TICK_KIND)?;
            let payload = current_payload(&existing)?.clone();
            let status = payload["status"].as_str().unwrap_or("replayed");
            return Ok(Some(TickDispatchOutcome {
                summary_status: if status == "skipped_overlap" {
                    "skipped_overlap"
                } else {
                    "replayed"
                },
                payload,
            }));
        }

        let trace_id = schedule_trace_id(&plan.schedule_id, due.nominal_tick_at_utc)?;
        let lease = self
            .host
            .acquire_resource_lease(AcquireResourceLease {
                resource_kind: "worker_schedule_dispatch".to_owned(),
                resource_id: plan.schedule_id.clone(),
                holder_invocation_id: InvocationId::generate(),
                function_id: FunctionId::new("worker::schedule_dispatch")?,
                actor_id: ActorId::new("worker-scheduler")?,
                authority_grant_id: AuthorityGrantId::new("engine-system")?,
                trace_id: trace_id.clone(),
                parent_invocation_id: None,
                idempotency_key: Some(target_idempotency_key(
                    &plan.schedule_id,
                    due.nominal_tick_at_utc,
                )),
                ttl_ms: SCHEDULER_LEASE_TTL_MS,
            })
            .await?;
        let result = self
            .dispatch_due_tick_with_lease(&plan, due, inspection, trace_id, &lease)
            .await;
        let release = self.host.release_resource_lease(&lease.lease_id).await;
        match (result, release) {
            (Ok(value), Ok(_)) => Ok(value),
            (Err(error), Ok(_)) => Err(error),
            (Ok(_), Err(error)) | (Err(_), Err(error)) => Err(error),
        }
    }

    async fn dispatch_due_tick_with_lease(
        &self,
        plan: &WorkerSchedulePlan,
        due: DueTick,
        schedule_inspection: &EngineResourceInspection,
        trace_id: TraceId,
        lease: &EngineResourceLease,
    ) -> Result<Option<TickDispatchOutcome>> {
        let latest_tick_id = tick_id(&plan.schedule_id, due.nominal_tick_at_utc);
        if let Some(existing) = self.host.inspect_resource(&latest_tick_id).await? {
            ensure_resource_kind(&existing, WORKER_SCHEDULE_TICK_KIND)?;
            return Ok(Some(TickDispatchOutcome {
                summary_status: "replayed",
                payload: current_payload(&existing)?.clone(),
            }));
        }

        if let Some(active) = self
            .active_prior_tick(plan, due.nominal_tick_at_utc)
            .await?
        {
            let payload = tick_payload(TickPayloadInput {
                status: "skipped_overlap",
                tick_id: &latest_tick_id,
                plan,
                nominal_tick_at_utc: due.nominal_tick_at_utc,
                trace_id: &trace_id,
                queue_receipt_id: None,
                trigger_dispatch_invocation_id: None,
                target_idempotency_key: &target_idempotency_key(
                    &plan.schedule_id,
                    due.nominal_tick_at_utc,
                ),
                lease_id: Some(&lease.lease_id),
                missed: None,
                overlap: Some(json!({
                    "activeTickResourceId": active.tick_resource_id,
                    "activeNominalTickAtUtc": active.nominal_tick_at_utc.to_rfc3339(),
                    "evidence": active.evidence,
                })),
                error: None,
            });
            self.create_tick(
                &latest_tick_id,
                schedule_inspection,
                "skipped_overlap",
                payload.clone(),
                &trace_id,
                None,
            )
            .await?;
            return Ok(Some(TickDispatchOutcome {
                summary_status: "skipped_overlap",
                payload,
            }));
        }

        if due.missed_tick_count > 0
            && let Some(skipped_nominal) = due.skipped_nominal_tick_at_utc
        {
            let skipped_id = tick_id(&plan.schedule_id, skipped_nominal);
            if self.host.inspect_resource(&skipped_id).await?.is_none() {
                let payload = tick_payload(TickPayloadInput {
                    status: "skipped_missed",
                    tick_id: &skipped_id,
                    plan,
                    nominal_tick_at_utc: skipped_nominal,
                    trace_id: &trace_id,
                    queue_receipt_id: None,
                    trigger_dispatch_invocation_id: None,
                    target_idempotency_key: &target_idempotency_key(
                        &plan.schedule_id,
                        skipped_nominal,
                    ),
                    lease_id: Some(&lease.lease_id),
                    missed: Some(json!({
                        "missedTickCount": due.missed_tick_count,
                        "latestDispatchedNominalTickAtUtc": due.nominal_tick_at_utc.to_rfc3339(),
                        "policy": "skip_missed_ticks_v1",
                    })),
                    overlap: None,
                    error: None,
                });
                self.create_tick(
                    &skipped_id,
                    schedule_inspection,
                    "skipped_missed",
                    payload,
                    &trace_id,
                    None,
                )
                .await?;
            }
        }

        let target_key = target_idempotency_key(&plan.schedule_id, due.nominal_tick_at_utc);
        let requested_payload = tick_payload(TickPayloadInput {
            status: "requested",
            tick_id: &latest_tick_id,
            plan,
            nominal_tick_at_utc: due.nominal_tick_at_utc,
            trace_id: &trace_id,
            queue_receipt_id: None,
            trigger_dispatch_invocation_id: None,
            target_idempotency_key: &target_key,
            lease_id: Some(&lease.lease_id),
            missed: None,
            overlap: None,
            error: None,
        });
        self.create_tick(
            &latest_tick_id,
            schedule_inspection,
            "requested",
            requested_payload,
            &trace_id,
            None,
        )
        .await?;

        let dispatch = self
            .dispatch_trigger(plan, due.nominal_tick_at_utc, &target_key, &trace_id)
            .await;
        match dispatch {
            Ok(dispatch) => {
                let payload = tick_payload(TickPayloadInput {
                    status: "enqueued",
                    tick_id: &latest_tick_id,
                    plan,
                    nominal_tick_at_utc: due.nominal_tick_at_utc,
                    trace_id: &trace_id,
                    queue_receipt_id: dispatch.queue_receipt_id.as_deref(),
                    trigger_dispatch_invocation_id: Some(dispatch.invocation_id.as_str()),
                    target_idempotency_key: &target_key,
                    lease_id: Some(&lease.lease_id),
                    missed: None,
                    overlap: None,
                    error: None,
                });
                self.update_tick(&latest_tick_id, "enqueued", payload.clone(), &trace_id)
                    .await?;
                Ok(Some(TickDispatchOutcome {
                    summary_status: "enqueued",
                    payload,
                }))
            }
            Err(error) => {
                let payload = tick_payload(TickPayloadInput {
                    status: "failed",
                    tick_id: &latest_tick_id,
                    plan,
                    nominal_tick_at_utc: due.nominal_tick_at_utc,
                    trace_id: &trace_id,
                    queue_receipt_id: None,
                    trigger_dispatch_invocation_id: None,
                    target_idempotency_key: &target_key,
                    lease_id: Some(&lease.lease_id),
                    missed: None,
                    overlap: None,
                    error: Some(&error),
                });
                self.update_tick(&latest_tick_id, "failed", payload, &trace_id)
                    .await?;
                Err(error)
            }
        }
    }

    async fn load_schedule_plan(
        &self,
        inspection: &EngineResourceInspection,
    ) -> Result<WorkerSchedulePlan> {
        ensure_resource_kind(inspection, WORKER_SCHEDULE_PLAN_KIND)?;
        if inspection.resource.schema_id != WORKER_SCHEDULE_PLAN_SCHEMA_ID {
            return Err(EngineError::PolicyViolation(format!(
                "worker schedule plan {} must use schema {WORKER_SCHEDULE_PLAN_SCHEMA_ID}",
                inspection.resource.resource_id
            )));
        }
        if inspection.resource.lifecycle != "reviewed" {
            return Err(EngineError::PolicyViolation(format!(
                "worker schedule plan {} must be reviewed",
                inspection.resource.resource_id
            )));
        }
        reject_secret_material_in_value(
            "worker schedule plan policy",
            &inspection.resource.policy,
        )?;
        let payload = current_payload(inspection)?;
        reject_secret_material_in_value("worker schedule plan", payload)?;
        let plan = WorkerSchedulePlan::from_payload(&inspection.resource, payload)?;
        self.validate_schedule_binding(&plan, inspection).await?;
        Ok(plan)
    }

    async fn validate_schedule_binding(
        &self,
        plan: &WorkerSchedulePlan,
        inspection: &EngineResourceInspection,
    ) -> Result<()> {
        let trigger = self.host.inspect_trigger(&plan.trigger_id).await?;
        if trigger.target_function.as_str() != LAUNCH_FROM_TRIGGER_FUNCTION {
            return Err(EngineError::PolicyViolation(format!(
                "worker schedule trigger {} must target {LAUNCH_FROM_TRIGGER_FUNCTION}",
                plan.trigger_id
            )));
        }
        if trigger.delivery_mode != DeliveryMode::Enqueue {
            return Err(EngineError::PolicyViolation(format!(
                "worker schedule trigger {} must use enqueue delivery",
                plan.trigger_id
            )));
        }
        reject_secret_material_in_value("worker schedule trigger config", &trigger.config)?;
        let trigger_grant = self
            .host
            .inspect_authority_grant(&trigger.authority_grant)
            .await?
            .ok_or_else(|| {
                EngineError::PolicyViolation(format!(
                    "worker schedule trigger {} authority grant {} not found",
                    plan.trigger_id, trigger.authority_grant
                ))
            })?;
        if trigger_grant.lifecycle != EngineGrantLifecycle::Active {
            return Err(EngineError::PolicyViolation(format!(
                "worker schedule trigger {} authority grant {} is not active",
                plan.trigger_id, trigger.authority_grant
            )));
        }

        let autostart_inspection = self
            .host
            .inspect_resource(&plan.autostart_plan_resource_id)
            .await?
            .ok_or_else(|| EngineError::NotFound {
                kind: WORKER_AUTOSTART_PLAN_KIND,
                id: plan.autostart_plan_resource_id.clone(),
            })?;
        ensure_resource_kind(&autostart_inspection, WORKER_AUTOSTART_PLAN_KIND)?;
        reject_secret_material_in_value(
            "worker schedule autostart plan policy",
            &autostart_inspection.resource.policy,
        )?;
        if autostart_inspection.resource.schema_id != WORKER_AUTOSTART_PLAN_SCHEMA_ID {
            return Err(EngineError::PolicyViolation(format!(
                "worker autostart plan {} must use schema {WORKER_AUTOSTART_PLAN_SCHEMA_ID}",
                plan.autostart_plan_resource_id
            )));
        }
        if autostart_inspection.resource.lifecycle != "reviewed" {
            return Err(EngineError::PolicyViolation(format!(
                "worker autostart plan {} must be reviewed",
                plan.autostart_plan_resource_id
            )));
        }
        let autostart_payload = current_payload(&autostart_inspection)?;
        reject_secret_material_in_value("worker schedule autostart plan", autostart_payload)?;
        let autostart =
            AutostartPlan::from_payload(&plan.autostart_plan_resource_id, autostart_payload)?;
        if autostart.trigger_id != plan.trigger_id {
            return Err(EngineError::PolicyViolation(
                "worker schedule triggerId must match autostart triggerId".to_owned(),
            ));
        }

        let launch_plan_inspection = self
            .host
            .inspect_resource(&autostart.launch_plan_resource_id)
            .await?
            .ok_or_else(|| EngineError::NotFound {
                kind: WORKER_LAUNCH_PLAN_KIND,
                id: autostart.launch_plan_resource_id.clone(),
            })?;
        ensure_resource_kind(&launch_plan_inspection, WORKER_LAUNCH_PLAN_KIND)?;
        reject_secret_material_in_value(
            "worker schedule launch plan policy",
            &launch_plan_inspection.resource.policy,
        )?;
        if launch_plan_inspection.resource.schema_id != WORKER_LAUNCH_PLAN_SCHEMA_ID {
            return Err(EngineError::PolicyViolation(format!(
                "worker launch plan {} must use schema {WORKER_LAUNCH_PLAN_SCHEMA_ID}",
                autostart.launch_plan_resource_id
            )));
        }
        if launch_plan_inspection.resource.lifecycle != "reviewed" {
            return Err(EngineError::PolicyViolation(format!(
                "worker launch plan {} must be reviewed",
                autostart.launch_plan_resource_id
            )));
        }
        let launch_payload = current_payload(&launch_plan_inspection)?;
        reject_secret_material_in_value("worker schedule launch plan", launch_payload)?;
        let launch_plan =
            LaunchPlan::from_payload(&autostart.launch_plan_resource_id, launch_payload)?;
        validate_autostart_launch_plan(&autostart, &launch_plan, &inspection.resource.scope)?;
        Ok(())
    }

    async fn dispatch_trigger(
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

    async fn create_tick(
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

    async fn update_tick(
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
