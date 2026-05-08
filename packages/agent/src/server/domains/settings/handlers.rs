//! Operation binding for the settings worker.

use super::*;

pub(crate) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let payload = &invocation.payload;
    match method {
        "settings::get" => {
            serde_json::to_value(&deps.profile_runtime.current().settings).map_err(|error| {
                CapabilityError::Internal {
                    message: error.to_string(),
                }
            })
        }
        "settings::update" => settings_update_value(Some(payload), invocation, deps).await,
        "settings::reset_to_defaults" => settings_reset_to_defaults_value(deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("settings method {method} is not engine-owned"),
        }),
    }
}
