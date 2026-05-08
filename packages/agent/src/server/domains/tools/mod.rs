//! tools domain worker.
//!
//! This module owns canonical function execution for the tools namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.

pub(crate) mod contract;
pub(crate) mod spec;

use super::*;
#[derive(Clone)]
pub(crate) struct Deps {
    orchestrator: Arc<Orchestrator>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &EngineCapabilityDeps) -> Self {
        Self {
            orchestrator: deps.orchestrator.clone(),
        }
    }
}

pub(crate) mod interactive_enrichment;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    match method {
        "tool::result" => tool_result_value(&invocation.payload, deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("tool method {method} is not engine-owned"),
        }),
    }
}

async fn tool_result_value(payload: &Value, deps: &Deps) -> Result<Value, CapabilityError> {
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
