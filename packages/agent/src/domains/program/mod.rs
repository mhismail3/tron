//! Program executor domain worker.
//!
//! This domain owns Tron's first-party JavaScript program execution capability.
//! The model still invokes it only through `capability::execute` with
//! `mode = "program"`; this worker owns the concrete `program::run_javascript`
//! implementation, QuickJS runtime limits, child capability host calls, audit
//! payload shape, and tests.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `contract` | Canonical `program::run_javascript` contract and schemas |
//! | `deps` | Narrow dependency bundle for program execution |
//! | `handlers` | Operation binding for the program worker |
//! | `runtime` | QuickJS runtime, limits, host-call policy, and result types |
//!
//! # INVARIANT: no host APIs in JavaScript
//!
//! JavaScript programs receive only immutable `args`, `console.log`, and the
//! frozen `tools.search`/`tools.inspect`/`tools.execute` host-call surface. There is no
//! filesystem, network, process, import loader, environment, secret, mutable
//! clock, native module, or host object surface.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) mod runtime;

pub(crate) use deps::Deps;

use serde_json::{Value, json};

use crate::domains::capability::types::CapabilityProgramRunRecord;
use crate::domains::worker::{DomainRegistrationContext, DomainWorkerModule};
use crate::engine::Invocation;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;

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
    let result = run_blocking_task("program.run_javascript.quickjs", move || {
        executor
            .execute(request, std::sync::Arc::new(tool_host))
            .map_err(program_runtime_error)
    })
    .await?;
    deps.record_program_run(CapabilityProgramRunRecord {
        program_run_id: result.program_run_id.clone(),
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
        }),
    )
    .await?;
    Ok(
        serde_json::to_value(result).map_err(|error| CapabilityError::Internal {
            message: format!("serialize program execution result: {error}"),
        })?,
    )
}

fn program_runtime_error(error: runtime::ProgramRuntimeError) -> CapabilityError {
    CapabilityError::Custom {
        code: error.code,
        message: error.message,
        details: error.details,
    }
}
