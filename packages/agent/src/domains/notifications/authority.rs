use crate::engine::{EngineGrant, Invocation, is_bootstrap_authority_grant_id};
use crate::shared::server::errors::CapabilityError;

use super::contract::{
    DEVICE_READ_SCOPE, READ_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE, WRITE_SCOPE,
};
use super::{Deps, NOTIFICATION_DELIVERY_KIND, NOTIFICATION_KIND};
use crate::engine::DEVICE_REGISTRATION_KIND;

pub(super) async fn ensure_write_authority(
    deps: &Deps,
    invocation: &Invocation,
    operation: &str,
    needs_device_read: bool,
) -> Result<(), CapabilityError> {
    if !invocation.causal_context.has_scope(WRITE_SCOPE)
        || !invocation.causal_context.has_scope(RESOURCE_WRITE_SCOPE)
        || !invocation.causal_context.has_scope(READ_SCOPE)
        || !invocation.causal_context.has_scope(RESOURCE_READ_SCOPE)
    {
        return Err(invalid(format!(
            "{operation} requires {READ_SCOPE}, {WRITE_SCOPE}, {RESOURCE_READ_SCOPE}, and {RESOURCE_WRITE_SCOPE}"
        )));
    }
    if needs_device_read && !invocation.causal_context.has_scope(DEVICE_READ_SCOPE) {
        return Err(invalid(format!(
            "{operation} with pushRequested requires {DEVICE_READ_SCOPE}"
        )));
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
    for scope in [
        READ_SCOPE,
        WRITE_SCOPE,
        RESOURCE_READ_SCOPE,
        RESOURCE_WRITE_SCOPE,
    ] {
        require_explicit_grant_item(&grant.allowed_authority_scopes, scope, operation)?;
    }
    if needs_device_read {
        require_explicit_grant_item(
            &grant.allowed_authority_scopes,
            DEVICE_READ_SCOPE,
            operation,
        )?;
    }
    require_kind_selectors(
        &grant,
        operation,
        &[NOTIFICATION_KIND, NOTIFICATION_DELIVERY_KIND],
    )?;
    if needs_device_read {
        require_kind_selectors(&grant, operation, &[DEVICE_REGISTRATION_KIND])?;
    }
    if grant.network_policy != "none" {
        return Err(invalid(format!("{operation} requires networkPolicy none")));
    }
    Ok(())
}

pub(super) async fn inspect_read_grant(
    deps: &Deps,
    invocation: &Invocation,
    operation: &str,
) -> Result<EngineGrant, CapabilityError> {
    let grant = deps
        .engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("{operation} authority grant was not found")))?;
    require_explicit_grant_item(&grant.allowed_authority_scopes, READ_SCOPE, operation)?;
    require_explicit_grant_item(
        &grant.allowed_authority_scopes,
        RESOURCE_READ_SCOPE,
        operation,
    )?;
    if grant.network_policy != "none" {
        return Err(invalid(format!("{operation} requires networkPolicy none")));
    }
    Ok(grant)
}

pub(super) fn require_kind_selectors(
    grant: &EngineGrant,
    operation: &str,
    kinds: &[&str],
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
    for kind in kinds {
        require_explicit_grant_item(&grant.allowed_resource_kinds, kind, operation)?;
        let selector = format!("kind:{kind}");
        if !grant
            .resource_selectors
            .iter()
            .any(|actual| actual == &selector)
        {
            return Err(invalid(format!(
                "{operation} requires explicit {selector} selector"
            )));
        }
    }
    Ok(())
}

fn require_explicit_grant_item(
    values: &[String],
    required: &str,
    operation: &str,
) -> Result<(), CapabilityError> {
    if values.iter().any(|value| value == "*") {
        return Err(invalid(format!("{operation} rejects wildcard grants")));
    }
    if !values.iter().any(|value| value == required) {
        return Err(invalid(format!(
            "{operation} requires explicit {required} grant"
        )));
    }
    Ok(())
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
