use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use crate::engine::{
    CreateResource, EngineResourceLocation, EngineResourceScope, Invocation, ListResources,
};
use crate::shared::server::errors::CapabilityError;

use super::authority::{
    ensure_write_authority, inspect_read_grant, require_exact_resource_selector,
};
use super::contract::{
    WEB_RESEARCH_REQUEST_SCHEMA_VERSION, WEB_RESEARCH_REVIEW_SCHEMA_VERSION,
    WEB_RESEARCH_SOURCE_SCHEMA_VERSION,
};
use super::payload_safety::reject_unsafe_payload;
use super::projection::{
    inspected_request, inspected_review, inspected_source, request_summary, reviewed_summary,
    source_summary,
};
use super::records::{
    RequestInput, ReviewInput, SourceInput, request_record, request_resource_id, resource_policy,
    resource_ref, review_record, review_resource_id, scope_ref, side_effect_proof, source_record,
    source_resource_id, version_ref,
};
use super::resource_store::{
    current_payload, engine_error, ensure_request, ensure_review, ensure_scope, ensure_source,
    inspect_resource_required, publish_lifecycle_event, request_summary_for_resource,
    review_summary_for_resource, source_summary_for_resource, worker_id,
};
use super::validation::*;
use super::{
    Deps, WEB_RESEARCH_REQUEST_KIND, WEB_RESEARCH_REQUEST_SCHEMA_ID, WEB_RESEARCH_REVIEW_KIND,
    WEB_RESEARCH_REVIEW_SCHEMA_ID, WEB_RESEARCH_SOURCE_KIND, WEB_RESEARCH_SOURCE_SCHEMA_ID,
};

pub(crate) async fn record_request_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    ensure_write_authority(deps, invocation, "web_research_request_record").await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let scope = resource_scope(invocation)?;
    let request_id_input = optional_string(payload, "webResearchRequestId")?
        .unwrap_or_else(|| invocation.id.as_str().to_owned());
    let request_id = bounded_token("webResearchRequestId", &request_id_input, ID_MAX_BYTES)?;
    let state = request_lifecycle_state(payload)?;
    let title = bounded_text(
        "title",
        &required_string(payload, "title")?,
        TITLE_MAX_BYTES,
    )?;
    let question_summary = bounded_text(
        "questionSummary",
        &required_string(payload, "questionSummary")?,
        SUMMARY_MAX_BYTES,
    )?;
    let scope_summary = optional_string(payload, "scopeSummary")?
        .map(|value| bounded_text("scopeSummary", &value, SUMMARY_MAX_BYTES))
        .transpose()?;
    let record = request_record(RequestInput {
        request_id: &request_id,
        state: &state,
        scope: &scope,
        title: &title,
        question_summary: &question_summary,
        scope_summary: scope_summary.as_deref(),
        policy_labels: labels(payload, "policyLabels")?,
        source_refs: refs(payload, "sourceRefs")?,
        citation_refs: refs(payload, "citationRefs")?,
        robots_evidence_refs: refs(payload, "robotsEvidenceRefs")?,
        dependency_request_refs: refs(payload, "dependencyRequestRefs")?,
        current_scope_refs: refs(payload, "currentScopeRefs")?,
        evidence_refs: refs(payload, "evidenceRefs")?,
        created_at: &operation_at.to_rfc3339(),
        updated_at: &operation_at.to_rfc3339(),
        invocation,
        idempotency_key: &idempotency_key,
    });
    let resource_id = request_resource_id(&scope, &request_id, &idempotency_key);
    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_request(&existing, "web_research_request_record replay")?;
        ensure_scope(&existing, &scope, "web_research_request_record replay")?;
        let (version, payload) = current_payload(&existing, "web_research_request_record replay")?;
        return Ok(json!({
            "schemaVersion": WEB_RESEARCH_REQUEST_SCHEMA_VERSION,
            "operation": "web_research_request_record",
            "status": existing.resource.lifecycle,
            "idempotentReplay": true,
            "webResearchRequestResourceId": resource_id,
            "webResearchRequestVersionId": version.version_id,
            "request": request_summary(&existing.resource, version, payload),
            "resourceRefs": [version_ref(&existing.resource, version, "web_research_request")]
        }));
    }
    let resource = create_resource(
        deps,
        invocation,
        resource_id,
        WEB_RESEARCH_REQUEST_KIND,
        WEB_RESEARCH_REQUEST_SCHEMA_ID,
        &scope,
        &state,
        record,
        "web_research_request",
        &format!("web-research-request:{request_id}"),
    )
    .await?;
    let version_id = current_version_id(&resource, "web research request")?;
    publish_lifecycle_event(
        deps,
        invocation,
        "web_research.request_recorded",
        &resource,
        json!({"metadataOnly": true, "reviewRequired": true, "networkPolicy": "none"}),
    )
    .await?;
    Ok(json!({
        "schemaVersion": WEB_RESEARCH_REQUEST_SCHEMA_VERSION,
        "operation": "web_research_request_record",
        "status": resource.lifecycle,
        "idempotentReplay": false,
        "webResearchRequestResourceId": resource.resource_id,
        "webResearchRequestVersionId": version_id,
        "request": request_summary_for_resource(deps, &resource).await?,
        "resourceRefs": [resource_ref(&resource, "web_research_request")]
    }))
}

