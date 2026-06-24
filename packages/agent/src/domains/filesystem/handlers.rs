//! Operation binding for the filesystem worker.

use crate::domains::registration::bindings::operation_bindings;

use super::Deps;
use super::agent_tools;
use super::service::{create_dir_value, get_home_value, list_dir_value};

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "get_home" => |_invocation, deps| {
            get_home_value(deps).await
        },
        "list_dir" => |invocation, deps| {
            list_dir_value(invocation.payload.clone(), deps).await
        },
        "create_dir" => |invocation, deps| {
            create_dir_value(invocation.payload.clone(), deps).await
        },
        "read" => |invocation, _deps| {
            agent_tools::read_value(&invocation, &invocation.payload).await
        },
        "list" => |invocation, _deps| {
            agent_tools::list_value(&invocation, &invocation.payload).await
        },
        "find" => |invocation, _deps| {
            agent_tools::find_value(&invocation, &invocation.payload, false).await
        },
        "glob" => |invocation, _deps| {
            agent_tools::find_value(&invocation, &invocation.payload, true).await
        },
        "search_text" => |invocation, _deps| {
            agent_tools::search_text_value(&invocation, &invocation.payload).await
        },
        "diff" => |invocation, _deps| {
            agent_tools::diff_value(&invocation, &invocation.payload).await
        },
        "write" => |invocation, deps| {
            agent_tools::write_value(&deps.engine_host, &invocation, &invocation.payload).await
        },
        "edit" => |invocation, deps| {
            agent_tools::edit_value(&deps.engine_host, &invocation, &invocation.payload).await
        },
        "apply_patch" => |invocation, deps| {
            agent_tools::edit_value(&deps.engine_host, &invocation, &invocation.payload).await
        },
    ];
}
