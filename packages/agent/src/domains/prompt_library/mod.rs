//! prompt library domain worker.
//!
//! This module owns canonical function execution for the prompt library
//! namespace and keeps domain contracts, services, and tests beside the worker
//! that uses them. Prompt snippets and captured prompt history are `artifact`
//! resources with system scope because they are reusable library state, not
//! chat-session state. Old prompt-library SQLite rows are not runtime source
//! truth.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub mod implementation;
pub(crate) use deps::Deps;
pub use implementation::*;

use base64::Engine;
use chrono::{Duration as ChronoDuration, Utc};
use serde_json::{Value, json};
use uuid::Uuid;

use crate::domains::prompt_library::implementation::normalize::{
    hash_hex, is_blank, normalize_for_hash,
};
use crate::domains::worker::DomainRegistrationContext;
use crate::domains::worker::DomainWorkerModule;
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, FunctionId, Invocation, TraceId,
};
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::params::{opt_string, opt_u64, require_string_param};
use crate::shared::server::validation::validate_string_param;

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
const MAX_LIST_LIMIT: usize = 200;
const DEFAULT_LIST_LIMIT: usize = 50;
const SNIPPET_NAME_MAX: usize = 100;
const HISTORY_RESOURCE_PREFIX: &str = "artifact:prompt-history:";
const SNIPPET_RESOURCE_PREFIX: &str = "artifact:prompt-snippet:";

async fn prompt_history_list_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let limit_raw =
        usize::try_from(opt_u64(params, "limit", DEFAULT_LIST_LIMIT as u64)).unwrap_or(usize::MAX);
    if limit_raw > MAX_LIST_LIMIT {
        return Err(CapabilityError::InvalidParams {
            message: format!("'limit' must be ≤ {MAX_LIST_LIMIT} (got {limit_raw})"),
        });
    }
    let limit = limit_raw.clamp(1, MAX_LIST_LIMIT);
    let cursor = opt_string(params, "cursor");
    let query = opt_string(params, "query");
    if let Some(ref query) = query {
        validate_string_param(query, "query", MAX_SEARCH_QUERY_LEN)?;
    }
    let cursor_pair = cursor.map(decode_cursor).transpose()?;
    let query_lower = query
        .as_deref()
        .map(str::trim)
        .filter(|query| !query.is_empty())
        .map(str::to_lowercase);

    let mut items = history_items(deps).await?;
    if let Some(query) = query_lower {
        items.retain(|item| {
            item.get("text")
                .and_then(Value::as_str)
                .map(str::to_lowercase)
                .is_some_and(|text| text.contains(&query))
        });
    }
    if let Some((last_used_at, id)) = cursor_pair {
        items.retain(|item| {
            let item_last = item
                .get("lastUsedAt")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let item_id = item.get("id").and_then(Value::as_str).unwrap_or_default();
            item_last < last_used_at.as_str()
                || (item_last == last_used_at.as_str() && item_id < id.as_str())
        });
    }
    let next_cursor = if items.len() > limit {
        let cursor_item = items.get(limit - 1).cloned();
        items.truncate(limit);
        cursor_item.and_then(|item| {
            Some(encode_cursor(
                item.get("lastUsedAt")?.as_str()?,
                item.get("id")?.as_str()?,
            ))
        })
    } else {
        None
    };
    Ok(json!({"items": items, "nextCursor": next_cursor}))
}