pub(crate) async fn list_request_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    list_values(
        deps,
        invocation,
        payload,
        "web_research_request_list",
        WEB_RESEARCH_REQUEST_KIND,
        "pending_review",
        request_summary,
        "requests",
    )
    .await
}

pub(crate) async fn inspect_request_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let grant = inspect_read_grant(deps, invocation, "web_research_request_inspect").await?;
    let resource_id = required_string(payload, "webResearchRequestResourceId")?;
    validate_request_resource_id(&resource_id)?;
    require_exact_resource_selector(&grant, &resource_id, "web_research_request_inspect")?;
    let scope = resource_scope(invocation)?;
    let inspection = inspect_resource_required(deps, &resource_id, "web research request").await?;
    ensure_request(&inspection, "web_research_request_inspect")?;
    ensure_scope(&inspection, &scope, "web_research_request_inspect")?;
    let (version, payload) = current_payload(&inspection, "web_research_request_inspect")?;
    Ok(json!({
        "schemaVersion": WEB_RESEARCH_REQUEST_SCHEMA_VERSION,
        "operation": "web_research_request_inspect",
        "scope": scope_ref(&scope),
        "request": inspected_request(&inspection.resource, version, payload),
        "sideEffects": side_effect_proof()
    }))
}

pub(crate) async fn record_review_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let grant = ensure_write_authority(deps, invocation, "web_research_review_record").await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let scope = resource_scope(invocation)?;
    let request_resource_id = required_string(payload, "webResearchRequestResourceId")?;
    validate_request_resource_id(&request_resource_id)?;
    require_exact_resource_selector(&grant, &request_resource_id, "web_research_review_record")?;
    let request_inspection =
        inspect_resource_required(deps, &request_resource_id, "web research request").await?;
    ensure_request(&request_inspection, "web_research_review_record")?;
    ensure_scope(&request_inspection, &scope, "web_research_review_record")?;
    let (request_version, _) = current_payload(&request_inspection, "web_research_review_record")?;
    let review_id_input = optional_string(payload, "webResearchReviewId")?
        .unwrap_or_else(|| invocation.id.as_str().to_owned());
    let review_id = bounded_token("webResearchReviewId", &review_id_input, ID_MAX_BYTES)?;
    let state = review_lifecycle_state(payload)?;
    let outcome = bounded_token(
        "reviewOutcome",
        &optional_string(payload, "reviewOutcome")?.unwrap_or_else(|| "pending_review".to_owned()),
        TOKEN_MAX_BYTES,
    )?;
    let summary = bounded_text(
        "reviewSummary",
        &required_string(payload, "reviewSummary")?,
        SUMMARY_MAX_BYTES,
    )?;
    let record = review_record(ReviewInput {
        review_id: &review_id,
        state: &state,
        request_resource: &request_inspection.resource,
        request_version,
        outcome: &outcome,
        summary: &summary,
        policy_labels: labels(payload, "policyLabels")?,
        source_refs: refs(payload, "sourceRefs")?,
        citation_refs: refs(payload, "citationRefs")?,
        robots_evidence_refs: refs(payload, "robotsEvidenceRefs")?,
        dependency_request_refs: refs(payload, "dependencyRequestRefs")?,
        evidence_refs: refs(payload, "evidenceRefs")?,
        created_at: &operation_at.to_rfc3339(),
        updated_at: &operation_at.to_rfc3339(),
        invocation,
        idempotency_key: &idempotency_key,
    });
    let resource_id =
        review_resource_id(&scope, &review_id, &request_resource_id, &idempotency_key);
    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_review(&existing, "web_research_review_record replay")?;
        ensure_scope(&existing, &scope, "web_research_review_record replay")?;
        let (version, payload) = current_payload(&existing, "web_research_review_record replay")?;
        return Ok(json!({
            "schemaVersion": WEB_RESEARCH_REVIEW_SCHEMA_VERSION,
            "operation": "web_research_review_record",
            "status": existing.resource.lifecycle,
            "idempotentReplay": true,
            "webResearchReviewResourceId": resource_id,
            "webResearchReviewVersionId": version.version_id,
            "review": reviewed_summary(&existing.resource, version, payload),
            "resourceRefs": [version_ref(&existing.resource, version, "web_research_review")]
        }));
    }
    let resource = create_resource(
        deps,
        invocation,
        resource_id,
        WEB_RESEARCH_REVIEW_KIND,
        WEB_RESEARCH_REVIEW_SCHEMA_ID,
        &scope,
        &state,
        record,
        "web_research_review",
        &format!("web-research-review:{review_id}"),
    )
    .await?;
    let version_id = current_version_id(&resource, "web research review")?;
    publish_lifecycle_event(
        deps,
        invocation,
        "web_research.review_recorded",
        &resource,
        json!({"metadataOnly": true, "requestLinked": true, "networkPolicy": "none"}),
    )
    .await?;
    Ok(json!({
        "schemaVersion": WEB_RESEARCH_REVIEW_SCHEMA_VERSION,
        "operation": "web_research_review_record",
        "status": resource.lifecycle,
        "idempotentReplay": false,
        "webResearchReviewResourceId": resource.resource_id,
        "webResearchReviewVersionId": version_id,
        "review": review_summary_for_resource(deps, &resource).await?,
        "resourceRefs": [resource_ref(&resource, "web_research_review")]
    }))
}

