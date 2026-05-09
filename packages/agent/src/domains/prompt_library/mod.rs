//! prompt library domain worker.
//!
//! This module owns canonical function execution for the prompt library
//! namespace and keeps domain contracts, services, and tests beside the worker
//! that uses them. Agent prompt completion records prompt history through the
//! hidden `prompt_library::history_record` engine function, so even product
//! side effects stay visible to the engine ledger.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub mod implementation;
pub(crate) use deps::Deps;
pub use implementation::*;

use crate::domains::prompt_library::implementation::store as prompt_store;
use crate::domains::worker::DomainRegistrationContext;
use crate::domains::worker::DomainWorkerModule;
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::errors::to_json_value;
use crate::shared::server::params::opt_string;
use crate::shared::server::params::opt_u64;
use crate::shared::server::params::require_string_param;
use crate::shared::server::validation::validate_string_param;
use serde_json::Value;
use serde_json::json;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        crate::domains::worker::domain_worker_module(
            "prompt_library",
            contract::STREAM_TOPICS,
            handlers::function_registrations(contract::capabilities()?, domain_deps)?,
        )
    }
}

const MAX_SEARCH_QUERY_LEN: usize = 200;

fn map_store_err(e: crate::domains::session::event_store::EventStoreError) -> CapabilityError {
    match e {
        crate::domains::session::event_store::EventStoreError::InvalidOperation(message) => {
            CapabilityError::InvalidParams { message }
        }
        crate::domains::session::event_store::EventStoreError::Sqlite(err) => {
            CapabilityError::Internal {
                message: format!("Database error: {err}"),
            }
        }
        crate::domains::session::event_store::EventStoreError::Internal(msg) => {
            CapabilityError::Internal { message: msg }
        }
        other => crate::shared::server::error_mapping::map_event_store_error(other),
    }
}

async fn prompt_history_list_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let limit_raw = opt_u64(params, "limit", prompt_store::DEFAULT_LIST_LIMIT as u64);
    if limit_raw > prompt_store::MAX_LIST_LIMIT as u64 {
        return Err(CapabilityError::InvalidParams {
            message: format!(
                "'limit' must be ≤ {} (got {limit_raw})",
                prompt_store::MAX_LIST_LIMIT
            ),
        });
    }
    let limit = limit_raw as u32;
    let cursor = opt_string(params, "cursor");
    let query = opt_string(params, "query");
    if let Some(ref query) = query {
        validate_string_param(query, "query", MAX_SEARCH_QUERY_LEN)?;
    }

    let page = prompt_store::list_history(deps.event_store.pool(), limit, cursor, query)
        .map_err(map_store_err)?;
    Ok(json!({
        "items": to_json_value(&page.items)?,
        "nextCursor": page.next_cursor,
    }))
}

async fn prompt_history_record_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let prompt = require_string_param(params, "prompt")?;
    validate_string_param(
        &prompt,
        "prompt",
        crate::shared::server::validation::MAX_PROMPT_LENGTH,
    )?;
    let source = opt_string(params, "source");
    let is_cron = source
        .as_deref()
        .map(|source| source.starts_with("cron"))
        .unwrap_or(false);
    let settings = crate::domains::settings::get_settings()
        .prompt_library
        .clone();
    if is_cron {
        return Ok(json!({"recorded": false, "reason": "cron_source"}));
    }
    if !settings.history_enabled {
        return Ok(json!({"recorded": false, "reason": "history_disabled"}));
    }

    let char_count = prompt.chars().count();
    let outcome = prompt_store::record_prompt_and_prune(
        deps.event_store.pool(),
        &prompt,
        settings
            .history_auto_prune
            .then_some(settings.history_max_entries)
            .filter(|n| *n > 0),
        settings
            .history_auto_prune
            .then_some(settings.history_max_age_days)
            .filter(|n| *n > 0),
    )
    .map_err(map_store_err)?;
    tracing::debug!(char_count, ?outcome, "recorded prompt history");
    Ok(json!({"recorded": true, "reason": null}))
}

async fn prompt_history_delete_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let id = require_string_param(params, "id")?;
    let deleted =
        prompt_store::delete_history(deps.event_store.pool(), &id).map_err(map_store_err)?;
    Ok(json!({ "deleted": deleted }))
}

async fn prompt_history_clear_value(deps: &Deps) -> Result<Value, CapabilityError> {
    let deleted_count =
        prompt_store::clear_history(deps.event_store.pool()).map_err(map_store_err)?;
    Ok(json!({ "deletedCount": deleted_count }))
}

async fn prompt_snippet_list_value(deps: &Deps) -> Result<Value, CapabilityError> {
    let items = prompt_store::list_snippets(deps.event_store.pool()).map_err(map_store_err)?;
    Ok(json!({ "items": to_json_value(&items)? }))
}

async fn prompt_snippet_get_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let id = require_string_param(params, "id")?;
    let snippet = prompt_store::get_snippet(deps.event_store.pool(), &id)
        .map_err(map_store_err)?
        .ok_or_else(|| CapabilityError::NotFound {
            code: "SNIPPET_NOT_FOUND".into(),
            message: format!("Snippet not found: {id}"),
        })?;
    Ok(json!({ "snippet": to_json_value(&snippet)? }))
}

async fn prompt_snippet_create_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let name = require_string_param(params, "name")?;
    let text = require_string_param(params, "text")?;
    validate_string_param(
        &text,
        "text",
        crate::shared::server::validation::MAX_PROMPT_LENGTH,
    )?;

    let snippet = prompt_store::create_snippet(deps.event_store.pool(), &name, &text)
        .map_err(map_store_err)?;
    Ok(json!({ "snippet": to_json_value(&snippet)? }))
}

async fn prompt_snippet_update_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let id = require_string_param(params, "id")?;
    let name = opt_string(params, "name");
    let text = opt_string(params, "text");

    if name.is_none() && text.is_none() {
        return Err(CapabilityError::InvalidParams {
            message: "update requires at least one of 'name' or 'text'".into(),
        });
    }
    if let Some(ref text) = text {
        validate_string_param(
            text,
            "text",
            crate::shared::server::validation::MAX_PROMPT_LENGTH,
        )?;
    }

    let updated = prompt_store::update_snippet(deps.event_store.pool(), &id, name, text)
        .map_err(map_store_err)?
        .ok_or_else(|| CapabilityError::NotFound {
            code: "SNIPPET_NOT_FOUND".into(),
            message: format!("Snippet not found: {id}"),
        })?;
    Ok(json!({ "snippet": to_json_value(&updated)? }))
}

async fn prompt_snippet_delete_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let id = require_string_param(params, "id")?;
    let deleted =
        prompt_store::delete_snippet(deps.event_store.pool(), &id).map_err(map_store_err)?;
    Ok(json!({ "deleted": deleted }))
}
