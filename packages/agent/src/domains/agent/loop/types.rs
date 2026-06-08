//! Runtime configuration and result types.

use std::sync::Arc;

use crate::domains::agent::context::types::CompactionConfig;
use crate::domains::model::providers::{
    AnthropicEffortLevel, ProviderHealthTracker, ReasoningEffort,
};
use crate::shared::protocol::messages::TokenUsage;
use serde::{Deserialize, Serialize};

use crate::domains::agent::r#loop::errors::StopReason;

// ─────────────────────────────────────────────────────────────────────────────
// Agent configuration
// ─────────────────────────────────────────────────────────────────────────────

/// Reasoning level for agent execution.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReasoningLevel {
    /// No reasoning.
    None,
    /// Low reasoning effort.
    Low,
    /// Medium reasoning effort.
    Medium,
    /// High reasoning effort.
    High,
    /// Extra-high reasoning effort (Anthropic only, maps to High for other providers).
    XHigh,
    /// Maximum reasoning effort (Anthropic only, maps to High for other providers).
    Max,
}

impl ReasoningLevel {
    /// Convert to Google Gemini thinking level string.
    /// Gemini supports: `THINKING_DISABLED`, `THINKING_LOW`, `THINKING_MEDIUM`, `THINKING_HIGH`.
    /// XHigh/Max clamp to `THINKING_HIGH`.
    pub fn as_gemini_thinking_level(&self) -> &str {
        match self {
            Self::None => "THINKING_DISABLED",
            Self::Low => "THINKING_LOW",
            Self::Medium => "THINKING_MEDIUM",
            Self::High | Self::XHigh | Self::Max => "THINKING_HIGH",
        }
    }

    /// Convert to Anthropic [`AnthropicEffortLevel`].
    ///
    /// Returns `None` for `ReasoningLevel::None` (use model default). Anthropic
    /// now supports the full `low/medium/high/xhigh/max` ladder (xhigh is new
    /// in Opus 4.7). Per-model support is advertised via
    /// `ClaudeModelInfo::reasoning_levels`; callers that pick a level not
    /// supported by the target model will surface a 400 from the API.
    pub fn as_anthropic_effort(&self) -> Option<AnthropicEffortLevel> {
        match self {
            Self::None => None,
            Self::Low => Some(AnthropicEffortLevel::Low),
            Self::Medium => Some(AnthropicEffortLevel::Medium),
            Self::High => Some(AnthropicEffortLevel::High),
            Self::XHigh => Some(AnthropicEffortLevel::Xhigh),
            Self::Max => Some(AnthropicEffortLevel::Max),
        }
    }

    /// Convert to `OpenAI` [`ReasoningEffort`].
    ///
    /// Full pass-through for GPT 5.4 levels. Provider-side clamping
    /// handles older models that don't support all levels.
    pub fn as_openai_reasoning(&self) -> ReasoningEffort {
        match self {
            Self::None => ReasoningEffort::None,
            Self::Low => ReasoningEffort::Low,
            Self::Medium => ReasoningEffort::Medium,
            Self::High => ReasoningEffort::High,
            Self::XHigh => ReasoningEffort::Xhigh,
            Self::Max => ReasoningEffort::Max,
        }
    }

    /// Parse from a string, case-insensitive.
    pub fn from_str_loose(s: &str) -> Option<Self> {
        match s.to_lowercase().as_str() {
            "none" => Some(Self::None),
            "low" => Some(Self::Low),
            "medium" => Some(Self::Medium),
            "high" => Some(Self::High),
            "xhigh" | "x_high" | "x-high" => Some(Self::XHigh),
            "max" => Some(Self::Max),
            _ => Option::None,
        }
    }
}

/// Configuration for creating a `TronAgent`.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentConfig {
    /// LLM provider type override.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider_type: Option<crate::shared::protocol::messages::Provider>,
    /// Model identifier.
    pub model: String,
    /// System prompt override.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub system_prompt: Option<String>,
    /// Maximum output tokens.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_tokens: Option<u32>,
    /// Sampling temperature.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub temperature: Option<f64>,
    /// Maximum turns before stopping.
    #[serde(default = "default_max_turns")]
    pub max_turns: u32,
    /// Enable extended thinking.
    #[serde(default)]
    pub enable_thinking: bool,
    /// Thinking budget in tokens.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thinking_budget: Option<u32>,
    /// Stop sequences.
    #[serde(default)]
    pub stop_sequences: Vec<String>,
    /// Compaction configuration.
    #[serde(skip)]
    pub compaction: CompactionConfig,
    /// Working directory for file operations.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub working_directory: Option<String>,
    /// Server origin (e.g. `"localhost:9847"`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub server_origin: Option<String>,
    /// Retry configuration for provider stream failures.
    #[serde(skip)]
    pub retry: Option<crate::shared::foundation::retry::RetryConfig>,
    /// Shared provider health tracker for recording success/failure outcomes.
    #[serde(skip)]
    pub health_tracker: Option<Arc<ProviderHealthTracker>>,
    /// Workspace ID for scoping memory recall (resolved from working directory).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workspace_id: Option<String>,
}

