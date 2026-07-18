//! Operation bindings for the native UI domain.

use super::{Deps, service};
use crate::domains::registration::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "validate_definition" => |invocation, deps| { service::validate_definition(invocation, deps).await },
        "create_preview" => |invocation, deps| { service::create_preview(invocation, deps).await },
        "activate_definition" => |invocation, deps| { service::activate_definition(invocation, deps).await },
        "list_revisions" => |invocation, deps| { service::list_revisions(invocation, deps).await },
        "rollback_definition" => |invocation, deps| { service::rollback_definition(invocation, deps).await },
        "get_surface" => |invocation, deps| { service::get_surface(invocation, deps).await },
        "reconstruct_surface" => |invocation, deps| { service::reconstruct_surface(invocation, deps).await },
        "dismiss_surface" => |invocation, deps| { service::dismiss_surface(invocation, deps).await },
        "register_client_catalog" => |invocation, deps| { service::register_client_catalog(invocation, deps).await },
        "dispatch_action" => |invocation, deps| { service::dispatch_action(invocation, deps).await },
    ];
}
