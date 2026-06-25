//! Robots policy evidence, cache, and event helpers.

use futures::StreamExt;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use url::Url;

use crate::engine::{
    EngineResource, EngineResourceScope, Invocation, PublishStreamEvent, VisibilityScope,
    WEB_ROBOTS_POLICY_KIND,
};
use crate::shared::server::errors::CapabilityError;

use super::request::RobotsRequest;
use super::{WEB_ROBOTS_POLICY_SCHEMA_VERSION, engine_error, invalid};
use crate::domains::web::{Deps, WEB_LIFECYCLE_TOPIC, WORKER};

pub(super) async fn existing_robots_check(
    deps: &Deps,
    invocation: &Invocation,
    request: &RobotsRequest,
    robots_url: &Url,
) -> Result<Option<Value>, CapabilityError> {
    let resource_id = robots_resource_id(invocation, request, robots_url);
    let Some(inspection) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    else {
        return Ok(None);
    };
    if inspection.resource.kind != WEB_ROBOTS_POLICY_KIND {
        return Err(invalid(
            "web_robots_check idempotency resource kind mismatch",
        ));
    }
    if inspection.resource.scope != session_resource_scope(invocation)? {
        return Err(invalid(
            "web_robots_check idempotency resource is outside the current session scope",
        ));
    }
    Ok(Some(robots_result(&inspection.resource, 0, true, None)))
}

pub(super) struct BoundedBody {
    pub(super) bytes: Vec<u8>,
    pub(super) truncated: bool,
}

pub(super) async fn read_bounded_response(
    response: reqwest::Response,
    max_bytes: usize,
) -> Result<BoundedBody, CapabilityError> {
    let mut stream = response.bytes_stream();
    let mut bytes = Vec::new();
    let mut truncated = false;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|error| invalid(format!("read robots body: {error}")))?;
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

pub(super) fn robots_url_for(target: &Url) -> Url {
    let mut robots = target.clone();
    robots.set_path("/robots.txt");
    robots.set_query(None);
    robots.set_fragment(None);
    robots
}

pub(super) fn target_path(url: &Url) -> String {
    let mut path = url.path().to_owned();
    if path.is_empty() {
        path.push('/');
    }
    if let Some(query) = url.query() {
        path.push('?');
        path.push_str(query);
    }
    path
}

pub(super) fn origin_string(url: &Url) -> String {
    let host = url.host_str().unwrap_or_default();
    match url.port() {
        Some(port) => format!("{}://{}:{port}", url.scheme(), host),
        None => format!("{}://{}", url.scheme(), host),
    }
}

pub(super) fn robots_resource_id(
    invocation: &Invocation,
    request: &RobotsRequest,
    robots_url: &Url,
) -> String {
    let key = invocation
        .causal_context
        .idempotency_key
        .as_deref()
        .unwrap_or(&request.idempotency_key);
    let material = json!({
        "version": 1,
        "scope": {
            "kind": session_resource_scope(invocation).map(|scope| scope.kind().to_owned()).unwrap_or_default(),
            "value": session_resource_scope(invocation).map(|scope| scope.value().to_owned()).unwrap_or_default()
        },
        "idempotencyKey": key,
        "robotsUrl": sanitize_url_for_evidence(robots_url),
        "userAgent": request.user_agent
    });
    format!(
        "{WEB_ROBOTS_POLICY_KIND}:{}",
        sha256_hex(
            serde_json::to_string(&material)
                .unwrap_or_default()
                .as_bytes()
        )
    )
}

pub(super) fn robots_result(
    resource: &EngineResource,
    stream_cursor: u64,
    cache_hit: bool,
    extra: Option<Value>,
) -> Value {
    let mut value = json!({
        "schemaVersion": WEB_ROBOTS_POLICY_SCHEMA_VERSION,
        "status": "checked",
        "operation": "web_robots_check",
        "webRobotsPolicyResourceId": resource.resource_id,
        "webRobotsPolicyVersionId": resource.current_version_id,
        "streamCursor": stream_cursor,
        "cache": {
            "hit": cache_hit,
            "resourceId": resource.resource_id
        },
        "resourceRefs": [{
            "role": "robots_policy",
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

pub(super) async fn publish_robots_event(
    deps: &Deps,
    invocation: &Invocation,
    resource: &EngineResource,
) -> Result<crate::engine::StreamCursor, CapabilityError> {
    deps.engine_host
        .publish_stream_event(PublishStreamEvent {
            topic: WEB_LIFECYCLE_TOPIC.to_owned(),
            payload: json!({
                "type": "web.robots_checked",
                "authorityGrantId": invocation.causal_context.authority_grant_id.as_str(),
                "actorId": invocation.causal_context.actor_id.as_str(),
                "payload": {
                    "webRobotsPolicyResourceId": resource.resource_id,
                    "webRobotsPolicyVersionId": resource.current_version_id,
                    "resourceRefs": [{
                        "role": "robots_policy",
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

pub(super) fn session_resource_scope(
    invocation: &Invocation,
) -> Result<EngineResourceScope, CapabilityError> {
    invocation
        .causal_context
        .session_id
        .as_ref()
        .map(|session| EngineResourceScope::Session(session.clone()))
        .ok_or_else(|| invalid("web_robots_check requires trusted current session context"))
}

pub(super) fn trace_refs(invocation: &Invocation) -> Vec<Value> {
    vec![json!({
        "traceId": invocation.causal_context.trace_id.as_str(),
        "invocationId": invocation.id.as_str(),
        "functionId": invocation.function_id.as_str()
    })]
}

pub(super) fn replay_refs(invocation: &Invocation) -> Vec<Value> {
    vec![json!({
        "kind": "engine_invocation",
        "invocationId": invocation.id.as_str(),
        "traceId": invocation.causal_context.trace_id.as_str()
    })]
}

pub(super) fn sanitize_url_for_evidence(url: &Url) -> String {
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

pub(super) struct BoundedText {
    pub(super) text: String,
    pub(super) truncated: bool,
}

pub(super) fn bounded_utf8(value: &str, max_bytes: usize) -> BoundedText {
    if value.len() <= max_bytes {
        return BoundedText {
            text: value.to_owned(),
            truncated: false,
        };
    }
    let mut end = max_bytes;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    BoundedText {
        text: value[..end].to_owned(),
        truncated: true,
    }
}

pub(super) fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}
