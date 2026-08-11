//! Authenticated native-client bindings for canonical agent projections.
//!
//! These functions deliberately contain no client-side join logic. The
//! runtime authorizes the selected visible session, derives relationships from
//! canonical topology, and returns server-authored allowed actions.

use serde_json::Value;

use super::Deps;
use crate::engine::Invocation;

pub(super) async fn relations(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime.client_agent_relations(invocation).await
}

pub(super) async fn inspect(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime.client_agent_inspect(invocation).await
}

pub(super) async fn assignments(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime.client_agent_assignments(invocation).await
}

pub(super) async fn messages(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime.client_agent_messages(invocation).await
}

pub(super) async fn message_detail(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime.client_agent_message_detail(invocation).await
}

pub(super) async fn result_read(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime.client_agent_result_read(invocation).await
}

pub(super) async fn operator_message(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, String> {
    deps.runtime.client_agent_operator_message(invocation).await
}

pub(super) async fn manage(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime.client_agent_manage(invocation).await
}

pub(super) async fn retry(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime.client_agent_retry(invocation).await
}

pub(super) async fn promote(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime.client_agent_promote(invocation).await
}
