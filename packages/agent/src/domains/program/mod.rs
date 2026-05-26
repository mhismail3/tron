//! Program executor domain worker.
//!
//! This domain owns Tron's first-party JavaScript program execution capability.
//! The model invokes it through the single `capability::execute` primitive by
//! selecting the `program::run_javascript` target; the parent-side domain owns
//! the concrete capability while a separate first-party process owns the
//! QuickJS runtime. Child capability calls return to the parent over the program
//! protocol, so the engine remains the sole authority for capability
//! resolution, preparation, execution, policy, trace, and audit.
//! Packaged and dev flows must stage `tron-program-worker` beside the running
//! `tron` executable; production code does not rely on `TRON_PROGRAM_WORKER_BIN`
//! except as a focused test override.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `contract` | Canonical `program::run_javascript` contract and schemas |
//! | `deps` | Narrow dependency bundle for program execution |
//! | `handlers` | Operation binding for the program worker |
//! | `process` | Parent-side process lifecycle and host-call protocol loop |
//! | `protocol` | JSON-line parent/child program worker messages |
//! | `runtime` | QuickJS runtime, limits, host-call policy, and result types |
//!
//! # INVARIANT: no host APIs in JavaScript
//!
//! JavaScript programs receive only immutable `args`, `console.log`, and the
//! frozen `tools.execute` host-call surface for bounded program composition.
//! There is no
//! filesystem, network, process, import loader, environment, secret, mutable
//! clock, native module, or host object surface.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) mod process;
pub(crate) mod protocol;
pub(crate) mod runtime;

pub(crate) use deps::Deps;

use serde_json::{Value, json};

use crate::domains::capability::types::CapabilityProgramRunRecord;
use crate::domains::worker::{DomainRegistrationContext, DomainWorkerModule};
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, FunctionId, Invocation, TraceId,
};
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;

/// Entrypoint used by the `tron-program-worker` child process.
#[must_use]
pub fn worker_process_main() -> std::process::ExitCode {
    process::worker_process_main()
}

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    let domain_deps = Deps::from_engine(deps);
    crate::domains::worker::domain_worker_module(
        "program",
        contract::STREAM_TOPICS,
        handlers::function_registrations(contract::capabilities()?, domain_deps)?,
    )
}

pub(crate) async fn run_javascript_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let request = runtime::ProgramRunRequest::from_payload(&invocation.payload)?;
    let limits = request.limits_value();
    let allowed_contracts = request.allowed_contracts.clone();
    let allowed_implementations = request.allowed_implementations.clone();
    let tool_host = runtime::EngineProgramToolHost::new(
        deps.engine_host.clone(),
        invocation
            .causal_context
            .clone()
            .with_parent_invocation(invocation.id.clone()),
        request.allowed_contracts.clone(),
        request.allowed_implementations.clone(),
        request.budget.clone(),
        tokio::runtime::Handle::current(),
    );
    let executor = deps.executor.clone();
    let trace_id = invocation.causal_context.trace_id.as_str().to_owned();
    let parent_invocation_id = invocation
        .causal_context
        .parent_invocation_id
        .as_ref()
        .map(|id| id.as_str().to_owned());
    let root_invocation_id = invocation
        .causal_context
        .runtime_metadata
        .get("rootInvocationId")
        .cloned()
        .or_else(|| parent_invocation_id.clone())
        .unwrap_or_else(|| invocation.id.as_str().to_owned());
    let binding_decision_id = invocation
        .causal_context
        .runtime_metadata
        .get("bindingDecisionId")
        .cloned();
    let mut result = run_blocking_task("program.run_javascript.quickjs", move || {
        executor
            .execute(request, std::sync::Arc::new(tool_host))
            .map_err(program_runtime_error)
    })
    .await?;
    result.trace_id = trace_id.clone();
    if !result.artifacts.is_empty() {
        return Err(CapabilityError::Custom {
            code: "PROGRAM_ARTIFACTS_REQUIRE_RESOURCE_REFS".to_owned(),
            message: "program::run_javascript no longer accepts loose artifacts; use resource capabilities from the program body".to_owned(),
            details: None,
        });
    }
    let resource_refs = create_execution_output_resource(deps, invocation, &result).await?;
    deps.record_program_run(CapabilityProgramRunRecord {
        program_run_id: result.program_run_id.clone(),
        parent_invocation_id: parent_invocation_id.clone(),
        root_invocation_id: root_invocation_id.clone(),
        binding_decision_id: binding_decision_id.clone(),
        status: result.status.clone(),
        trace_id: result.trace_id.clone(),
        code_hash: result.code_hash.clone(),
        args_hash: result.args_hash.clone(),
        limits,
        allowed_contracts,
        allowed_implementations,
        child_invocations: result.child_invocations.clone(),
        selected_implementations: result.selected_implementations.clone(),
        approval_state: result.approval_state.clone(),
        artifacts: result.artifacts.clone(),
        logs: result.logs.clone(),
        error: result.error.clone(),
        compensation_attempts: Vec::new(),
    })
    .await?;
    deps.registry_audit(
        "program.run_javascript",
        Some(&trace_id),
        json!({
            "programRunId": result.program_run_id,
            "status": result.status,
            "codeHash": result.code_hash,
            "argsHash": result.args_hash,
            "childInvocations": result.child_invocations,
            "selectedImplementations": result.selected_implementations,
            "approvalState": result.approval_state,
            "rootInvocationId": root_invocation_id,
            "bindingDecisionId": binding_decision_id,
        }),
    )
    .await?;
    let mut result_value =
        serde_json::to_value(result).map_err(|error| CapabilityError::Internal {
            message: format!("serialize program execution result: {error}"),
        })?;
    if let Some(object) = result_value.as_object_mut() {
        object.insert("parentInvocationId".to_owned(), json!(parent_invocation_id));
        object.insert("rootInvocationId".to_owned(), json!(root_invocation_id));
        object.insert("bindingDecisionId".to_owned(), json!(binding_decision_id));
        object.insert("compensationAttempts".to_owned(), json!([]));
        object.insert("resourceRefs".to_owned(), Value::Array(resource_refs));
        object.remove("artifacts");
    }
    Ok(result_value)
}

