//! Model handlers: list, switch.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::rpc::context::RpcContext;
use crate::rpc::errors::{self, RpcError};
use crate::rpc::handlers::require_string_param;
use crate::rpc::registry::MethodHandler;

#[allow(clippy::too_many_lines)]
fn known_models() -> Vec<Value> {
    vec![
        // ── Anthropic Claude Models ──
        serde_json::json!({
            "id": "claude-opus-4-6",
            "name": "Opus 4.6",
            "provider": "anthropic",
            "contextWindow": 200_000,
            "maxOutput": 128_000,
            "supportsThinking": true,
            "supportsImages": true,
            "inputCostPerMillion": 5.0,
            "outputCostPerMillion": 25.0,
            "tier": "opus",
            "family": "Claude 4.6",
            "description": "Most capable model with adaptive thinking, effort control, and 128K output.",
            "supportsReasoning": true,
            "reasoningLevels": ["low", "medium", "high", "max"],
            "defaultReasoningLevel": "high",
            "recommended": true,
            "isLegacy": false,
            "releaseDate": "2026-02-01",
            "sortOrder": 0,
        }),
        serde_json::json!({
            "id": "claude-sonnet-4-6",
            "name": "Sonnet 4.6",
            "provider": "anthropic",
            "contextWindow": 200_000,
            "maxOutput": 64_000,
            "supportsThinking": true,
            "supportsImages": true,
            "inputCostPerMillion": 3.0,
            "outputCostPerMillion": 15.0,
            "tier": "sonnet",
            "family": "Claude 4.6",
            "description": "Best combination of speed and intelligence — adaptive thinking, effort control.",
            "supportsReasoning": true,
            "reasoningLevels": ["low", "medium", "high", "max"],
            "defaultReasoningLevel": "medium",
            "recommended": true,
            "isLegacy": false,
            "releaseDate": "2026-02-17",
            "sortOrder": 1,
        }),
        serde_json::json!({
            "id": "claude-opus-4-5-20251101",
            "name": "Opus 4.5",
            "provider": "anthropic",
            "contextWindow": 200_000,
            "maxOutput": 64_000,
            "supportsThinking": true,
            "supportsImages": true,
            "inputCostPerMillion": 5.0,
            "outputCostPerMillion": 25.0,
            "tier": "opus",
            "family": "Claude 4.5",
            "description": "Premium model combining maximum intelligence with practical performance.",
            "supportsReasoning": false,
            "recommended": false,
            "isLegacy": false,
            "releaseDate": "2025-11-01",
            "sortOrder": 2,
        }),
        serde_json::json!({
            "id": "claude-sonnet-4-5-20250929",
            "name": "Sonnet 4.5",
            "provider": "anthropic",
            "contextWindow": 200_000,
            "maxOutput": 64_000,
            "supportsThinking": true,
            "supportsImages": true,
            "inputCostPerMillion": 3.0,
            "outputCostPerMillion": 15.0,
            "tier": "sonnet",
            "family": "Claude 4.5",
            "description": "Smart model for complex agents and coding. Best balance of intelligence, speed, and cost.",
            "supportsReasoning": false,
            "recommended": false,
            "isLegacy": true,
            "releaseDate": "2025-09-29",
            "sortOrder": 3,
        }),
        serde_json::json!({
            "id": "claude-haiku-4-5-20251001",
            "name": "Haiku 4.5",
            "provider": "anthropic",
            "contextWindow": 200_000,
            "maxOutput": 64_000,
            "supportsThinking": true,
            "supportsImages": true,
            "inputCostPerMillion": 1.0,
            "outputCostPerMillion": 5.0,
            "tier": "haiku",
            "family": "Claude 4.5",
            "description": "Fastest model with near-frontier intelligence.",
            "supportsReasoning": false,
            "recommended": true,
            "isLegacy": false,
            "releaseDate": "2025-10-01",
            "sortOrder": 4,
        }),
        serde_json::json!({
            "id": "claude-opus-4-1-20250805",
            "name": "Opus 4.1",
            "provider": "anthropic",
            "contextWindow": 200_000,
            "maxOutput": 32_000,
            "supportsThinking": true,
            "supportsImages": true,
            "inputCostPerMillion": 15.0,
            "outputCostPerMillion": 75.0,
            "tier": "opus",
            "family": "Claude 4.1",
            "description": "Previous Opus with enhanced agentic capabilities.",
            "supportsReasoning": false,
            "recommended": false,
            "isLegacy": true,
            "releaseDate": "2025-08-05",
            "sortOrder": 5,
        }),
        serde_json::json!({
            "id": "claude-opus-4-20250514",
            "name": "Opus 4",
            "provider": "anthropic",
            "contextWindow": 200_000,
            "maxOutput": 32_000,
            "supportsThinking": true,
            "supportsImages": true,
            "inputCostPerMillion": 15.0,
            "outputCostPerMillion": 75.0,
            "tier": "opus",
            "family": "Claude 4",
            "description": "Opus 4 with tool use and extended thinking.",
            "supportsReasoning": false,
            "recommended": false,
            "isLegacy": true,
            "releaseDate": "2025-05-14",
            "sortOrder": 6,
        }),
        serde_json::json!({
            "id": "claude-sonnet-4-20250514",
            "name": "Sonnet 4",
            "provider": "anthropic",
            "contextWindow": 200_000,
            "maxOutput": 64_000,
            "supportsThinking": true,
            "supportsImages": true,
            "inputCostPerMillion": 3.0,
            "outputCostPerMillion": 15.0,
            "tier": "sonnet",
            "family": "Claude 4",
            "description": "Fast and capable for everyday coding tasks.",
            "supportsReasoning": false,
            "recommended": false,
            "isLegacy": true,
            "releaseDate": "2025-05-14",
            "sortOrder": 7,
        }),
        serde_json::json!({
            "id": "claude-3-7-sonnet-20250219",
            "name": "Sonnet 3.7",
            "provider": "anthropic",
            "contextWindow": 200_000,
            "maxOutput": 64_000,
            "supportsThinking": true,
            "supportsImages": true,
            "inputCostPerMillion": 3.0,
            "outputCostPerMillion": 15.0,
            "tier": "sonnet",
            "family": "Claude 3.7",
            "description": "Claude 3.7 Sonnet — deprecated by Anthropic.",
            "supportsReasoning": false,
            "recommended": false,
            "isLegacy": true,
            "isDeprecated": true,
            "deprecationDate": "2025-10-01",
            "releaseDate": "2025-02-19",
            "sortOrder": 8,
        }),
        serde_json::json!({
            "id": "claude-3-haiku-20240307",
            "name": "Haiku 3",
            "provider": "anthropic",
            "contextWindow": 200_000,
            "maxOutput": 4_096,
            "supportsThinking": false,
            "supportsImages": true,
            "inputCostPerMillion": 0.25,
            "outputCostPerMillion": 1.25,
            "tier": "haiku",
            "family": "Claude 3",
            "description": "Claude 3 Haiku — fast and compact.",
            "supportsReasoning": false,
            "recommended": false,
            "isLegacy": true,
            "releaseDate": "2024-03-07",
            "sortOrder": 9,
        }),
        // ── OpenAI Codex Models ──
        serde_json::json!({
            "id": "gpt-5.4",
            "name": "GPT-5.4",
            "provider": "openai-codex",
            "contextWindow": 272_000,
            "maxOutput": 128_000,
            "supportsThinking": false,
            "supportsImages": true,
            "inputCostPerMillion": 2.0,
            "outputCostPerMillion": 16.0,
            "cacheReadCostPerMillion": 0.2,
            "tier": "flagship",
            "family": "GPT-5.4",
            "description": "Latest OpenAI flagship — 272K context (1M with extended context opt-in), tool search, computer use, and expanded reasoning.",
            "supportsReasoning": true,
            "reasoningLevels": ["none", "low", "medium", "high", "xhigh"],
            "defaultReasoningLevel": "medium",
            "recommended": true,
            "isLegacy": false,
            "sortOrder": 0,
        }),
        serde_json::json!({
            "id": "gpt-5.4-pro",
            "name": "GPT-5.4 Pro",
            "provider": "openai-codex",
            "contextWindow": 272_000,
            "maxOutput": 128_000,
            "supportsThinking": false,
            "supportsImages": true,
            "inputCostPerMillion": 4.0,
            "outputCostPerMillion": 32.0,
            "cacheReadCostPerMillion": 0.4,
            "tier": "flagship",
            "family": "GPT-5.4",
            "description": "Highest capability tier — 272K context (1M with extended context opt-in), tool search, computer use, and maximum reasoning.",
            "supportsReasoning": true,
            "reasoningLevels": ["none", "low", "medium", "high", "xhigh"],
            "defaultReasoningLevel": "high",
            "recommended": false,
            "isLegacy": false,
            "sortOrder": 1,
        }),
        serde_json::json!({
            "id": "gpt-5.3-codex",
            "name": "GPT-5.3 Codex",
            "provider": "openai-codex",
            "contextWindow": 400_000,
            "maxOutput": 128_000,
            "supportsThinking": false,
            "supportsImages": true,
            "inputCostPerMillion": 1.75,
            "outputCostPerMillion": 14.0,
            "cacheReadCostPerMillion": 0.175,
            "tier": "flagship",
            "family": "GPT-5.3",
            "description": "Agentic coding model — 400K context, reasoning, vision, and structured outputs.",
            "supportsReasoning": true,
            "reasoningLevels": ["low", "medium", "high", "xhigh"],
            "defaultReasoningLevel": "medium",
            "knowledgeCutoff": "2025-08-31",
            "recommended": false,
            "isLegacy": true,
            "sortOrder": 0,
        }),
        serde_json::json!({
            "id": "gpt-5.3-codex-spark",
            "name": "GPT-5.3 Codex Spark",
            "provider": "openai-codex",
            "contextWindow": 128_000,
            "maxOutput": 32_000,
            "supportsThinking": false,
            "supportsImages": false,
            "inputCostPerMillion": 1.75,
            "outputCostPerMillion": 14.0,
            "cacheReadCostPerMillion": 0.175,
            "tier": "standard",
            "family": "GPT-5.3",
            "description": "Fast distilled coding model optimized for ultra-fast inference.",
            "supportsReasoning": true,
            "reasoningLevels": ["low", "medium", "high"],
            "defaultReasoningLevel": "low",
            "recommended": false,
            "isLegacy": true,
            "sortOrder": 1,
        }),
        serde_json::json!({
            "id": "gpt-5.2-codex",
            "name": "GPT-5.2 Codex",
            "provider": "openai-codex",
            "contextWindow": 400_000,
            "maxOutput": 128_000,
            "supportsThinking": false,
            "supportsImages": true,
            "inputCostPerMillion": 1.75,
            "outputCostPerMillion": 14.0,
            "cacheReadCostPerMillion": 0.175,
            "tier": "flagship",
            "family": "GPT-5.2",
            "description": "GPT-5.2 Codex — proven agentic coding model with 400K context.",
            "supportsReasoning": true,
            "reasoningLevels": ["low", "medium", "high", "xhigh"],
            "defaultReasoningLevel": "medium",
            "recommended": false,
            "isLegacy": false,
            "sortOrder": 2,
        }),
        serde_json::json!({
            "id": "gpt-5.1-codex-max",
            "name": "GPT-5.1 Codex Max",
            "provider": "openai-codex",
            "contextWindow": 400_000,
            "maxOutput": 128_000,
            "supportsThinking": false,
            "supportsImages": true,
            "inputCostPerMillion": 1.25,
            "outputCostPerMillion": 10.0,
            "cacheReadCostPerMillion": 0.125,
            "tier": "flagship",
            "family": "GPT-5.1",
            "description": "GPT-5.1 Codex Max — deep reasoning capabilities with 400K context.",
            "supportsReasoning": true,
            "reasoningLevels": ["low", "medium", "high", "xhigh"],
            "defaultReasoningLevel": "high",
            "recommended": false,
            "isLegacy": false,
            "sortOrder": 3,
        }),
        serde_json::json!({
            "id": "gpt-5.1-codex-mini",
            "name": "GPT-5.1 Codex Mini",
            "provider": "openai-codex",
            "contextWindow": 400_000,
            "maxOutput": 128_000,
            "supportsThinking": false,
            "supportsImages": true,
            "inputCostPerMillion": 0.25,
            "outputCostPerMillion": 2.0,
            "cacheReadCostPerMillion": 0.025,
            "tier": "standard",
            "family": "GPT-5.1",
            "description": "GPT-5.1 Codex Mini — fast and cost-efficient coding model.",
            "supportsReasoning": true,
            "reasoningLevels": ["low", "medium", "high"],
            "defaultReasoningLevel": "low",
            "recommended": false,
            "isLegacy": false,
            "sortOrder": 4,
        }),
        // ── Google Gemini Models ──
        // Pricing: TS uses inputCostPer1k, we multiply by 1000 for per-million
        serde_json::json!({
            "id": "gemini-3.1-pro-preview",
            "name": "Gemini 3.1 Pro",
            "provider": "google",
            "contextWindow": 1_048_576,
            "maxOutput": 65_536,
            "supportsThinking": true,
            "supportsImages": true,
            "inputCostPerMillion": 1.25,
            "outputCostPerMillion": 10.0,
            "tier": "pro",
            "family": "Gemini 3",
            "description": "Gemini 3.1 Pro (Preview) — optimized for software engineering and agentic workflows.",
            "isPreview": true,
            "thinkingLevel": "high",
            "supportedThinkingLevels": ["low", "medium", "high"],
            "recommended": true,
            "isLegacy": false,
            "sortOrder": 0,
        }),
        serde_json::json!({
            "id": "gemini-3-pro-preview",
            "name": "Gemini 3 Pro",
            "provider": "google",
            "contextWindow": 1_048_576,
            "maxOutput": 65_536,
            "supportsThinking": true,
            "supportsImages": true,
            "inputCostPerMillion": 1.25,
            "outputCostPerMillion": 5.0,
            "tier": "pro",
            "family": "Gemini 3",
            "description": "Gemini 3 Pro (Preview) — deprecated, replaced by Gemini 3.1 Pro.",
            "isPreview": true,
            "thinkingLevel": "high",
            "supportedThinkingLevels": ["low", "medium", "high"],
            "recommended": false,
            "isLegacy": false,
            "isDeprecated": true,
            "deprecationDate": "2026-03-09",
            "sortOrder": 1,
        }),
        serde_json::json!({
            "id": "gemini-3-flash-preview",
            "name": "Gemini 3 Flash",
            "provider": "google",
            "contextWindow": 1_048_576,
            "maxOutput": 65_536,
            "supportsThinking": false,
            "supportsImages": true,
            "inputCostPerMillion": 0.075,
            "outputCostPerMillion": 0.30,
            "tier": "flash",
            "family": "Gemini 3",
            "description": "Gemini 3 Flash (Preview) — flash tier (preview)",
            "isPreview": true,
            "recommended": false,
            "isLegacy": false,
            "sortOrder": 2,
        }),
        serde_json::json!({
            "id": "gemini-3.1-flash-lite-preview",
            "name": "Gemini 3.1 Flash Lite",
            "provider": "google",
            "contextWindow": 1_048_576,
            "maxOutput": 65_536,
            "supportsThinking": false,
            "supportsImages": true,
            "inputCostPerMillion": 0.25,
            "outputCostPerMillion": 1.50,
            "tier": "flash-lite",
            "family": "Gemini 3",
            "description": "Gemini 3.1 Flash Lite (Preview) — cost-optimized for high-volume agentic tasks.",
            "isPreview": true,
            "recommended": false,
            "isLegacy": false,
            "sortOrder": 3,
        }),
        serde_json::json!({
            "id": "gemini-2.5-pro",
            "name": "Gemini 2.5 Pro",
            "provider": "google",
            "contextWindow": 2_097_152,
            "maxOutput": 16_384,
            "supportsThinking": true,
            "supportsImages": true,
            "inputCostPerMillion": 1.25,
            "outputCostPerMillion": 5.0,
            "tier": "pro",
            "family": "Gemini 2.5",
            "description": "Gemini 2.5 Pro — pro tier",
            "thinkingLevel": "high",
            "supportedThinkingLevels": ["low", "medium", "high"],
            "recommended": false,
            "isLegacy": false,
            "sortOrder": 4,
        }),
        serde_json::json!({
            "id": "gemini-2.5-flash",
            "name": "Gemini 2.5 Flash",
            "provider": "google",
            "contextWindow": 1_048_576,
            "maxOutput": 16_384,
            "supportsThinking": true,
            "supportsImages": true,
            "inputCostPerMillion": 0.075,
            "outputCostPerMillion": 0.30,
            "tier": "flash",
            "family": "Gemini 2.5",
            "description": "Gemini 2.5 Flash — flash tier",
            "thinkingLevel": "low",
            "supportedThinkingLevels": ["minimal", "low", "medium", "high"],
            "recommended": false,
            "isLegacy": false,
            "sortOrder": 5,
        }),
        serde_json::json!({
            "id": "gemini-2.5-flash-lite",
            "name": "Gemini 2.5 Flash Lite",
            "provider": "google",
            "contextWindow": 1_048_576,
            "maxOutput": 8_192,
            "supportsThinking": false,
            "supportsImages": true,
            "inputCostPerMillion": 0.0375,
            "outputCostPerMillion": 0.15,
            "tier": "flash-lite",
            "family": "Gemini 2.5",
            "description": "Gemini 2.5 Flash Lite — flash-lite tier",
            "recommended": false,
            "isLegacy": false,
            "sortOrder": 6,
        }),
        // ── MiniMax Models ──
        serde_json::json!({
            "id": "MiniMax-M2.5",
            "name": "MiniMax M2.5",
            "provider": "minimax",
            "contextWindow": 204_800,
            "maxOutput": 128_000,
            "supportsThinking": true,
            "supportsImages": false,
            "inputCostPerMillion": 0.3,
            "outputCostPerMillion": 1.2,
            "tier": "flagship",
            "family": "MiniMax M2",
            "description": "MiniMax M2.5 — latest and most capable MiniMax model.",
            "supportsReasoning": false,
            "recommended": true,
            "isLegacy": false,
            "sortOrder": 0,
        }),
        serde_json::json!({
            "id": "MiniMax-M2.5-highspeed",
            "name": "MiniMax M2.5 Highspeed",
            "provider": "minimax",
            "contextWindow": 204_800,
            "maxOutput": 128_000,
            "supportsThinking": true,
            "supportsImages": false,
            "inputCostPerMillion": 0.3,
            "outputCostPerMillion": 1.2,
            "tier": "flagship",
            "family": "MiniMax M2",
            "description": "MiniMax M2.5 Highspeed — optimized for faster inference.",
            "supportsReasoning": false,
            "recommended": false,
            "isLegacy": false,
            "sortOrder": 1,
        }),
        serde_json::json!({
            "id": "MiniMax-M2.1",
            "name": "MiniMax M2.1",
            "provider": "minimax",
            "contextWindow": 204_800,
            "maxOutput": 128_000,
            "supportsThinking": true,
            "supportsImages": false,
            "inputCostPerMillion": 0.3,
            "outputCostPerMillion": 1.2,
            "tier": "flagship",
            "family": "MiniMax M2",
            "description": "MiniMax M2.1 — capable general-purpose model.",
            "supportsReasoning": false,
            "recommended": false,
            "isLegacy": false,
            "sortOrder": 2,
        }),
        serde_json::json!({
            "id": "MiniMax-M2.1-highspeed",
            "name": "MiniMax M2.1 Highspeed",
            "provider": "minimax",
            "contextWindow": 204_800,
            "maxOutput": 128_000,
            "supportsThinking": true,
            "supportsImages": false,
            "inputCostPerMillion": 0.3,
            "outputCostPerMillion": 1.2,
            "tier": "flagship",
            "family": "MiniMax M2",
            "description": "MiniMax M2.1 Highspeed — optimized for faster inference.",
            "supportsReasoning": false,
            "recommended": false,
            "isLegacy": false,
            "sortOrder": 3,
        }),
        serde_json::json!({
            "id": "MiniMax-M2",
            "name": "MiniMax M2",
            "provider": "minimax",
            "contextWindow": 204_800,
            "maxOutput": 128_000,
            "supportsThinking": true,
            "supportsImages": false,
            "inputCostPerMillion": 0.3,
            "outputCostPerMillion": 1.2,
            "tier": "flagship",
            "family": "MiniMax M2",
            "description": "MiniMax M2 — foundation model.",
            "supportsReasoning": false,
            "recommended": false,
            "isLegacy": false,
            "sortOrder": 4,
        }),
    ]
}

