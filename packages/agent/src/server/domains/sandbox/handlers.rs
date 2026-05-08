//! Operation binding for the sandbox worker.

use super::*;
use crate::server::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "list_containers" => |_invocation, deps| {
            list_containers(deps).await
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
