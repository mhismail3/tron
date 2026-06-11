use chrono::Utc;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::contracts::AutostartPlan;
use super::process_resource::{
    current_payload, ensure_resource_kind, launch_response_from_process, redact_text,
    validate_activation_for_launch, validate_launch_plan_matches_activation,
};
use super::{
    EngineWorkerOrchestrationRuntime, STDIN_BUNDLE_DELIVERY_MODE, WORKER_AUTOSTART_PLAN_KIND,
    WORKER_AUTOSTART_PLAN_SCHEMA_ID, WORKER_TRIGGER_LAUNCH_ATTEMPT_KIND,
    WORKER_TRIGGER_LAUNCH_ATTEMPT_SCHEMA_ID,
};
use crate::engine::durability::resources::{
    CreateResource, EngineResourceInspection, EngineResourceVersion, UpdateResource,
};
use crate::engine::invocation::model::{CausalContext, Invocation};
use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::ids::{FunctionId, TriggerId, WorkerId};
use crate::engine::primitives::WORKER_WORKER_ID;

const LAUNCH_FROM_TRIGGER_FUNCTION: &str = "worker::launch_from_trigger";

pub(super) struct TriggerLaunchRequest {
    autostart_plan_resource_id: String,
    launch_reason: Option<String>,
    startup_timeout_ms: Option<u64>,
}

impl TriggerLaunchRequest {
    pub(super) fn from_invocation(invocation: &Invocation) -> Result<Self> {
        Ok(Self {
            autostart_plan_resource_id: non_empty_request_string(
                &invocation.payload,
                "autostartPlanResourceId",
            )?,
            launch_reason: optional_request_string(&invocation.payload, "launchReason")?,
            startup_timeout_ms: optional_request_u64(&invocation.payload, "startupTimeoutMs")?,
        })
    }
}

