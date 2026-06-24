//! Direct web fetch implementation for source provenance evidence.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use chrono::Utc;
use futures::StreamExt;
use regex::Regex;
use reqwest::redirect::{Attempt, Policy};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use url::Url;

use crate::engine::{
    CreateResource, EngineResource, EngineResourceScope, Invocation, PublishStreamEvent,
    VisibilityScope, WEB_SOURCE_KIND, WEB_SOURCE_SCHEMA_ID, WorkerId,
};
use crate::shared::server::errors::CapabilityError;

use super::network_policy::{
    SafeDnsResolver, validate_final_url, validate_redirect_target, validate_url,
};
use super::{Deps, WEB_LIFECYCLE_TOPIC, WEB_SOURCE_SCHEMA_VERSION, WORKER, WRITE_SCOPE};

const MAX_URL_BYTES: usize = 2_048;
const DEFAULT_TIMEOUT_MS: u64 = 10_000;
const MAX_TIMEOUT_MS: u64 = 30_000;
const DEFAULT_RESPONSE_BYTES: usize = 262_144;
const MAX_RESPONSE_BYTES: usize = 1_048_576;
const DEFAULT_OUTPUT_BYTES: usize = 20_000;
const MAX_OUTPUT_BYTES: usize = 100_000;
const DEFAULT_REDIRECTS: usize = 5;
const MAX_REDIRECTS: usize = 10;

