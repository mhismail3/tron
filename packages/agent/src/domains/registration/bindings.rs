//! Method-agnostic operation binding helpers for domain-local handlers.
//!
//! Domains own the operation tables that use this helper. This module only
//! provides the small runtime wrapper and completeness validation needed to
//! keep each `handlers.rs` declarative.

use std::collections::BTreeSet;
use std::sync::Arc;

use futures::future::BoxFuture;
use serde_json::Value;

use crate::domains::registration::catalog::{CapabilitySpec, function_definition_for_capability};
use crate::domains::registration::worker::DomainFunctionRegistration;
use crate::engine::{EngineError, InProcessFunctionHandler, Invocation};
use crate::shared::server::error_mapping::capability_error_to_engine;
use crate::shared::server::errors::CapabilityError;

pub(crate) type OperationFuture<'a> = BoxFuture<'a, Result<Value, CapabilityError>>;

type OperationHandler<D> =
    Arc<dyn for<'a> Fn(&'a Invocation, &'a D) -> OperationFuture<'a> + Send + Sync>;

pub(crate) struct OperationBinding<D> {
    operation_key: &'static str,
    handler: OperationHandler<D>,
}

impl<D> Clone for OperationBinding<D> {
    fn clone(&self) -> Self {
        Self {
            operation_key: self.operation_key,
            handler: Arc::clone(&self.handler),
        }
    }
}

