//! Engine-owned primitive workers.
//!
//! Primitive workers are built into the engine, but they still follow the same
//! worker/function contract shape as domain workers. The host coordinates
//! locking and ledger completion; this module owns primitive worker definitions,
//! schemas, handler bindings, and privileged query response shaping through the
//! local `runtime` module. Backend store ownership lives in `stores`, while
//! worker and function registration assembly lives in `workers`; this root keeps
//! shared primitive constants and payload/schema helpers only.
//! `grant::*` is the engine-owned authority surface; `resource::*` plus the
//! artifact/goal/claim/evidence/decision wrappers form the durable output
//! substrate, including agent-authored memory and rule resources. Materialized-
//! file wrappers keep file bytes tied to resource versions, record damaged
//! truth through the resource store, and block operational reads or rewrites
//! after discard while leaving inspection available. `trigger::*` dispatches
//! registered triggers back through the same trigger runtime used by transports
//! and schedules, so queued trigger delivery is not a harness-only path.
//! `ui::*` stores runtime UI surface resources, validates the bounded schema,
//! and records generic action submissions without server-authored target
//! routing.
//! `storage::*` is the
//! system primitive surface for the unified
//! `tron.sqlite` runtime: stats, retention, checkpoints, and portable snapshot
//! export.

use std::sync::Arc;

use serde_json::{Value, json};

use crate::engine::durability::state::EngineStateScope;
use crate::engine::invocation::model::{InProcessFunctionHandler, Invocation};
use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::ids::{FunctionId, WorkerId};
use crate::engine::kernel::types::{
    AuthorityRequirement, CompensationContract, CompensationKind, EffectClass, FunctionDefinition,
    RiskLevel, VisibilityScope,
};

pub(crate) mod catalog;
pub(crate) mod grant;
pub(crate) mod queue;
pub(crate) mod resource;
pub(in crate::engine) mod runtime;
pub(crate) mod state;
pub(crate) mod storage;
mod stores;
pub(crate) mod stream;
pub(crate) mod trigger;
pub(crate) mod ui;
pub(crate) mod worker;
mod workers;

pub(in crate::engine) use crate::engine::authority::grants::EngineGrantStoreBackend;
pub(in crate::engine) use stores::{
    PrimitiveStores, QueueStoreBackend, ResourceStoreBackend, StateStoreBackend, StreamStoreBackend,
};
pub(in crate::engine) use workers::{primitive_function_definitions, primitive_workers};

pub(crate) const STREAM_WORKER_ID: &str = "stream";
pub(crate) const STATE_WORKER_ID: &str = "state";
pub(crate) const QUEUE_WORKER_ID: &str = "queue";
pub(crate) const RESOURCE_WORKER_ID: &str = "resource";
pub(crate) const TRIGGER_WORKER_ID: &str = "trigger";
pub(crate) const GRANT_WORKER_ID: &str = "grant";
pub(crate) const CATALOG_WORKER_ID: &str = "catalog";
pub(crate) const WORKER_WORKER_ID: &str = "worker";
pub(crate) const STORAGE_WORKER_ID: &str = "storage";
pub(crate) const UI_WORKER_ID: &str = "ui";

/// One primitive function registration.
pub(crate) struct PrimitiveFunctionRegistration {
    /// Function contract.
    pub definition: FunctionDefinition,
    /// In-process handler. Host-dispatched primitives use `None`.
    pub handler: Option<Arc<dyn InProcessFunctionHandler>>,
}

pub(super) fn primitive_function(
    id: &str,
    worker: &str,
    description: &str,
    effect: EffectClass,
    authority_scope: &str,
) -> FunctionDefinition {
    FunctionDefinition::new(
        function_id(id).expect("valid static primitive function id"),
        worker_id(worker).expect("valid static primitive worker id"),
        description,
        VisibilityScope::Agent,
        effect,
    )
    .with_required_authority(AuthorityRequirement::scope(authority_scope))
    .with_risk(if effect.is_mutating() {
        RiskLevel::Medium
    } else {
        RiskLevel::Low
    })
}

pub(super) fn host_dispatched_registration(
    definition: FunctionDefinition,
) -> PrimitiveFunctionRegistration {
    PrimitiveFunctionRegistration {
        definition,
        handler: None,
    }
}

