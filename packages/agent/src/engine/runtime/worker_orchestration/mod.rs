//! Governed process orchestration for already issued worker activations.
//!
//! This runtime owns the local process-supervision boundary only. It does not
//! create schedules, provider-visible tools, public `/engine` launch methods, or
//! restart loops. Trigger-created launch is a thin internal bridge over reviewed
//! autostart plans, fresh activation issue, and the same stdin launch path. A
//! launched process remains non-routable until the existing external-worker
//! runtime accepts its SAAWA hello and exact function registration.

use std::path::PathBuf;
use std::time::Duration as StdDuration;

use chrono::Utc;
use serde_json::{Value, json};

use crate::engine::authority::grants::EngineGrantLifecycle;
use crate::engine::durability::resources::{
    CreateResource, EngineResourceInspection, EngineResourceVersion, UpdateResource,
};
use crate::engine::invocation::host::EngineHostHandle;
use crate::engine::invocation::model::Invocation;
use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::ids::{AuthorityGrantId, FunctionId, TraceId, WorkerId};
use crate::engine::primitives::WORKER_WORKER_ID;
use crate::engine::runtime::worker_protocol::WorkerRegistrationMode;

pub(in crate::engine::runtime) mod contracts;
mod process_resource;
mod supervisor;
mod trigger_launch;

use contracts::{
    ActivationResource, LaunchActivationRequest, LaunchPlan, StopProcessRequest,
    parse_target_visibility, parse_time, payload_str,
};
use process_resource::{
    ActivationHandoffAudit, RedactedOutput, current_payload, ensure_idempotency,
    ensure_resource_kind, expected_readiness_markers, is_terminal_process_status, launch_env,
    launch_response_from_process, process_handle_from_payload, process_payload,
    process_resource_id, redact_text, scope_ids, validate_activation_for_launch,
    validate_launch_plan_matches_activation,
};
#[cfg(test)]
pub use supervisor::{
    WorkerProcessHandle, WorkerProcessStartResult, WorkerProcessStopResult, WorkerProcessSupervisor,
};
pub use supervisor::{
    WorkerProcessSecretStdin, WorkerProcessStartRequest, WorkerProcessSupervisorRegistry,
};

/// Built-in resource kind for reviewed local process launch plans.
pub const WORKER_LAUNCH_PLAN_KIND: &str = "worker_launch_plan";
/// Schema id for reviewed local process launch plans.
pub const WORKER_LAUNCH_PLAN_SCHEMA_ID: &str = "tron.resource.worker_launch_plan.v1";
/// Built-in resource kind for process lifecycle audit.
pub const WORKER_PROCESS_KIND: &str = "worker_process";
/// Schema id for process lifecycle audit.
pub const WORKER_PROCESS_SCHEMA_ID: &str = "tron.resource.worker_process.v1";
/// Built-in resource kind for trigger-created worker launch attempts.
pub const WORKER_TRIGGER_LAUNCH_ATTEMPT_KIND: &str = "worker_trigger_launch_attempt";
/// Schema id for trigger-created worker launch attempts.
pub const WORKER_TRIGGER_LAUNCH_ATTEMPT_SCHEMA_ID: &str =
    "tron.resource.worker_trigger_launch_attempt.v1";
/// Built-in resource kind for reviewed trigger autostart plans.
pub const WORKER_AUTOSTART_PLAN_KIND: &str = "worker_autostart_plan";
/// Schema id for reviewed trigger autostart plans.
pub const WORKER_AUTOSTART_PLAN_SCHEMA_ID: &str = "tron.resource.worker_autostart_plan.v1";

const WORKER_ACTIVATION_KIND: &str = "worker_activation";
const PREISSUED_BUNDLE_DELIVERY_MODE: &str = "preissued_bundle";
const STDIN_BUNDLE_DELIVERY_MODE: &str = "stdin_activation_bundle_v1";
const DEFAULT_STARTUP_TIMEOUT_MS: u64 = 10_000;
const DEFAULT_STOP_TIMEOUT_MS: u64 = 5_000;
const MAX_STARTUP_TIMEOUT_MS: u64 = 60_000;
const MAX_STOP_TIMEOUT_MS: u64 = 30_000;
const MAX_LOG_CAPTURE_BYTES: u64 = 32 * 1024;

