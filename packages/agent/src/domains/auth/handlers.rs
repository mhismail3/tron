//! Operation binding for the auth worker.

use super::Deps;
use super::credentials::*;
use super::oauth::*;
use crate::domains::registration::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "get" => |_invocation, deps| {
            auth_get(deps).await
        },
        "update" => |invocation, deps| {
            auth_update(invocation, deps).await
        },
        "clear" => |invocation, deps| {
            auth_clear(invocation, deps).await
        },
        "oauth_begin" => |invocation, deps| {
            auth_oauth_begin(&invocation.payload, deps).await
        },
        "oauth_complete" => |invocation, deps| {
            auth_oauth_complete(invocation, deps).await
        },
        "rename_account" => |invocation, deps| {
            auth_rename_account(invocation, deps).await
        },
        "set_active" => |invocation, deps| {
            auth_set_active(invocation, deps).await
        },
        "remove_account" => |invocation, deps| {
            auth_remove_account(invocation, deps).await
        },
        "remove_api_key" => |invocation, deps| {
            auth_remove_api_key(invocation, deps).await
        },
    ];
}