pub(crate) async fn list_review_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    list_values(
        deps,
        invocation,
        payload,
        "web_research_review_list",
        WEB_RESEARCH_REVIEW_KIND,
        "pending_review",
        reviewed_summary,
        "reviews",
    )
    .await
}

pub(crate) async fn inspect_review_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let grant = inspect_read_grant(deps, invocation, "web_research_review_inspect").await?;
    let resource_id = required_string(payload, "webResearchReviewResourceId")?;
    validate_review_resource_id(&resource_id)?;
    require_exact_resource_selector(&grant, &resource_id, "web_research_review_inspect")?;
    let scope = resource_scope(invocation)?;
    let inspection = inspect_resource_required(deps, &resource_id, "web research review").await?;
    ensure_review(&inspection, "web_research_review_inspect")?;
    ensure_scope(&inspection, &scope, "web_research_review_inspect")?;
    let (version, payload) = current_payload(&inspection, "web_research_review_inspect")?;
    Ok(json!({
        "schemaVersion": WEB_RESEARCH_REVIEW_SCHEMA_VERSION,
        "operation": "web_research_review_inspect",
        "scope": scope_ref(&scope),
        "review": inspected_review(&inspection.resource, version, payload),
        "sideEffects": side_effect_proof()
    }))
}

pub(crate) async fn record_source_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let grant = ensure_write_authority(deps, invocation, "web_research_source_record").await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let scope = resource_scope(invocation)?;
    let request_resource_id = optional_string(payload, "webResearchRequestResourceId")?;
    let review_resource_id = optional_string(payload, "webResearchReviewResourceId")?;
    if request_resource_id.is_none() && review_resource_id.is_none() {
        return Err(invalid(
            "web_research_source_record requires request or review linkage",
        ));
    }
    let request_ref = if let Some(id) = request_resource_id.as_deref() {
        validate_request_resource_id(id)?;
        require_exact_resource_selector(&grant, id, "web_research_source_record")?;
        let inspection = inspect_resource_required(deps, id, "web research request").await?;
        ensure_request(&inspection, "web_research_source_record")?;
        ensure_scope(&inspection, &scope, "web_research_source_record")?;
        let (version, _) = current_payload(&inspection, "web_research_source_record")?;
        Some(version_ref(
            &inspection.resource,
            version,
            "web_research_request",
        ))
    } else {
        None
    };
    let review_ref = if let Some(id) = review_resource_id.as_deref() {
        validate_review_resource_id(id)?;
        require_exact_resource_selector(&grant, id, "web_research_source_record")?;
        let inspection = inspect_resource_required(deps, id, "web research review").await?;
        ensure_review(&inspection, "web_research_source_record")?;
        ensure_scope(&inspection, &scope, "web_research_source_record")?;
        let (version, _) = current_payload(&inspection, "web_research_source_record")?;
        Some(version_ref(
            &inspection.resource,
            version,
            "web_research_review",
        ))
    } else {
        None
    };
    let source_id_input = optional_string(payload, "webResearchSourceId")?
        .unwrap_or_else(|| invocation.id.as_str().to_owned());
    let source_id = bounded_token("webResearchSourceId", &source_id_input, ID_MAX_BYTES)?;
    let state = source_lifecycle_state(payload)?;
    let artifact_kind = bounded_token(
        "artifactKind",
        &required_string(payload, "artifactKind")?,
        TOKEN_MAX_BYTES,
    )?;
    let title = bounded_text(
        "title",
        &required_string(payload, "title")?,
        TITLE_MAX_BYTES,
    )?;
    let summary = bounded_text(
        "summary",
        &required_string(payload, "summary")?,
        SUMMARY_MAX_BYTES,
    )?;
    let parent_id = review_resource_id
        .as_deref()
        .or(request_resource_id.as_deref())
        .expect("checked parent id");
    let record = source_record(SourceInput {
        source_id: &source_id,
        state: &state,
        scope: &scope,
        request_ref,
        review_ref,
        artifact_kind: &artifact_kind,
        title: &title,
        summary: &summary,
        policy_labels: labels(payload, "policyLabels")?,
        source_refs: refs(payload, "sourceRefs")?,
        citation_refs: refs(payload, "citationRefs")?,
        robots_evidence_refs: refs(payload, "robotsEvidenceRefs")?,
        dependency_request_refs: refs(payload, "dependencyRequestRefs")?,
        evidence_refs: refs(payload, "evidenceRefs")?,
        created_at: &operation_at.to_rfc3339(),
        updated_at: &operation_at.to_rfc3339(),
        invocation,
        idempotency_key: &idempotency_key,
    });
    let resource_id = source_resource_id(&scope, &source_id, parent_id, &idempotency_key);
    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_source(&existing, "web_research_source_record replay")?;
        ensure_scope(&existing, &scope, "web_research_source_record replay")?;
        let (version, payload) = current_payload(&existing, "web_research_source_record replay")?;
        return Ok(json!({
            "schemaVersion": WEB_RESEARCH_SOURCE_SCHEMA_VERSION,
            "operation": "web_research_source_record",
            "status": existing.resource.lifecycle,
            "idempotentReplay": true,
            "webResearchSourceResourceId": resource_id,
            "webResearchSourceVersionId": version.version_id,
            "source": source_summary(&existing.resource, version, payload),
            "resourceRefs": [version_ref(&existing.resource, version, "web_research_source")]
        }));
    }
    let resource = create_resource(
        deps,
        invocation,
        resource_id,
        WEB_RESEARCH_SOURCE_KIND,
        WEB_RESEARCH_SOURCE_SCHEMA_ID,
        &scope,
        &state,
        record,
        "web_research_source",
        &format!("web-research-source:{source_id}"),
    )
    .await?;
    let version_id = current_version_id(&resource, "web research source")?;
    publish_lifecycle_event(
        deps,
        invocation,
        "web_research.source_recorded",
        &resource,
        json!({"metadataOnly": true, "boundedSummaryOnly": true, "networkPolicy": "none"}),
    )
    .await?;
    Ok(json!({
        "schemaVersion": WEB_RESEARCH_SOURCE_SCHEMA_VERSION,
        "operation": "web_research_source_record",
        "status": resource.lifecycle,
        "idempotentReplay": false,
        "webResearchSourceResourceId": resource.resource_id,
        "webResearchSourceVersionId": version_id,
        "source": source_summary_for_resource(deps, &resource).await?,
        "resourceRefs": [resource_ref(&resource, "web_research_source")]
    }))
}