pub(super) fn handled_registration(
    definition: FunctionDefinition,
    handler: Arc<dyn InProcessFunctionHandler>,
) -> PrimitiveFunctionRegistration {
    PrimitiveFunctionRegistration {
        definition,
        handler: Some(handler),
    }
}

pub(super) fn state_scope_from_payload(invocation: &Invocation) -> Result<EngineStateScope> {
    match optional_string(invocation.payload.get("scope"))?
        .unwrap_or_else(|| "session".to_owned())
        .as_str()
    {
        "system" => Ok(EngineStateScope::System),
        "workspace" => {
            let workspace_id = optional_string(invocation.payload.get("workspaceId"))?
                .or(invocation.causal_context.workspace_id.clone())
                .ok_or_else(|| {
                    EngineError::PolicyViolation(
                        "workspace-scoped state requires workspaceId".to_owned(),
                    )
                })?;
            Ok(EngineStateScope::Workspace(workspace_id))
        }
        "session" => {
            let session_id = optional_string(invocation.payload.get("sessionId"))?
                .or(invocation.causal_context.session_id.clone())
                .ok_or_else(|| {
                    EngineError::PolicyViolation(
                        "session-scoped state requires sessionId".to_owned(),
                    )
                })?;
            Ok(EngineStateScope::Session(session_id))
        }
        other => Err(EngineError::PolicyViolation(format!(
            "unsupported state scope {other}"
        ))),
    }
}

pub(super) fn required_string_owned(payload: &Value, field: &str) -> Result<String> {
    Ok(required_str(payload, field)?.to_owned())
}

pub(in crate::engine) fn required_str<'a>(payload: &'a Value, field: &str) -> Result<&'a str> {
    payload.get(field).and_then(Value::as_str).ok_or_else(|| {
        EngineError::PolicyViolation(format!("required field {field} must be a string"))
    })
}

pub(in crate::engine) fn optional_string(value: Option<&Value>) -> Result<Option<String>> {
    value
        .map(|value| {
            value.as_str().map(str::to_owned).ok_or_else(|| {
                EngineError::PolicyViolation("optional field must be a string".to_owned())
            })
        })
        .transpose()
}

pub(in crate::engine) fn optional_u64(value: Option<&Value>) -> Result<Option<u64>> {
    value
        .map(|value| {
            value.as_u64().ok_or_else(|| {
                EngineError::PolicyViolation("optional field must be an integer".to_owned())
            })
        })
        .transpose()
}

pub(super) fn optional_visibility(value: Option<&Value>) -> Result<Option<VisibilityScope>> {
    value
        .map(|value| {
            value
                .as_str()
                .ok_or_else(|| {
                    EngineError::PolicyViolation("visibility must be a string".to_owned())
                })
                .and_then(parse_visibility)
        })
        .transpose()
}

pub(super) fn parse_visibility(value: &str) -> Result<VisibilityScope> {
    match value {
        "internal" => Ok(VisibilityScope::Internal),
        "session" => Ok(VisibilityScope::Session),
        "workspace" => Ok(VisibilityScope::Workspace),
        "system" => Ok(VisibilityScope::System),
        "client" => Ok(VisibilityScope::Client),
        "worker" => Ok(VisibilityScope::Worker),
        "agent" => Ok(VisibilityScope::Agent),
        "admin" => Ok(VisibilityScope::Admin),
        _ => Err(EngineError::PolicyViolation(format!(
            "unsupported visibility {value}"
        ))),
    }
}

pub(super) fn function_id(value: &str) -> Result<FunctionId> {
    FunctionId::new(value)
}

pub(super) fn worker_id(value: &str) -> Result<WorkerId> {
    WorkerId::new(value)
}

pub(super) fn boolean_response_schema(field: &str) -> Value {
    let mut properties = serde_json::Map::new();
    properties.insert(field.to_owned(), json!({"type": "boolean"}));
    json!({
        "type": "object",
        "required": [field],
        "additionalProperties": false,
        "properties": properties
    })
}

pub(super) fn nullable_response_schema(field: &str) -> Value {
    let mut properties = serde_json::Map::new();
    properties.insert(field.to_owned(), json!({}));
    json!({
        "type": "object",
        "required": [field],
        "additionalProperties": false,
        "properties": properties
    })
}

pub(super) fn primitive_compensation(
    kind: CompensationKind,
    notes: &'static str,
) -> CompensationContract {
    CompensationContract::new(kind, notes)
}