impl EngineWorkerOrchestrationRuntime {
    /// Launch a reviewed worker plan from a trusted trigger dispatch.
    pub async fn launch_from_trigger(&self, invocation: Invocation) -> Result<Value> {
        let request = TriggerLaunchRequest::from_invocation(&invocation)?;
        ensure_trigger_launch_context(&invocation)?;
        let trigger_id = invocation
            .causal_context
            .trigger_id
            .clone()
            .expect("validated trigger id");
        let target_idempotency_key = invocation
            .causal_context
            .idempotency_key
            .as_deref()
            .expect("validated idempotency key")
            .to_owned();
        let attempt_id = trigger_launch_attempt_id(
            &request.autostart_plan_resource_id,
            &trigger_id,
            &target_idempotency_key,
        );
        if let Some(existing) = self.host.inspect_resource(&attempt_id).await? {
            ensure_resource_kind(&existing, WORKER_TRIGGER_LAUNCH_ATTEMPT_KIND)?;
            return trigger_launch_response(&existing);
        }

        let (autostart_inspection, autostart) = self
            .load_autostart_plan(&request.autostart_plan_resource_id)
            .await?;
        self.validate_trigger_binding(&autostart, &trigger_id)
            .await?;
        let launch_plan = self
            .load_launch_plan(&autostart.launch_plan_resource_id)
            .await?;
        validate_autostart_launch_plan(&autostart, &launch_plan, &invocation)?;

        let issue_idempotency_key = format!("saawtl:issue:{attempt_id}");
        let launch_idempotency_key = format!("saawtl:launch:{attempt_id}");
        let initial_payload = trigger_launch_attempt_payload(
            "requested",
            &attempt_id,
            &autostart,
            &trigger_id,
            &target_idempotency_key,
            &issue_idempotency_key,
            &launch_idempotency_key,
            None,
            None,
            None,
            &invocation,
        );
        self.host
            .create_resource(CreateResource {
                resource_id: Some(attempt_id.clone()),
                kind: WORKER_TRIGGER_LAUNCH_ATTEMPT_KIND.to_owned(),
                schema_id: Some(WORKER_TRIGGER_LAUNCH_ATTEMPT_SCHEMA_ID.to_owned()),
                scope: autostart_inspection.resource.scope.clone(),
                owner_worker_id: WorkerId::new(WORKER_WORKER_ID)?,
                owner_actor_id: invocation.causal_context.actor_id.clone(),
                lifecycle: Some("requested".to_owned()),
                policy: json!({
                    "deliveryMode": "stdin_activation_bundle_v1",
                    "restartPolicy": "none",
                    "duplicatePolicy": "idempotency_key_replay_v1",
                    "secretStorage": "activation_bundle_vault_only"
                }),
                initial_payload: Some(initial_payload),
                locations: Vec::new(),
                trace_id: invocation.causal_context.trace_id.clone(),
                invocation_id: Some(invocation.id.clone()),
            })
            .await?;

        let issue_result = self
            .host
            .invoke(Invocation::new_sync(
                FunctionId::new("worker::issue_activation")?,
                autostart.issue_payload(&issue_idempotency_key),
                derived_context(&invocation.causal_context, &issue_idempotency_key),
            ))
            .await;
        let Some(issue_value) = issue_result.value else {
            let error = issue_result.error.unwrap_or_else(|| {
                EngineError::HandlerFailed("worker activation issue returned no value".to_owned())
            });
            self.fail_attempt(
                &attempt_id,
                &autostart,
                &trigger_id,
                &target_idempotency_key,
                &issue_idempotency_key,
                &launch_idempotency_key,
                None,
                None,
                &error,
                &invocation,
            )
            .await?;
            return Err(error);
        };
        let activation_resource_id = issue_value["activationResourceId"]
            .as_str()
            .ok_or_else(|| {
                EngineError::HandlerFailed(
                    "worker activation issue omitted activationResourceId".to_owned(),
                )
            })?
            .to_owned();
        self.update_attempt(
            &attempt_id,
            trigger_launch_attempt_payload(
                "activation_issued",
                &attempt_id,
                &autostart,
                &trigger_id,
                &target_idempotency_key,
                &issue_idempotency_key,
                &launch_idempotency_key,
                Some(&activation_resource_id),
                None,
                None,
                &invocation,
            ),
            "activation_issued",
            &invocation,
        )
        .await?;

        let activation = self.load_activation(&activation_resource_id).await?;
        if let Err(error) = validate_activation_for_launch(&activation)
            .and_then(|_| validate_launch_plan_matches_activation(&launch_plan, &activation))
        {
            self.fail_attempt(
                &attempt_id,
                &autostart,
                &trigger_id,
                &target_idempotency_key,
                &issue_idempotency_key,
                &launch_idempotency_key,
                Some(&activation_resource_id),
                None,
                &error,
                &invocation,
            )
            .await?;
            return Err(error);
        }

        self.update_attempt(
            &attempt_id,
            trigger_launch_attempt_payload(
                "launch_starting",
                &attempt_id,
                &autostart,
                &trigger_id,
                &target_idempotency_key,
                &issue_idempotency_key,
                &launch_idempotency_key,
                Some(&activation_resource_id),
                None,
                None,
                &invocation,
            ),
            "launch_starting",
            &invocation,
        )
        .await?;
        let launch_result = self
            .host
            .invoke(Invocation::new_sync(
                FunctionId::new("worker::launch_activation")?,
                launch_payload(
                    &activation_resource_id,
                    &autostart.launch_plan_resource_id,
                    request.launch_reason.as_deref(),
                    request.startup_timeout_ms,
                    &launch_idempotency_key,
                ),
                derived_context(&invocation.causal_context, &launch_idempotency_key),
            ))
            .await;
        let Some(launch_value) = launch_result.value else {
            let error = launch_result.error.unwrap_or_else(|| {
                EngineError::HandlerFailed("worker launch returned no value".to_owned())
            });
            self.fail_attempt(
                &attempt_id,
                &autostart,
                &trigger_id,
                &target_idempotency_key,
                &issue_idempotency_key,
                &launch_idempotency_key,
                Some(&activation_resource_id),
                None,
                &error,
                &invocation,
            )
            .await?;
            return Err(error);
        };
        let process_resource_id = launch_value["workerProcessResourceId"]
            .as_str()
            .ok_or_else(|| {
                EngineError::HandlerFailed(
                    "worker launch omitted workerProcessResourceId".to_owned(),
                )
            })?
            .to_owned();
        self.update_attempt(
            &attempt_id,
            trigger_launch_attempt_payload(
                "ready_pending",
                &attempt_id,
                &autostart,
                &trigger_id,
                &target_idempotency_key,
                &issue_idempotency_key,
                &launch_idempotency_key,
                Some(&activation_resource_id),
                Some(&process_resource_id),
                None,
                &invocation,
            ),
            "ready_pending",
            &invocation,
        )
        .await?;
        let process = self.require_process(&process_resource_id).await?;
        let launch = launch_response_from_process(&process, &activation, &launch_plan)?;
        Ok(json!({
            "triggerLaunchAttemptResourceId": attempt_id,
            "triggerId": trigger_id.as_str(),
            "autostartPlanResourceId": autostart.resource_id,
            "activationResourceId": activation_resource_id,
            "workerProcessResourceId": process_resource_id,
            "status": "ready_pending",
            "processState": launch["launchStatus"].clone(),
            "launch": launch,
        }))
    }

