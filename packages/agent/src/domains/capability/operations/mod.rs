//! Live capability projection and execution primitives.
//!
//! The functions here intentionally adapt the existing engine catalog rather
//! than creating a second capability catalog. A catalog function is projected as a
//! stable contract plus one concrete implementation. Future plugin manifests
//! can add richer contract/binding rows without changing the model-facing
//! single `execute` surface. Target-specific argument affordances are isolated in
//! `target_arguments`, deterministic route and argument-fit heuristics live in
//! `target_resolution`, target payload guidance lives in `schema_validation`,
//! model-visible summaries live in `presentation`, worker-guide resource
//! materialization stays in this operations boundary, and profile policy
//! persistence plus admin primitives live in `policy_profile` and `admin`, so
//! the shared execute flow does not grow new per-capability branches unnoticed.

use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::sync::atomic::{AtomicU64, Ordering};

use super::Deps;
use super::registry::{
    CapabilityContextPrimerPolicy, CapabilityRegistryEntry, CapabilityRegistrySnapshot,
    CapabilityRegistryStore, CapabilitySearchPolicy, CapabilityTarget, binding_decision,
    parse_target, render_capability_primer as render_primer_from_snapshot, requires_fresh_revision,
    string_field,
};
#[cfg(test)]
use super::types::CapabilityPluginManifest;
use super::types::{CapabilityBindingDecision, CapabilityIndexStatus, CapabilityRejectedCandidate};
use crate::domains::capability_support::implementations::primitive_surface::{
    CONTRACT_ALLOW_SCOPE_PREFIX, CONTRACT_DENY_SCOPE_PREFIX, IMPLEMENTATION_ALLOW_SCOPE_PREFIX,
    IMPLEMENTATION_DENY_SCOPE_PREFIX, PLUGIN_ALLOW_SCOPE_PREFIX, PLUGIN_DENY_SCOPE_PREFIX,
};
use crate::engine::{
    ActorContext, ActorId, ActorKind, AuthorityGrantId, EffectClass, FunctionDefinition,
    FunctionHealth, FunctionId, FunctionQuery, HARNESS_DOC_KIND, Invocation, RiskLevel, TraceId,
};
#[cfg(test)]
use crate::engine::{
    ApprovalStatus, CausalContext, DeliveryMode, EngineApprovalRecord, InvocationRecord,
};
#[cfg(test)]
use crate::shared::content::CapabilityResultContent;
use crate::shared::model_capabilities::CapabilityResult;
#[cfg(test)]
use crate::shared::model_capabilities::CapabilityResultBody;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::error_mapping::engine_error_to_capability_error;
use crate::shared::server::errors::CapabilityError;

static IN_FLIGHT_VECTOR_WARMUP_SIGNATURE: AtomicU64 = AtomicU64::new(0);
const WORKER_GUIDE_POINTER_TOKEN_RESERVE: usize = 96;

mod admin;
mod audit;
mod execute;
mod inspect;
mod policy_profile;
mod presentation;
mod run;
mod schema_validation;
mod search;
mod target_arguments;
mod target_resolution;

use admin::validate_nonempty_id;
#[cfg(test)]
use admin::validate_plugin_manifest;
pub(crate) use admin::{
    binding_list_value, binding_set_value, conformance_run_value, implementation_set_state_value,
    plugin_inspect_value, plugin_install_value, plugin_list_value, plugin_promote_value,
    plugin_set_state_value, plugin_update_value, policy_get_value, policy_update_value,
    policy_validate_value, program_run_list_value, registry_snapshot_value,
};
use admin::{record_admin_audit, registry_snapshot_from_store};
pub(crate) use audit::audit_query_value;
#[cfg(test)]
use audit::{audit_event_matches_orchestration_filters, filter_orchestration_audit_result};
pub(crate) use execute::execute_value;
#[cfg(test)]
use execute::{parse_orchestrated_execute_input, prepared_execute_payload};
#[cfg(test)]
use inspect::inspect_targets;
pub(crate) use inspect::{inspect_value, status_value};
#[cfg(test)]
use policy_profile::validate_capability_execution_policy_payload;
use presentation::{
    missing_inspection_requirements_error, render_inspection_summary, render_search_summary,
};
#[cfg(test)]
use run::{
    approval_child_invocation_ids_from_records, approval_was_replayed_for_invocation,
    approved_execution_result, child_execute_causal_context, payload_preflight_status,
    policy_preflight_status, preflight_rejection_result,
};
use schema_validation::validate_target_payload;
pub(crate) use search::search_value;
#[cfg(test)]
use search::{render_search_result_value, search_queries};
#[cfg(test)]
use target_arguments::{
    normalize_target_arguments, normalize_target_idempotency_argument,
    normalize_target_specific_arguments,
};
#[cfg(test)]
use target_resolution::{
    apply_argument_schema_fit_filter, apply_deterministic_intent_route,
    clarification_candidates_for_intent, deterministic_intent_route, intent_strongly_matches_hit,
    lacks_sufficient_intent_resolution_evidence, orchestration_constraints_allow_hit,
    orchestration_hit_from_entry, promote_argument_schema_fit_candidates,
    validate_orchestration_constraint_shape, validate_orchestration_constraints,
};