const fn default_max_turns() -> u32 {
    250
}

impl Default for AgentConfig {
    fn default() -> Self {
        Self {
            provider_type: None,
            model: "claude-opus-4-6".into(),
            system_prompt: None,
            max_tokens: None,
            temperature: None,
            max_turns: default_max_turns(),
            enable_thinking: false,
            thinking_budget: None,
            stop_sequences: Vec::new(),
            compaction: CompactionConfig::default(),
            working_directory: None,
            server_origin: None,
            retry: None,
            health_tracker: None,
            workspace_id: None,
        }
    }
}

/// Per-turn volatile token estimates for context accounting.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VolatileTokens {}

/// Per-prompt execution context.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RunContext {
    /// Stable runtime run id for causal/idempotency metadata. This is assigned
    /// by the prompt runtime and is intentionally not serialized into prompt
    /// context snapshots.
    #[serde(skip)]
    pub run_id: Option<String>,
    /// Engine trace inherited from the hidden `agent::run_turn` invocation.
    #[serde(skip)]
    pub engine_trace_id: Option<crate::engine::TraceId>,
    /// Parent engine invocation id for child capability/function invocations.
    #[serde(skip)]
    pub parent_invocation_id: Option<crate::engine::InvocationId>,
    /// Reasoning level override.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning_level: Option<ReasoningLevel>,
    /// Compact projection of agent-owned state loaded through engine state primitives.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent_state_context: Option<String>,
    /// Override user message content (e.g., multimodal blocks with images).
    /// When set, `run()` uses this instead of creating a text-only message.
    #[serde(skip)]
    pub user_content_override: Option<crate::shared::protocol::messages::UserMessageContent>,
    /// Volatile token estimates for context breakdown accounting.
    #[serde(default)]
    pub volatile_tokens: VolatileTokens,
}

// ─────────────────────────────────────────────────────────────────────────────
// Results
// ─────────────────────────────────────────────────────────────────────────────

/// Result of a single turn execution.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[allow(clippy::struct_excessive_bools)]
pub struct TurnResult {
    /// Whether the turn completed successfully.
    pub success: bool,
    /// Error message if turn failed.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// Number of capability invocations executed.
    pub capability_invocations_executed: usize,
    /// Token usage for this turn.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub token_usage: Option<TokenUsage>,
    /// Why the turn stopped.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stop_reason: Option<StopReason>,
    /// Whether the turn was interrupted.
    pub interrupted: bool,
    /// Content captured before interruption.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub partial_content: Option<String>,
    /// Whether a capability requested turn stop.
    pub stop_turn_requested: bool,
    /// LLM model ID used for this turn.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// Turn duration in milliseconds.
    pub latency_ms: u64,
    /// Whether the response contained thinking blocks.
    pub has_thinking: bool,
    /// Raw LLM stop reason string (e.g. `end_turn`, `capability_invocation`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub llm_stop_reason: Option<String>,
    /// Context window tokens this turn (for cross-turn baseline tracking).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context_window_tokens: Option<u64>,
}

impl Default for TurnResult {
    fn default() -> Self {
        Self {
            success: true,
            error: None,
            capability_invocations_executed: 0,
            token_usage: None,
            stop_reason: None,
            interrupted: false,
            partial_content: None,
            stop_turn_requested: false,
            model: None,
            latency_ms: 0,
            has_thinking: false,
            llm_stop_reason: None,
            context_window_tokens: None,
        }
    }
}

/// Result of a full agent run (multi-turn).
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RunResult {
    /// Number of turns executed.
    pub turns_executed: u32,
    /// Cumulative token usage.
    pub total_token_usage: TokenUsage,
    /// Why the agent stopped.
    pub stop_reason: StopReason,
    /// Whether the run was interrupted.
    pub interrupted: bool,
    /// Error message if run failed.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// Context window tokens from the last turn (for compaction ratio).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_context_window_tokens: Option<u64>,
}

