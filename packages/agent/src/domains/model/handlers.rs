//! Operation binding for the model/config workers.

use super::Deps;
use crate::domains::registration::bindings::operation_bindings;

pub(crate) mod model {
    use super::{Deps, operation_bindings};
    use crate::domains::model::routing;

    operation_bindings! {
        deps = Deps;
        hidden = [];
        bindings = [
            "list" => |invocation, deps| {
                let allow_server_context = matches!(
                    invocation.causal_context.actor_kind,
                    crate::engine::ActorKind::Client
                );
                routing::list_models(&invocation.payload, deps, allow_server_context).await
            },
            "switch" => |invocation, deps| {
                routing::switch_model(&invocation.payload, deps).await
            },
        ];
    }
}
