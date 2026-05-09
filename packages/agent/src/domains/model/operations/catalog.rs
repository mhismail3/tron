//! Model operation implementations.
//!
//! Model catalog reads, model switching, and reasoning-level mutation live here
//! behind canonical `model::*` and `config::*` functions.

use crate::domains::model::Deps;
use crate::domains::model::catalog as model_catalog;
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
        crate::domains::auth::provider_credentials::openai::infer_auth_path(&auth_json_path, None)
            .unwrap_or(
                crate::domains::model::providers::openai::types::OpenAIAuthPath::ChatGptCodex,
            );
    Ok(json!({ "models": model_catalog::known_models(auth_path).await }))
}

pub(crate) async fn switch_model(payload: &Value, deps: &Deps) -> Result<Value, CapabilityError> {
    model_catalog::switch_model(Some(payload), deps).await
}

pub(crate) async fn set_reasoning_level(
    payload: &Value,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    model_catalog::set_reasoning_level(Some(payload), deps).await
}
