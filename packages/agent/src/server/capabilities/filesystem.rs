use super::*;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &EngineCapabilityDeps,
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
    _deps: &EngineCapabilityDeps,
) -> Result<Value, CapabilityError> {
    let home = crate::core::paths::home_dir();
    let path = opt_string(params, "path").unwrap_or(home);
    let show_hidden = opt_bool(params, "showHidden").unwrap_or(false);
    run_blocking_task("filesystem::list_dir", move || {
        filesystem_service::list_dir(&path, show_hidden)
    })
    .await
}

async fn filesystem_get_home_value(_deps: &EngineCapabilityDeps) -> Result<Value, CapabilityError> {
    let home = crate::core::paths::home_dir();
    run_blocking_task("filesystem::get_home", move || {
        Ok(filesystem_service::get_home(&home))
    })
    .await
}

async fn file_read_value(
    params: Option<&Value>,
    _deps: &EngineCapabilityDeps,
) -> Result<Value, CapabilityError> {
    let path = require_string_param(params, "path")?;
    run_blocking_task("filesystem::read_file", move || {
        filesystem_service::read_file(&path)
    })
    .await
}

async fn filesystem_create_dir_value(
    params: Option<&Value>,
    _deps: &EngineCapabilityDeps,
) -> Result<Value, CapabilityError> {
    let path = require_string_param(params, "path")?;
    run_blocking_task("filesystem::create_dir", move || {
        filesystem_service::create_dir(&path)
    })
    .await
}
