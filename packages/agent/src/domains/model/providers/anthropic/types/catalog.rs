//! Anthropic Claude model catalog metadata and API projection helpers.

use std::collections::HashMap;
use std::sync::LazyLock;

// ─────────────────────────────────────────────────────────────────────────────
// Model catalog
// ─────────────────────────────────────────────────────────────────────────────

/// Information about a Claude model.
#[derive(Clone, Debug)]
#[allow(clippy::struct_excessive_bools)]
pub struct ClaudeModelInfo {
    /// Human-readable name.
    pub name: &'static str,
    /// Short name for compact display.
    pub short_name: &'static str,
    /// Model family.
    pub family: &'static str,
    /// Context window size in tokens.
    pub context_window: u64,
    /// Maximum output tokens.
    pub max_output: u32,
    /// Supports extended thinking.
    pub supports_thinking: bool,
    /// Requires thinking beta headers (pre-Opus 4.6).
    pub supports_thinking_beta_headers: bool,
    /// Supports adaptive thinking (Opus 4.6+).
    pub supports_adaptive_thinking: bool,
    /// Supports effort levels (Opus 4.6+).
    pub supports_effort: bool,
    /// Supports capability invocation.
    pub supports_capabilities: bool,
    /// Supports image inputs.
    pub supports_images: bool,
    /// Input cost per million tokens (USD).
    pub input_cost_per_million: f64,
    /// Output cost per million tokens (USD).
    pub output_cost_per_million: f64,
    /// Cache read cost per million tokens (USD).
    pub cache_read_cost_per_million: f64,
    /// Model description.
    pub description: &'static str,
    /// Whether this is the recommended model.
    pub recommended: bool,
    /// Whether this is a retired-generation model.
    pub retired_generation: bool,
    /// Model tier (e.g., "opus", "sonnet", "haiku").
    pub tier: &'static str,
    /// Display sort order within the provider (lower = higher priority).
    pub sort_order: u16,
    /// Release date (ISO-8601).
    pub release_date: &'static str,
    /// Whether this model is retired by the provider.
    pub is_retired: bool,
    /// Retirement date (ISO-8601), if retired.
    pub deprecation_date: Option<&'static str>,
    /// Supported reasoning/effort levels (e.g., `["low", "medium", "high", "max"]`).
    /// `None` means the model does not support reasoning levels.
    pub reasoning_levels: Option<&'static [&'static str]>,
    /// Default reasoning/effort level. `None` if reasoning not supported.
    pub default_reasoning_level: Option<&'static str>,
    /// Thinking display mode to send in `thinking.display`.
    /// `None` → omit the field (matches prior behavior for Opus 4.6 and below,
    /// where "summarized" was the API default). `Some("summarized")` → explicit
    /// opt-in (required on Opus 4.7+ to keep summarized thinking blocks visible,
    /// since their default is "omitted").
    pub thinking_display: Option<&'static str>,
}

/// Get model info for a Claude model ID.
#[must_use]
pub fn get_claude_model(model_id: &str) -> Option<&'static ClaudeModelInfo> {
    CLAUDE_MODELS.get(model_id)
}

/// All registered Claude model IDs.
#[must_use]
pub fn all_claude_model_ids() -> Vec<&'static str> {
    CLAUDE_MODELS.keys().copied().collect()
}

