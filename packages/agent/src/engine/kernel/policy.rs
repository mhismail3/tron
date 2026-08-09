//! Engine substrate registration and invocation checks.
//!
//! This layer protects primitive runtime integrity: idempotency, schemas,
//! and visibility. It does not encode product
//! prompt policy.
//!
//! INVARIANT: internal functions are callable only by the engine-owned System
//! actor. Native-client functions additionally admit authenticated Client
//! actors but exclude Agent and Worker actors. Public functions admit all four
//! actor kinds; actor identity is evidence, not a grant hierarchy.

use crate::engine::catalog::discovery::{ActorContext, ActorKind};
use crate::engine::invocation::model::{CausalContext, Invocation};

use super::errors::{EngineError, Result};
use super::schema;
use super::types::{FunctionDefinition, FunctionVisibility};

/// Validate a function definition before registration.
pub fn validate_function_registration(function: &FunctionDefinition) -> Result<()> {
    if function.effect_class.requires_idempotency() && function.idempotency.is_none() {
        return Err(EngineError::PolicyViolation(format!(
            "mutating function {} requires idempotency",
            function.id
        )));
    }
    if let Some(schema) = &function.request_schema {
        schema::validate_schema_definition(&function.id, "request", schema)?;
    }
    if let Some(schema) = &function.response_schema {
        schema::validate_schema_definition(&function.id, "response", schema)?;
    }

    Ok(())
}

/// Validate invocation policy.
pub fn validate_invocation(function: &FunctionDefinition, invocation: &Invocation) -> Result<()> {
    validate_invocation_contract(function, invocation)
}

fn validate_invocation_contract(
    function: &FunctionDefinition,
    invocation: &Invocation,
) -> Result<()> {
    let actor = actor_from_causal_context(&invocation.causal_context);
    if !is_visible_to_actor(function, &actor) {
        return Err(EngineError::PolicyViolation(format!(
            "function {} is not visible to actor {}",
            function.id, invocation.causal_context.actor_id
        )));
    }

    if function.effect_class.is_mutating() && invocation.causal_context.idempotency_key.is_none() {
        return Err(EngineError::PolicyViolation(format!(
            "mutating invocation of {} requires an idempotency key",
            function.id
        )));
    }

    Ok(())
}

/// Whether a function is visible to the actor for discovery.
#[must_use]
pub fn is_visible_to_actor(function: &FunctionDefinition, actor: &ActorContext) -> bool {
    match function.visibility {
        FunctionVisibility::Public => true,
        FunctionVisibility::NativeClient => {
            matches!(actor.actor_kind, ActorKind::Client | ActorKind::System)
        }
        FunctionVisibility::Internal => actor.actor_kind == ActorKind::System,
    }
}

fn actor_from_causal_context(context: &CausalContext) -> ActorContext {
    ActorContext {
        actor_id: context.actor_id.clone(),
        actor_kind: context.actor_kind.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::{ActorId, EffectClass, FunctionId, WorkerId};

    #[test]
    fn internal_visibility_requires_runtime_actor_kind() {
        let function = FunctionDefinition::new(
            FunctionId::new("alpha::hidden").expect("function id"),
            WorkerId::new("alpha").expect("worker id"),
            "hidden function",
            FunctionVisibility::Internal,
            EffectClass::PureRead,
        );
        let actor = |kind| ActorContext::new(ActorId::new("actor").expect("actor id"), kind);

        assert!(!is_visible_to_actor(&function, &actor(ActorKind::Client)));
        assert!(!is_visible_to_actor(&function, &actor(ActorKind::Agent)));
        assert!(!is_visible_to_actor(&function, &actor(ActorKind::Worker)));
        assert!(is_visible_to_actor(&function, &actor(ActorKind::System)));
    }

    #[test]
    fn native_client_visibility_excludes_model_backed_actors() {
        let function = FunctionDefinition::new(
            FunctionId::new("alpha::native").expect("function id"),
            WorkerId::new("alpha").expect("worker id"),
            "native client function",
            FunctionVisibility::NativeClient,
            EffectClass::PureRead,
        );
        let actor = |kind| ActorContext::new(ActorId::new("actor").expect("actor id"), kind);

        assert!(is_visible_to_actor(&function, &actor(ActorKind::Client)));
        assert!(!is_visible_to_actor(&function, &actor(ActorKind::Agent)));
        assert!(!is_visible_to_actor(&function, &actor(ActorKind::Worker)));
        assert!(is_visible_to_actor(&function, &actor(ActorKind::System)));
    }
}
