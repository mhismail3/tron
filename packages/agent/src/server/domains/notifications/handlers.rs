//! Operation binding for the notifications worker.

use super::*;

pub(crate) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let payload = &invocation.payload;
    match method {
        "notifications::list" => notifications_list_value(Some(payload), deps).await,
        "notifications::mark_read" => notifications_mark_read_value(Some(payload), deps).await,
        "notifications::mark_all_read" => {
            notifications_mark_all_read_value(Some(payload), deps).await
        }
        _ => Err(CapabilityError::Internal {
            message: format!("notifications method {method} is not engine-owned"),
        }),
    }
}
