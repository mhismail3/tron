//! Replay manifest primitive execute operation.

use serde_json::json;

use super::{Deps, ok_result};
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn replay_manifest(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let session_id = invocation
        .causal_context
        .session_id
        .clone()
        .ok_or_else(|| CapabilityError::InvalidParams {
            message: "replay_manifest requires a current session".to_owned(),
        })?;
    let manifest = crate::domains::session::replay::replay_manifest_value(
        crate::domains::session::replay::ReplayDeps::new(
            deps.event_store.clone(),
            deps.engine_host.clone(),
        ),
        session_id,
    )
    .await?;

    Ok(ok_result(
        "Replay manifest exported.".to_owned(),
        json!({
            "primitiveOperation": "replay_manifest",
            "status": "ok",
            "manifest": manifest
        }),
    ))
}
