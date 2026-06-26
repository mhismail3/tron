use crate::domains::registration::bindings::operation_bindings;

use super::{Deps, service};

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "status" => |invocation, deps| {
            service::status_memory_value(&deps.engine_host, invocation, &invocation.payload).await
        },
        "configure_policy" => |invocation, deps| {
            service::configure_policy_value(&deps.engine_host, invocation, &invocation.payload).await
        },
        "retain" => |invocation, deps| {
            service::retain_memory_value(&deps.engine_host, invocation, &invocation.payload).await
        },
        "edit" => |invocation, deps| {
            service::edit_memory_value(&deps.engine_host, invocation, &invocation.payload).await
        },
        "tombstone" => |invocation, deps| {
            service::tombstone_memory_value(&deps.engine_host, invocation, &invocation.payload).await
        },
        "list" => |invocation, deps| {
            service::list_memory_value(&deps.engine_host, invocation, &invocation.payload).await
        },
        "inspect" => |invocation, deps| {
            service::inspect_memory_value(&deps.engine_host, invocation, &invocation.payload).await
        },
        "migrate_export" => |invocation, deps| {
            service::migrate_export_value(&deps.engine_host, invocation, &invocation.payload).await
        },
        "migrate_import" => |invocation, deps| {
            service::migrate_import_value(&deps.engine_host, invocation, &invocation.payload).await
        },
        "record_prompt_trace" => |invocation, deps| {
            service::record_prompt_trace_value(&deps.engine_host, invocation, &invocation.payload).await
        },
        "record_query" => |invocation, deps| {
            service::record_memory_query_value(&deps.engine_host, invocation, &invocation.payload).await
        },
        "query_list" => |invocation, deps| {
            service::list_memory_queries_value(&deps.engine_host, invocation, &invocation.payload).await
        },
        "query_inspect" => |invocation, deps| {
            service::inspect_memory_query_value(&deps.engine_host, invocation, &invocation.payload).await
        },
        "record_decision" => |invocation, deps| {
            service::record_memory_decision_value(&deps.engine_host, invocation, &invocation.payload).await
        },
        "decision_list" => |invocation, deps| {
            service::list_memory_decisions_value(&deps.engine_host, invocation, &invocation.payload).await
        },
        "decision_inspect" => |invocation, deps| {
            service::inspect_memory_decision_value(&deps.engine_host, invocation, &invocation.payload).await
        },
    ];
}
