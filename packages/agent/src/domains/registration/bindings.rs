//! Method-agnostic operation binding helpers for domain-local handlers.
//!
//! Domains own the operation tables that use this helper. This module only
//! provides the small runtime wrapper and completeness validation needed to
//! keep each `handlers.rs` declarative.

use std::collections::BTreeSet;
use std::sync::Arc;

use futures::future::BoxFuture;
use serde_json::Value;

use crate::domains::registration::composition::DomainFunctionRegistration;
use crate::engine::{EngineError, FunctionDefinition, InProcessFunctionHandler, Invocation};
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
    definitions: Vec<FunctionDefinition>,
    deps: D,
    bindings: Vec<OperationBinding<D>>,
) -> crate::engine::Result<Vec<DomainFunctionRegistration>>
where
    D: Clone + Send + Sync + 'static,
{
    validate_bindings(&definitions, &bindings)?;
    definitions
        .into_iter()
        .map(|definition| {
            let handler =
                handler_for_operation(operation_key(&definition), deps.clone(), bindings.clone())?;
            Ok(DomainFunctionRegistration {
                definition,
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
    definitions: &[FunctionDefinition],
    bindings: &[OperationBinding<D>],
) -> crate::engine::Result<()> {
    let mut spec_keys = BTreeSet::new();
    for definition in definitions {
        let operation_key = operation_key(definition);
        if !spec_keys.insert(operation_key) {
            return Err(EngineError::PolicyViolation(format!(
                "duplicate contract operation key '{}'",
                operation_key
            )));
        }
    }

    let mut binding_keys = BTreeSet::new();
    for binding in bindings {
        if !binding_keys.insert(binding.operation_key) {
            return Err(EngineError::PolicyViolation(format!(
                "duplicate handler operation key '{}'",
                binding.operation_key
            )));
        }
        if !spec_keys.contains(binding.operation_key) {
            return Err(EngineError::PolicyViolation(format!(
                "handler operation key '{}' has no domain contract",
                binding.operation_key
            )));
        }
    }

    for definition in definitions {
        let operation_key = operation_key(definition);
        if !binding_keys.contains(operation_key) {
            return Err(EngineError::PolicyViolation(format!(
                "domain contract operation key '{}' has no handler binding",
                operation_key
            )));
        }
    }
    Ok(())
}

fn operation_key(definition: &FunctionDefinition) -> &str {
    definition
        .id
        .as_str()
        .rsplit_once("::")
        .map_or(definition.id.as_str(), |(_, operation)| operation)
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
        pub(crate) fn bind_functions(
            definitions: Vec<$crate::engine::FunctionDefinition>,
            deps: $deps_ty,
        ) -> $crate::engine::Result<Vec<$crate::domains::registration::composition::DomainFunctionRegistration>> {
            $crate::domains::registration::bindings::function_registrations(
                definitions,
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
    };
}

pub(crate) use operation_bindings;

#[cfg(test)]
mod tests {
    use serde_json::Value;

    use super::*;
    use crate::domains::registration::contract::FunctionContract;
    use crate::engine::{EffectClass, RiskLevel};

    #[derive(Clone)]
    struct DummyDeps;

    fn definition(operation_key: &'static str) -> FunctionDefinition {
        FunctionContract::new(
            match operation_key {
                "one" => "dummy::one",
                "two" => "dummy::two",
                "hidden" => "dummy::hidden",
                other => panic!("unknown test operation key {other}"),
            },
            "dummy",
            EffectClass::PureRead,
            RiskLevel::Low,
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
            vec![definition("one"), definition("two")],
            DummyDeps,
            vec![binding("one")],
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
            vec![definition("one")],
            DummyDeps,
            vec![binding("one"), binding("two")],
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
}
