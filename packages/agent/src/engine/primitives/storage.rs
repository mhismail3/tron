//! Storage primitive worker contracts.
//!
//! Storage functions expose the unified `tron.sqlite` runtime as canonical
//! engine capabilities. They do not bypass the engine ledger: checkpoint,
//! export, stats, and retention requests are normal invocations with authority,
//! idempotency, and audit records.

use serde_json::{Value, json};

use super::{
    PrimitiveFunctionRegistration, STORAGE_WORKER_ID, host_dispatched_registration,
    primitive_function,
};
use crate::engine::{EffectClass, IdempotencyContract, Result, RiskLevel, VisibilityScope};

pub(crate) const STATS_FUNCTION: &str = "storage::stats";
pub(crate) const CHECKPOINT_FUNCTION: &str = "storage::checkpoint";
pub(crate) const EXPORT_SNAPSHOT_FUNCTION: &str = "storage::export_snapshot";
pub(crate) const RETENTION_RUN_FUNCTION: &str = "storage::retention_run";

pub(super) fn registrations() -> Result<Vec<PrimitiveFunctionRegistration>> {
    Ok(vec![
        system_registration(
            primitive_function(
                STATS_FUNCTION,
                STORAGE_WORKER_ID,
                "report unified engine storage size and table ownership",
                EffectClass::PureRead,
                "storage.read",
            )
            .with_request_schema(empty_schema())
            .with_response_schema(json!({
                "type": "object",
                "required": ["stats"],
                "additionalProperties": false,
                "properties": {"stats": {"type": "object"}}
            })),
        ),
        system_registration(
            primitive_function(
                CHECKPOINT_FUNCTION,
                STORAGE_WORKER_ID,
                "checkpoint unified storage WAL into the main SQLite file",
                EffectClass::IdempotentWrite,
                "storage.write",
            )
            .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
            .with_risk(RiskLevel::Medium)
            .with_request_schema(empty_schema())
            .with_response_schema(json!({
                "type": "object",
                "required": ["checkpoint"],
                "additionalProperties": false,
                "properties": {"checkpoint": {"type": "object"}}
            })),
        ),
        system_registration(
            primitive_function(
                EXPORT_SNAPSHOT_FUNCTION,
                STORAGE_WORKER_ID,
                "export unified storage into a portable single-file SQLite snapshot",
                EffectClass::IdempotentWrite,
                "storage.write",
            )
            .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
            .with_risk(RiskLevel::Medium)
            .with_request_schema(export_schema())
            .with_response_schema(json!({
                "type": "object",
                "required": ["export"],
                "additionalProperties": false,
                "properties": {"export": {"type": "object"}}
            })),
        ),
        system_registration(
            primitive_function(
                RETENTION_RUN_FUNCTION,
                STORAGE_WORKER_ID,
                "run unified storage retention and blob cleanup",
                EffectClass::IdempotentWrite,
                "storage.write",
            )
            .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
            .with_risk(RiskLevel::Medium)
            .with_request_schema(retention_schema())
            .with_response_schema(json!({
                "type": "object",
                "required": ["retention"],
                "additionalProperties": false,
                "properties": {"retention": {"type": "object"}}
            })),
        ),
    ])
}

fn system_registration(
    mut definition: crate::engine::FunctionDefinition,
) -> PrimitiveFunctionRegistration {
    definition.visibility = VisibilityScope::System;
    host_dispatched_registration(definition)
}

fn empty_schema() -> Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {}
    })
}

fn export_schema() -> Value {
    json!({
        "type": "object",
        "required": ["snapshotPath"],
        "additionalProperties": false,
        "properties": {
            "snapshotPath": {"type": "string"}
        }
    })
}

fn retention_schema() -> Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "dryRun": {"type": "boolean"},
            "verboseRetentionDays": {"type": "integer"}
        }
    })
}
