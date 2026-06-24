//! Model operation implementations.
//!
//! Model catalog reads and model switching live here behind canonical
//! `model::*` functions.

use crate::domains::auth::credentials::OpenAIAuthPath;
use crate::domains::model::Deps;
use crate::domains::model::routing::catalog as model_catalog;
use crate::shared::server::errors::CapabilityError;
use serde_json::{Value, json};
use std::path::PathBuf;

pub(crate) async fn list_models(
    payload: &Value,
    deps: &Deps,
    allow_server_context: bool,
) -> Result<Value, CapabilityError> {
    let auth_json_path = allow_server_context
        .then(|| {
            payload
                .pointer("/__capabilityContext/authPath")
                .and_then(Value::as_str)
                .map(PathBuf::from)
        })
        .flatten()
        .unwrap_or_else(|| deps.auth_path.clone());
    let auth_path =
        crate::domains::auth::credentials::openai::infer_auth_path(&auth_json_path, None)
            .unwrap_or(OpenAIAuthPath::ChatGptCodex);
    Ok(json!({ "models": model_catalog::known_models(auth_path).await }))
}

pub(crate) async fn switch_model(payload: &Value, deps: &Deps) -> Result<Value, CapabilityError> {
    model_catalog::switch_model(Some(payload), deps).await
}
