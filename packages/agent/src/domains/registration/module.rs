//! Domain function-composition data structures.
//!
//! This module is the setup-only boundary between the broad server runtime
//! context and domain-owned function sets. Runtime handlers receive the narrow
//! `Deps` type owned by their domain; this context is only used while building
//! registrations at startup. `DomainModule` groups one source-owned function
//! set; it is not a runtime worker or a second lifecycle plane. Startup tasks
//! and shutdown hooks remain under the registration lifecycle token until
//! complete engine setup succeeds.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;

use crate::app::lifecycle::shutdown::ShutdownCoordinator;
use crate::domains::agent::r#loop::orchestrator::core::Orchestrator;
use crate::domains::agent::r#loop::orchestrator::session_manager::SessionManager;
use crate::domains::model::responder::ModelResponderFactory;
use crate::domains::registration::catalog;
use crate::domains::session::event_store::EventStore;
use crate::domains::settings::SettingsRuntime;
use crate::engine::{FunctionDefinition, InProcessFunctionHandler, WorkerId};
use crate::shared::server::context::ServerRuntimeContext;

#[derive(Clone)]
pub(crate) struct DomainRegistrationContext {
    pub(crate) orchestrator: Arc<Orchestrator>,
    pub(crate) session_manager: Arc<SessionManager>,
    pub(crate) event_store: Arc<EventStore>,
    pub(crate) responder_factory: Option<Arc<dyn ModelResponderFactory>>,
    pub(crate) settings_runtime: Arc<SettingsRuntime>,
    pub(crate) shutdown_coordinator: Option<Arc<ShutdownCoordinator>>,
    pub(crate) origin: String,
    pub(crate) server_start_time: Instant,
    pub(crate) settings_path: PathBuf,
    pub(crate) auth_path: PathBuf,
    pub(crate) oauth_flows: Arc<
        tokio::sync::Mutex<
            std::collections::HashMap<String, crate::domains::auth::oauth::flows::PendingOAuthFlow>,
        >,
    >,
    pub(crate) engine_host: crate::engine::EngineHostHandle,
}

impl DomainRegistrationContext {
    pub(crate) fn from_context(ctx: &ServerRuntimeContext) -> Self {
        Self {
            orchestrator: Arc::clone(&ctx.orchestrator),
            session_manager: Arc::clone(&ctx.session_manager),
            event_store: Arc::clone(&ctx.event_store),
            responder_factory: ctx.responder_factory.clone(),
            settings_runtime: Arc::clone(&ctx.settings_runtime),
            shutdown_coordinator: ctx.shutdown_coordinator.clone(),
            origin: ctx.origin.clone(),
            server_start_time: ctx.server_start_time,
            settings_path: ctx.settings_path.clone(),
            auth_path: ctx.auth_path.clone(),
            oauth_flows: Arc::clone(&ctx.oauth_flows),
            engine_host: ctx.engine_host.clone(),
        }
    }
}

#[derive(Clone)]
pub(crate) struct DomainFunctionRegistration {
    pub(crate) definition: FunctionDefinition,
    pub(crate) handler: Arc<dyn InProcessFunctionHandler>,
    pub(crate) stream_topics: Vec<&'static str>,
}

pub(crate) struct DomainModule {
    pub(super) owner: WorkerId,
    pub(super) functions: Vec<DomainFunctionRegistration>,
    pub(super) stream_topics: &'static [&'static str],
}

pub(crate) fn domain_module(
    namespace: &'static str,
    stream_topics: &'static [&'static str],
    functions: Vec<DomainFunctionRegistration>,
) -> crate::engine::Result<DomainModule> {
    Ok(DomainModule {
        owner: catalog::worker_id(namespace)?,
        functions,
        stream_topics,
    })
}
