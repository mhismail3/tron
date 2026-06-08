//! Outbound `/engine` WebSocket serialization and backpressure handling.

use metrics::counter;
use serde_json::Value;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

pub(super) fn send_engine_ws_value(out_tx: &mpsc::Sender<String>, value: Value) -> bool {
    let mut value = value;
    remove_null_transport_fields(&mut value);
    let json = match serde_json::to_string(&value) {
        Ok(json) => json,
        Err(error) => {
            tracing::error!(%error, "failed to serialize engine WebSocket response");
            return false;
        }
    };
    match out_tx.try_send(json) {
        Ok(()) => true,
        Err(mpsc::error::TrySendError::Full(_)) => {
            counter!("engine_ws_overload_total").increment(1);
            tracing::warn!("engine WebSocket outbound queue overloaded; closing connection");
            false
        }
        Err(mpsc::error::TrySendError::Closed(_)) => false,
    }
}

pub(super) async fn send_engine_ws_value_async(
    out_tx: &mpsc::Sender<String>,
    cancel: &CancellationToken,
    value: Value,
) -> bool {
    let mut value = value;
    remove_null_transport_fields(&mut value);
    let json = match serde_json::to_string(&value) {
        Ok(json) => json,
        Err(error) => {
            tracing::error!(%error, "failed to serialize engine WebSocket push event");
            return false;
        }
    };
    tokio::select! {
        () = cancel.cancelled() => false,
        result = out_tx.send(json) => {
            if result.is_err() {
                tracing::debug!("engine WebSocket outbound queue closed while sending stream event");
                return false;
            }
            true
        }
    }
}

fn remove_null_transport_fields(value: &mut Value) {
    if let Value::Object(object) = value {
        object.retain(|_, value| !value.is_null());
        if let Some(Value::Object(error)) = object.get_mut("error") {
            error.retain(|_, value| !value.is_null());
        }
    }
}
