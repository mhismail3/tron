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
use crate::shared::server::params::opt_u64;
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

async fn filesystem_write_file_value(
    params: Option<&Value>,
    _deps: &Deps,
) -> Result<Value, CapabilityError> {
    let path = require_string_param(params, "path")?;
    let content = require_string_param(params, "content")?;
    run_blocking_task("filesystem::write_file", move || {
        filesystem_service::write_file(&path, &content)
    })
    .await
}

async fn filesystem_edit_file_value(
    params: Option<&Value>,
    _deps: &Deps,
) -> Result<Value, CapabilityError> {
    let path = require_string_param(params, "path")?;
    let old_string = require_string_param(params, "oldString")?;
    let new_string = require_string_param(params, "newString")?;
    let replace_all = opt_bool(params, "replaceAll").unwrap_or(false);
    run_blocking_task("filesystem::edit_file", move || {
        filesystem_service::edit_file(&path, &old_string, &new_string, replace_all)
    })
    .await
}

async fn filesystem_apply_patch_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    filesystem_edit_file_value(params, deps).await
}

async fn filesystem_diff_value(
    params: Option<&Value>,
    _deps: &Deps,
) -> Result<Value, CapabilityError> {
    let path = require_string_param(params, "path")?;
    let new_content = require_string_param(params, "newContent")?;
    run_blocking_task("filesystem::diff", move || {
        filesystem_service::diff_file(&path, &new_content)
    })
    .await
}

async fn filesystem_find_value(
    params: Option<&Value>,
    _deps: &Deps,
) -> Result<Value, CapabilityError> {
    let home = crate::shared::paths::home_dir();
    let path = opt_string(params, "path").unwrap_or(home);
    let pattern = require_string_param(params, "pattern")?;
    let type_filter = opt_string(params, "type").unwrap_or_else(|| "all".to_owned());
    let max_depth = match opt_u64(params, "maxDepth", 0) {
        0 => None,
        value => usize::try_from(value).ok(),
    };
    let max_results = usize::try_from(opt_u64(params, "maxResults", 200)).unwrap_or(200);
    let exclude = params
        .and_then(|value| value.get("exclude"))
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(ToOwned::to_owned)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    run_blocking_task("filesystem::find", move || {
        filesystem_service::find(
            &path,
            &pattern,
            &type_filter,
            max_depth,
            max_results.min(10_000),
            &exclude,
        )
    })
    .await
}

async fn filesystem_search_text_value(
    params: Option<&Value>,
    _deps: &Deps,
) -> Result<Value, CapabilityError> {
    let home = crate::shared::paths::home_dir();
    let path = opt_string(params, "path").unwrap_or(home);
    let pattern = require_string_param(params, "pattern")?;
    let file_pattern = opt_string(params, "filePattern");
    let context = usize::try_from(opt_u64(params, "context", 0))
        .unwrap_or(0)
        .min(20);
    let max_results = usize::try_from(opt_u64(params, "maxResults", 100))
        .unwrap_or(100)
        .min(10_000);
    run_blocking_task("filesystem::search_text", move || {
        filesystem_service::search_text(
            &path,
            &pattern,
            file_pattern.as_deref(),
            context,
            max_results,
        )
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
