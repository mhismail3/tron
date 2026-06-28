//! Module-owned jobs/program-execution execute operation adapters.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::{Deps, invalid, ok_result, optional_str, optional_u64, required_str};
use crate::domains::{jobs, module_runtime, program_execution};
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

const SCHEMA_VERSION: &str = "tron.module_program_execution.v1";
const MODULE_RUNTIME_KIND: &str = "jobs_program_execution";
const DEFAULT_RUNTIME_LABEL: &str = "Jobs program execution";

pub(super) async fn module_program_execution_start(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    ensure_network_policy_none(&invocation.payload)?;
    let command = required_str(&invocation.payload, "command")?;
    if command.trim().is_empty() {
        return Err(invalid(
            "module_program_execution_start command must not be empty",
        ));
    }

    let module_runtime_deps = module_runtime::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let runtime_payload = runtime_request_payload(&invocation.payload, operation_at)?;
    let runtime_invocation = invocation_with_payload_idempotency(invocation, &runtime_payload);
    let runtime = module_runtime::service::request_module_runtime_value_at(
        &module_runtime_deps,
        &runtime_invocation,
        &runtime_payload,
        operation_at,
    )
    .await?;
    if runtime["idempotentReplay"].as_bool().unwrap_or(false) {
        let replay = replayed_start_details(invocation, deps, &runtime).await?;
        return Ok(result(
            "Module program execution start replayed.",
            "module_program_execution_start",
            replay,
        ));
    }

    let program_execution_deps = program_execution::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let program_payload = program_execution_payload(&invocation.payload, &runtime)?;
    let program = program_execution::service::record_program_execution_record_value_at(
        &program_execution_deps,
        invocation,
        &program_payload,
        operation_at,
    )
    .await?;

    let start_payload = job_start_payload(&invocation.payload, command)?;
    let job = match jobs::service::start_job_value(
        &deps.engine_host,
        deps.shutdown_coordinator.clone(),
        jobs::runtime(),
        invocation,
        &start_payload,
    )
    .await
    {
        Ok(job) => job,
        Err(error) => {
            let _ = module_runtime::service::record_delegated_job_runtime_update_at(
                &module_runtime_deps,
                invocation,
                module_runtime::service::DelegatedJobRuntimeUpdate {
                    module_runtime_resource_id: runtime_resource_id(&runtime)?,
                    expected_module_runtime_version_id: None,
                    state: "failed".to_owned(),
                    job_ref: json!({
                        "kind": "job_process",
                        "role": "delegated_job_process",
                        "status": "spawn_failed"
                    }),
                    program_execution_ref: Some(program_execution_ref(&program)?),
                    output_ref: None,
                    terminal: Some(json!({
                        "status": "failed",
                        "exitCode": Value::Null,
                        "timedOut": false,
                        "cancelled": false,
                        "errorRedacted": true,
                        "rawErrorReturned": false
                    })),
                    cancellation: None,
                    cleanup: None,
                },
                operation_at,
            )
            .await;
            return Err(error);
        }
    };

    let job_ref = job_ref(&job, "delegated_job_process")?;
    let runtime_update = module_runtime::service::record_delegated_job_runtime_update_at(
        &module_runtime_deps,
        invocation,
        module_runtime::service::DelegatedJobRuntimeUpdate {
            module_runtime_resource_id: runtime_resource_id(&runtime)?,
            expected_module_runtime_version_id: None,
            state: "running".to_owned(),
            job_ref: job_ref.clone(),
            program_execution_ref: Some(program_execution_ref(&program)?),
            output_ref: None,
            terminal: None,
            cancellation: None,
            cleanup: Some(json!({
                "state": "retained",
                "cleanupAfterSeconds": invocation
                    .payload
                    .get("cleanupAfterSeconds")
                    .cloned()
                    .unwrap_or(Value::Null),
                "exactCleanupRequired": true
            })),
        },
        operation_at,
    )
    .await?;
    let redacted_job = redacted_job_status(invocation, deps, &job_resource_id(&job)?).await?;

    Ok(result(
        "Module program execution started.",
        "module_program_execution_start",
        json!({
            "schemaVersion": SCHEMA_VERSION,
            "operation": "module_program_execution_start",
            "status": "running",
            "idempotentReplay": false,
            "moduleRuntime": runtime_update,
            "programExecution": program,
            "job": redacted_job,
            "resourceRefs": [
                runtime_resource_ref(&runtime_update)?,
                program_execution_ref(&program)?,
                job_ref
            ],
            "providerSafety": provider_safety_proof()
        }),
    ))
}

