use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Value, json};

use crate::engine::{
    ActorContext, EffectClass, EngineHostHandle, EngineResource, FunctionDefinition, FunctionQuery,
    Invocation, PublishStreamEvent, StreamCursor, VisibilityScope,
};
use crate::shared::server::errors::CapabilityError;

use super::errors::engine_error;
use super::params::{optional_str, privileged_actor_context, query_from_payload};
use super::projection::{
    catalog_summary, filtered_trigger_types, filtered_triggers, filtered_workers,
    function_effect_contracts_ok, function_report_entry, protected_function_failure_counts,
    protected_omission_counts, resource_evidence, trigger_summary, trigger_type_summary,
    worker_summary,
};
use super::{
    CATALOG_DISCOVERY_TOPIC, CONFORMANCE_REPORT_FUNCTION, INSPECT_FUNCTION, SEARCH_FUNCTION, WORKER,
};

const REPORT_SCHEMA_VERSION: &str = "tron.catalog_discovery_report.v1";

pub(super) async fn build_report_payload(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
    actor: &ActorContext,
) -> Result<Value, CapabilityError> {
    let query = query_from_payload(payload, actor.clone())?;
    let visible_functions = engine_host.discover(&query).await;
    let visible_workers = filtered_workers(
        engine_host.visible_workers(actor).await,
        &visible_functions,
        payload,
    )?;
    let visible_triggers = filtered_triggers(engine_host.visible_triggers(actor).await, payload)?;
    let visible_trigger_types =
        filtered_trigger_types(engine_host.visible_trigger_types(actor).await, payload)?;
    let protected =
        protected_omission_counts(engine_host, payload, &visible_functions, &visible_workers)
            .await?;
    let resource_evidence = resource_evidence(engine_host).await?;
    let summary = catalog_summary(
        &visible_functions,
        &visible_workers,
        &visible_triggers,
        &visible_trigger_types,
        protected.clone(),
    );
    let audit_query = FunctionQuery {
        actor: Some(actor.clone()),
        ..FunctionQuery::default()
    };
    let audit_functions = engine_host.discover(&audit_query).await;
    let checks = report_checks(
        engine_host,
        &audit_functions,
        &visible_functions,
        &protected,
    )
    .await?;
    let status = if checks.iter().all(check_passed_or_noncritical) {
        "passed"
    } else {
        "failed"
    };

    Ok(json!({
        "schemaVersion": REPORT_SCHEMA_VERSION,
        "status": status,
        "catalogRevision": engine_host.catalog_revision().await.0,
        "reason": optional_str(payload, "reason")?.unwrap_or("catalog discovery conformance report"),
        "actor": {
            "kind": format!("{:?}", invocation.causal_context.actor_kind),
            "id": invocation.causal_context.actor_id.as_str(),
            "sessionId": invocation.causal_context.session_id,
            "workspaceId": invocation.causal_context.workspace_id
        },
        "summary": summary,
        "checks": checks,
        "visible": {
            "functions": visible_functions.iter().map(function_report_entry).collect::<Vec<_>>(),
            "workers": visible_workers.iter().map(worker_summary).collect::<Vec<_>>(),
            "triggers": visible_triggers.iter().map(trigger_summary).collect::<Vec<_>>(),
            "triggerTypes": visible_trigger_types.iter().map(trigger_type_summary).collect::<Vec<_>>()
        },
        "protected": protected,
        "resourceEvidence": resource_evidence,
    }))
}

