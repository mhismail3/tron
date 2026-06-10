//! Primitive execute operations for the bare engine loop.
//!
//! `capability::execute` is the only model-facing tool on this branch. It does
//! not search, inspect, route, bind, approve, or execute catalog targets. It
//! performs one direct host primitive operation and returns a model-visible
//! observation with engine details for audit. `replay_manifest` is the only
//! read-only operation that bypasses trace-record creation; tracing that read
//! would mutate the manifest it returns.
//!
//! The operation gate is intentionally stricter than the provider schema:
//! `execute` accepts only trusted agent/system runtime contexts, rejects
//! bootstrap authority grants, requires a derived least-privilege grant for
//! every effectful call, resolves file/process roots from trusted runtime
//! metadata, denies system-scoped state, and keeps trace/log/replay reads bound
//! to the current session. `process_run` additionally inspects the active grant
//! and runs only when it carries `networkPolicy none`.

use std::time::Instant;

use chrono::Utc;
use serde_json::{Value, json};

use super::Deps;
use crate::engine::{ActorKind, Invocation, is_bootstrap_authority_grant_id};
use crate::shared::protocol::content::CapabilityResultContent;
use crate::shared::protocol::model_capabilities::{CapabilityResult, CapabilityResultBody};
use crate::shared::server::errors::CapabilityError;

mod filesystem;
mod logs;
mod process;
mod replay;
mod state;
mod trace;

use filesystem::{file_read, file_write};
use logs::log_recent;
use process::process_run;
use replay::replay_manifest;
use state::{state_get, state_list, state_set};
use trace::{complete_trace_record, started_trace_record, trace_get, trace_list};

pub(crate) async fn execute_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let operation = required_str(&invocation.payload, "operation")?.to_owned();
    validate_execute_context(invocation, &operation)?;
    if operation == "replay_manifest" {
        return result_value(replay_manifest(invocation, deps).await?);
    }
    let _root = filesystem::working_directory(invocation)?;

    let started_at = Utc::now().to_rfc3339();
    let start = Instant::now();
    let mut trace_record = started_trace_record(invocation, deps, &operation, &started_at)?;
    deps.event_store
        .append_trace_record(&trace_record)
        .map_err(|error| internal(format!("record trace start: {error}")))?;

    let result = execute_operation(&operation, invocation, deps).await;
    match result {
        Ok(result) => {
            complete_trace_record(
                &mut trace_record,
                invocation,
                &result,
                None,
                start.elapsed(),
            );
            deps.event_store
                .update_trace_record(&trace_record)
                .map_err(|error| internal(format!("record trace completion: {error}")))?;
            result_value(result)
        }
        Err(error) => {
            complete_trace_record(
                &mut trace_record,
                invocation,
                &error_capability_result(error.to_string(), json!({"status": "failed"})),
                Some(&error),
                start.elapsed(),
            );
            deps.event_store
                .update_trace_record(&trace_record)
                .map_err(|store_error| internal(format!("record trace failure: {store_error}")))?;
            Err(error)
        }
    }
}

fn validate_execute_context(
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
    match operation {
        "state_get" | "state_set" | "state_list" => validate_state_scope(invocation),
        "trace_list" | "trace_get" | "log_recent" | "replay_manifest" => {
            require_current_session(invocation, operation)
        }
        _ => Ok(()),
    }
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

async fn execute_operation(
    operation: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    Ok(match operation {
        "observe" => observe(invocation)?,
        "state_get" => state_get(invocation, deps).await?,
        "state_set" => state_set(invocation, deps).await?,
        "state_list" => state_list(invocation, deps).await?,
        "file_read" => file_read(invocation).await?,
        "file_write" => file_write(invocation).await?,
        "process_run" => process_run(invocation, deps).await?,
        "trace_list" => trace_list(invocation, deps)?,
        "trace_get" => trace_get(invocation, deps)?,
        "log_recent" => log_recent(invocation, deps).await?,
        "replay_manifest" => replay_manifest(invocation, deps).await?,
        other => {
            return Err(CapabilityError::InvalidParams {
                message: format!(
                    "Unsupported primitive execute operation '{other}'. Use observe, state_get, state_set, state_list, file_read, file_write, process_run, trace_list, trace_get, log_recent, or replay_manifest."
                ),
            });
        }
    })
}

fn observe(invocation: &Invocation) -> Result<CapabilityResult, CapabilityError> {
    let input = optional_str(&invocation.payload, "input")?.unwrap_or("");
    Ok(ok_result(
        if input.is_empty() {
            "Observation recorded.".to_owned()
        } else {
            input.to_owned()
        },
        json!({
            "primitiveOperation": "observe",
            "status": "ok"
        }),
    ))
}

fn required_str<'a>(payload: &'a Value, field: &str) -> Result<&'a str, CapabilityError> {
    optional_str(payload, field)?.ok_or_else(|| CapabilityError::InvalidParams {
        message: format!("missing required field {field}"),
    })
}

fn optional_str<'a>(payload: &'a Value, field: &str) -> Result<Option<&'a str>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Ok(Some(value)),
        Some(_) => Err(CapabilityError::InvalidParams {
            message: format!("{field} must be a string"),
        }),
    }
}

fn optional_u64(payload: &Value, field: &str) -> Result<Option<u64>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(value)) => {
            value
                .as_u64()
                .map(Some)
                .ok_or_else(|| CapabilityError::InvalidParams {
                    message: format!("{field} must be a positive integer"),
                })
        }
        Some(_) => Err(CapabilityError::InvalidParams {
            message: format!("{field} must be a positive integer"),
        }),
    }
}

pub(super) fn ok_result(text: String, details: Value) -> CapabilityResult {
    CapabilityResult {
        content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(text)]),
        details: Some(details),
        is_error: Some(false),
        stop_turn: None,
    }
}

fn error_capability_result(text: String, details: Value) -> CapabilityResult {
    CapabilityResult {
        content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(text)]),
        details: Some(details),
        is_error: Some(true),
        stop_turn: None,
    }
}

fn result_value(result: CapabilityResult) -> Result<Value, CapabilityError> {
    serde_json::to_value(result).map_err(|error| internal(format!("serialize result: {error}")))
}

fn compact_json(value: &Value) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "<unserializable>".to_owned())
}

pub(super) fn internal(message: impl Into<String>) -> CapabilityError {
    CapabilityError::Internal {
        message: message.into(),
    }
}

fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}