impl ClaudeModelInfo {
    /// Serialize this model to JSON for the `model.list` API response.
    pub fn to_api_json(&self, id: &str) -> serde_json::Value {
        let mut obj = serde_json::json!({
            "id": id,
            "name": self.short_name,
            "shortName": self.short_name,
            "provider": "anthropic",
            "providerDisplayName": "Anthropic",
            "providerSortOrder": 0,
            "contextWindow": self.context_window,
            "maxOutput": self.max_output,
            "supportsThinking": self.supports_thinking,
            "supportsCapabilityPrimitives": self.supports_capabilities,
            "supportsImages": self.supports_images,
            "supportsDocuments": true,
            "inputCostPerMillion": self.input_cost_per_million,
            "outputCostPerMillion": self.output_cost_per_million,
            "cacheReadCostPerMillion": self.cache_read_cost_per_million,
            "tier": self.tier,
            "family": self.family,
            "description": self.description,
            "supportsReasoning": self.reasoning_levels.is_some(),
            "recommended": self.recommended,
            "isLegacy": self.retired_generation,
            "releaseDate": self.release_date,
            "sortOrder": self.sort_order,
        });
        let map = obj.as_object_mut().unwrap();
        if let Some(levels) = self.reasoning_levels {
            let _ = map.insert("reasoningLevels".into(), serde_json::json!(levels));
        }
        if let Some(default) = self.default_reasoning_level {
            let _ = map.insert("defaultReasoningLevel".into(), serde_json::json!(default));
        }
        if self.is_retired {
            let _ = map.insert("isDeprecated".into(), serde_json::json!(true));
        }
        if let Some(date) = self.deprecation_date {
            let _ = map.insert("deprecationDate".into(), serde_json::json!(date));
        }
        obj
    }
}

/// All Claude models serialized for the `model.list` API, sorted by `sort_order`.
pub fn all_claude_models_api_json() -> Vec<serde_json::Value> {
    let mut entries: Vec<_> = CLAUDE_MODELS.iter().collect();
    entries.sort_by_key(|(_, info)| info.sort_order);
    entries
        .into_iter()
        .map(|(id, info)| info.to_api_json(id))
        .collect()
}

