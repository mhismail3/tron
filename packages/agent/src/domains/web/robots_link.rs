//! Fetch-side validation for linking robots-policy evidence to web sources.

use serde_json::{Value, json};
use url::Url;

use crate::engine::{
    EngineGrant, EngineResourceInspection, EngineResourceScope, EngineResourceVersion, Invocation,
    WEB_ROBOTS_POLICY_KIND, WEB_ROBOTS_POLICY_SCHEMA_ID, WEB_SOURCE_KIND,
};
use crate::shared::server::errors::CapabilityError;

use super::robots::WEB_ROBOTS_POLICY_SCHEMA_VERSION;
use super::{Deps, READ_SCOPE, WRITE_SCOPE};

const RESOURCE_READ_SCOPE: &str = "resource.read";
const RESOURCE_WRITE_SCOPE: &str = "resource.write";
const WEB_ROBOTS_POLICY_ID_PREFIX: &str = "web_robots_policy:";

pub(super) struct RobotsPolicyEvidenceRequest {
    pub(super) resource_id: String,
    pub(super) expected_version_id: String,
}

impl RobotsPolicyEvidenceRequest {
    pub(super) fn parse(payload: &Value) -> Result<Option<Self>, CapabilityError> {
        let resource_id = optional_string(payload, "webRobotsPolicyResourceId")?;
        let expected_version_id = optional_string(payload, "expectedWebRobotsPolicyVersionId")?;
        match (resource_id, expected_version_id) {
            (None, None) => Ok(None),
            (Some(resource_id), Some(expected_version_id)) => {
                let resource_id = resource_id.trim().to_owned();
                let expected_version_id = expected_version_id.trim().to_owned();
                validate_web_robots_policy_id(&resource_id)?;
                validate_version_id("expectedWebRobotsPolicyVersionId", &expected_version_id)?;
                Ok(Some(Self {
                    resource_id,
                    expected_version_id,
                }))
            }
            _ => Err(invalid(
                "web_fetch requires webRobotsPolicyResourceId and expectedWebRobotsPolicyVersionId together",
            )),
        }
    }
}

pub(super) async fn inspect_fetch_grant(
    deps: &Deps,
    invocation: &Invocation,
    robots_policy: Option<&RobotsPolicyEvidenceRequest>,
) -> Result<EngineGrant, CapabilityError> {
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
    for (items, required, label) in [
        (
            &grant.allowed_authority_scopes,
            WRITE_SCOPE,
            "authority scope",
        ),
        (
            &grant.allowed_authority_scopes,
            RESOURCE_WRITE_SCOPE,
            "authority scope",
        ),
        (
            &grant.allowed_resource_kinds,
            WEB_SOURCE_KIND,
            "resource kind",
        ),
    ] {
        require_grant_item(items, required, label, "web_fetch")?;
    }
    require_grant_selector(&grant, WEB_SOURCE_KIND, "web_fetch")?;
    if robots_policy.is_some() {
        for (items, required, label) in [
            (
                &grant.allowed_authority_scopes,
                READ_SCOPE,
                "authority scope",
            ),
            (
                &grant.allowed_authority_scopes,
                RESOURCE_READ_SCOPE,
                "authority scope",
            ),
            (
                &grant.allowed_resource_kinds,
                WEB_ROBOTS_POLICY_KIND,
                "resource kind",
            ),
        ] {
            require_grant_item(items, required, label, "web_fetch")?;
        }
        require_grant_selector(&grant, WEB_ROBOTS_POLICY_KIND, "web_fetch")?;
    }
    Ok(grant)
}

pub(super) struct RobotsPolicyEvidenceRef {
    resource_id: String,
    version_id: String,
    schema_id: String,
    lifecycle: String,
    content_hash: String,
    origin: String,
    target_url: String,
    decision: String,
}