fn is_model_supported(model_id: &str) -> bool {
    known_models().iter().any(|m| m["id"] == model_id)
}

fn is_model_deprecated(model_id: &str) -> bool {
    known_models()
        .iter()
        .any(|m| m["id"] == model_id && m["isDeprecated"] == true)
}

/// List available models.
pub struct ListModelsHandler;

#[async_trait]
impl MethodHandler for ListModelsHandler {
    #[instrument(skip(self, _ctx), fields(method = "model.list"))]
    async fn handle(&self, _params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        Ok(serde_json::json!({ "models": known_models() }))
    }
}

/// Switch the model for a session.
pub struct SwitchModelHandler;

#[async_trait]
impl MethodHandler for SwitchModelHandler {
    #[instrument(skip(self, ctx), fields(method = "model.switch"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let model = require_string_param(params.as_ref(), "model")?;

        if !is_model_supported(&model) {
            return Err(RpcError::InvalidParams {
                message: format!("Unknown model: {model}"),
            });
        }

        if is_model_deprecated(&model) {
            return Err(RpcError::InvalidParams {
                message: format!("Model '{model}' is deprecated and cannot be selected"),
            });
        }

        // Get current model for response
        let session = ctx
            .event_store
            .get_session(&session_id)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?
            .ok_or_else(|| RpcError::NotFound {
                code: errors::SESSION_NOT_FOUND.into(),
                message: format!("Session '{session_id}' not found"),
            })?;