pub(crate) async fn render_capability_primer(
    engine_host: &crate::engine::EngineHostHandle,
    session_id: &str,
    workspace_id: Option<&str>,
    policy: &CapabilityContextPrimerPolicy,
) -> Result<Option<String>, CapabilityError> {
    let mut actor = ActorContext::new(
        crate::engine::ActorId::new(format!("agent:{session_id}")).map_err(|error| {
            CapabilityError::Internal {
                message: error.to_string(),
            }
        })?,
        ActorKind::Agent,
        AuthorityGrantId::new("agent-worker-guide").map_err(|error| CapabilityError::Internal {
            message: error.to_string(),
        })?,
    )
    .with_scope("capability.search")
    .with_scope("capability.inspect")
    .with_scope("capability.execute")
    .with_session_id(session_id.to_owned());
    if let Some(workspace_id) = workspace_id {
        actor = actor.with_workspace_id(workspace_id.to_owned());
    }
    let functions = engine_host
        .discover(&FunctionQuery {
            actor: Some(actor.clone()),
            health: Some(FunctionHealth::Healthy),
            ..FunctionQuery::default()
        })
        .await;
    let revision = engine_host.catalog_revision().await;
    let triggers = engine_host.visible_triggers(&actor).await;
    let snapshot = CapabilityRegistrySnapshot::with_triggers(functions, triggers, revision.0);
    let mut render_policy = policy.clone();
    if render_policy.max_tokens > WORKER_GUIDE_POINTER_TOKEN_RESERVE {
        render_policy.max_tokens -= WORKER_GUIDE_POINTER_TOKEN_RESERVE;
    }
    let Some(primer) = render_primer_from_snapshot(&snapshot, &render_policy) else {
        return Ok(None);
    };
    let doc_ref = materialize_worker_guide_resource(
        engine_host,
        session_id,
        workspace_id,
        &snapshot,
        policy,
        &primer,
    )
    .await?;
    Ok(Some(format!(
        "{primer}\nWorker guide resource: resourceId={} versionId={} kind={} catalogRevision={} inspectTarget=resource::inspect.\n",
        doc_ref.resource_id, doc_ref.version_id, HARNESS_DOC_KIND, snapshot.catalog_revision
    )))
}

struct WorkerGuideResourceRef {
    resource_id: String,
    version_id: String,
}

async fn materialize_worker_guide_resource(
    engine_host: &crate::engine::EngineHostHandle,
    session_id: &str,
    workspace_id: Option<&str>,
    snapshot: &CapabilityRegistrySnapshot,
    policy: &CapabilityContextPrimerPolicy,
    body: &str,
) -> Result<WorkerGuideResourceRef, CapabilityError> {
    let policy_value = serde_json::to_value(policy).map_err(|error| CapabilityError::Internal {
        message: error.to_string(),
    })?;
    let policy_bytes =
        serde_json::to_vec(&policy_value).map_err(|error| CapabilityError::Internal {
            message: error.to_string(),
        })?;
    let policy_digest = sha256_hex_128(&policy_bytes);
    let content_hash = sha256_hex_128(body.as_bytes());
    let resource_id = format!(
        "harness_doc:worker-guide:{policy_digest}:catalog-{}:{content_hash}",
        snapshot.catalog_revision
    );
    let payload = json!({
        "resourceId": resource_id,
        "kind": HARNESS_DOC_KIND,
        "scope": "session",
        "sessionId": session_id,
        "lifecycle": "active",
        "policy": {
            "managedBy": "capability",
            "retention": "catalog_revision"
        },
        "payload": {
            "docId": "worker-guide",
            "title": "Worker guide",
            "format": "text/markdown",
            "body": body,
            "catalogRevision": snapshot.catalog_revision,
            "policy": policy_value,
            "contentHash": content_hash,
            "source": "worker.guide",
            "metadata": {
                "sessionId": session_id,
                "workspaceId": workspace_id,
                "entryCount": snapshot.entries.len(),
                "resourceKind": HARNESS_DOC_KIND
            }
        }
    });
    let mut causal_context = crate::engine::CausalContext::new(
        ActorId::new("system:capability").map_err(capability_engine_error)?,
        ActorKind::System,
        AuthorityGrantId::new("engine-system").map_err(capability_engine_error)?,
        TraceId::new(format!(
            "trace:worker-guide:{}:{}",
            snapshot.catalog_revision, content_hash
        ))
        .map_err(capability_engine_error)?,
    )
    .with_scope("resource.write")
    .with_session_id(session_id.to_owned())
    .with_idempotency_key(format!("worker-guide:v1:{resource_id}"));
    if let Some(workspace_id) = workspace_id {
        causal_context = causal_context.with_workspace_id(workspace_id.to_owned());
    }
    let invocation = Invocation::new_sync(
        FunctionId::new("resource::create").map_err(capability_engine_error)?,
        payload,
        causal_context,
    );
    let result = engine_host.invoke(invocation).await;
    if let Some(error) = result.error {
        return Err(engine_error_to_capability_error(error));
    }
    let value = result.value.ok_or_else(|| CapabilityError::Internal {
        message: "resource::create returned no value for worker guide".to_owned(),
    })?;
    let reference = value
        .get("resourceRefs")
        .and_then(Value::as_array)
        .and_then(|refs| refs.first())
        .ok_or_else(|| CapabilityError::Internal {
            message: "resource::create returned no worker guide resource ref".to_owned(),
        })?;
    let resource_id = reference
        .get("resourceId")
        .and_then(Value::as_str)
        .ok_or_else(|| CapabilityError::Internal {
            message: "worker guide resource ref omitted resourceId".to_owned(),
        })?
        .to_owned();
    let version_id = reference
        .get("versionId")
        .and_then(Value::as_str)
        .ok_or_else(|| CapabilityError::Internal {
            message: "worker guide resource ref omitted versionId".to_owned(),
        })?
        .to_owned();
    Ok(WorkerGuideResourceRef {
        resource_id,
        version_id,
    })
}

