//! Operation binding for the model worker.

use super::*;

pub(crate) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
    allow_server_context: bool,
) -> Result<Value, CapabilityError> {
    match method {
        "model::list" => model_list_value(&invocation.payload, deps, allow_server_context).await,
        "model::switch" => {
            model_catalog::switch_model(Some(&invocation.payload), &deps.server_context).await
        }
        "config::set_reasoning_level" => {
            model_catalog::set_reasoning_level(Some(&invocation.payload), &deps.server_context)
                .await
        }
        _ => Err(CapabilityError::Internal {
            message: format!("model method {method} is not engine-owned"),
        }),
    }
}
