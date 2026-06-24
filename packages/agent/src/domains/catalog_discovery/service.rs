use serde_json::{Value, json};

use crate::engine::{
    CATALOG_DISCOVERY_REPORT_KIND, CATALOG_DISCOVERY_REPORT_SCHEMA_ID, CreateResource,
    EngineHostHandle, FunctionId, Invocation, TriggerId, TriggerTypeId, WorkerId,
};
use crate::shared::server::errors::CapabilityError;

use super::errors::{engine_error, invalid_params};
use super::params::{
    actor_context, ensure_catalog_visibility, include_protected_counts, optional_limit, query_echo,
    query_from_payload, report_scope, required_str,
};
use super::projection::{
    catalog_summary, filtered_trigger_types, filtered_triggers, filtered_workers,
    function_conformance, function_schema_hints, function_summary, next_actions,
    protected_omission_counts, resource_evidence, resource_ref, trigger_summary,
    trigger_type_summary, worker_summary,
};
use super::report::{build_report_payload, publish_report_event};
use super::{CATALOG_DISCOVERY_TOPIC, WORKER};

const SEARCH_SCHEMA_VERSION: &str = "tron.catalog_discovery.search.v1";
const INSPECT_SCHEMA_VERSION: &str = "tron.catalog_discovery.inspect.v1";

/// Compose the visible catalog into a self-inspection search payload.
pub(crate) async fn search_catalog_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let actor = actor_context(invocation);
    let limit = optional_limit(payload)?.unwrap_or(100);
    let query = query_from_payload(payload, actor.clone())?;
    let visible_functions = engine_host.discover(&query).await;
    let visible_workers = filtered_workers(
        engine_host.visible_workers(&actor).await,
        &visible_functions,
        payload,
    )?;
    let visible_triggers = filtered_triggers(engine_host.visible_triggers(&actor).await, payload)?;
    let visible_trigger_types =
        filtered_trigger_types(engine_host.visible_trigger_types(&actor).await, payload)?;
    let resource_evidence = resource_evidence(engine_host).await?;
    let protected = if include_protected_counts(payload) {
        protected_omission_counts(engine_host, payload, &visible_functions, &visible_workers)
            .await?
    } else {
        json!({"included": false})
    };
    let summary = catalog_summary(
        &visible_functions,
        &visible_workers,
        &visible_triggers,
        &visible_trigger_types,
        protected.clone(),
    );

    Ok(json!({
        "schemaVersion": SEARCH_SCHEMA_VERSION,
        "catalogRevision": engine_host.catalog_revision().await.0,
        "query": query_echo(payload, limit),
        "summary": summary,
        "functions": visible_functions.iter().take(limit).map(function_summary).collect::<Vec<_>>(),
        "workers": visible_workers.iter().take(limit).map(worker_summary).collect::<Vec<_>>(),
        "triggers": visible_triggers.iter().take(limit).map(trigger_summary).collect::<Vec<_>>(),
        "triggerTypes": visible_trigger_types.iter().take(limit).map(trigger_type_summary).collect::<Vec<_>>(),
        "resourceEvidence": resource_evidence,
        "continuity": {
            "historySource": "catalog.changes",
            "reportResourceKind": CATALOG_DISCOVERY_REPORT_KIND,
            "streamTopic": CATALOG_DISCOVERY_TOPIC
        },
        "nextActions": next_actions(&visible_functions, &resource_evidence),
    }))
}

