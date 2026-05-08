//! Operation binding for the events worker.

use super::{
    Deps, events_append_value, events_get_history_value, events_get_since_value,
    events_subscribe_value, events_unsubscribe_value,
};
use crate::server::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "get_history" => |invocation, deps| {
            events_get_history_value(Some(&invocation.payload), deps).await
        },
        "get_since" => |invocation, deps| {
            events_get_since_value(Some(&invocation.payload), deps).await
        },
        "append" => |invocation, deps| {
            events_append_value(Some(&invocation.payload), invocation, deps).await
        },
        "subscribe" => |invocation, deps| {
            events_subscribe_value(Some(&invocation.payload), invocation, deps).await
        },
        "unsubscribe" => |invocation, deps| {
            events_unsubscribe_value(Some(&invocation.payload), deps).await
        },
    ];
}
