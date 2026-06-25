//! Robots policy check and evidence capture.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use chrono::Utc;
use reqwest::redirect::{Attempt, Policy};
use serde_json::{Value, json};
use url::{Host, Url};

use crate::engine::{
    CreateResource, EngineGrant, Invocation, WEB_ROBOTS_POLICY_KIND, WEB_ROBOTS_POLICY_SCHEMA_ID,
    WorkerId,
};
use crate::shared::server::errors::CapabilityError;

use super::fetch::redact_text;
use super::network_policy::{validate_final_url, validate_redirect_target, validate_url};
use super::{Deps, WORKER, WRITE_SCOPE};

mod evidence;
mod parser;
mod request;

use evidence::{
    bounded_utf8, existing_robots_check, origin_string, publish_robots_event,
    read_bounded_response, replay_refs, robots_resource_id, robots_result, robots_url_for,
    sanitize_url_for_evidence, session_resource_scope, sha256_hex, target_path, trace_refs,
};
use parser::{decision_for_status, parse_robots};
use request::RobotsRequest;

pub(crate) const WEB_ROBOTS_POLICY_SCHEMA_VERSION: &str = "tron.web_robots_policy.v1";
const RESOURCE_WRITE_SCOPE: &str = "resource.write";
const RESOURCE_READ_SCOPE: &str = "resource.read";
const PARSER_ID: &str = "tron.web.robots";
const PARSER_VERSION: &str = "1";

