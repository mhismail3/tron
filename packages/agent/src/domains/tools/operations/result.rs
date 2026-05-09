//! Tool workflow operations.
use crate::domains::tools::Deps;
use crate::shared::server::errors;
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::params::require_param;
use crate::shared::server::params::require_string_param;
use serde_json::Value;
use serde_json::json;

pub(crate) async fn tool_result_value(
    payload: &Value,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let _session_id = require_string_param(Some(payload), "sessionId")?;
    let tool_use_id = require_string_param(Some(payload), "toolUseId")?;
    let result = require_param(Some(payload), "result")?;

    if deps
        .orchestrator
        .resolve_tool_call(&tool_use_id, result.clone())
    {
        Ok(json!({
            "success": true,
            "toolCallId": tool_use_id,
        }))
    } else {
        Err(CapabilityError::NotFound {
            code: errors::NOT_FOUND.into(),
            message: format!("No pending tool call '{tool_use_id}'"),
        })
    }
}