/// Runtime facade used by primitives and external-worker readiness callbacks.
#[derive(Clone)]
pub struct EngineWorkerOrchestrationRuntime {
    host: EngineHostHandle,
    supervisor_registry: WorkerProcessSupervisorRegistry,
}

impl EngineWorkerOrchestrationRuntime {
    /// Create an orchestration runtime over an engine host and supervisor set.
    #[must_use]
    pub fn new(
        host: EngineHostHandle,
        supervisor_registry: WorkerProcessSupervisorRegistry,
    ) -> Self {
        Self {
            host,
            supervisor_registry,
        }
    }

    /// Launch a reviewed local process for an already issued activation.
    pub async fn launch_activation(&self, invocation: Invocation) -> Result<Value> {
        ensure_idempotency(&invocation, "worker::launch_activation")?;
        let request = LaunchActivationRequest::from_invocation(&invocation)?;
        let activation = self
            .load_activation(&request.activation_resource_id)
            .await?;
        let plan = self
            .load_launch_plan(&request.launch_plan_resource_id)
            .await?;
        validate_activation_for_launch(&activation)?;
        self.validate_activation_grant(&activation).await?;
        validate_launch_plan_matches_activation(&plan, &activation)?;
        let startup_timeout_ms = request
            .startup_timeout_ms
            .unwrap_or(plan.startup_timeout_ms)
            .min(plan.startup_timeout_ms);
        let process_resource_id = process_resource_id(
            &request.activation_resource_id,
            &request.launch_plan_resource_id,
            &request.idempotency_key,
        );
        if let Some(existing) = self.host.inspect_resource(&process_resource_id).await? {
            return launch_response_from_process(&existing, &activation, &plan);
        }

        let initial_payload = process_payload(
            "requested",
            &process_resource_id,
            &activation,
            &plan,
            &request,
            None,
            RedactedOutput::empty(plan.max_log_capture_bytes),
            None,
            None,
        );
        self.host
            .create_resource(CreateResource {
                resource_id: Some(process_resource_id.clone()),
                kind: WORKER_PROCESS_KIND.to_owned(),
                schema_id: Some(WORKER_PROCESS_SCHEMA_ID.to_owned()),
                scope: activation.resource.scope.clone(),
                owner_worker_id: WorkerId::new(WORKER_WORKER_ID)?,
                owner_actor_id: invocation.causal_context.actor_id.clone(),
                lifecycle: Some("requested".to_owned()),
                policy: json!({
                    "directExecOnly": true,
                    "restartPolicy": "none",
                    "tokenStorage": "not_persisted",
                    "logRedaction": "secret_line_elision"
                }),
                initial_payload: Some(initial_payload),
                locations: Vec::new(),
                trace_id: invocation.causal_context.trace_id.clone(),
                invocation_id: Some(invocation.id.clone()),
            })
            .await?;
        self.publish_process_event(
            "worker.process_requested",
            &activation,
            &process_resource_id,
            Some("launch requested"),
        )
        .await?;

        self.link_process_on_activation(&activation, &process_resource_id, &invocation)
            .await?;

        let secret_stdin = if plan.activation_delivery_mode == STDIN_BUNDLE_DELIVERY_MODE {
            let metadata = self
                .host
                .worker_activation_bundle_metadata_for_test(&request.activation_resource_id)
                .await?
                .ok_or_else(|| {
                    EngineError::PolicyViolation(format!(
                        "activation bundle {} is missing, expired, or already consumed",
                        request.activation_resource_id
                    ))
                })?;
            validate_vault_metadata_matches_activation(&metadata, &activation)?;
            let consumed = self
                .host
                .consume_worker_activation_bundle(&request.activation_resource_id)
                .await?;
            validate_vault_metadata_matches_activation(&consumed.metadata, &activation)?;
            Some(WorkerProcessSecretStdin {
                bytes: consumed.stdin_bytes,
                fingerprint: consumed.metadata.bundle_fingerprint,
                byte_count: consumed.metadata.bundle_byte_count,
            })
        } else {
            None
        };
        let handoff_audit = secret_stdin
            .as_ref()
            .map(ActivationHandoffAudit::from_secret_stdin);
        let start_request = WorkerProcessStartRequest {
            process_resource_id: process_resource_id.clone(),
            executable_path: PathBuf::from(&plan.executable_path),
            argv: plan.argv.clone(),
            env: launch_env(&plan, &activation),
            cwd: plan.cwd.as_ref().map(PathBuf::from),
            startup_timeout: StdDuration::from_millis(startup_timeout_ms),
            stop_timeout: StdDuration::from_millis(plan.stop_timeout_ms),
            max_log_capture_bytes: plan.max_log_capture_bytes as usize,
            secret_stdin,
        };
        let start_result = self
            .supervisor_registry
            .supervisor()
            .start(start_request)
            .await;
        match start_result {
            Ok(started) => {
                let inspection = self.require_process(&process_resource_id).await?;
                let payload = process_payload(
                    "starting",
                    &process_resource_id,
                    &activation,
                    &plan,
                    &request,
                    Some(started.handle.clone()),
                    RedactedOutput::from_start_result(&started, plan.max_log_capture_bytes),
                    handoff_audit.clone(),
                    None,
                );
                self.update_process(&inspection, "starting", payload, Some(&invocation))
                    .await?;
                self.publish_process_event(
                    "worker.process_starting",
                    &activation,
                    &process_resource_id,
                    Some("process started; waiting for SAAWA hello"),
                )
                .await?;
                Ok(json!({
                    "workerProcessResourceId": process_resource_id,
                    "activationResourceId": request.activation_resource_id,
                    "workerId": activation.worker_id.as_str(),
                    "functionId": activation.function_id.as_str(),
                    "launchStatus": "starting",
                    "processHandle": started.handle,
                    "expectedReadinessMarkers": expected_readiness_markers(&activation),
                }))
            }
            Err(error) => {
                let inspection = self.require_process(&process_resource_id).await?;
                let payload = process_payload(
                    "failed",
                    &process_resource_id,
                    &activation,
                    &plan,
                    &request,
                    None,
                    RedactedOutput::empty(plan.max_log_capture_bytes),
                    handoff_audit,
                    Some(redact_text(
                        &error.to_string(),
                        plan.max_log_capture_bytes as usize,
                    )),
                );
                self.update_process(&inspection, "failed", payload, Some(&invocation))
                    .await?;
                Err(error)
            }
        }
    }