pub(super) async fn registry_snapshot_for_functions(
    deps: &Deps,
    actor: &ActorContext,
    functions: Vec<FunctionDefinition>,
) -> CapabilityRegistrySnapshot {
    let catalog_revision = deps.engine_host.catalog_revision().await;
    let triggers = deps.engine_host.visible_triggers(actor).await;
    CapabilityRegistrySnapshot::with_triggers(functions, triggers, catalog_revision.0)
}

struct ResolvedCapabilityTarget {
    entry: super::registry::CapabilityRegistryEntry,
    binding_decision: CapabilityBindingDecision,
}

async fn resolve_target(
    params: &Value,
    deps: &Deps,
    actor: &ActorContext,
) -> Result<ResolvedCapabilityTarget, CapabilityError> {
    let Some(target) = parse_target(params) else {
        return Err(CapabilityError::InvalidParams {
            message: "Pass one of functionId, implementationId, capabilityId, or contractId"
                .to_owned(),
        });
    };
    let functions = deps
        .engine_host
        .discover(&FunctionQuery {
            actor: Some(actor.clone()),
            health: Some(FunctionHealth::Healthy),
            ..FunctionQuery::default()
        })
        .await;
    let snapshot = registry_snapshot_for_functions(deps, actor, functions).await;
    let candidates = snapshot.find_candidates(&target);
    let store = deps.registry_store.clone();
    let embedding_provider = deps.embedding_provider.clone();
    let target_for_resolver = target.clone();
    let actor_session_id = actor.session_id.as_deref().map(ToOwned::to_owned);
    let actor_workspace_id = actor.workspace_id.as_deref().map(ToOwned::to_owned);
    let resolved = run_blocking_task("capability.binding.resolve", move || {
        let mut store = store.lock().map_err(|_| CapabilityError::Internal {
            message: "capability registry store mutex poisoned".to_owned(),
        })?;
        let sync_policy = registry_metadata_sync_policy();
        store
            .sync_snapshot(&snapshot, embedding_provider.as_ref(), &sync_policy)
            .map_err(registry_store_error)?;
        let resolved = binding_decision_with_store(
            store.as_mut(),
            &target_for_resolver,
            &candidates,
            actor_session_id.as_deref(),
            actor_workspace_id.as_deref(),
        )?;
        if let Some((entry, decision)) = &resolved {
            store
                .record_binding_decision(decision, entry)
                .map_err(registry_store_error)?;
            store
                .record_audit_event(
                    "capability.binding",
                    None,
                    json!({
                        "contractId": decision.contract_id,
                        "implementationId": decision.selected_implementation,
                        "functionId": decision.selected_function_id,
                        "selectionPolicy": decision.selection_policy,
                        "catalogRevision": decision.catalog_revision,
                        "schemaDigest": decision.schema_digest,
                        "rejectedCandidates": decision.rejected_candidates,
                    }),
                )
                .map_err(registry_store_error)?;
        }
        Ok(resolved)
    })
    .await?;
    let Some((entry, decision)) = resolved else {
        return Err(CapabilityError::NotFound {
            code: "CAPABILITY_NOT_FOUND".to_owned(),
            message: "No visible healthy capability matches the requested target".to_owned(),
        });
    };
    Ok(ResolvedCapabilityTarget {
        entry,
        binding_decision: decision,
    })
}

