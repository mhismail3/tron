//! Operation binding for the sandbox worker.

use super::{Deps, get_spawned_worker, list_containers, list_spawned_workers, remove_container};
use super::{run_container_command, spawn_worker, stop_spawned_worker};
use crate::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "list_containers" => |_invocation, deps| {
            list_containers(deps).await
        },
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
        },
        "start_container" => |invocation, _deps| {
            run_container_command("start", &invocation.payload).await
        },
        "stop_container" => |invocation, _deps| {
            run_container_command("stop", &invocation.payload).await
        },
        "kill_container" => |invocation, _deps| {
            run_container_command("kill", &invocation.payload).await
        },
        "remove_container" => |invocation, deps| {
            remove_container(&invocation.payload, deps).await
        },
    ];
}