pub(crate) async fn web_fetch_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let grant = inspect_fetch_grant(deps, invocation).await?;
    let request = FetchRequest::parse(payload)?;
    let parsed = validate_url(&request.url)?;
    if let Some(existing) = existing_fetch(deps, invocation, &request).await? {
        return Ok(existing);
    }

    let now = Utc::now();
    let redirect_count = Arc::new(AtomicUsize::new(0));
    let redirect_limit = request.max_redirects;
    let redirect_count_for_policy = Arc::clone(&redirect_count);
    let client = reqwest::Client::builder()
        .redirect(Policy::custom(move |attempt: Attempt<'_>| {
            let next_count = attempt.previous().len().saturating_add(1);
            redirect_count_for_policy.store(next_count, Ordering::SeqCst);
            if attempt.previous().len() >= redirect_limit {
                attempt.stop()
            } else if validate_redirect_target(attempt.url(), attempt.previous()).is_err() {
                attempt.error("web_fetch redirect target rejected by URL policy")
            } else {
                attempt.follow()
            }
        }))
        .dns_resolver(Arc::new(SafeDnsResolver::from_deps(deps)))
        .timeout(Duration::from_millis(request.timeout_ms))
        .user_agent("tron-web-fetch/0.1 source-provenance")
        .no_proxy()
        .build()
        .map_err(|error| internal(format!("build web fetch client: {error}")))?;

    let response = client
        .get(parsed.url.clone())
        .send()
        .await
        .map_err(|error| {
            invalid(format!(
                "web_fetch request failed: {}",
                redact_error(&error)
            ))
        })?;
    let status = response.status().as_u16();
    let final_url = response.url().clone();
    validate_final_url(&final_url)?;
    let content_type = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .map(ToOwned::to_owned);
    let textual = is_textual_content_type(content_type.as_deref());
    let body = read_bounded_response(response, request.max_response_bytes).await?;
    let response_truncated = body.truncated;
    let captured_sha256 = sha256_hex(&body.bytes);
    let byte_count = body.bytes.len();
    let raw_text = if textual {
        String::from_utf8_lossy(&body.bytes).into_owned()
    } else {
        String::new()
    };
    let (bounded_text, output_truncated) = truncate_utf8(&raw_text, request.max_output_bytes);
    let redacted = redact_text(&bounded_text);
    let source_resource_id = source_resource_id(invocation, &request);
    let record = json!({
        "schemaVersion": WEB_SOURCE_SCHEMA_VERSION,
        "operation": "web_fetch",
        "state": "fetched",
        "requestedUrl": sanitize_url_for_evidence(&parsed.url),
        "finalUrl": sanitize_url_for_evidence(&final_url),
        "fetchedAt": now.to_rfc3339(),
        "status": status,
        "contentType": content_type,
        "byteEvidence": {
            "capturedBytes": byte_count,
            "maxResponseBytes": request.max_response_bytes,
            "responseBytesTruncated": response_truncated,
            "sha256": captured_sha256,
            "hashScope": "captured_response_bytes"
        },
        "textEvidence": {
            "preview": redacted.text,
            "textBytes": bounded_text.len(),
            "maxOutputBytes": request.max_output_bytes,
            "outputTextTruncated": output_truncated,
            "binaryBodyOmitted": !textual
        },
        "redaction": {
            "applied": redacted.count > 0,
            "replacementCount": redacted.count,
            "policy": "common_token_key_password_patterns"
        },
        "redirects": {
            "maxRedirects": request.max_redirects,
            "observedRedirects": redirect_count.load(Ordering::SeqCst),
            "finalUrlChanged": sanitize_url_for_evidence(&parsed.url) != sanitize_url_for_evidence(&final_url)
        },
        "authority": {
            "actorId": invocation.causal_context.actor_id.as_str(),
            "authorityGrantId": invocation.causal_context.authority_grant_id.as_str(),
            "networkPolicy": grant.network_policy,
            "authorityScopes": invocation.causal_context.authority_scopes,
            "noCredentialsCookiesBrowserOrShell": true
        },
        "traceRefs": trace_refs(invocation),
        "replayRefs": replay_refs(invocation),
        "cache": {
            "cacheKey": source_resource_id,
            "idempotencyScoped": true,
            "cacheHit": false
        },
        "idempotency": {
            "key": request.idempotency_key,
            "invocationId": invocation.id.as_str(),
            "functionId": invocation.function_id.as_str()
        },
        "revision": 1
    });
    let resource = deps
        .engine_host
        .create_resource(CreateResource {
            resource_id: Some(source_resource_id),
            kind: WEB_SOURCE_KIND.to_owned(),
            schema_id: Some(WEB_SOURCE_SCHEMA_ID.to_owned()),
            scope: resource_scope(invocation),
            owner_worker_id: WorkerId::new(WORKER).map_err(engine_error)?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("fetched".to_owned()),
            policy: json!({
                "owner": WORKER,
                "kind": "web_source",
                "authority": WRITE_SCOPE,
                "retention": "source_provenance",
                "redaction": "bounded_redacted_text_only"
            }),
            initial_payload: Some(record),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let cursor = publish_fetch_event(deps, invocation, &resource).await?;
    Ok(fetch_result(&resource, cursor.0, false, None))
}

struct FetchRequest {
    url: String,
    timeout_ms: u64,
    max_response_bytes: usize,
    max_output_bytes: usize,
    max_redirects: usize,
    idempotency_key: String,
}

impl FetchRequest {
    fn parse(payload: &Value) -> Result<Self, CapabilityError> {
        let url = required_string(payload, "url")?;
        if url.len() > MAX_URL_BYTES {
            return Err(invalid(format!(
                "url exceeds {MAX_URL_BYTES} bytes and cannot be fetched"
            )));
        }
        Ok(Self {
            url,
            timeout_ms: optional_u64(payload, "timeoutMs")?
                .unwrap_or(DEFAULT_TIMEOUT_MS)
                .clamp(1, MAX_TIMEOUT_MS),
            max_response_bytes: optional_u64(payload, "maxResponseBytes")?
                .map(|value| value as usize)
                .unwrap_or(DEFAULT_RESPONSE_BYTES)
                .clamp(1, MAX_RESPONSE_BYTES),
            max_output_bytes: optional_u64(payload, "maxOutputBytes")?
                .map(|value| value as usize)
                .unwrap_or(DEFAULT_OUTPUT_BYTES)
                .clamp(1, MAX_OUTPUT_BYTES),
            max_redirects: optional_u64(payload, "maxRedirects")?
                .map(|value| value as usize)
                .unwrap_or(DEFAULT_REDIRECTS)
                .clamp(0, MAX_REDIRECTS),
            idempotency_key: optional_string(payload, "idempotencyKey")?
                .unwrap_or_else(|| "<context>".to_owned()),
        })
    }
}

async fn inspect_fetch_grant(
    deps: &Deps,
    invocation: &Invocation,
) -> Result<crate::engine::EngineGrant, CapabilityError> {
    let grant = deps
        .engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .map_err(|error| internal(format!("inspect web fetch authority grant: {error}")))?
        .ok_or_else(|| invalid("web_fetch authority grant was not found"))?;
    if grant.network_policy != "declared" {
        return Err(invalid(
            "web_fetch requires an authority grant with networkPolicy declared",
        ));
    }
    Ok(grant)
}

struct BoundedBody {
    bytes: Vec<u8>,
    truncated: bool,
}

async fn read_bounded_response(
    response: reqwest::Response,
    max_bytes: usize,
) -> Result<BoundedBody, CapabilityError> {
    let mut stream = response.bytes_stream();
    let mut bytes = Vec::new();
    let mut truncated = false;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|error| invalid(format!("read response body: {error}")))?;
        let remaining = max_bytes.saturating_sub(bytes.len());
        if chunk.len() > remaining {
            bytes.extend_from_slice(&chunk[..remaining]);
            truncated = true;
            break;
        }
        bytes.extend_from_slice(&chunk);
        if bytes.len() == max_bytes {
            truncated = true;
            break;
        }
    }
    Ok(BoundedBody { bytes, truncated })
}