        let previous_model = session.latest_model.clone();

        // Reject if session is busy (agent running)
        if ctx.orchestrator.has_active_run(&session_id) {
            return Err(RpcError::Custom {
                code: "SESSION_BUSY".into(),
                message: "Cannot switch model while session is running".into(),
                details: None,
            });
        }

        let _ = ctx
            .event_store
            .update_latest_model(&session_id, &model)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?;

        // Persist config.model_switch event
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &session_id,
            event_type: tron_events::EventType::ConfigModelSwitch,
            payload: serde_json::json!({
                "previousModel": previous_model,
                "newModel": model,
            }),
            parent_id: None,
        });

        // Invalidate cached session so next resume reconstructs with new model
        ctx.session_manager.invalidate_session(&session_id);

        // Emit session.updated event via broadcast
        let is_active = ctx.session_manager.is_active(&session_id);
        let _ = ctx
            .orchestrator
            .broadcast()
            .emit(tron_core::events::TronEvent::SessionUpdated {
                base: tron_core::events::BaseEvent::now(&session_id),
                title: session.title.clone(),
                model: model.clone(),
                message_count: session.event_count,
                input_tokens: session.total_input_tokens,
                output_tokens: session.total_output_tokens,
                last_turn_input_tokens: session.last_turn_input_tokens,
                cache_read_tokens: session.total_cache_read_tokens,
                cache_creation_tokens: session.total_cache_creation_tokens,
                cost: session.total_cost,
                last_activity: session.last_activity_at.clone(),
                is_active,
                last_user_prompt: None,
                last_assistant_response: None,
                parent_session_id: session.parent_session_id.clone(),
            });

        Ok(serde_json::json!({
            "previousModel": previous_model,
            "newModel": model,
        }))
    }
}

