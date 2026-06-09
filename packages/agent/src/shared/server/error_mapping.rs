//! Error mapping for retained primitive engine boundaries.
//!
//! Domain helpers here translate engine, event-store, and provider-auth errors
//! into the JSON-RPC capability error shape used by the server transports.

use crate::domains::auth::credentials::errors::AuthError;
use crate::domains::session::event_store::errors::EventStoreError;
use crate::engine::{EngineError, InvocationResult};
use crate::shared::server::errors::{self as codes, CapabilityError};
use crate::shared::server::failure::{
    ENGINE_DELIVERY_MODE_NOT_ALLOWED, ENGINE_DOMAIN_FAILURE, ENGINE_HANDLER_FAILED,
    ENGINE_INVALID_FUNCTION_ID, ENGINE_INVALID_ID, ENGINE_INVALID_SCHEMA, ENGINE_LEDGER_FAILURE,
    ENGINE_NAMESPACE_DENIED, ENGINE_NOT_ROUTABLE, ENGINE_POLICY_VIOLATION, ENGINE_SCHEMA_VIOLATION,
    ENGINE_STORED_INVOCATION_ERROR, ENGINE_UNSUPPORTED_DELIVERY_MODE,
    ENGINE_WORKER_TRANSPORT_FAILURE, FailureCategory, FailureEnvelope, FailureOrigin,
};
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
    CapabilityError::from_failure(engine_error_to_failure(&error))
}

