//! Read-only web source citation inspection.

use serde_json::{Value, json};

use crate::engine::{
    EngineGrant, EngineResource, EngineResourceInspection, EngineResourceScope,
    EngineResourceVersion, Invocation, ListResources, WEB_SOURCE_KIND, WEB_SOURCE_SCHEMA_ID,
};
use crate::shared::server::errors::CapabilityError;

use super::fetch::{MAX_TITLE_BYTES, safe_title};
use super::{Deps, READ_SCOPE, WEB_SOURCE_SCHEMA_VERSION};

const RESOURCE_READ_SCOPE: &str = "resource.read";
const LIST_LIMIT_DEFAULT: usize = 25;
const LIST_LIMIT_MAX: usize = 100;
const LIST_PREVIEW_BYTES_DEFAULT: usize = 512;
const LIST_PREVIEW_BYTES_MAX: usize = 2_000;
const INSPECT_SNIPPET_BYTES_DEFAULT: usize = 4_000;
const INSPECT_SNIPPET_BYTES_MAX: usize = 20_000;
const WEB_SOURCE_ID_PREFIX: &str = "web_source:";

pub(crate) async fn web_source_list_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    inspect_read_grant(deps, invocation, "web_source_list").await?;
    let include_archived = optional_bool(payload, "includeArchived")?.unwrap_or(false);
    let limit = optional_u64(payload, "limit")?
        .map(|value| value as usize)
        .unwrap_or(LIST_LIMIT_DEFAULT)
        .clamp(1, LIST_LIMIT_MAX);
    let max_preview_bytes = optional_u64(payload, "maxPreviewBytes")?
        .map(|value| value as usize)
        .unwrap_or(LIST_PREVIEW_BYTES_DEFAULT)
        .clamp(1, LIST_PREVIEW_BYTES_MAX);
    let scope = resource_scope(invocation);
    let resources = deps
        .engine_host
        .list_resources(ListResources {
            kind: Some(WEB_SOURCE_KIND.to_owned()),
            scope: Some(scope.clone()),
            lifecycle: if include_archived {
                None
            } else {
                Some("fetched".to_owned())
            },
            limit: limit.saturating_add(1),
        })
        .await
        .map_err(engine_error)?;
    let truncated = resources.len() > limit;
    let mut sources = Vec::new();
    for resource in resources.into_iter().take(limit) {
        let Some(inspection) = deps
            .engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
        else {
            continue;
        };
        ensure_web_source(&inspection, "web_source_list")?;
        ensure_scope(&inspection, &scope, "web_source_list")?;
        let (version, source) = current_available_source(&inspection, "web_source_list")?;
        sources.push(source_summary(
            &inspection.resource,
            version,
            source,
            max_preview_bytes,
        ));
    }

    let returned = sources.len();
    Ok(json!({
        "schemaVersion": WEB_SOURCE_SCHEMA_VERSION,
        "operation": "web_source_list",
        "scope": scope_ref(&scope),
        "sources": sources,
        "limits": {
            "requestedLimit": limit,
            "returned": returned,
            "truncated": truncated,
            "maxPreviewBytes": max_preview_bytes,
            "includeArchived": include_archived
        },
        "network": {"performed": false, "requiredPolicy": "none"}
    }))
}

pub(crate) async fn web_source_inspect_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    inspect_read_grant(deps, invocation, "web_source_inspect").await?;
    let resource_id = required_string(payload, "webSourceResourceId")?;
    validate_web_source_id(&resource_id)?;
    let requested_version_id = optional_string(payload, "webSourceVersionId")?;
    let max_snippet_bytes = optional_u64(payload, "maxSnippetBytes")?
        .map(|value| value as usize)
        .unwrap_or(INSPECT_SNIPPET_BYTES_DEFAULT)
        .clamp(1, INSPECT_SNIPPET_BYTES_MAX);
    let scope = resource_scope(invocation);
    let inspection = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid("web_source_inspect webSourceResourceId was not found"))?;
    ensure_web_source(&inspection, "web_source_inspect")?;
    ensure_scope(&inspection, &scope, "web_source_inspect")?;
    let (version, source) = current_available_source(&inspection, "web_source_inspect")?;
    if let Some(expected) = requested_version_id {
        validate_version_id(&expected)?;
        if !inspection
            .versions
            .iter()
            .any(|version| version.version_id == expected)
        {
            return Err(invalid(
                "web_source_inspect webSourceVersionId was not found for this resource",
            ));
        }
        if version.version_id != expected {
            return Err(invalid(
                "web_source_inspect webSourceVersionId is stale; inspect the current version",
            ));
        }
    }

    Ok(json!({
        "schemaVersion": WEB_SOURCE_SCHEMA_VERSION,
        "operation": "web_source_inspect",
        "scope": scope_ref(&scope),
        "source": source_details(&inspection.resource, version, source, max_snippet_bytes),
        "network": {"performed": false, "requiredPolicy": "none"}
    }))
}

