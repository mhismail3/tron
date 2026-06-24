use crate::domains::session::Deps;
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::params::{opt_string, require_string_param};
use serde_json::Value;

pub(crate) async fn session_reconstruct_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    let limit = params
        .and_then(|p| p.get("limit"))
        .and_then(Value::as_u64)
        .map(|value| value as i64);
    let before_event_id = opt_string(params, "beforeEventId");
    crate::domains::session::reconstruction::SessionReconstructionService::reconstruct(
        deps,
        session_id,
        limit,
        before_event_id,
    )
    .await
}
