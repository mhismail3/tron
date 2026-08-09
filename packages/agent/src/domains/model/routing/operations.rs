//! Model operation implementations.
//!
//! Model catalog reads and model switching live here behind canonical
//! `model::*` functions.

use crate::domains::auth::credentials::OpenAIAuthPath;
use crate::domains::model::Deps;
use crate::domains::model::routing::catalog as model_catalog;
use crate::shared::server::errors::ToolError;
use serde_json::{Value, json};

pub(crate) async fn list_models(deps: &Deps) -> Result<Value, ToolError> {
    let auth_path =
        crate::domains::auth::credentials::openai::infer_auth_path(&deps.auth_path, None)
            .unwrap_or(OpenAIAuthPath::ChatGptCodex);
    let snapshot = deps.settings_runtime.current();
    Ok(json!({
        "models": model_catalog::known_models(
            auth_path,
            &snapshot.settings.api.ollama.base_url,
        ).await
    }))
}

pub(crate) async fn switch_model(payload: &Value, deps: &Deps) -> Result<Value, ToolError> {
    model_catalog::switch_model(Some(payload), deps).await
}

pub(crate) async fn set_reasoning_level(payload: &Value, deps: &Deps) -> Result<Value, ToolError> {
    model_catalog::set_reasoning_level(Some(payload), deps).await
}
