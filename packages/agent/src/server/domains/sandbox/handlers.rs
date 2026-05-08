//! Operation binding for the sandbox worker.

use super::*;

pub(crate) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    match method {
        "sandbox::list_containers" => list_containers(deps).await,
        "sandbox::start_container" => run_container_command("start", &invocation.payload).await,
        "sandbox::stop_container" => run_container_command("stop", &invocation.payload).await,
        "sandbox::kill_container" => run_container_command("kill", &invocation.payload).await,
        "sandbox::remove_container" => remove_container(&invocation.payload, deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("sandbox method {method} is not engine-owned"),
        }),
    }
}
