//! Narrow model-facing agent delivery and wait primitives.

use serde_json::Value;

use super::Deps;
use crate::engine::Invocation;

pub(super) async fn discover(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime.agent_discover(invocation).await
}

pub(super) async fn team_context(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime.agent_team_context(invocation).await
}

pub(super) async fn spawn(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime.agent_spawn(invocation).await
}

pub(super) async fn send(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime.agent_send(invocation).await
}

pub(super) async fn wait(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime.agent_wait(invocation).await
}

pub(super) async fn manage(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime.agent_manage(invocation).await
}

pub(super) async fn wait_for_workers(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, String> {
    deps.runtime.agent_wait_for_workers(invocation).await
}

pub(super) async fn mailbox_list(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime.agent_mailbox_list(invocation)
}

pub(super) async fn mailbox_claim(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime.agent_mailbox_claim(invocation)
}

pub(super) async fn mailbox_curate(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime.curate_new_session_mailbox(invocation).await
}