async fn validate_inspection_handle(
    deps: &Deps,
    handle: &str,
    entry: CapabilityRegistryEntry,
) -> Result<bool, CapabilityError> {
    let store = deps.registry_store.clone();
    let handle = handle.to_owned();
    run_blocking_task("capability.inspect.validate", move || {
        let store = store.lock().map_err(|_| CapabilityError::Internal {
            message: "capability registry store mutex poisoned".to_owned(),
        })?;
        store
            .validate_inspection(&handle, &entry)
            .map_err(registry_store_error)
    })
    .await
}

fn binding_decision_with_store(
    store: &mut dyn CapabilityRegistryStore,
    target: &CapabilityTarget,
    candidates: &[CapabilityRegistryEntry],
    session_id: Option<&str>,
    workspace_id: Option<&str>,
) -> Result<Option<(CapabilityRegistryEntry, CapabilityBindingDecision)>, CapabilityError> {
    if candidates.is_empty() {
        return Ok(None);
    }
    let explicit = matches!(
        target,
        CapabilityTarget::Function(_) | CapabilityTarget::Implementation(_)
    );
    if explicit {
        let Some((entry, mut decision)) = binding_decision(target, candidates) else {
            return Ok(None);
        };
        ensure_selectable(store, &entry)?;
        decision.selection_policy = "explicit".to_owned();
        decision.rejected_candidates = rejected_candidates_for(candidates, &entry, store)?;
        return Ok(Some((entry, decision)));
    }

    let contract_id = candidates
        .first()
        .map(|entry| entry.contract_id.as_str())
        .unwrap_or_default();
    if let Some(binding) = store
        .active_binding(contract_id, session_id, workspace_id)
        .map_err(registry_store_error)?
        && let Some(entry) = candidates
            .iter()
            .find(|entry| entry.implementation_id == binding.selected_implementation)
            .cloned()
    {
        ensure_selectable(store, &entry)?;
        return Ok(Some((
            entry.clone(),
            decision_for_entry(
                &entry,
                &binding.selection_policy,
                rejected_candidates_for(candidates, &entry, store)?,
            ),
        )));
    }

    let tiers = [
        ("first_party_healthy", &["first_party_signed"][..]),
        ("trusted_healthy", &["trusted_signed"][..]),
        (
            "approved_external_or_session_healthy",
            &[
                "user_installed",
                "session_generated",
                "external_mcp",
                "external_openapi",
            ][..],
        ),
    ];
    for (policy, allowed_tiers) in tiers {
        for entry in candidates {
            if !allowed_tiers.contains(&entry.trust_tier.as_str()) {
                continue;
            }
            if is_selectable(store, entry)? {
                return Ok(Some((
                    entry.clone(),
                    decision_for_entry(
                        entry,
                        policy,
                        rejected_candidates_for(candidates, entry, store)?,
                    ),
                )));
            }
        }
    }
    Ok(None)
}

fn is_selectable(
    store: &mut dyn CapabilityRegistryStore,
    entry: &CapabilityRegistryEntry,
) -> Result<bool, CapabilityError> {
    let state = store
        .implementation_conformance_state(&entry.implementation_id)
        .map_err(registry_store_error)?
        .unwrap_or_else(|| "candidate".to_owned());
    Ok(state == "healthy")
}

fn ensure_selectable(
    store: &mut dyn CapabilityRegistryStore,
    entry: &CapabilityRegistryEntry,
) -> Result<(), CapabilityError> {
    if is_selectable(store, entry)? {
        return Ok(());
    }
    let state = store
        .implementation_conformance_state(&entry.implementation_id)
        .map_err(registry_store_error)?
        .unwrap_or_else(|| "candidate".to_owned());
    Err(CapabilityError::Custom {
        code: "CAPABILITY_IMPLEMENTATION_NOT_SELECTABLE".to_owned(),
        message: format!(
            "{} is not binding-selectable because conformanceState={state}",
            entry.implementation_id
        ),
        details: Some(json!({
            "implementationId": entry.implementation_id,
            "functionId": entry.function_id,
            "conformanceState": state,
        })),
    })
}

fn decision_for_entry(
    entry: &CapabilityRegistryEntry,
    selection_policy: &str,
    rejected_candidates: Vec<CapabilityRejectedCandidate>,
) -> CapabilityBindingDecision {
    CapabilityBindingDecision {
        decision_id: format!("binding_decision_{}", uuid::Uuid::now_v7()),
        contract_id: entry.contract_id.clone(),
        selected_implementation: entry.implementation_id.clone(),
        selected_function_id: entry.function_id.clone(),
        selection_policy: selection_policy.to_owned(),
        rejected_candidates,
        catalog_revision: entry.catalog_revision,
        schema_digest: entry.schema_digest.clone(),
    }
}

