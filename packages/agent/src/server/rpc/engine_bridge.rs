//! RPC-to-engine migration bridge.
//!
//! JSON-RPC is becoming a trigger transport into engine functions. This module
//! owns the temporary migration inventory for that path: every registered RPC
//! method has an explicit capability spec, migrated specs register domain-owned
//! in-process worker functions, and generic-trigger methods bypass
//! method-specific business handlers entirely. Prompt library, settings, logs,
//! skills, notifications, plan, events, basic filesystem, all job methods,
//! agent queue controls, session create/delete/fork/archive/export except
//! `session.resume`, and all context snapshot/compaction/clear methods now run
//! through this generic-trigger path.
//!
//! The `rpc` worker is now transport compatibility only. Domain workers such as
//! `skills`, `filesystem`, `events`, `notifications`, `plan`, `settings`,
//! `logs`, `prompt_library`, `model`, `session`, `context`, `job`, `agent`,
//! and `system` own executable function contracts and behavior metadata.
//! `json_rpc` trigger records capture the old client method name and dispatch
//! directly into canonical ids such as `skills::activate` or
//! `session::reconstruct`; `rpc::<method>` names remain compatibility metadata
//! for handler-only inventory during the migration.
//!
//! # INVARIANT: the bridge is temporary demolition scaffolding
//!
//! The desired end state is a collapsed engine architecture where JSON-RPC is
//! only a transport trigger over canonical domain functions. Handler-only specs
//! remain non-routable internal catalog metadata until their behavior moves
//! behind the engine boundary, then groups advance to generic triggers and the
//! method-specific handlers are deleted. Compatibility ids must not become the
//! agent-facing surface again.
//! Every migration package must advance at least one method group and remove
//! superseded business handlers; adding a mirror or fallback without deletion
//! is not progress toward the collapsed architecture.

mod dispatch;
mod functions;
mod schemas;
mod specs;

#[cfg(test)]
mod tests;

use serde_json::Value;

use crate::engine::{EngineError, EngineHostHandle, InvocationResult, Result as EngineResult};
use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::{self, RpcError};
use crate::server::rpc::registry::MethodRegistry;

pub use dispatch::{RpcEngineInvocation, RpcGenericTriggerHandler, try_dispatch_generic_rpc};
pub use specs::{
    RpcCapabilitySpec, RpcExecutionPolicy, RpcIdempotencyMode, RpcMigrationState, RpcSchemaMode,
    capability_specs,
};

pub(super) const RPC_WORKER_ID: &str = "rpc";
pub(super) const RPC_OWNER_ACTOR: &str = "system";
pub(super) const RPC_AUTHORITY_GRANT: &str = "rpc-bridge";
pub(super) const RPC_READ_AUTHORITY: &str = "rpc.read";
pub(super) const RPC_WRITE_AUTHORITY: &str = "rpc.write";

/// Register the in-process RPC worker and its current capability inventory.
pub fn register_rpc_worker_for_context(
    ctx: &RpcContext,
    registry: &MethodRegistry,
) -> EngineResult<()> {
    register_rpc_worker(
        &ctx.engine_host,
        registry,
        functions::RpcEngineDeps::from_context(ctx),
    )
}

fn register_rpc_worker(
    handle: &EngineHostHandle,
    registry: &MethodRegistry,
    deps: functions::RpcEngineDeps,
) -> EngineResult<()> {
    let specs = specs::capability_specs(registry)?;
    handle.register_worker_for_setup(specs::rpc_worker(), false)?;
    for worker in specs::domain_workers()? {
        handle.register_worker_for_setup(worker, false)?;
    }
    handle.register_trigger_type_for_setup(specs::json_rpc_trigger_type()?, false)?;
    handle.register_trigger_type_for_setup(specs::manual_trigger_type()?, false)?;
    for spec in &specs {
        let handler = specs::is_engine_routable(&spec).then(|| {
            std::sync::Arc::new(functions::RpcFunctionHandler {
                method: spec.method,
                deps: deps.clone(),
            }) as std::sync::Arc<dyn crate::engine::InProcessFunctionHandler>
        });
        handle.register_function_for_setup(
            specs::function_definition_for_spec(&spec),
            handler,
            false,
        )?;
    }
    for spec in &specs {
        if let Some(trigger) = specs::json_rpc_trigger_for_spec(spec)? {
            handle.register_trigger_for_setup(trigger, false)?;
        }
    }
    Ok(())
}

pub(super) fn rpc_error_to_engine(error: RpcError) -> EngineError {
    let body = error.to_error_body();
    EngineError::AdapterFailure {
        adapter: "rpc".to_owned(),
        code: body.code,
        message: body.message,
        details: body.details,
    }
}

pub(super) fn result_to_rpc(result: InvocationResult) -> Result<Value, RpcError> {
    if let Some(error) = result.error {
        return Err(engine_error_to_rpc(error));
    }
    Ok(result.value.unwrap_or(Value::Null))
}

pub(super) fn engine_error_to_rpc(error: EngineError) -> RpcError {
    match error {
        EngineError::AdapterFailure {
            adapter: _,
            code,
            message,
            details,
        } => rpc_error_from_parts(&code, message, details),
        EngineError::SchemaViolation { message, .. } => RpcError::InvalidParams { message },
        EngineError::PolicyViolation(message) => RpcError::InvalidParams { message },
        EngineError::IdempotencyConflict {
            function_id,
            key,
            reason,
        } => RpcError::Custom {
            code: errors::IDEMPOTENCY_CONFLICT.to_owned(),
            message: format!("Idempotency conflict for {function_id}: {reason}"),
            details: Some(serde_json::json!({
                "functionId": function_id,
                "key": key,
                "reason": reason,
            })),
        },
        EngineError::NotFound { id, .. } => RpcError::NotFound {
            code: errors::NOT_FOUND.to_owned(),
            message: format!("Engine function '{id}' not found"),
        },
        other => RpcError::Internal {
            message: other.to_string(),
        },
    }
}

fn rpc_error_from_parts(code: &str, message: String, details: Option<Value>) -> RpcError {
    match code {
        errors::INVALID_PARAMS => RpcError::InvalidParams { message },
        errors::INTERNAL_ERROR => RpcError::Internal { message },
        errors::NOT_AVAILABLE => RpcError::NotAvailable { message },
        errors::NOT_FOUND => RpcError::NotFound {
            code: errors::NOT_FOUND.to_owned(),
            message,
        },
        _ => RpcError::Custom {
            code: code.to_owned(),
            message,
            details,
        },
    }
}