async fn prompt_history_record_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let params = Some(&invocation.payload);
    let prompt = require_string_param(params, "prompt")?;
    validate_string_param(
        &prompt,
        "prompt",
        crate::shared::server::validation::MAX_PROMPT_LENGTH,
    )?;
    if is_blank(&prompt) {
        return Ok(json!({"recorded": false, "reason": "blank_prompt", "resourceRefs": []}));
    }
    let source = opt_string(params, "source");
    if source
        .as_deref()
        .is_some_and(|source| source.starts_with("cron"))
    {
        return Ok(json!({"recorded": false, "reason": "cron_source", "resourceRefs": []}));
    }
    let settings = crate::domains::settings::get_settings()
        .prompt_library
        .clone();
    if !settings.history_enabled {
        return Ok(json!({"recorded": false, "reason": "history_disabled", "resourceRefs": []}));
    }
    reject_raw_secret_text(&prompt, "prompt")?;

    let now = Utc::now().to_rfc3339();
    let normalized = normalize_for_hash(&prompt);
    let id = hash_hex(normalized.as_bytes());
    let resource_id = history_resource_id(&id);
    let inspection = inspect_resource(deps, Some(invocation), &resource_id).await?;
    let (payload, function_id, role) = if let Some(inspection) = inspection {
        let mut payload = current_payload(&inspection)?;
        let use_count = payload.get("useCount").and_then(Value::as_i64).unwrap_or(1) + 1;
        payload["lastUsedAt"] = json!(now);
        payload["useCount"] = json!(use_count);
        (
            json!({
                "resourceId": resource_id,
                "expectedCurrentVersionId": inspection.pointer("/resource/currentVersionId").cloned().unwrap_or(Value::Null),
                "lifecycle": "promoted",
                "payload": payload,
            }),
            "resource::update",
            "updated",
        )
    } else {
        let trimmed = prompt.trim().to_owned();
        let payload = json!({
            "id": id,
            "title": "Prompt history",
            "body": trimmed,
            "format": "prompt",
            "summary": "Captured interactive prompt",
            "text": trimmed,
            "firstUsedAt": now,
            "lastUsedAt": now,
            "useCount": 1,
            "charCount": prompt.trim().chars().count() as i64,
            "metadata": {"domain": "prompt_library", "recordKind": "history"}
        });
        (
            json!({
                "resourceId": resource_id,
                "scope": "system",
                "lifecycle": "promoted",
                "payload": payload,
                "policy": {"retention": "prompt_history"}
            }),
            "artifact::create",
            "created",
        )
    };
    let recorded = invoke_resource_capability(
        deps,
        Some(invocation),
        function_id,
        payload,
        role,
        "resource.write",
    )
    .await?;
    let mut refs = resource_refs(&recorded);
    if settings.history_auto_prune {
        refs.extend(prune_history_resources(deps, invocation, &settings).await?);
    }
    Ok(json!({"recorded": true, "reason": Value::Null, "resourceRefs": refs}))
}

async fn prompt_history_delete_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let id = require_string_param(Some(&invocation.payload), "id")?;
    let resource_id = history_resource_id(&id);
    let Some(inspection) = inspect_resource(deps, Some(invocation), &resource_id).await? else {
        return Ok(json!({"deleted": false, "resourceRefs": []}));
    };
    if inspection["resource"]["lifecycle"] == "discarded" {
        return Ok(json!({"deleted": false, "resourceRefs": []}));
    }
    let discarded = discard_artifact(deps, invocation, &resource_id).await?;
    Ok(json!({"deleted": true, "resourceRefs": resource_refs(&discarded)}))
}

async fn prompt_history_clear_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let histories = history_resources(deps).await?;
    let mut refs = Vec::new();
    let mut deleted_count = 0_u64;
    for resource in histories {
        if resource["lifecycle"] == "discarded" {
            continue;
        }
        let Some(resource_id) = resource.get("resourceId").and_then(Value::as_str) else {
            continue;
        };
        let discarded = discard_artifact(deps, invocation, resource_id).await?;
        refs.extend(resource_refs(&discarded));
        deleted_count += 1;
    }
    Ok(json!({"deletedCount": deleted_count, "resourceRefs": refs}))
}

async fn prompt_snippet_list_value(deps: &Deps) -> Result<Value, CapabilityError> {
    Ok(json!({ "items": snippet_items(deps).await? }))
}

async fn prompt_snippet_get_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let id = require_string_param(params, "id")?;
    let inspection = inspect_resource(deps, None, &snippet_resource_id(&id)).await?;
    let snippet = inspection
        .filter(|inspection| inspection["resource"]["lifecycle"] != "discarded")
        .and_then(|inspection| snippet_from_payload(&current_payload(&inspection).ok()?))
        .ok_or_else(|| CapabilityError::NotFound {
            code: "SNIPPET_NOT_FOUND".into(),
            message: format!("Snippet not found: {id}"),
        })?;
    Ok(json!({ "snippet": snippet }))
}