pub(crate) fn engine_error_to_failure(error: &EngineError) -> FailureEnvelope {
    match error {
        EngineError::InvalidId { kind, value } => FailureEnvelope::new(
            ENGINE_INVALID_ID,
            FailureCategory::InvalidRequest,
            error.to_string(),
            false,
            true,
            FailureOrigin::Engine,
        )
        .with_details(Some(serde_json::json!({ "kind": kind, "value": value }))),
        EngineError::InvalidFunctionId(value) => FailureEnvelope::new(
            ENGINE_INVALID_FUNCTION_ID,
            FailureCategory::InvalidRequest,
            error.to_string(),
            false,
            true,
            FailureOrigin::Engine,
        )
        .with_details(Some(serde_json::json!({ "value": value }))),
        EngineError::NotFound { kind, id } => FailureEnvelope::new(
            codes::NOT_FOUND,
            FailureCategory::NotFound,
            format!("{kind} not found: {id}"),
            false,
            true,
            FailureOrigin::Engine,
        )
        .with_details(Some(serde_json::json!({ "kind": kind, "id": id }))),
        EngineError::OwnerMismatch {
            kind,
            id,
            owner,
            attempted_owner,
        } => FailureEnvelope::new(
            codes::ENGINE_OWNER_MISMATCH,
            FailureCategory::Conflict,
            format!("{kind} {id} is owned by {owner}, not {attempted_owner}"),
            false,
            true,
            FailureOrigin::Engine,
        )
        .with_details(Some(serde_json::json!({
            "kind": kind,
            "id": id,
            "owner": owner,
            "attemptedOwner": attempted_owner,
        }))),
        EngineError::NamespaceDenied {
            worker_id,
            function_id,
        } => FailureEnvelope::new(
            ENGINE_NAMESPACE_DENIED,
            FailureCategory::Auth,
            error.to_string(),
            false,
            true,
            FailureOrigin::Engine,
        )
        .with_details(Some(serde_json::json!({
            "workerId": worker_id,
            "functionId": function_id,
        }))),
        EngineError::UnsupportedDeliveryMode { mode } => FailureEnvelope::new(
            ENGINE_UNSUPPORTED_DELIVERY_MODE,
            FailureCategory::InvalidRequest,
            error.to_string(),
            false,
            true,
            FailureOrigin::Engine,
        )
        .with_details(Some(serde_json::json!({ "mode": mode }))),
        EngineError::DeliveryModeNotAllowed { function_id, mode } => FailureEnvelope::new(
            ENGINE_DELIVERY_MODE_NOT_ALLOWED,
            FailureCategory::InvalidRequest,
            error.to_string(),
            false,
            true,
            FailureOrigin::Engine,
        )
        .with_details(Some(serde_json::json!({
            "functionId": function_id,
            "mode": mode,
        }))),
        EngineError::IdempotencyConflict {
            function_id,
            key,
            reason,
        } => FailureEnvelope::new(
            codes::IDEMPOTENCY_CONFLICT,
            FailureCategory::Conflict,
            format!("Idempotency conflict for {function_id}: {reason}"),
            false,
            true,
            FailureOrigin::Engine,
        )
        .with_details(Some(serde_json::json!({
            "functionId": function_id,
            "key": key,
            "reason": reason,
        }))),
        EngineError::LedgerFailure { operation, message } => FailureEnvelope::new(
            ENGINE_LEDGER_FAILURE,
            FailureCategory::Persistence,
            "Engine ledger operation failed",
            false,
            false,
            FailureOrigin::Engine,
        )
        .with_details(Some(serde_json::json!({
            "operation": operation,
            "message": message,
        }))),
        EngineError::StoredInvocationError { kind, message } => FailureEnvelope::new(
            ENGINE_STORED_INVOCATION_ERROR,
            FailureCategory::Capability,
            message.clone(),
            false,
            false,
            FailureOrigin::Engine,
        )
        .with_error_type(Some(kind.clone()))
        .with_details(Some(serde_json::json!({ "kind": kind }))),
        EngineError::InvalidSchema {
            function_id,
            direction,
            message,
        } => FailureEnvelope::new(
            ENGINE_INVALID_SCHEMA,
            FailureCategory::InvalidRequest,
            message.clone(),
            false,
            true,
            FailureOrigin::Engine,
        )
        .with_details(Some(serde_json::json!({
            "functionId": function_id,
            "direction": direction,
        }))),
        EngineError::SchemaViolation {
            function_id,
            direction,
            path,
            message,
        } => FailureEnvelope::new(
            ENGINE_SCHEMA_VIOLATION,
            FailureCategory::InvalidRequest,
            message.clone(),
            false,
            true,
            FailureOrigin::Engine,
        )
        .with_details(Some(serde_json::json!({
            "functionId": function_id,
            "direction": direction,
            "path": path,
        }))),
        EngineError::InvalidVisibilityPromotion {
            function_id,
            target,
            reason,
        } => FailureEnvelope::new(
            codes::INVALID_VISIBILITY_PROMOTION,
            FailureCategory::InvalidRequest,
            format!("invalid visibility promotion for {function_id} to {target}: {reason}"),
            false,
            true,
            FailureOrigin::Engine,
        )
        .with_details(Some(serde_json::json!({
            "functionId": function_id,
            "target": target,
            "reason": reason,
        }))),
        EngineError::PolicyViolation(message) => FailureEnvelope::new(
            ENGINE_POLICY_VIOLATION,
            FailureCategory::InvalidRequest,
            message.clone(),
            false,
            true,
            FailureOrigin::Engine,
        ),
        EngineError::NotRoutable {
            function_id,
            reason,
        } => FailureEnvelope::new(
            ENGINE_NOT_ROUTABLE,
            FailureCategory::Unavailable,
            error.to_string(),
            true,
            true,
            FailureOrigin::Engine,
        )
        .with_details(Some(serde_json::json!({
            "functionId": function_id,
            "reason": reason,
        }))),
        EngineError::DomainFailure {
            domain,
            code,
            message,
            details,
        } => {
            let mut detail_map = serde_json::Map::new();
            let _ = detail_map.insert("domain".to_owned(), Value::String(domain.clone()));
            if let Some(details) = details.clone() {
                let _ = detail_map.insert("details".to_owned(), details);
            }
            let capability_failure =
                capability_error_from_parts(code, message.clone(), Some(Value::Object(detail_map)))
                    .to_failure(FailureOrigin::Capability);
            FailureEnvelope::new(
                code.clone(),
                capability_failure.category,
                message.clone(),
                capability_failure.retryable,
                capability_failure.recoverable,
                FailureOrigin::Capability,
            )
            .with_details(capability_failure.details)
            .with_error_type(Some(ENGINE_DOMAIN_FAILURE.to_owned()))
        }
        EngineError::WorkerTransportFailure { code, message } => FailureEnvelope::new(
            code.clone(),
            FailureCategory::Engine,
            message.clone(),
            true,
            true,
            FailureOrigin::Engine,
        )
        .with_error_type(Some(ENGINE_WORKER_TRANSPORT_FAILURE.to_owned())),
        EngineError::HandlerFailed(message) => FailureEnvelope::new(
            ENGINE_HANDLER_FAILED,
            FailureCategory::Capability,
            message.clone(),
            false,
            false,
            FailureOrigin::Capability,
        ),
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
    use super::{
        engine_error_to_capability_error, engine_error_to_failure, map_auth_error,
        map_event_store_error,
    };
    use crate::domains::auth::credentials::errors::AuthError as A;
    use crate::domains::session::event_store::errors::EventStoreError as E;
    use crate::engine::EngineError;
    use crate::shared::server::failure::{
        ENGINE_DELIVERY_MODE_NOT_ALLOWED, ENGINE_HANDLER_FAILED, ENGINE_INVALID_FUNCTION_ID,
        ENGINE_INVALID_ID, ENGINE_INVALID_SCHEMA, ENGINE_LEDGER_FAILURE, ENGINE_NAMESPACE_DENIED,
        ENGINE_NOT_ROUTABLE, ENGINE_POLICY_VIOLATION, ENGINE_SCHEMA_VIOLATION,
        ENGINE_STORED_INVOCATION_ERROR, ENGINE_UNSUPPORTED_DELIVERY_MODE, FailureCategory,
    };

    #[test]
    fn every_engine_error_variant_has_stable_failure_mapping() {
        let cases = [
            (
                EngineError::InvalidId {
                    kind: "actor",
                    value: "bad id".to_owned(),
                },
                ENGINE_INVALID_ID,
                FailureCategory::InvalidRequest,
            ),
            (
                EngineError::InvalidFunctionId("bad".to_owned()),
                ENGINE_INVALID_FUNCTION_ID,
                FailureCategory::InvalidRequest,
            ),
            (
                EngineError::NotFound {
                    kind: "function",
                    id: "demo::missing".to_owned(),
                },
                "NOT_FOUND",
                FailureCategory::NotFound,
            ),
            (
                EngineError::OwnerMismatch {
                    kind: "function",
                    id: "demo::run".to_owned(),
                    owner: "worker-a".to_owned(),
                    attempted_owner: "worker-b".to_owned(),
                },
                "ENGINE_OWNER_MISMATCH",
                FailureCategory::Conflict,
            ),
            (
                EngineError::NamespaceDenied {
                    worker_id: "worker-a".to_owned(),
                    function_id: "other::run".to_owned(),
                },
                ENGINE_NAMESPACE_DENIED,
                FailureCategory::Auth,
            ),
            (
                EngineError::UnsupportedDeliveryMode { mode: "enqueue" },
                ENGINE_UNSUPPORTED_DELIVERY_MODE,
                FailureCategory::InvalidRequest,
            ),
            (
                EngineError::DeliveryModeNotAllowed {
                    function_id: "demo::run".to_owned(),
                    mode: "enqueue",
                },
                ENGINE_DELIVERY_MODE_NOT_ALLOWED,
                FailureCategory::InvalidRequest,
            ),
            (
                EngineError::IdempotencyConflict {
                    function_id: "demo::run".to_owned(),
                    key: "k".to_owned(),
                    reason: "payload mismatch".to_owned(),
                },
                "IDEMPOTENCY_CONFLICT",
                FailureCategory::Conflict,
            ),
            (
                EngineError::LedgerFailure {
                    operation: "insert",
                    message: "locked".to_owned(),
                },
                ENGINE_LEDGER_FAILURE,
                FailureCategory::Persistence,
            ),
            (
                EngineError::StoredInvocationError {
                    kind: "handler_failed".to_owned(),
                    message: "failed".to_owned(),
                },
                ENGINE_STORED_INVOCATION_ERROR,
                FailureCategory::Capability,
            ),
            (
                EngineError::InvalidSchema {
                    function_id: "demo::run".to_owned(),
                    direction: "request",
                    message: "bad schema".to_owned(),
                },
                ENGINE_INVALID_SCHEMA,
                FailureCategory::InvalidRequest,
            ),
            (
                EngineError::SchemaViolation {
                    function_id: "demo::run".to_owned(),
                    direction: "request",
                    path: "$.x".to_owned(),
                    message: "missing".to_owned(),
                },
                ENGINE_SCHEMA_VIOLATION,
                FailureCategory::InvalidRequest,
            ),
            (
                EngineError::InvalidVisibilityPromotion {
                    function_id: "demo::run".to_owned(),
                    target: "session".to_owned(),
                    reason: "not allowed".to_owned(),
                },
                "INVALID_VISIBILITY_PROMOTION",
                FailureCategory::InvalidRequest,
            ),
            (
                EngineError::PolicyViolation("denied".to_owned()),
                ENGINE_POLICY_VIOLATION,
                FailureCategory::InvalidRequest,
            ),
            (
                EngineError::NotRoutable {
                    function_id: "demo::run".to_owned(),
                    reason: "worker offline".to_owned(),
                },
                ENGINE_NOT_ROUTABLE,
                FailureCategory::Unavailable,
            ),
            (
                EngineError::DomainFailure {
                    domain: "session".to_owned(),
                    code: "SESSION_NOT_FOUND".to_owned(),
                    message: "missing".to_owned(),
                    details: Some(serde_json::json!({"sessionId": "s1"})),
                },
                "SESSION_NOT_FOUND",
                FailureCategory::NotFound,
            ),
            (
                EngineError::WorkerTransportFailure {
                    code: "WORKER_DISCONNECTED".to_owned(),
                    message: "worker disconnected".to_owned(),
                },
                "WORKER_DISCONNECTED",
                FailureCategory::Engine,
            ),
            (
                EngineError::HandlerFailed("boom".to_owned()),
                ENGINE_HANDLER_FAILED,
                FailureCategory::Capability,
            ),
        ];

        for (error, expected_code, expected_category) in cases {
            let failure = engine_error_to_failure(&error);
            assert_eq!(failure.code, expected_code, "{error:?}");
            assert_eq!(failure.category, expected_category, "{error:?}");
            assert!(!failure.message.trim().is_empty(), "{error:?}");
        }
    }

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
        assert_eq!(details["failure"]["category"], "conflict");
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
        assert_eq!(details["failure"]["code"], "INVALID_VISIBILITY_PROMOTION");
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