impl Default for RunResult {
    fn default() -> Self {
        Self {
            turns_executed: 0,
            total_token_usage: TokenUsage::default(),
            stop_reason: StopReason::EndTurn,
            interrupted: false,
            error: None,
            last_context_window_tokens: None,
        }
    }
}

/// Result of a primitive capability invocation.
#[derive(Clone, Debug)]
pub struct CapabilityInvocationExecutionResult {
    /// Capability result.
    pub result: crate::shared::protocol::model_capabilities::CapabilityResult,
    /// Execution duration in milliseconds.
    pub duration_ms: u64,
    /// Whether this capability requested a turn stop.
    pub stops_turn: bool,
}

/// Accumulated result from stream processing.
#[derive(Clone, Debug)]
pub struct StreamResult {
    /// Full assistant message.
    pub message: crate::shared::protocol::events::AssistantMessage,
    /// Extracted capability invocations.
    pub capability_invocations: Vec<crate::shared::protocol::messages::CapabilityInvocationDraft>,
    /// Stop reason string from LLM.
    pub stop_reason: String,
    /// Token usage.
    pub token_usage: Option<TokenUsage>,
    /// Whether the stream was interrupted.
    pub interrupted: bool,
    /// Partial content if interrupted.
    pub partial_content: Option<String>,
    /// Time to first token in milliseconds (from stream start to first content).
    pub ttft_ms: Option<u64>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn agent_config_default() {
        let cfg = AgentConfig::default();
        assert_eq!(cfg.model, "claude-opus-4-6");
        assert_eq!(cfg.max_turns, 250);
        assert!(!cfg.enable_thinking);
        assert!(cfg.stop_sequences.is_empty());
        assert!(cfg.provider_type.is_none());
        assert!(cfg.system_prompt.is_none());
        assert!(cfg.max_tokens.is_none());
        assert!(cfg.temperature.is_none());
        assert!(cfg.thinking_budget.is_none());
    }

    #[test]
    fn agent_config_serde_roundtrip() {
        let cfg = AgentConfig {
            model: "claude-sonnet-4-5".into(),
            max_turns: 10,
            enable_thinking: true,
            thinking_budget: Some(5000),
            ..Default::default()
        };
        let json = serde_json::to_string(&cfg).unwrap();
        let back: AgentConfig = serde_json::from_str(&json).unwrap();
        assert_eq!(back.model, "claude-sonnet-4-5");
        assert_eq!(back.max_turns, 10);
        assert!(back.enable_thinking);
        assert_eq!(back.thinking_budget, Some(5000));
    }

    #[test]
    fn agent_config_serde_skips_none() {
        let cfg = AgentConfig::default();
        let json = serde_json::to_value(&cfg).unwrap();
        assert!(json.get("providerType").is_none());
        assert!(json.get("systemPrompt").is_none());
        assert!(json.get("maxTokens").is_none());
    }

    #[test]
    fn run_context_default() {
        let ctx = RunContext::default();
        assert!(ctx.agent_state_context.is_none());
        assert!(ctx.reasoning_level.is_none());
    }

    #[test]
    fn run_context_serde_roundtrip() {
        let ctx = RunContext {
            agent_state_context: Some("state ctx".into()),
            reasoning_level: Some(ReasoningLevel::High),
            ..Default::default()
        };
        let json = serde_json::to_string(&ctx).unwrap();
        let back: RunContext = serde_json::from_str(&json).unwrap();
        assert_eq!(back.agent_state_context.as_deref(), Some("state ctx"));
        assert_eq!(back.reasoning_level, Some(ReasoningLevel::High));
    }

    #[test]
    fn turn_result_default() {
        let tr = TurnResult::default();
        assert!(tr.success);
        assert!(tr.error.is_none());
        assert_eq!(tr.capability_invocations_executed, 0);
        assert!(!tr.interrupted);
        assert!(!tr.stop_turn_requested);
        assert!(tr.model.is_none());
        assert_eq!(tr.latency_ms, 0);
        assert!(!tr.has_thinking);
        assert!(tr.llm_stop_reason.is_none());
    }

    #[test]
    fn turn_result_with_metadata() {
        let tr = TurnResult {
            success: true,
            model: Some("claude-opus-4-6".into()),
            latency_ms: 1500,
            has_thinking: true,
            llm_stop_reason: Some("end_turn".into()),
            ..Default::default()
        };
        assert_eq!(tr.model.as_deref(), Some("claude-opus-4-6"));
        assert_eq!(tr.latency_ms, 1500);
        assert!(tr.has_thinking);
        assert_eq!(tr.llm_stop_reason.as_deref(), Some("end_turn"));
    }