pub(crate) async fn web_robots_check_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let grant = inspect_robots_grant(deps, invocation).await?;
    let request = RobotsRequest::parse(payload)?;
    let target = validate_robots_url(deps, &request.url)?;
    let robots_url = robots_url_for(&target.url);
    validate_robots_url(deps, robots_url.as_str())?;
    if let Some(existing) = existing_robots_check(deps, invocation, &request, &robots_url).await? {
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
                attempt.error("web_robots_check redirect target rejected by URL policy")
            } else {
                attempt.follow()
            }
        }))
        .dns_resolver(Arc::new(super::network_policy::SafeDnsResolver::from_deps(
            deps,
        )))
        .timeout(Duration::from_millis(request.timeout_ms))
        .user_agent("tron-web-robots/0.1 policy-evidence")
        .no_proxy()
        .build()
        .map_err(|error| internal(format!("build web robots client: {error}")))?;

    let response = client
        .get(robots_url.clone())
        .send()
        .await
        .map_err(|error| {
            invalid(format!(
                "web_robots_check request failed: {}",
                redact_error(&error)
            ))
        })?;
    let status = response.status().as_u16();
    let final_robots_url = response.url().clone();
    validate_final_url(&final_robots_url)?;
    let body = read_bounded_response(response, request.max_robots_bytes).await?;
    let captured_sha256 = sha256_hex(&body.bytes);
    let parse_input = String::from_utf8_lossy(&body.bytes);
    let malformed_utf8 = matches!(parse_input, std::borrow::Cow::Owned(_));
    let parsed = parse_robots(&parse_input, &request.user_agent, target_path(&target.url));
    let missing = matches!(status, 404 | 410);
    let decision = decision_for_status(status, missing, body.truncated, &parsed);
    let bounded_body = bounded_utf8(&parse_input, request.max_output_bytes);
    let redacted_body = redact_text(&bounded_body.text);
    let robots_resource_id = robots_resource_id(invocation, &request, &robots_url);
    let record = json!({
        "schemaVersion": WEB_ROBOTS_POLICY_SCHEMA_VERSION,
        "operation": "web_robots_check",
        "state": "checked",
        "origin": origin_string(&target.url),
        "targetUrl": sanitize_url_for_evidence(&target.url),
        "robotsUrl": sanitize_url_for_evidence(&robots_url),
        "finalRobotsUrl": sanitize_url_for_evidence(&final_robots_url),
        "fetchedAt": now.to_rfc3339(),
        "status": status,
        "missing": missing,
        "bodyEvidence": {
            "capturedBytes": body.bytes.len(),
            "maxRobotsBytes": request.max_robots_bytes,
            "robotsBytesTruncated": body.truncated,
            "sha256": captured_sha256,
            "hashScope": "captured_robots_txt_bytes",
            "storedPreviewBytes": redacted_body.text.len(),
            "maxOutputBytes": request.max_output_bytes,
            "previewTruncated": bounded_body.truncated,
            "malformedUtf8": malformed_utf8
        },
        "parser": {
            "id": PARSER_ID,
            "version": PARSER_VERSION,
            "tolerantMalformedBody": true
        },
        "policy": {
            "matchedUserAgent": parsed.matched_user_agent,
            "requestedUserAgent": request.user_agent,
            "decision": decision.decision,
            "reason": decision.reason,
            "relevantMatchedRule": decision.rule
        },
        "sitemaps": {
            "refs": parsed.sitemaps,
            "metadataOnly": true,
            "truncated": parsed.sitemaps_truncated,
            "traversed": false
        },
        "boundedBody": {
            "preview": redacted_body.text,
            "redaction": {
                "applied": redacted_body.count > 0,
                "replacementCount": redacted_body.count,
                "policy": "common_token_key_password_patterns"
            }
        },
        "redirects": {
            "maxRedirects": request.max_redirects,
            "observedRedirects": redirect_count.load(Ordering::SeqCst),
            "finalUrlChanged": sanitize_url_for_evidence(&robots_url) != sanitize_url_for_evidence(&final_robots_url)
        },
        "authority": {
            "actorId": invocation.causal_context.actor_id.as_str(),
            "authorityGrantId": invocation.causal_context.authority_grant_id.as_str(),
            "networkPolicy": grant.network_policy,
            "authorityScopes": invocation.causal_context.authority_scopes,
            "resourceKind": WEB_ROBOTS_POLICY_KIND,
            "noSearchCrawlBrowserLoginCookiesOrSitemapTraversal": true
        },
        "traceRefs": trace_refs(invocation),
        "replayRefs": replay_refs(invocation),
        "cache": {
            "cacheKey": robots_resource_id,
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
            resource_id: Some(robots_resource_id),
            kind: WEB_ROBOTS_POLICY_KIND.to_owned(),
            schema_id: Some(WEB_ROBOTS_POLICY_SCHEMA_ID.to_owned()),
            scope: session_resource_scope(invocation)?,
            owner_worker_id: WorkerId::new(WORKER).map_err(engine_error)?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("checked".to_owned()),
            policy: json!({
                "owner": WORKER,
                "kind": WEB_ROBOTS_POLICY_KIND,
                "authority": WRITE_SCOPE,
                "retention": "robots_policy_evidence",
                "sitemaps": "metadata_only_no_traversal"
            }),
            initial_payload: Some(record),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let cursor = publish_robots_event(deps, invocation, &resource).await?;
    Ok(robots_result(&resource, cursor.0, false, None))
}

async fn inspect_robots_grant(
    deps: &Deps,
    invocation: &Invocation,
) -> Result<EngineGrant, CapabilityError> {
    let grant = deps
        .engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .map_err(|error| internal(format!("inspect web robots authority grant: {error}")))?
        .ok_or_else(|| invalid("web_robots_check authority grant was not found"))?;
    if grant.network_policy != "declared" {
        return Err(invalid(
            "web_robots_check requires an authority grant with networkPolicy declared",
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
            RESOURCE_READ_SCOPE,
            "authority scope",
        ),
        (
            &grant.allowed_authority_scopes,
            RESOURCE_WRITE_SCOPE,
            "authority scope",
        ),
        (
            &grant.allowed_resource_kinds,
            WEB_ROBOTS_POLICY_KIND,
            "resource kind",
        ),
    ] {
        require_grant_item(items, required, label)?;
    }
    if !allows_item(&grant.resource_selectors, "*")
        && !allows_item(
            &grant.resource_selectors,
            &format!("kind:{WEB_ROBOTS_POLICY_KIND}"),
        )
    {
        return Err(invalid(format!(
            "web_robots_check requires a grant selector for kind:{WEB_ROBOTS_POLICY_KIND}"
        )));
    }
    Ok(grant)
}

fn require_grant_item(
    items: &[String],
    required: &str,
    label: &str,
) -> Result<(), CapabilityError> {
    if allows_item(items, required) {
        Ok(())
    } else {
        Err(invalid(format!(
            "web_robots_check requires {label} {required}"
        )))
    }
}

fn allows_item(items: &[String], required: &str) -> bool {
    items.iter().any(|item| item == "*" || item == required)
}

fn validate_robots_url(
    deps: &Deps,
    value: &str,
) -> Result<super::network_policy::ValidatedUrl, CapabilityError> {
    let validated = validate_url(value)?;
    if validated.url.scheme() == "http" && !allow_test_http_loopback_for_robots(deps) {
        return Err(invalid(
            "web_robots_check requires https URLs; http loopback is test-only",
        ));
    }
    if validated.url.scheme() == "http" && !is_http_loopback_ip(&validated.url) {
        return Err(invalid(
            "web_robots_check supports test http only for loopback IP targets",
        ));
    }
    Ok(validated)
}

fn is_http_loopback_ip(url: &Url) -> bool {
    match url.host() {
        Some(Host::Ipv4(addr)) => addr.is_loopback(),
        Some(Host::Ipv6(addr)) => addr.is_loopback(),
        _ => false,
    }
}

#[cfg(test)]
fn allow_test_http_loopback_for_robots(deps: &Deps) -> bool {
    deps.allow_test_http_loopback_for_robots
}

#[cfg(not(test))]
fn allow_test_http_loopback_for_robots(_deps: &Deps) -> bool {
    false
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

pub(super) fn engine_error(error: crate::engine::EngineError) -> CapabilityError {
    CapabilityError::Internal {
        message: error.to_string(),
    }
}

pub(super) fn internal(message: impl Into<String>) -> CapabilityError {
    CapabilityError::Internal {
        message: message.into(),
    }
}

pub(super) fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}
