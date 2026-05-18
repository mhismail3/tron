//! Operation binding for the sandbox worker.

use super::{Deps, get_spawned_worker, list_spawned_workers, spawn_worker, stop_spawned_worker};
use crate::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "spawn_worker" => |invocation, deps| {
            spawn_worker(invocation, deps).await
        },
        "list_spawned_workers" => |_invocation, deps| {
            list_spawned_workers(deps).await
        },
        "get_spawned_worker" => |invocation, deps| {
            get_spawned_worker(invocation, deps).await
        },
        "stop_spawned_worker" => |invocation, deps| {
            stop_spawned_worker(invocation, deps).await
        }
    ];
}