fn rejected_candidates_for(
    candidates: &[CapabilityRegistryEntry],
    selected: &CapabilityRegistryEntry,
    store: &mut dyn CapabilityRegistryStore,
) -> Result<Vec<CapabilityRejectedCandidate>, CapabilityError> {
    candidates
        .iter()
        .filter(|entry| entry.implementation_id != selected.implementation_id)
        .map(|entry| {
            let state = store
                .implementation_conformance_state(&entry.implementation_id)
                .map_err(registry_store_error)?
                .unwrap_or_else(|| "candidate".to_owned());
            let reason = if state == "healthy" {
                "lower_precedence_candidate".to_owned()
            } else {
                format!("conformance_state_{state}")
            };
            Ok(CapabilityRejectedCandidate {
                implementation_id: entry.implementation_id.clone(),
                function_id: entry.function_id.clone(),
                reason,
            })
        })
        .collect()
}

fn registry_metadata_sync_policy() -> CapabilitySearchPolicy {
    CapabilitySearchPolicy {
        local_vector: false,
        require_local_vector: false,
        ..CapabilitySearchPolicy::default()
    }
}

fn registry_operator_sync_policy() -> CapabilitySearchPolicy {
    CapabilitySearchPolicy {
        local_vector: true,
        require_local_vector: false,
        allow_lexical_only_when_degraded: true,
        ..CapabilitySearchPolicy::default()
    }
}

fn allows_degraded_vector_search(policy: &CapabilitySearchPolicy) -> bool {
    policy.local_vector && !policy.require_local_vector && policy.allow_lexical_only_when_degraded
}

fn admin_vector_ready(admin: &Value) -> bool {
    admin
        .get("indexStatus")
        .and_then(|status| status.get("state"))
        .and_then(Value::as_str)
        == Some("ready")
}

fn registry_needs_metadata_sync(admin: &Value, catalog_revision: u64) -> bool {
    admin.get("catalogRevision").and_then(Value::as_u64) != Some(catalog_revision)
        || admin.get("documents").and_then(Value::as_u64).unwrap_or(0) == 0
}

fn degraded_search_status(
    admin: &Value,
    policy: &CapabilitySearchPolicy,
    embedding_provider: &dyn super::embeddings::EmbeddingProvider,
) -> CapabilityIndexStatus {
    let index = admin.get("indexStatus").unwrap_or(&Value::Null);
    let state = index
        .get("state")
        .and_then(Value::as_str)
        .unwrap_or("unavailable");
    let degraded_reason = index
        .get("degradedReason")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| {
            if state == "unavailable" {
                "local vector index is warming; lexical capability search returned".to_owned()
            } else {
                format!("local vector index state is {state}; lexical capability search returned")
            }
        });
    CapabilityIndexStatus {
        lexical: policy.lexical,
        local_vector: policy.local_vector,
        cloud_embeddings: false,
        vector_store: index
            .get("vectorStore")
            .and_then(Value::as_str)
            .unwrap_or("sqlite-vec")
            .to_owned(),
        embedding_model: index
            .get("embeddingModel")
            .and_then(Value::as_str)
            .unwrap_or_else(|| embedding_provider.model_id())
            .to_owned(),
        state: state.to_owned(),
        degraded_reason: Some(degraded_reason),
    }
}

fn search_policy_from_runtime(
    invocation: &Invocation,
) -> Result<CapabilitySearchPolicy, CapabilityError> {
    if let Some(raw) = invocation
        .causal_context
        .runtime_metadata("capability.searchPolicy")
    {
        return serde_json::from_str(raw).map_err(|error| CapabilityError::InvalidParams {
            message: format!("Invalid internal capability search policy metadata: {error}"),
        });
    }
    if matches!(
        invocation.causal_context.actor_kind,
        ActorKind::System | ActorKind::Admin
    ) {
        return Ok(CapabilitySearchPolicy::default());
    }
    Err(CapabilityError::Custom {
        code: "CAPABILITY_SEARCH_POLICY_REQUIRED".to_owned(),
        message: "capability::search requires an active profile search policy in runtime metadata"
            .to_owned(),
        details: Some(json!({
            "requiredRuntimeMetadata": "capability.searchPolicy"
        })),
    })
}

fn registry_store_error(error: String) -> CapabilityError {
    if let Some(message) = error.strip_prefix("CAPABILITY_INDEX_UNAVAILABLE: ") {
        return CapabilityError::Custom {
            code: "CAPABILITY_INDEX_UNAVAILABLE".to_owned(),
            message: message.to_owned(),
            details: None,
        };
    }
    CapabilityError::Internal { message: error }
}

fn capability_engine_error(error: impl std::fmt::Display) -> CapabilityError {
    CapabilityError::Internal {
        message: error.to_string(),
    }
}

