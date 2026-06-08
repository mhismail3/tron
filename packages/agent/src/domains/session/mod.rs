//! session domain worker.
//!
//! This module owns canonical function execution for the session namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.
//! Lifecycle, history, reconstruction, archive/delete, and export operation
//! bodies live in `operations`; command/query/reconstruct services remain
//! nearby and take the narrowed `SessionDeps` bundle. `commands/` is split by
//! lifecycle action. The prompt context is owned by the agent runtime and
//! primitive state; this domain does not preload external policy planes.
//! `session::list` is the server-owned session-list query for clients and
//! supports domain-local filtering and pagination through the session event
//! store. Its user-visible filter intentionally hides abandoned chat drafts
//! that contain only the root `session.start` event, while preserving direct
//! reconstruction and export by session ID.

pub(crate) mod contract;
pub mod event_store;
pub(crate) mod operations;

use std::sync::Arc;

use crate::domains::agent::runner::orchestrator::orchestrator::Orchestrator;
use crate::domains::agent::runner::orchestrator::session_manager::SessionManager;
use crate::domains::bindings::operation_bindings;
use crate::domains::session::event_store::EventStore;
use crate::domains::worker::DomainRegistrationContext;
use crate::domains::worker::DomainWorkerModule;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) event_store: Arc<EventStore>,
    pub(super) orchestrator: Arc<Orchestrator>,
    pub(super) session_manager: Arc<SessionManager>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            event_store: deps.event_store.clone(),
            orchestrator: deps.orchestrator.clone(),
            session_manager: deps.session_manager.clone(),
        }
    }

    #[cfg(test)]
    pub(crate) fn from_test_context(
        ctx: &crate::shared::server::context::ServerRuntimeContext,
    ) -> Self {
        Self::from_engine(&DomainRegistrationContext::from_context(ctx))
    }
}

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        crate::domains::worker::domain_worker_module(
            "session",
            contract::STREAM_TOPICS,
            function_registrations(contract::capabilities()?, domain_deps)?,
        )
    }
}

pub(crate) mod commands;
pub(crate) mod queries;
pub(crate) mod reconstruct;

use operations::*;

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
