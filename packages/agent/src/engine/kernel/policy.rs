//! Engine substrate registration and invocation checks.
//!
//! This layer protects primitive runtime integrity: idempotency, schemas,
//! visibility, and routability. It does not encode product
//! prompt policy.
//!
//! INVARIANT: internal catalog visibility is derived from the authenticated
//! runtime actor kind; public clients, users, and agent contexts remain denied.

use crate::engine::catalog::discovery::{ActorContext, ActorKind};
use crate::engine::invocation::model::{CausalContext, Invocation};

use super::errors::{EngineError, Result};
use super::schema;
use super::types::{FunctionDefinition, VisibilityScope};

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

    if !function.health.is_routable() {
        return Err(EngineError::NotRoutable {
            function_id: function.id.to_string(),
            reason: format!("health is {:?}", function.health),
        });
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
        VisibilityScope::Internal => matches!(
            actor.actor_kind,
            ActorKind::Admin
                | ActorKind::System
                | ActorKind::Worker
                | ActorKind::Queue
                | ActorKind::Cron
        ),
        VisibilityScope::Session => {
            actor.actor_kind.is_admin_like()
                || matches!(
                    (
                        actor.session_id.as_deref(),
                        function.provenance.session_id.as_deref()
                    ),
                    (Some(actor_session), Some(function_session))
                        if actor_session == function_session
                )
        }
        VisibilityScope::Workspace => {
            actor.actor_kind.is_admin_like()
                || matches!(
                    (
                        actor.workspace_id.as_deref(),
                        function.provenance.workspace_id.as_deref()
                    ),
                    (Some(actor_workspace), Some(function_workspace))
                        if actor_workspace == function_workspace
                )
        }
        VisibilityScope::System => true,
        VisibilityScope::Client => {
            matches!(actor.actor_kind, ActorKind::Client) || actor.actor_kind.is_admin_like()
        }
        VisibilityScope::Worker => {
            matches!(actor.actor_kind, ActorKind::Worker) || actor.actor_kind.is_admin_like()
        }
        VisibilityScope::Admin => actor.actor_kind.is_admin_like(),
        VisibilityScope::Agent => {
            matches!(actor.actor_kind, ActorKind::Agent) || actor.actor_kind.is_admin_like()
        }
    }
}

fn actor_from_causal_context(context: &CausalContext) -> ActorContext {
    ActorContext {
        actor_id: context.actor_id.clone(),
        actor_kind: context.actor_kind.clone(),
        session_id: context.session_id.clone(),
        workspace_id: context.workspace_id.clone(),
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
            VisibilityScope::Internal,
            EffectClass::PureRead,
        );
        let actor = |kind| ActorContext::new(ActorId::new("actor").expect("actor id"), kind);

        assert!(!is_visible_to_actor(&function, &actor(ActorKind::Client)));
        assert!(!is_visible_to_actor(&function, &actor(ActorKind::User)));
        assert!(!is_visible_to_actor(&function, &actor(ActorKind::Agent)));
        assert!(is_visible_to_actor(&function, &actor(ActorKind::Worker)));
        assert!(is_visible_to_actor(&function, &actor(ActorKind::System)));
    }
}
