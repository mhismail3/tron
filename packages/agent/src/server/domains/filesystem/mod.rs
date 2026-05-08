//! filesystem domain worker.
//!
//! This module owns canonical function execution for the filesystem namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.

pub(crate) mod contract;
pub(crate) mod spec;

use super::*;
#[derive(Clone)]
pub(crate) struct Deps;

impl Deps {
    pub(crate) fn from_engine(_deps: &EngineCapabilityDeps) -> Self {
        Self
    }
}

pub(crate) mod service;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let payload = &invocation.payload;
    match method {
        "filesystem::list_dir" => filesystem_list_dir_value(Some(payload), deps).await,
        "filesystem::get_home" => filesystem_get_home_value(deps).await,
        "filesystem::read_file" => file_read_value(Some(payload), deps).await,
        "filesystem::create_dir" => filesystem_create_dir_value(Some(payload), deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("filesystem method {method} is not engine-owned"),
        }),
    }
}

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