async fn prompt_snippet_create_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let params = Some(&invocation.payload);
    let name = validate_snippet_name(&require_string_param(params, "name")?)?;
    let text = validate_snippet_text(&require_string_param(params, "text")?)?;
    let id = Uuid::now_v7().to_string();
    let now = Utc::now().to_rfc3339();
    let snippet_payload = json!({
        "id": id,
        "title": name,
        "body": text,
        "format": "prompt",
        "summary": "Prompt library snippet",
        "name": name,
        "text": text,
        "createdAt": now,
        "updatedAt": now,
        "metadata": {"domain": "prompt_library", "recordKind": "snippet"}
    });
    let created = invoke_resource_capability(
        deps,
        Some(invocation),
        "artifact::create",
        json!({
            "resourceId": snippet_resource_id(&id),
            "scope": "system",
            "lifecycle": "promoted",
            "payload": snippet_payload,
            "policy": {"retention": "prompt_snippet"}
        }),
        "snippet:create",
        "resource.write",
    )
    .await?;
    let snippet = created
        .get("resource")
        .and_then(|resource| resource.get("currentVersionId"))
        .and_then(|_| created.pointer("/resource/initialPayload"))
        .and_then(snippet_from_payload)
        .unwrap_or_else(|| {
            json!({
                "id": id,
                "name": name,
                "text": text,
                "createdAt": now,
                "updatedAt": now
            })
        });
    Ok(json!({"snippet": snippet, "resourceRefs": resource_refs(&created)}))
}

async fn prompt_snippet_update_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let params = Some(&invocation.payload);
    let id = require_string_param(params, "id")?;
    let name = opt_string(params, "name")
        .map(|name| validate_snippet_name(&name))
        .transpose()?;
    let text = opt_string(params, "text")
        .map(|text| validate_snippet_text(&text))
        .transpose()?;
    if name.is_none() && text.is_none() {
        return Err(CapabilityError::InvalidParams {
            message: "update requires at least one of 'name' or 'text'".into(),
        });
    }
    let resource_id = snippet_resource_id(&id);
    let inspection = inspect_resource(deps, Some(invocation), &resource_id)
        .await?
        .filter(|inspection| inspection["resource"]["lifecycle"] != "discarded")
        .ok_or_else(|| CapabilityError::NotFound {
            code: "SNIPPET_NOT_FOUND".into(),
            message: format!("Snippet not found: {id}"),
        })?;
    let mut payload = current_payload(&inspection)?;
    if let Some(name) = name {
        payload["title"] = json!(name);
        payload["name"] = json!(name);
    }
    if let Some(text) = text {
        payload["body"] = json!(text);
        payload["text"] = json!(text);
    }
    payload["updatedAt"] = json!(Utc::now().to_rfc3339());
    let updated = invoke_resource_capability(
        deps,
        Some(invocation),
        "artifact::update",
        json!({
            "resourceId": resource_id,
            "expectedCurrentVersionId": inspection.pointer("/resource/currentVersionId").cloned().unwrap_or(Value::Null),
            "payload": payload,
        }),
        "snippet:update",
        "resource.write",
    )
    .await?;
    let snippet = updated
        .get("version")
        .and_then(|version| version.get("payload"))
        .and_then(snippet_from_payload)
        .ok_or_else(|| CapabilityError::Internal {
            message: "updated snippet payload was invalid".to_owned(),
        })?;
    Ok(json!({"snippet": snippet, "resourceRefs": resource_refs(&updated)}))
}

async fn prompt_snippet_delete_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let id = require_string_param(Some(&invocation.payload), "id")?;
    let resource_id = snippet_resource_id(&id);
    let Some(inspection) = inspect_resource(deps, Some(invocation), &resource_id).await? else {
        return Ok(json!({"deleted": false, "resourceRefs": []}));
    };
    if inspection["resource"]["lifecycle"] == "discarded" {
        return Ok(json!({"deleted": false, "resourceRefs": []}));
    }
    let discarded = discard_artifact(deps, invocation, &resource_id).await?;
    Ok(json!({"deleted": true, "resourceRefs": resource_refs(&discarded)}))
}