    /// Stop a launched process. Stopped/missing terminal processes replay safely.
    pub async fn stop_process(&self, invocation: Invocation) -> Result<Value> {
        ensure_idempotency(&invocation, "worker::stop_process")?;
        let request = StopProcessRequest::from_invocation(&invocation)?;
        let Some(inspection) = self
            .host
            .inspect_resource(&request.worker_process_resource_id)
            .await?
        else {
            return Ok(json!({
                "workerProcessResourceId": request.worker_process_resource_id,
                "status": "stopped",
                "terminal": true
            }));
        };
        ensure_resource_kind(&inspection, WORKER_PROCESS_KIND)?;
        let mut payload = current_payload(&inspection)?.clone();
        let status = payload_str(&payload, "status")?.to_owned();
        if is_terminal_process_status(&status) {
            return Ok(json!({
                "workerProcessResourceId": request.worker_process_resource_id,
                "status": status,
                "terminal": true
            }));
        }
        payload["status"] = json!("stopping");
        payload["exit"]["reason"] = json!(request.reason.as_deref().unwrap_or("manual stop"));
        self.update_process(&inspection, "stopping", payload, Some(&invocation))
            .await?;
        let inspection = self
            .require_process(&request.worker_process_resource_id)
            .await?;
        let payload = current_payload(&inspection)?.clone();
        let handle = process_handle_from_payload(&payload)?;
        let stop_timeout_ms = payload["launch"]["stopTimeoutMs"]
            .as_u64()
            .unwrap_or(DEFAULT_STOP_TIMEOUT_MS);
        let stopped = self
            .supervisor_registry
            .supervisor()
            .stop(handle, StdDuration::from_millis(stop_timeout_ms))
            .await?;
        let status = stopped.status.clone();
        let max_log_capture_bytes = payload["launch"]["maxLogCaptureBytes"]
            .as_u64()
            .unwrap_or(MAX_LOG_CAPTURE_BYTES);
        let mut payload = payload;
        payload["status"] = json!(status);
        payload["logs"] = RedactedOutput::from_stop_result(&stopped, max_log_capture_bytes).json();
        payload["exit"] = json!({
            "reason": request.reason.unwrap_or_else(|| "manual stop".to_owned()),
            "exitCode": stopped.exit_code,
            "stoppedAt": Utc::now().to_rfc3339(),
        });
        self.update_process(&inspection, &status, payload.clone(), Some(&invocation))
            .await?;
        if let Some(worker_id) = payload["workerId"].as_str() {
            self.unregister_worker_if_present(worker_id).await?;
        }
        if let Some(activation_resource_id) = payload["activationResourceId"].as_str() {
            self.update_activation_process_status(
                activation_resource_id,
                &request.worker_process_resource_id,
                "disconnected",
                Some("worker process stopped"),
                Some(&invocation),
            )
            .await?;
        }
        Ok(json!({
            "workerProcessResourceId": request.worker_process_resource_id,
            "status": status,
            "terminal": true
        }))
    }

