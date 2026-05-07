use super::*;

const MAX_SEARCH_QUERY_LEN: usize = 200;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &EngineCapabilityDeps,
) -> Result<Value, RpcError> {
    let payload = &invocation.payload;
    match method {
        "promptHistory.list" => prompt_history_list_value(Some(payload), deps).await,
        "promptHistory.delete" => prompt_history_delete_value(Some(payload), deps).await,
        "promptHistory.clear" => prompt_history_clear_value(deps).await,
        "promptSnippet.list" => prompt_snippet_list_value(deps).await,
        "promptSnippet.get" => prompt_snippet_get_value(Some(payload), deps).await,
        "promptSnippet.create" => prompt_snippet_create_value(Some(payload), deps).await,
        "promptSnippet.update" => prompt_snippet_update_value(Some(payload), deps).await,
        "promptSnippet.delete" => prompt_snippet_delete_value(Some(payload), deps).await,
        _ => Err(RpcError::Internal {
            message: format!("prompt-library method {method} is not engine-owned"),
        }),
    }
}

async fn prompt_history_list_value(
    params: Option<&Value>,
    deps: &EngineCapabilityDeps,
) -> Result<Value, RpcError> {
    let limit_raw = opt_u64(params, "limit", store::DEFAULT_LIST_LIMIT as u64);
    if limit_raw > store::MAX_LIST_LIMIT as u64 {
        return Err(RpcError::InvalidParams {
            message: format!(
                "'limit' must be ≤ {} (got {limit_raw})",
                store::MAX_LIST_LIMIT
            ),
        });
    }
    let limit = limit_raw as u32;
    let cursor = opt_string(params, "cursor");
    let query = opt_string(params, "query");
    if let Some(ref query) = query {
        validate_string_param(query, "query", MAX_SEARCH_QUERY_LEN)?;
    }

    let page = store::list_history(deps.event_store.pool(), limit, cursor, query)
        .map_err(map_store_err)?;
    Ok(json!({
        "items": to_json_value(&page.items)?,
        "nextCursor": page.next_cursor,
    }))
}

async fn prompt_history_delete_value(
    params: Option<&Value>,
    deps: &EngineCapabilityDeps,
) -> Result<Value, RpcError> {
    let id = require_string_param(params, "id")?;
    let deleted = store::delete_history(deps.event_store.pool(), &id).map_err(map_store_err)?;
    Ok(json!({ "deleted": deleted }))
}

async fn prompt_history_clear_value(deps: &EngineCapabilityDeps) -> Result<Value, RpcError> {
    let deleted_count = store::clear_history(deps.event_store.pool()).map_err(map_store_err)?;
    Ok(json!({ "deletedCount": deleted_count }))
}

async fn prompt_snippet_list_value(deps: &EngineCapabilityDeps) -> Result<Value, RpcError> {
    let items = store::list_snippets(deps.event_store.pool()).map_err(map_store_err)?;
    Ok(json!({ "items": to_json_value(&items)? }))
}

async fn prompt_snippet_get_value(
    params: Option<&Value>,
    deps: &EngineCapabilityDeps,
) -> Result<Value, RpcError> {
    let id = require_string_param(params, "id")?;
    let snippet = store::get_snippet(deps.event_store.pool(), &id)
        .map_err(map_store_err)?
        .ok_or_else(|| RpcError::NotFound {
            code: "SNIPPET_NOT_FOUND".into(),
            message: format!("Snippet not found: {id}"),
        })?;
    Ok(json!({ "snippet": to_json_value(&snippet)? }))
}

async fn prompt_snippet_create_value(
    params: Option<&Value>,
    deps: &EngineCapabilityDeps,
) -> Result<Value, RpcError> {
    let name = require_string_param(params, "name")?;
    let text = require_string_param(params, "text")?;
    validate_string_param(
        &text,
        "text",
        crate::server::rpc::validation::MAX_PROMPT_LENGTH,
    )?;

    let snippet =
        store::create_snippet(deps.event_store.pool(), &name, &text).map_err(map_store_err)?;
    Ok(json!({ "snippet": to_json_value(&snippet)? }))
}

async fn prompt_snippet_update_value(
    params: Option<&Value>,
    deps: &EngineCapabilityDeps,
) -> Result<Value, RpcError> {
    let id = require_string_param(params, "id")?;
    let name = opt_string(params, "name");
    let text = opt_string(params, "text");

    if name.is_none() && text.is_none() {
        return Err(RpcError::InvalidParams {
            message: "update requires at least one of 'name' or 'text'".into(),
        });
    }
    if let Some(ref text) = text {
        validate_string_param(
            text,
            "text",
            crate::server::rpc::validation::MAX_PROMPT_LENGTH,
        )?;
    }

    let updated = store::update_snippet(deps.event_store.pool(), &id, name, text)
        .map_err(map_store_err)?
        .ok_or_else(|| RpcError::NotFound {
            code: "SNIPPET_NOT_FOUND".into(),
            message: format!("Snippet not found: {id}"),
        })?;
    Ok(json!({ "snippet": to_json_value(&updated)? }))
}

async fn prompt_snippet_delete_value(
    params: Option<&Value>,
    deps: &EngineCapabilityDeps,
) -> Result<Value, RpcError> {
    let id = require_string_param(params, "id")?;
    let deleted = store::delete_snippet(deps.event_store.pool(), &id).map_err(map_store_err)?;
    Ok(json!({ "deleted": deleted }))
}
