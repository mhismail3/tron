//! Canonical provider-tool surface selection and introspection.
//!
//! This module owns worker relevance, session promotion, stable ordering, and
//! provider-neutral surface evidence. Agent/provider code adapts the resolved
//! function contracts to provider schemas; it does not maintain a second
//! worker-selection implementation.
//!
//! `promotions` owns bounded session promotions and rebuildable success
//! evidence. `snapshots` owns provider-neutral DTOs. `filtering` owns fixed
//! audiences, ordering, access paths, retrieval projection, and digests. This
//! module remains the single selection entry point; `tests` covers the combined
//! contract. Foreground user input is deliberately omitted from delegated
//! agent-worker surfaces; workers return missing information to their parent,
//! and the parent owns the native user interaction. One-release historical
//! worker await/result names are synthesized only for an exact trusted
//! dynamic-worker `agentTools` allowlist; they never enter the live catalog,
//! fixed inventory, discovery, or an ordinary provider surface.

use std::collections::{BTreeMap, BTreeSet};

use crate::engine::{
    ActorContext, ActorId, ActorKind, DelegationPolicy, EngineHostHandle, FunctionDefinition,
    ModelToolAudience, ModelToolContract,
};

const MAX_RELEVANT_WORKERS: usize = 12;
const RETAINED_WORKER_AGENT_TOOL_ALIASES: [(&str, &str); 2] = [
    ("worker_await", "worker_kernel::await"),
    ("worker_result_read", "worker_kernel::result_read"),
];

mod filtering;
mod promotions;
mod snapshots;

pub(crate) use filtering::fixed_tool_inventory;
use filtering::*;
pub(crate) use promotions::promote_worker_for_session;
pub(super) use promotions::{publish_worker_surface_evidence, session_worker_promotions};
use promotions::{session_worker_promotion_entries, worker_surface_evidence};
pub(crate) use snapshots::{
    AvailableWorkerToolSnapshot, EngineSurfaceSnapshot, ResolvedToolFunction, ResolvedToolSurface,
    SurfaceToolSnapshot,
};

/// Resolve the one-release model-name aliases accepted only from an immutable
/// dynamic-worker `agentTools` allowlist. These aliases never enter the live
/// catalog or fixed inventory.
pub(super) fn retained_worker_agent_tool_alias_target(model_name: &str) -> Option<&'static str> {
    RETAINED_WORKER_AGENT_TOOL_ALIASES
        .iter()
        .find_map(|(alias, function_id)| (*alias == model_name).then_some(*function_id))
}

fn retained_worker_agent_tool_aliases(
    functions: &[FunctionDefinition],
    worker_agent_tools: Option<&[String]>,
    trusted_worker_allowlist: bool,
) -> Vec<FunctionDefinition> {
    if !trusted_worker_allowlist {
        return Vec::new();
    }
    let Some(requested) = worker_agent_tools else {
        return Vec::new();
    };
    requested
        .iter()
        .filter_map(|model_name| {
            let function_id = retained_worker_agent_tool_alias_target(model_name)?;
            let mut alias = functions
                .iter()
                .find(|function| function.id.as_str() == function_id)?
                .clone();
            let (order, group) = alias
                .model_tool
                .as_ref()
                .map_or((Some(146), Some("worker_interaction".to_owned())), |tool| {
                    (tool.order, tool.group.clone())
                });
            alias.model_tool = Some(ModelToolContract {
                name: model_name.clone(),
                audience: ModelToolAudience::Specialist,
                order,
                group,
                worker: None,
            });
            Some(alias)
        })
        .collect()
}

/// Resolve the exact fixed and dynamic function contracts for one provider
/// request.
pub(crate) async fn resolve_tool_surface(
    host: &EngineHostHandle,
    session_id: &str,
    relevance_query: Option<&str>,
    origin_worker_id: Option<&str>,
    worker_agent_tools: Option<&[String]>,
    delegated_function_grant: Option<&[String]>,
) -> Result<ResolvedToolSurface, String> {
    resolve_tool_surface_inner(
        host,
        session_id,
        relevance_query,
        origin_worker_id,
        worker_agent_tools,
        delegated_function_grant,
    )
    .await
}

