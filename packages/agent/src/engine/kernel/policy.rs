//! Engine substrate registration and invocation checks.
//!
//! This layer protects primitive runtime integrity: idempotency, schemas,
//! and visibility. It does not encode product
//! prompt policy.
//!
//! INVARIANT: internal functions are callable only by the engine-owned System
//! actor or by an Agent carrying an immutable exact grant for a source-declared
//! delegable function. A reusable child Agent is identified by durable agent
//! identity; assignment turns additionally carry assignment/execution
//! topology, while idle question/offer turns carry a read-only auxiliary exact
//! grant. Either form must carry its immutable grant, and a missing snapshot
//! fails closed before visibility is considered. Visible root Agents retain
//! the ordinary public surface.
//! Native-client functions exclude model-backed actors.

use crate::engine::catalog::discovery::{ActorContext, ActorKind};
use crate::engine::invocation::model::{CausalContext, Invocation};

use super::errors::{EngineError, Result};
use super::schema;
use super::types::{DelegationPolicy, FunctionDefinition, FunctionVisibility};

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
    let exact_grant = invocation.causal_context.delegated_function_grant();
    let is_granted =
        exact_grant.is_some_and(|grant| grant.iter().any(|id| id == function.id.as_str()));
    if actor.actor_kind == ActorKind::Agent
        && invocation.causal_context.agent_id().is_some()
        && exact_grant.is_none()
    {
        return Err(EngineError::PolicyViolation(format!(
            "reusable agent invocation of {} is missing its immutable delegated grant",
            function.id
        )));
    }
    if actor.actor_kind == ActorKind::Agent
        && exact_grant.is_some()
        && (function.delegation_policy == DelegationPolicy::Never || !is_granted)
    {
        return Err(EngineError::PolicyViolation(format!(
            "function {} is outside the agent's immutable delegated grant",
            function.id
        )));
    }
    let explicitly_delegated_internal = function.visibility == FunctionVisibility::Internal
        && actor.actor_kind == ActorKind::Agent
        && function.delegation_policy != DelegationPolicy::Never
        && is_granted;
    if !is_visible_to_actor(function, &actor) && !explicitly_delegated_internal {
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
    use crate::engine::{
        ActorId, CausalContext, DelegationPolicy, EffectClass, FunctionId, Invocation, TraceId,
        WorkerId, WorkspaceEffect,
    };

    fn agent_invocation(function_id: &str, grant: Vec<&str>) -> Invocation {
        Invocation::new_sync(
            FunctionId::new(function_id).expect("function id"),
            serde_json::json!({}),
            CausalContext::new(
                ActorId::new("agent:test").expect("actor id"),
                ActorKind::Agent,
                TraceId::generate(),
            )
            .with_delegated_function_grant(grant.into_iter().map(ToOwned::to_owned).collect()),
        )
    }

    fn reusable_agent_invocation(function_id: &str, grant: Option<Vec<&str>>) -> Invocation {
        let context = CausalContext::new(
            ActorId::new("agent:child").expect("actor id"),
            ActorKind::Agent,
            TraceId::generate(),
        )
        .with_agent_execution("agent-child", "assignment-child", "execution-child");
        let context = grant.map_or(context.clone(), |grant| {
            context
                .with_delegated_function_grant(grant.into_iter().map(ToOwned::to_owned).collect())
        });
        Invocation::new_sync(
            FunctionId::new(function_id).expect("function id"),
            serde_json::json!({}),
            context,
        )
    }

    #[test]
    fn function_authority_metadata_fails_closed() {
        let function = FunctionDefinition::new(
            FunctionId::new("alpha::defaulted").expect("function id"),
            WorkerId::new("alpha").expect("worker id"),
            "defaulted function",
            FunctionVisibility::Public,
            EffectClass::PureRead,
        );

        assert_eq!(function.delegation_policy, DelegationPolicy::Never);
        assert_eq!(function.workspace_effect, WorkspaceEffect::None);
    }

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

    #[test]
    fn delegated_agent_grant_restricts_public_functions_exactly() {
        let allowed = FunctionDefinition::new(
            FunctionId::new("alpha::allowed").expect("function id"),
            WorkerId::new("alpha").expect("worker id"),
            "allowed",
            FunctionVisibility::Public,
            EffectClass::PureRead,
        )
        .with_delegation_policy(DelegationPolicy::Inherit);
        validate_invocation(
            &allowed,
            &agent_invocation("alpha::allowed", vec!["alpha::allowed"]),
        )
        .expect("exact inherited grant is callable");

        let denied = FunctionDefinition::new(
            FunctionId::new("alpha::denied").expect("function id"),
            WorkerId::new("alpha").expect("worker id"),
            "denied",
            FunctionVisibility::Public,
            EffectClass::PureRead,
        )
        .with_delegation_policy(DelegationPolicy::Inherit);
        let error = validate_invocation(
            &denied,
            &agent_invocation("alpha::denied", vec!["alpha::allowed"]),
        )
        .expect_err("public functions outside an exact agent grant must fail closed");
        assert!(error.to_string().contains("immutable delegated grant"));
    }

    #[test]
    fn reusable_agents_require_an_exact_grant_while_visible_roots_keep_public_access() {
        let function = FunctionDefinition::new(
            FunctionId::new("alpha::public").expect("function id"),
            WorkerId::new("alpha").expect("worker id"),
            "public",
            FunctionVisibility::Public,
            EffectClass::PureRead,
        )
        .with_delegation_policy(DelegationPolicy::Inherit);

        validate_invocation(
            &function,
            &Invocation::new_sync(
                FunctionId::new("alpha::public").expect("function id"),
                serde_json::json!({}),
                CausalContext::new(
                    ActorId::new("agent:root").expect("actor id"),
                    ActorKind::Agent,
                    TraceId::generate(),
                ),
            ),
        )
        .expect("a visible root agent retains the ordinary public surface");

        let error =
            validate_invocation(&function, &reusable_agent_invocation("alpha::public", None))
                .expect_err("a reusable child without its snapshot must fail closed");
        assert!(
            error
                .to_string()
                .contains("missing its immutable delegated grant")
        );

        validate_invocation(
            &function,
            &reusable_agent_invocation("alpha::public", Some(vec!["alpha::public"])),
        )
        .expect("the exact immutable child grant remains callable");
    }

    #[test]
    fn delegated_internal_functions_require_exact_non_never_grants() {
        let internal = FunctionDefinition::new(
            FunctionId::new("alpha::internal").expect("function id"),
            WorkerId::new("alpha").expect("worker id"),
            "internal",
            FunctionVisibility::Internal,
            EffectClass::PureRead,
        )
        .with_delegation_policy(DelegationPolicy::Explicit);
        validate_invocation(
            &internal,
            &agent_invocation("alpha::internal", vec!["alpha::internal"]),
        )
        .expect("an exact explicitly delegable internal function is callable");

        let never = internal
            .clone()
            .with_delegation_policy(DelegationPolicy::Never);
        validate_invocation(
            &never,
            &agent_invocation("alpha::internal", vec!["alpha::internal"]),
        )
        .expect_err("nondelegable internal functions remain unavailable");

        validate_invocation(
            &internal,
            &agent_invocation("alpha::internal", vec!["alpha::different"]),
        )
        .expect_err("internal functions require their exact id in the grant");
    }
}
