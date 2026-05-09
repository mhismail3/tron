//! Operation binding for the session worker.

use super::Deps;
use super::operations::*;
use crate::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "create" => |invocation, deps| {
            session_create_value(Some(&invocation.payload), deps).await
        },
        "resume" => |invocation, deps| {
            session_resume_value(Some(&invocation.payload), deps).await
        },
        "list" => |invocation, deps| {
            session_list_value(Some(&invocation.payload), deps).await
        },
        "delete" => |invocation, deps| {
            session_delete_value(Some(&invocation.payload), deps).await
        },
        "fork" => |invocation, deps| {
            session_fork_value(Some(&invocation.payload), deps).await
        },
        "get_head" => |invocation, deps| {
            session_get_head_value(Some(&invocation.payload), deps).await
        },
        "get_state" => |invocation, deps| {
            session_get_state_value(Some(&invocation.payload), deps).await
        },
        "get_history" => |invocation, deps| {
            session_get_history_value(Some(&invocation.payload), deps).await
        },
        "reconstruct" => |invocation, deps| {
            session_reconstruct_value(Some(&invocation.payload), deps).await
        },
        "archive" => |invocation, deps| {
            session_archive_value(Some(&invocation.payload), deps).await
        },
        "unarchive" => |invocation, deps| {
            session_unarchive_value(Some(&invocation.payload), deps).await
        },
        "archive_older_than" => |invocation, deps| {
            session_archive_older_than_value(Some(&invocation.payload), deps).await
        },
        "export" => |invocation, deps| {
            session_export_value(Some(&invocation.payload), deps).await
        },
    ];
}
