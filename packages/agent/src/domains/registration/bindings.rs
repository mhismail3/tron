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
use crate::shared::server::error_mapping::tool_error_to_engine;
use crate::shared::server::errors::ToolError;

pub(crate) type OperationFuture<'a> = BoxFuture<'a, Result<Value, ToolError>>;

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
            let handler = handler_for_definition(&definition, deps.clone(), bindings.clone())?;
            Ok(DomainFunctionRegistration {
                definition,
                handler,
            })
        })
        .collect()
}

fn handler_for_definition<D>(
    definition: &FunctionDefinition,
    deps: D,
    bindings: Vec<OperationBinding<D>>,
) -> crate::engine::Result<Arc<dyn InProcessFunctionHandler>>
where
    D: Send + Sync + 'static,
{
    let full_id = definition.id.as_str();
    let operation = operation_key(definition);
    let binding = bindings
        .iter()
        .find(|binding| binding.operation_key == full_id)
        .or_else(|| {
            bindings
                .iter()
                .find(|binding| binding.operation_key == operation)
        })
        .cloned()
        .ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "function '{}' has no handler binding",
                definition.id
            ))
        })?;
    Ok(Arc::new(LocalOperationHandler { binding, deps }))
}

fn validate_bindings<D>(
    definitions: &[FunctionDefinition],
    bindings: &[OperationBinding<D>],
) -> crate::engine::Result<()> {
    let mut spec_ids = BTreeSet::new();
    for definition in definitions {
        if !spec_ids.insert(definition.id.as_str()) {
            return Err(EngineError::PolicyViolation(format!(
                "duplicate contract function id '{}'",
                definition.id
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
        let matches = definitions
            .iter()
            .filter(|definition| {
                if binding.operation_key.contains("::") {
                    definition.id.as_str() == binding.operation_key
                } else {
                    operation_key(definition) == binding.operation_key
                }
            })
            .count();
        if matches == 0 {
            return Err(EngineError::PolicyViolation(format!(
                "handler operation key '{}' has no domain contract",
                binding.operation_key
            )));
        }
        if matches > 1 {
            return Err(EngineError::PolicyViolation(format!(
                "handler operation key '{}' is ambiguous; use fully qualified function ids",
                binding.operation_key
            )));
        }
    }

    for definition in definitions {
        let full_id = definition.id.as_str();
        let operation = operation_key(definition);
        let exact_matches = bindings
            .iter()
            .filter(|binding| binding.operation_key == full_id)
            .count();
        let matches = if exact_matches > 0 {
            exact_matches
        } else {
            bindings
                .iter()
                .filter(|binding| {
                    !binding.operation_key.contains("::") && binding.operation_key == operation
                })
                .count()
        };
        if matches == 0 {
            return Err(EngineError::PolicyViolation(format!(
                "domain contract function '{}' has no handler binding",
                definition.id
            )));
        }
        if matches > 1 {
            return Err(EngineError::PolicyViolation(format!(
                "domain contract function '{}' has multiple handler bindings",
                definition.id
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
            .map_err(tool_error_to_engine)
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
        .expect("valid test tool")
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
                .contains("domain contract function 'dummy::two' has no handler binding"),
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

    #[test]
    fn fully_qualified_bindings_disambiguate_shared_operation_names() {
        let definitions = ["alpha::inspect", "beta::inspect"]
            .into_iter()
            .map(|function_id| {
                FunctionContract::new(function_id, "dummy", EffectClass::PureRead, RiskLevel::Low)
                    .build()
                    .expect("valid test function")
            })
            .collect::<Vec<_>>();
        let ambiguous = match function_registrations(
            definitions.clone(),
            DummyDeps,
            vec![binding("inspect")],
        ) {
            Ok(_) => panic!("ambiguous short binding must be rejected"),
            Err(error) => error,
        };
        assert!(ambiguous.to_string().contains("is ambiguous"));

        let registrations = function_registrations(
            definitions,
            DummyDeps,
            vec![binding("alpha::inspect"), binding("beta::inspect")],
        )
        .expect("fully qualified bindings are exact");
        assert_eq!(registrations.len(), 2);
    }
}
