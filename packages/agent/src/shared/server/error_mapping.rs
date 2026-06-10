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
        E::SessionNotFound(id) => CapabilityError::from_failure(
            FailureEnvelope::new(
                codes::SESSION_NOT_FOUND,
                FailureCategory::NotFound,
                format!("Session not found: {id}"),
                false,
                true,
                FailureOrigin::EventStore,
            )
            .with_details(Some(serde_json::json!({ "sessionId": id }))),
        ),
        E::EventNotFound(id) => CapabilityError::from_failure(
            FailureEnvelope::new(
                codes::EVENT_NOT_FOUND,
                FailureCategory::NotFound,
                format!("Event not found: {id}"),
                false,
                true,
                FailureOrigin::EventStore,
            )
            .with_details(Some(serde_json::json!({ "eventId": id }))),
        ),
        E::WorkspaceNotFound(id) => CapabilityError::from_failure(
            FailureEnvelope::new(
                codes::WORKSPACE_NOT_FOUND,
                FailureCategory::NotFound,
                format!("Workspace not found: {id}"),
                false,
                true,
                FailureOrigin::EventStore,
            )
            .with_details(Some(serde_json::json!({ "workspaceId": id }))),
        ),
        E::BlobNotFound(id) => CapabilityError::from_failure(
            FailureEnvelope::new(
                codes::BLOB_NOT_FOUND,
                FailureCategory::NotFound,
                format!("Blob not found: {id}"),
                false,
                true,
                FailureOrigin::EventStore,
            )
            .with_details(Some(serde_json::json!({ "blobId": id }))),
        ),
        E::InvalidOperation(message) => CapabilityError::from_failure(
            FailureEnvelope::new(
                codes::INVALID_PARAMS,
                FailureCategory::InvalidRequest,
                message.clone(),
                false,
                true,
                FailureOrigin::EventStore,
            )
            .with_details(Some(serde_json::json!({ "reason": message }))),
        ),
        E::Busy {
            operation,
            attempts,
        } => CapabilityError::from_failure(
            FailureEnvelope::new(
                codes::EVENT_STORE_BUSY,
                FailureCategory::Unavailable,
                format!("Event store busy during {operation}"),
                true,
                true,
                FailureOrigin::EventStore,
            )
            .with_details(Some(serde_json::json!({
                "operation": operation,
                "attempts": attempts,
            }))),
        ),
        E::Sqlite(error) => event_store_internal_failure("sqlite", Some(error.to_string())),
        E::Pool(error) => event_store_internal_failure("pool", Some(error.to_string())),
        E::Serde(error) => event_store_internal_failure("serde", Some(error.to_string())),
        E::Migration { message } => event_store_internal_failure("migration", Some(message)),
        E::Internal(message) => event_store_internal_failure("internal", Some(message)),
    }
}

