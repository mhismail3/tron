//! Bounded resource collection projections for domain workers.
//!
//! Domain-owned list views and cleanup traversals should stay projections over
//! canonical `resource::list` and `resource::inspect` invocations. This helper
//! keeps the list/inspect shape bounded and auditable without giving domains a
//! separate resource reader or persistence path.

use serde_json::{Value, json};

use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, EngineHostHandle, FunctionId, Invocation,
    TraceId,
};
use crate::shared::server::errors::CapabilityError;

pub(crate) const MAX_RESOURCE_COLLECTION_LIMIT: usize = 500;

pub(crate) struct ResourceCollectionQuery<'a> {
    pub(crate) kind: &'a str,
    pub(crate) resource_id_prefix: &'a str,
    pub(crate) limit: usize,
    pub(crate) actor_id: &'a str,
    pub(crate) default_trace_id: &'a str,
    pub(crate) default_session_id: &'a str,
    pub(crate) default_workspace_id: &'a str,
    pub(crate) idempotency_namespace: &'a str,
    pub(crate) read_scope: &'a str,
    pub(crate) error_code: &'a str,
}

pub(crate) struct CurrentResourceProjection {
    pub(crate) resource_id: String,
    pub(crate) payload: Value,
}

pub(crate) async fn current_payloads_by_prefix(
    engine_host: &EngineHostHandle,
    parent: Option<&Invocation>,
    query: ResourceCollectionQuery<'_>,
) -> Result<Vec<CurrentResourceProjection>, CapabilityError> {
    let mut projections = Vec::new();
    for resource in listed_resources_by_prefix(engine_host, parent, &query).await? {
        let Some(resource_id) = resource.get("resourceId").and_then(Value::as_str) else {
            continue;
        };
        let inspected = invoke_resource_capability(
            engine_host,
            parent,
            &query,
            "resource::inspect",
            json!({"resourceId": resource_id}),
            &format!("inspect:{resource_id}"),
        )
        .await?;
        let Some(inspection) = inspected
            .get("inspection")
            .filter(|inspection| !inspection.is_null())
        else {
            continue;
        };
        if let Some(payload) = current_payload(inspection) {
            projections.push(CurrentResourceProjection {
                resource_id: resource_id.to_owned(),
                payload,
            });
        }
    }
    Ok(projections)
}

pub(crate) async fn resource_ids_by_prefix(
    engine_host: &EngineHostHandle,
    parent: Option<&Invocation>,
    query: ResourceCollectionQuery<'_>,
) -> Result<Vec<String>, CapabilityError> {
    Ok(listed_resources_by_prefix(engine_host, parent, &query)
        .await?
        .into_iter()
        .filter_map(|resource| {
            resource
                .get("resourceId")
                .and_then(Value::as_str)
                .map(str::to_owned)
        })
        .collect())
}

async fn listed_resources_by_prefix(
    engine_host: &EngineHostHandle,
    parent: Option<&Invocation>,
    query: &ResourceCollectionQuery<'_>,
) -> Result<Vec<Value>, CapabilityError> {
    let limit = query.limit.clamp(1, MAX_RESOURCE_COLLECTION_LIMIT);
    let listed = invoke_resource_capability(
        engine_host,
        parent,
        query,
        "resource::list",
        json!({"kind": query.kind, "limit": limit}),
        "list",
    )
    .await?;
    Ok(listed["resources"]
        .as_array()
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .filter(|resource| resource["lifecycle"] != "discarded")
        .filter(|resource| {
            resource["resourceId"]
                .as_str()
                .is_some_and(|id| id.starts_with(query.resource_id_prefix))
        })
        .collect())
}

fn current_payload(inspection: &Value) -> Option<Value> {
    let current = inspection
        .pointer("/resource/currentVersionId")
        .and_then(Value::as_str)?;
    inspection
        .get("versions")
        .and_then(Value::as_array)?
        .iter()
        .find(|version| version["versionId"] == current)?
        .get("payload")
        .cloned()
}

async fn invoke_resource_capability(
    engine_host: &EngineHostHandle,
    parent: Option<&Invocation>,
    query: &ResourceCollectionQuery<'_>,
    function_id: &str,
    payload: Value,
    idempotency_label: &str,
) -> Result<Value, CapabilityError> {
    let mut causal = CausalContext::new(
        ActorId::new(query.actor_id).map_err(|error| projection_error(query, error))?,
        ActorKind::System,
        AuthorityGrantId::new("engine-system").map_err(|error| projection_error(query, error))?,
        TraceId::new(
            parent
                .map(|invocation| invocation.causal_context.trace_id.as_str())
                .unwrap_or(query.default_trace_id),
        )
        .map_err(|error| projection_error(query, error))?,
    )
    .with_scope(query.read_scope)
    .with_idempotency_key(format!(
        "{}:{}:{idempotency_label}",
        query.idempotency_namespace,
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
            .with_session_id(query.default_session_id)
            .with_workspace_id(query.default_workspace_id);
    }
    let result = engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new(function_id).map_err(|error| projection_error(query, error))?,
            payload,
            causal,
        ))
        .await;
    if let Some(error) = result.error {
        return Err(projection_error(query, error));
    }
    result.value.ok_or_else(|| CapabilityError::Custom {
        code: query.error_code.to_owned(),
        message: format!("{function_id} returned no value"),
        details: None,
    })
}

fn projection_error(
    query: &ResourceCollectionQuery<'_>,
    error: impl std::fmt::Display,
) -> CapabilityError {
    CapabilityError::Custom {
        code: query.error_code.to_owned(),
        message: error.to_string(),
        details: None,
    }
}