async fn resolve_tool_surface_inner(
    host: &EngineHostHandle,
    session_id: &str,
    relevance_query: Option<&str>,
    origin_worker_id: Option<&str>,
    worker_agent_tools: Option<&[String]>,
    delegated_function_grant: Option<&[String]>,
) -> Result<ResolvedToolSurface, String> {
    let trusted_worker_allowlist = origin_worker_id.is_some() && worker_agent_tools.is_some();
    let (actor_id, actor_kind) = if trusted_worker_allowlist {
        (
            ActorId::new("system:worker-agent-surface").map_err(|error| error.to_string())?,
            ActorKind::System,
        )
    } else {
        (
            ActorId::new(format!("agent:{session_id}")).map_err(|error| error.to_string())?,
            ActorKind::Agent,
        )
    };
    let actor = ActorContext::new(actor_id, actor_kind);
    let (catalog_revision, mut functions) = host.visible_functions_with_revision(&actor).await;
    if let Some(grant) = delegated_function_grant {
        let exact = grant.iter().map(String::as_str).collect::<BTreeSet<_>>();
        functions.retain(|function| {
            function.delegation_policy != crate::engine::DelegationPolicy::Never
                && exact.contains(function.id.as_str())
        });
    }
    functions.sort_by_key(|function| {
        (
            function
                .model_tool
                .as_ref()
                .and_then(|tool| tool.order)
                .unwrap_or(u16::MAX),
            function.id.as_str().to_owned(),
        )
    });

    // INVARIANT: retained aliases are synthesized only after the live catalog
    // and exact reusable-child grant have been resolved. They therefore cannot
    // become discoverable fixed functions or widen an ordinary/root surface.
    let retained_aliases = retained_worker_agent_tool_aliases(
        &functions,
        worker_agent_tools,
        trusted_worker_allowlist,
    );

    let explicit_agent_tools =
        worker_agent_tools.map(|tools| tools.iter().map(String::as_str).collect::<BTreeSet<_>>());
    let promotion_entries = session_worker_promotion_entries(host, session_id).await?;
    let evidence = worker_surface_evidence(host, &functions).await?;
    let dynamic_documents = functions
        .iter()
        .filter_map(|function| {
            let worker = direct_worker_contract(function)?;
            if explicit_agent_tools.as_ref().is_some_and(|allowed| {
                model_tool_name(function)
                    .as_deref()
                    .is_none_or(|model_name| !allowed.contains(model_name))
            }) {
                return None;
            }
            Some(retrieval_document(
                function,
                worker,
                evidence.get(&worker.worker_id),
            ))
        })
        .collect::<Vec<_>>();
    let available_worker_count = dynamic_documents.len();
    let applicable_promotions = promotion_entries
        .iter()
        .filter(|promotion| {
            functions.iter().any(|function| {
                direct_worker_contract(function).is_some_and(|worker| {
                    worker.worker_id == promotion.worker_id
                        && Some(worker.worker_version.as_str())
                            == promotion.worker_version.as_deref()
                })
            })
        })
        .map(|promotion| promotion.worker_id.clone())
        .collect::<BTreeSet<_>>();
    let ranking = super::retrieval::WorkerRankingOutcome::deterministic(
        super::retrieval::rank_workers(dynamic_documents, relevance_query, &applicable_promotions),
        if origin_worker_id.is_some() {
            "child_agent_allowlist"
        } else {
            "deterministic_relevance"
        },
    );
    let ranked = &ranking.ranks;
    let query_is_empty = super::retrieval::query_is_empty(relevance_query);
    let worker_rank = ranked
        .iter()
        .enumerate()
        .map(|(index, rank)| (rank.worker_id.clone(), index))
        .collect::<BTreeMap<_, _>>();
    let mut selected_dynamic = BTreeMap::new();
    if let Some(allowed) = &explicit_agent_tools {
        for function in &functions {
            if direct_worker_contract(function).is_none() {
                continue;
            }
            if model_tool_name(function)
                .as_deref()
                .is_some_and(|model_name| allowed.contains(model_name))
            {
                let _ = selected_dynamic.insert(function.id.as_str().to_owned(), "agent_allowlist");
            }
        }
    } else {
        for promotion in &promotion_entries {
            if selected_dynamic.len() >= MAX_RELEVANT_WORKERS {
                break;
            }
            let Some(rank) = ranked
                .iter()
                .find(|rank| rank.worker_id == promotion.worker_id && rank.promoted)
            else {
                continue;
            };
            let _ = selected_dynamic.insert(rank.key.clone(), "session_promotion");
        }
        for rank in ranked {
            if selected_dynamic.contains_key(&rank.key)
                || (!query_is_empty && rank.relevance_score == 0)
                || selected_dynamic.len() >= MAX_RELEVANT_WORKERS
            {
                continue;
            }
            let reason = if rank.relevance_score > 0 {
                "relevance"
            } else {
                "default"
            };
            let _ = selected_dynamic.insert(rank.key.clone(), reason);
        }
    }
    let available_workers = ranked
        .iter()
        .filter_map(|rank| {
            let function = functions
                .iter()
                .find(|function| function.id.as_str() == rank.key)?;
            let model_name = model_tool_name(function)?;
            let selection_reason = selected_dynamic
                .get(function.id.as_str())
                .map(|reason| (*reason).to_owned());
            Some(AvailableWorkerToolSnapshot {
                worker_id: rank.worker_id.clone(),
                model_name,
                function_id: function.id.as_str().to_owned(),
                function_revision: function.revision.0,
                worker_version: direct_worker_contract(function)
                    .map(|worker| worker.worker_version.clone()),
                promoted: rank.promoted,
                projected: selection_reason.is_some(),
                selection_reason,
                omission_reason: (!selected_dynamic.contains_key(function.id.as_str())).then(
                    || {
                        if !query_is_empty && rank.relevance_score == 0 {
                            "not_relevant"
                        } else if selected_dynamic.len() >= MAX_RELEVANT_WORKERS {
                            "projection_limit"
                        } else {
                            "not_selected"
                        }
                        .to_owned()
                    },
                ),
                ranking_mechanism: ranking.mechanism.clone(),
                relevance_score: rank.relevance_score,
                completed_runs: rank.completed_runs,
            })
        })
        .collect::<Vec<_>>();
    let mut seen_names = BTreeSet::new();
    let mut resolved = Vec::new();
    let mut snapshot_tools = Vec::new();
    for function in functions.iter().chain(retained_aliases.iter()) {
        if !is_provider_primitive(&function) || function.request_schema.is_none() {
            continue;
        }
        let direct_worker = direct_worker_contract(&function).cloned();
        let is_dynamic = direct_worker.is_some();
        let Some(model_name) = model_tool_name(&function) else {
            continue;
        };
        let retained_alias = retained_worker_agent_tool_alias_target(&model_name)
            .is_some_and(|target| target == function.id.as_str());
        let selection_reason = if retained_alias {
            "retained_worker_agent_tools_alias"
        } else if is_dynamic {
            let Some(reason) = selected_dynamic.get(function.id.as_str()) else {
                continue;
            };
            *reason
        } else {
            "fixed"
        };
        // Delegated agent workers cannot suspend their owning durable worker
        // invocation on a foreground-only iOS interaction. They return missing
        // information to the parent agent, which owns the user-facing request.
        if origin_worker_id.is_some() && model_name == "request_user_input" {
            continue;
        }
        if explicit_agent_tools
            .as_ref()
            .is_some_and(|allowed| !allowed.contains(model_name.as_str()))
        {
            continue;
        }
        if trusted_worker_allowlist && function.delegation_policy == DelegationPolicy::Never {
            continue;
        }
        if !model_tool_exposure_allows(&function, relevance_query, trusted_worker_allowlist) {
            continue;
        }
        if !seen_names.insert(model_name.clone()) {
            return Err(format!(
                "duplicate model tool name {model_name} in live catalog"
            ));
        }
        let input_schema = function
            .request_schema
            .clone()
            .unwrap_or_else(|| serde_json::json!({"type":"object"}));
        let output_schema = function.response_schema.clone();
        snapshot_tools.push(SurfaceToolSnapshot {
            model_name: model_name.clone(),
            function_id: function.id.as_str().to_owned(),
            function_revision: function.revision.0,
            owner_worker: function.owner_worker.as_str().to_owned(),
            description: function.description.clone(),
            input_schema_sha256: schema_digest(&input_schema)?,
            output_schema_sha256: output_schema.as_ref().map(schema_digest).transpose()?,
            input_schema,
            output_schema,
            effect_class: function.effect_class.as_str().to_owned(),
            risk: function.risk_level.as_str().to_owned(),
            delegation_policy: function.delegation_policy.as_str().to_owned(),
            workspace_effect: function.workspace_effect.as_str().to_owned(),
            exposed: true,
            worker_id: direct_worker
                .as_ref()
                .map(|worker| worker.worker_id.clone()),
            worker_version: direct_worker
                .as_ref()
                .map(|worker| worker.worker_version.clone()),
            primitive_group: function
                .model_tool
                .as_ref()
                .and_then(|tool| tool.group.clone()),
            audience: function
                .model_tool
                .as_ref()
                .map_or("unavailable", |tool| tool.audience.as_str())
                .to_owned(),
            access_path: if retained_alias {
                "retained_worker_agent_tools_alias".to_owned()
            } else {
                model_tool_access_path(&function).to_owned()
            },
            selection_reason: selection_reason.to_owned(),
            omission_reason: None,
        });
        resolved.push(ResolvedToolFunction {
            model_name,
            definition: function.clone(),
        });
    }
    resolved.sort_by_key(|resolved| {
        direct_worker_contract(&resolved.definition).map_or_else(
            || {
                (
                    0usize,
                    resolved
                        .definition
                        .model_tool
                        .as_ref()
                        .and_then(|tool| tool.order)
                        .map_or(usize::MAX, usize::from),
                    resolved.definition.id.as_str().to_owned(),
                )
            },
            |worker| {
                (
                    1usize,
                    worker_rank
                        .get(&worker.worker_id)
                        .copied()
                        .unwrap_or(usize::MAX),
                    resolved.definition.id.as_str().to_owned(),
                )
            },
        )
    });
    snapshot_tools.sort_by_key(|tool| {
        tool.worker_id.as_ref().map_or_else(
            || {
                (
                    0usize,
                    functions_order(&tool.function_id, &resolved),
                    tool.function_id.clone(),
                )
            },
            |worker_id| {
                (
                    1usize,
                    worker_rank.get(worker_id).copied().unwrap_or(usize::MAX),
                    tool.function_id.clone(),
                )
            },
        )
    });

    let fixed_tool_count = snapshot_tools
        .iter()
        .filter(|tool| {
            tool.worker_id.is_none() && tool.selection_reason != "retained_worker_agent_tools_alias"
        })
        .count();
    let projected_worker_count = snapshot_tools
        .iter()
        .filter(|tool| tool.worker_id.is_some())
        .count();
    let fixed_tools = fixed_tool_snapshots(&functions, &snapshot_tools)?;
    let ordinary_fixed_tool_count = fixed_tools
        .iter()
        .filter(|tool| tool.audience == "ordinary")
        .count();
    let specialist_fixed_tool_count = fixed_tools
        .iter()
        .filter(|tool| tool.audience == "specialist")
        .count();
    let conditional_fixed_tool_count = fixed_tools
        .iter()
        .filter(|tool| tool.audience == "conditional")
        .count();
    let surface_hash = surface_hash(&snapshot_tools)?;
    Ok(ResolvedToolSurface {
        functions: resolved,
        snapshot: EngineSurfaceSnapshot {
            catalog_revision: catalog_revision.0,
            surface_hash,
            fixed_tool_count,
            ordinary_fixed_tool_count,
            specialist_fixed_tool_count,
            conditional_fixed_tool_count,
            projected_worker_count,
            available_worker_count,
            ranking_mechanism: ranking.mechanism,
            tools: snapshot_tools,
            fixed_tools,
            available_workers,
        },
    })
}

#[cfg(test)]
mod tests;