    /// Mark process audit after accepted SAAWA hello.
    pub async fn mark_hello_seen(
        &self,
        activation_resource_id: &str,
        reason: Option<&str>,
    ) -> Result<()> {
        self.mark_process_for_activation(activation_resource_id, "hello_seen", reason)
            .await
    }

    /// Mark process audit after the exact expected function registers.
    pub async fn mark_ready(
        &self,
        activation_resource_id: &str,
        reason: Option<&str>,
    ) -> Result<()> {
        self.mark_process_for_activation(activation_resource_id, "ready", reason)
            .await
    }

    /// Mark process audit failed/unhealthy for an activation-bound worker.
    pub async fn mark_failed_for_activation(
        &self,
        activation_resource_id: &str,
        status: &str,
        reason: Option<&str>,
    ) -> Result<()> {
        self.mark_process_for_activation(activation_resource_id, status, reason)
            .await
    }

    async fn mark_process_for_activation(
        &self,
        activation_resource_id: &str,
        status: &str,
        reason: Option<&str>,
    ) -> Result<()> {
        let Some(activation) = self.host.inspect_resource(activation_resource_id).await? else {
            return Ok(());
        };
        let activation_payload = current_payload(&activation)?;
        let Some(process_resource_id) = activation_payload
            .get("workerProcessResourceId")
            .and_then(Value::as_str)
        else {
            return Ok(());
        };
        let Some(process) = self.host.inspect_resource(process_resource_id).await? else {
            return Ok(());
        };
        ensure_resource_kind(&process, WORKER_PROCESS_KIND)?;
        let mut payload = current_payload(&process)?.clone();
        if is_terminal_process_status(payload_str(&payload, "status")?) {
            return Ok(());
        }
        payload["status"] = json!(status);
        let now = Utc::now().to_rfc3339();
        match status {
            "hello_seen" => {
                payload["readiness"]["helloSeen"] = json!(true);
                payload["readiness"]["helloSeenAt"] = json!(now);
            }
            "ready" => {
                payload["readiness"]["helloSeen"] = json!(true);
                payload["readiness"]["functionRegistered"] = json!(true);
                payload["readiness"]["readyAt"] = json!(now);
            }
            _ => {
                payload["readiness"]["failureReason"] = json!(reason);
            }
        }
        self.update_process(&process, status, payload, None).await?;
        Ok(())
    }

    async fn load_activation(&self, resource_id: &str) -> Result<ActivationResource> {
        let inspection = self
            .host
            .inspect_resource(resource_id)
            .await?
            .ok_or_else(|| EngineError::NotFound {
                kind: WORKER_ACTIVATION_KIND,
                id: resource_id.to_owned(),
            })?;
        ensure_resource_kind(&inspection, WORKER_ACTIVATION_KIND)?;
        let payload = current_payload(&inspection)?.clone();
        let function_id = FunctionId::new(payload_str(&payload, "functionId")?)?;
        let worker_id = WorkerId::new(payload_str(&payload, "workerId")?)?;
        let target_visibility =
            parse_target_visibility(payload_str(&payload, "targetVisibility")?)?;
        let namespace = function_id.namespace().to_owned();
        let expires_at = parse_time(payload_str(&payload, "expiresAt")?, "activation expiresAt")?;
        let grant_id = payload_str(&payload, "grantId")?.to_owned();
        let registration_mode = match payload_str(&payload, "registrationMode")? {
            "volatile" => WorkerRegistrationMode::Volatile,
            other => {
                return Err(EngineError::PolicyViolation(format!(
                    "activation registration mode {other} is not supported for launch"
                )));
            }
        };
        Ok(ActivationResource {
            resource: inspection.resource,
            payload,
            function_id,
            worker_id,
            target_visibility,
            namespace,
            expires_at,
            grant_id,
            registration_mode,
        })
    }

