//! Non-bypassable Phase 1 engine policy checks.

use super::discovery::{ActorContext, ActorKind};
use super::errors::{EngineError, Result};
use super::invocation::{CausalContext, Invocation};
use super::schema;
use super::types::{
    CompensationKind, DeliveryMode, FunctionDefinition, RiskLevel, TriggerDefinition,
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

    if function.visibility.is_agent_visible() {
        if function
            .effect_class
            .requires_approval_for_agent_visibility()
            && !function.required_authority.approval_required
            && !has_sandbox_autonomy_contract(function)
            && !has_conditional_approval_contract(function)
        {
            return Err(EngineError::PolicyViolation(format!(
                "irreversible agent-visible function {} requires approval metadata",
                function.id
            )));
        }
        if function.effect_class.is_mutating()
            && function.risk_level >= RiskLevel::High
            && !function.required_authority.approval_required
            && !has_sandbox_autonomy_contract(function)
            && !has_conditional_approval_contract(function)
        {
            return Err(EngineError::PolicyViolation(format!(
                "high-risk agent-visible function {} requires approval metadata",
                function.id
            )));
        }
    }

    if function.effect_class.is_mutating() && function.risk_level >= RiskLevel::High {
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

fn has_sandbox_autonomy_contract(function: &FunctionDefinition) -> bool {
    let Some(contract) = function
        .metadata
        .pointer("/highRiskContract/sandboxAutonomy")
    else {
        return false;
    };
    contract
        .get("withoutUserApproval")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false)
        && contract
            .get("requiresIdempotency")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false)
        && contract
            .get("requiresLease")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false)
        && contract
            .get("requiresCompensation")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false)
}

fn has_conditional_approval_contract(function: &FunctionDefinition) -> bool {
    let Some(contract) = function
        .metadata
        .pointer("/highRiskContract/conditionalApproval")
    else {
        return false;
    };
    contract
        .get("owner")
        .and_then(serde_json::Value::as_str)
        .is_some_and(|value| !value.trim().is_empty())
        && contract
            .get("policy")
            .and_then(serde_json::Value::as_str)
            .is_some_and(|value| !value.trim().is_empty())
        && contract
            .get("approvalRequiredFor")
            .and_then(serde_json::Value::as_array)
            .is_some_and(|items| !items.is_empty())
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::{
        AuthorityRequirement, CompensationContract, CompensationKind, EffectClass, FunctionId,
        IdempotencyContract, Provenance, ResourceLeaseRequirement, WorkerId,
    };
    use serde_json::json;

    fn high_risk_process_function(metadata: serde_json::Value) -> FunctionDefinition {
        let mut function = FunctionDefinition::new(
            FunctionId::new("process::run").expect("function id"),
            WorkerId::new("process").expect("worker id"),
            "Run process".to_owned(),
            VisibilityScope::System,
            EffectClass::ExternalSideEffect,
        )
        .with_risk(RiskLevel::High)
        .with_required_authority(AuthorityRequirement::scope("process.run"))
        .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
        .with_resource_lease(ResourceLeaseRequirement::exclusive_template(
            "process",
            "process:{sessionId}",
            60_000,
        ))
        .with_compensation(CompensationContract::new(
            CompensationKind::ManualOnly,
            "process output is the audit boundary",
        ))
        .with_provenance(Provenance::system());
        function.metadata = metadata;
        function
    }

    #[test]
    fn conditional_approval_contract_satisfies_high_risk_registration_policy() {
        let function = high_risk_process_function(json!({
            "highRiskContract": {
                "conditionalApproval": {
                    "owner": "process",
                    "policy": "process::run command classifier",
                    "approvalRequiredFor": ["privileged commands"]
                }
            }
        }));

        validate_function_registration(&function).expect("conditional approval is metadata");
    }

    #[test]
    fn missing_conditional_approval_contract_is_rejected_for_high_risk_agent_visible_function() {
        let function = high_risk_process_function(json!({}));

        let error = validate_function_registration(&function).expect_err("missing approval");

        assert!(
            matches!(error, EngineError::PolicyViolation(message) if message.contains("requires approval metadata"))
        );
    }
}
