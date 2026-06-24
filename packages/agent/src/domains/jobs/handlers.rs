use crate::domains::registration::bindings::operation_bindings;

use super::{Deps, service};

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "start" => |invocation, deps| {
            service::start_job_value(
                &deps.engine_host,
                deps.shutdown_coordinator.clone(),
                deps.runtime.clone(),
                invocation,
                &invocation.payload,
            ).await
        },
        "status" => |invocation, deps| {
            service::status_job_value(
                &deps.engine_host,
                deps.runtime.clone(),
                deps.reconcile.clone(),
                invocation,
                &invocation.payload,
            ).await
        },
        "list" => |invocation, deps| {
            service::list_jobs_value(
                &deps.engine_host,
                deps.runtime.clone(),
                deps.reconcile.clone(),
                invocation,
                &invocation.payload,
            ).await
        },
        "log" => |invocation, deps| {
            service::log_job_value(
                &deps.engine_host,
                deps.runtime.clone(),
                deps.reconcile.clone(),
                invocation,
                &invocation.payload,
            ).await
        },
        "cancel" => |invocation, deps| {
            service::cancel_job_value(
                &deps.engine_host,
                deps.runtime.clone(),
                deps.reconcile.clone(),
                invocation,
                &invocation.payload,
            ).await
        },
        "cleanup" => |invocation, deps| {
            service::cleanup_jobs_value(
                &deps.engine_host,
                deps.runtime.clone(),
                deps.reconcile.clone(),
                invocation,
                &invocation.payload,
            ).await
        },
    ];
}
