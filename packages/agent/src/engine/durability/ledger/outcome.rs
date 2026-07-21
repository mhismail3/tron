//! Persisted invocation outcome projections for the engine ledger.

use serde::Serialize;
use serde_json::Value;

use crate::engine::invocation::model::{Invocation, InvocationResult};
use crate::engine::kernel::errors::EngineError;
use crate::engine::kernel::ids::{InvocationId, WorkerId};
use crate::engine::kernel::types::{CatalogRevision, FunctionRevision};

/// Stable projection of an engine error for persisted history.
#[derive(Clone, Debug, PartialEq, Serialize, serde::Deserialize)]
pub struct StoredEngineError {
    /// Stable error kind.
    pub kind: String,
    /// Human-readable error message.
    pub message: String,
    /// Structured details where the originating error exposes them.
    pub details: Value,
}

impl StoredEngineError {
    /// Project an [`EngineError`] into a stable stored representation.
    #[must_use]
    pub fn from_engine_error(error: &EngineError) -> Self {
        let stored = match error {
            EngineError::InvalidId { kind, value } => Self {
                kind: "invalid_id".to_owned(),
                message: error.to_string(),
                details: serde_json::json!({ "kind": kind, "value": value }),
            },
            EngineError::InvalidFunctionId(value) => Self {
                kind: "invalid_function_id".to_owned(),
                message: error.to_string(),
                details: serde_json::json!({ "value": value }),
            },
            EngineError::NotFound { kind, id } => Self {
                kind: "not_found".to_owned(),
                message: error.to_string(),
                details: serde_json::json!({ "kind": kind, "id": id }),
            },
            EngineError::OwnerMismatch {
                kind,
                id,
                owner,
                attempted_owner,
            } => Self {
                kind: "owner_mismatch".to_owned(),
                message: error.to_string(),
                details: serde_json::json!({
                    "kind": kind,
                    "id": id,
                    "owner": owner,
                    "attemptedOwner": attempted_owner,
                }),
            },
            EngineError::NamespaceDenied {
                worker_id,
                function_id,
            } => Self {
                kind: "namespace_denied".to_owned(),
                message: error.to_string(),
                details: serde_json::json!({
                    "workerId": worker_id,
                    "functionId": function_id,
                }),
            },
            EngineError::IdempotencyConflict {
                function_id,
                key,
                reason,
            } => Self {
                kind: "idempotency_conflict".to_owned(),
                message: error.to_string(),
                details: serde_json::json!({
                    "functionId": function_id,
                    "key": key,
                    "reason": reason,
                }),
            },
            EngineError::LedgerFailure { operation, message } => Self {
                kind: "ledger_failure".to_owned(),
                message: error.to_string(),
                details: serde_json::json!({ "operation": operation, "message": message }),
            },
            EngineError::StoredInvocationError { kind, message } => Self {
                kind: "stored_invocation_error".to_owned(),
                message: error.to_string(),
                details: serde_json::json!({ "kind": kind, "message": message }),
            },
            EngineError::InvalidSchema {
                function_id,
                direction,
                message,
            } => Self {
                kind: "invalid_schema".to_owned(),
                message: error.to_string(),
                details: serde_json::json!({
                    "functionId": function_id,
                    "direction": direction,
                    "message": message,
                }),
            },
            EngineError::SchemaViolation {
                function_id,
                direction,
                path,
                message,
            } => Self {
                kind: "schema_violation".to_owned(),
                message: error.to_string(),
                details: serde_json::json!({
                    "functionId": function_id,
                    "direction": direction,
                    "path": path,
                    "message": message,
                }),
            },
            EngineError::StaleFunctionSurface {
                function_id,
                expected_revision,
                actual_revision,
                expected_worker_version,
                actual_worker_version,
            } => Self {
                kind: "stale_function_surface".to_owned(),
                message: error.to_string(),
                details: serde_json::json!({
                    "functionId": function_id,
                    "expectedRevision": expected_revision,
                    "actualRevision": actual_revision,
                    "expectedWorkerVersion": expected_worker_version,
                    "actualWorkerVersion": actual_worker_version,
                }),
            },
            EngineError::PolicyViolation(message) => Self {
                kind: "policy_violation".to_owned(),
                message: error.to_string(),
                details: serde_json::json!({ "message": message }),
            },
            EngineError::DomainFailure {
                domain,
                code,
                message,
                details,
            } => Self {
                kind: "domain_failure".to_owned(),
                message: error.to_string(),
                details: serde_json::json!({
                    "domain": domain,
                    "code": code,
                    "message": message,
                    "details": details,
                }),
            },
            EngineError::InvocationCancelled => Self {
                kind: "invocation_cancelled".to_owned(),
                message: error.to_string(),
                details: serde_json::json!({}),
            },
            EngineError::HandlerFailed(message) => Self {
                kind: "handler_failed".to_owned(),
                message: error.to_string(),
                details: serde_json::json!({ "message": message }),
            },
        };
        stored.redacted_for_storage()
    }

    #[must_use]
    fn redacted_for_storage(&self) -> Self {
        Self {
            kind: self.kind.clone(),
            message: crate::shared::foundation::redaction::redact_sensitive_content(&self.message),
            details: crate::shared::foundation::redaction::redact_sensitive_json(&self.details),
        }
    }

