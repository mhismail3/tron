//! Operation binding for the filesystem worker.

use super::{
    Deps, file_read_value, filesystem_apply_patch_value, filesystem_create_dir_value,
    filesystem_diff_value, filesystem_edit_file_value, filesystem_find_value,
    filesystem_get_home_value, filesystem_list_dir_value, filesystem_search_text_value,
    filesystem_write_file_value,
};
use crate::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "list_dir" => |invocation, deps| {
            filesystem_list_dir_value(invocation, deps).await
        },
        "get_home" => |_invocation, deps| {
            filesystem_get_home_value(deps).await
        },
        "read_file" => |invocation, deps| {
            file_read_value(invocation, deps).await
        },
        "write_file" => |invocation, deps| {
            filesystem_write_file_value(invocation, deps).await
        },
        "edit_file" => |invocation, deps| {
            filesystem_edit_file_value(invocation, deps, "edit").await
        },
        "find" => |invocation, deps| {
            filesystem_find_value(invocation, deps).await
        },
        "glob" => |invocation, deps| {
            filesystem_find_value(invocation, deps).await
        },
        "search_text" => |invocation, deps| {
            filesystem_search_text_value(invocation, deps).await
        },
        "diff" => |invocation, deps| {
            filesystem_diff_value(invocation, deps).await
        },
        "apply_patch" => |invocation, deps| {
            filesystem_apply_patch_value(invocation, deps).await
        },
        "create_dir" => |invocation, deps| {
            filesystem_create_dir_value(invocation, deps).await
        },
    ];
}
