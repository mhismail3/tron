//! Error mapping for retained primitive engine boundaries.
//!
//! Domain helpers here translate engine, event-store, and provider-auth errors
//! into the JSON-RPC capability error shape used by the server transports.

use crate::domains::auth::credentials::errors::AuthError;
use crate::domains::session::event_store::errors::EventStoreError;
use crate::engine::{EngineError, InvocationResult};
use crate::shared::server::errors::{self as codes, CapabilityError};
use serde_json::Value;

pub(crate) fn capability_error_to_engine(error: CapabilityError) -> EngineError {
    EngineError::DomainFailure {
        domain: "server_capability".to_owned(),
        code: error.code().to_owned(),
        message: error.to_string(),
        details: error.details(),
    }
}

pub(crate) fn result_to_capability_value(
    result: InvocationResult,
) -> Result<Value, CapabilityError> {
    if let Some(error) = result.error {
        return Err(engine_error_to_capability_error(error));
    }
    Ok(result.value.unwrap_or(Value::Null))
}

pub(crate) fn engine_error_to_capability_error(error: EngineError) -> CapabilityError {
    match error {
        EngineError::DomainFailure {
            domain: _,
            code,
            message,
            details,
        } => capability_error_from_parts(&code, message, details),
        EngineError::SchemaViolation { message, .. } => CapabilityError::InvalidParams { message },
        EngineError::PolicyViolation(message) => CapabilityError::InvalidParams { message },
        EngineError::IdempotencyConflict {
            function_id,
            key,
            reason,
        } => CapabilityError::Custom {
            code: codes::IDEMPOTENCY_CONFLICT.to_owned(),
            message: format!("Idempotency conflict for {function_id}: {reason}"),
            details: Some(serde_json::json!({
                "functionId": function_id,
                "key": key,
                "reason": reason,
            })),
        },
        EngineError::OwnerMismatch {
            kind,
            id,
            owner,
            attempted_owner,
        } => CapabilityError::Custom {
            code: codes::ENGINE_OWNER_MISMATCH.to_owned(),
            message: format!("{kind} {id} is owned by {owner}, not {attempted_owner}"),
            details: Some(serde_json::json!({
                "kind": kind,
                "id": id,
                "owner": owner,
                "attemptedOwner": attempted_owner,
            })),
        },
        EngineError::InvalidVisibilityPromotion {
            function_id,
            target,
            reason,
        } => CapabilityError::Custom {
            code: codes::INVALID_VISIBILITY_PROMOTION.to_owned(),
            message: format!(
                "invalid visibility promotion for {function_id} to {target}: {reason}"
            ),
            details: Some(serde_json::json!({
                "functionId": function_id,
                "target": target,
                "reason": reason,
            })),
        },
        EngineError::NotFound { id, .. } => CapabilityError::NotFound {
            code: codes::NOT_FOUND.to_owned(),
            message: format!("Engine function '{id}' not found"),
        },
        other => CapabilityError::Internal {
            message: other.to_string(),
        },
    }
}

fn capability_error_from_parts(
    code: &str,
    message: String,
    details: Option<Value>,
) -> CapabilityError {
    match code {
        codes::INVALID_PARAMS => CapabilityError::InvalidParams { message },
        codes::INTERNAL_ERROR => CapabilityError::Internal { message },
        codes::NOT_AVAILABLE => CapabilityError::NotAvailable { message },
        codes::NOT_FOUND => CapabilityError::NotFound {
            code: codes::NOT_FOUND.to_owned(),
            message,
        },
        _ => CapabilityError::Custom {
            code: code.to_owned(),
            message,
            details,
        },
    }
}

pub(crate) fn map_event_store_error(e: EventStoreError) -> CapabilityError {
    use EventStoreError as E;
    match e {
        E::SessionNotFound(id) => CapabilityError::NotFound {
            code: codes::SESSION_NOT_FOUND.into(),
            message: format!("Session not found: {id}"),
        },
        E::EventNotFound(id) => CapabilityError::NotFound {
            code: codes::EVENT_NOT_FOUND.into(),
            message: format!("Event not found: {id}"),
        },
        E::WorkspaceNotFound(id) => CapabilityError::NotFound {
            code: codes::WORKSPACE_NOT_FOUND.into(),
            message: format!("Workspace not found: {id}"),
        },
        E::BlobNotFound(id) => CapabilityError::NotFound {
            code: codes::BLOB_NOT_FOUND.into(),
            message: format!("Blob not found: {id}"),
        },
        E::InvalidOperation(m) => CapabilityError::InvalidParams { message: m },
        E::Sqlite(_)
        | E::Pool(_)
        | E::Serde(_)
        | E::Migration { .. }
        | E::Busy { .. }
        | E::Internal(_) => CapabilityError::Internal {
            message: e.to_string(),
        },
    }
}

