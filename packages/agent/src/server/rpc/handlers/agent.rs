//! Agent handlers: prompt, abort.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;
#[cfg(test)]
use crate::events::EventType;

use crate::server::rpc::agent_commands::AgentCommandService;
use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::handlers::{opt_array, opt_string, require_string_param};
use crate::server::rpc::registry::MethodHandler;
#[path = "agent_prompt_runtime.rs"]
pub(crate) mod prompt_runtime;
#[path = "agent_prompt_service.rs"]
pub(crate) mod prompt_service;

#[cfg(test)]
use prompt_runtime::{
    build_user_event_payload, format_subagent_results, get_pending_subagent_results,
};
use prompt_service::{PromptRequest, spawn_prompt_run};

/// Submit a prompt to the agent for a session.
pub struct PromptHandler;

#[async_trait]
impl MethodHandler for PromptHandler {
    #[instrument(skip(self, ctx), fields(method = "agent.prompt", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let prompt = require_string_param(params.as_ref(), "prompt")?;

        crate::server::rpc::validation::validate_string_param(
            &prompt,
            "prompt",
            crate::server::rpc::validation::MAX_PROMPT_LENGTH,
        )?;

        // Extract optional extra params
        let reasoning_level = opt_string(params.as_ref(), "reasoningLevel");
        let images = opt_array(params.as_ref(), "images").cloned();
        let attachments = opt_array(params.as_ref(), "attachments").cloned();

        // Validate attachment sizes before processing.
        if let Some(ref imgs) = images {
            for img in imgs {
                if let Some(data) = img.get("data").and_then(|v| v.as_str()) {
                    crate::server::rpc::validation::validate_attachment_size(data)?;
                }
            }
        }
        if let Some(ref atts) = attachments {
            for att in atts {
                if let Some(data) = att.get("data").and_then(|v| v.as_str()) {
                    crate::server::rpc::validation::validate_attachment_size(data)?;
                }
            }
        }
        // Verify the session exists and get its details
        let session = AgentCommandService::load_prompt_session(ctx, &session_id).await?;

        let deps = ctx
            .agent_deps
            .as_ref()
            .ok_or_else(|| RpcError::NotAvailable {
                message: "Agent execution dependencies are not configured".into(),
            })?;

        let run_id = uuid::Uuid::now_v7().to_string();

        // Register the run with the orchestrator (tracks CancellationToken).
        // If the session already has an active run, this returns an error.
        let started_run = ctx
            .orchestrator
            .begin_run(&session_id, &run_id)
            .map_err(|e| RpcError::Custom {
                code: e.category().to_uppercase(),
                message: e.to_string(),
                details: None,
            })?;
        spawn_prompt_run(
            ctx,
            deps,
            &session,
            started_run,
            run_id.clone(),
            PromptRequest {
                session_id,
                prompt,
                reasoning_level,
                images,
                attachments,
                message_metadata: None,
            },
        );

        Ok(serde_json::json!({
            "acknowledged": true,
            "runId": run_id,
        }))
    }
}

/// Abort a running agent in a session.
pub struct AbortHandler;

#[async_trait]
impl MethodHandler for AbortHandler {
    #[instrument(skip(self, ctx), fields(method = "agent.abort", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        AgentCommandService::abort(ctx, &session_id)
    }
}

#[cfg(test)]
#[path = "agent/tests.rs"]
mod tests;