async fn history_items(deps: &Deps) -> Result<Vec<Value>, CapabilityError> {
    let mut items = Vec::new();
    for resource in history_resources(deps).await? {
        if resource["lifecycle"] == "discarded" {
            continue;
        }
        let Some(resource_id) = resource.get("resourceId").and_then(Value::as_str) else {
            continue;
        };
        if let Some(inspection) = inspect_resource(deps, None, resource_id).await?
            && let Ok(payload) = current_payload(&inspection)
            && let Some(item) = history_from_payload(&payload)
        {
            items.push(item);
        }
    }
    items.sort_by(compare_history_items);
    Ok(items)
}

async fn snippet_items(deps: &Deps) -> Result<Vec<Value>, CapabilityError> {
    let mut items = Vec::new();
    for resource in snippet_resources(deps).await? {
        if resource["lifecycle"] == "discarded" {
            continue;
        }
        let Some(resource_id) = resource.get("resourceId").and_then(Value::as_str) else {
            continue;
        };
        if let Some(inspection) = inspect_resource(deps, None, resource_id).await?
            && let Ok(payload) = current_payload(&inspection)
            && let Some(item) = snippet_from_payload(&payload)
        {
            items.push(item);
        }
    }
    items.sort_by(compare_snippets);
    Ok(items)
}

async fn history_resources(deps: &Deps) -> Result<Vec<Value>, CapabilityError> {
    prefixed_artifacts(deps, HISTORY_RESOURCE_PREFIX).await
}

async fn snippet_resources(deps: &Deps) -> Result<Vec<Value>, CapabilityError> {
    prefixed_artifacts(deps, SNIPPET_RESOURCE_PREFIX).await
}

async fn prefixed_artifacts(deps: &Deps, prefix: &str) -> Result<Vec<Value>, CapabilityError> {
    let listed = invoke_resource_capability(
        deps,
        None,
        "resource::list",
        json!({"kind": "artifact", "limit": 10_000}),
        prefix,
        "resource.read",
    )
    .await?;
    Ok(listed["resources"]
        .as_array()
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .filter(|resource| {
            resource["resourceId"]
                .as_str()
                .is_some_and(|id| id.starts_with(prefix))
        })
        .collect())
}

async fn inspect_resource(
    deps: &Deps,
    parent: Option<&Invocation>,
    resource_id: &str,
) -> Result<Option<Value>, CapabilityError> {
    let value = invoke_resource_capability(
        deps,
        parent,
        "resource::inspect",
        json!({"resourceId": resource_id}),
        &format!("inspect:{resource_id}"),
        "resource.read",
    )
    .await?;
    Ok(value
        .get("inspection")
        .cloned()
        .filter(|value| !value.is_null()))
}

async fn discard_artifact(
    deps: &Deps,
    parent: &Invocation,
    resource_id: &str,
) -> Result<Value, CapabilityError> {
    invoke_resource_capability(
        deps,
        Some(parent),
        "artifact::discard",
        json!({"resourceId": resource_id}),
        &format!("discard:{resource_id}"),
        "resource.write",
    )
    .await
}

async fn prune_history_resources(
    deps: &Deps,
    parent: &Invocation,
    settings: &crate::domains::settings::PromptLibrarySettings,
) -> Result<Vec<Value>, CapabilityError> {
    let max_entries =
        (settings.history_max_entries > 0).then_some(settings.history_max_entries as usize);
    let cutoff = (settings.history_max_age_days > 0)
        .then(|| Utc::now() - ChronoDuration::days(settings.history_max_age_days as i64));
    if max_entries.is_none() && cutoff.is_none() {
        return Ok(Vec::new());
    }
    let mut histories = Vec::new();
    for resource in history_resources(deps).await? {
        if resource["lifecycle"] == "discarded" {
            continue;
        }
        let Some(resource_id) = resource.get("resourceId").and_then(Value::as_str) else {
            continue;
        };
        if let Some(inspection) = inspect_resource(deps, Some(parent), resource_id).await?
            && let Ok(payload) = current_payload(&inspection)
            && let Some(item) = history_from_payload(&payload)
        {
            histories.push((resource_id.to_owned(), item));
        }
    }
    histories.sort_by(|(_, left), (_, right)| compare_history_items(left, right));
    let mut refs = Vec::new();
    for (index, (resource_id, item)) in histories.iter().enumerate() {
        let exceeds_count = max_entries.is_some_and(|max| index >= max);
        let exceeds_age = cutoff.is_some_and(|cutoff| {
            item.get("lastUsedAt")
                .and_then(Value::as_str)
                .and_then(|timestamp| chrono::DateTime::parse_from_rfc3339(timestamp).ok())
                .is_some_and(|timestamp| timestamp.with_timezone(&Utc) < cutoff)
        });
        if exceeds_count || exceeds_age {
            let discarded = discard_artifact(deps, parent, resource_id).await?;
            refs.extend(resource_refs(&discarded));
        }
    }
    Ok(refs)
}