async fn inspect_read_grant(
    deps: &Deps,
    invocation: &Invocation,
    operation: &str,
) -> Result<EngineGrant, CapabilityError> {
    let grant = deps
        .engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .map_err(|error| internal(format!("inspect web source authority grant: {error}")))?
        .ok_or_else(|| invalid(format!("{operation} authority grant was not found")))?;
    require_grant_item(
        &grant.allowed_authority_scopes,
        READ_SCOPE,
        "authority scope",
        operation,
    )?;
    require_grant_item(
        &grant.allowed_authority_scopes,
        RESOURCE_READ_SCOPE,
        "authority scope",
        operation,
    )?;
    require_grant_item(
        &grant.allowed_resource_kinds,
        WEB_SOURCE_KIND,
        "resource kind",
        operation,
    )?;
    if grant.network_policy != "none" {
        return Err(invalid(format!(
            "{operation} requires an authority grant with networkPolicy none"
        )));
    }
    if !allows_item(&grant.resource_selectors, "*")
        && !allows_item(
            &grant.resource_selectors,
            &format!("kind:{WEB_SOURCE_KIND}"),
        )
    {
        return Err(invalid(format!(
            "{operation} requires a grant selector for kind:{WEB_SOURCE_KIND}"
        )));
    }
    Ok(grant)
}

fn require_grant_item(
    items: &[String],
    required: &str,
    label: &str,
    operation: &str,
) -> Result<(), CapabilityError> {
    if allows_item(items, required) {
        Ok(())
    } else {
        Err(invalid(format!("{operation} requires {label} {required}")))
    }
}

fn allows_item(items: &[String], required: &str) -> bool {
    items.iter().any(|item| item == "*" || item == required)
}

