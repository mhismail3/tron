//! Operation binding for the session worker.

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
        "create" => session_create_value(Some(payload), deps).await,
        "resume" => session_resume_value(Some(payload), deps).await,
        "list" => session_list_value(Some(payload), deps).await,
        "delete" => session_delete_value(Some(payload), deps).await,
        "fork" => session_fork_value(Some(payload), deps).await,
        "get_head" => session_get_head_value(Some(payload), deps).await,
        "get_state" => session_get_state_value(Some(payload), deps).await,
        "get_history" => session_get_history_value(Some(payload), deps).await,
        "reconstruct" => session_reconstruct_value(Some(payload), deps).await,
        "archive" => session_archive_value(Some(payload), deps).await,
        "unarchive" => session_unarchive_value(Some(payload), deps).await,
        "archive_older_than" => session_archive_older_than_value(Some(payload), deps).await,
        "export" => session_export_value(Some(payload), deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("session method {operation_key} is not engine-owned"),
        }),
    }
}