pub(super) async fn publish_report_event(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    resource: &EngineResource,
    report: &Value,
) -> Result<StreamCursor, CapabilityError> {
    engine_host
        .publish_stream_event(PublishStreamEvent {
            topic: CATALOG_DISCOVERY_TOPIC.to_owned(),
            payload: json!({
                "type": "catalog_discovery.report.created",
                "status": report["status"],
                "catalogRevision": report["catalogRevision"],
                "reportResourceId": resource.resource_id,
                "summary": report["summary"],
                "authorityGrantId": invocation.causal_context.authority_grant_id.as_str(),
                "actorId": invocation.causal_context.actor_id.as_str(),
            }),
            visibility: VisibilityScope::System,
            session_id: invocation.causal_context.session_id.clone(),
            workspace_id: invocation.causal_context.workspace_id.clone(),
            producer: WORKER.to_owned(),
            trace_id: Some(invocation.causal_context.trace_id.clone()),
            parent_invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)
}

async fn report_checks(
    engine_host: &EngineHostHandle,
    audit_functions: &[FunctionDefinition],
    visible_functions: &[FunctionDefinition],
    protected: &Value,
) -> Result<Vec<Value>, CapabilityError> {
    let mut checks = Vec::new();
    let audit_ids = audit_functions
        .iter()
        .map(|function| function.id.as_str())
        .collect::<BTreeSet<_>>();
    let discovery_surface_present = [
        SEARCH_FUNCTION,
        INSPECT_FUNCTION,
        CONFORMANCE_REPORT_FUNCTION,
    ]
    .iter()
    .all(|id| audit_ids.contains(id));
    checks.push(check_value(
        "catalog_discovery_surface_registered",
        discovery_surface_present,
        "critical",
        "Search, inspect, and report functions are visible to the requesting actor.",
        json!({
            "requiredFunctions": [SEARCH_FUNCTION, INSPECT_FUNCTION, CONFORMANCE_REPORT_FUNCTION],
            "present": discovery_surface_present
        }),
    ));

    let missing_schema = visible_functions
        .iter()
        .filter(|function| {
            function.request_schema.is_none()
                || (function.response_schema.is_none() && !function.opaque_response)
        })
        .map(|function| function.id.as_str())
        .collect::<Vec<_>>();
    checks.push(check_value(
        "visible_functions_have_schemas",
        missing_schema.is_empty(),
        "critical",
        "Visible functions declare request schemas and response schemas or explicit opaque responses.",
        json!({"missing": missing_schema}),
    ));

    let missing_effect_contracts = visible_functions
        .iter()
        .filter(|function| !function_effect_contracts_ok(function))
        .map(|function| function.id.as_str())
        .collect::<Vec<_>>();
    checks.push(check_value(
        "mutating_functions_have_effect_contracts",
        missing_effect_contracts.is_empty(),
        "critical",
        "Visible mutating functions carry idempotency, compensation, and resource evidence contracts where required.",
        json!({"missing": missing_effect_contracts}),
    ));

    let discovery_contracts_ok = discovery_contracts_ok(audit_functions);
    checks.push(check_value(
        "discovery_functions_are_inspect_only",
        discovery_contracts_ok,
        "critical",
        "Search and inspect are pure reads; report generation only writes catalog-discovery evidence.",
        json!({"targetExecution": false}),
    ));

    let execute_singular = audit_ids.contains("capability::execute")
        && !audit_ids.iter().any(|id| {
            matches!(
                *id,
                "capability::search"
                    | "capability::inspect"
                    | "capability::status"
                    | "capability::registry_snapshot"
            ) || id.starts_with("capability::binding_")
                || id.starts_with("capability::plugin_")
                || id.starts_with("capability::conformance_")
        });
    checks.push(check_value(
        "provider_execute_surface_singular",
        execute_singular,
        "critical",
        "Provider-facing execution remains the single capability::execute primitive.",
        json!({"modelVisibleTool": "execute"}),
    ));

    checks.push(check_value(
        "protected_omission_preserves_hidden_names",
        protected
            .pointer("/functions/omitted")
            .and_then(Value::as_u64)
            .is_some(),
        "critical",
        "Protected functions are represented only as omission counts by visibility.",
        json!({"protected": protected}),
    ));

    let privileged_query = FunctionQuery {
        actor: Some(privileged_actor_context()),
        include_internal: true,
        ..FunctionQuery::default()
    };
    let protected_failures = protected_function_failure_counts(
        &engine_host.discover(&privileged_query).await,
        visible_functions,
    );
    checks.push(check_value(
        "protected_functions_checked_without_name_leak",
        protected_failures.values().all(|count| *count == 0),
        "critical",
        "Protected functions are checked for schema/effect conformance without storing their ids.",
        json!({"failureCounts": protected_failures}),
    ));

    Ok(checks)
}

fn check_value(id: &str, passed: bool, severity: &str, summary: &str, details: Value) -> Value {
    json!({
        "id": id,
        "status": if passed { "passed" } else { "failed" },
        "severity": severity,
        "summary": summary,
        "details": details
    })
}

fn check_passed_or_noncritical(check: &Value) -> bool {
    check["severity"] != "critical" || check["status"] == "passed"
}

fn discovery_contracts_ok(functions: &[FunctionDefinition]) -> bool {
    let by_id = functions
        .iter()
        .map(|function| (function.id.as_str(), function))
        .collect::<BTreeMap<_, _>>();
    by_id.get(SEARCH_FUNCTION).is_some_and(|function| {
        function.effect_class == EffectClass::PureRead
            && function.idempotency.is_none()
            && function.resource_lease.is_none()
            && function.compensation.is_none()
    }) && by_id.get(INSPECT_FUNCTION).is_some_and(|function| {
        function.effect_class == EffectClass::PureRead
            && function.idempotency.is_none()
            && function.resource_lease.is_none()
            && function.compensation.is_none()
    }) && by_id
        .get(CONFORMANCE_REPORT_FUNCTION)
        .is_some_and(|function| {
            function.effect_class == EffectClass::AppendOnlyEvent
                && function.idempotency.is_some()
                && function.resource_lease.is_some()
                && function.compensation.is_some()
        })
}
