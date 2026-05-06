use super::*;

use crate::server::rpc::handlers::model as rpc_model;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &RpcEngineDeps,
    allow_rpc_context: bool,
) -> Result<Value, RpcError> {
    match method {
        "model.list" => model_list_value(&invocation.payload, deps, allow_rpc_context).await,
        _ => Err(RpcError::Internal {
            message: format!("model method {method} is not engine-owned"),
        }),
    }
}

async fn model_list_value(
    payload: &Value,
    deps: &RpcEngineDeps,
    allow_rpc_context: bool,
) -> Result<Value, RpcError> {
    let auth_json_path = allow_rpc_context
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