fn current_payload(inspection: &Value) -> Result<Value, CapabilityError> {
    let current = inspection
        .pointer("/resource/currentVersionId")
        .and_then(Value::as_str)
        .ok_or_else(|| CapabilityError::Internal {
            message: "resource has no current version".to_owned(),
        })?;
    inspection
        .get("versions")
        .and_then(Value::as_array)
        .and_then(|versions| {
            versions
                .iter()
                .find(|version| version["versionId"] == current)
        })
        .and_then(|version| version.get("payload"))
        .cloned()
        .ok_or_else(|| CapabilityError::Internal {
            message: "resource current payload is missing".to_owned(),
        })
}

fn history_from_payload(payload: &Value) -> Option<Value> {
    Some(json!({
        "id": payload.get("id")?.as_str()?,
        "text": payload.get("text").or_else(|| payload.get("body"))?.as_str()?,
        "firstUsedAt": payload.get("firstUsedAt")?.as_str()?,
        "lastUsedAt": payload.get("lastUsedAt")?.as_str()?,
        "useCount": payload.get("useCount")?.as_i64()?,
        "charCount": payload.get("charCount")?.as_i64()?,
    }))
}

fn snippet_from_payload(payload: &Value) -> Option<Value> {
    Some(json!({
        "id": payload.get("id")?.as_str()?,
        "name": payload.get("name").or_else(|| payload.get("title"))?.as_str()?,
        "text": payload.get("text").or_else(|| payload.get("body"))?.as_str()?,
        "createdAt": payload.get("createdAt")?.as_str()?,
        "updatedAt": payload.get("updatedAt")?.as_str()?,
    }))
}

fn compare_history_items(left: &Value, right: &Value) -> std::cmp::Ordering {
    right
        .get("lastUsedAt")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .cmp(
            left.get("lastUsedAt")
                .and_then(Value::as_str)
                .unwrap_or_default(),
        )
        .then_with(|| {
            right
                .get("id")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .cmp(left.get("id").and_then(Value::as_str).unwrap_or_default())
        })
}

fn compare_snippets(left: &Value, right: &Value) -> std::cmp::Ordering {
    right
        .get("updatedAt")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .cmp(
            left.get("updatedAt")
                .and_then(Value::as_str)
                .unwrap_or_default(),
        )
        .then_with(|| {
            right
                .get("id")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .cmp(left.get("id").and_then(Value::as_str).unwrap_or_default())
        })
}

fn validate_snippet_name(name: &str) -> Result<String, CapabilityError> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return Err(CapabilityError::InvalidParams {
            message: "snippet name must be non-empty".to_owned(),
        });
    }
    if trimmed.chars().count() > SNIPPET_NAME_MAX {
        return Err(CapabilityError::InvalidParams {
            message: format!("snippet name must be ≤ {SNIPPET_NAME_MAX} characters"),
        });
    }
    reject_raw_secret_text(trimmed, "name")?;
    Ok(trimmed.to_owned())
}

fn validate_snippet_text(text: &str) -> Result<String, CapabilityError> {
    if text.is_empty() {
        return Err(CapabilityError::InvalidParams {
            message: "snippet text must be non-empty".to_owned(),
        });
    }
    validate_string_param(
        text,
        "text",
        crate::shared::server::validation::MAX_PROMPT_LENGTH,
    )?;
    reject_raw_secret_text(text, "text")?;
    Ok(text.to_owned())
}

