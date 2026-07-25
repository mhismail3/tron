//! Protocol binding for fixed kernel operations.
//!
//! The binding table is the only function-name dispatch map. Concern modules
//! decode typed payloads and call the single `WorkerRuntime`; they do not own
//! alternate catalogs, grants, or compatibility adapters.
//!
//! ## Ownership
//!
//! - `core` owns session-title, engine introspection/hooks, and isolated core
//!   proposal handlers.
//! - `authoring` owns atomic bundle upsert and bounded source-tree import.
//! - `discovery` owns list, inspect, and relevance-backed promotion.
//! - `invocation` owns manual dispatch, nested worker-input admission errors,
//!   lifecycle controls, and bounded durable-result reads.
//! - `inbox` owns durable result projection and adaptive inbox context.
//! - `webhook` owns credential rotation and authenticated ingress materialization.
//! - `support` owns shared payload admission and response translation.

use std::sync::Arc;

use crate::domains::registration::bindings::operation_bindings;

use super::host;
use super::runtime::WorkerRuntime;

mod authoring;
mod core;
mod discovery;
mod inbox;
mod invocation;
mod support;
mod webhook;

#[derive(Clone)]
pub(super) struct Deps {
    pub(super) runtime: Arc<WorkerRuntime>,
}

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "filesystem_read" => |invocation, deps| { support::response(invocation, host::filesystem_read(invocation, &deps.runtime).await) },
        "filesystem_list" => |invocation, deps| { support::response(invocation, host::filesystem_list(invocation, &deps.runtime).await) },
        "filesystem_search_text" => |invocation, deps| { support::response(invocation, host::filesystem_search_text(invocation, &deps.runtime).await) },
        "filesystem_write" => |invocation, deps| { support::response(invocation, host::filesystem_write(invocation, &deps.runtime).await) },
        "filesystem_edit" => |invocation, deps| { support::response(invocation, host::filesystem_edit(invocation, &deps.runtime).await) },
        "process_run" => |invocation, deps| { support::response(invocation, host::process_run(invocation, &deps.runtime).await) },
        "web_fetch" => |invocation, deps| { support::response(invocation, host::web_fetch(invocation, &deps.runtime).await) },
        "session_set_title" => |invocation, deps| { support::response(invocation, core::session_set_title(invocation, deps).await) },
        "core_proposal_create" => |invocation, deps| { support::response(invocation, core::core_proposal_create(invocation, deps).await) },
        "core_proposal_list" => |invocation, deps| { support::response(invocation, core::core_proposal_list(invocation, deps).await) },
        "core_proposal_inspect" => |invocation, deps| { support::response(invocation, core::core_proposal_inspect(invocation, deps).await) },
        "core_proposal_apply" => |invocation, deps| { support::response(invocation, core::core_proposal_apply(invocation, deps).await) },
        "upsert" => |invocation, deps| { support::response(invocation, authoring::upsert(invocation, deps).await) },
        "discover" => |invocation, deps| { support::response(invocation, discovery::discover(invocation, deps).await) },
        "list" => |invocation, deps| { support::response(invocation, discovery::list(invocation, deps).await) },
        "inspect" => |invocation, deps| { support::response(invocation, discovery::inspect(invocation, deps).await) },
        "invoke" => |invocation, deps| { invocation::invoke_worker(invocation, deps).await },
        "await" => |invocation, deps| { support::response(invocation, invocation::await_worker(invocation, deps).await) },
        "result_read" => |invocation, deps| { support::response(invocation, invocation::read_worker_result(invocation, deps).await) },
        "result_projection" => |invocation, deps| { support::response(invocation, invocation::project_worker_results(invocation, deps).await) },
        "detach" => |invocation, deps| { support::response(invocation, invocation::detach_worker_invocation(invocation, deps).await) },
        "cancel" => |invocation, deps| { support::response(invocation, invocation::cancel_worker_invocation(invocation, deps).await) },
        "stop" => |invocation, deps| { support::response(invocation, invocation::stop_worker(invocation, deps).await) },
        "disable" => |invocation, deps| { support::response(invocation, invocation::set_enabled(invocation, deps, false).await) },
        "enable" => |invocation, deps| { support::response(invocation, invocation::set_enabled(invocation, deps, true).await) },
        "rollback" => |invocation, deps| { support::response(invocation, invocation::rollback(invocation, deps).await) },
        "retire" => |invocation, deps| { support::response(invocation, invocation::retire(invocation, deps).await) },
        "purge" => |invocation, deps| { support::response(invocation, invocation::purge(invocation, deps).await) },
        "inbox" => |invocation, deps| { support::response(invocation, inbox::inbox(invocation, deps).await) },
        "inbox_attach" => |invocation, deps| { support::response(invocation, inbox::inbox_attach(invocation, deps).await) },
        "runs" => |invocation, deps| { support::response(invocation, inbox::runs(invocation, deps).await) },
        "webhook_rotate" => |invocation, deps| { support::response(invocation, webhook::rotate_webhook(invocation, deps).await) },
        "stop_all" => |invocation, deps| { support::response(invocation, invocation::stop_all(invocation, deps).await) },
        "context_summary" => |invocation, deps| { support::response(invocation, core::context_summary(invocation, deps).await) },
        "session_title" => |invocation, deps| { support::response(invocation, core::session_title(invocation, deps).await) },
        "worker_relevance" => |invocation, deps| { support::response(invocation, core::worker_relevance(invocation, deps).await) },
        "surface_snapshot" => |invocation, deps| { support::response(invocation, core::engine_surface_snapshot(invocation, deps).await) },
        "webhook_invoke" => |invocation, deps| { support::response(invocation, webhook::webhook(invocation, deps).await) },
    ];
}
