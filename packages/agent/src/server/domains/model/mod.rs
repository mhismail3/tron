//! model domain worker.
//!
//! This module owns canonical function execution for the model namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.

pub(crate) mod contract;
pub(crate) mod spec;

use super::*;
#[derive(Clone)]
pub(crate) struct Deps {
    auth_path: PathBuf,
    capability_context: Arc<ServerCapabilityContext>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &EngineCapabilityDeps) -> Self {
        Self {
            auth_path: deps.auth_path.clone(),
            capability_context: deps.capability_context.clone(),
        }
    }
}

pub(crate) mod catalog;
use crate::server::domains::model::catalog as model_catalog;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
    allow_capability_context: bool,
) -> Result<Value, CapabilityError> {
    match method {
        "model::list" => {
            model_list_value(&invocation.payload, deps, allow_capability_context).await
        }
        "model::switch" => {
            model_catalog::switch_model(Some(&invocation.payload), &deps.capability_context).await
        }
        "config::set_reasoning_level" => {
            model_catalog::set_reasoning_level(Some(&invocation.payload), &deps.capability_context)
                .await
        }
        _ => Err(CapabilityError::Internal {
            message: format!("model method {method} is not engine-owned"),
        }),
    }
}

async fn model_list_value(
    payload: &Value,
    deps: &Deps,
    allow_capability_context: bool,
) -> Result<Value, CapabilityError> {
    let auth_json_path = allow_capability_context
        .then(|| {
            payload
                .pointer("/__capabilityContext/authPath")
                .and_then(Value::as_str)
                .map(PathBuf::from)
        })
        .flatten()
        .unwrap_or_else(|| deps.auth_path.clone());
    let auth_path = crate::llm::auth::openai::infer_auth_path(&auth_json_path, None)
        .unwrap_or(crate::llm::openai::types::OpenAIAuthPath::ChatGptCodex);
    Ok(json!({ "models": model_catalog::known_models(auth_path).await }))
}
