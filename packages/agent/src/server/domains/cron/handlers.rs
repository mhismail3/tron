//! Operation binding for the cron worker.

use super::operations::*;
use super::*;

pub(crate) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    match method {
        "cron::list" => cron_list_value(&invocation.payload, deps).await,
        "cron::get" => cron_get_value(&invocation.payload, deps).await,
        "cron::create" => cron_create_value(&invocation.payload, invocation, deps).await,
        "cron::update" => cron_update_value(&invocation.payload, invocation, deps).await,
        "cron::delete" => cron_delete_value(&invocation.payload, invocation, deps).await,
        "cron::run" => cron_run_value(&invocation.payload, invocation, deps).await,
        "cron::status" => cron_status_value(deps).await,
        "cron::get_runs" => cron_get_runs_value(&invocation.payload, deps).await,
        "cron::scheduled_fire" => {
            cron_scheduled_fire_value(&invocation.payload, invocation, deps).await
        }
        _ => Err(CapabilityError::Internal {
            message: format!("cron method {method} is not engine-owned"),
        }),
    }
}
