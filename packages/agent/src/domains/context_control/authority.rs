use crate::engine::{
    ActorKind, EngineGrant, EngineResourceScope, Invocation, is_bootstrap_authority_grant_id,
};
use crate::shared::server::errors::CapabilityError;

use super::Deps;
use super::contract::{READ_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE, WRITE_SCOPE};
use super::{
    CONTEXT_CONTROL_ACTION_KIND, CONTEXT_CONTROL_EPOCH_KIND, CONTEXT_CONTROL_SNAPSHOT_KIND,
};

pub(super) enum AccessMode {
    Read,
    Write,
}

pub(super) async fn ensure_authority(
    deps: &Deps,
    invocation: &Invocation,
    operation: &str,
    mode: AccessMode,
    session_id: &str,
    exact_resource_id: Option<&str>,
) -> Result<(), CapabilityError> {
    if is_first_party_system(invocation) {
        return Ok(());
    }
    if is_bootstrap_authority_grant_id(&invocation.causal_context.authority_grant_id) {
        return Err(invalid(format!(
            "{operation} requires a derived non-bootstrap grant"
        )));
    }
    let grant = deps
        .engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("{operation} authority grant was not found")))?;
    require_explicit_scope(&grant, READ_SCOPE, operation)?;
    require_explicit_scope(&grant, RESOURCE_READ_SCOPE, operation)?;
    if matches!(mode, AccessMode::Write) {
        require_explicit_scope(&grant, WRITE_SCOPE, operation)?;
        require_explicit_scope(&grant, RESOURCE_WRITE_SCOPE, operation)?;
    }
    for kind in [
        CONTEXT_CONTROL_SNAPSHOT_KIND,
        CONTEXT_CONTROL_ACTION_KIND,
        CONTEXT_CONTROL_EPOCH_KIND,
    ] {
        require_explicit_kind(&grant, kind, operation)?;
        require_kind_selector(&grant, kind, operation)?;
    }
    require_session_selector(&grant, session_id, operation)?;
    if let Some(resource_id) = exact_resource_id {
        require_exact_resource_selector(&grant, resource_id, operation)?;
    }
    if grant.network_policy != "none" {
        return Err(invalid(format!("{operation} requires networkPolicy none")));
    }
    Ok(())
}

pub(super) fn session_scope_for_invocation(
    invocation: &Invocation,
    payload_session_id: Option<&str>,
    operation: &str,
) -> Result<(String, EngineResourceScope), CapabilityError> {
    let session_id = match invocation.causal_context.actor_kind {
        ActorKind::Agent => invocation
            .causal_context
            .session_id
            .as_deref()
            .ok_or_else(|| invalid(format!("{operation} requires trusted session context")))?,
        ActorKind::System => payload_session_id
            .or(invocation.causal_context.session_id.as_deref())
            .ok_or_else(|| invalid(format!("{operation} requires sessionId")))?,
        _ => {
            return Err(invalid(format!(
                "{operation} requires trusted agent or system context"
            )));
        }
    };
    if let Some(payload_session_id) = payload_session_id
        && payload_session_id != session_id
    {
        return Err(invalid(format!(
            "{operation} sessionId must match current session"
        )));
    }
    Ok((
        session_id.to_owned(),
        EngineResourceScope::Session(session_id.to_owned()),
    ))
}

pub(super) fn require_exact_resource_selector(
    grant: &EngineGrant,
    resource_id: &str,
    operation: &str,
) -> Result<(), CapabilityError> {
    if is_broad_selector(resource_id) {
        return Err(invalid(format!("{operation} rejects broad resource id")));
    }
    let selector = format!("resource:{resource_id}");
    if grant
        .resource_selectors
        .iter()
        .any(|actual| actual == &selector)
    {
        Ok(())
    } else {
        Err(invalid(format!(
            "{operation} requires exact {selector} selector"
        )))
    }
}

fn is_first_party_system(invocation: &Invocation) -> bool {
    invocation.causal_context.actor_kind == ActorKind::System
        && invocation
            .causal_context
            .actor_id
            .as_str()
            .starts_with("system")
}

fn require_explicit_scope(
    grant: &EngineGrant,
    required: &str,
    operation: &str,
) -> Result<(), CapabilityError> {
    if grant
        .allowed_authority_scopes
        .iter()
        .any(|scope| scope == "*")
    {
        return Err(invalid(format!("{operation} rejects wildcard grants")));
    }
    if grant
        .allowed_authority_scopes
        .iter()
        .any(|scope| scope == required)
    {
        Ok(())
    } else {
        Err(invalid(format!(
            "{operation} requires explicit {required} grant"
        )))
    }
}

fn require_explicit_kind(
    grant: &EngineGrant,
    required: &str,
    operation: &str,
) -> Result<(), CapabilityError> {
    if grant.allowed_resource_kinds.iter().any(|kind| kind == "*") {
        return Err(invalid(format!(
            "{operation} rejects wildcard resource kinds"
        )));
    }
    if grant
        .allowed_resource_kinds
        .iter()
        .any(|kind| kind == required)
    {
        Ok(())
    } else {
        Err(invalid(format!(
            "{operation} requires explicit {required} resource kind"
        )))
    }
}

fn require_kind_selector(
    grant: &EngineGrant,
    kind: &str,
    operation: &str,
) -> Result<(), CapabilityError> {
    if let Some(selector) = grant
        .resource_selectors
        .iter()
        .find(|selector| is_broad_selector(selector))
    {
        return Err(invalid(format!(
            "{operation} rejects broad resource selector {selector}"
        )));
    }
    let selector = format!("kind:{kind}");
    if grant
        .resource_selectors
        .iter()
        .any(|actual| actual == &selector)
    {
        Ok(())
    } else {
        Err(invalid(format!(
            "{operation} requires explicit {selector} selector"
        )))
    }
}

fn require_session_selector(
    grant: &EngineGrant,
    session_id: &str,
    operation: &str,
) -> Result<(), CapabilityError> {
    let selector = format!("session:{session_id}");
    if grant
        .resource_selectors
        .iter()
        .any(|actual| actual == &selector)
    {
        Ok(())
    } else {
        Err(invalid(format!(
            "{operation} requires exact {selector} selector"
        )))
    }
}

fn is_broad_selector(selector: &str) -> bool {
    let trimmed = selector.trim();
    trimmed == "*"
        || trimmed == "kind:*"
        || trimmed == "resource:*"
        || trimmed == "kind:"
        || trimmed == "resource:"
        || trimmed.ends_with(":*")
}

fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}

fn engine_error(error: crate::engine::EngineError) -> CapabilityError {
    CapabilityError::Internal {
        message: error.to_string(),
    }
}