    async fn load_launch_plan(&self, resource_id: &str) -> Result<LaunchPlan> {
        let inspection = self
            .host
            .inspect_resource(resource_id)
            .await?
            .ok_or_else(|| EngineError::NotFound {
                kind: WORKER_LAUNCH_PLAN_KIND,
                id: resource_id.to_owned(),
            })?;
        ensure_resource_kind(&inspection, WORKER_LAUNCH_PLAN_KIND)?;
        if inspection.resource.schema_id != WORKER_LAUNCH_PLAN_SCHEMA_ID {
            return Err(EngineError::PolicyViolation(format!(
                "worker launch plan {resource_id} must use schema {WORKER_LAUNCH_PLAN_SCHEMA_ID}"
            )));
        }
        if inspection.resource.lifecycle != "reviewed" {
            return Err(EngineError::PolicyViolation(format!(
                "worker launch plan {resource_id} must be reviewed"
            )));
        }
        LaunchPlan::from_payload(resource_id, current_payload(&inspection)?)
    }

    async fn validate_activation_grant(&self, activation: &ActivationResource) -> Result<()> {
        let grant_id = AuthorityGrantId::new(&activation.grant_id)?;
        let grant = self
            .host
            .inspect_authority_grant(&grant_id)
            .await?
            .ok_or_else(|| {
                EngineError::PolicyViolation(format!("activation grant {grant_id} does not exist"))
            })?;
        if grant.lifecycle == EngineGrantLifecycle::Revoked {
            return Err(EngineError::PolicyViolation(format!(
                "activation grant {grant_id} is revoked"
            )));
        }
        if let Some(expires_at) = grant.expires_at
            && expires_at <= Utc::now()
        {
            return Err(EngineError::PolicyViolation(format!(
                "activation grant {grant_id} is expired"
            )));
        }
        Ok(())
    }

    async fn require_process(&self, resource_id: &str) -> Result<EngineResourceInspection> {
        let inspection = self
            .host
            .inspect_resource(resource_id)
            .await?
            .ok_or_else(|| EngineError::NotFound {
                kind: WORKER_PROCESS_KIND,
                id: resource_id.to_owned(),
            })?;
        ensure_resource_kind(&inspection, WORKER_PROCESS_KIND)?;
        Ok(inspection)
    }

    async fn update_process(
        &self,
        inspection: &EngineResourceInspection,
        lifecycle: &str,
        payload: Value,
        invocation: Option<&Invocation>,
    ) -> Result<EngineResourceVersion> {
        self.host
            .update_resource(UpdateResource {
                resource_id: inspection.resource.resource_id.clone(),
                expected_current_version_id: inspection.resource.current_version_id.clone(),
                lifecycle: Some(lifecycle.to_owned()),
                payload,
                state: None,
                locations: Vec::new(),
                trace_id: invocation
                    .map(|invocation| invocation.causal_context.trace_id.clone())
                    .unwrap_or_else(TraceId::generate),
                invocation_id: invocation.map(|invocation| invocation.id.clone()),
            })
            .await
    }

    async fn link_process_on_activation(
        &self,
        activation: &ActivationResource,
        process_resource_id: &str,
        invocation: &Invocation,
    ) -> Result<()> {
        let Some(activation_inspection) = self
            .host
            .inspect_resource(&activation.resource.resource_id)
            .await?
        else {
            return Ok(());
        };
        let mut payload = current_payload(&activation_inspection)?.clone();
        payload["workerProcessResourceId"] = json!(process_resource_id);
        if payload.get("metadata").and_then(Value::as_object).is_none() {
            payload["metadata"] = json!({});
        }
        payload["metadata"]["launch"] = json!({
            "workerProcessResourceId": process_resource_id,
            "linkedAt": Utc::now().to_rfc3339(),
        });
        self.host
            .update_resource(UpdateResource {
                resource_id: activation.resource.resource_id.clone(),
                expected_current_version_id: activation_inspection.resource.current_version_id,
                lifecycle: Some(activation_inspection.resource.lifecycle),
                payload,
                state: None,
                locations: Vec::new(),
                trace_id: invocation.causal_context.trace_id.clone(),
                invocation_id: Some(invocation.id.clone()),
            })
            .await?;
        Ok(())
    }