pub(crate) async fn list_source_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    list_values(
        deps,
        invocation,
        payload,
        "web_research_source_list",
        WEB_RESEARCH_SOURCE_KIND,
        "available",
        source_summary,
        "sources",
    )
    .await
}

pub(crate) async fn inspect_source_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let grant = inspect_read_grant(deps, invocation, "web_research_source_inspect").await?;
    let resource_id = required_string(payload, "webResearchSourceResourceId")?;
    validate_source_resource_id(&resource_id)?;
    require_exact_resource_selector(&grant, &resource_id, "web_research_source_inspect")?;
    let scope = resource_scope(invocation)?;
    let inspection = inspect_resource_required(deps, &resource_id, "web research source").await?;
    ensure_source(&inspection, "web_research_source_inspect")?;
    ensure_scope(&inspection, &scope, "web_research_source_inspect")?;
    let (version, payload) = current_payload(&inspection, "web_research_source_inspect")?;
    Ok(json!({
        "schemaVersion": WEB_RESEARCH_SOURCE_SCHEMA_VERSION,
        "operation": "web_research_source_inspect",
        "scope": scope_ref(&scope),
        "source": inspected_source(&inspection.resource, version, payload),
        "sideEffects": side_effect_proof()
    }))
}

async fn create_resource(
    deps: &Deps,
    invocation: &Invocation,
    resource_id: String,
    kind: &str,
    schema_id: &str,
    scope: &EngineResourceScope,
    lifecycle: &str,
    payload: Value,
    location_kind: &str,
    location_uri: &str,
) -> Result<crate::engine::EngineResource, CapabilityError> {
    deps.engine_host
        .create_resource(CreateResource {
            resource_id: Some(resource_id),
            kind: kind.to_owned(),
            schema_id: Some(schema_id.to_owned()),
            scope: scope.clone(),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(lifecycle.to_owned()),
            policy: resource_policy(kind),
            initial_payload: Some(payload),
            locations: vec![EngineResourceLocation {
                kind: location_kind.to_owned(),
                uri: location_uri.to_owned(),
                mime_type: Some("application/json".to_owned()),
                size_bytes: None,
            }],
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)
}

fn current_version_id(
    resource: &crate::engine::EngineResource,
    label: &str,
) -> Result<String, CapabilityError> {
    resource.current_version_id.clone().ok_or_else(|| {
        invalid(format!(
            "{label} resource was created without a current version"
        ))
    })
}

fn refs(payload: &Value, field: &str) -> Result<Vec<Value>, CapabilityError> {
    validate_ref_array(
        field,
        &optional_array(payload, field)?.unwrap_or_default(),
        MAX_REFS,
    )
}

async fn list_values(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation: &str,
    kind: &str,
    default_lifecycle: &str,
    summarize: fn(
        &crate::engine::EngineResource,
        &crate::engine::EngineResourceVersion,
        &Value,
    ) -> Value,
    response_key: &str,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    inspect_read_grant(deps, invocation, operation).await?;
    let scope = resource_scope(invocation)?;
    let limit = optional_u64(payload, "limit")?
        .map(|value| usize::try_from(value).unwrap_or(LIST_LIMIT_MAX))
        .unwrap_or(LIST_LIMIT_DEFAULT)
        .min(LIST_LIMIT_MAX);
    let lifecycle =
        optional_string(payload, "lifecycleState")?.unwrap_or_else(|| default_lifecycle.to_owned());
    let resources = deps
        .engine_host
        .list_resources(ListResources {
            kind: Some(kind.to_owned()),
            scope: Some(scope.clone()),
            lifecycle: Some(lifecycle.clone()),
            limit,
        })
        .await
        .map_err(engine_error)?;
    let mut values = Vec::new();
    for resource in resources {
        let inspection =
            inspect_resource_required(deps, &resource.resource_id, "web research record").await?;
        ensure_scope(&inspection, &scope, operation)?;
        match kind {
            WEB_RESEARCH_REQUEST_KIND => ensure_request(&inspection, operation)?,
            WEB_RESEARCH_REVIEW_KIND => ensure_review(&inspection, operation)?,
            WEB_RESEARCH_SOURCE_KIND => ensure_source(&inspection, operation)?,
            _ => return Err(invalid("unsupported web research kind")),
        }
        let (version, payload) = current_payload(&inspection, operation)?;
        values.push(summarize(&inspection.resource, version, payload));
    }
    Ok(json!({
        "operation": operation,
        "scope": scope_ref(&scope),
        "kind": kind,
        "lifecycleState": lifecycle,
        "limit": limit,
        "truncated": values.len() >= limit,
        response_key: values,
        "sideEffects": side_effect_proof()
    }))
}
