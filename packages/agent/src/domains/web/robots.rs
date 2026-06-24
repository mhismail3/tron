//! Robots policy check and evidence capture.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use chrono::Utc;
use futures::StreamExt;
use reqwest::redirect::{Attempt, Policy};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use url::Url;

use crate::engine::{
    CreateResource, EngineGrant, EngineResource, EngineResourceScope, Invocation,
    PublishStreamEvent, VisibilityScope, WEB_ROBOTS_POLICY_KIND, WEB_ROBOTS_POLICY_SCHEMA_ID,
    WorkerId,
};
use crate::shared::server::errors::CapabilityError;

use super::fetch::redact_text;
use super::network_policy::{validate_final_url, validate_redirect_target, validate_url};
use super::{Deps, WEB_LIFECYCLE_TOPIC, WORKER, WRITE_SCOPE};

pub(crate) const WEB_ROBOTS_POLICY_SCHEMA_VERSION: &str = "tron.web_robots_policy.v1";
const RESOURCE_WRITE_SCOPE: &str = "resource.write";
const MAX_URL_BYTES: usize = 2_048;
const MAX_USER_AGENT_BYTES: usize = 128;
const DEFAULT_USER_AGENT: &str = "tron";
const DEFAULT_TIMEOUT_MS: u64 = 10_000;
const MAX_TIMEOUT_MS: u64 = 30_000;
const DEFAULT_ROBOTS_BYTES: usize = 65_536;
const MAX_ROBOTS_BYTES: usize = 262_144;
const DEFAULT_OUTPUT_BYTES: usize = 8_192;
const MAX_OUTPUT_BYTES: usize = 20_000;
const DEFAULT_REDIRECTS: usize = 3;
const MAX_REDIRECTS: usize = 5;
const MAX_SITEMAPS: usize = 20;
const PARSER_ID: &str = "tron.web.robots";
const PARSER_VERSION: &str = "1";

pub(crate) async fn web_robots_check_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let grant = inspect_robots_grant(deps, invocation).await?;
    let request = RobotsRequest::parse(payload)?;
    let target = validate_url(&request.url)?;
    let robots_url = robots_url_for(&target.url);
    validate_url(robots_url.as_str())?;
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

struct RobotsRequest {
    url: String,
    user_agent: String,
    timeout_ms: u64,
    max_robots_bytes: usize,
    max_output_bytes: usize,
    max_redirects: usize,
    idempotency_key: String,
}

