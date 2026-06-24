//! Engine substrate registration and invocation checks.
//!
//! This layer protects primitive runtime integrity: idempotency, schemas,
//! resource leases, compensation metadata, delivery modes, visibility, and
//! routability. It does not encode product prompt policy.
//!
//! INVARIANT: `engine.internal.invoke` is a trusted runtime scope, not public
//! authority. It can unlock internal catalog visibility only for engine-owned
//! runtime actor kinds; public clients, users, and agent contexts remain denied
//! even if they carry the raw string.

use crate::engine::catalog::discovery::{ActorContext, ActorKind};
use crate::engine::invocation::model::{
    CausalContext, Invocation, RUNTIME_METADATA_TRIGGER_DEPTH, RUNTIME_METADATA_TRIGGER_PATH,
};

use super::errors::{EngineError, Result};
use super::schema;
use super::types::{
    CompensationKind, DeliveryMode, EffectClass, FunctionDefinition, RiskLevel, TriggerDefinition,
    TriggerTypeDefinition, VisibilityScope,
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
    if !function.output_contract.is_enforceable() {
        return Err(EngineError::PolicyViolation(format!(
            "function {} declares an invalid durable output contract",
            function.id
        )));
    }

    if function.effect_class == EffectClass::IrreversibleSideEffect
        || (function.effect_class.is_mutating() && function.risk_level >= RiskLevel::High)
    {
        let Some(compensation) = &function.compensation else {
            return Err(EngineError::PolicyViolation(format!(
                "high-risk function {} requires a compensation contract",
                function.id
            )));
        };
        if compensation.kind != CompensationKind::None && !compensation.has_notes() {
            return Err(EngineError::PolicyViolation(format!(
                "high-risk function {} requires compensation notes",
                function.id
            )));
        }
    }

    if let Some(lease) = &function.resource_lease {
        if !function.effect_class.is_mutating() {
            return Err(EngineError::PolicyViolation(format!(
                "read function {} cannot require a resource lease",
                function.id
            )));
        }
        if !lease.exclusive {
            return Err(EngineError::PolicyViolation(format!(
                "function {} requested a non-exclusive resource lease; shared leases are deferred",
                function.id
            )));
        }
        if lease.ttl_ms <= 0 {
            return Err(EngineError::PolicyViolation(format!(
                "function {} resource lease ttl must be positive",
                function.id
            )));
        }
        if lease.resource_kind.trim().is_empty() || lease.resource_id_template.trim().is_empty() {
            return Err(EngineError::PolicyViolation(format!(
                "function {} resource lease kind/template must not be empty",
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
    if trigger.delivery_mode == DeliveryMode::Void && !is_void_loss_tolerant_target(function) {
        return Err(EngineError::PolicyViolation(format!(
            "Void trigger delivery for {} requires explicit loss-tolerant target metadata",
            function.id
        )));
    }
    Ok(())
}

fn is_void_loss_tolerant_target(function: &FunctionDefinition) -> bool {
    let explicitly_loss_tolerant = function
        .metadata
        .pointer("/delivery/voidLossTolerant")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false);
    explicitly_loss_tolerant
        && matches!(
            function.effect_class,
            EffectClass::PureRead
                | EffectClass::DeterministicCompute
                | EffectClass::AppendOnlyEvent
        )
        && function.risk_level <= RiskLevel::Low
}

/// Validate invocation policy.
pub fn validate_invocation(function: &FunctionDefinition, invocation: &Invocation) -> Result<()> {
    if invocation.delivery_mode != DeliveryMode::Sync {
        return Err(EngineError::UnsupportedDeliveryMode {
            mode: invocation.delivery_mode.as_str(),
        });
    }
    validate_invocation_contract(function, invocation)
}

/// Validate a trigger runtime target invocation.
pub(in crate::engine) fn validate_trigger_target_invocation(
    function: &FunctionDefinition,
    invocation: &Invocation,
) -> Result<()> {
    if invocation.delivery_mode == DeliveryMode::Void {
        if !is_trigger_void_invocation(invocation) {
            return Err(EngineError::UnsupportedDeliveryMode {
                mode: invocation.delivery_mode.as_str(),
            });
        }
        if !is_void_loss_tolerant_target(function) {
            return Err(EngineError::PolicyViolation(format!(
                "Void trigger delivery for {} requires explicit loss-tolerant target metadata",
                function.id
            )));
        }
    } else if invocation.delivery_mode != DeliveryMode::Sync {
        return Err(EngineError::UnsupportedDeliveryMode {
            mode: invocation.delivery_mode.as_str(),
        });
    }
    validate_invocation_contract(function, invocation)
}

fn validate_invocation_contract(
    function: &FunctionDefinition,
    invocation: &Invocation,
) -> Result<()> {
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

    if function.effect_class.is_mutating() && invocation.causal_context.idempotency_key.is_none() {
        return Err(EngineError::PolicyViolation(format!(
            "mutating invocation of {} requires an idempotency key",
            function.id
        )));
    }

    Ok(())
}

fn is_trigger_void_invocation(invocation: &Invocation) -> bool {
    invocation.delivery_mode == DeliveryMode::Void
        && invocation.causal_context.trigger_id.is_some()
        && invocation
            .causal_context
            .runtime_metadata(RUNTIME_METADATA_TRIGGER_DEPTH)
            .is_some()
        && invocation
            .causal_context
            .runtime_metadata(RUNTIME_METADATA_TRIGGER_PATH)
            .is_some()
}

/// Whether a function is visible to the actor for discovery.
#[must_use]
pub fn is_visible_to_actor(function: &FunctionDefinition, actor: Option<&ActorContext>) -> bool {
    match function.visibility {
        VisibilityScope::Internal => actor
            .map(|ctx| ctx.actor_kind.is_admin_like() || has_trusted_internal_invoke_scope(ctx))
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

fn has_trusted_internal_invoke_scope(ctx: &ActorContext) -> bool {
    ctx.has_scope(ENGINE_INTERNAL_INVOKE_SCOPE)
        && matches!(
            ctx.actor_kind,
            ActorKind::System | ActorKind::Worker | ActorKind::Queue | ActorKind::Cron
        )
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::{
        ActorId, AuthorityGrantId, AuthorityRequirement, CompensationContract, CompensationKind,
        EffectClass, FunctionId, IdempotencyContract, Provenance, ResourceLeaseRequirement,
        WorkerId,
    };

    fn high_risk_execute_function() -> FunctionDefinition {
        FunctionDefinition::new(
            FunctionId::new("capability::execute").expect("function id"),
            WorkerId::new("capability").expect("worker id"),
            "Execute primitive operation".to_owned(),
            VisibilityScope::System,
            EffectClass::ExternalSideEffect,
        )
        .with_risk(RiskLevel::High)
        .with_required_authority(AuthorityRequirement::scope("capability.execute"))
        .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
        .with_resource_lease(ResourceLeaseRequirement::exclusive_template(
            "capability_execute",
            "capability_execute:{sessionId}",
            60_000,
        ))
        .with_compensation(CompensationContract::new(
            CompensationKind::ManualOnly,
            "trace record is the audit boundary",
        ))
        .with_provenance(Provenance::system())
    }

    #[test]
    fn high_risk_registration_requires_compensation_not_prompt_metadata() {
        let function = high_risk_execute_function();

        validate_function_registration(&function)
            .expect("high-risk registration relies on idempotency, lease, and compensation");
    }

    #[test]
    fn internal_visibility_scope_requires_trusted_runtime_actor() {
        let function = FunctionDefinition::new(
            FunctionId::new("alpha::hidden").expect("function id"),
            WorkerId::new("alpha").expect("worker id"),
            "hidden function",
            VisibilityScope::Internal,
            EffectClass::PureRead,
        );
        let scoped_actor = |kind| {
            ActorContext::new(
                ActorId::new("actor").expect("actor id"),
                kind,
                AuthorityGrantId::new("grant").expect("grant id"),
            )
            .with_scope(ENGINE_INTERNAL_INVOKE_SCOPE)
        };

        assert!(!is_visible_to_actor(
            &function,
            Some(&scoped_actor(ActorKind::Client))
        ));
        assert!(!is_visible_to_actor(
            &function,
            Some(&scoped_actor(ActorKind::User))
        ));
        assert!(!is_visible_to_actor(
            &function,
            Some(&scoped_actor(ActorKind::Agent))
        ));
        assert!(is_visible_to_actor(
            &function,
            Some(&scoped_actor(ActorKind::Worker))
        ));
        assert!(is_visible_to_actor(
            &function,
            Some(&scoped_actor(ActorKind::System))
        ));
    }
}
