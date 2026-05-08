//! filesystem domain worker.
//!
//! This module owns canonical function execution for the filesystem namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) use deps::Deps;
pub(super) use handlers::handle;

use super::*;

pub(crate) fn worker_module(
    deps: &DomainSetupContext,
) -> crate::engine::Result<DomainWorkerModule> {
    super::domain_worker_module(
        "filesystem",
        contract::STREAM_TOPICS,
        contract::capabilities()?,
        Deps::from_engine(deps),
        super::filesystem_handler,
    )
}

pub(crate) mod service;

async fn filesystem_list_dir_value(
    params: Option<&Value>,
    _deps: &Deps,
) -> Result<Value, CapabilityError> {
    let home = crate::core::paths::home_dir();
    let path = opt_string(params, "path").unwrap_or(home);
    let show_hidden = opt_bool(params, "showHidden").unwrap_or(false);
    run_blocking_task("filesystem::list_dir", move || {
        filesystem_service::list_dir(&path, show_hidden)
    })
    .await
}

async fn filesystem_get_home_value(_deps: &Deps) -> Result<Value, CapabilityError> {
    let home = crate::core::paths::home_dir();
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