    async fn load_autostart_plan(
        &self,
        resource_id: &str,
    ) -> Result<(EngineResourceInspection, AutostartPlan)> {
        let inspection = self
            .host
            .inspect_resource(resource_id)
            .await?
            .ok_or_else(|| EngineError::NotFound {
                kind: WORKER_AUTOSTART_PLAN_KIND,
                id: resource_id.to_owned(),
            })?;
        ensure_resource_kind(&inspection, WORKER_AUTOSTART_PLAN_KIND)?;
        if inspection.resource.schema_id != WORKER_AUTOSTART_PLAN_SCHEMA_ID {
            return Err(EngineError::PolicyViolation(format!(
                "worker autostart plan {resource_id} must use schema {WORKER_AUTOSTART_PLAN_SCHEMA_ID}"
            )));
        }
        if inspection.resource.lifecycle != "reviewed" {
            return Err(EngineError::PolicyViolation(format!(
                "worker autostart plan {resource_id} must be reviewed"
            )));
        }
        let plan = AutostartPlan::from_payload(resource_id, current_payload(&inspection)?)?;
        Ok((inspection, plan))
    }

    async fn validate_trigger_binding(
        &self,
        plan: &AutostartPlan,
        causal_trigger_id: &TriggerId,
    ) -> Result<()> {
        if &plan.trigger_id != causal_trigger_id {
            return Err(EngineError::PolicyViolation(
                "worker autostart plan triggerId must match causal trigger".to_owned(),
            ));
        }
        let trigger = self.host.inspect_trigger(causal_trigger_id).await?;
        if trigger.target_function.as_str() != LAUNCH_FROM_TRIGGER_FUNCTION {
            return Err(EngineError::PolicyViolation(format!(
                "trigger {causal_trigger_id} must target {LAUNCH_FROM_TRIGGER_FUNCTION}"
            )));
        }
        Ok(())
    }

    async fn fail_attempt(
        &self,
        attempt_id: &str,
        autostart: &AutostartPlan,
        trigger_id: &TriggerId,
        target_idempotency_key: &str,
        issue_idempotency_key: &str,
        launch_idempotency_key: &str,
        activation_resource_id: Option<&str>,
        process_resource_id: Option<&str>,
        error: &EngineError,
        invocation: &Invocation,
    ) -> Result<EngineResourceVersion> {
        self.update_attempt(
            attempt_id,
            trigger_launch_attempt_payload(
                "failed",
                attempt_id,
                autostart,
                trigger_id,
                target_idempotency_key,
                issue_idempotency_key,
                launch_idempotency_key,
                activation_resource_id,
                process_resource_id,
                Some(error),
                invocation,
            ),
            "failed",
            invocation,
        )
        .await
    }

