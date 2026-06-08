//! Primitive execute operations for the bare engine loop.
//!
//! `capability::execute` is the only model-facing tool on this branch. It does
//! not search, inspect, route, bind, approve, or execute catalog targets. It
//! performs one direct host primitive operation and returns a model-visible
//! observation with engine details for audit.

use std::time::Instant;

use chrono::Utc;
use serde_json::{Value, json};

use super::Deps;
use crate::engine::Invocation;
use crate::shared::protocol::content::CapabilityResultContent;
use crate::shared::protocol::model_capabilities::{CapabilityResult, CapabilityResultBody};
use crate::shared::server::errors::CapabilityError;

mod filesystem;
mod logs;
mod process;
mod state;
mod trace;

use filesystem::{file_read, file_write};
use logs::log_recent;
use process::process_run;
use state::{state_get, state_list, state_set};
use trace::{complete_trace_record, started_trace_record, trace_get, trace_list};

pub(crate) async fn execute_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let started_at = Utc::now().to_rfc3339();
    let start = Instant::now();
    let operation = required_str(&invocation.payload, "operation")?.to_owned();
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
        "process_run" => process_run(invocation).await?,
        "trace_list" => trace_list(invocation, deps)?,
        "trace_get" => trace_get(invocation, deps)?,
        "log_recent" => log_recent(invocation, deps).await?,
        other => {
            return Err(CapabilityError::InvalidParams {
                message: format!(
                    "Unsupported primitive execute operation '{other}'. Use observe, state_get, state_set, state_list, file_read, file_write, process_run, trace_list, trace_get, or log_recent."
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

fn ok_result(text: String, details: Value) -> CapabilityResult {
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

fn internal(message: impl Into<String>) -> CapabilityError {
    CapabilityError::Internal {
        message: message.into(),
    }
}