pub(crate) fn map_auth_error(e: AuthError) -> CapabilityError {
    use AuthError as A;
    match e {
        A::NotConfigured(provider) => CapabilityError::from_failure(
            FailureEnvelope::new(
                codes::AUTH_NOT_CONFIGURED,
                FailureCategory::Auth,
                format!("No auth configured for provider: {provider}"),
                false,
                true,
                FailureOrigin::Auth,
            )
            .with_details(Some(serde_json::json!({ "provider": provider })))
            .with_suggestion(Some(format!("Run `tron auth {provider}`."))),
        ),
        A::TokenExpired(message) => CapabilityError::from_failure(
            FailureEnvelope::new(
                codes::AUTH_TOKEN_EXPIRED,
                FailureCategory::Auth,
                "Auth token expired and refresh failed",
                false,
                true,
                FailureOrigin::Auth,
            )
            .with_details(Some(serde_json::json!({ "reason": message })))
            .with_suggestion(Some("Re-authenticate the provider.".to_owned())),
        ),
        A::OAuth { status, message } => {
            let retryable = matches!(status, 408 | 429 | 502 | 503 | 504);
            CapabilityError::from_failure(
                FailureEnvelope::new(
                    codes::AUTH_OAUTH_ERROR,
                    FailureCategory::Auth,
                    format!("OAuth error ({status}): {message}"),
                    retryable,
                    true,
                    FailureOrigin::Auth,
                )
                .with_status_code(Some(status))
                .with_details(Some(serde_json::json!({
                    "status": status,
                    "reason": message,
                }))),
            )
        }
        A::MalformedProviderAuth { provider, details } => CapabilityError::from_failure(
            FailureEnvelope::new(
                codes::AUTH_NOT_CONFIGURED,
                FailureCategory::Auth,
                format!("Malformed auth for {provider}. Re-authenticate the provider."),
                false,
                true,
                FailureOrigin::Auth,
            )
            .with_details(Some(serde_json::json!({
                "provider": provider,
                "reason": details,
            })))
            .with_suggestion(Some(format!("Run `tron auth {provider}`."))),
        ),
        A::MalformedAuthFile { details, .. } => CapabilityError::from_failure(
            FailureEnvelope::new(
                codes::AUTH_STORAGE_ERROR,
                FailureCategory::Auth,
                "Malformed auth storage. Fix the file or run `tron auth reset`.",
                false,
                true,
                FailureOrigin::Auth,
            )
            .with_details(Some(serde_json::json!({ "reason": details })))
            .with_suggestion(Some(
                "Run `tron auth reset` if the file cannot be repaired.".to_owned(),
            )),
        ),
        A::Http(error) => {
            let status = error.status();
            let retryable = error.is_timeout()
                || error.is_connect()
                || status.is_some_and(|status| {
                    status.is_server_error() || status == reqwest::StatusCode::TOO_MANY_REQUESTS
                });
            let error_type = if error.is_timeout() {
                "timeout"
            } else if error.is_connect() {
                "connect"
            } else if status.is_some() {
                "http_status"
            } else {
                "request"
            };
            CapabilityError::from_failure(
                FailureEnvelope::new(
                    codes::AUTH_TRANSPORT_ERROR,
                    FailureCategory::Network,
                    "Auth provider request failed",
                    retryable,
                    true,
                    FailureOrigin::Auth,
                )
                .with_status_code(status.map(|status| status.as_u16()))
                .with_error_type(Some(error_type.to_owned()))
                .with_details(Some(serde_json::json!({ "kind": error_type }))),
            )
        }
        A::Json { operation, message } => CapabilityError::from_failure(
            FailureEnvelope::new(
                codes::AUTH_STORAGE_ERROR,
                FailureCategory::Auth,
                "Auth storage JSON operation failed",
                false,
                true,
                FailureOrigin::Auth,
            )
            .with_details(Some(serde_json::json!({
                "operation": operation,
                "reason": message,
            }))),
        ),
        A::Io(error) => CapabilityError::from_failure(
            FailureEnvelope::new(
                codes::AUTH_STORAGE_ERROR,
                FailureCategory::Auth,
                "Auth storage I/O operation failed",
                false,
                true,
                FailureOrigin::Auth,
            )
            .with_error_type(Some(format!("{:?}", error.kind())))
            .with_details(Some(
                serde_json::json!({ "kind": format!("{:?}", error.kind()) }),
            )),
        ),
    }
}