async fn replayed_start_details(
    invocation: &Invocation,
    deps: &Deps,
    runtime: &Value,
) -> Result<Value, CapabilityError> {
    let job_ref = replay_job_ref(runtime)?;
    let program_ref = replay_program_execution_ref(runtime)?;
    let job_resource_id = job_ref
        .get("resourceId")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            invalid("module program execution replay missing delegated job resource id")
        })?;
    let redacted_job = redacted_job_status(invocation, deps, job_resource_id).await?;
    Ok(json!({
                "schemaVersion": SCHEMA_VERSION,
                "operation": "module_program_execution_start",
                "status": runtime.get("status").and_then(Value::as_str).unwrap_or("running"),
                "idempotentReplay": true,
                "moduleRuntime": runtime,
                "programExecution": replay_program_execution_record(&program_ref)?,
                "job": redacted_job,
                "resourceRefs": [
                    runtime_resource_ref(runtime)?,
                    program_ref,
                    job_ref
                ],
                "providerSafety": provider_safety_proof()
    }))
}

fn invocation_with_payload_idempotency(invocation: &Invocation, payload: &Value) -> Invocation {
    let Some(idempotency_key) = payload.get("idempotencyKey").and_then(Value::as_str) else {
        return invocation.clone();
    };
    let mut delegated = invocation.clone();
    delegated.causal_context = delegated
        .causal_context
        .with_idempotency_key(idempotency_key.to_owned());
    delegated
}

pub(super) async fn module_program_execution_status(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let job_resource_id = required_str(&invocation.payload, "jobResourceId")?;
    let runtime = inspect_bound_runtime(invocation, deps, job_resource_id).await?;
    let job = redacted_job_status(invocation, deps, job_resource_id).await?;
    let status = job["status"].as_str().unwrap_or("unknown");
    Ok(result(
        "Module program execution status inspected.",
        "module_program_execution_status",
        json!({
            "schemaVersion": SCHEMA_VERSION,
            "operation": "module_program_execution_status",
            "status": status,
            "moduleRuntime": runtime,
            "job": job,
            "providerSafety": provider_safety_proof()
        }),
    ))
}

pub(super) async fn module_program_execution_cancel(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let job_resource_id = required_str(&invocation.payload, "jobResourceId")?;
    inspect_bound_runtime(invocation, deps, job_resource_id).await?;
    let cancel = jobs::service::cancel_job_value(
        &deps.engine_host,
        jobs::runtime(),
        deps.jobs_reconcile.clone(),
        invocation,
        &invocation.payload,
    )
    .await?;
    let job = redacted_job_status(invocation, deps, job_resource_id).await?;
    let module_runtime_deps = module_runtime::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let runtime_update = module_runtime::service::record_delegated_job_runtime_update_at(
        &module_runtime_deps,
        invocation,
        module_runtime::service::DelegatedJobRuntimeUpdate {
            module_runtime_resource_id: required_str(
                &invocation.payload,
                "moduleRuntimeResourceId",
            )?
            .to_owned(),
            expected_module_runtime_version_id: Some(
                required_str(&invocation.payload, "expectedModuleRuntimeVersionId")?.to_owned(),
            ),
            state: "cancelled".to_owned(),
            job_ref: redacted_status_job_ref(&job, "delegated_job_process")?,
            program_execution_ref: None,
            output_ref: redacted_status_output_ref(&job),
            terminal: redacted_status_terminal(&job),
            cancellation: Some(json!({
                "state": "cancel_requested",
                "cancelRequested": true,
                "cancelledAt": operation_at.to_rfc3339(),
                "reasonRedacted": invocation.payload.get("reason").is_some(),
                "processSignalSent": false,
                "jobCancelDelegated": true
            })),
            cleanup: None,
        },
        operation_at,
    )
    .await?;
    Ok(result(
        "Module program execution cancellation requested.",
        "module_program_execution_cancel",
        json!({
            "schemaVersion": SCHEMA_VERSION,
            "operation": "module_program_execution_cancel",
            "status": cancel.get("status").and_then(Value::as_str).unwrap_or("cancel_requested"),
            "moduleRuntime": runtime_update,
            "job": job,
            "cancel": redacted_cancel_result(&cancel),
            "providerSafety": provider_safety_proof()
        }),
    ))
}

