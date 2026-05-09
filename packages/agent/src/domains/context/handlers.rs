//! Operation binding for the context worker.

use super::Deps;
use crate::domains::bindings::operation_bindings;
use crate::domains::context::operations;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "get_snapshot" => |invocation, deps| {
            operations::get_snapshot(&invocation.payload, deps).await
        },
        "get_detailed_snapshot" => |invocation, deps| {
            operations::get_detailed_snapshot(&invocation.payload, deps).await
        },
        "get_audit_trace" => |invocation, deps| {
            operations::get_audit_trace(&invocation.payload, deps).await
        },
        "should_compact" => |invocation, deps| {
            operations::should_compact(&invocation.payload, deps).await
        },
        "preview_compaction" => |invocation, deps| {
            operations::preview_compaction(&invocation.payload, deps).await
        },
        "can_accept_turn" => |invocation, deps| {
            operations::can_accept_turn(&invocation.payload, deps).await
        },
        "confirm_compaction" => |invocation, deps| {
            operations::confirm_compaction(&invocation.payload, deps).await
        },
        "clear" => |invocation, deps| {
            operations::clear(&invocation.payload, deps).await
        },
        "compact" => |invocation, deps| {
            operations::compact(&invocation.payload, deps).await
        },
    ];
}