fn current_available_source<'a>(
    inspection: &'a EngineResourceInspection,
    operation: &str,
) -> Result<(&'a EngineResourceVersion, &'a Value), CapabilityError> {
    let current = inspection
        .resource
        .current_version_id
        .as_deref()
        .ok_or_else(|| invalid(format!("{operation} web_source has no current version")))?;
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

fn source_summary(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    source: &Value,
    max_preview_bytes: usize,
) -> Value {
    let preview = source
        .pointer("/textEvidence/preview")
        .and_then(Value::as_str)
        .unwrap_or("");
    let snippet = bounded_utf8(preview, max_preview_bytes);
    json!({
        "requestedUrl": source.get("requestedUrl").cloned().unwrap_or(Value::Null),
        "finalUrl": source.get("finalUrl").cloned().unwrap_or(Value::Null),
        "state": source.get("state").cloned().unwrap_or(Value::Null),
        "fetchedAt": source.get("fetchedAt").cloned().unwrap_or(Value::Null),
        "status": source.get("status").cloned().unwrap_or(Value::Null),
        "contentType": source.get("contentType").cloned().unwrap_or(Value::Null),
        "title": safe_source_title(source),
        "capturedSha256": source.pointer("/byteEvidence/sha256").cloned().unwrap_or(Value::Null),
        "capturedBytes": source.pointer("/byteEvidence/capturedBytes").cloned().unwrap_or(Value::Null),
        "outputTextBytes": source.pointer("/textEvidence/textBytes").cloned().unwrap_or(Value::Null),
        "extraction": extraction_metadata(source),
        "truncation": truncation_metadata(source, &snippet, max_preview_bytes),
        "redaction": source.get("redaction").cloned().unwrap_or(Value::Null),
        "snippet": snippet.text,
        "traceRefs": source.get("traceRefs").cloned().unwrap_or_else(|| json!([])),
        "replayRefs": source.get("replayRefs").cloned().unwrap_or_else(|| json!([])),
        "archive": source.get("archive").cloned().unwrap_or(Value::Null),
        "resourceRefs": [resource_ref(resource, version, "source")]
    })
}

fn source_details(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    source: &Value,
    max_snippet_bytes: usize,
) -> Value {
    let preview = source
        .pointer("/textEvidence/preview")
        .and_then(Value::as_str)
        .unwrap_or("");
    let snippet = bounded_utf8(preview, max_snippet_bytes);
    json!({
        "requestedUrl": source.get("requestedUrl").cloned().unwrap_or(Value::Null),
        "finalUrl": source.get("finalUrl").cloned().unwrap_or(Value::Null),
        "state": source.get("state").cloned().unwrap_or(Value::Null),
        "fetchedAt": source.get("fetchedAt").cloned().unwrap_or(Value::Null),
        "status": source.get("status").cloned().unwrap_or(Value::Null),
        "contentType": source.get("contentType").cloned().unwrap_or(Value::Null),
        "byteEvidence": source.get("byteEvidence").cloned().unwrap_or(Value::Null),
        "textEvidence": {
            "snippet": snippet.text,
            "snippetBytes": snippet.bytes,
            "maxSnippetBytes": max_snippet_bytes,
            "snippetTruncated": snippet.truncated,
            "storedTextBytes": source.pointer("/textEvidence/textBytes").cloned().unwrap_or(Value::Null),
            "storedMaxOutputBytes": source.pointer("/textEvidence/maxOutputBytes").cloned().unwrap_or(Value::Null),
            "storedOutputTextTruncated": source.pointer("/textEvidence/outputTextTruncated").cloned().unwrap_or(Value::Null),
            "extractedTextBytes": source.pointer("/textEvidence/extractedTextBytes").cloned().unwrap_or(Value::Null),
            "extractedTextTruncated": source.pointer("/textEvidence/extractedTextTruncated").cloned().unwrap_or(Value::Null),
            "binaryBodyOmitted": source.pointer("/textEvidence/binaryBodyOmitted").cloned().unwrap_or(Value::Null)
        },
        "extraction": extraction_metadata(source),
        "redaction": source.get("redaction").cloned().unwrap_or(Value::Null),
        "redirects": source.get("redirects").cloned().unwrap_or(Value::Null),
        "traceRefs": source.get("traceRefs").cloned().unwrap_or_else(|| json!([])),
        "replayRefs": source.get("replayRefs").cloned().unwrap_or_else(|| json!([])),
        "archive": source.get("archive").cloned().unwrap_or(Value::Null),
        "resourceRefs": [resource_ref(resource, version, "source")],
        "cache": source.get("cache").cloned().unwrap_or(Value::Null)
    })
}

fn extraction_metadata(source: &Value) -> Value {
    json!({
        "mode": source.pointer("/textEvidence/extractionMode").cloned().unwrap_or(Value::Null),
        "extractorId": source.pointer("/textEvidence/extractorId").cloned().unwrap_or(Value::Null),
        "extractorVersion": source.pointer("/textEvidence/extractorVersion").cloned().unwrap_or(Value::Null),
        "title": safe_source_title(source),
        "titleBytes": source.pointer("/textEvidence/titleBytes").cloned().unwrap_or(Value::Null),
        "maxTitleBytes": source.pointer("/textEvidence/maxTitleBytes").cloned().unwrap_or(Value::Null),
        "titleTruncated": source.pointer("/textEvidence/titleTruncated").cloned().unwrap_or(Value::Null),
        "extractedTextBytes": source.pointer("/textEvidence/extractedTextBytes").cloned().unwrap_or(Value::Null),
        "extractedTextTruncated": source.pointer("/textEvidence/extractedTextTruncated").cloned().unwrap_or(Value::Null)
    })
}

fn safe_source_title(source: &Value) -> Value {
    let max_bytes = source
        .pointer("/textEvidence/maxTitleBytes")
        .and_then(Value::as_u64)
        .map(|value| value as usize)
        .unwrap_or(MAX_TITLE_BYTES);
    safe_title(
        source
            .pointer("/textEvidence/title")
            .and_then(Value::as_str),
        max_bytes,
    )
    .text
    .map(Value::String)
    .unwrap_or(Value::Null)
}

fn truncation_metadata(source: &Value, snippet: &BoundedText, max_bytes: usize) -> Value {
    json!({
        "responseBytesTruncated": source.pointer("/byteEvidence/responseBytesTruncated").cloned().unwrap_or(Value::Null),
        "maxResponseBytes": source.pointer("/byteEvidence/maxResponseBytes").cloned().unwrap_or(Value::Null),
        "storedOutputTextTruncated": source.pointer("/textEvidence/outputTextTruncated").cloned().unwrap_or(Value::Null),
        "storedMaxOutputBytes": source.pointer("/textEvidence/maxOutputBytes").cloned().unwrap_or(Value::Null),
        "binaryBodyOmitted": source.pointer("/textEvidence/binaryBodyOmitted").cloned().unwrap_or(Value::Null),
        "snippetBytes": snippet.bytes,
        "maxPreviewBytes": max_bytes,
        "snippetTruncated": snippet.truncated
    })
}

fn ensure_web_source(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    if inspection.resource.kind != WEB_SOURCE_KIND {
        return Err(invalid(format!(
            "{operation} resource kind mismatch: expected {WEB_SOURCE_KIND}"
        )));
    }
    if inspection.resource.schema_id != WEB_SOURCE_SCHEMA_ID {
        return Err(invalid(format!(
            "{operation} resource schema mismatch: expected {WEB_SOURCE_SCHEMA_ID}"
        )));
    }
    Ok(())
}

fn ensure_scope(
    inspection: &EngineResourceInspection,
    expected: &EngineResourceScope,
    operation: &str,
) -> Result<(), CapabilityError> {
    if &inspection.resource.scope == expected {
        Ok(())
    } else {
        Err(invalid(format!(
            "{operation} cannot inspect a web_source outside the current session scope"
        )))
    }
}

fn resource_scope(invocation: &Invocation) -> EngineResourceScope {
    invocation
        .causal_context
        .session_id
        .as_ref()
        .map(|session| EngineResourceScope::Session(session.clone()))
        .or_else(|| {
            invocation
                .causal_context
                .workspace_id
                .as_ref()
                .map(|workspace| EngineResourceScope::Workspace(workspace.clone()))
        })
        .unwrap_or(EngineResourceScope::System)
}

fn scope_ref(scope: &EngineResourceScope) -> Value {
    json!({
        "kind": scope.kind(),
        "value": scope.value()
    })
}

fn resource_ref(resource: &EngineResource, version: &EngineResourceVersion, role: &str) -> Value {
    json!({
        "role": role,
        "kind": resource.kind,
        "resourceId": resource.resource_id,
        "versionId": version.version_id,
        "schemaId": resource.schema_id,
        "lifecycle": resource.lifecycle,
        "contentHash": version.content_hash
    })
}

struct BoundedText {
    text: String,
    bytes: usize,
    truncated: bool,
}

fn bounded_utf8(value: &str, max_bytes: usize) -> BoundedText {
    if value.len() <= max_bytes {
        return BoundedText {
            text: value.to_owned(),
            bytes: value.len(),
            truncated: false,
        };
    }
    let mut end = max_bytes;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    BoundedText {
        text: value[..end].to_owned(),
        bytes: end,
        truncated: true,
    }
}

fn validate_web_source_id(value: &str) -> Result<(), CapabilityError> {
    if !value.starts_with(WEB_SOURCE_ID_PREFIX) {
        return Err(invalid(format!(
            "webSourceResourceId must start with {WEB_SOURCE_ID_PREFIX}"
        )));
    }
    validate_token("webSourceResourceId", value, 180)
}

fn validate_version_id(value: &str) -> Result<(), CapabilityError> {
    validate_token("webSourceVersionId", value, 180)
}

fn validate_token(field: &str, value: &str, max_len: usize) -> Result<(), CapabilityError> {
    if value.is_empty()
        || value.len() > max_len
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b':' | b'-' | b'_' | b'.'))
    {
        return Err(invalid(format!("{field} is malformed")));
    }
    Ok(())
}