pub(super) async fn module_program_execution_cleanup(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let job_resource_id = required_str(&invocation.payload, "jobResourceId")?;
    inspect_bound_runtime(invocation, deps, job_resource_id).await?;
    let cleanup = jobs::service::cleanup_job_resource_value(
        &deps.engine_host,
        jobs::runtime(),
        deps.jobs_reconcile.clone(),
        invocation,
        &invocation.payload,
    )
    .await?;
    let job = redacted_job_status(invocation, deps, job_resource_id).await?;
    let module_runtime_deps = module_runtime::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let runtime_update = module_runtime::service::record_delegated_job_runtime_update_at(
        &module_runtime_deps,
        invocation,
        module_runtime::service::DelegatedJobRuntimeUpdate {
            module_runtime_resource_id: required_str(
                &invocation.payload,
                "moduleRuntimeResourceId",
            )?
            .to_owned(),
            expected_module_runtime_version_id: Some(
                required_str(&invocation.payload, "expectedModuleRuntimeVersionId")?.to_owned(),
            ),
            state: "archived".to_owned(),
            job_ref: redacted_status_job_ref(&job, "delegated_job_process")?,
            program_execution_ref: None,
            output_ref: redacted_status_output_ref(&job),
            terminal: redacted_status_terminal(&job),
            cancellation: None,
            cleanup: Some(json!({
                "state": "archived",
                "cleanedAt": operation_at.to_rfc3339(),
                "jobCleanupDelegated": true,
                "rawOutputDeleted": false,
                "resourceLifecycleArchived": true
            })),
        },
        operation_at,
    )
    .await?;
    Ok(result(
        "Module program execution cleanup recorded.",
        "module_program_execution_cleanup",
        json!({
            "schemaVersion": SCHEMA_VERSION,
            "operation": "module_program_execution_cleanup",
            "status": "archived",
            "moduleRuntime": runtime_update,
            "job": job,
            "cleanup": cleanup,
            "providerSafety": provider_safety_proof()
        }),
    ))
}

fn runtime_request_payload(
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    let mut value = json!({
        "moduleLifecycleResourceId": required_str(payload, "moduleLifecycleResourceId")?,
        "runtimeRequestId": required_str(payload, "runtimeRequestId")?,
        "runtimeKind": optional_str(payload, "runtimeKind")?.unwrap_or(MODULE_RUNTIME_KIND),
        "runtimeLabel": optional_str(payload, "runtimeLabel")?.unwrap_or(DEFAULT_RUNTIME_LABEL),
        "runtimeState": "running",
        "reason": required_str(payload, "reason")?,
        "timeoutMs": optional_u64(payload, "timeoutMs")?.unwrap_or(30_000),
        "inputRefs": array_field(payload, "inputRefs"),
        "outputArtifactRefs": [],
        "evidenceRefs": array_field(payload, "evidenceRefs")
    });
    if let Some(key) = optional_str(payload, "idempotencyKey")? {
        value["idempotencyKey"] = json!(key);
    }
    value["evidenceRefs"]
        .as_array_mut()
        .expect("evidenceRefs array")
        .push(json!({
            "kind": "module_manifest",
            "resourceId": "module_manifest:jobs_program_execution_module",
            "role": "module_pack",
            "status": "pending_review"
        }));
    value["evidenceRefs"]
        .as_array_mut()
        .expect("evidenceRefs array")
        .push(json!({
            "kind": "trace",
            "id": format!("module_program_execution_start:{}", operation_at.timestamp_millis()),
            "role": "request_time"
        }));
    Ok(value)
}

fn program_execution_payload(payload: &Value, runtime: &Value) -> Result<Value, CapabilityError> {
    let mut value = json!({
        "operation": "program_execution_record",
        "programId": optional_str(payload, "programId")?.unwrap_or(required_str(payload, "runtimeRequestId")?),
        "runtimeId": required_str(payload, "runtimeId")?,
        "languageId": required_str(payload, "languageId")?,
        "programFingerprint": required_str(payload, "programFingerprint")?,
        "maxWallClockMs": optional_u64(payload, "timeoutMs")?.unwrap_or(30_000),
        "maxOutputBytes": optional_u64(payload, "maxOutputBytes")?.unwrap_or(20_000),
        "evidenceRefs": array_field(payload, "evidenceRefs"),
        "sourceRefs": array_field(payload, "sourceRefs")
    });
    copy_optional_ref(payload, &mut value, "sourceRef");
    copy_optional_ref(payload, &mut value, "inputRef");
    copy_optional_string(payload, &mut value, "inputFingerprint")?;
    copy_optional_string(payload, &mut value, "programLabel")?;
    copy_optional_string(payload, &mut value, "programSummary")?;
    if let Some(key) = optional_str(payload, "idempotencyKey")? {
        value["idempotencyKey"] = json!(key);
    }
    value["evidenceRefs"]
        .as_array_mut()
        .expect("evidenceRefs array")
        .push(runtime_program_execution_ref(runtime)?);
    Ok(value)
}

