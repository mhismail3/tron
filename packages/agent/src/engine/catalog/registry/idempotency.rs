//! Invocation idempotency reservation and replay handling.

use serde_json::Value;
use sha2::{Digest, Sha256};

use super::LiveCatalog;
use crate::engine::durability::ledger::{
    IdempotencyEntry, IdempotencyKey, IdempotencyReservation, IdempotencyStatus,
    StoredInvocationOutcome,
};
use crate::engine::invocation::model::{Invocation, InvocationResult};
use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::types::{DedupeScope, FunctionDefinition, IdempotencyScope};

impl LiveCatalog {
    pub(super) fn result_for_existing_idempotency(
        &self,
        function: &FunctionDefinition,
        invocation: &Invocation,
        existing: &IdempotencyEntry,
        payload_fingerprint: &str,
    ) -> InvocationResult {
        if existing.payload_fingerprint != payload_fingerprint {
            return InvocationResult::error(
                invocation,
                function.owner_worker.clone(),
                function.revision,
                self.revision,
                EngineError::IdempotencyConflict {
                    function_id: function.id.to_string(),
                    key: existing.key.key.clone(),
                    reason: "same key was used with a different payload".to_owned(),
                },
            );
        }
        if existing.function_revision != function.revision {
            return InvocationResult::error(
                invocation,
                function.owner_worker.clone(),
                function.revision,
                self.revision,
                EngineError::IdempotencyConflict {
                    function_id: function.id.to_string(),
                    key: existing.key.key.clone(),
                    reason: "same key was used across function revisions".to_owned(),
                },
            );
        }

        match existing.status {
            IdempotencyStatus::InProgress => InvocationResult::error(
                invocation,
                function.owner_worker.clone(),
                function.revision,
                self.revision,
                EngineError::IdempotencyConflict {
                    function_id: function.id.to_string(),
                    key: existing.key.key.clone(),
                    reason: "previous attempt is still in progress".to_owned(),
                },
            ),
            IdempotencyStatus::Completed => existing.outcome.as_ref().map_or_else(
                || {
                    InvocationResult::error(
                        invocation,
                        function.owner_worker.clone(),
                        function.revision,
                        self.revision,
                        EngineError::IdempotencyConflict {
                            function_id: function.id.to_string(),
                            key: existing.key.key.clone(),
                            reason: "completed reservation is missing outcome".to_owned(),
                        },
                    )
                },
                |outcome| {
                    outcome.to_replay_result(
                        invocation,
                        function.owner_worker.clone(),
                        function.revision,
                        self.revision,
                        existing.first_invocation_id.clone(),
                    )
                },
            ),
        }
    }

    /// Complete a reservation after executing work.
    pub(in crate::engine) fn complete_invocation_idempotency(
        &mut self,
        reservation: &IdempotencyReservation,
        invocation: &Invocation,
        function: &FunctionDefinition,
        result: &InvocationResult,
    ) -> Option<InvocationResult> {
        self.ledger
            .complete_idempotency(
                &reservation.key,
                &invocation.id,
                StoredInvocationOutcome::from_result(result),
            )
            .err()
            .map(|err| {
                InvocationResult::error(
                    invocation,
                    function.owner_worker.clone(),
                    function.revision,
                    self.revision,
                    err,
                )
            })
    }

    pub(super) fn idempotency_lookup(
        &self,
        function: &FunctionDefinition,
        invocation: &Invocation,
    ) -> Result<Option<IdempotencyReservation>> {
        let Some(contract) = &function.idempotency else {
            return Ok(None);
        };
        let Some(key) = &invocation.causal_context.idempotency_key else {
            return Ok(None);
        };
        let scope = idempotency_scope_value(&contract.dedupe_scope, invocation)?;
        Ok(Some(IdempotencyReservation {
            key: IdempotencyKey {
                function_id: function.id.clone(),
                scope,
                key: key.clone(),
            },
            payload_fingerprint: payload_fingerprint(&invocation.payload),
            function_revision: function.revision,
            invocation_id: invocation.id.clone(),
        }))
    }
}

fn idempotency_scope_value(
    scope: &DedupeScope,
    invocation: &Invocation,
) -> Result<IdempotencyScope> {
    match scope {
        DedupeScope::Session => invocation
            .causal_context
            .session_id
            .clone()
            .map(|session| IdempotencyScope::new("session", session))
            .ok_or_else(|| {
                EngineError::PolicyViolation(
                    "session-scoped idempotency requires a session id".to_owned(),
                )
            }),
        DedupeScope::System => Ok(IdempotencyScope::new("system", "system")),
    }
}

fn payload_fingerprint(payload: &Value) -> String {
    let mut canonical = String::new();
    write_canonical_json(payload, &mut canonical);
    let digest = Sha256::digest(canonical.as_bytes());
    hex::encode(digest)
}

fn write_canonical_json(value: &Value, out: &mut String) {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(value) => out.push_str(if *value { "true" } else { "false" }),
        Value::Number(value) => out.push_str(&value.to_string()),
        Value::String(value) => {
            let encoded = serde_json::to_string(value).expect("string serialization cannot fail");
            out.push_str(&encoded);
        }
        Value::Array(values) => {
            out.push('[');
            for (index, value) in values.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_canonical_json(value, out);
            }
            out.push(']');
        }
        Value::Object(values) => {
            out.push('{');
            let mut keys = values.keys().collect::<Vec<_>>();
            keys.sort();
            for (index, key) in keys.into_iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                let encoded = serde_json::to_string(key).expect("string serialization cannot fail");
                out.push_str(&encoded);
                out.push(':');
                write_canonical_json(
                    values.get(key).expect("key was collected from this object"),
                    out,
                );
            }
            out.push('}');
        }
    }
}
