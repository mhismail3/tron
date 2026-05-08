//! Operation binding for the agent worker.

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
        "prompt" => prompt_value(invocation, deps).await,
        "prompt_apply" => prompt_apply_value(Some(payload), invocation, deps).await,
        "run_turn" => run_turn_value(Some(payload), invocation, deps).await,
        "prompt_queue_drain" => prompt_queue_drain_value(Some(payload), invocation, deps).await,
        "status" => status_value(Some(payload), deps).await,
        "abort" => abort_value(Some(payload), deps).await,
        "abort_tool" => abort_tool_value(Some(payload), deps).await,
        "queue_prompt" => queue_prompt_value(Some(payload), invocation, deps).await,
        "dequeue_prompt" => dequeue_prompt_value(Some(payload), invocation, deps).await,
        "clear_queue" => clear_queue_value(Some(payload), invocation, deps).await,
        "deliver_subagent_results" => deliver_subagent_results_value(Some(payload), deps).await,
        "submit_confirmation" => submit_confirmation_value(Some(payload), deps).await,
        "submit_answers" => submit_answers_value(Some(payload), deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("agent method {operation_key} is not engine-owned"),
        }),
    }
}
