//! notifications domain worker.
//!
//! This module owns canonical function execution for the notifications namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) use deps::Deps;

use crate::domains::notifications::inbox::NotificationInboxService;
use crate::domains::worker::DomainRegistrationContext;
use crate::domains::worker::DomainWorkerModule;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::errors::to_json_value;
use crate::shared::server::params::opt_string;
use crate::shared::server::params::opt_u64;
use crate::shared::server::params::require_string_param;
use serde_json::Value;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        crate::domains::worker::domain_worker_module(
            "notifications",
            contract::STREAM_TOPICS,
            handlers::function_registrations(contract::capabilities()?, domain_deps)?,
        )
    }
}

pub(crate) mod inbox;

async fn notifications_list_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let limit = opt_u64(params, "limit", 50).min(100);
    let pool = deps.event_store.pool().clone();
    let result = run_blocking_task("notifications::list", move || {
        let conn = pool.get().map_err(|error| CapabilityError::Internal {
            message: format!("Failed to get DB connection: {error}"),
        })?;
        NotificationInboxService::list(&conn, limit)
    })
    .await?;
    to_json_value(&result)
}

async fn notifications_mark_read_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let event_id = require_string_param(params, "eventId")?;
    let pool = deps.event_store.pool().clone();
    let result = run_blocking_task("notifications.mark_read", move || {
        let conn = pool.get().map_err(|error| CapabilityError::Internal {
            message: format!("Failed to get DB connection: {error}"),
        })?;
        NotificationInboxService::mark_read(&conn, &event_id)
    })
    .await?;
    to_json_value(&result)
}

async fn notifications_mark_all_read_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = opt_string(params, "sessionId");
    let pool = deps.event_store.pool().clone();
    let result = run_blocking_task("notifications.mark_all_read", move || {
        let conn = pool.get().map_err(|error| CapabilityError::Internal {
            message: format!("Failed to get DB connection: {error}"),
        })?;
        NotificationInboxService::mark_all_read(&conn, session_id.as_deref())
    })
    .await?;
    to_json_value(&result)
}