    async fn update_activation_process_status(
        &self,
        activation_resource_id: &str,
        process_resource_id: &str,
        lifecycle: &str,
        reason: Option<&str>,
        invocation: Option<&Invocation>,
    ) -> Result<()> {
        let Some(activation) = self.host.inspect_resource(activation_resource_id).await? else {
            return Ok(());
        };
        if activation.resource.kind != WORKER_ACTIVATION_KIND {
            return Ok(());
        }
        let mut payload = current_payload(&activation)?.clone();
        payload["status"] = json!(lifecycle);
        payload["workerProcessResourceId"] = json!(process_resource_id);
        if payload.get("metadata").and_then(Value::as_object).is_none() {
            payload["metadata"] = json!({});
        }
        payload["metadata"]["lastProcessEvent"] = json!({
            "workerProcessResourceId": process_resource_id,
            "status": lifecycle,
            "reason": reason,
            "timestamp": Utc::now().to_rfc3339(),
        });
        self.host
            .update_resource(UpdateResource {
                resource_id: activation.resource.resource_id,
                expected_current_version_id: activation.resource.current_version_id,
                lifecycle: Some(lifecycle.to_owned()),
                payload,
                state: None,
                locations: Vec::new(),
                trace_id: invocation
                    .map(|invocation| invocation.causal_context.trace_id.clone())
                    .unwrap_or_else(TraceId::generate),
                invocation_id: invocation.map(|invocation| invocation.id.clone()),
            })
            .await?;
        Ok(())
    }

    async fn unregister_worker_if_present(&self, worker_id: &str) -> Result<()> {
        let worker_id = WorkerId::new(worker_id)?;
        let Ok(worker) = self.host.inspect_worker(&worker_id).await else {
            return Ok(());
        };
        if self.host.worker_is_volatile(&worker_id).await == Some(true) {
            self.host
                .unregister_worker(&worker_id, worker.owner_actor.as_str())
                .await?;
        }
        Ok(())
    }

    async fn publish_process_event(
        &self,
        event_type: &str,
        activation: &ActivationResource,
        process_resource_id: &str,
        reason: Option<&str>,
    ) -> Result<()> {
        let visibility = activation.target_visibility.clone();
        let (session_id, workspace_id) = scope_ids(&activation.resource.scope);
        let _ = self
            .host
            .publish_stream_event(crate::engine::durability::streams::PublishStreamEvent {
                topic: "worker.lifecycle".to_owned(),
                payload: json!({
                    "eventType": event_type,
                    "workerId": activation.worker_id.as_str(),
                    "functionId": activation.function_id.as_str(),
                    "activationResourceId": activation.resource.resource_id,
                    "workerProcessResourceId": process_resource_id,
                    "reason": reason,
                    "timestamp": Utc::now().to_rfc3339(),
                }),
                visibility,
                session_id,
                workspace_id,
                producer: "worker-orchestration".to_owned(),
                trace_id: Some(TraceId::generate()),
                parent_invocation_id: None,
            })
            .await?;
        Ok(())
    }
}

fn validate_vault_metadata_matches_activation(
    metadata: &crate::engine::runtime::worker_activation_bundle_vault::WorkerActivationBundleMetadata,
    activation: &ActivationResource,
) -> Result<()> {
    if metadata.activation_resource_id != activation.resource.resource_id {
        return Err(EngineError::PolicyViolation(
            "activation bundle id does not match launch activation".to_owned(),
        ));
    }
    if metadata.worker_id != activation.worker_id {
        return Err(EngineError::PolicyViolation(
            "activation bundle workerId does not match activation".to_owned(),
        ));
    }
    if metadata.function_id != activation.function_id {
        return Err(EngineError::PolicyViolation(
            "activation bundle functionId does not match activation".to_owned(),
        ));
    }
    if metadata.expires_at <= Utc::now() {
        return Err(EngineError::PolicyViolation(
            "activation bundle is expired".to_owned(),
        ));
    }
    let activation_fingerprint = activation
        .payload
        .get("tokenFingerprint")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if metadata.token_fingerprint != activation_fingerprint {
        return Err(EngineError::PolicyViolation(
            "activation bundle fingerprint does not match activation".to_owned(),
        ));
    }
    Ok(())
}