fn event_store_internal_failure(kind: &'static str, reason: Option<String>) -> CapabilityError {
    CapabilityError::from_failure(
        FailureEnvelope::new(
            codes::EVENT_STORE_FAILURE,
            FailureCategory::Persistence,
            "Event store operation failed",
            false,
            false,
            FailureOrigin::EventStore,
        )
        .with_error_type(Some(kind.to_owned()))
        .with_details(Some(serde_json::json!({ "kind": kind, "reason": reason }))),
    )
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
    use crate::shared::server::errors::{self as codes, CapabilityError};
    use crate::shared::server::failure::{
        ENGINE_DELIVERY_MODE_NOT_ALLOWED, ENGINE_HANDLER_FAILED, ENGINE_INVALID_FUNCTION_ID,
        ENGINE_INVALID_ID, ENGINE_INVALID_SCHEMA, ENGINE_LEDGER_FAILURE, ENGINE_NAMESPACE_DENIED,
        ENGINE_NOT_ROUTABLE, ENGINE_POLICY_VIOLATION, ENGINE_SCHEMA_VIOLATION,
        ENGINE_STORED_INVOCATION_ERROR, ENGINE_UNSUPPORTED_DELIVERY_MODE, FailureCategory,
        FailureOrigin,
    };

    fn assert_embedded_failure(
        mapped: &CapabilityError,
        expected_code: &str,
        expected_category: FailureCategory,
        expected_origin: FailureOrigin,
        expected_retryable: bool,
        expected_recoverable: bool,
    ) -> serde_json::Value {
        assert_eq!(mapped.code(), expected_code);
        let details = mapped.details().expect("canonical failure details");
        assert_eq!(details["failure"]["code"], expected_code);
        assert_eq!(details["failure"]["category"], expected_category.as_str());
        assert_eq!(details["failure"]["origin"], expected_origin.as_str());
        assert_eq!(details["failure"]["retryable"], expected_retryable);
        assert_eq!(details["failure"]["recoverable"], expected_recoverable);
        details
    }

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
        let details = assert_embedded_failure(
            &mapped,
            codes::SESSION_NOT_FOUND,
            FailureCategory::NotFound,
            FailureOrigin::EventStore,
            false,
            true,
        );
        assert_eq!(details["sessionId"], "sess-42");
        assert!(mapped.to_string().contains("sess-42"));
    }

    #[test]
    fn event_store_event_not_found_is_typed() {
        let mapped = map_event_store_error(E::EventNotFound("evt-7".into()));
        let details = assert_embedded_failure(
            &mapped,
            codes::EVENT_NOT_FOUND,
            FailureCategory::NotFound,
            FailureOrigin::EventStore,
            false,
            true,
        );
        assert_eq!(details["eventId"], "evt-7");
        assert!(mapped.to_string().contains("evt-7"));
    }

    #[test]
    fn event_store_workspace_not_found_is_typed() {
        let mapped = map_event_store_error(E::WorkspaceNotFound("ws-1".into()));
        let details = assert_embedded_failure(
            &mapped,
            codes::WORKSPACE_NOT_FOUND,
            FailureCategory::NotFound,
            FailureOrigin::EventStore,
            false,
            true,
        );
        assert_eq!(details["workspaceId"], "ws-1");
        assert!(mapped.to_string().contains("ws-1"));
    }

    #[test]
    fn event_store_blob_not_found_is_typed() {
        let mapped = map_event_store_error(E::BlobNotFound("blob-abc".into()));
        let details = assert_embedded_failure(
            &mapped,
            codes::BLOB_NOT_FOUND,
            FailureCategory::NotFound,
            FailureOrigin::EventStore,
            false,
            true,
        );
        assert_eq!(details["blobId"], "blob-abc");
        assert!(mapped.to_string().contains("blob-abc"));
    }

    #[test]
    fn event_store_invalid_operation_is_invalid_params() {
        let mapped = map_event_store_error(E::InvalidOperation("can't fork".into()));
        let details = assert_embedded_failure(
            &mapped,
            codes::INVALID_PARAMS,
            FailureCategory::InvalidRequest,
            FailureOrigin::EventStore,
            false,
            true,
        );
        assert_eq!(details["reason"], "can't fork");
        assert!(mapped.to_string().contains("can't fork"));
    }

    #[test]
    fn event_store_busy_is_retryable_unavailable() {
        let mapped = map_event_store_error(E::Busy {
            operation: "append_event",
            attempts: 5,
        });
        let details = assert_embedded_failure(
            &mapped,
            codes::EVENT_STORE_BUSY,
            FailureCategory::Unavailable,
            FailureOrigin::EventStore,
            true,
            true,
        );
        assert_eq!(details["operation"], "append_event");
        assert_eq!(details["attempts"], 5);
    }

    #[test]
    fn event_store_internal_errors_preserve_persistence_failure() {
        let mapped = map_event_store_error(E::Sqlite(rusqlite::Error::QueryReturnedNoRows));
        let details = assert_embedded_failure(
            &mapped,
            codes::EVENT_STORE_FAILURE,
            FailureCategory::Persistence,
            FailureOrigin::EventStore,
            false,
            false,
        );
        assert_eq!(details["kind"], "sqlite");
        assert_eq!(details["failure"]["errorType"], "sqlite");
    }

    #[test]
    fn event_store_migration_errors_preserve_safe_reason() {
        let mapped = map_event_store_error(E::Migration {
            message: "v003 failed".into(),
        });
        let details = assert_embedded_failure(
            &mapped,
            codes::EVENT_STORE_FAILURE,
            FailureCategory::Persistence,
            FailureOrigin::EventStore,
            false,
            false,
        );
        assert_eq!(details["kind"], "migration");
        assert_eq!(details["reason"], "v003 failed");
    }

    #[test]
    fn auth_not_configured_is_typed() {
        let mapped = map_auth_error(A::NotConfigured("anthropic".into()));
        let details = assert_embedded_failure(
            &mapped,
            codes::AUTH_NOT_CONFIGURED,
            FailureCategory::Auth,
            FailureOrigin::Auth,
            false,
            true,
        );
        assert_eq!(details["provider"], "anthropic");
        assert!(mapped.to_string().contains("anthropic"));
    }

    #[test]
    fn auth_token_expired_is_typed() {
        let mapped = map_auth_error(A::TokenExpired("refresh returned 403".into()));
        let details = assert_embedded_failure(
            &mapped,
            codes::AUTH_TOKEN_EXPIRED,
            FailureCategory::Auth,
            FailureOrigin::Auth,
            false,
            true,
        );
        assert_eq!(details["reason"], "refresh returned 403");
        assert_eq!(mapped.to_string(), "Auth token expired and refresh failed");
    }

    #[test]
    fn auth_oauth_error_is_typed() {
        let mapped = map_auth_error(A::OAuth {
            status: 401,
            message: "invalid_grant".into(),
        });
        let details = assert_embedded_failure(
            &mapped,
            codes::AUTH_OAUTH_ERROR,
            FailureCategory::Auth,
            FailureOrigin::Auth,
            false,
            true,
        );
        assert_eq!(details["status"], 401);
        assert_eq!(details["failure"]["statusCode"], 401);
        assert!(mapped.to_string().contains("invalid_grant"));
    }

    #[test]
    fn auth_oauth_transient_status_is_retryable() {
        let mapped = map_auth_error(A::OAuth {
            status: 503,
            message: "unavailable".into(),
        });
        let details = assert_embedded_failure(
            &mapped,
            codes::AUTH_OAUTH_ERROR,
            FailureCategory::Auth,
            FailureOrigin::Auth,
            true,
            true,
        );
        assert_eq!(details["failure"]["statusCode"], 503);
    }

    #[test]
    fn auth_io_is_storage_error() {
        let mapped = map_auth_error(A::Io(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "x",
        )));
        let details = assert_embedded_failure(
            &mapped,
            codes::AUTH_STORAGE_ERROR,
            FailureCategory::Auth,
            FailureOrigin::Auth,
            false,
            true,
        );
        assert_eq!(details["kind"], "NotFound");
    }

    #[test]
    fn auth_json_is_storage_error() {
        let serde_err = serde_json::from_str::<String>("not json").unwrap_err();
        let mapped = map_auth_error(A::json("decode auth", serde_err));
        let details = assert_embedded_failure(
            &mapped,
            codes::AUTH_STORAGE_ERROR,
            FailureCategory::Auth,
            FailureOrigin::Auth,
            false,
            true,
        );
        assert_eq!(details["operation"], "decode auth");
    }

    #[test]
    fn auth_malformed_provider_auth_is_not_configured() {
        let mapped = map_auth_error(A::MalformedProviderAuth {
            provider: "google".into(),
            details: "unknown field `endpoint`".into(),
        });
        let details = assert_embedded_failure(
            &mapped,
            codes::AUTH_NOT_CONFIGURED,
            FailureCategory::Auth,
            FailureOrigin::Auth,
            false,
            true,
        );
        assert_eq!(details["provider"], "google");
        assert_eq!(details["reason"], "unknown field `endpoint`");
        let msg = mapped.to_string();
        assert!(msg.contains("google"));
        assert_eq!(details["failure"]["suggestion"], "Run `tron auth google`.");
    }

    #[test]
    fn auth_malformed_auth_file_is_sanitized_storage_error() {
        let mapped = map_auth_error(A::MalformedAuthFile {
            path: "/Users/local-secret/.tron/profiles/auth.json".into(),
            details: "unknown field `services`".into(),
        });
        let details = assert_embedded_failure(
            &mapped,
            codes::AUTH_STORAGE_ERROR,
            FailureCategory::Auth,
            FailureOrigin::Auth,
            false,
            true,
        );
        assert_eq!(details["reason"], "unknown field `services`");
        assert!(!mapped.to_string().contains("/Users/local-secret"));
        assert!(!details.to_string().contains("/Users/local-secret"));
    }
}
