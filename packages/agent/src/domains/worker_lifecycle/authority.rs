use crate::engine::{ActorKind, Invocation};
use crate::shared::server::errors::CapabilityError;

use super::Deps;
use super::errors::{engine_error, policy_error};
use super::{APPLY_SCOPE, LAUNCH_FUNCTION, PROPOSE_FUNCTION, PROPOSE_SCOPE};

pub(super) async fn ensure_proposal_authority(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<(), CapabilityError> {
    if !invocation.causal_context.has_scope(PROPOSE_SCOPE)
        && !invocation.causal_context.has_scope(APPLY_SCOPE)
    {
        return Err(policy_error(format!(
            "{PROPOSE_FUNCTION} requires {PROPOSE_SCOPE} or {APPLY_SCOPE}"
        )));
    }
    ensure_known_non_bootstrap_grant(invocation, deps).await
}

pub(super) async fn ensure_apply_authority(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<(), CapabilityError> {
    if !matches!(
        invocation.causal_context.actor_kind,
        ActorKind::User | ActorKind::Admin | ActorKind::System | ActorKind::Client
    ) {
        return Err(policy_error(
            "worker lifecycle apply functions require trusted user, client, admin, or system actor"
                .to_owned(),
        ));
    }
    if !invocation.causal_context.has_scope(APPLY_SCOPE) {
        return Err(policy_error(format!(
            "worker lifecycle apply functions require {APPLY_SCOPE}"
        )));
    }
    ensure_known_non_bootstrap_grant(invocation, deps).await
}

async fn ensure_known_non_bootstrap_grant(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<(), CapabilityError> {
    if crate::engine::is_bootstrap_authority_grant_id(&invocation.causal_context.authority_grant_id)
    {
        return Err(policy_error(
            "worker lifecycle changes require a derived non-bootstrap grant".to_owned(),
        ));
    }
    let grant = deps
        .engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| {
            policy_error(format!(
                "unknown authority grant {}",
                invocation.causal_context.authority_grant_id
            ))
        })?;
    if !grant.can_delegate && invocation.function_id.as_str() == LAUNCH_FUNCTION {
        return Err(policy_error(
            "worker launch requires a caller grant that can derive a worker grant".to_owned(),
        ));
    }
    Ok(())
}
