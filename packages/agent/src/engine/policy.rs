//! Non-bypassable Phase 1 engine policy checks.

use super::discovery::{ActorContext, ActorKind};
use super::errors::{EngineError, Result};
use super::invocation::{CausalContext, Invocation};
use super::schema;
use super::types::{
    DeliveryMode, FunctionDefinition, TriggerDefinition, TriggerTypeDefinition, VisibilityScope,
};

/// Delegation-only authority scope used by engine internals to execute hidden
/// apply functions while preserving the original actor in the causal ledger.
pub const ENGINE_INTERNAL_INVOKE_SCOPE: &str = "engine.internal.invoke";

/// Validate a function definition before registration.
pub fn validate_function_registration(function: &FunctionDefinition) -> Result<()> {
    if function.effect_class.requires_idempotency() && function.idempotency.is_none() {
        return Err(EngineError::PolicyViolation(format!(
            "mutating function {} requires idempotency",
            function.id
        )));
    }

    if function.visibility.is_agent_visible() {
        if function
            .effect_class
            .requires_approval_for_agent_visibility()
            && !function.required_authority.approval_required
        {
            return Err(EngineError::PolicyViolation(format!(
                "irreversible agent-visible function {} requires approval metadata",
                function.id
            )));
        }
    }

    if function.allowed_delivery_modes.is_empty() {
        return Err(EngineError::PolicyViolation(format!(
            "function {} must allow at least one delivery mode",
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

/// Validate a trigger definition before registration.
pub fn validate_trigger_registration(
    trigger: &TriggerDefinition,
    trigger_type: &TriggerTypeDefinition,
    function: &FunctionDefinition,
) -> Result<()> {
    if !trigger_type
        .allowed_delivery_modes
        .contains(&trigger.delivery_mode)
    {
        return Err(EngineError::DeliveryModeNotAllowed {
            function_id: function.id.to_string(),
            mode: trigger.delivery_mode.as_str(),
        });
    }
    if !function
        .allowed_delivery_modes
        .contains(&trigger.delivery_mode)
    {
        return Err(EngineError::DeliveryModeNotAllowed {
            function_id: function.id.to_string(),
            mode: trigger.delivery_mode.as_str(),
        });
    }
    if let Some(target_revision) = trigger.target_revision {
        if target_revision != function.revision {
            return Err(EngineError::StaleFunctionRevision {
                function_id: function.id.to_string(),
                expected: target_revision.0,
                actual: function.revision.0,
            });
        }
    }
    Ok(())
}

/// Validate invocation policy.
pub fn validate_invocation(function: &FunctionDefinition, invocation: &Invocation) -> Result<()> {
    if invocation.delivery_mode != DeliveryMode::Sync {
        return Err(EngineError::UnsupportedDeliveryMode {
            mode: invocation.delivery_mode.as_str(),
        });
    }

    let actor = actor_from_causal_context(&invocation.causal_context);
    if !is_visible_to_actor(function, Some(&actor)) {
        return Err(EngineError::PolicyViolation(format!(
            "function {} is not visible to actor {}",
            function.id, invocation.causal_context.actor_id
        )));
    }

    if !function
        .allowed_delivery_modes
        .contains(&invocation.delivery_mode)
    {
        return Err(EngineError::DeliveryModeNotAllowed {
            function_id: function.id.to_string(),
            mode: invocation.delivery_mode.as_str(),
        });
    }

    if !function.health.is_routable() {
        return Err(EngineError::NotRoutable {
            function_id: function.id.to_string(),
            reason: format!("health is {:?}", function.health),
        });
    }

    for scope in &function.required_authority.scopes {
        if !invocation.causal_context.has_scope(scope) {
            return Err(EngineError::PolicyViolation(format!(
                "missing required authority scope {scope} for {}",
                function.id
            )));
        }
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
pub fn is_visible_to_actor(function: &FunctionDefinition, actor: Option<&ActorContext>) -> bool {
    match function.visibility {
        VisibilityScope::Internal => actor
            .map(|ctx| {
                ctx.actor_kind.is_admin_like()
                    || ctx
                        .authority_scopes
                        .iter()
                        .any(|scope| scope == ENGINE_INTERNAL_INVOKE_SCOPE)
            })
            .unwrap_or(false),
        VisibilityScope::Session => actor
            .map(|ctx| {
                ctx.actor_kind.is_admin_like()
                    || matches!(
                        (
                            ctx.session_id.as_deref(),
                            function.provenance.session_id.as_deref()
                        ),
                        (Some(actor_session), Some(function_session))
                            if actor_session == function_session
                    )
            })
            .unwrap_or(false),
        VisibilityScope::Workspace => actor
            .map(|ctx| {
                ctx.actor_kind.is_admin_like()
                    || matches!(
                        (
                            ctx.workspace_id.as_deref(),
                            function.provenance.workspace_id.as_deref()
                        ),
                        (Some(actor_workspace), Some(function_workspace))
                            if actor_workspace == function_workspace
                    )
            })
            .unwrap_or(false),
        VisibilityScope::System => actor.is_some(),
        VisibilityScope::Client => actor
            .map(|ctx| {
                matches!(ctx.actor_kind, ActorKind::Client) || ctx.actor_kind.is_admin_like()
            })
            .unwrap_or(false),
        VisibilityScope::Worker => actor
            .map(|ctx| {
                matches!(ctx.actor_kind, ActorKind::Worker) || ctx.actor_kind.is_admin_like()
            })
            .unwrap_or(false),
        VisibilityScope::Admin => actor
            .map(|ctx| ctx.actor_kind.is_admin_like())
            .unwrap_or(false),
        VisibilityScope::Agent => actor
            .map(|ctx| matches!(ctx.actor_kind, ActorKind::Agent) || ctx.actor_kind.is_admin_like())
            .unwrap_or(false),
    }
}

fn actor_from_causal_context(context: &CausalContext) -> ActorContext {
    ActorContext {
        actor_id: context.actor_id.clone(),
        actor_kind: context.actor_kind.clone(),
        authority_grant_id: context.authority_grant_id.clone(),
        authority_scopes: context.authority_scopes.clone(),
        session_id: context.session_id.clone(),
        workspace_id: context.workspace_id.clone(),
    }
}
