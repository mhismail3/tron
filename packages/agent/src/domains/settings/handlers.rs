//! Operation binding for the settings worker.

use super::{Deps, settings_reset_to_defaults_value, settings_update_value};
use crate::domains::bindings::operation_bindings;
use crate::shared::server::errors::CapabilityError;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "get" => |_invocation, deps| {
            serde_json::to_value(&deps.profile_runtime.current().settings).map_err(|error| {
                CapabilityError::Internal {
                    message: format!("Failed to serialize settings: {error}"),
                }
            })
        },
        "update" => |invocation, deps| {
            settings_update_value(Some(&invocation.payload), deps).await
        },
        "reset_to_defaults" => |_invocation, deps| {
            settings_reset_to_defaults_value(deps).await
        },
    ];
}
