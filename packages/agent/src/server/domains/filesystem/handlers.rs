//! Operation binding for the filesystem worker.

use super::*;
use crate::server::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "list_dir" => |invocation, deps| {
            filesystem_list_dir_value(Some(&invocation.payload), deps).await
        },
        "get_home" => |_invocation, deps| {
            filesystem_get_home_value(deps).await
        },
        "read_file" => |invocation, deps| {
            file_read_value(Some(&invocation.payload), deps).await
        },
        "create_dir" => |invocation, deps| {
            filesystem_create_dir_value(Some(&invocation.payload), deps).await
        },
    ];
}