impl RobotsRequest {
    fn parse(payload: &Value) -> Result<Self, CapabilityError> {
        let url = required_string(payload, "url")?;
        if url.len() > MAX_URL_BYTES {
            return Err(invalid(format!(
                "url exceeds {MAX_URL_BYTES} bytes and cannot be checked"
            )));
        }
        let user_agent =
            optional_string(payload, "userAgent")?.unwrap_or_else(|| DEFAULT_USER_AGENT.to_owned());
        validate_user_agent(&user_agent)?;
        Ok(Self {
            url,
            user_agent,
            timeout_ms: optional_u64(payload, "timeoutMs")?
                .unwrap_or(DEFAULT_TIMEOUT_MS)
                .clamp(1, MAX_TIMEOUT_MS),
            max_robots_bytes: optional_u64(payload, "maxRobotsBytes")?
                .map(|value| value as usize)
                .unwrap_or(DEFAULT_ROBOTS_BYTES)
                .clamp(1, MAX_ROBOTS_BYTES),
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

struct ParsedRobots {
    matched_user_agent: Option<String>,
    rules: Vec<RobotsRule>,
    sitemaps: Vec<String>,
    sitemaps_truncated: bool,
}

#[derive(Clone)]
struct RobotsRule {
    directive: &'static str,
    pattern: String,
    line: usize,
}

fn parse_robots(body: &str, user_agent: &str, target_path: String) -> ParsedRobots {
    let mut groups = Vec::<RobotsGroup>::new();
    let mut current_agents = Vec::<String>::new();
    let mut current_rules = Vec::<RobotsRule>::new();
    let mut sitemaps = Vec::new();
    let mut sitemaps_truncated = false;
    for (index, raw_line) in body.lines().enumerate() {
        let line_number = index.saturating_add(1);
        let line = raw_line
            .split_once('#')
            .map_or(raw_line, |(prefix, _)| prefix)
            .trim();
        if line.is_empty() {
            if !current_agents.is_empty() || !current_rules.is_empty() {
                groups.push(RobotsGroup {
                    agents: std::mem::take(&mut current_agents),
                    rules: std::mem::take(&mut current_rules),
                });
            }
            continue;
        }
        let Some((field, value)) = line.split_once(':') else {
            continue;
        };
        let field = field.trim().to_ascii_lowercase();
        let value = value.trim();
        match field.as_str() {
            "user-agent" => {
                if !current_rules.is_empty() {
                    groups.push(RobotsGroup {
                        agents: std::mem::take(&mut current_agents),
                        rules: std::mem::take(&mut current_rules),
                    });
                }
                if !value.is_empty() {
                    current_agents.push(value.to_ascii_lowercase());
                }
            }
            "allow" if !current_agents.is_empty() => current_rules.push(RobotsRule {
                directive: "allow",
                pattern: value.to_owned(),
                line: line_number,
            }),
            "disallow" if !current_agents.is_empty() => current_rules.push(RobotsRule {
                directive: "disallow",
                pattern: value.to_owned(),
                line: line_number,
            }),
            "sitemap" => {
                if sitemaps.len() < MAX_SITEMAPS {
                    sitemaps.push(value.to_owned());
                } else {
                    sitemaps_truncated = true;
                }
            }
            _ => {}
        }
    }
    if !current_agents.is_empty() || !current_rules.is_empty() {
        groups.push(RobotsGroup {
            agents: current_agents,
            rules: current_rules,
        });
    }

    let user_agent = user_agent.to_ascii_lowercase();
    let mut best_specificity = None::<usize>;
    let mut matched_agents = Vec::<String>::new();
    let mut matched_rules = Vec::<RobotsRule>::new();
    for group in groups {
        let specificity = group
            .agents
            .iter()
            .filter_map(|agent| user_agent_specificity(&user_agent, agent))
            .max();
        let Some(specificity) = specificity else {
            continue;
        };
        match best_specificity {
            None => {
                best_specificity = Some(specificity);
                matched_agents = group.agents;
                matched_rules = group.rules;
            }
            Some(best) if specificity > best => {
                best_specificity = Some(specificity);
                matched_agents = group.agents;
                matched_rules = group.rules;
            }
            Some(best) if specificity == best => {
                matched_agents.extend(group.agents);
                matched_rules.extend(group.rules);
            }
            _ => {}
        }
    }
    let matched_user_agent = matched_agents.into_iter().next();
    let rules = matched_rules
        .into_iter()
        .filter(|rule| {
            rule.directive == "allow" && !rule.pattern.is_empty()
                || rule.directive == "disallow" && !rule.pattern.is_empty()
        })
        .filter(|rule| rule_matches(&rule.pattern, &target_path))
        .collect();
    ParsedRobots {
        matched_user_agent,
        rules,
        sitemaps,
        sitemaps_truncated,
    }
}

struct RobotsGroup {
    agents: Vec<String>,
    rules: Vec<RobotsRule>,
}

struct RobotsDecision {
    decision: &'static str,
    reason: &'static str,
    rule: Value,
}

fn decision_for_status(
    status: u16,
    missing: bool,
    body_truncated: bool,
    parsed: &ParsedRobots,
) -> RobotsDecision {
    if missing {
        return empty_decision("allow", "robots_missing");
    }
    if matches!(status, 401 | 403) {
        return empty_decision("deny", "robots_status_denies_all");
    }
    if status >= 500 {
        return empty_decision("deny", "robots_unavailable_fail_closed");
    }
    if body_truncated {
        return empty_decision("deny", "robots_body_truncated_fail_closed");
    }
    let Some(rule) = best_rule(&parsed.rules) else {
        return empty_decision("allow", "no_matching_disallow_rule");
    };
    let decision = if rule.directive == "allow" {
        "allow"
    } else {
        "deny"
    };
    RobotsDecision {
        decision,
        reason: "matched_robots_rule",
        rule: json!({
            "directive": rule.directive,
            "path": rule.pattern,
            "line": rule.line,
            "matchLength": rule_match_length(&rule.pattern)
        }),
    }
}

fn empty_decision(decision: &'static str, reason: &'static str) -> RobotsDecision {
    RobotsDecision {
        decision,
        reason,
        rule: Value::Null,
    }
}

fn best_rule(rules: &[RobotsRule]) -> Option<&RobotsRule> {
    rules.iter().max_by(|left, right| {
        rule_match_length(&left.pattern)
            .cmp(&rule_match_length(&right.pattern))
            .then_with(|| (left.directive == "allow").cmp(&(right.directive == "allow")))
    })
}

fn user_agent_specificity(user_agent: &str, candidate: &str) -> Option<usize> {
    let candidate = candidate.trim();
    if candidate == "*" {
        Some(0)
    } else if !candidate.is_empty() && user_agent.contains(candidate) {
        Some(candidate.len())
    } else {
        None
    }
}

fn rule_matches(pattern: &str, target_path: &str) -> bool {
    if pattern.is_empty() {
        return false;
    }
    let anchored = pattern.ends_with('$');
    let pattern = pattern.trim_end_matches('$');
    if !pattern.contains('*') {
        return if anchored {
            target_path == pattern
        } else {
            target_path.starts_with(pattern)
        };
    }
    let mut remainder = target_path;
    for (index, part) in pattern.split('*').enumerate() {
        if part.is_empty() {
            continue;
        }
        if index == 0 {
            if !remainder.starts_with(part) {
                return false;
            }
            remainder = &remainder[part.len()..];
        } else if let Some(offset) = remainder.find(part) {
            remainder = &remainder[offset + part.len()..];
        } else {
            return false;
        }
    }
    !anchored || remainder.is_empty()
}

fn rule_match_length(pattern: &str) -> usize {
    pattern
        .trim_end_matches('$')
        .chars()
        .filter(|ch| *ch != '*')
        .count()
}

async fn existing_robots_check(
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

fn robots_url_for(target: &Url) -> Url {
    let mut robots = target.clone();
    robots.set_path("/robots.txt");
    robots.set_query(None);
    robots.set_fragment(None);
    robots
}

fn target_path(url: &Url) -> String {
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

fn origin_string(url: &Url) -> String {
    let host = url.host_str().unwrap_or_default();
    match url.port() {
        Some(port) => format!("{}://{}:{port}", url.scheme(), host),
        None => format!("{}://{}", url.scheme(), host),
    }
}

fn robots_resource_id(
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

fn robots_result(
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

async fn publish_robots_event(
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

fn session_resource_scope(invocation: &Invocation) -> Result<EngineResourceScope, CapabilityError> {
    invocation
        .causal_context
        .session_id
        .as_ref()
        .map(|session| EngineResourceScope::Session(session.clone()))
        .ok_or_else(|| invalid("web_robots_check requires trusted current session context"))
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

struct BoundedText {
    text: String,
    truncated: bool,
}

fn bounded_utf8(value: &str, max_bytes: usize) -> BoundedText {
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

fn validate_user_agent(value: &str) -> Result<(), CapabilityError> {
    if value.trim().is_empty() || value.len() > MAX_USER_AGENT_BYTES {
        return Err(invalid(format!(
            "userAgent must be 1..={MAX_USER_AGENT_BYTES} bytes"
        )));
    }
    if !value.bytes().all(|byte| {
        byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b'/' | b' ')
    }) {
        return Err(invalid("userAgent contains unsupported characters"));
    }
    Ok(())
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
