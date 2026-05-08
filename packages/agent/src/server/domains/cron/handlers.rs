//! Operation binding for the cron worker.

use super::operations::*;
use super::*;

pub(crate) fn function_registrations(
    specs: Vec<crate::server::domains::catalog::CapabilitySpec>,
    deps: Deps,
) -> crate::engine::Result<Vec<crate::server::domains::DomainFunctionRegistration>> {
    specs
        .into_iter()
        .map(|spec| function_registration(spec, deps.clone()))
        .collect()
}

pub(crate) fn function_registration(
    spec: crate::server::domains::catalog::CapabilitySpec,
    deps: Deps,
) -> crate::engine::Result<crate::server::domains::DomainFunctionRegistration> {
    Ok(crate::server::domains::DomainFunctionRegistration {
        definition: crate::server::domains::catalog::function_definition_for_capability(&spec),
        handler: handler_for_operation(spec.operation_key, deps),
    })
}

pub(crate) fn handler_for_operation(
    operation_key: impl Into<String>,
    deps: Deps,
) -> std::sync::Arc<dyn crate::engine::InProcessFunctionHandler> {
    std::sync::Arc::new(FunctionHandler {
        operation_key: operation_key.into(),
        deps,
    })
}

struct FunctionHandler {
    operation_key: String,
    deps: Deps,
}

#[async_trait::async_trait]
impl crate::engine::InProcessFunctionHandler for FunctionHandler {
    async fn invoke(
        &self,
        invocation: crate::engine::Invocation,
    ) -> Result<serde_json::Value, crate::engine::EngineError> {
        handle(&self.operation_key, &invocation, &self.deps)
            .await
            .map_err(crate::server::shared::error_mapping::capability_error_to_engine)
    }
}

pub(crate) async fn handle(
    operation_key: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    match operation_key {
        "list" => cron_list_value(&invocation.payload, deps).await,
        "get" => cron_get_value(&invocation.payload, deps).await,
        "create" => cron_create_value(&invocation.payload, invocation, deps).await,
        "update" => cron_update_value(&invocation.payload, invocation, deps).await,
        "delete" => cron_delete_value(&invocation.payload, invocation, deps).await,
        "run" => cron_run_value(&invocation.payload, invocation, deps).await,
        "status" => cron_status_value(deps).await,
        "get_runs" => cron_get_runs_value(&invocation.payload, deps).await,
        "scheduled_fire" => cron_scheduled_fire_value(&invocation.payload, invocation, deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("cron method {operation_key} is not engine-owned"),
        }),
    }
}
