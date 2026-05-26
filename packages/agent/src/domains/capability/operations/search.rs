//! Capability search request handling and result projection.

use serde_json::{Value, json};

use super::{
    actor_from_invocation, admin_vector_ready, allows_degraded_vector_search,
    capability_result_value, degraded_search_status, effect_field, registry_metadata_sync_policy,
    registry_needs_metadata_sync, registry_store_error, render_search_summary, risk_field,
    schedule_vector_warmup, search_policy_from_runtime, search_results_need_vector_warmup,
};
use crate::domains::capability::Deps;
use crate::domains::capability::registry::{
    CapabilityIndexSearchResult, CapabilityRegistrySnapshot, CapabilitySearchFilters, bool_field,
    string_field, u64_field,
};
use crate::engine::Invocation;
use crate::shared::content::CapabilityResultContent;
use crate::shared::model_capabilities::{CapabilityResult, CapabilityResultBody};
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;

const DEFAULT_LIMIT: usize = 12;
const MAX_LIMIT: usize = 50;

pub(crate) async fn search_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let params = &invocation.payload;
    let queries = search_queries(params)?;
    let limit = u64_field(params, "limit")
        .map(|value| value.clamp(1, MAX_LIMIT as u64) as usize)
        .unwrap_or(DEFAULT_LIMIT);
    let cursor_offset = parse_cursor(params)?;
    let filters = CapabilitySearchFilters {
        kind: string_field(params, "kind"),
        contract_id: string_field(params, "contractId")
            .or_else(|| string_field(params, "contract_id")),
        namespace: string_field(params, "namespace"),
        plugin_id: string_field(params, "pluginId").or_else(|| string_field(params, "plugin_id")),
        effect: effect_field(params, "effect")?,
        risk_max: risk_field(params, "riskMax")?,
        trust_tier_min: string_field(params, "trustTierMin")
            .or_else(|| string_field(params, "trust_tier_min")),
        include_unavailable: bool_field(params, "includeUnavailable").unwrap_or(false),
        scope: string_field(params, "scope"),
    };

    let actor = actor_from_invocation(invocation)?;
    let functions = deps
        .engine_host
        .discover(&filters.function_query(actor))
        .await;

    let catalog_revision = deps.engine_host.catalog_revision().await;
    let snapshot = CapabilityRegistrySnapshot::new(functions, catalog_revision.0);
    let policy = search_policy_from_runtime(invocation)?;
    let allow_degraded_vector_search = allows_degraded_vector_search(&policy);
    let warmup_snapshot = if policy.local_vector {
        Some(snapshot.clone())
    } else {
        None
    };
    let queries_for_index = queries.clone();
    let index_limit = cursor_offset.saturating_add(limit).saturating_add(1);
    let store = deps.registry_store.clone();
    let embedding_provider = deps.embedding_provider.clone();
    let trace_id = invocation.causal_context.trace_id.as_str().to_owned();
    let filters_for_index = filters.clone();
    let catalog_revision_value = catalog_revision.0;
    let search_result = run_blocking_task("capability.search.index", move || {
        let mut store = store.lock().map_err(|_| CapabilityError::Internal {
            message: "capability registry store mutex poisoned".to_owned(),
        })?;
        let admin_before = store.admin_status().map_err(registry_store_error)?;
        if registry_needs_metadata_sync(&admin_before, catalog_revision_value) {
            let sync_policy = registry_metadata_sync_policy();
            if let Err(error) =
                store.sync_snapshot(&snapshot, embedding_provider.as_ref(), &sync_policy)
            {
                let _ = store.record_audit_event(
                    "capability.search",
                    Some(&trace_id),
                    json!({
                        "status": "error",
                        "queries": queries_for_index,
                        "catalogRevision": catalog_revision_value,
                        "error": error.clone(),
                    }),
                );
                return Err(registry_store_error(error));
            }
        }
        let mut effective_policy = policy.clone();
        let mut degraded_status = None;
        if allow_degraded_vector_search {
            let admin = store.admin_status().map_err(registry_store_error)?;
            if !admin_vector_ready(&admin) {
                effective_policy.local_vector = false;
                effective_policy.require_local_vector = false;
                degraded_status = Some(degraded_search_status(
                    &admin,
                    &policy,
                    embedding_provider.as_ref(),
                ));
            }
        }
        let mut results = Vec::new();
        for query in &queries_for_index {
            let mut result = store
                .search(
                    query,
                    &filters_for_index,
                    &effective_policy,
                    index_limit,
                    embedding_provider.as_ref(),
                )
                .map_err(registry_store_error)?;
            if let Some(status) = degraded_status.clone() {
                result.status = status;
            }
            results.push((query.clone(), result));
        }
        store
            .record_audit_event(
                "capability.search",
                Some(&trace_id),
                json!({
                    "queries": queries_for_index,
                    "filters": {
                        "kind": filters_for_index.kind,
                        "contractId": filters_for_index.contract_id,
                        "namespace": filters_for_index.namespace,
                        "pluginId": filters_for_index.plugin_id,
                    },
                    "catalogRevision": catalog_revision_value,
                    "indexStatus": results
                        .first()
                        .map(|(_, result)| result.status.clone()),
                }),
            )
            .map_err(registry_store_error)?;
        Ok(results)
    })
    .await;
    let search_results = search_result?;
    if let Some(snapshot) = warmup_snapshot
        && search_results_need_vector_warmup(&search_results)
    {
        schedule_vector_warmup(snapshot, deps);
    }
    render_search_result_value(search_results, catalog_revision.0, cursor_offset, limit)
}

