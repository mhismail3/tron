use serde_json::Value;

use crate::domains::registration::bindings::operation_bindings;
use crate::engine::Invocation;
use crate::shared::server::errors::CapabilityError;

use super::{Deps, service};

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "request" => |invocation, deps| {
            request_approval(invocation, deps).await
        },
        "decide" => |invocation, deps| {
            decide_approval(invocation, deps).await
        },
        "check" => |invocation, deps| {
            check_approval(invocation, deps).await
        },
    ];
}

async fn request_approval(invocation: &Invocation, deps: &Deps) -> Result<Value, CapabilityError> {
    service::request_approval_value(&deps.engine_host, invocation, &invocation.payload).await
}

async fn decide_approval(invocation: &Invocation, deps: &Deps) -> Result<Value, CapabilityError> {
    service::decide_approval_value(&deps.engine_host, invocation, &invocation.payload).await
}

async fn check_approval(invocation: &Invocation, deps: &Deps) -> Result<Value, CapabilityError> {
    service::check_approval_value(&deps.engine_host, &invocation.payload).await
}
