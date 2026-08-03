//! Narrow model-facing agent delivery and wait primitives.

use serde_json::Value;

use super::Deps;
use crate::engine::Invocation;

pub(super) async fn send(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime.agent_send(invocation).await
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
