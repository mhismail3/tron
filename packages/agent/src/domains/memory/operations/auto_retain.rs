//! Auto-retain scheduling owned by the memory worker.

use serde_json::Value;

use crate::domains::memory::Deps;
use crate::domains::memory::retain::{self, RetainDeps};
use crate::engine::Invocation;
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::params::require_string_param;

pub(crate) async fn auto_retain_fire(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let payload = &invocation.payload;
    let session_id = require_string_param(Some(payload), "sessionId")?;
    let _run_id = require_string_param(Some(payload), "runId")?;
    let outcome = retain::auto_retain::maybe_fire(
        &RetainDeps::from_memory_deps(deps),
        &session_id,
        Some(invocation.clone()),
    )
    .await;
    Ok(outcome.into_value())
}