    async fn update_attempt(
        &self,
        attempt_id: &str,
        payload: Value,
        lifecycle: &str,
        invocation: &Invocation,
    ) -> Result<EngineResourceVersion> {
        let inspection = self
            .host
            .inspect_resource(attempt_id)
            .await?
            .ok_or_else(|| EngineError::NotFound {
                kind: WORKER_TRIGGER_LAUNCH_ATTEMPT_KIND,
                id: attempt_id.to_owned(),
            })?;
        self.host
            .update_resource(UpdateResource {
                resource_id: attempt_id.to_owned(),
                expected_current_version_id: inspection.resource.current_version_id,
                lifecycle: Some(lifecycle.to_owned()),
                payload,
                state: None,
                locations: Vec::new(),
                trace_id: invocation.causal_context.trace_id.clone(),
                invocation_id: Some(invocation.id.clone()),
            })
            .await
    }
}

fn validate_autostart_launch_plan(
    autostart: &AutostartPlan,
    launch_plan: &super::contracts::LaunchPlan,
    invocation: &Invocation,
) -> Result<()> {
    if launch_plan.activation_delivery_mode != STDIN_BUNDLE_DELIVERY_MODE {
        return Err(EngineError::PolicyViolation(
            "worker trigger launch requires stdin_activation_bundle_v1 launch plan".to_owned(),
        ));
    }
    if launch_plan.expected_function_id != autostart.function_id {
        return Err(EngineError::PolicyViolation(
            "worker autostart plan functionId must match launch plan".to_owned(),
        ));
    }
    if launch_plan.target_visibility != autostart.target_visibility {
        return Err(EngineError::PolicyViolation(
            "worker autostart plan visibility must match launch plan".to_owned(),
        ));
    }
    if launch_plan.namespace != autostart.function_id.namespace() {
        return Err(EngineError::PolicyViolation(
            "worker autostart plan namespace must match launch plan".to_owned(),
        ));
    }
    let expected_scope = match autostart.target_visibility {
        crate::engine::kernel::types::VisibilityScope::Session => {
            (invocation.causal_context.session_id.clone(), None)
        }
        crate::engine::kernel::types::VisibilityScope::Workspace => (
            None,
            autostart
                .workspace_id
                .clone()
                .or_else(|| invocation.causal_context.workspace_id.clone()),
        ),
        _ => (None, None),
    };
    if (
        launch_plan.scope.session_id.clone(),
        launch_plan.scope.workspace_id.clone(),
    ) != expected_scope
    {
        return Err(EngineError::PolicyViolation(
            "worker autostart plan scope must match launch plan".to_owned(),
        ));
    }
    Ok(())
}

fn ensure_trigger_launch_context(invocation: &Invocation) -> Result<()> {
    if invocation.causal_context.trigger_id.is_none() {
        return Err(EngineError::PolicyViolation(
            "worker::launch_from_trigger requires trigger causal context".to_owned(),
        ));
    }
    if invocation
        .causal_context
        .idempotency_key
        .as_deref()
        .is_none_or(str::is_empty)
    {
        return Err(EngineError::PolicyViolation(
            "worker::launch_from_trigger requires target idempotency key".to_owned(),
        ));
    }
    for scope in ["worker.activate", "worker.launch"] {
        if !invocation.causal_context.has_scope(scope) {
            return Err(EngineError::PolicyViolation(format!(
                "worker::launch_from_trigger requires {scope}"
            )));
        }
    }
    Ok(())
}

fn derived_context(parent: &CausalContext, idempotency_key: &str) -> CausalContext {
    let mut context = parent.clone();
    context.idempotency_key = Some(idempotency_key.to_owned());
    context
}

fn launch_payload(
    activation_resource_id: &str,
    launch_plan_resource_id: &str,
    launch_reason: Option<&str>,
    startup_timeout_ms: Option<u64>,
    idempotency_key: &str,
) -> Value {
    let mut payload = json!({
        "activationResourceId": activation_resource_id,
        "launchPlanResourceId": launch_plan_resource_id,
        "launchReason": launch_reason.unwrap_or("trigger launch"),
        "idempotencyKey": idempotency_key,
    });
    if let Some(startup_timeout_ms) = startup_timeout_ms {
        payload["startupTimeoutMs"] = json!(startup_timeout_ms);
    }
    payload
}