/// Claude model registry.
///
/// Model IDs match the canonical constants from `crate::domains::model::routing::models::model_ids`.
static CLAUDE_MODELS: LazyLock<HashMap<&'static str, ClaudeModelInfo>> = LazyLock::new(|| {
    let mut m = HashMap::new();

    // Claude Opus 4.7 — released April 2026, most capable
    let _ = m.insert(
        "claude-opus-4-7",
        ClaudeModelInfo {
            name: "Claude Opus 4.7",
            short_name: "Opus 4.7",
            family: "Claude 4.7",
            context_window: 1_000_000,
            max_output: 128_000,
            supports_thinking: true,
            supports_thinking_beta_headers: false,
            supports_adaptive_thinking: true,
            supports_effort: true,
            supports_capabilities: true,
            supports_images: true,
            input_cost_per_million: 5.0,
            output_cost_per_million: 25.0,
            cache_read_cost_per_million: 0.5,
            description: "Most capable Claude model — xhigh effort, high-res vision",
            recommended: true,
            retired_generation: false,
            tier: "opus",
            sort_order: 0,
            release_date: "2026-04-16",
            is_retired: false,
            deprecation_date: None,
            reasoning_levels: Some(&["low", "medium", "high", "xhigh", "max"]),
            default_reasoning_level: Some("xhigh"),
            thinking_display: Some("summarized"),
        },
    );

    // Claude Opus 4.6
    let _ = m.insert(
        "claude-opus-4-6",
        ClaudeModelInfo {
            name: "Claude Opus 4.6",
            short_name: "Opus 4.6",
            family: "Claude 4.6",
            context_window: 1_000_000,
            max_output: 128_000,
            supports_thinking: true,
            supports_thinking_beta_headers: false,
            supports_adaptive_thinking: true,
            supports_effort: true,
            supports_capabilities: true,
            supports_images: true,
            input_cost_per_million: 5.0,
            output_cost_per_million: 25.0,
            cache_read_cost_per_million: 0.5,
            description: "Previous Opus — adaptive thinking, effort levels",
            recommended: false,
            retired_generation: false,
            tier: "opus",
            sort_order: 1,
            release_date: "2026-02-01",
            is_retired: false,
            deprecation_date: None,
            reasoning_levels: Some(&["low", "medium", "high", "max"]),
            default_reasoning_level: Some("high"),
            thinking_display: None,
        },
    );

    // Claude Sonnet 4.6
    let _ = m.insert(
        "claude-sonnet-4-6",
        ClaudeModelInfo {
            name: "Claude Sonnet 4.6",
            short_name: "Sonnet 4.6",
            family: "Claude 4.6",
            context_window: 1_000_000,
            max_output: 64_000,
            supports_thinking: true,
            supports_thinking_beta_headers: false,
            supports_adaptive_thinking: true,
            supports_effort: true,
            supports_capabilities: true,
            supports_images: true,
            input_cost_per_million: 3.0,
            output_cost_per_million: 15.0,
            cache_read_cost_per_million: 0.3,
            description: "Best combination of speed and intelligence — adaptive thinking",
            recommended: true,
            retired_generation: false,
            tier: "sonnet",
            sort_order: 2,
            release_date: "2026-02-17",
            is_retired: false,
            deprecation_date: None,
            reasoning_levels: Some(&["low", "medium", "high", "max"]),
            default_reasoning_level: Some("medium"),
            thinking_display: None,
        },
    );

    // Claude 4.5 family
    let _ = m.insert(
        "claude-opus-4-5-20251101",
        ClaudeModelInfo {
            name: "Claude Opus 4.5",
            short_name: "Opus 4.5",
            family: "Claude 4.5",
            context_window: 200_000,
            max_output: 64_000,
            supports_thinking: true,
            supports_thinking_beta_headers: true,
            supports_adaptive_thinking: false,
            supports_effort: false,
            supports_capabilities: true,
            supports_images: true,
            input_cost_per_million: 5.0,
            output_cost_per_million: 25.0,
            cache_read_cost_per_million: 0.5,
            description: "Opus-tier intelligence with extended thinking",
            recommended: false,
            retired_generation: false,
            tier: "opus",
            sort_order: 3,
            release_date: "2025-11-01",
            is_retired: false,
            deprecation_date: None,
            reasoning_levels: None,
            default_reasoning_level: None,
            thinking_display: None,
        },
    );

    let _ = m.insert(
        "claude-sonnet-4-5-20250929",
        ClaudeModelInfo {
            name: "Claude Sonnet 4.5",
            short_name: "Sonnet 4.5",
            family: "Claude 4.5",
            context_window: 200_000,
            max_output: 64_000,
            supports_thinking: true,
            supports_thinking_beta_headers: true,
            supports_adaptive_thinking: false,
            supports_effort: false,
            supports_capabilities: true,
            supports_images: true,
            input_cost_per_million: 3.0,
            output_cost_per_million: 15.0,
            cache_read_cost_per_million: 0.3,
            description: "Best balance of speed and intelligence",
            recommended: false,
            retired_generation: true,
            tier: "sonnet",
            sort_order: 4,
            release_date: "2025-09-29",
            is_retired: false,
            deprecation_date: None,
            reasoning_levels: None,
            default_reasoning_level: None,
            thinking_display: None,
        },
    );

    let _ = m.insert(
        "claude-haiku-4-5-20251001",
        ClaudeModelInfo {
            name: "Claude Haiku 4.5",
            short_name: "Haiku 4.5",
            family: "Claude 4.5",
            context_window: 200_000,
            max_output: 64_000,
            supports_thinking: true,
            supports_thinking_beta_headers: true,
            supports_adaptive_thinking: false,
            supports_effort: false,
            supports_capabilities: true,
            supports_images: true,
            input_cost_per_million: 1.0,
            output_cost_per_million: 5.0,
            cache_read_cost_per_million: 0.1,
            description: "Fast and affordable",
            recommended: true,
            retired_generation: false,
            tier: "haiku",
            sort_order: 5,
            release_date: "2025-10-01",
            is_retired: false,
            deprecation_date: None,
            reasoning_levels: None,
            default_reasoning_level: None,
            thinking_display: None,
        },
    );

    // Claude 4.1 (retired generation — August 2025)
    let _ = m.insert(
        "claude-opus-4-1-20250805",
        ClaudeModelInfo {
            name: "Claude Opus 4.1",
            short_name: "Opus 4.1",
            family: "Claude 4.1",
            context_window: 200_000,
            max_output: 32_000,
            supports_thinking: true,
            supports_thinking_beta_headers: true,
            supports_adaptive_thinking: false,
            supports_effort: false,
            supports_capabilities: true,
            supports_images: true,
            input_cost_per_million: 15.0,
            output_cost_per_million: 75.0,
            cache_read_cost_per_million: 1.5,
            description: "Previous Opus with enhanced agentic capabilities",
            recommended: false,
            retired_generation: true,
            tier: "opus",
            sort_order: 6,
            release_date: "2025-08-05",
            is_retired: false,
            deprecation_date: None,
            reasoning_levels: None,
            default_reasoning_level: None,
            thinking_display: None,
        },
    );

    // Claude 4 (retired generation — May 2025)
    let _ = m.insert(
        "claude-opus-4-20250514",
        ClaudeModelInfo {
            name: "Claude Opus 4",
            short_name: "Opus 4",
            family: "Claude 4",
            context_window: 200_000,
            max_output: 32_000,
            supports_thinking: true,
            supports_thinking_beta_headers: true,
            supports_adaptive_thinking: false,
            supports_effort: false,
            supports_capabilities: true,
            supports_images: true,
            input_cost_per_million: 15.0,
            output_cost_per_million: 75.0,
            cache_read_cost_per_million: 1.5,
            description: "Previous generation Opus",
            recommended: false,
            retired_generation: true,
            tier: "opus",
            sort_order: 7,
            release_date: "2025-05-14",
            is_retired: false,
            deprecation_date: None,
            reasoning_levels: None,
            default_reasoning_level: None,
            thinking_display: None,
        },
    );

    let _ = m.insert(
        "claude-sonnet-4-20250514",
        ClaudeModelInfo {
            name: "Claude Sonnet 4",
            short_name: "Sonnet 4",
            family: "Claude 4",
            context_window: 200_000,
            max_output: 64_000,
            supports_thinking: true,
            supports_thinking_beta_headers: true,
            supports_adaptive_thinking: false,
            supports_effort: false,
            supports_capabilities: true,
            supports_images: true,
            input_cost_per_million: 3.0,
            output_cost_per_million: 15.0,
            cache_read_cost_per_million: 0.3,
            description: "Fast and capable",
            recommended: false,
            retired_generation: true,
            tier: "sonnet",
            sort_order: 8,
            release_date: "2025-05-14",
            is_retired: false,
            deprecation_date: None,
            reasoning_levels: None,
            default_reasoning_level: None,
            thinking_display: None,
        },
    );

    // Claude 3.7 (provider-retired; unavailable for new model selection)
    let _ = m.insert(
        "claude-3-7-sonnet-20250219",
        ClaudeModelInfo {
            name: "Claude 3.7 Sonnet",
            short_name: "Sonnet 3.7",
            family: "Claude 3.7",
            context_window: 200_000,
            max_output: 64_000,
            supports_thinking: true,
            supports_thinking_beta_headers: true,
            supports_adaptive_thinking: false,
            supports_effort: false,
            supports_capabilities: true,
            supports_images: true,
            input_cost_per_million: 3.0,
            output_cost_per_million: 15.0,
            cache_read_cost_per_million: 0.3,
            description: "Retired — use Sonnet 4 or newer",
            recommended: false,
            retired_generation: true,
            tier: "sonnet",
            sort_order: 9,
            release_date: "2025-02-19",
            is_retired: true,
            deprecation_date: Some("2025-10-01"),
            reasoning_levels: None,
            default_reasoning_level: None,
            thinking_display: None,
        },
    );

    // Claude 3 (retired generation — oldest)
    let _ = m.insert(
        "claude-3-haiku-20240307",
        ClaudeModelInfo {
            name: "Claude 3 Haiku",
            short_name: "Haiku 3",
            family: "Claude 3",
            context_window: 200_000,
            max_output: 4_096,
            supports_thinking: false,
            supports_thinking_beta_headers: false,
            supports_adaptive_thinking: false,
            supports_effort: false,
            supports_capabilities: true,
            supports_images: true,
            input_cost_per_million: 0.25,
            output_cost_per_million: 1.25,
            cache_read_cost_per_million: 0.025,
            description: "Retired generation — fast and affordable",
            recommended: false,
            retired_generation: true,
            tier: "haiku",
            sort_order: 10,
            release_date: "2024-03-07",
            is_retired: false,
            deprecation_date: None,
            reasoning_levels: None,
            default_reasoning_level: None,
            thinking_display: None,
        },
    );

    m
});

/// Default model ID.
#[cfg(test)]
pub const DEFAULT_MODEL: &str = "claude-opus-4-6";
