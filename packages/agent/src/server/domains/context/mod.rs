//! context domain worker.
//!
//! This module owns canonical function execution for the context namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.

pub(crate) mod contract;

use super::*;

pub(crate) fn worker_module(
    deps: &EngineCapabilityDeps,
) -> crate::engine::Result<DomainWorkerModule> {
    super::domain_worker_module(
        "context",
        contract::capabilities()?,
        Deps::from_engine(deps),
        super::context_handler,
    )
}
#[derive(Clone)]
pub(crate) struct Deps {
    capability_context: Arc<ServerCapabilityContext>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &EngineCapabilityDeps) -> Self {
        Self {
            capability_context: deps.capability_context.clone(),
        }
    }
}

pub(crate) mod commands;
pub(crate) mod queries;
pub(crate) mod service;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let payload = &invocation.payload;
    match method {
        "context::get_snapshot" => {
            let session_id = require_string_param(Some(payload), "sessionId")?;
            crate::server::domains::context::queries::ContextQueryService::get_snapshot(
                deps.capability_context.as_ref(),
                session_id,
            )
            .await
        }
        "context::get_detailed_snapshot" => {
            let session_id = require_string_param(Some(payload), "sessionId")?;
            crate::server::domains::context::queries::ContextQueryService::get_detailed_snapshot(
                deps.capability_context.as_ref(),
                session_id,
            )
            .await
        }
        "context::get_audit_trace" => {
            let session_id = require_string_param(Some(payload), "sessionId")?;
            let turn = payload
                .get("turn")
                .and_then(Value::as_u64)
                .map(u32::try_from)
                .transpose()
                .map_err(|_| CapabilityError::InvalidParams {
                    message: "turn must fit in u32".into(),
                })?;
            crate::server::domains::context::queries::ContextQueryService::get_audit_trace(
                deps.capability_context.as_ref(),
                session_id,
                turn,
            )
            .await
        }
        "context::should_compact" => {
            let session_id = require_string_param(Some(payload), "sessionId")?;
            crate::server::domains::context::queries::ContextQueryService::should_compact(
                deps.capability_context.as_ref(),
                session_id,
            )
            .await
        }
        "context::preview_compaction" => {
            let session_id = require_string_param(Some(payload), "sessionId")?;
            crate::server::domains::context::queries::ContextQueryService::preview_compaction(
                deps.capability_context.as_ref(),
                session_id,
            )
            .await
        }
        "context::can_accept_turn" => {
            let session_id = require_string_param(Some(payload), "sessionId")?;
            crate::server::domains::context::queries::ContextQueryService::can_accept_turn(
                deps.capability_context.as_ref(),
                session_id,
            )
            .await
        }
        "context::confirm_compaction" => {
            let session_id = require_string_param(Some(payload), "sessionId")?;
            let edited_summary = opt_string(Some(payload), "editedSummary");
            crate::server::domains::context::commands::ContextCommandService::confirm_compaction(
                deps.capability_context.as_ref(),
                session_id,
                edited_summary,
            )
            .await
        }
        "context::clear" => {
            let session_id = require_string_param(Some(payload), "sessionId")?;
            crate::server::domains::context::commands::ContextCommandService::clear(
                deps.capability_context.as_ref(),
                session_id,
            )
            .await
        }
        "context::compact" => {
            let session_id = require_string_param(Some(payload), "sessionId")?;
            crate::server::domains::context::commands::ContextCommandService::compact(
                deps.capability_context.as_ref(),
                session_id,
            )
            .await
        }
        _ => Err(CapabilityError::Internal {
            message: format!("context method {method} is not engine-owned"),
        }),
    }
}