/// Inspect one visible catalog item without invoking it.
pub(crate) async fn inspect_catalog_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let actor = actor_context(invocation);
    let kind = required_str(payload, "kind")?;
    let id = required_str(payload, "id")?;
    let catalog_revision = engine_host.catalog_revision().await.0;
    match kind {
        "function" => {
            let function_id = FunctionId::new(id).map_err(engine_error)?;
            let definition = engine_host
                .inspect_function(&function_id, Some(&actor))
                .await
                .map_err(engine_error)?;
            Ok(json!({
                "schemaVersion": INSPECT_SCHEMA_VERSION,
                "catalogRevision": catalog_revision,
                "kind": kind,
                "id": id,
                "definition": definition,
                "summary": function_summary(&definition),
                "schemaHints": function_schema_hints(&definition),
                "conformance": function_conformance(&definition),
            }))
        }
        "worker" => {
            let worker_id = WorkerId::new(id).map_err(engine_error)?;
            let definition = engine_host
                .inspect_worker(&worker_id)
                .await
                .map_err(engine_error)?;
            ensure_catalog_visibility(
                &definition.visibility,
                definition.provenance.session_id.as_deref(),
                definition.provenance.workspace_id.as_deref(),
                &actor,
                "worker",
                id,
            )?;
            Ok(json!({
                "schemaVersion": INSPECT_SCHEMA_VERSION,
                "catalogRevision": catalog_revision,
                "kind": kind,
                "id": id,
                "definition": definition,
                "summary": worker_summary(&definition),
                "conformance": {
                    "visible": true,
                    "namespaceClaims": definition.namespace_claims,
                    "historyPointer": "catalog.changes"
                }
            }))
        }
        "trigger_type" => {
            let trigger_type_id = TriggerTypeId::new(id).map_err(engine_error)?;
            let definition = engine_host
                .inspect_trigger_type(&trigger_type_id)
                .await
                .map_err(engine_error)?;
            ensure_catalog_visibility(
                &definition.visibility,
                definition.provenance.session_id.as_deref(),
                definition.provenance.workspace_id.as_deref(),
                &actor,
                "trigger type",
                id,
            )?;
            Ok(json!({
                "schemaVersion": INSPECT_SCHEMA_VERSION,
                "catalogRevision": catalog_revision,
                "kind": kind,
                "id": id,
                "definition": definition,
                "summary": trigger_type_summary(&definition),
                "schemaHints": {
                    "configSchemaPresent": definition.config_schema.is_some()
                }
            }))
        }
        "trigger" => {
            let trigger_id = TriggerId::new(id).map_err(engine_error)?;
            let definition = engine_host
                .inspect_trigger(&trigger_id)
                .await
                .map_err(engine_error)?;
            ensure_catalog_visibility(
                &definition.visibility,
                definition.provenance.session_id.as_deref(),
                definition.provenance.workspace_id.as_deref(),
                &actor,
                "trigger",
                id,
            )?;
            Ok(json!({
                "schemaVersion": INSPECT_SCHEMA_VERSION,
                "catalogRevision": catalog_revision,
                "kind": kind,
                "id": id,
                "definition": definition,
                "summary": trigger_summary(&definition),
                "conformance": {
                    "visible": true,
                    "targetFunction": definition.target_function.as_str(),
                    "deliveryMode": format!("{:?}", definition.delivery_mode)
                }
            }))
        }
        other => Err(invalid_params(format!(
            "unsupported catalog inspect kind {other}"
        ))),
    }
}

/// Create a durable catalog discovery report and stream event.
pub(crate) async fn conformance_report_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let actor = actor_context(invocation);
    let report = build_report_payload(engine_host, invocation, payload, &actor).await?;
    let status = report["status"].as_str().unwrap_or("failed").to_owned();
    let catalog_revision = report["catalogRevision"].as_u64().unwrap_or_default();
    let resource_id = format!(
        "{CATALOG_DISCOVERY_REPORT_KIND}:{}:{}",
        catalog_revision,
        invocation.id.as_str()
    );
    let resource = engine_host
        .create_resource(CreateResource {
            resource_id: Some(resource_id),
            kind: CATALOG_DISCOVERY_REPORT_KIND.to_owned(),
            schema_id: Some(CATALOG_DISCOVERY_REPORT_SCHEMA_ID.to_owned()),
            scope: report_scope(invocation),
            owner_worker_id: WorkerId::new(WORKER).map_err(engine_error)?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(status.clone()),
            policy: json!({
                "owner": WORKER,
                "authority": super::WRITE_SCOPE,
                "visibility": "definitions only; protected ids omitted"
            }),
            initial_payload: Some(report.clone()),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let cursor = publish_report_event(engine_host, invocation, &resource, &report).await?;
    let resource_ref = resource_ref(&resource, "catalog_discovery_report");

    Ok(json!({
        "status": status,
        "reportResourceId": resource.resource_id,
        "streamCursor": cursor.0,
        "summary": report["summary"].clone(),
        "resourceRefs": [resource_ref],
    }))
}