async fn sync_registry_for_admin(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<u64, CapabilityError> {
    let actor = actor_from_invocation(invocation)?;
    let functions = deps
        .engine_host
        .discover(&FunctionQuery {
            actor: Some(actor.clone()),
            ..FunctionQuery::default()
        })
        .await;
    let snapshot = registry_snapshot_for_functions(deps, &actor, functions).await;
    let catalog_revision = snapshot.catalog_revision;
    let warmup_snapshot = snapshot.clone();
    let store = deps.registry_store.clone();
    let embedding_provider = deps.embedding_provider.clone();
    run_blocking_task("capability.admin.sync_registry", move || {
        let mut store = store.lock().map_err(|_| CapabilityError::Internal {
            message: "capability registry store mutex poisoned".to_owned(),
        })?;
        store
            .sync_snapshot(
                &snapshot,
                embedding_provider.as_ref(),
                &registry_metadata_sync_policy(),
            )
            .map_err(registry_store_error)?;
        Ok(())
    })
    .await?;
    schedule_vector_warmup(warmup_snapshot, deps);
    Ok(catalog_revision)
}

fn schedule_vector_warmup(snapshot: CapabilityRegistrySnapshot, deps: &Deps) {
    let signature = vector_warmup_signature(&snapshot);
    if IN_FLIGHT_VECTOR_WARMUP_SIGNATURE
        .compare_exchange(0, signature, Ordering::SeqCst, Ordering::SeqCst)
        .is_err()
    {
        return;
    }
    let store = deps.registry_store.clone();
    let embedding_provider = deps.embedding_provider.clone();
    tokio::spawn(async move {
        let result = run_blocking_task("capability.registry.vector_warmup", move || {
            let mut store = store.lock().map_err(|_| CapabilityError::Internal {
                message: "capability registry store mutex poisoned".to_owned(),
            })?;
            store
                .sync_snapshot(
                    &snapshot,
                    embedding_provider.as_ref(),
                    &registry_operator_sync_policy(),
                )
                .map_err(registry_store_error)?;
            Ok(())
        })
        .await;
        IN_FLIGHT_VECTOR_WARMUP_SIGNATURE.store(0, Ordering::SeqCst);
        if let Err(error) = result {
            tracing::warn!(%error, "capability vector warm-up failed");
        }
    });
}

fn search_results_need_vector_warmup(
    search_results: &[(String, super::registry::CapabilityIndexSearchResult)],
) -> bool {
    search_results
        .iter()
        .any(|(_, result)| index_status_needs_vector_warmup(&result.status))
}

fn index_status_needs_vector_warmup(status: &CapabilityIndexStatus) -> bool {
    status.local_vector
        && (status.state != "ready"
            || status
                .degraded_reason
                .as_deref()
                .is_some_and(is_vector_indexing_error))
}

fn is_vector_indexing_error(error: &str) -> bool {
    error.starts_with("CAPABILITY_INDEX_INDEXING:")
}

fn vector_warmup_signature(snapshot: &CapabilityRegistrySnapshot) -> u64 {
    let mut hasher = Sha256::new();
    hasher.update(snapshot.catalog_revision.to_le_bytes());
    for document in snapshot.index_documents() {
        hasher.update(document.kind.as_bytes());
        hasher.update([0]);
        hasher.update(document.contract_id.as_bytes());
        hasher.update([0]);
        hasher.update(document.implementation_id.as_bytes());
        hasher.update([0]);
        hasher.update(document.function_id.as_bytes());
        hasher.update([0]);
        hasher.update(document.text.as_bytes());
        hasher.update([0]);
    }
    let digest = hasher.finalize();
    let mut bytes = [0u8; 8];
    bytes.copy_from_slice(&digest[..8]);
    u64::from_le_bytes(bytes).max(1)
}

fn actor_from_invocation(invocation: &Invocation) -> Result<ActorContext, CapabilityError> {
    let mut actor = ActorContext::new(
        invocation.causal_context.actor_id.clone(),
        invocation.causal_context.actor_kind.clone(),
        AuthorityGrantId::new(invocation.causal_context.authority_grant_id.as_str()).map_err(
            |error| CapabilityError::Internal {
                message: error.to_string(),
            },
        )?,
    );
    actor.authority_scopes = invocation.causal_context.authority_scopes.clone();
    actor.session_id = invocation
        .causal_context
        .session_id
        .clone()
        .or_else(|| payload_context_string(invocation, "sessionId"));
    actor.workspace_id = invocation
        .causal_context
        .workspace_id
        .clone()
        .or_else(|| payload_context_string(invocation, "workspaceId"));
    if !matches!(
        actor.actor_kind,
        ActorKind::Agent | ActorKind::System | ActorKind::Admin
    ) {
        tracing::debug!(
            actor_kind = ?actor.actor_kind,
            "capability primitive invoked by non-agent actor"
        );
    }
    Ok(actor)
}

fn payload_context_string(invocation: &Invocation, field: &str) -> Option<String> {
    string_field(&invocation.payload, field)
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
}

fn is_capability_primitive(function: &FunctionDefinition) -> bool {
    function
        .metadata
        .get("capabilityPrimitive")
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

fn capability_primitive_target_error(function: &FunctionDefinition) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: format!(
            "execute cannot target {} because it is a capability primitive. This call is already the execute primitive; set target to the real capability, for example filesystem::read_file or process::run, and put only that target's arguments inside arguments.",
            function.id.as_str()
        ),
    }
}