    /// Convert a stored error into an engine result error for replay.
    #[must_use]
    pub fn to_replay_error(&self) -> EngineError {
        if self.kind == "schema_violation" {
            return EngineError::SchemaViolation {
                function_id: self
                    .details
                    .get("functionId")
                    .and_then(Value::as_str)
                    .unwrap_or("stored")
                    .to_owned(),
                direction: match self.details.get("direction").and_then(Value::as_str) {
                    Some("response") => "response",
                    _ => "request",
                },
                path: self
                    .details
                    .get("path")
                    .and_then(Value::as_str)
                    .unwrap_or("$")
                    .to_owned(),
                message: self
                    .details
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or(&self.message)
                    .to_owned(),
            };
        }
        if self.kind == "policy_violation" {
            return EngineError::PolicyViolation(
                self.details
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or(&self.message)
                    .to_owned(),
            );
        }
        if self.kind == "stale_function_surface" {
            return EngineError::StaleFunctionSurface {
                function_id: self
                    .details
                    .get("functionId")
                    .and_then(Value::as_str)
                    .unwrap_or("stored")
                    .to_owned(),
                expected_revision: self
                    .details
                    .get("expectedRevision")
                    .and_then(Value::as_u64)
                    .unwrap_or(0),
                actual_revision: self
                    .details
                    .get("actualRevision")
                    .and_then(Value::as_u64)
                    .unwrap_or(0),
                expected_worker_version: self
                    .details
                    .get("expectedWorkerVersion")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned),
                actual_worker_version: self
                    .details
                    .get("actualWorkerVersion")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned),
            };
        }
        if self.kind == "domain_failure" {
            let domain = self
                .details
                .get("domain")
                .and_then(Value::as_str)
                .unwrap_or("stored")
                .to_owned();
            let code = self
                .details
                .get("code")
                .and_then(Value::as_str)
                .unwrap_or("STORED_INVOCATION_ERROR")
                .to_owned();
            let message = self
                .details
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or(&self.message)
                .to_owned();
            let details = self
                .details
                .get("details")
                .cloned()
                .filter(|value| !value.is_null());
            return EngineError::DomainFailure {
                domain,
                code,
                message,
                details,
            };
        }
        if self.kind == "invocation_cancelled" {
            return EngineError::InvocationCancelled;
        }
        EngineError::StoredInvocationError {
            kind: self.kind.clone(),
            message: self.message.clone(),
        }
    }
}

/// Stable stored invocation outcome.
#[derive(Clone, Debug, PartialEq, Serialize, serde::Deserialize)]
pub struct StoredInvocationOutcome {
    /// Successful result value.
    pub value: Option<Value>,
    /// Stable error projection.
    pub error: Option<StoredEngineError>,
}

impl StoredInvocationOutcome {
    /// Project an invocation result into stable storage.
    #[must_use]
    pub fn from_result(result: &InvocationResult) -> Self {
        Self {
            value: result
                .value
                .as_ref()
                .map(crate::shared::foundation::redaction::redact_sensitive_json),
            error: result
                .error
                .as_ref()
                .map(StoredEngineError::from_engine_error),
        }
    }

    /// Return the audit-safe projection accepted by durable and in-memory
    /// idempotency ledgers.
    #[must_use]
    pub(crate) fn redacted_for_storage(&self) -> Self {
        Self {
            value: self
                .value
                .as_ref()
                .map(crate::shared::foundation::redaction::redact_sensitive_json),
            error: self
                .error
                .as_ref()
                .map(StoredEngineError::redacted_for_storage),
        }
    }

    /// Rebuild a replay result for the current invocation.
    #[must_use]
    pub fn to_replay_result(
        &self,
        invocation: &Invocation,
        worker_id: WorkerId,
        function_revision: FunctionRevision,
        catalog_revision: CatalogRevision,
        replayed_from: InvocationId,
    ) -> InvocationResult {
        InvocationResult {
            invocation_id: invocation.id.clone(),
            function_id: invocation.function_id.clone(),
            worker_id,
            function_revision,
            catalog_revision,
            trace_id: invocation.causal_context.trace_id.clone(),
            value: self
                .value
                .clone()
                .or(Some(Value::Null))
                .filter(|_| self.error.is_none()),
            error: self.error.as_ref().map(StoredEngineError::to_replay_error),
            replayed_from: Some(replayed_from),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::invocation::model::CausalContext;
    use crate::engine::{ActorId, ActorKind, FunctionId, TraceId};

    #[test]
    fn stored_outcome_redacts_one_time_credential_but_live_result_stays_raw() {
        let invocation = Invocation::new_sync(
            FunctionId::new("worker_kernel::webhook_rotate").unwrap(),
            serde_json::json!({}),
            CausalContext::new(
                ActorId::new("agent-secret").unwrap(),
                ActorKind::Agent,
                TraceId::new("trace-secret").unwrap(),
            ),
        );
        let token = "trwh_0123456789abcdef0123456789abcdef";
        let result = InvocationResult::success(
            &invocation,
            WorkerId::new("worker-kernel").unwrap(),
            FunctionRevision(1),
            CatalogRevision(1),
            serde_json::json!({"token":token}),
        );

        let stored = StoredInvocationOutcome::from_result(&result);

        assert_eq!(stored.value.as_ref().unwrap()["token"], "****");
        assert_eq!(result.value.as_ref().unwrap()["token"], token);
    }
}