fn trigger_launch_attempt_payload(
    status: &str,
    attempt_id: &str,
    autostart: &AutostartPlan,
    trigger_id: &TriggerId,
    target_idempotency_key: &str,
    issue_idempotency_key: &str,
    launch_idempotency_key: &str,
    activation_resource_id: Option<&str>,
    process_resource_id: Option<&str>,
    error: Option<&EngineError>,
    invocation: &Invocation,
) -> Value {
    json!({
        "status": status,
        "attemptId": attempt_id,
        "triggerId": trigger_id.as_str(),
        "autostartPlanResourceId": autostart.resource_id,
        "launchPlanResourceId": autostart.launch_plan_resource_id,
        "activationResourceId": activation_resource_id,
        "workerProcessResourceId": process_resource_id,
        "functionId": autostart.function_id.as_str(),
        "targetVisibility": autostart.target_visibility.as_str(),
        "scope": {
            "sessionId": invocation.causal_context.session_id,
            "workspaceId": autostart.workspace_id.as_deref().or(invocation.causal_context.workspace_id.as_deref()),
        },
        "idempotency": {
            "targetKeyFingerprint": short_hash(target_idempotency_key),
            "issueKeyFingerprint": short_hash(issue_idempotency_key),
            "launchKeyFingerprint": short_hash(launch_idempotency_key),
            "duplicatePolicy": "idempotency_key_replay_v1",
        },
        "trace": {
            "traceId": invocation.causal_context.trace_id.as_str(),
            "triggerInvocationId": invocation.id.as_str(),
            "parentInvocationId": invocation
                .causal_context
                .parent_invocation_id
                .as_ref()
                .map(|id| id.as_str()),
        },
        "policy": {
            "deliveryMode": "stdin_activation_bundle_v1",
            "restartPolicy": "none",
            "secretStorage": "activation_bundle_vault_only",
        },
        "error": error.map(|error| json!({
            "redacted": true,
            "message": redact_text(&error.to_string(), 4096),
        })),
        "metadata": {
            "source": "worker::launch_from_trigger",
            "updatedAt": Utc::now().to_rfc3339(),
        }
    })
}

fn trigger_launch_response(inspection: &EngineResourceInspection) -> Result<Value> {
    let payload = current_payload(inspection)?;
    Ok(json!({
        "triggerLaunchAttemptResourceId": inspection.resource.resource_id,
        "triggerId": payload["triggerId"].clone(),
        "autostartPlanResourceId": payload["autostartPlanResourceId"].clone(),
        "activationResourceId": payload["activationResourceId"].clone(),
        "workerProcessResourceId": payload["workerProcessResourceId"].clone(),
        "status": payload["status"].clone(),
        "processState": payload["status"].clone(),
        "replayed": true,
    }))
}

fn trigger_launch_attempt_id(
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

fn short_hash(value: &str) -> String {
    let hash = hex::encode(Sha256::digest(value.as_bytes()));
    hash.chars().take(16).collect()
}

fn non_empty_request_string(payload: &Value, field: &str) -> Result<String> {
    let value = payload.get(field).and_then(Value::as_str).ok_or_else(|| {
        EngineError::PolicyViolation(format!("required field {field} must be a string"))
    })?;
    if value.trim().is_empty() {
        return Err(EngineError::PolicyViolation(format!(
            "{field} must be non-empty"
        )));
    }
    Ok(value.to_owned())
}

fn optional_request_string(payload: &Value, field: &str) -> Result<Option<String>> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) if !value.trim().is_empty() => Ok(Some(value.clone())),
        Some(Value::String(_)) => Err(EngineError::PolicyViolation(format!(
            "{field} must be non-empty"
        ))),
        Some(other) => Err(EngineError::PolicyViolation(format!(
            "{field} must be a string, got {other}"
        ))),
    }
}

fn optional_request_u64(payload: &Value, field: &str) -> Result<Option<u64>> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(number)) => number.as_u64().map(Some).ok_or_else(|| {
            EngineError::PolicyViolation(format!("{field} must be an unsigned integer"))
        }),
        Some(other) => Err(EngineError::PolicyViolation(format!(
            "{field} must be an unsigned integer, got {other}"
        ))),
    }
}
