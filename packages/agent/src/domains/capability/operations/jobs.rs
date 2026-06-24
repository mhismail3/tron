//! Durable job primitive execute operations.

use serde_json::{Value, json};

use super::{Deps, ok_result};
use crate::domains::jobs;
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn job_start(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let result = jobs::service::start_job_value(
        &deps.engine_host,
        deps.shutdown_coordinator.clone(),
        jobs::runtime(),
        invocation,
        &invocation.payload,
    )
    .await?;
    job_result("job_start", result)
}

pub(super) async fn job_status(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let result =
        jobs::service::status_job_value(&deps.engine_host, invocation, &invocation.payload).await?;
    job_result("job_status", result)
}

pub(super) async fn job_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let result =
        jobs::service::list_jobs_value(&deps.engine_host, invocation, &invocation.payload).await?;
    job_result("job_list", result)
}

pub(super) async fn job_log(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let result =
        jobs::service::log_job_value(&deps.engine_host, invocation, &invocation.payload).await?;
    job_result("job_log", result)
}

pub(super) async fn job_cancel(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let result = jobs::service::cancel_job_value(
        &deps.engine_host,
        jobs::runtime(),
        invocation,
        &invocation.payload,
    )
    .await?;
    job_result("job_cancel", result)
}

fn job_result(operation: &'static str, result: Value) -> Result<CapabilityResult, CapabilityError> {
    let status = result["status"].as_str().unwrap_or("ok");
    let text = match operation {
        "job_list" => {
            let count = result["jobs"].as_array().map_or(0, Vec::len);
            format!("{operation} {status}: {count} job(s)")
        }
        "job_log" => format!(
            "{operation} {status}: {}\nstdout:\n{}\nstderr:\n{}",
            result["jobResourceId"].as_str().unwrap_or("unknown"),
            result["stdoutPreview"].as_str().unwrap_or(""),
            result["stderrPreview"].as_str().unwrap_or("")
        ),
        _ => format!(
            "{operation} {status}: {}",
            result
                .pointer("/job/jobResourceId")
                .or_else(|| result.get("jobResourceId"))
                .and_then(Value::as_str)
                .unwrap_or("unknown")
        ),
    };
    Ok(ok_result(
        text,
        json!({
            "primitiveOperation": operation,
            "status": status,
            "jobs": result
        }),
    ))
}
