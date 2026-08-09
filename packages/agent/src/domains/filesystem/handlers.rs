//! Operation binding for the filesystem worker.

use crate::domains::registration::bindings::operation_bindings;

use super::Deps;
use super::service::{
    create_dir_value, get_home_value, inspect_source_control_value, list_dir_value,
};

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
        "inspect_source_control" => |invocation, deps| {
            inspect_source_control_value(invocation.payload.clone(), deps).await
        },
    ];
}