fn is_textual_content_type(content_type: Option<&str>) -> bool {
    let Some(content_type) = content_type else {
        return true;
    };
    let lower = content_type.to_ascii_lowercase();
    lower.starts_with("text/")
        || lower.contains("json")
        || lower.contains("xml")
        || lower.contains("javascript")
        || lower.contains("x-www-form-urlencoded")
}

fn truncate_utf8(value: &str, max_bytes: usize) -> (String, bool) {
    if value.len() <= max_bytes {
        return (value.to_owned(), false);
    }
    let mut end = max_bytes;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    (value[..end].to_owned(), true)
}

struct RedactedText {
    text: String,
    count: usize,
}

fn redact_text(value: &str) -> RedactedText {
    let secret_value = Regex::new("(?i)(sk-[A-Za-z0-9_-]{8,}|Bearer\\s+[A-Za-z0-9._~+/=-]{8,})")
        .expect("static redaction regex");
    let key_value =
        Regex::new("(?i)((?:api[_-]?key|token|secret|password)\\s*[:=]\\s*)[^\\s'\\\"<>&]{4,}")
            .expect("static redaction regex");
    let mut count = secret_value.find_iter(value).count();
    let first = secret_value
        .replace_all(value, "<redacted-secret>")
        .into_owned();
    count += key_value.find_iter(&first).count();
    let text = key_value
        .replace_all(&first, "${1}<redacted-secret>")
        .into_owned();
    RedactedText { text, count }
}

fn sanitize_url_for_evidence(url: &Url) -> String {
    let mut sanitized = url.clone();
    let sensitive = ["key", "token", "secret", "password", "api_key", "apikey"];
    if sanitized.query().is_some() {
        let pairs = sanitized
            .query_pairs()
            .map(|(key, value)| {
                if sensitive
                    .iter()
                    .any(|needle| key.to_ascii_lowercase().contains(needle))
                {
                    (key.into_owned(), "<redacted>".to_owned())
                } else {
                    (key.into_owned(), value.into_owned())
                }
            })
            .collect::<Vec<_>>();
        sanitized.set_query(None);
        {
            let mut serializer = sanitized.query_pairs_mut();
            for (key, value) in pairs {
                serializer.append_pair(&key, &value);
            }
        }
    }
    sanitized.to_string()
}

fn source_resource_id(invocation: &Invocation, request: &FetchRequest) -> String {
    let key = invocation
        .causal_context
        .idempotency_key
        .as_deref()
        .unwrap_or(&request.idempotency_key);
    let material = json!({
        "version": 1,
        "scope": {
            "kind": resource_scope(invocation).kind(),
            "value": resource_scope(invocation).value()
        },
        "idempotencyKey": key
    });
    format!(
        "{WEB_SOURCE_KIND}:{}",
        sha256_hex(
            serde_json::to_string(&material)
                .unwrap_or_default()
                .as_bytes()
        )
    )
}