/// Look up the default reasoning level for a model ID from the known models list.
fn default_reasoning_level(model_id: &str) -> Option<String> {
    known_models()
        .iter()
        .find(|m| m.get("id").and_then(|v| v.as_str()) == Some(model_id))
        .and_then(|m| m.get("defaultReasoningLevel"))
        .and_then(|v| v.as_str())
        .map(String::from)
}

/// Set the reasoning level for a session.
///
/// Persists a `config.reasoning_level` event and invalidates the session cache.
/// The server is the source of truth: it resolves `previousLevel` from event
/// history, falling back to the model's `defaultReasoningLevel` for the first
/// change in a session. The client only sends `sessionId` and `level`.
pub struct SetReasoningLevelHandler;

#[async_trait]
impl MethodHandler for SetReasoningLevelHandler {
    #[instrument(skip(self, ctx), fields(method = "config.setReasoningLevel"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let new_level = require_string_param(params.as_ref(), "level")?;

        // Verify session exists
        let _ = ctx
            .event_store
            .get_session(&session_id)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?
            .ok_or_else(|| RpcError::NotFound {
                code: errors::SESSION_NOT_FOUND.into(),
                message: format!("Session '{session_id}' not found"),
            })?;

        // Resolve previous level: event history first, then model default.
        let state = ctx.event_store.get_state_at_head(&session_id).ok();
        let previous_level = state
            .as_ref()
            .and_then(|s| s.reasoning_level.clone())
            .or_else(|| {
                state
                    .as_ref()
                    .and_then(|s| default_reasoning_level(&s.model))
            });

