use serde_json::{Value, json};

use crate::engine::{
    EngineResource, EngineResourceInspection, EngineResourceScope, EngineResourceVersion,
    Invocation, PublishStreamEvent, WorkerId,
};
use crate::shared::server::errors::CapabilityError;

use super::contract::{WEB_RESEARCH_LIFECYCLE_TOPIC, WORKER};
use super::projection::{request_summary, reviewed_summary, source_summary};
use super::records::resource_ref;
use super::validation::invalid;
use super::{
    Deps, WEB_RESEARCH_REQUEST_KIND, WEB_RESEARCH_REQUEST_SCHEMA_ID, WEB_RESEARCH_REVIEW_KIND,
    WEB_RESEARCH_REVIEW_SCHEMA_ID, WEB_RESEARCH_SOURCE_KIND, WEB_RESEARCH_SOURCE_SCHEMA_ID,
};

pub(super) async fn inspect_resource_required(
    deps: &Deps,
    resource_id: &str,
    label: &str,
) -> Result<EngineResourceInspection, CapabilityError> {
    deps.engine_host
        .inspect_resource(resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("missing {label} {resource_id}")))
}

pub(super) async fn request_summary_for_resource(
    deps: &Deps,
    resource: &EngineResource,
) -> Result<Value, CapabilityError> {
    let inspection =
        inspect_resource_required(deps, &resource.resource_id, "web research request").await?;
    let (version, payload) = current_payload(&inspection, "web_research_request projection")?;
    Ok(request_summary(&inspection.resource, version, payload))
}

pub(super) async fn review_summary_for_resource(
    deps: &Deps,
    resource: &EngineResource,
) -> Result<Value, CapabilityError> {
    let inspection =
        inspect_resource_required(deps, &resource.resource_id, "web research review").await?;
    let (version, payload) = current_payload(&inspection, "web_research_review projection")?;
    Ok(reviewed_summary(&inspection.resource, version, payload))
}

pub(super) async fn source_summary_for_resource(
    deps: &Deps,
    resource: &EngineResource,
) -> Result<Value, CapabilityError> {
    let inspection =
        inspect_resource_required(deps, &resource.resource_id, "web research source").await?;
    let (version, payload) = current_payload(&inspection, "web_research_source projection")?;
    Ok(source_summary(&inspection.resource, version, payload))
}

pub(super) fn ensure_request(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    ensure_kind_schema(
        inspection,
        operation,
        WEB_RESEARCH_REQUEST_KIND,
        WEB_RESEARCH_REQUEST_SCHEMA_ID,
    )
}

pub(super) fn ensure_review(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    ensure_kind_schema(
        inspection,
        operation,
        WEB_RESEARCH_REVIEW_KIND,
        WEB_RESEARCH_REVIEW_SCHEMA_ID,
    )
}

pub(super) fn ensure_source(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    ensure_kind_schema(
        inspection,
        operation,
        WEB_RESEARCH_SOURCE_KIND,
        WEB_RESEARCH_SOURCE_SCHEMA_ID,
    )
}

fn ensure_kind_schema(
    inspection: &EngineResourceInspection,
    operation: &str,
    kind: &str,
    schema_id: &str,
) -> Result<(), CapabilityError> {
    if inspection.resource.kind != kind {
        return Err(invalid(format!("{operation} expected {kind}")));
    }
    if inspection.resource.schema_id != schema_id {
        return Err(invalid(format!("{operation} expected schema {schema_id}")));
    }
    Ok(())
}

pub(super) fn ensure_scope(
    inspection: &EngineResourceInspection,
    expected: &EngineResourceScope,
    operation: &str,
) -> Result<(), CapabilityError> {
    if &inspection.resource.scope != expected {
        return Err(invalid(format!(
            "{operation} cannot access web research records outside the current scope"
        )));
    }
    Ok(())
}

pub(super) fn current_payload<'a>(
    inspection: &'a EngineResourceInspection,
    operation: &str,
) -> Result<(&'a EngineResourceVersion, &'a Value), CapabilityError> {
    let current = inspection
        .resource
        .current_version_id
        .as_deref()
        .ok_or_else(|| invalid(format!("{operation} resource has no current version")))?;
    let version = inspection
        .versions
        .iter()
        .find(|version| version.version_id == current)
        .ok_or_else(|| invalid(format!("{operation} current version is missing")))?;
    if !version.state.may_be_current() {
        return Err(invalid(format!(
            "{operation} current version is not available"
        )));
    }
    Ok((version, &version.payload))
}

pub(super) async fn publish_lifecycle_event(
    deps: &Deps,
    invocation: &Invocation,
    event_type: &str,
    resource: &EngineResource,
    payload: Value,
) -> Result<(), CapabilityError> {
    deps.engine_host
        .publish_stream_event(PublishStreamEvent {
            topic: WEB_RESEARCH_LIFECYCLE_TOPIC.to_owned(),
            payload: json!({
                "event": event_type,
                "resource": resource_ref(resource, "subject"),
                "details": payload,
                "webResearchBoundary": {
                    "metadataOnly": true,
                    "networkPolicy": "none",
                    "networkAccessPerformed": false,
                    "browserAutomationPerformed": false,
                    "searchPerformed": false,
                    "crawlPerformed": false,
                    "loginOrCookieReusePerformed": false,
                    "rawHtmlStored": false,
                    "pageDumpStored": false,
                    "browserLogsStored": false,
                    "cookiesStored": false,
                    "credentialsStored": false
                }
            }),
            visibility: crate::engine::VisibilityScope::Session,
            session_id: invocation.causal_context.session_id.clone(),
            workspace_id: invocation.causal_context.workspace_id.clone(),
            producer: WORKER.to_owned(),
            trace_id: Some(invocation.causal_context.trace_id.clone()),
            parent_invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    Ok(())
}

pub(super) fn worker_id() -> Result<WorkerId, CapabilityError> {
    WorkerId::new(WORKER).map_err(|error| CapabilityError::Internal {
        message: error.to_string(),
    })
}

pub(super) fn engine_error(error: crate::engine::EngineError) -> CapabilityError {
    CapabilityError::Internal {
        message: error.to_string(),
    }
}
