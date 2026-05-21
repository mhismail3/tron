//! web domain worker.
//!
//! This worker owns HTTP fetch and web search capabilities. Provider integrations
//! never receive web-specific model capabilities; agents discover and invoke these
//! capabilities through the single `execute` orchestrator.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) use deps::Deps;

use std::collections::HashMap;

use serde_json::{Value, json};

use crate::domains::worker::{DomainRegistrationContext, DomainWorkerModule};
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::params::{opt_string, opt_u64, require_string_param};

const BRAVE_BASE_URL: &str = "https://api.search.brave.com/res/v1/web/search";
const DEFAULT_FETCH_MAX_BYTES: usize = 512 * 1024;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    let domain_deps = Deps::from_engine(deps);
    crate::domains::worker::domain_worker_module(
        "web",
        contract::STREAM_TOPICS,
        handlers::function_registrations(contract::capabilities()?, domain_deps)?,
    )
}

async fn web_fetch_value(params: Option<&Value>, deps: &Deps) -> Result<Value, CapabilityError> {
    let url = require_string_param(params, "url")?;
    let max_bytes = usize::try_from(opt_u64(params, "maxBytes", DEFAULT_FETCH_MAX_BYTES as u64))
        .unwrap_or(DEFAULT_FETCH_MAX_BYTES)
        .clamp(1, 1024 * 1024);
    let headers = string_map(params.and_then(|value| value.get("headers")));
    let mut request = deps.client.get(&url);
    for (key, value) in headers {
        request = request.header(key, value);
    }
    let response = request
        .send()
        .await
        .map_err(|error| CapabilityError::Custom {
            code: "WEB_FETCH_FAILED".to_owned(),
            message: error.to_string(),
            details: None,
        })?;
    let status = response.status().as_u16();
    let content_type = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .map(ToOwned::to_owned);
    let bytes = response
        .bytes()
        .await
        .map_err(|error| CapabilityError::Custom {
            code: "WEB_FETCH_BODY_FAILED".to_owned(),
            message: error.to_string(),
            details: None,
        })?;
    let truncated = bytes.len() > max_bytes;
    let body = String::from_utf8_lossy(if truncated {
        &bytes[..max_bytes]
    } else {
        &bytes
    })
    .into_owned();
    Ok(json!({
        "url": url,
        "status": status,
        "contentType": content_type,
        "body": body,
        "truncated": truncated,
    }))
}

async fn web_search_value(params: Option<&Value>, deps: &Deps) -> Result<Value, CapabilityError> {
    let query = require_string_param(params, "query")?;
    let api_key = crate::domains::auth::provider_credentials::storage::get_service_api_keys(
        &deps.auth_path,
        "brave",
    )
    .map_err(|error| CapabilityError::Custom {
        code: "WEB_SEARCH_AUTH_LOAD_FAILED".to_owned(),
        message: error.to_string(),
        details: None,
    })?
    .into_iter()
    .find(|key| !key.trim().is_empty())
    .ok_or_else(|| CapabilityError::Custom {
        code: "WEB_SEARCH_AUTH_REQUIRED".to_owned(),
        message: "Brave Search API key is not configured".to_owned(),
        details: None,
    })?;

    let count = opt_u64(params, "count", 10).clamp(1, 20);
    let mut query_params = vec![
        ("q".to_owned(), query.clone()),
        ("count".to_owned(), count.to_string()),
    ];
    if let Some(freshness) = opt_string(params, "freshness") {
        query_params.push(("freshness".to_owned(), freshness));
    }
    if let Some(country) = opt_string(params, "country") {
        query_params.push(("country".to_owned(), country));
    }
    if let Some(safesearch) = opt_string(params, "safesearch") {
        query_params.push(("safesearch".to_owned(), safesearch));
    }
    let qs = query_params
        .iter()
        .map(|(key, value)| format!("{key}={}", urlencoding::encode(value)))
        .collect::<Vec<_>>()
        .join("&");
    let response = deps
        .client
        .get(format!("{BRAVE_BASE_URL}?{qs}"))
        .header("Accept", "application/json")
        .header("X-Subscription-Token", api_key)
        .send()
        .await
        .map_err(|error| CapabilityError::Custom {
            code: "WEB_SEARCH_FAILED".to_owned(),
            message: error.to_string(),
            details: None,
        })?;
    let status = response.status().as_u16();
    let body = response
        .text()
        .await
        .map_err(|error| CapabilityError::Custom {
            code: "WEB_SEARCH_BODY_FAILED".to_owned(),
            message: error.to_string(),
            details: None,
        })?;
    if status != 200 {
        return Err(CapabilityError::Custom {
            code: "WEB_SEARCH_HTTP_ERROR".to_owned(),
            message: format!("Brave Search returned HTTP {status}"),
            details: Some(json!({"status": status, "body": body})),
        });
    }
    let json_body: Value =
        serde_json::from_str(&body).map_err(|error| CapabilityError::Custom {
            code: "WEB_SEARCH_PARSE_FAILED".to_owned(),
            message: error.to_string(),
            details: None,
        })?;
    let results = json_body
        .get("web")
        .and_then(|value| value.get("results"))
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .map(|item| {
                    json!({
                        "title": item.get("title").and_then(Value::as_str).unwrap_or(""),
                        "url": item.get("url").and_then(Value::as_str).unwrap_or(""),
                        "snippet": item.get("description").and_then(Value::as_str).unwrap_or(""),
                    })
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    Ok(json!({
        "query": query,
        "results": results,
    }))
}

fn string_map(value: Option<&Value>) -> HashMap<String, String> {
    value
        .and_then(Value::as_object)
        .map(|map| {
            map.iter()
                .filter_map(|(key, value)| {
                    value.as_str().map(|value| (key.clone(), value.to_owned()))
                })
                .collect()
        })
        .unwrap_or_default()
}