fn job_start_payload(payload: &Value, command: &str) -> Result<Value, CapabilityError> {
    let mut value = json!({"command": command});
    copy_optional_u64(payload, &mut value, "timeoutMs")?;
    copy_optional_u64(payload, &mut value, "maxOutputBytes")?;
    copy_optional_u64(payload, &mut value, "cleanupAfterSeconds")?;
    Ok(value)
}

async fn redacted_job_status(
    invocation: &Invocation,
    deps: &Deps,
    job_resource_id: &str,
) -> Result<Value, CapabilityError> {
    jobs::service::redacted_job_status_value(
        &deps.engine_host,
        jobs::runtime(),
        deps.jobs_reconcile.clone(),
        invocation,
        &json!({"jobResourceId": job_resource_id}),
    )
    .await
}

async fn inspect_bound_runtime(
    invocation: &Invocation,
    deps: &Deps,
    job_resource_id: &str,
) -> Result<Value, CapabilityError> {
    let module_runtime_deps = module_runtime::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let runtime = module_runtime::service::inspect_module_runtime_value(
        &module_runtime_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    ensure_runtime_job_binding(&runtime, job_resource_id)?;
    Ok(runtime)
}

fn ensure_runtime_job_binding(
    runtime: &Value,
    requested_job_resource_id: &str,
) -> Result<(), CapabilityError> {
    let bound_job_resource_id = runtime
        .pointer("/moduleRuntime/moduleRuntime/supervision/job/jobRef/resourceId")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            invalid(
                "module program execution runtime has no delegated job binding for requested job",
            )
        })?;
    if bound_job_resource_id == requested_job_resource_id {
        return Ok(());
    }
    Err(invalid(format!(
        "module program execution runtime/job binding mismatch: runtime is bound to {bound_job_resource_id}, requested {requested_job_resource_id}"
    )))
}

fn result(text: &str, operation: &str, details: Value) -> CapabilityResult {
    ok_result(
        text.to_owned(),
        json!({
            "primitiveOperation": operation,
            "status": details.get("status").and_then(Value::as_str).unwrap_or("ok"),
            "moduleProgramExecution": details
        }),
    )
}

fn ensure_network_policy_none(payload: &Value) -> Result<(), CapabilityError> {
    let Some(policy) = optional_str(payload, "networkPolicy")? else {
        return Ok(());
    };
    if policy == "none" {
        Ok(())
    } else {
        Err(invalid(
            "module_program_execution_start supports only networkPolicy none",
        ))
    }
}

fn array_field(payload: &Value, field: &str) -> Value {
    payload
        .get(field)
        .and_then(Value::as_array)
        .cloned()
        .map(Value::Array)
        .unwrap_or_else(|| json!([]))
}

fn copy_optional_ref(source: &Value, target: &mut Value, field: &str) {
    if let Some(value) = source.get(field) {
        target[field] = value.clone();
    }
}

fn copy_optional_string(
    source: &Value,
    target: &mut Value,
    field: &str,
) -> Result<(), CapabilityError> {
    if let Some(value) = optional_str(source, field)? {
        target[field] = json!(value);
    }
    Ok(())
}

fn copy_optional_u64(
    source: &Value,
    target: &mut Value,
    field: &str,
) -> Result<(), CapabilityError> {
    if let Some(value) = optional_u64(source, field)? {
        target[field] = json!(value);
    }
    Ok(())
}

fn runtime_resource_id(value: &Value) -> Result<String, CapabilityError> {
    value
        .get("moduleRuntimeResourceId")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| invalid("module runtime response omitted resource id"))
}

fn job_resource_id(value: &Value) -> Result<String, CapabilityError> {
    value
        .get("jobResourceId")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| invalid("job start response omitted resource id"))
}

fn job_ref(value: &Value, role: &str) -> Result<Value, CapabilityError> {
    Ok(json!({
        "kind": "job_process",
        "resourceId": job_resource_id(value)?,
        "versionId": value.get("jobVersionId").and_then(Value::as_str).unwrap_or("unknown"),
        "role": role,
        "status": value.get("status").and_then(Value::as_str).unwrap_or("running")
    }))
}

fn runtime_resource_ref(value: &Value) -> Result<Value, CapabilityError> {
    Ok(json!({
        "kind": "module_runtime_state",
        "resourceId": runtime_resource_id(value)?,
        "versionId": value.get("moduleRuntimeVersionId").and_then(Value::as_str).unwrap_or("unknown"),
        "role": "module_runtime_state",
        "status": value.get("status").and_then(Value::as_str).unwrap_or("running")
    }))
}