pub(super) async fn validate_fetch_robots_policy(
    deps: &Deps,
    invocation: &Invocation,
    request: &RobotsPolicyEvidenceRequest,
    requested_url: &Url,
) -> Result<RobotsPolicyEvidenceRef, CapabilityError> {
    let inspection = deps
        .engine_host
        .inspect_resource(&request.resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid("web_fetch webRobotsPolicyResourceId was not found"))?;
    ensure_web_robots_policy(&inspection)?;
    ensure_robots_scope(&inspection, invocation)?;
    let (version, policy) = current_robots_policy(&inspection)?;
    if !inspection
        .versions
        .iter()
        .any(|version| version.version_id == request.expected_version_id)
    {
        return Err(invalid(
            "web_fetch expectedWebRobotsPolicyVersionId was not found for this resource",
        ));
    }
    if version.version_id != request.expected_version_id {
        return Err(invalid(
            "web_fetch expectedWebRobotsPolicyVersionId is stale; re-run web_robots_check",
        ));
    }
    let schema_version = required_payload_string(policy, "/schemaVersion")?;
    if schema_version != WEB_ROBOTS_POLICY_SCHEMA_VERSION {
        return Err(invalid(
            "web_fetch web_robots_policy schemaVersion mismatch",
        ));
    }
    if required_payload_string(policy, "/operation")? != "web_robots_check" {
        return Err(invalid("web_fetch web_robots_policy operation mismatch"));
    }
    if required_payload_string(policy, "/state")? != "checked" {
        return Err(invalid("web_fetch web_robots_policy is not checked"));
    }
    let origin = required_payload_string(policy, "/origin")?.to_owned();
    let target_url = required_payload_string(policy, "/targetUrl")?.to_owned();
    let decision = required_payload_string(policy, "/policy/decision")?.to_owned();
    if decision != "allow" {
        return Err(invalid(
            "web_fetch requires web_robots_policy decision allow",
        ));
    }
    let requested_origin = origin_string(requested_url);
    if origin != requested_origin {
        return Err(invalid(
            "web_fetch web_robots_policy origin does not match requested URL",
        ));
    }
    let requested_target = sanitize_url_for_evidence(requested_url);
    if target_url != requested_target {
        return Err(invalid(
            "web_fetch web_robots_policy targetUrl does not match requested URL",
        ));
    }
    Ok(RobotsPolicyEvidenceRef {
        resource_id: inspection.resource.resource_id.clone(),
        version_id: version.version_id.clone(),
        schema_id: inspection.resource.schema_id.clone(),
        lifecycle: inspection.resource.lifecycle.clone(),
        content_hash: version.content_hash.clone(),
        origin,
        target_url,
        decision,
    })
}

pub(super) fn robots_policy_refs_value(reference: Option<&RobotsPolicyEvidenceRef>) -> Value {
    match reference {
        Some(reference) => json!([robots_policy_ref_value(reference)]),
        None => json!([]),
    }
}

pub(super) fn fetch_result_extra(reference: Option<&RobotsPolicyEvidenceRef>) -> Option<Value> {
    reference.map(|reference| {
        json!({
            "robotsPolicyRefs": robots_policy_refs_value(Some(reference))
        })
    })
}

fn ensure_web_robots_policy(inspection: &EngineResourceInspection) -> Result<(), CapabilityError> {
    if inspection.resource.kind != WEB_ROBOTS_POLICY_KIND {
        return Err(invalid(format!(
            "web_fetch resource kind mismatch: expected {WEB_ROBOTS_POLICY_KIND}"
        )));
    }
    if inspection.resource.schema_id != WEB_ROBOTS_POLICY_SCHEMA_ID {
        return Err(invalid(format!(
            "web_fetch resource schema mismatch: expected {WEB_ROBOTS_POLICY_SCHEMA_ID}"
        )));
    }
    if inspection.resource.lifecycle != "checked" {
        return Err(invalid(
            "web_fetch web_robots_policy resource is not checked",
        ));
    }
    Ok(())
}

