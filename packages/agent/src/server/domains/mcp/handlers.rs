//! Operation binding for the mcp worker.

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
    let payload = &invocation.payload;
    match operation_key {
        "status" => mcp_status_value(deps).await,
        "add_server" => mcp_add_server_value(Some(payload), invocation, deps).await,
        "remove_server" => mcp_remove_server_value(Some(payload), invocation, deps).await,
        "enable_server" => mcp_enable_server_value(Some(payload), invocation, deps).await,
        "disable_server" => mcp_disable_server_value(Some(payload), invocation, deps).await,
        "restart_server" => mcp_restart_server_value(Some(payload), invocation, deps).await,
        "reload" => mcp_reload_value(invocation, deps).await,
        "list_tools" => mcp_list_tools_value(Some(payload), deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("mcp method {operation_key} is not engine-owned"),
        }),
    }
}