fn runtime_program_execution_ref(value: &Value) -> Result<Value, CapabilityError> {
    Ok(json!({
        "kind": "module_runtime_state",
        "resourceId": runtime_resource_id(value)?,
        "versionId": value.get("moduleRuntimeVersionId").and_then(Value::as_str).unwrap_or("unknown"),
        "role": "module_runtime_state"
    }))
}

fn replay_job_ref(runtime: &Value) -> Result<Value, CapabilityError> {
    runtime
        .pointer("/moduleRuntime/supervision/job/jobRef")
        .filter(|value| value.is_object())
        .cloned()
        .ok_or_else(|| {
            invalid("module program execution replay found runtime without delegated job binding")
        })
}

fn replay_program_execution_ref(runtime: &Value) -> Result<Value, CapabilityError> {
    runtime
        .pointer("/moduleRuntime/supervision/programExecution/metadataOnlyRecordRef")
        .filter(|value| value.is_object())
        .cloned()
        .ok_or_else(|| {
            invalid("module program execution replay found runtime without program execution ref")
        })
}

fn replay_program_execution_record(value: &Value) -> Result<Value, CapabilityError> {
    Ok(json!({
        "programExecutionResourceId": value
            .get("resourceId")
            .and_then(Value::as_str)
            .ok_or_else(|| invalid("program execution replay ref omitted resource id"))?,
        "programExecutionVersionId": value
            .get("versionId")
            .and_then(Value::as_str)
            .unwrap_or("unknown"),
        "status": value.get("status").and_then(Value::as_str).unwrap_or("active"),
        "resourceRefs": [value.clone()],
        "projection": {
            "replayedFromModuleRuntime": true,
            "rawCodeReturned": false,
            "rawIoReturned": false
        }
    }))
}

fn program_execution_ref(value: &Value) -> Result<Value, CapabilityError> {
    Ok(json!({
        "kind": "program_execution_record",
        "resourceId": value
            .get("programExecutionResourceId")
            .and_then(Value::as_str)
            .ok_or_else(|| invalid("program execution response omitted resource id"))?,
        "versionId": value
            .get("programExecutionVersionId")
            .and_then(Value::as_str)
            .unwrap_or("unknown"),
        "role": "program_execution_metadata",
        "status": value.get("status").and_then(Value::as_str).unwrap_or("active")
    }))
}

fn redacted_status_job_ref(value: &Value, role: &str) -> Result<Value, CapabilityError> {
    let job = value
        .get("job")
        .ok_or_else(|| invalid("redacted job response omitted job"))?;
    Ok(json!({
        "kind": "job_process",
        "resourceId": job
            .get("jobResourceId")
            .and_then(Value::as_str)
            .ok_or_else(|| invalid("redacted job response omitted resource id"))?,
        "versionId": job.get("jobVersionId").and_then(Value::as_str).unwrap_or("unknown"),
        "role": role,
        "status": job.get("state").and_then(Value::as_str).unwrap_or("unknown")
    }))
}

fn redacted_status_output_ref(value: &Value) -> Option<Value> {
    value
        .pointer("/job/output")
        .filter(|output| output.is_object())
        .cloned()
}

fn redacted_status_terminal(value: &Value) -> Option<Value> {
    value
        .pointer("/job/terminal")
        .filter(|terminal| terminal.is_object())
        .cloned()
}

fn redacted_cancel_result(value: &Value) -> Value {
    json!({
        "status": value.get("status").and_then(Value::as_str).unwrap_or("unknown"),
        "state": value.get("state").and_then(Value::as_str),
        "jobResourceId": value.get("jobResourceId").and_then(Value::as_str),
        "jobVersionId": value.get("jobVersionId").and_then(Value::as_str),
        "idempotent": value.get("idempotent").and_then(Value::as_bool).unwrap_or(false),
        "runtimeHadJob": value.get("runtimeHadJob").and_then(Value::as_bool),
        "rawReasonReturned": false,
        "rawOutputReturned": false
    })
}

fn provider_safety_proof() -> Value {
    json!({
        "rawCommandReturned": false,
        "rawCommandStoredInModuleRuntime": false,
        "workingDirectoryReturned": false,
        "authorityIdsReturned": false,
        "stdoutPreviewReturned": false,
        "stderrPreviewReturned": false,
        "rawOutputReturned": false,
        "rawOutputStoredInModuleRuntime": false,
        "programExecutionStoresRawCode": false,
        "programExecutionStoresRawIo": false,
        "jobProcessPayloadReturned": false,
        "executionOutputPayloadReturned": false,
        "providerVisibleOutput": "refs_fingerprints_and_exit_metadata_only"
    })
}
