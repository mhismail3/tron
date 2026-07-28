//! Closed browser request validation and bounded response projection.

use super::*;

pub(super) fn validate_request(request: &BrowserClientRequest) -> Result<()> {
    validate_identifier("requestId", &request.request_id, 128)?;
    if !(MIN_TIMEOUT_MS..=MAX_TIMEOUT_MS).contains(&request.timeout_ms) {
        bail!("timeoutMs must be between {MIN_TIMEOUT_MS} and {MAX_TIMEOUT_MS}");
    }
    match &request.action {
        BrowserAction::Tabs => {}
        BrowserAction::Observe { tab_id } | BrowserAction::Screenshot { tab_id } => {
            validate_tab_id(*tab_id)?;
        }
        BrowserAction::Click {
            tab_id,
            observation_id,
            element_ref,
        } => {
            validate_element_target(*tab_id, observation_id, element_ref)?;
        }
        BrowserAction::Type {
            tab_id,
            observation_id,
            element_ref,
            text,
            ..
        } => {
            validate_element_target(*tab_id, observation_id, element_ref)?;
            if text.len() > 4_000 {
                bail!("typed text exceeds the 4000-byte ceiling");
            }
        }
        BrowserAction::Key {
            tab_id,
            observation_id,
            element_ref,
            ..
        } => {
            validate_tab_id(*tab_id)?;
            if observation_id.is_some() != element_ref.is_some() {
                bail!("key target requires both observationId and elementRef");
            }
            if let (Some(observation_id), Some(element_ref)) = (observation_id, element_ref) {
                validate_element_target(*tab_id, observation_id, element_ref)?;
            }
        }
        BrowserAction::Scroll {
            tab_id,
            delta_x,
            delta_y,
        } => {
            validate_tab_id(*tab_id)?;
            if *delta_x == 0 && *delta_y == 0 {
                bail!("scroll delta must not be zero");
            }
            if delta_x.unsigned_abs() > 2_000 || delta_y.unsigned_abs() > 2_000 {
                bail!("scroll deltas must be within -2000...2000");
            }
        }
        BrowserAction::Navigate { tab_id, url } => {
            validate_tab_id(*tab_id)?;
            validate_navigation_url(url)?;
        }
    }
    Ok(())
}

pub(super) fn validate_tab_id(tab_id: i64) -> Result<()> {
    if tab_id <= 0 {
        bail!("tabId must be a positive stable Chrome tab id");
    }
    Ok(())
}

pub(super) fn validate_element_target(
    tab_id: i64,
    observation_id: &str,
    element_ref: &str,
) -> Result<()> {
    validate_tab_id(tab_id)?;
    validate_identifier("observationId", observation_id, 96)?;
    validate_identifier("elementRef", element_ref, 128)
}

pub(super) fn validate_identifier(name: &str, value: &str, max_bytes: usize) -> Result<()> {
    if value.is_empty()
        || value.len() > max_bytes
        || value
            .bytes()
            .any(|byte| !(byte.is_ascii_alphanumeric() || b"-_:.".contains(&byte)))
    {
        bail!("{name} must be a 1..={max_bytes}-byte identifier");
    }
    Ok(())
}

pub(super) fn validate_navigation_url(raw: &str) -> Result<()> {
    if raw.len() > 2_048 {
        bail!("navigation URL exceeds the 2048-byte ceiling");
    }
    let parsed = url::Url::parse(raw).context("navigation URL must be absolute")?;
    if !parsed.username().is_empty() || parsed.password().is_some() {
        bail!("navigation URL must not contain credentials");
    }
    let is_loopback_http = parsed.scheme() == "http"
        && parsed
            .host_str()
            .is_some_and(|host| matches!(host, "localhost" | "127.0.0.1" | "::1" | "[::1]"));
    if parsed.scheme() != "https" && !is_loopback_http {
        bail!("navigation allows HTTPS or loopback HTTP only");
    }
    Ok(())
}

pub(super) fn bounded_native_response(
    request_id: &str,
    ok: bool,
    result: Option<Value>,
    error: Option<String>,
) -> Value {
    let response = if ok {
        serde_json::json!({
            "requestId": request_id,
            "ok": true,
            "result": result.unwrap_or(Value::Null),
        })
    } else {
        let reason = error
            .as_deref()
            .map(sanitize_reason)
            .filter(|reason| !reason.is_empty())
            .unwrap_or_else(|| "browser_action_failed".to_owned());
        error_response(request_id, &reason)
    };
    if serde_json::to_vec(&response).map_or(true, |bytes| bytes.len() > MAX_NATIVE_RESPONSE_BYTES) {
        error_response(request_id, "browser_response_oversized")
    } else {
        response
    }
}

pub(super) fn error_response(request_id: &str, reason: &str) -> Value {
    serde_json::json!({
        "requestId": request_id,
        "ok": false,
        "error": sanitize_reason(reason),
    })
}

pub(super) fn sanitize_reason(reason: &str) -> String {
    reason
        .chars()
        .filter(|character| !character.is_control() || matches!(character, '\n' | '\r' | '\t'))
        .take(512)
        .collect()
}