fn reject_raw_secret_text(text: &str, field: &str) -> Result<(), CapabilityError> {
    let trimmed = text.trim();
    if trimmed.starts_with("secret_ref:") || trimmed.starts_with("vault:") {
        return Ok(());
    }
    let lower = trimmed.to_ascii_lowercase();
    let secret_like = trimmed.starts_with("sk-")
        || lower.contains("secret=")
        || lower.contains("token=")
        || lower.contains("password=")
        || lower.contains("api_key=")
        || lower.contains("apikey=");
    if secret_like {
        return Err(CapabilityError::InvalidParams {
            message: format!(
                "{field} contains secret-like value; store only secret_ref or vault handles"
            ),
        });
    }
    Ok(())
}

fn history_resource_id(id: &str) -> String {
    format!("{HISTORY_RESOURCE_PREFIX}{id}")
}

fn snippet_resource_id(id: &str) -> String {
    format!("{SNIPPET_RESOURCE_PREFIX}{id}")
}

fn encode_cursor(last_used_at: &str, id: &str) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(format!("{last_used_at}|{id}"))
}

fn decode_cursor(encoded: String) -> Result<(String, String), CapabilityError> {
    let raw = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(encoded.as_bytes())
        .map_err(|error| CapabilityError::InvalidParams {
            message: format!("bad cursor: {error}"),
        })?;
    let decoded = String::from_utf8(raw).map_err(|error| CapabilityError::InvalidParams {
        message: format!("bad cursor utf8: {error}"),
    })?;
    let (timestamp, id) =
        decoded
            .split_once('|')
            .ok_or_else(|| CapabilityError::InvalidParams {
                message: "bad cursor format".to_owned(),
            })?;
    if timestamp.is_empty() || id.is_empty() {
        return Err(CapabilityError::InvalidParams {
            message: "empty cursor field".to_owned(),
        });
    }
    Ok((timestamp.to_owned(), id.to_owned()))
}

fn resource_refs(value: &Value) -> Vec<Value> {
    value["resourceRefs"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

async fn invoke_resource_capability(
    deps: &Deps,
    parent: Option<&Invocation>,
    function_id: &str,
    payload: Value,
    idempotency_label: &str,
    scope: &str,
) -> Result<Value, CapabilityError> {
    let mut causal = CausalContext::new(
        ActorId::new("system:prompt_library").map_err(engine_capability_error)?,
        ActorKind::System,
        AuthorityGrantId::new("engine-system").map_err(engine_capability_error)?,
        TraceId::new(
            parent
                .map(|invocation| invocation.causal_context.trace_id.as_str())
                .unwrap_or("prompt-library-resource"),
        )
        .map_err(engine_capability_error)?,
    )
    .with_scope(scope)
    .with_idempotency_key(format!(
        "prompt_library:{}:{idempotency_label}",
        parent
            .map(|invocation| invocation.id.as_str())
            .unwrap_or("read")
    ));
    if let Some(parent) = parent {
        causal.parent_invocation_id = Some(parent.id.clone());
        if let Some(session_id) = &parent.causal_context.session_id {
            causal = causal.with_session_id(session_id.clone());
        }
        if let Some(workspace_id) = &parent.causal_context.workspace_id {
            causal = causal.with_workspace_id(workspace_id.clone());
        }
    } else {
        causal = causal
            .with_session_id("prompt-library")
            .with_workspace_id("prompt-library");
    }
    let result = deps
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new(function_id).map_err(engine_capability_error)?,
            payload,
            causal,
        ))
        .await;
    if let Some(error) = result.error {
        return Err(engine_capability_error(error));
    }
    result.value.ok_or_else(|| CapabilityError::Internal {
        message: format!("{function_id} returned no value"),
    })
}

fn engine_capability_error(error: impl std::fmt::Display) -> CapabilityError {
    CapabilityError::Custom {
        code: "PROMPT_LIBRARY_RESOURCE_OPERATION_FAILED".to_owned(),
        message: error.to_string(),
        details: None,
    }
}