async fn create_execution_output_resource(
    deps: &Deps,
    invocation: &Invocation,
    result: &runtime::ProgramRunResult,
) -> Result<Vec<Value>, CapabilityError> {
    let created = invoke_resource_capability(
        deps,
        invocation,
        "resource::create",
        json!({
            "kind": "execution_output",
            "payload": {
                "stdoutPreview": serde_json::to_string(&result.output).unwrap_or_default(),
                "stderrPreview": result.error.as_ref().map(Value::to_string).unwrap_or_default(),
                "logPreview": result.logs.join("\n"),
                "exitCode": if result.status == "ok" { 0 } else { 1 },
                "durationMs": 0,
                "timedOut": false,
                "outputTruncated": false,
                "redactionPolicy": {"preview": "bounded"},
                "metadata": {
                    "programRunId": result.program_run_id.as_str(),
                    "status": result.status.as_str(),
                    "childInvocations": &result.child_invocations,
                    "selectedImplementations": &result.selected_implementations
                }
            }
        }),
    )
    .await?;
    Ok(created
        .get("resourceRefs")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default())
}

async fn invoke_resource_capability(
    deps: &Deps,
    parent: &Invocation,
    function_id: &str,
    payload: Value,
) -> Result<Value, CapabilityError> {
    let mut causal = CausalContext::new(
        ActorId::new("system:program").map_err(engine_capability_error)?,
        ActorKind::System,
        AuthorityGrantId::new("engine-system").map_err(engine_capability_error)?,
        TraceId::new(parent.causal_context.trace_id.as_str()).map_err(engine_capability_error)?,
    )
    .with_parent_invocation(parent.id.clone())
    .with_scope("resource.write")
    .with_idempotency_key(format!("{}:{}", parent.id.as_str(), function_id));
    if let Some(session_id) = &parent.causal_context.session_id {
        causal = causal.with_session_id(session_id.clone());
    }
    if let Some(workspace_id) = &parent.causal_context.workspace_id {
        causal = causal.with_workspace_id(workspace_id.clone());
    }
    let result = deps
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new(function_id).map_err(engine_capability_error)?,
            payload,
            causal,
        ))
        .await;
    if let Some(error) = result.error {
        return Err(engine_capability_error(error));
    }
    result.value.ok_or_else(|| CapabilityError::Internal {
        message: format!("{function_id} returned no value"),
    })
}

fn engine_capability_error(error: impl std::fmt::Display) -> CapabilityError {
    CapabilityError::Custom {
        code: "ENGINE_RESOURCE_MATERIALIZATION_FAILED".to_owned(),
        message: error.to_string(),
        details: None,
    }
}

fn program_runtime_error(error: runtime::ProgramRuntimeError) -> CapabilityError {
    CapabilityError::Custom {
        code: error.code,
        message: error.message,
        details: error.details,
    }
}