fn enforce_execution_policy(
    invocation: &Invocation,
    decision: &CapabilityBindingDecision,
    function: &FunctionDefinition,
) -> Result<(), CapabilityError> {
    if matches!(
        invocation.causal_context.actor_kind,
        ActorKind::System | ActorKind::Admin
    ) {
        return Ok(());
    }

    let contract_candidates = [decision.contract_id.as_str()];
    let implementation_candidates = [decision.selected_implementation.as_str()];
    let function_candidates = [decision.selected_function_id.as_str(), function.id.as_str()];
    let plugin_id = string_field(&function.metadata, "pluginId")
        .unwrap_or_else(|| function.owner_worker.as_str().to_owned());
    let plugin_candidates = [plugin_id.as_str()];
    if policy_scope_matches(
        &invocation.causal_context.authority_scopes,
        CONTRACT_DENY_SCOPE_PREFIX,
        &contract_candidates,
    ) || policy_scope_matches(
        &invocation.causal_context.authority_scopes,
        IMPLEMENTATION_DENY_SCOPE_PREFIX,
        &implementation_candidates,
    ) || policy_scope_matches(
        &invocation.causal_context.authority_scopes,
        IMPLEMENTATION_DENY_SCOPE_PREFIX,
        &function_candidates,
    ) || policy_scope_matches(
        &invocation.causal_context.authority_scopes,
        PLUGIN_DENY_SCOPE_PREFIX,
        &plugin_candidates,
    ) {
        return Err(CapabilityError::Custom {
            code: "CAPABILITY_DENIED".to_owned(),
            message: format!(
                "{} is denied by the active capability policy",
                function.id.as_str()
            ),
            details: Some(json!({
                "contractId": decision.contract_id.as_str(),
                "implementationId": decision.selected_implementation.as_str(),
                "functionId": function.id.as_str()
            })),
        });
    }
    let contract_allowed = policy_scope_matches(
        &invocation.causal_context.authority_scopes,
        CONTRACT_ALLOW_SCOPE_PREFIX,
        &contract_candidates,
    );
    let implementation_allowed = policy_scope_matches(
        &invocation.causal_context.authority_scopes,
        IMPLEMENTATION_ALLOW_SCOPE_PREFIX,
        &implementation_candidates,
    ) || policy_scope_matches(
        &invocation.causal_context.authority_scopes,
        IMPLEMENTATION_ALLOW_SCOPE_PREFIX,
        &function_candidates,
    );
    let plugin_allowed = policy_scope_matches(
        &invocation.causal_context.authority_scopes,
        PLUGIN_ALLOW_SCOPE_PREFIX,
        &plugin_candidates,
    );
    if contract_allowed && implementation_allowed && plugin_allowed {
        return Ok(());
    }
    Err(CapabilityError::Custom {
        code: "CAPABILITY_DENIED".to_owned(),
        message: format!(
            "{} is not allowed by the active capability policy",
            function.id.as_str()
        ),
        details: Some(json!({
            "contractId": decision.contract_id.as_str(),
            "implementationId": decision.selected_implementation.as_str(),
            "functionId": function.id.as_str()
        })),
    })
}

fn requires_fresh_revision_for_payload(
    function: &FunctionDefinition,
    invocation_payload: &Value,
) -> bool {
    if function.id.as_str() == "process::run" {
        let target_payload = invocation_payload
            .get("payload")
            .unwrap_or(invocation_payload);
        if !crate::domains::process::approval::run_execution_requires_approval(target_payload) {
            return false;
        }
    }
    if function.id.as_str() == "notifications::send" {
        return false;
    }
    requires_fresh_revision(function)
}

fn execution_requires_approval(function: &FunctionDefinition, payload: &Value) -> bool {
    function.required_authority.approval_required
        || (function.id.as_str() == "process::run"
            && crate::domains::process::approval::run_execution_requires_approval(payload))
}

fn validate_target_policy_before_approval(
    function: &FunctionDefinition,
    payload: &Value,
) -> Result<(), CapabilityError> {
    if function.id.as_str() == "process::run"
        && let Err(message) =
            crate::domains::process::approval::validate_run_payload_before_approval(payload)
    {
        if message == crate::domains::process::approval::sandbox_output_path_relative_message() {
            return Err(CapabilityError::Custom {
                code: "INVALID_PARAMS".to_owned(),
                message: message.to_owned(),
                details: Some(json!({
                    "validationKind": "repairable_argument",
                    "invalidFields": ["expectedOutputs[].path"],
                    "invalidArgumentPaths": ["arguments.expectedOutputs[].path"]
                })),
            });
        }
        return Err(CapabilityError::InvalidParams {
            message: message.to_owned(),
        });
    }
    Ok(())
}