async fn existing_fetch(
    deps: &Deps,
    invocation: &Invocation,
    request: &FetchRequest,
) -> Result<Option<Value>, CapabilityError> {
    let resource_id = source_resource_id(invocation, request);
    let Some(inspection) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    else {
        return Ok(None);
    };
    if inspection.resource.kind != WEB_SOURCE_KIND {
        return Err(invalid("web_fetch idempotency resource kind mismatch"));
    }
    Ok(Some(fetch_result(&inspection.resource, 0, true, None)))
}

fn fetch_result(
    resource: &EngineResource,
    stream_cursor: u64,
    cache_hit: bool,
    extra: Option<Value>,
) -> Value {
    let mut value = json!({
        "schemaVersion": WEB_SOURCE_SCHEMA_VERSION,
        "status": "fetched",
        "operation": "web_fetch",
        "webSourceResourceId": resource.resource_id,
        "webSourceVersionId": resource.current_version_id,
        "streamCursor": stream_cursor,
        "cache": {
            "hit": cache_hit,
            "resourceId": resource.resource_id
        },
        "resourceRefs": [{
            "role": "source",
            "kind": resource.kind,
            "resourceId": resource.resource_id,
            "versionId": resource.current_version_id,
            "schemaId": resource.schema_id,
            "lifecycle": resource.lifecycle
        }]
    });
    if let Some(Value::Object(extra)) = extra {
        if let Value::Object(ref mut object) = value {
            object.extend(extra);
        }
    }
    value
}

async fn publish_fetch_event(
    deps: &Deps,
    invocation: &Invocation,
    resource: &EngineResource,
) -> Result<crate::engine::StreamCursor, CapabilityError> {
    deps.engine_host
        .publish_stream_event(PublishStreamEvent {
            topic: WEB_LIFECYCLE_TOPIC.to_owned(),
            payload: json!({
                "type": "web.fetched",
                "authorityGrantId": invocation.causal_context.authority_grant_id.as_str(),
                "actorId": invocation.causal_context.actor_id.as_str(),
                "payload": {
                    "webSourceResourceId": resource.resource_id,
                    "webSourceVersionId": resource.current_version_id,
                    "resourceRefs": [{
                        "role": "source",
                        "kind": resource.kind,
                        "resourceId": resource.resource_id,
                        "versionId": resource.current_version_id,
                        "schemaId": resource.schema_id,
                        "lifecycle": resource.lifecycle
                    }]
                }
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

fn trace_refs(invocation: &Invocation) -> Vec<Value> {
    vec![json!({
        "traceId": invocation.causal_context.trace_id.as_str(),
        "invocationId": invocation.id.as_str(),
        "functionId": invocation.function_id.as_str()
    })]
}

fn replay_refs(invocation: &Invocation) -> Vec<Value> {
    vec![json!({
        "kind": "engine_invocation",
        "invocationId": invocation.id.as_str(),
        "traceId": invocation.causal_context.trace_id.as_str()
    })]
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

fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}

fn redact_error(error: &reqwest::Error) -> String {
    if error.is_timeout() {
        "request timed out".to_owned()
    } else if error.is_redirect() {
        "redirect policy rejected the request".to_owned()
    } else if error.is_connect() {
        "connection failed".to_owned()
    } else if error.is_body() {
        "response body read failed".to_owned()
    } else {
        "request failed".to_owned()
    }
}

fn required_string(payload: &Value, field: &str) -> Result<String, CapabilityError> {
    match payload.get(field) {
        Some(Value::String(value)) if !value.trim().is_empty() => Ok(value.trim().to_owned()),
        Some(Value::String(_)) => Err(invalid(format!("{field} must not be empty"))),
        Some(_) => Err(invalid(format!("{field} must be a string"))),
        None => Err(invalid(format!("{field} is required"))),
    }
}

fn optional_string(payload: &Value, field: &str) -> Result<Option<String>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Ok(Some(value.clone())),
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
