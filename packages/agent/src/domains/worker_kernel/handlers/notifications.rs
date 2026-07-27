//! Authenticated native notification registration, inbox, and responses.

use serde::de::DeserializeOwned;
use serde_json::Value;

use crate::engine::Invocation;

use super::Deps;

pub(super) async fn device_upsert(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime
        .notification_device_upsert(decode(&invocation.payload)?)
}

pub(super) async fn device_disable(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime
        .notification_device_disable(decode(&invocation.payload)?)
}

pub(super) async fn deliveries(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime
        .notification_deliveries(decode(&invocation.payload)?)
}

pub(super) async fn acknowledge(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime
        .acknowledge_notification_delivery(decode(&invocation.payload)?)
        .await
}

pub(super) async fn status(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime
        .notification_delivery_status(decode(&invocation.payload)?)
}

fn decode<T: DeserializeOwned>(value: &Value) -> Result<T, String> {
    serde_json::from_value(value.clone()).map_err(|error| error.to_string())
}