    #[test]
    fn turn_result_serde_roundtrip() {
        let tr = TurnResult {
            success: false,
            error: Some("provider timeout".into()),
            capability_invocations_executed: 3,
            token_usage: Some(TokenUsage {
                input_tokens: 100,
                output_tokens: 50,
                ..Default::default()
            }),
            stop_reason: Some(StopReason::Error),
            model: Some("claude-opus-4-6".into()),
            latency_ms: 2000,
            has_thinking: true,
            llm_stop_reason: Some("end_turn".into()),
            ..Default::default()
        };
        let json = serde_json::to_string(&tr).unwrap();
        let back: TurnResult = serde_json::from_str(&json).unwrap();
        assert!(!back.success);
        assert_eq!(back.capability_invocations_executed, 3);
        assert_eq!(back.stop_reason, Some(StopReason::Error));
        assert_eq!(back.model.as_deref(), Some("claude-opus-4-6"));
        assert_eq!(back.latency_ms, 2000);
        assert!(back.has_thinking);
        assert_eq!(back.llm_stop_reason.as_deref(), Some("end_turn"));
    }

    #[test]
    fn run_result_default() {
        let rr = RunResult::default();
        assert_eq!(rr.turns_executed, 0);
        assert_eq!(rr.stop_reason, StopReason::EndTurn);
        assert!(!rr.interrupted);
        assert!(rr.error.is_none());
        assert!(rr.last_context_window_tokens.is_none());
    }

    #[test]
    fn run_result_serde_roundtrip() {
        let rr = RunResult {
            turns_executed: 5,
            total_token_usage: TokenUsage {
                input_tokens: 1000,
                output_tokens: 500,
                ..Default::default()
            },
            stop_reason: StopReason::MaxTurns,
            interrupted: false,
            error: None,
            last_context_window_tokens: None,
        };
        let json = serde_json::to_string(&rr).unwrap();
        let back: RunResult = serde_json::from_str(&json).unwrap();
        assert_eq!(back.turns_executed, 5);
        assert_eq!(back.stop_reason, StopReason::MaxTurns);
        assert_eq!(back.total_token_usage.input_tokens, 1000);
    }

    #[test]
    fn run_result_has_last_context_window_tokens() {
        let rr = RunResult {
            last_context_window_tokens: Some(85_000),
            ..Default::default()
        };
        assert_eq!(rr.last_context_window_tokens, Some(85_000));
    }

    #[test]
    fn run_result_serde_with_context_window_tokens() {
        let rr = RunResult {
            turns_executed: 3,
            last_context_window_tokens: Some(120_000),
            ..Default::default()
        };
        let json = serde_json::to_string(&rr).unwrap();
        let back: RunResult = serde_json::from_str(&json).unwrap();
        assert_eq!(back.last_context_window_tokens, Some(120_000));
        assert_eq!(back.turns_executed, 3);
    }

    #[test]
    fn reasoning_level_serde() {
        assert_eq!(
            serde_json::to_string(&ReasoningLevel::None).unwrap(),
            "\"none\""
        );
        assert_eq!(
            serde_json::to_string(&ReasoningLevel::Low).unwrap(),
            "\"low\""
        );
        assert_eq!(
            serde_json::to_string(&ReasoningLevel::Medium).unwrap(),
            "\"medium\""
        );
        assert_eq!(
            serde_json::to_string(&ReasoningLevel::High).unwrap(),
            "\"high\""
        );
        assert_eq!(
            serde_json::to_string(&ReasoningLevel::XHigh).unwrap(),
            "\"x_high\""
        );
        assert_eq!(
            serde_json::to_string(&ReasoningLevel::Max).unwrap(),
            "\"max\""
        );
    }

    #[test]
    fn reasoning_level_xhigh_canonical_form() {
        let level: ReasoningLevel = serde_json::from_str("\"x_high\"").unwrap();
        assert_eq!(level, ReasoningLevel::XHigh);
    }

    #[test]
    fn reasoning_level_xhigh_alias_rejected() {
        let result = serde_json::from_str::<ReasoningLevel>("\"xhigh\"");
        assert!(result.is_err());
    }

