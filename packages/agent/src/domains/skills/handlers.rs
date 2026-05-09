//! Operation binding for the skills worker.

use super::{
    Deps, skill_activate_value, skill_active_value, skill_deactivate_value, skill_get_value,
    skill_list_value, skill_refresh_value,
};
use crate::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "list" => |invocation, deps| {
            Ok(skill_list_value(Some(&invocation.payload), deps))
        },
        "get" => |invocation, deps| {
            skill_get_value(Some(&invocation.payload), deps)
        },
        "refresh" => |invocation, deps| {
            skill_refresh_value(Some(&invocation.payload), deps).await
        },
        "activate" => |invocation, deps| {
            skill_activate_value(Some(&invocation.payload), deps)
        },
        "deactivate" => |invocation, deps| {
            skill_deactivate_value(Some(&invocation.payload), deps)
        },
        "active" => |invocation, deps| {
            skill_active_value(Some(&invocation.payload), deps)
        },
    ];
}
