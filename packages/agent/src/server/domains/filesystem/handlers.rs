//! Operation binding for the filesystem worker.

use super::*;

pub(crate) async fn handle(
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
