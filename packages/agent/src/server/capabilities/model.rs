use super::*;

use crate::server::services::model_catalog as rpc_model;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &EngineCapabilityDeps,
    allow_capability_context: bool,
) -> Result<Value, CapabilityError> {
    match method {
        "model::list" => {
            model_list_value(&invocation.payload, deps, allow_capability_context).await
        }
        "model::switch" => {
            rpc_model::switch_model(Some(&invocation.payload), &deps.capability_context).await
        }
        "config::set_reasoning_level" => {
            rpc_model::set_reasoning_level(Some(&invocation.payload), &deps.capability_context)
                .await
        }
        _ => Err(CapabilityError::Internal {
            message: format!("model method {method} is not engine-owned"),
        }),
    }
}

async fn model_list_value(
    payload: &Value,
    deps: &EngineCapabilityDeps,
    allow_capability_context: bool,
) -> Result<Value, CapabilityError> {
    let auth_json_path = allow_capability_context
        .then(|| {
            payload
                .pointer("/__rpcContext/authPath")
                .and_then(Value::as_str)
                .map(PathBuf::from)
        })
        .flatten()
        .unwrap_or_else(|| deps.auth_path.clone());
    let auth_path = crate::llm::auth::openai::infer_auth_path(&auth_json_path, None)
        .unwrap_or(crate::llm::openai::types::OpenAIAuthPath::ChatGptCodex);
    Ok(json!({ "models": rpc_model::known_models(auth_path).await }))
}
