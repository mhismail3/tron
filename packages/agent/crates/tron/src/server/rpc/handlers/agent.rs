//! Agent handlers: prompt, abort, getState.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;
#[cfg(test)]
use crate::events::EventType;

use crate::server::rpc::agent_commands::AgentCommandService;
use crate::server::rpc::agent_queries::AgentQueryService;
use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::handlers::{opt_array, opt_string, require_string_param};
use crate::server::rpc::registry::MethodHandler;
#[path = "agent_prompt_runtime.rs"]
mod prompt_runtime;
#[path = "agent_prompt_service.rs"]
mod prompt_service;

use prompt_runtime::extract_skills;
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
        let raw_skills_json = opt_array(params.as_ref(), "skills").cloned();
        let raw_spells_json = opt_array(params.as_ref(), "spells").cloned();
        let device_context = opt_string(params.as_ref(), "deviceContext");
        let skills = {
            let tmp = raw_skills_json.clone().map(Value::Array);
            let v = extract_skills(tmp.as_ref());
            if v.is_empty() { None } else { Some(v) }
        };
        let spells = {
            let tmp = raw_spells_json.clone().map(Value::Array);
            let v = extract_skills(tmp.as_ref());
            if v.is_empty() { None } else { Some(v) }
        };

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
                skills,
                spells,
                raw_skills_json,
                raw_spells_json,
                device_context,
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

/// Get the current agent state for a session.
pub struct GetAgentStateHandler;

#[async_trait]
impl MethodHandler for GetAgentStateHandler {
    #[instrument(skip(self, ctx), fields(method = "agent.getState", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        AgentQueryService::get_state(ctx, session_id).await
    }
}

#[cfg(test)]
#[path = "agent/tests.rs"]
mod tests;