fn ensure_robots_scope(
    inspection: &EngineResourceInspection,
    invocation: &Invocation,
) -> Result<(), CapabilityError> {
    let expected = session_resource_scope(invocation)?;
    if inspection.resource.scope == expected {
        Ok(())
    } else {
        Err(invalid(
            "web_fetch cannot use web_robots_policy outside the current session scope",
        ))
    }
}

fn current_robots_policy<'a>(
    inspection: &'a EngineResourceInspection,
) -> Result<(&'a EngineResourceVersion, &'a Value), CapabilityError> {
    let current = inspection
        .resource
        .current_version_id
        .as_deref()
        .ok_or_else(|| invalid("web_fetch web_robots_policy has no current version"))?;
    let version = inspection
        .versions
        .iter()
        .find(|version| version.version_id == current)
        .ok_or_else(|| invalid("web_fetch web_robots_policy current version is missing"))?;
    if !version.state.may_be_current() {
        return Err(invalid(
            "web_fetch web_robots_policy current version is not available",
        ));
    }
    Ok((version, &version.payload))
}

fn required_payload_string<'a>(
    payload: &'a Value,
    pointer: &str,
) -> Result<&'a str, CapabilityError> {
    payload
        .pointer(pointer)
        .and_then(Value::as_str)
        .ok_or_else(|| {
            invalid(format!(
                "web_fetch web_robots_policy payload missing string field {pointer}"
            ))
        })
}

fn robots_policy_ref_value(reference: &RobotsPolicyEvidenceRef) -> Value {
    json!({
        "role": "robots_policy",
        "kind": WEB_ROBOTS_POLICY_KIND,
        "resourceId": reference.resource_id,
        "versionId": reference.version_id,
        "schemaId": reference.schema_id,
        "lifecycle": reference.lifecycle,
        "contentHash": reference.content_hash,
        "origin": reference.origin,
        "targetUrl": reference.target_url,
        "decision": reference.decision
    })
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

fn require_grant_selector(
    grant: &EngineGrant,
    kind: &str,
    operation: &str,
) -> Result<(), CapabilityError> {
    if allows_item(&grant.resource_selectors, "*")
        || allows_item(&grant.resource_selectors, &format!("kind:{kind}"))
    {
        Ok(())
    } else {
        Err(invalid(format!(
            "{operation} requires a grant selector for kind:{kind}"
        )))
    }
}

fn allows_item(items: &[String], required: &str) -> bool {
    items.iter().any(|item| item == "*" || item == required)
}

fn session_resource_scope(invocation: &Invocation) -> Result<EngineResourceScope, CapabilityError> {
    invocation
        .causal_context
        .session_id
        .as_ref()
        .map(|session| EngineResourceScope::Session(session.clone()))
        .ok_or_else(|| invalid("web_fetch requires trusted current session context"))
}

fn origin_string(url: &Url) -> String {
    let host = url.host_str().unwrap_or_default();
    match url.port() {
        Some(port) => format!("{}://{}:{port}", url.scheme(), host),
        None => format!("{}://{}", url.scheme(), host),
    }
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

fn validate_web_robots_policy_id(value: &str) -> Result<(), CapabilityError> {
    if !value.starts_with(WEB_ROBOTS_POLICY_ID_PREFIX) {
        return Err(invalid(format!(
            "webRobotsPolicyResourceId must start with {WEB_ROBOTS_POLICY_ID_PREFIX}"
        )));
    }
    validate_token("webRobotsPolicyResourceId", value, 220)
}

fn validate_version_id(field: &str, value: &str) -> Result<(), CapabilityError> {
    validate_token(field, value, 180)
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

fn optional_string(payload: &Value, field: &str) -> Result<Option<String>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Ok(Some(value.clone())),
        Some(_) => Err(invalid(format!("{field} must be a string"))),
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
