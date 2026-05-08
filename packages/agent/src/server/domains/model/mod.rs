//! model domain worker.
//!
//! This module owns canonical function execution for the model namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) use deps::Deps;
pub(super) use handlers::handle;

use super::*;

pub(crate) fn worker_modules(
    deps: &DomainSetupContext,
) -> crate::engine::Result<Vec<DomainWorkerModule>> {
    let contracts = contract::capabilities()?;
    let model_specs = contracts
        .iter()
        .filter(|spec| spec.owner_worker.as_str() == "model")
        .cloned()
        .collect::<Vec<_>>();
    let config_specs = contracts
        .into_iter()
        .filter(|spec| spec.owner_worker.as_str() == "config")
        .collect::<Vec<_>>();
    Ok(vec![
        super::domain_worker_module(
            "model",
            contract::STREAM_TOPICS,
            model_specs,
            Deps::from_engine(deps),
            super::model_handler,
        )?,
        super::domain_worker_module(
            "config",
            contract::STREAM_TOPICS,
            config_specs,
            Deps::from_engine(deps),
            super::model_handler,
        )?,
    ])
}

pub(crate) mod catalog;
use crate::server::domains::model::catalog as model_catalog;

async fn model_list_value(
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
    let auth_path = crate::llm::auth::openai::infer_auth_path(&auth_json_path, None)
        .unwrap_or(crate::llm::openai::types::OpenAIAuthPath::ChatGptCodex);
    Ok(json!({ "models": model_catalog::known_models(auth_path).await }))
}
