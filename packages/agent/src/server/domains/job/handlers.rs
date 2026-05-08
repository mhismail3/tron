//! Operation binding for the job worker.

use super::Deps;
use super::operations::*;
use crate::server::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = ["background_apply", "cancel_apply"];
    bindings = [
        "background" => |invocation, deps| {
            enqueue_and_sync_drain_job_apply(
                "job::background_apply",
                "job::background_apply",
                invocation,
                deps,
            )
            .await
        },
        "cancel" => |invocation, deps| {
            enqueue_and_sync_drain_job_apply(
                "job::cancel_apply",
                "job::cancel_apply",
                invocation,
                deps,
            )
            .await
        },
        "background_apply" => |invocation, deps| {
            job_background_apply_value(Some(&invocation.payload), invocation, deps).await
        },
        "cancel_apply" => |invocation, deps| {
            job_cancel_apply_value(Some(&invocation.payload), invocation, deps).await
        },
        "list" => |invocation, deps| {
            job_list_value(Some(&invocation.payload), deps)
        },
        "subscribe" => |invocation, deps| {
            job_subscribe_value(Some(&invocation.payload), deps).await
        },
        "unsubscribe" => |invocation, _deps| {
            job_unsubscribe_value(Some(&invocation.payload))
        },
    ];
}
