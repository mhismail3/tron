//! Operation binding for the notifications worker.

use super::{
    Deps, notifications_list_value, notifications_mark_all_read_value,
    notifications_mark_read_value, notifications_send_value,
};
use crate::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "send" => |invocation, deps| {
            notifications_send_value(Some(&invocation.payload), deps, invocation).await
        },
        "list" => |invocation, deps| {
            notifications_list_value(Some(&invocation.payload), deps).await
        },
        "mark_read" => |invocation, deps| {
            notifications_mark_read_value(Some(&invocation.payload), deps).await
        },
        "mark_all_read" => |invocation, deps| {
            notifications_mark_all_read_value(Some(&invocation.payload), deps).await
        },
    ];
}
