//! Operation binding for the model/config workers.

use super::Deps;
use crate::domains::bindings::operation_bindings;

pub(crate) mod model {
    use super::{Deps, operation_bindings};
    use crate::domains::model::operations;

    operation_bindings! {
        deps = Deps;
        hidden = [];
        bindings = [
            "list" => |invocation, deps| {
                let allow_server_context = matches!(
                    invocation.causal_context.actor_kind,
                    crate::engine::ActorKind::Client
                );
                operations::list_models(&invocation.payload, deps, allow_server_context).await
            },
            "switch" => |invocation, deps| {
                operations::switch_model(&invocation.payload, deps).await
            },
        ];
    }
}

pub(crate) mod config {
    use super::{Deps, operation_bindings};
    use crate::domains::model::operations;

    operation_bindings! {
        deps = Deps;
        hidden = [];
        bindings = [
            "set_reasoning_level" => |invocation, deps| {
                operations::set_reasoning_level(&invocation.payload, deps).await
            },
        ];
    }
}
