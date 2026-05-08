//! Operation binding for the import worker.

use super::*;

pub(crate) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    match method {
        "import::list_sources" => list_sources(deps).await,
        "import::list_sessions" => list_sessions(&invocation.payload, deps).await,
        "import::preview_session" => preview_session(&invocation.payload, deps).await,
        "import::execute" => execute_import(&invocation.payload, deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("import method {method} is not engine-owned"),
        }),
    }
}