pub(super) fn search_queries(params: &Value) -> Result<Vec<String>, CapabilityError> {
    if let Some(values) = params.get("queries").and_then(Value::as_array)
        && !values.is_empty()
    {
        let mut queries = Vec::new();
        for value in values.iter().take(8) {
            let Some(query) = value.as_str() else {
                return Err(CapabilityError::InvalidParams {
                    message: "capability search queries must be strings".to_owned(),
                });
            };
            queries.push(query.to_owned());
        }
        return Ok(queries);
    }
    Ok(vec![string_field(params, "query").unwrap_or_default()])
}

pub(super) fn render_search_result_value(
    search_results: Vec<(String, CapabilityIndexSearchResult)>,
    catalog_revision: u64,
    cursor_offset: usize,
    limit: usize,
) -> Result<Value, CapabilityError> {
    if search_results.len() == 1 {
        let (query, search_result) = search_results
            .into_iter()
            .next()
            .expect("single search result exists");
        let next_cursor = if search_result.hits.len() > cursor_offset.saturating_add(limit) {
            Some(cursor_offset.saturating_add(limit).to_string())
        } else {
            None
        };
        let page_hits = search_result
            .hits
            .into_iter()
            .skip(cursor_offset)
            .take(limit)
            .collect::<Vec<_>>();
        let summary = render_search_summary(&query, &page_hits);
        let results =
            serde_json::to_value(&page_hits).map_err(|error| CapabilityError::Internal {
                message: error.to_string(),
            })?;
        return capability_result_value(CapabilityResult {
            content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(summary)]),
            details: Some(json!({
                "query": query,
                "catalogRevision": catalog_revision,
                "results": results,
                "nextCursor": next_cursor,
                "searchMode": search_result.status
            })),
            is_error: None,
            stop_turn: None,
        });
    }

    let mut batch_results = Vec::new();
    let mut summary_lines = Vec::new();
    for (query, search_result) in search_results {
        let next_cursor = if search_result.hits.len() > cursor_offset.saturating_add(limit) {
            Some(cursor_offset.saturating_add(limit).to_string())
        } else {
            None
        };
        let page_hits = search_result
            .hits
            .into_iter()
            .skip(cursor_offset)
            .take(limit)
            .collect::<Vec<_>>();
        let result_count = page_hits.len();
        let query_summary = render_search_summary(&query, &page_hits);
        let results =
            serde_json::to_value(&page_hits).map_err(|error| CapabilityError::Internal {
                message: error.to_string(),
            })?;
        summary_lines.push(format!(
            "## Query: {query}\n{query_summary}\n({result_count} result(s))"
        ));
        batch_results.push(json!({
            "query": query,
            "results": results,
            "nextCursor": next_cursor,
            "searchMode": search_result.status,
        }));
    }
    capability_result_value(CapabilityResult {
        content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(format!(
            "Capability batch search completed.\n\n{}",
            summary_lines.join("\n\n")
        ))]),
        details: Some(json!({
            "queries": batch_results,
            "catalogRevision": catalog_revision,
        })),
        is_error: None,
        stop_turn: None,
    })
}

fn parse_cursor(params: &Value) -> Result<usize, CapabilityError> {
    let Some(cursor) = string_field(params, "cursor") else {
        return Ok(0);
    };
    let raw = cursor
        .strip_prefix("offset:")
        .unwrap_or(cursor.as_str())
        .trim();
    raw.parse::<usize>()
        .map_err(|_| CapabilityError::InvalidParams {
            message: format!("Unsupported capability search cursor '{cursor}'"),
        })
}
