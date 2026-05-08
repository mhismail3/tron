//! Operation binding for the context worker.

use super::operations;
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
        "get_snapshot" => operations::get_snapshot(payload, deps).await,
        "get_detailed_snapshot" => operations::get_detailed_snapshot(payload, deps).await,
        "get_audit_trace" => operations::get_audit_trace(payload, deps).await,
        "should_compact" => operations::should_compact(payload, deps).await,
        "preview_compaction" => operations::preview_compaction(payload, deps).await,
        "can_accept_turn" => operations::can_accept_turn(payload, deps).await,
        "confirm_compaction" => operations::confirm_compaction(payload, deps).await,
        "clear" => operations::clear(payload, deps).await,
        "compact" => operations::compact(payload, deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("context method {operation_key} is not engine-owned"),
        }),
    }
}