fn required_string(payload: &Value, field: &str) -> Result<String, CapabilityError> {
    optional_string(payload, field)?.ok_or_else(|| invalid(format!("{field} is required")))
}

fn optional_string(payload: &Value, field: &str) -> Result<Option<String>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) if !value.trim().is_empty() => Ok(Some(value.trim().to_owned())),
        Some(Value::String(_)) => Err(invalid(format!("{field} must not be empty"))),
        Some(_) => Err(invalid(format!("{field} must be a string"))),
    }
}

fn optional_u64(payload: &Value, field: &str) -> Result<Option<u64>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(value)) => value
            .as_u64()
            .map(Some)
            .ok_or_else(|| invalid(format!("{field} must be a positive integer"))),
        Some(_) => Err(invalid(format!("{field} must be a positive integer"))),
    }
}

fn optional_bool(payload: &Value, field: &str) -> Result<Option<bool>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(value)) => Ok(Some(*value)),
        Some(_) => Err(invalid(format!("{field} must be a boolean"))),
    }
}

fn engine_error(error: crate::engine::EngineError) -> CapabilityError {
    CapabilityError::Internal {
        message: error.to_string(),
    }
}

fn internal(message: impl Into<String>) -> CapabilityError {
    CapabilityError::Internal {
        message: message.into(),
    }
}

fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}
