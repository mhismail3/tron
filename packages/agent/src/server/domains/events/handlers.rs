//! Operation binding for the events worker.

use super::*;

pub(crate) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let payload = &invocation.payload;
    match method {
        "events::get_history" => events_get_history_value(Some(payload), deps).await,
        "events::get_since" => events_get_since_value(Some(payload), deps).await,
        "events::append" => events_append_value(Some(payload), invocation, deps).await,
        "events::subscribe" => events_subscribe_value(Some(payload), invocation, deps).await,
        "events::unsubscribe" => events_unsubscribe_value(Some(payload), deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("events method {method} is not engine-owned"),
        }),
    }
}
