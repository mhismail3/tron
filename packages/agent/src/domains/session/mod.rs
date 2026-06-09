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
//! | `contract` | Capability contracts and stream topic declarations. |
//! | `lifecycle` | Create, delete, fork, archive, and lifecycle operation wrappers. |
//! | `query` | Resume, list, head/state/history, export, and replay manifest operation wrappers. |
//! | `reconstruction` | Server-owned session reconstruction and in-flight reconciliation. |
//! | `replay` | Canonical `tron.replay.v1` manifest export and hashing. |
//! | `event_store` | Durable event/session/blob/log/trace storage and reconstruction primitives. |
//!
//! ## Invariants
//!
//! - The root module performs registration and dependency narrowing only.
//! - Lifecycle, query, and reconstruction bodies stay in their owner folders;
//!   no root `operations.rs` catch-all is retained.
//! - The prompt context is owned by the agent runtime and primitive state; this
//!   domain does not preload external policy planes.
//! `session::list` is the server-owned session-list query for clients and
//! supports domain-local filtering and pagination through the session event
//! store. Its user-visible filter intentionally hides abandoned chat drafts
//! that contain only the root `session.start` event, while preserving direct
//! reconstruction and export by session ID.

pub(crate) mod contract;
pub mod event_store;
pub(crate) mod lifecycle;
pub(crate) mod query;
pub(crate) mod reconstruction;
pub(crate) mod replay;

use std::sync::Arc;

use crate::domains::agent::r#loop::orchestrator::core::Orchestrator;
use crate::domains::agent::r#loop::orchestrator::session_manager::SessionManager;
use crate::domains::registration::bindings::operation_bindings;
use crate::domains::registration::worker::DomainRegistrationContext;
use crate::domains::registration::worker::DomainWorkerModule;
use crate::domains::session::event_store::EventStore;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) engine_host: crate::engine::EngineHostHandle,
    pub(super) event_store: Arc<EventStore>,
    pub(super) orchestrator: Arc<Orchestrator>,
    pub(super) session_manager: Arc<SessionManager>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            engine_host: deps.engine_host.clone(),
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
        crate::domains::registration::worker::domain_worker_module(
            "session",
            contract::STREAM_TOPICS,
            function_registrations(contract::capabilities()?, domain_deps)?,
        )
    }
}

use lifecycle::{
    session_archive_older_than_value, session_archive_value, session_create_value,
    session_delete_value, session_fork_value, session_unarchive_value,
};
use query::{
    session_export_value, session_get_head_value, session_get_history_value,
    session_get_state_value, session_list_value, session_replay_manifest_value,
    session_resume_value,
};
use reconstruction::session_reconstruct_value;

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
        "replay_manifest" => |invocation, deps| {
            session_replay_manifest_value(Some(&invocation.payload), deps).await
        },
    ];
}
