//! Auto-retain scheduling owned by the memory worker.

use serde_json::{Value, json};

use crate::domains::memory::Deps;
use crate::domains::memory::retain::{self, RetainDeps};
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::params::require_string_param;

pub(crate) async fn auto_retain_fire(
    payload: &Value,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(Some(payload), "sessionId")?;
    let _run_id = require_string_param(Some(payload), "runId")?;
    retain::auto_retain::maybe_fire(&RetainDeps::from_memory_deps(deps), &session_id).await;
    Ok(json!({"fired": true, "reason": null}))
}
