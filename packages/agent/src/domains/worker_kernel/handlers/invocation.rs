//! Manual worker dispatch, waiting, lifecycle, and profile stop state.

use std::time::Duration;

use serde_json::{Value, json};

use crate::engine::Invocation;
use crate::shared::server::errors::ToolError;

use super::super::runtime::WorkerInputContractError;
use super::super::types::InvokeRequest;
use super::Deps;
use super::support::required_string;

pub(super) async fn invoke_worker(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, ToolError> {
    let retry_of_invocation_id = invocation
        .payload
        .get("retryOfInvocationId")
        .and_then(Value::as_str);
    let normal_request =
        if retry_of_invocation_id.is_none() {
            let worker_id = required_string(&invocation.payload, "workerId")
                .map_err(|message| ToolError::InvalidParams { message })?;
            let input = invocation.payload.get("input").cloned().ok_or_else(|| {
                ToolError::InvalidParams {
                    message: "worker_invoke requires input".to_owned(),
                }
            })?;
            deps.runtime
                .validate_active_input_contract(&worker_id, &input)
                .map_err(worker_input_contract_error)?;
            Some((worker_id, input))
        } else {
            None
        };
    let key = invocation
        .payload
        .get("idempotencyKey")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .or_else(|| invocation.causal_context.idempotency_key.clone())
        .unwrap_or_else(|| format!("manual:{}", invocation.id));
    let mode = invocation
        .payload
        .get("mode")
        .and_then(Value::as_str)
        .unwrap_or("wait");
    let model_tool_invocation_id = invocation.causal_context.model_tool_invocation_id();
    let parent_worker_invocation_id = invocation.causal_context.origin_worker_invocation_id();
    let parent_worker_tool_ordinal = invocation.causal_context.origin_worker_tool_ordinal();
    let record = match (mode, retry_of_invocation_id, normal_request) {
        ("enqueue", Some(retry_of), None) => deps.runtime.retry_enqueue_from_provider_tool(
            retry_of,
            key,
            invocation.causal_context.trace_id.as_str().to_owned(),
            invocation.causal_context.trigger_depth(),
            invocation.causal_context.session_id.clone(),
            model_tool_invocation_id,
            parent_worker_invocation_id,
            parent_worker_tool_ordinal,
        ),
        ("wait", Some(retry_of), None) => {
            deps.runtime
                .retry_from_provider_tool(
                    retry_of,
                    key,
                    invocation.causal_context.trace_id.as_str().to_owned(),
                    invocation.causal_context.trigger_depth(),
                    invocation.causal_context.session_id.clone(),
                    model_tool_invocation_id,
                    parent_worker_invocation_id,
                    parent_worker_tool_ordinal,
                )
                .await
        }
        ("enqueue", None, Some((worker_id, input))) => deps.runtime.enqueue_from_provider_tool(
            InvokeRequest {
                worker_id,
                input,
                idempotency_key: key,
                trace_id: invocation.causal_context.trace_id.as_str().to_owned(),
                causal_depth: invocation.causal_context.trigger_depth(),
                trigger_kind: "manual".to_owned(),
                origin_session_id: invocation.causal_context.session_id.clone(),
            },
            model_tool_invocation_id,
            parent_worker_invocation_id,
            parent_worker_tool_ordinal,
        ),
        ("wait", None, Some((worker_id, input))) => {
            deps.runtime
                .invoke_from_provider_tool(
                    InvokeRequest {
                        worker_id,
                        input,
                        idempotency_key: key,
                        trace_id: invocation.causal_context.trace_id.as_str().to_owned(),
                        causal_depth: invocation.causal_context.trigger_depth(),
                        trigger_kind: "manual".to_owned(),
                        origin_session_id: invocation.causal_context.session_id.clone(),
                    },
                    model_tool_invocation_id,
                    parent_worker_invocation_id,
                    parent_worker_tool_ordinal,
                )
                .await
        }
        mode => {
            return Err(ToolError::InvalidParams {
                message: format!("unsupported worker invocation request '{mode:?}'"),
            });
        }
    };
    let record = record.map_err(|message| ToolError::Internal { message })?;
    deps.runtime
        .provider_invocation_record(record)
        .map_err(|message| ToolError::Internal { message })
}

fn worker_input_contract_error(error: WorkerInputContractError) -> ToolError {
    match error {
        WorkerInputContractError::Invalid(message) => ToolError::InvalidParams { message },
        WorkerInputContractError::Internal(message) => ToolError::Internal { message },
    }
}

pub(super) async fn await_worker(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    let timeout = Duration::from_secs(
        invocation
            .payload
            .get("timeoutSeconds")
            .and_then(Value::as_u64)
            .unwrap_or(10)
            .min(10),
    );
    let (record, timed_out) = deps
        .runtime
        .await_invocation(
            &required_string(&invocation.payload, "invocationId")?,
            timeout,
        )
        .await?;
    Ok(json!({
        "invocation":deps.runtime.provider_invocation_record(record)?,
        "timedOut":timed_out
    }))
}

pub(super) async fn read_worker_result(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, String> {
    let pointer = invocation
        .payload
        .get("pointer")
        .and_then(Value::as_str)
        .unwrap_or("");
    let offset = invocation
        .payload
        .get("offset")
        .and_then(Value::as_u64)
        .unwrap_or_default()
        .try_into()
        .map_err(|_| "worker result offset is too large".to_owned())?;
    let limit = invocation
        .payload
        .get("limit")
        .and_then(Value::as_u64)
        .unwrap_or(10)
        .try_into()
        .map_err(|_| "worker result limit is too large".to_owned())?;
    deps.runtime.read_worker_result(
        invocation,
        &required_string(&invocation.payload, "invocationId")?,
        pointer,
        offset,
        limit,
    )
}

pub(super) async fn detach_worker_invocation(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, String> {
    deps.runtime.provider_invocation_record(
        deps.runtime
            .detach_invocation(&required_string(&invocation.payload, "invocationId")?)
            .await?,
    )
}

pub(super) async fn cancel_worker_invocation(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, String> {
    let record = deps
        .runtime
        .cancel_invocation(&required_string(&invocation.payload, "invocationId")?)
        .await?;
    deps.runtime.provider_invocation_record(record)
}

pub(super) async fn set_enabled(
    invocation: &Invocation,
    deps: &Deps,
    enabled: bool,
) -> Result<Value, String> {
    deps.runtime
        .set_enabled(&required_string(&invocation.payload, "workerId")?, enabled)
        .await
}

pub(super) async fn stop_worker(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime
        .stop_worker(&required_string(&invocation.payload, "workerId")?)
        .await
}

pub(super) async fn rollback(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime
        .rollback(
            &required_string(&invocation.payload, "workerId")?,
            &required_string(&invocation.payload, "version")?,
        )
        .await
}

pub(super) async fn retire(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime
        .retire(&required_string(&invocation.payload, "workerId")?)
        .await
}

pub(super) async fn purge(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    let worker_id = required_string(&invocation.payload, "workerId")?;
    serde_json::to_value(deps.runtime.purge(&worker_id).await?).map_err(|error| error.to_string())
}

pub(super) async fn stop_all(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    let stopped = invocation
        .payload
        .get("stopped")
        .and_then(Value::as_bool)
        .ok_or_else(|| "worker_stop_all requires stopped".to_owned())?;
    deps.runtime.set_stop_all(stopped).await?;
    Ok(json!({"stopped":stopped}))
}

#[cfg(test)]
mod tests {
    use crate::shared::server::errors::{INTERNAL_ERROR, INVALID_PARAMS};

    use super::*;

    #[test]
    fn nested_worker_schema_errors_are_invalid_requests() {
        let error = worker_input_contract_error(WorkerInputContractError::Invalid(
            "worker input does not match its schema".to_owned(),
        ));
        assert_eq!(error.code(), INVALID_PARAMS);
    }

    #[test]
    fn worker_contract_load_errors_remain_internal() {
        let error = worker_input_contract_error(WorkerInputContractError::Internal(
            "load worker contract".to_owned(),
        ));
        assert_eq!(error.code(), INTERNAL_ERROR);
    }
}
