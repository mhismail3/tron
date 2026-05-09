//! filesystem domain worker.
//!
//! This module owns canonical function execution for the filesystem namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) use deps::Deps;

use crate::domains::filesystem::service as filesystem_service;
use crate::domains::worker::DomainRegistrationContext;
use crate::domains::worker::DomainWorkerModule;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::params::opt_bool;
use crate::shared::server::params::opt_string;
use crate::shared::server::params::require_string_param;
use serde_json::Value;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        crate::domains::worker::domain_worker_module(
            "filesystem",
            contract::STREAM_TOPICS,
            handlers::function_registrations(contract::capabilities()?, domain_deps)?,
        )
    }
}

pub(crate) mod service;

async fn filesystem_list_dir_value(
    params: Option<&Value>,
    _deps: &Deps,
) -> Result<Value, CapabilityError> {
    let home = crate::shared::paths::home_dir();
    let path = opt_string(params, "path").unwrap_or(home);
    let show_hidden = opt_bool(params, "showHidden").unwrap_or(false);
    run_blocking_task("filesystem::list_dir", move || {
        filesystem_service::list_dir(&path, show_hidden)
    })
    .await
}

async fn filesystem_get_home_value(_deps: &Deps) -> Result<Value, CapabilityError> {
    let home = crate::shared::paths::home_dir();
    run_blocking_task("filesystem::get_home", move || {
        Ok(filesystem_service::get_home(&home))
    })
    .await
}

async fn file_read_value(params: Option<&Value>, _deps: &Deps) -> Result<Value, CapabilityError> {
    let path = require_string_param(params, "path")?;
    run_blocking_task("filesystem::read_file", move || {
        filesystem_service::read_file(&path)
    })
    .await
}

async fn filesystem_create_dir_value(
    params: Option<&Value>,
    _deps: &Deps,
) -> Result<Value, CapabilityError> {
    let path = require_string_param(params, "path")?;
    run_blocking_task("filesystem::create_dir", move || {
        filesystem_service::create_dir(&path)
    })
    .await
}
