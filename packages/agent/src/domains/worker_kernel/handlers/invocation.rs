//! Manual worker dispatch, waiting, lifecycle, and profile stop state.

use std::time::Duration;

use serde_json::{Value, json};

use crate::engine::Invocation;

use super::super::types::InvokeRequest;
use super::Deps;
use super::support::required_string;

pub(super) async fn invoke_worker(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    let worker_id = required_string(&invocation.payload, "workerId")?;
    let input = invocation
        .payload
        .get("input")
        .cloned()
        .ok_or_else(|| "worker_invoke requires input".to_owned())?;
    let key = invocation
        .payload
        .get("idempotencyKey")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .or_else(|| invocation.causal_context.idempotency_key.clone())
        .unwrap_or_else(|| format!("manual:{}", invocation.id));
    let request = InvokeRequest {
        worker_id,
        input,
        idempotency_key: key,
        trace_id: invocation.causal_context.trace_id.as_str().to_owned(),
        causal_depth: invocation.causal_context.trigger_depth(),
        trigger_kind: "manual".to_owned(),
    };
    let record = match invocation
        .payload
        .get("mode")
        .and_then(Value::as_str)
        .unwrap_or("wait")
    {
        "enqueue" => deps.runtime.enqueue_and_dispatch(request)?,
        "wait" => deps.runtime.invoke(request).await?,
        mode => return Err(format!("unsupported worker invocation mode '{mode}'")),
    };
    serde_json::to_value(record).map_err(|error| error.to_string())
}

pub(super) async fn await_worker(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    let timeout = Duration::from_secs(
        invocation
            .payload
            .get("timeoutSeconds")
            .and_then(Value::as_u64)
            .unwrap_or(30)
            .min(7_200),
    );
    let (record, timed_out) = deps
        .runtime
        .await_invocation(
            &required_string(&invocation.payload, "invocationId")?,
            timeout,
        )
        .await?;
    Ok(json!({"invocation":record,"timedOut":timed_out}))
}

pub(super) async fn cancel_worker_invocation(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, String> {
    let record = deps
        .runtime
        .cancel_invocation(&required_string(&invocation.payload, "invocationId")?)
        .await?;
    serde_json::to_value(record).map_err(|error| error.to_string())
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