impl<D> OperationBinding<D> {
    pub(crate) fn new<F>(operation_key: &'static str, handler: F) -> Self
    where
        F: for<'a> Fn(&'a Invocation, &'a D) -> OperationFuture<'a> + Send + Sync + 'static,
    {
        Self {
            operation_key,
            handler: Arc::new(handler),
        }
    }
}

pub(crate) fn function_registrations<D>(
    specs: Vec<CapabilitySpec>,
    deps: D,
    bindings: Vec<OperationBinding<D>>,
    hidden_operation_keys: &[&'static str],
) -> crate::engine::Result<Vec<DomainFunctionRegistration>>
where
    D: Clone + Send + Sync + 'static,
{
    validate_bindings(&specs, &bindings, hidden_operation_keys)?;
    specs
        .into_iter()
        .map(|spec| {
            let handler =
                handler_for_operation(&spec.operation_key, deps.clone(), bindings.clone())?;
            Ok(DomainFunctionRegistration {
                definition: function_definition_for_capability(&spec),
                handler,
            })
        })
        .collect()
}

pub(crate) fn handler_for_operation<D>(
    operation_key: &str,
    deps: D,
    bindings: Vec<OperationBinding<D>>,
) -> crate::engine::Result<Arc<dyn InProcessFunctionHandler>>
where
    D: Send + Sync + 'static,
{
    let binding = bindings
        .into_iter()
        .find(|binding| binding.operation_key == operation_key)
        .ok_or_else(|| {
            EngineError::PolicyViolation(format!("operation key '{operation_key}' is not bound"))
        })?;
    Ok(Arc::new(LocalOperationHandler { binding, deps }))
}

fn validate_bindings<D>(
    specs: &[CapabilitySpec],
    bindings: &[OperationBinding<D>],
    hidden_operation_keys: &[&'static str],
) -> crate::engine::Result<()> {
    let mut spec_keys = BTreeSet::new();
    for spec in specs {
        if !spec_keys.insert(spec.operation_key.as_str()) {
            return Err(EngineError::PolicyViolation(format!(
                "duplicate contract operation key '{}'",
                spec.operation_key
            )));
        }
    }

    let hidden_keys = hidden_operation_keys
        .iter()
        .copied()
        .collect::<BTreeSet<_>>();
    let mut binding_keys = BTreeSet::new();
    for binding in bindings {
        if !binding_keys.insert(binding.operation_key) {
            return Err(EngineError::PolicyViolation(format!(
                "duplicate handler operation key '{}'",
                binding.operation_key
            )));
        }
        if !spec_keys.contains(binding.operation_key)
            && !hidden_keys.contains(binding.operation_key)
        {
            return Err(EngineError::PolicyViolation(format!(
                "handler operation key '{}' has no domain contract or hidden function",
                binding.operation_key
            )));
        }
    }

    for spec in specs {
        if !binding_keys.contains(spec.operation_key.as_str()) {
            return Err(EngineError::PolicyViolation(format!(
                "domain contract operation key '{}' has no handler binding",
                spec.operation_key
            )));
        }
    }
    for hidden in hidden_operation_keys {
        if !binding_keys.contains(hidden) {
            return Err(EngineError::PolicyViolation(format!(
                "hidden operation key '{hidden}' has no handler binding"
            )));
        }
    }
    Ok(())
}

struct LocalOperationHandler<D> {
    binding: OperationBinding<D>,
    deps: D,
}

#[async_trait::async_trait]
impl<D> InProcessFunctionHandler for LocalOperationHandler<D>
where
    D: Send + Sync + 'static,
{
    async fn invoke(&self, invocation: Invocation) -> Result<Value, EngineError> {
        (self.binding.handler)(&invocation, &self.deps)
            .await
            .map_err(capability_error_to_engine)
    }
}

macro_rules! operation_bindings {
    (
        deps = $deps_ty:ty;
        hidden = [];
        bindings = [
            $(
                $operation_key:expr => |$invocation:ident, $deps:ident| $body:block
            ),+ $(,)?
        ];
    ) => {
        pub(crate) fn function_registrations(
            specs: Vec<$crate::domains::registration::catalog::CapabilitySpec>,
            deps: Deps,
        ) -> $crate::engine::Result<Vec<$crate::domains::registration::worker::DomainFunctionRegistration>> {
            $crate::domains::registration::bindings::function_registrations(
                specs,
                deps,
                operation_bindings(),
                &[],
            )
        }

        fn operation_bindings() -> Vec<$crate::domains::registration::bindings::OperationBinding<$deps_ty>> {
            vec![
                $(
                    $crate::domains::registration::bindings::OperationBinding::new(
                        $operation_key,
                        |$invocation: &$crate::engine::Invocation, $deps: &$deps_ty| {
                            std::boxed::Box::pin(async move $body)
                        },
                    )
                ),+
            ]
        }
    };

    (
        deps = $deps_ty:ty;
        hidden = [$($hidden_key:expr),* $(,)?];
        bindings = [
            $(
                $operation_key:expr => |$invocation:ident, $deps:ident| $body:block
            ),+ $(,)?
        ];
    ) => {
        pub(crate) fn function_registrations(
            specs: Vec<$crate::domains::registration::catalog::CapabilitySpec>,
            deps: Deps,
        ) -> $crate::engine::Result<Vec<$crate::domains::registration::worker::DomainFunctionRegistration>> {
            $crate::domains::registration::bindings::function_registrations(
                specs,
                deps,
                operation_bindings(),
                HIDDEN_OPERATION_KEYS,
            )
        }

        pub(crate) fn handler_for_operation(
            operation_key: impl AsRef<str>,
            deps: Deps,
        ) -> $crate::engine::Result<std::sync::Arc<dyn $crate::engine::InProcessFunctionHandler>> {
            $crate::domains::registration::bindings::handler_for_operation(
                operation_key.as_ref(),
                deps,
                operation_bindings(),
            )
        }

        fn operation_bindings() -> Vec<$crate::domains::registration::bindings::OperationBinding<$deps_ty>> {
            vec![
                $(
                    $crate::domains::registration::bindings::OperationBinding::new(
                        $operation_key,
                        |$invocation: &$crate::engine::Invocation, $deps: &$deps_ty| {
                            std::boxed::Box::pin(async move $body)
                        },
                    )
                ),+
            ]
        }

        const HIDDEN_OPERATION_KEYS: &[&str] = &[$($hidden_key),*];
    };
}

pub(crate) use operation_bindings;

#[cfg(test)]
mod tests {
    use serde_json::Value;

    use super::*;
    use crate::domains::registration::contract::CapabilityContract;
    use crate::engine::{EffectClass, RiskLevel};

    #[derive(Clone)]
    struct DummyDeps;

    fn spec(operation_key: &'static str) -> crate::domains::registration::catalog::CapabilitySpec {
        CapabilityContract::new(
            match operation_key {
                "one" => "dummy::one",
                "two" => "dummy::two",
                "hidden" => "dummy::hidden",
                other => panic!("unknown test operation key {other}"),
            },
            "dummy",
            EffectClass::PureRead,
            RiskLevel::Low,
            Some("dummy.read"),
        )
        .build()
        .expect("valid test capability")
    }

    fn binding(operation_key: &'static str) -> OperationBinding<DummyDeps> {
        OperationBinding::new(operation_key, |_invocation, _deps| {
            Box::pin(async { Ok(Value::Null) })
        })
    }

    #[test]
    fn registrations_require_every_contract_to_have_one_binding() {
        let err = match function_registrations(
            vec![spec("one"), spec("two")],
            DummyDeps,
            vec![binding("one")],
            &[],
        ) {
            Ok(_) => panic!("missing binding must be rejected"),
            Err(err) => err,
        };
        assert!(
            err.to_string()
                .contains("domain contract operation key 'two' has no handler binding"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn registrations_reject_uncontracted_bindings() {
        let err = match function_registrations(
            vec![spec("one")],
            DummyDeps,
            vec![binding("one"), binding("two")],
            &[],
        ) {
            Ok(_) => panic!("extra binding must be rejected"),
            Err(err) => err,
        };
        assert!(
            err.to_string()
                .contains("handler operation key 'two' has no domain contract"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn registrations_accept_hidden_bindings_when_declared() {
        let regs = function_registrations(
            vec![spec("one")],
            DummyDeps,
            vec![binding("one"), binding("hidden")],
            &["hidden"],
        )
        .expect("hidden binding should be allowed when declared");
        assert_eq!(regs.len(), 1);
    }
}