pub(crate) fn map_auth_error(e: AuthError) -> CapabilityError {
    use AuthError as A;
    match e {
        A::NotConfigured(provider) => CapabilityError::NotFound {
            code: codes::AUTH_NOT_CONFIGURED.into(),
            message: format!("No auth configured for provider: {provider}"),
        },
        A::TokenExpired(m) => CapabilityError::Custom {
            code: codes::AUTH_TOKEN_EXPIRED.into(),
            message: format!("Token expired and refresh failed: {m}"),
            details: None,
        },
        A::OAuth { status, message } => CapabilityError::Custom {
            code: codes::AUTH_OAUTH_ERROR.into(),
            message: format!("OAuth error ({status}): {message}"),
            details: None,
        },
        A::MalformedProviderAuth { provider, details } => CapabilityError::NotFound {
            code: codes::AUTH_NOT_CONFIGURED.into(),
            message: format!(
                "Malformed auth for {provider}: {details}. Re-authenticate via `tron auth {provider}`."
            ),
        },
        A::MalformedAuthFile { path, details } => CapabilityError::Internal {
            message: format!(
                "Malformed auth file at '{path}': {details}. Fix the file or run `tron auth reset` to wipe and re-authenticate."
            ),
        },
        A::Http(_) | A::Json { .. } | A::Io(_) => CapabilityError::Internal {
            message: e.to_string(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::{engine_error_to_capability_error, map_auth_error, map_event_store_error};
    use crate::domains::auth::credentials::errors::AuthError as A;
    use crate::domains::session::event_store::errors::EventStoreError as E;
    use crate::engine::EngineError;

    #[test]
    fn engine_owner_mismatch_is_typed() {
        let mapped = engine_error_to_capability_error(EngineError::OwnerMismatch {
            kind: "function",
            id: "demo::run".to_owned(),
            owner: "worker-a".to_owned(),
            attempted_owner: "worker-b".to_owned(),
        });
        assert_eq!(mapped.code(), "ENGINE_OWNER_MISMATCH");
        let details = mapped.details().expect("owner mismatch details");
        assert_eq!(details["kind"], "function");
        assert_eq!(details["id"], "demo::run");
        assert_eq!(details["owner"], "worker-a");
        assert_eq!(details["attemptedOwner"], "worker-b");
    }

    #[test]
    fn engine_invalid_visibility_promotion_is_typed() {
        let mapped = engine_error_to_capability_error(EngineError::InvalidVisibilityPromotion {
            function_id: "demo::run".to_owned(),
            target: "session".to_owned(),
            reason: "only workspace and system promotion are supported".to_owned(),
        });
        assert_eq!(mapped.code(), "INVALID_VISIBILITY_PROMOTION");
        let details = mapped.details().expect("visibility promotion details");
        assert_eq!(details["functionId"], "demo::run");
        assert_eq!(details["target"], "session");
    }

    #[test]
    fn event_store_session_not_found_is_typed() {
        let mapped = map_event_store_error(E::SessionNotFound("sess-42".into()));
        assert_eq!(mapped.code(), "SESSION_NOT_FOUND");
        assert!(mapped.to_string().contains("sess-42"));
    }

    #[test]
    fn event_store_event_not_found_is_typed() {
        let mapped = map_event_store_error(E::EventNotFound("evt-7".into()));
        assert_eq!(mapped.code(), "EVENT_NOT_FOUND");
        assert!(mapped.to_string().contains("evt-7"));
    }

    #[test]
    fn event_store_workspace_not_found_is_typed() {
        let mapped = map_event_store_error(E::WorkspaceNotFound("ws-1".into()));
        assert_eq!(mapped.code(), "WORKSPACE_NOT_FOUND");
        assert!(mapped.to_string().contains("ws-1"));
    }

    #[test]
    fn event_store_blob_not_found_is_typed() {
        let mapped = map_event_store_error(E::BlobNotFound("blob-abc".into()));
        assert_eq!(mapped.code(), "BLOB_NOT_FOUND");
        assert!(mapped.to_string().contains("blob-abc"));
    }

    #[test]
    fn event_store_invalid_operation_is_invalid_params() {
        let mapped = map_event_store_error(E::InvalidOperation("can't fork".into()));
        assert_eq!(mapped.code(), "INVALID_PARAMS");
        assert!(mapped.to_string().contains("can't fork"));
    }

    #[test]
    fn event_store_internal_errors_stay_internal() {
        let mapped = map_event_store_error(E::Sqlite(rusqlite::Error::QueryReturnedNoRows));
        assert_eq!(mapped.code(), "INTERNAL_ERROR");
    }

    #[test]
    fn auth_not_configured_is_typed() {
        let mapped = map_auth_error(A::NotConfigured("anthropic".into()));
        assert_eq!(mapped.code(), "AUTH_NOT_CONFIGURED");
        assert!(mapped.to_string().contains("anthropic"));
    }

    #[test]
    fn auth_token_expired_is_typed() {
        let mapped = map_auth_error(A::TokenExpired("refresh returned 403".into()));
        assert_eq!(mapped.code(), "AUTH_TOKEN_EXPIRED");
        assert!(mapped.to_string().contains("refresh returned 403"));
    }

    #[test]
    fn auth_oauth_error_is_typed() {
        let mapped = map_auth_error(A::OAuth {
            status: 401,
            message: "invalid_grant".into(),
        });
        assert_eq!(mapped.code(), "AUTH_OAUTH_ERROR");
        assert!(mapped.to_string().contains("invalid_grant"));
    }

    #[test]
    fn auth_io_is_internal() {
        let mapped = map_auth_error(A::Io(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "x",
        )));
        assert_eq!(mapped.code(), "INTERNAL_ERROR");
    }

    #[test]
    fn auth_json_is_internal() {
        let serde_err = serde_json::from_str::<String>("not json").unwrap_err();
        let mapped = map_auth_error(A::json("decode auth", serde_err));
        assert_eq!(mapped.code(), "INTERNAL_ERROR");
    }

    #[test]
    fn auth_malformed_provider_auth_is_not_configured() {
        let mapped = map_auth_error(A::MalformedProviderAuth {
            provider: "google".into(),
            details: "unknown field `endpoint`".into(),
        });
        assert_eq!(mapped.code(), "AUTH_NOT_CONFIGURED");
        let msg = mapped.to_string();
        assert!(msg.contains("google"));
        assert!(msg.contains("endpoint"));
        assert!(msg.contains("tron auth google"));
    }
}