fn policy_scope_matches(scopes: &[String], prefix: &str, candidates: &[&str]) -> bool {
    scopes.iter().any(|scope| {
        let Some(value) = scope.strip_prefix(prefix) else {
            return false;
        };
        value == "*" || candidates.contains(&value)
    })
}

fn child_idempotency_key(
    invocation: &Invocation,
    function: &FunctionDefinition,
    payload: &Value,
    required: bool,
) -> Result<Option<String>, CapabilityError> {
    if let Some(key) = string_field(&invocation.payload, "idempotencyKey")
        .or_else(|| string_field(&invocation.payload, "idempotency_key"))
    {
        return Ok(Some(key));
    }
    if let Some(parent_key) = invocation.causal_context.idempotency_key.as_deref() {
        let material = json!({
            "parent": parent_key,
            "functionId": function.id.as_str(),
            "payload": payload,
        });
        let serialized = serde_json::to_vec(&material).unwrap_or_default();
        return Ok(Some(format!(
            "capability-execute:v2:{}",
            sha256_hex_128(&serialized)
        )));
    }
    if required {
        return Err(CapabilityError::InvalidParams {
            message: format!(
                "{} mutates state; pass idempotencyKey or invoke through a model capability invocation with engine idempotency",
                function.id.as_str()
            ),
        });
    }
    Ok(None)
}

fn child_idempotency_required(function: &FunctionDefinition, payload: &Value) -> bool {
    if function.id.as_str() == "process::run"
        && !crate::domains::process::approval::run_execution_requires_approval(payload)
    {
        return false;
    }
    function.effect_class.is_mutating()
}

fn capability_result_value(result: CapabilityResult) -> Result<Value, CapabilityError> {
    serde_json::to_value(result).map_err(|error| CapabilityError::Internal {
        message: error.to_string(),
    })
}

fn merge_optional_details(existing: Option<Value>, extra: Value) -> Value {
    match existing {
        Some(Value::Object(mut object)) => {
            let _ = object.insert("capabilityExecution".to_owned(), extra);
            Value::Object(object)
        }
        Some(value) => json!({
            "toolDetails": value,
            "capabilityExecution": extra
        }),
        None => extra,
    }
}

fn risk_field(params: &Value, key: &str) -> Result<Option<RiskLevel>, CapabilityError> {
    let Some(raw) = params.get(key) else {
        return Ok(None);
    };
    let Some(value) = raw
        .as_str()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    else {
        return Err(CapabilityError::InvalidParams {
            message: format!("{key} must be a non-empty string"),
        });
    };
    risk_level_from_str(value, key).map(Some)
}

fn risk_level_from_str(value: &str, label: &str) -> Result<RiskLevel, CapabilityError> {
    match value.to_ascii_lowercase().as_str() {
        "low" => Ok(RiskLevel::Low),
        "medium" => Ok(RiskLevel::Medium),
        "high" => Ok(RiskLevel::High),
        "critical" => Ok(RiskLevel::Critical),
        _ => Err(CapabilityError::InvalidParams {
            message: format!("Unsupported {label} '{value}'"),
        }),
    }
}

fn effect_field(params: &Value, key: &str) -> Result<Option<EffectClass>, CapabilityError> {
    let Some(raw) = params.get(key) else {
        return Ok(None);
    };
    let Some(value) = raw
        .as_str()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    else {
        return Err(CapabilityError::InvalidParams {
            message: format!("{key} must be a non-empty string"),
        });
    };
    effect_class_from_str(value, key).map(Some)
}

fn effect_class_from_str(value: &str, label: &str) -> Result<EffectClass, CapabilityError> {
    let normalized = value
        .chars()
        .filter(|ch| ch.is_ascii_alphanumeric())
        .collect::<String>()
        .to_ascii_lowercase();
    match normalized.as_str() {
        "pureread" => Ok(EffectClass::PureRead),
        "deterministiccompute" => Ok(EffectClass::DeterministicCompute),
        "delegatedinvocation" => Ok(EffectClass::DelegatedInvocation),
        "idempotentwrite" => Ok(EffectClass::IdempotentWrite),
        "appendonlyevent" => Ok(EffectClass::AppendOnlyEvent),
        "reversiblesideeffect" => Ok(EffectClass::ReversibleSideEffect),
        "externalsideeffect" => Ok(EffectClass::ExternalSideEffect),
        "irreversiblesideeffect" => Ok(EffectClass::IrreversibleSideEffect),
        _ => Err(CapabilityError::InvalidParams {
            message: format!("Unsupported {label} '{value}'"),
        }),
    }
}

fn sha256_hex_128(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hex::encode(&hasher.finalize()[..16])
}

#[cfg(test)]
mod tests;
