//! Authenticated native-client bindings for durable reusable-agent role review.

use serde_json::Value;

use crate::engine::Invocation;

use super::Deps;
use super::support::required_string;

pub(super) async fn list(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    let limit = usize::try_from(
        invocation
            .payload
            .get("limit")
            .and_then(Value::as_u64)
            .unwrap_or(50),
    )
    .unwrap_or(100)
    .clamp(1, 100);
    let offset = invocation
        .payload
        .get("offset")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let queue_limit = usize::try_from(
        invocation
            .payload
            .get("queueLimit")
            .and_then(Value::as_u64)
            .unwrap_or(100),
    )
    .unwrap_or(100)
    .clamp(1, 100);
    let queue_offset = invocation
        .payload
        .get("queueOffset")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    deps.runtime
        .client_agent_role_reviews(limit, offset, queue_limit, queue_offset)
        .await
}

pub(super) async fn start(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime
        .start_agent_role_review(
            &required_string(&invocation.payload, "workerId")?,
            invocation,
        )
        .await
}

pub(super) async fn inspect(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime
        .inspect_agent_role_review(&required_string(&invocation.payload, "proposalId")?)
}

pub(super) async fn apply(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    if invocation.payload.get("confirmed").and_then(Value::as_bool) != Some(true) {
        return Err("confirmed must be true to publish an agent role proposal".to_owned());
    }
    deps.runtime
        .apply_agent_role_review(
            &required_string(&invocation.payload, "proposalId")?,
            invocation,
        )
        .await
}

pub(super) async fn reject(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    let reason = invocation
        .payload
        .get("reason")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty());
    if reason.is_some_and(|value| value.len() > 512 || value.chars().any(char::is_control)) {
        return Err("reason must contain at most 512 UTF-8 bytes without controls".to_owned());
    }
    deps.runtime
        .reject_agent_role_review(
            &required_string(&invocation.payload, "proposalId")?,
            reason,
            invocation,
        )
        .await
}