    #[test]
    fn reasoning_level_as_gemini_thinking_level() {
        assert_eq!(
            ReasoningLevel::None.as_gemini_thinking_level(),
            "THINKING_DISABLED"
        );
        assert_eq!(
            ReasoningLevel::Low.as_gemini_thinking_level(),
            "THINKING_LOW"
        );
        assert_eq!(
            ReasoningLevel::Medium.as_gemini_thinking_level(),
            "THINKING_MEDIUM"
        );
        assert_eq!(
            ReasoningLevel::High.as_gemini_thinking_level(),
            "THINKING_HIGH"
        );
        // XHigh and Max clamp to THINKING_HIGH for Gemini
        assert_eq!(
            ReasoningLevel::XHigh.as_gemini_thinking_level(),
            "THINKING_HIGH"
        );
        assert_eq!(
            ReasoningLevel::Max.as_gemini_thinking_level(),
            "THINKING_HIGH"
        );
    }

    #[test]
    fn reasoning_level_as_anthropic_effort() {
        assert_eq!(ReasoningLevel::None.as_anthropic_effort(), None);
        assert_eq!(
            ReasoningLevel::Low.as_anthropic_effort(),
            Some(AnthropicEffortLevel::Low)
        );
        assert_eq!(
            ReasoningLevel::Medium.as_anthropic_effort(),
            Some(AnthropicEffortLevel::Medium)
        );
        assert_eq!(
            ReasoningLevel::High.as_anthropic_effort(),
            Some(AnthropicEffortLevel::High)
        );
        // XHigh and Max pass through to Anthropic (Anthropic supports the
        // full ladder; per-model support is advertised via reasoning_levels).
        assert_eq!(
            ReasoningLevel::XHigh.as_anthropic_effort(),
            Some(AnthropicEffortLevel::Xhigh)
        );
        assert_eq!(
            ReasoningLevel::Max.as_anthropic_effort(),
            Some(AnthropicEffortLevel::Max)
        );
    }

    #[test]
    fn reasoning_level_as_openai_reasoning() {
        assert_eq!(
            ReasoningLevel::None.as_openai_reasoning(),
            ReasoningEffort::None
        );
        assert_eq!(
            ReasoningLevel::Low.as_openai_reasoning(),
            ReasoningEffort::Low
        );
        assert_eq!(
            ReasoningLevel::Medium.as_openai_reasoning(),
            ReasoningEffort::Medium
        );
        assert_eq!(
            ReasoningLevel::High.as_openai_reasoning(),
            ReasoningEffort::High
        );
        assert_eq!(
            ReasoningLevel::XHigh.as_openai_reasoning(),
            ReasoningEffort::Xhigh
        );
        assert_eq!(
            ReasoningLevel::Max.as_openai_reasoning(),
            ReasoningEffort::Max
        );
    }

    #[test]
    fn reasoning_level_from_str_loose() {
        assert_eq!(
            ReasoningLevel::from_str_loose("none"),
            Some(ReasoningLevel::None)
        );
        assert_eq!(
            ReasoningLevel::from_str_loose("LOW"),
            Some(ReasoningLevel::Low)
        );
        assert_eq!(
            ReasoningLevel::from_str_loose("Medium"),
            Some(ReasoningLevel::Medium)
        );
        assert_eq!(
            ReasoningLevel::from_str_loose("HIGH"),
            Some(ReasoningLevel::High)
        );
        assert_eq!(
            ReasoningLevel::from_str_loose("xhigh"),
            Some(ReasoningLevel::XHigh)
        );
        assert_eq!(
            ReasoningLevel::from_str_loose("x_high"),
            Some(ReasoningLevel::XHigh)
        );
        assert_eq!(
            ReasoningLevel::from_str_loose("x-high"),
            Some(ReasoningLevel::XHigh)
        );
        assert_eq!(
            ReasoningLevel::from_str_loose("max"),
            Some(ReasoningLevel::Max)
        );
        assert_eq!(
            ReasoningLevel::from_str_loose("MAX"),
            Some(ReasoningLevel::Max)
        );
        assert_eq!(ReasoningLevel::from_str_loose("unknown"), Option::None);
        assert_eq!(ReasoningLevel::from_str_loose(""), Option::None);
    }

    #[test]
    fn reasoning_level_roundtrip() {
        for level in &[
            ReasoningLevel::None,
            ReasoningLevel::Low,
            ReasoningLevel::Medium,
            ReasoningLevel::High,
            ReasoningLevel::XHigh,
            ReasoningLevel::Max,
        ] {
            let json = serde_json::to_string(level).unwrap();
            let back: ReasoningLevel = serde_json::from_str(&json).unwrap();
            assert_eq!(*level, back);
        }
    }
}
