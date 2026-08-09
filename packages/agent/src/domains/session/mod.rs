//! Session domain worker.
//!
//! This module owns canonical function execution for the `session::*`
//! namespace and keeps domain contracts, services, and tests beside the worker
//! that uses them.
//!
//! ## Submodules
//!
//! | Module | Responsibility |
//! |--------|----------------|
//! | `contract` | Canonical function schemas and invocation contracts. |
//! | `lifecycle` | Create, delete, fork, archive, and lifecycle operation wrappers. |
//! | `query` | Resume, list, head/state/history, provider-context audit, readable delivery/wait state, export, and replay manifest operation wrappers. |
//! | `reconstruction` | Server-owned session reconstruction and in-flight reconciliation. |
//! | `replay` | Canonical `tron.replay.v2` manifest export, hashing, idempotency refs, and offline roundtrip harness. |
//! | `title` | Explicit title replacement, automatic compare-and-set, and live projection. |
//! | `event_store` | Durable event/session/blob/log storage and reconstruction primitives. |
//!
//! ## Invariants
//!
//! - The root module performs registration and dependency narrowing only.
//! - Lifecycle, query, and reconstruction bodies stay in their owner folders;
//!   no root `operations.rs` catch-all is retained.
//! - The prompt context is owned by the agent runtime and primitive state; this
//!   domain does not preload external policy planes.
//! - Closed `session::*` request contracts contain only fields consumed by the
//!   owning operation. Session/workspace provenance supplied by `/engine`
//!   remains transport context and is never duplicated as an ignored payload
//!   field.
//! - `session::context_requests` and `session::context_request_detail` are
//!   authenticated read-only projections over existing
//!   `model.provider_request` events. They do not invoke a model, hook, worker,
//!   or routing calculation and create no second context store or retention
//!   policy. V2 rows remain readable with provenance labeled unavailable.
//! - `session::reconstruct` preserves provider-request event identities and
//!   pagination cursors but defers their potentially large audit bodies. Its
//!   top-level metadata carries one bounded latest-request inventory; exact
//!   manifests remain available through the explicit detail/export owners.
//! - `session::agent_updates` is a bounded read projection over durable
//!   deliveries and waits. It does not claim mailboxes, run policy workers, or
//!   alter wake state.
//! `session::list` is the server-owned session-list query for clients and
//! supports bounded `(created_at, id)` keyset pagination beneath one opaque
//! server-issued `snapshotAsOf` boundary (with offset retained for older
//! clients). Snapshot and cursor ordering compares RFC 3339 instants at their
//! full nanosecond precision; SQLite floating-point date helpers are forbidden
//! on these boundaries because they can collapse distinct sessions. Mutable
//! activity never controls page membership, and list activity is projected by
//! one bounded batch query rather than one query per session. Its
//! user-visible filter intentionally hides abandoned chat drafts
//! that contain only the root `session.start` event, while preserving direct
//! reconstruction and export by session ID. Worker-owned agent sessions use
//! the same durable event custody with a reserved system tag: ordinary listings
//! exclude them, while exact reads remain available from worker-run audit links.
//! Graceful process shutdown never archives or ends retained sessions.

pub(crate) mod contract;
pub mod event_store;
pub(crate) mod lifecycle;
pub(crate) mod query;
pub(crate) mod reconstruction;
pub(crate) mod replay;
pub(crate) mod title;

use std::sync::Arc;

use crate::domains::agent::r#loop::orchestrator::core::Orchestrator;
use crate::domains::agent::r#loop::orchestrator::session_manager::SessionManager;
use crate::domains::registration::bindings::operation_bindings;
use crate::domains::registration::composition::{
    DomainFunctionRegistration, DomainRegistrationContext,
};
use crate::domains::session::event_store::EventStore;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) engine_host: crate::engine::EngineHostHandle,
    pub(super) event_store: Arc<EventStore>,
    pub(super) orchestrator: Arc<Orchestrator>,
    pub(super) session_manager: Arc<SessionManager>,
    pub(super) terminal_service: Arc<crate::domains::terminal::TerminalService>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            engine_host: deps.engine_host.clone(),
            event_store: deps.event_store.clone(),
            orchestrator: deps.orchestrator.clone(),
            session_manager: deps.session_manager.clone(),
            terminal_service: deps.terminal_service.clone(),
        }
    }

    #[cfg(test)]
    pub(crate) fn from_test_context(
        ctx: &crate::shared::server::context::ServerRuntimeContext,
    ) -> Self {
        Self::from_engine(&DomainRegistrationContext::from_context(ctx))
    }
}

pub(crate) fn function_registrations(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<Vec<DomainFunctionRegistration>> {
    bind_functions(contract::function_definitions()?, Deps::from_engine(deps))
}

use lifecycle::{
    session_archive_older_than_value, session_archive_value, session_create_value,
    session_delete_value, session_fork_value, session_unarchive_value,
};
use query::{
    session_agent_updates_value, session_context_request_detail_value,
    session_context_requests_value, session_export_value, session_get_head_value,
    session_get_history_value, session_get_state_value, session_list_value,
    session_replay_manifest_value, session_resume_value,
};
use reconstruction::session_reconstruct_value;
use title::session_set_title_value;

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
        "context_requests" => |invocation, deps| {
            session_context_requests_value(Some(&invocation.payload), deps).await
        },
        "context_request_detail" => |invocation, deps| {
            session_context_request_detail_value(Some(&invocation.payload), deps).await
        },
        "agent_updates" => |invocation, deps| {
            session_agent_updates_value(Some(&invocation.payload), deps).await
        },
        "set_title" => |invocation, deps| {
            session_set_title_value(invocation, deps).await
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
        "replay_manifest" => |invocation, deps| {
            session_replay_manifest_value(Some(&invocation.payload), deps).await
        },
    ];
}
