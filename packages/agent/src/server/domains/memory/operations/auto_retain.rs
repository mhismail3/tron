//! Auto-retain scheduling owned by the memory worker.

use serde_json::{Value, json};

use crate::server::domains::memory::Deps;
use crate::server::domains::memory::retain::{self, RetainDeps};
use crate::server::shared::errors::CapabilityError;
use crate::server::shared::params::require_string_param;

pub(crate) async fn auto_retain_fire(
    payload: &Value,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(Some(payload), "sessionId")?;
    let _run_id = require_string_param(Some(payload), "runId")?;
    retain::auto_retain::maybe_fire(&RetainDeps::from_memory_deps(deps), &session_id).await;
    Ok(json!({"fired": true, "reason": null}))
}