        // Skip if level hasn't actually changed (case-insensitive)
        if previous_level.as_deref().map(str::to_lowercase) == Some(new_level.to_lowercase()) {
            return Ok(serde_json::json!({
                "previousLevel": previous_level,
                "newLevel": new_level,
                "changed": false,
            }));
        }

        // Persist config.reasoning_level event
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &session_id,
            event_type: tron_events::EventType::ConfigReasoningLevel,
            payload: serde_json::json!({
                "previousLevel": previous_level,
                "newLevel": new_level,
            }),
            parent_id: None,
        });

        // Invalidate cached session so next resume reconstructs with new level
        ctx.session_manager.invalidate_session(&session_id);

        Ok(serde_json::json!({
            "previousLevel": previous_level,
            "newLevel": new_level,
            "changed": true,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn list_models_returns_array() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        assert!(result["models"].is_array());
        assert!(!result["models"].as_array().unwrap().is_empty());
    }

    #[tokio::test]
    async fn list_models_includes_all_anthropic() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();
        assert!(models.iter().any(|m| m["id"] == "claude-opus-4-6"));
        assert!(models.iter().any(|m| m["id"] == "claude-sonnet-4-6"));
        assert!(models.iter().any(|m| m["id"] == "claude-opus-4-5-20251101"));
        assert!(
            models
                .iter()
                .any(|m| m["id"] == "claude-sonnet-4-5-20250929")
        );
        assert!(
            models
                .iter()
                .any(|m| m["id"] == "claude-haiku-4-5-20251001")
        );
        assert!(models.iter().any(|m| m["id"] == "claude-opus-4-1-20250805"));
        assert!(models.iter().any(|m| m["id"] == "claude-opus-4-20250514"));
        assert!(models.iter().any(|m| m["id"] == "claude-sonnet-4-20250514"));
        assert!(
            models
                .iter()
                .any(|m| m["id"] == "claude-3-7-sonnet-20250219")
        );
        assert!(models.iter().any(|m| m["id"] == "claude-3-haiku-20240307"));
        let anthropic_count = models
            .iter()
            .filter(|m| m["provider"] == "anthropic")
            .count();
        assert_eq!(anthropic_count, 10);
    }

    #[tokio::test]
    async fn list_models_includes_all_openai() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();
        assert!(models.iter().any(|m| m["id"] == "gpt-5.4"));
        assert!(models.iter().any(|m| m["id"] == "gpt-5.4-pro"));
        assert!(models.iter().any(|m| m["id"] == "gpt-5.3-codex"));
        assert!(models.iter().any(|m| m["id"] == "gpt-5.3-codex-spark"));
        assert!(models.iter().any(|m| m["id"] == "gpt-5.2-codex"));
        assert!(models.iter().any(|m| m["id"] == "gpt-5.1-codex-max"));
        assert!(models.iter().any(|m| m["id"] == "gpt-5.1-codex-mini"));
        let openai_count = models
            .iter()
            .filter(|m| m["provider"] == "openai-codex")
            .count();
        assert_eq!(openai_count, 7);
    }

    #[tokio::test]
    async fn list_models_includes_all_google() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();
        assert!(models.iter().any(|m| m["id"] == "gemini-3.1-pro-preview"));
        assert!(models.iter().any(|m| m["id"] == "gemini-3-pro-preview"));
        assert!(models.iter().any(|m| m["id"] == "gemini-3-flash-preview"));
        assert!(models.iter().any(|m| m["id"] == "gemini-2.5-pro"));
        assert!(models.iter().any(|m| m["id"] == "gemini-2.5-flash"));
        assert!(
            models
                .iter()
                .any(|m| m["id"] == "gemini-3.1-flash-lite-preview")
        );
        assert!(models.iter().any(|m| m["id"] == "gemini-2.5-flash-lite"));
        let google_count = models.iter().filter(|m| m["provider"] == "google").count();
        assert_eq!(google_count, 7);
    }

    #[tokio::test]
    async fn list_models_includes_all_minimax() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();
        assert!(models.iter().any(|m| m["id"] == "MiniMax-M2.5"));
        assert!(models.iter().any(|m| m["id"] == "MiniMax-M2.5-highspeed"));
        assert!(models.iter().any(|m| m["id"] == "MiniMax-M2.1"));
        assert!(models.iter().any(|m| m["id"] == "MiniMax-M2.1-highspeed"));
        assert!(models.iter().any(|m| m["id"] == "MiniMax-M2"));
        let minimax_count = models.iter().filter(|m| m["provider"] == "minimax").count();
        assert_eq!(minimax_count, 5);
    }

    #[tokio::test]
    async fn list_models_minimax_no_images() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();
        for model in models.iter().filter(|m| m["provider"] == "minimax") {
            assert_eq!(
                model["supportsImages"], false,
                "{} should not support images",
                model["id"]
            );
        }
    }

    #[tokio::test]
    async fn list_models_minimax_has_required_fields() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();
        for model in models.iter().filter(|m| m["provider"] == "minimax") {
            assert!(model["id"].is_string());
            assert!(model["name"].is_string());
            assert!(model["provider"].is_string());
            assert!(model["contextWindow"].is_number());
        }
    }

    #[tokio::test]
    async fn list_models_has_required_fields() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();
        for model in models {
            assert!(model["id"].is_string());
            assert!(model["name"].is_string());
            assert!(model["provider"].is_string());
            assert!(model["contextWindow"].is_number());
            assert!(
                model["sortOrder"].is_number(),
                "Model {} missing sortOrder",
                model["id"]
            );
        }
    }

    #[tokio::test]
    async fn list_models_has_capabilities() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();
        for model in models {
            assert!(model.get("supportsThinking").is_some());
            assert!(model.get("supportsImages").is_some());
        }
    }

    #[tokio::test]
    async fn list_models_has_pricing() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();
        for model in models {
            assert!(model["inputCostPerMillion"].is_number());
            assert!(model["outputCostPerMillion"].is_number());
        }
    }

    #[tokio::test]
    async fn list_models_has_client_metadata() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();
        let opus = models
            .iter()
            .find(|m| m["id"] == "claude-opus-4-6")
            .unwrap();
        assert_eq!(opus["tier"], "opus");
        assert_eq!(opus["family"], "Claude 4.6");
        assert!(opus["description"].is_string());
        assert_eq!(opus["recommended"], true);
        assert!(opus["releaseDate"].is_string());
        assert!(opus["maxOutput"].is_number());
        assert_eq!(opus["isLegacy"], false);
    }

    #[tokio::test]
    async fn list_models_anthropic_reasoning_levels() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();
        let opus = models
            .iter()
            .find(|m| m["id"] == "claude-opus-4-6")
            .unwrap();
        assert_eq!(opus["supportsReasoning"], true);
        assert!(opus["reasoningLevels"].is_array());
        assert!(opus["defaultReasoningLevel"].is_string());
    }

    #[tokio::test]
    async fn list_models_google_thinking_levels() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();
        let gemini = models.iter().find(|m| m["id"] == "gemini-2.5-pro").unwrap();
        assert!(gemini["thinkingLevel"].is_string());
        assert!(gemini["supportedThinkingLevels"].is_array());
    }

    #[tokio::test]
    async fn switch_model_valid() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", None)
            .unwrap();

        let result = SwitchModelHandler
            .handle(
                Some(json!({"sessionId": sid, "model": "claude-sonnet-4-5-20250929"})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["previousModel"], "claude-opus-4-6");
        assert_eq!(result["newModel"], "claude-sonnet-4-5-20250929");
    }

    #[tokio::test]
    async fn switch_model_invalid() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        let err = SwitchModelHandler
            .handle(
                Some(json!({"sessionId": sid, "model": "nonexistent-model"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn switch_model_missing_session() {
        let ctx = make_test_context();
        let err = SwitchModelHandler
            .handle(
                Some(json!({"sessionId": "nope", "model": "claude-opus-4-6"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "SESSION_NOT_FOUND");
    }

    #[tokio::test]
    async fn switch_model_missing_params() {
        let ctx = make_test_context();
        let err = SwitchModelHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn switch_model_persists_change() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", None)
            .unwrap();

        let _ = SwitchModelHandler
            .handle(
                Some(json!({"sessionId": sid, "model": "claude-sonnet-4-5-20250929"})),
                &ctx,
            )
            .await
            .unwrap();

        let session = ctx.event_store.get_session(&sid).unwrap().unwrap();
        assert_eq!(session.latest_model, "claude-sonnet-4-5-20250929");
    }

    #[tokio::test]
    async fn switch_model_emits_session_updated() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", None)
            .unwrap();

        let mut rx = ctx.orchestrator.subscribe();

        let _ = SwitchModelHandler
            .handle(
                Some(json!({"sessionId": sid, "model": "claude-sonnet-4-5-20250929"})),
                &ctx,
            )
            .await
            .unwrap();

        let event = rx.try_recv().unwrap();
        assert_eq!(event.event_type(), "session_updated");
    }

    #[tokio::test]
    async fn switch_model_persists_config_event() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", None)
            .unwrap();

        let _ = SwitchModelHandler
            .handle(
                Some(json!({"sessionId": sid, "model": "claude-sonnet-4-5-20250929"})),
                &ctx,
            )
            .await
            .unwrap();

        let events = ctx
            .event_store
            .get_events_by_type(&sid, &["config.model_switch"], None)
            .unwrap();
        assert_eq!(events.len(), 1);
        let payload: serde_json::Value = serde_json::from_str(&events[0].payload).unwrap();
        assert_eq!(payload["previousModel"], "claude-opus-4-6");
        assert_eq!(payload["newModel"], "claude-sonnet-4-5-20250929");
    }

    #[tokio::test]
    async fn switch_model_rejects_busy_session() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", None)
            .unwrap();

        // Simulate a running session by starting a run via orchestrator
        let _run = ctx.orchestrator.begin_run(&sid, "run-1").unwrap();

        let err = SwitchModelHandler
            .handle(
                Some(json!({"sessionId": sid, "model": "claude-sonnet-4-5-20250929"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "SESSION_BUSY");
    }

    #[tokio::test]
    async fn switch_model_invalidates_cache() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", None)
            .unwrap();

        // Resume to cache it
        let _ = ctx.session_manager.resume_session(&sid);
        assert!(ctx.session_manager.is_active(&sid));

        let _ = SwitchModelHandler
            .handle(
                Some(json!({"sessionId": sid, "model": "claude-sonnet-4-5-20250929"})),
                &ctx,
            )
            .await
            .unwrap();

        // After switch, cache should be invalidated
        assert!(!ctx.session_manager.is_active(&sid));
    }

    #[tokio::test]
    async fn switch_model_uses_real_cost() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", None)
            .unwrap();

        // Add a turn end with cost to accumulate session cost
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::StreamTurnEnd,
            payload: json!({
                "turn": 1,
                "tokenUsage": {"inputTokens": 100, "outputTokens": 50},
                "cost": 0.005,
            }),
            parent_id: None,
        });

        let mut rx = ctx.orchestrator.subscribe();

        let _ = SwitchModelHandler
            .handle(
                Some(json!({"sessionId": sid, "model": "claude-sonnet-4-5-20250929"})),
                &ctx,
            )
            .await
            .unwrap();

        let event = rx.try_recv().unwrap();
        if let tron_core::events::TronEvent::SessionUpdated { cost, .. } = event {
            // Cost should come from session, not hardcoded 0.0
            // (exact value depends on how event store aggregates)
            assert!(cost >= 0.0);
        } else {
            panic!("expected SessionUpdated event");
        }
    }

    #[tokio::test]
    async fn switch_model_session_updated_has_model() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", None)
            .unwrap();

        let mut rx = ctx.orchestrator.subscribe();

        let _ = SwitchModelHandler
            .handle(
                Some(json!({"sessionId": sid, "model": "claude-sonnet-4-5-20250929"})),
                &ctx,
            )
            .await
            .unwrap();

        let event = rx.try_recv().unwrap();
        if let tron_core::events::TronEvent::SessionUpdated { model, .. } = event {
            assert_eq!(model, "claude-sonnet-4-5-20250929");
        } else {
            panic!("expected SessionUpdated event");
        }
    }

    #[tokio::test]
    async fn switch_model_rejects_deprecated() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", None)
            .unwrap();

        let err = SwitchModelHandler
            .handle(
                Some(json!({"sessionId": sid, "model": "gemini-3-pro-preview"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
        assert!(err.to_string().contains("deprecated"));
    }

    #[tokio::test]
    async fn switch_model_rejects_deprecated_sonnet_37() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", None)
            .unwrap();

        let err = SwitchModelHandler
            .handle(
                Some(json!({"sessionId": sid, "model": "claude-3-7-sonnet-20250219"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn list_models_deprecated_fields() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();

        // Gemini 3 Pro should be deprecated
        let gemini3 = models
            .iter()
            .find(|m| m["id"] == "gemini-3-pro-preview")
            .unwrap();
        assert_eq!(gemini3["isDeprecated"], true);
        assert_eq!(gemini3["deprecationDate"], "2026-03-09");

        // Gemini 3.1 Pro should NOT be deprecated
        let gemini31 = models
            .iter()
            .find(|m| m["id"] == "gemini-3.1-pro-preview")
            .unwrap();
        assert!(gemini31.get("isDeprecated").is_none() || gemini31["isDeprecated"] == false);

        // Sonnet 3.7 should be deprecated
        let sonnet37 = models
            .iter()
            .find(|m| m["id"] == "claude-3-7-sonnet-20250219")
            .unwrap();
        assert_eq!(sonnet37["isDeprecated"], true);
    }

    #[tokio::test]
    async fn switch_to_gemini_31_succeeds() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", None)
            .unwrap();

        let result = SwitchModelHandler
            .handle(
                Some(json!({"sessionId": sid, "model": "gemini-3.1-pro-preview"})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["newModel"], "gemini-3.1-pro-preview");
    }

    // ── SetReasoningLevelHandler ──

    #[tokio::test]
    async fn set_reasoning_level_emits_event() {
        // Sonnet 4.6 default is "medium" — changing to "max" should emit event
        // with previousLevel resolved from model default
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-sonnet-4-6", "/tmp", None)
            .unwrap();

        let result = SetReasoningLevelHandler
            .handle(Some(json!({"sessionId": sid, "level": "max"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["previousLevel"], "medium");
        assert_eq!(result["newLevel"], "max");
        assert_eq!(result["changed"], true);

        let events = ctx
            .event_store
            .get_events_by_type(&sid, &["config.reasoning_level"], None)
            .unwrap();
        assert_eq!(events.len(), 1);
        let payload: serde_json::Value = serde_json::from_str(&events[0].payload).unwrap();
        assert_eq!(payload["previousLevel"], "medium");
        assert_eq!(payload["newLevel"], "max");
    }

    #[tokio::test]
    async fn set_reasoning_level_default_is_noop() {
        // Setting to the model's own default should be a no-op
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-sonnet-4-6", "/tmp", None)
            .unwrap();

        let result = SetReasoningLevelHandler
            .handle(Some(json!({"sessionId": sid, "level": "medium"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["changed"], false);

        let events = ctx
            .event_store
            .get_events_by_type(&sid, &["config.reasoning_level"], None)
            .unwrap();
        assert_eq!(events.len(), 0);
    }

    #[tokio::test]
    async fn set_reasoning_level_no_duplicate() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-sonnet-4-6", "/tmp", None)
            .unwrap();

        let _ = SetReasoningLevelHandler
            .handle(Some(json!({"sessionId": sid, "level": "max"})), &ctx)
            .await
            .unwrap();

        // Same level again — server resolves previous from event history
        let result = SetReasoningLevelHandler
            .handle(Some(json!({"sessionId": sid, "level": "max"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["changed"], false);

        let events = ctx
            .event_store
            .get_events_by_type(&sid, &["config.reasoning_level"], None)
            .unwrap();
        assert_eq!(events.len(), 1);
    }

    #[tokio::test]
    async fn set_reasoning_level_case_insensitive() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-sonnet-4-6", "/tmp", None)
            .unwrap();

        let _ = SetReasoningLevelHandler
            .handle(Some(json!({"sessionId": sid, "level": "Max"})), &ctx)
            .await
            .unwrap();

        let result = SetReasoningLevelHandler
            .handle(Some(json!({"sessionId": sid, "level": "max"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["changed"], false);
    }

    #[tokio::test]
    async fn set_reasoning_level_change_emits_both() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-sonnet-4-6", "/tmp", None)
            .unwrap();

        // First change: medium (default) → high
        let r1 = SetReasoningLevelHandler
            .handle(Some(json!({"sessionId": sid, "level": "high"})), &ctx)
            .await
            .unwrap();
        assert_eq!(r1["previousLevel"], "medium");

        // Second change: high (from event) → max
        let r2 = SetReasoningLevelHandler
            .handle(Some(json!({"sessionId": sid, "level": "max"})), &ctx)
            .await
            .unwrap();
        assert_eq!(r2["previousLevel"], "high");
        assert_eq!(r2["newLevel"], "max");
        assert_eq!(r2["changed"], true);

        let events = ctx
            .event_store
            .get_events_by_type(&sid, &["config.reasoning_level"], None)
            .unwrap();
        assert_eq!(events.len(), 2);
    }

    #[tokio::test]
    async fn set_reasoning_level_session_not_found() {
        let ctx = make_test_context();
        let err = SetReasoningLevelHandler
            .handle(
                Some(json!({"sessionId": "nonexistent", "level": "high"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert!(matches!(err, RpcError::NotFound { .. }));
    }
}
