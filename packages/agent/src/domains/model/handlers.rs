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
                let _ = invocation;
                routing::list_models(deps).await
            },
            "switch" => |invocation, deps| {
                routing::switch_model(&invocation.payload, deps).await
            },
        ];
    }
}
