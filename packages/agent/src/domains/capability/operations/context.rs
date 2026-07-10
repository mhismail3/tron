use serde_json::Value;

use crate::engine::{ActorKind, Invocation, is_bootstrap_authority_grant_id};
use crate::shared::server::errors::CapabilityError;

use super::operation_contract;
use super::operation_contract::InvocationScope;

pub(super) fn validate_execute_context(
    invocation: &Invocation,
    operation: &str,
) -> Result<(), CapabilityError> {
    match invocation.causal_context.actor_kind {
        ActorKind::Agent => {
            let session_id = invocation
                .causal_context
                .session_id
                .as_deref()
                .ok_or_else(|| invalid("capability::execute agent context requires session id"))?;
            let expected_actor = format!("agent:{session_id}");
            if invocation.causal_context.actor_id.as_str() != expected_actor {
                return Err(invalid(
                    "capability::execute agent actor must match the current session",
                ));
            }
        }
        ActorKind::System => {}
        _ => {
            return Err(invalid(
                "capability::execute requires a trusted agent or system runtime context",
            ));
        }
    }
    if is_bootstrap_authority_grant_id(&invocation.causal_context.authority_grant_id) {
        return Err(invalid(
            "capability::execute requires a derived least-privilege authority grant",
        ));
    }
    match operation_contract::invocation_scope(operation) {
        InvocationScope::None => {}
        InvocationScope::CurrentSession => require_current_session(invocation, operation)?,
        InvocationScope::SessionOrWorkspace => require_session_or_workspace(invocation, operation)?,
    }
    match operation {
        "state_get" | "state_set" | "state_list" => validate_state_scope(invocation),
        _ if operation_contract::requires_idempotency(operation) => {
            require_idempotency_key(invocation, operation)
        }
        _ => Ok(()),
    }
}

fn require_session_or_workspace(
    invocation: &Invocation,
    operation: &str,
) -> Result<(), CapabilityError> {
    if invocation.causal_context.session_id.is_none()
        && invocation.causal_context.workspace_id.is_none()
    {
        return Err(invalid(format!(
            "{operation} requires trusted current session or workspace context"
        )));
    }
    Ok(())
}

fn validate_state_scope(invocation: &Invocation) -> Result<(), CapabilityError> {
    match optional_str(&invocation.payload, "scope")?.unwrap_or("session") {
        "session" => require_current_session(invocation, "state operation"),
        "workspace" => {
            if invocation.causal_context.workspace_id.is_none() {
                return Err(invalid(
                    "workspace state requires trusted workspace context",
                ));
            }
            Ok(())
        }
        "system" => Err(invalid(
            "capability::execute cannot read or write system-scoped state",
        )),
        other => Err(invalid(format!("unsupported execute state scope {other}"))),
    }
}

fn require_current_session(
    invocation: &Invocation,
    operation: &str,
) -> Result<(), CapabilityError> {
    if invocation.causal_context.session_id.is_none() {
        return Err(invalid(format!(
            "{operation} requires trusted current session context"
        )));
    }
    Ok(())
}

fn require_idempotency_key(
    invocation: &Invocation,
    operation: &str,
) -> Result<(), CapabilityError> {
    if invocation.causal_context.idempotency_key.is_none()
        && optional_str(&invocation.payload, "idempotencyKey")?.is_none()
    {
        return Err(invalid(format!(
            "{operation} writes durable evidence and requires an idempotencyKey"
        )));
    }
    Ok(())
}

fn optional_str<'a>(payload: &'a Value, field: &str) -> Result<Option<&'a str>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Ok(Some(value)),
        Some(_) => Err(invalid(format!("{field} must be a string"))),
    }
}

fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}
