//! Authenticated Artifact Inbox metadata, content, and explicit deletion.

use serde::de::DeserializeOwned;
use serde_json::Value;

use crate::engine::Invocation;

use super::Deps;

pub(super) async fn deliveries(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime
        .artifact_deliveries(decode(&invocation.payload)?)
}

pub(super) async fn content(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime.artifact_content(decode(&invocation.payload)?)
}

pub(super) async fn delete(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime.artifact_delete(decode(&invocation.payload)?)
}

fn decode<T: DeserializeOwned>(value: &Value) -> Result<T, String> {
    serde_json::from_value(value.clone()).map_err(|error| error.to_string())
}
