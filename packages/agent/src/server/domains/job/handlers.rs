//! Operation binding for the job worker.

use super::operations::*;
use super::*;

pub(crate) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let payload = &invocation.payload;
    match method {
        "job::background" => {
            enqueue_and_sync_drain_job_apply(
                "job::background_apply",
                "job::background_apply",
                invocation,
                deps,
            )
            .await
        }
        "job::cancel" => {
            enqueue_and_sync_drain_job_apply(
                "job::cancel_apply",
                "job::cancel_apply",
                invocation,
                deps,
            )
            .await
        }
        "job::background_apply" => {
            job_background_apply_value(Some(payload), invocation, deps).await
        }
        "job::cancel_apply" => job_cancel_apply_value(Some(payload), invocation, deps).await,
        "job::list" => job_list_value(Some(payload), deps),
        "job::subscribe" => job_subscribe_value(Some(payload), deps).await,
        "job::unsubscribe" => job_unsubscribe_value(Some(payload)),
        _ => Err(CapabilityError::Internal {
            message: format!("job method {method} is not engine-owned"),
        }),
    }
}
