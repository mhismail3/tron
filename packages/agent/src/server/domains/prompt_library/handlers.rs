//! Operation binding for the prompt_library worker.

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
        "history_list" => prompt_history_list_value(Some(payload), deps).await,
        "history_delete" => prompt_history_delete_value(Some(payload), deps).await,
        "history_clear" => prompt_history_clear_value(deps).await,
        "snippet_list" => prompt_snippet_list_value(deps).await,
        "snippet_get" => prompt_snippet_get_value(Some(payload), deps).await,
        "snippet_create" => prompt_snippet_create_value(Some(payload), deps).await,
        "snippet_update" => prompt_snippet_update_value(Some(payload), deps).await,
        "snippet_delete" => prompt_snippet_delete_value(Some(payload), deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("prompt-library method {operation_key} is not engine-owned"),
        }),
    }
}
