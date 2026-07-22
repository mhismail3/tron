use std::collections::HashMap;
use std::sync::LazyLock;

use super::GeminiThinkingLevel;

const THINKING_MINIMAL_TO_HIGH: &[&str] = &["minimal", "low", "medium", "high"];
const THINKING_LOW_TO_HIGH: &[&str] = &["low", "medium", "high"];

// ─────────────────────────────────────────────────────────────────────────────
// Model registry
// ─────────────────────────────────────────────────────────────────────────────

/// Information about a Gemini model.
#[derive(Clone, Debug)]
#[allow(clippy::struct_excessive_bools)]
pub struct GeminiModelInfo {
    /// Short display name.
    pub short_name: &'static str,
    /// Context window size in tokens.
    pub context_window: u64,
    /// Maximum output tokens.
    pub max_output: u64,
    /// Whether the model supports tool invocation.
    pub supports_tools: bool,
    /// Whether the model supports image inputs.
    pub supports_images: bool,
    /// Whether the model supports thinking mode.
    pub supports_thinking: bool,
    /// Model tier.
    pub tier: &'static str,
    /// Whether this is a preview model.
    pub preview: bool,
    /// Default thinking level for Gemini 3 models.
    pub default_thinking_level: Option<GeminiThinkingLevel>,
    /// Input cost per million tokens (USD).
    pub input_cost_per_million: f64,
    /// Output cost per million tokens (USD).
    pub output_cost_per_million: f64,
    /// Model family (e.g., "Gemini 3", "Gemini 2.5").
    pub family: &'static str,
    /// Model description for the client UI.
    pub description: &'static str,
    /// Display sort order within the provider (lower = higher priority).
    pub sort_order: u16,
    /// Whether this model is recommended for new users.
    pub recommended: bool,
    /// Whether this is a retired/older generation model.
    pub is_retired_generation: bool,
    /// Whether this model is retired by the provider.
    pub is_retired: bool,
    /// Retirement date (ISO-8601), if retired.
    pub deprecation_date: Option<&'static str>,
    /// Supported thinking level names for the API response.
    pub supported_thinking_levels: &'static [&'static str],
}

/// Model registry mapping model IDs to their metadata.
#[allow(unused_results)]
pub static GEMINI_MODELS: LazyLock<HashMap<&'static str, GeminiModelInfo>> = LazyLock::new(|| {
    let mut m = HashMap::new();
    m.insert(
        "gemini-3.6-flash",
        GeminiModelInfo {
            short_name: "Gemini 3.6 Flash",
            context_window: 1_048_576,
            max_output: 65_536,
            supports_tools: true,
            supports_images: true,
            supports_thinking: true,
            tier: "flash",
            preview: false,
            default_thinking_level: Some(GeminiThinkingLevel::Medium),
            input_cost_per_million: 1.50,
            output_cost_per_million: 7.50,
            family: "Gemini 3.6",
            description: "Gemini 3.6 Flash — Google's current balance of speed and intelligence for agentic and multimodal work.",
            sort_order: 0,
            recommended: true,
            is_retired_generation: false,
            is_retired: false,
            deprecation_date: None,
            supported_thinking_levels: THINKING_MINIMAL_TO_HIGH,
        },
    );
    m.insert(
        "gemini-3.5-flash",
        GeminiModelInfo {
            short_name: "Gemini 3.5 Flash",
            context_window: 1_048_576,
            max_output: 65_536,
            supports_tools: true,
            supports_images: true,
            supports_thinking: true,
            tier: "flash",
            preview: false,
            default_thinking_level: Some(GeminiThinkingLevel::Medium),
            input_cost_per_million: 1.50,
            output_cost_per_million: 9.00,
            family: "Gemini 3.5",
            description: "Gemini 3.5 Flash — sustained frontier performance for agentic coding and long-horizon tasks.",
            sort_order: 1,
            recommended: false,
            is_retired_generation: true,
            is_retired: false,
            deprecation_date: None,
            supported_thinking_levels: THINKING_MINIMAL_TO_HIGH,
        },
    );
    m.insert(
        "gemini-3.5-flash-lite",
        GeminiModelInfo {
            short_name: "Gemini 3.5 Flash-Lite",
            context_window: 1_048_576,
            max_output: 65_536,
            supports_tools: true,
            supports_images: true,
            supports_thinking: true,
            tier: "flash-lite",
            preview: false,
            default_thinking_level: Some(GeminiThinkingLevel::Minimal),
            input_cost_per_million: 0.30,
            output_cost_per_million: 2.50,
            family: "Gemini 3.5",
            description: "Gemini 3.5 Flash-Lite — low-cost, high-throughput agent and structured-data execution.",
            sort_order: 2,
            recommended: false,
            is_retired_generation: false,
            is_retired: false,
            deprecation_date: None,
            supported_thinking_levels: THINKING_MINIMAL_TO_HIGH,
        },
    );
    m.insert(
        "gemini-3.1-pro-preview",
        GeminiModelInfo {
            short_name: "Gemini 3.1 Pro",
            context_window: 1_048_576,
            max_output: 65_536,
            supports_tools: true,
            supports_images: true,
            supports_thinking: true,
            tier: "pro",
            preview: true,
            default_thinking_level: Some(GeminiThinkingLevel::High),
            input_cost_per_million: 2.0,
            output_cost_per_million: 12.0,
            family: "Gemini 3.1",
            description: "Gemini 3.1 Pro (Preview) — optimized for software engineering and agentic workflows.",
            sort_order: 3,
            recommended: false,
            is_retired_generation: false,
            is_retired: false,
            deprecation_date: None,
            supported_thinking_levels: THINKING_LOW_TO_HIGH,
        },
    );
    m.insert(
        "gemini-3.1-flash-lite",
        GeminiModelInfo {
            short_name: "Gemini 3.1 Flash-Lite",
            context_window: 1_048_576,
            max_output: 65_536,
            supports_tools: true,
            supports_images: true,
            supports_thinking: true,
            tier: "flash-lite",
            preview: false,
            default_thinking_level: Some(GeminiThinkingLevel::Minimal),
            input_cost_per_million: 0.25,
            output_cost_per_million: 1.50,
            family: "Gemini 3.1",
            description: "Gemini 3.1 Flash-Lite — efficient multimodal execution for lightweight tasks at scale.",
            sort_order: 4,
            recommended: false,
            is_retired_generation: true,
            is_retired: false,
            deprecation_date: None,
            supported_thinking_levels: THINKING_MINIMAL_TO_HIGH,
        },
    );
    m.insert(
        "gemini-3-pro-preview",
        GeminiModelInfo {
            short_name: "Gemini 3 Pro",
            context_window: 1_048_576,
            max_output: 65_536,
            supports_tools: true,
            supports_images: true,
            supports_thinking: true,
            tier: "pro",
            preview: true,
            default_thinking_level: Some(GeminiThinkingLevel::High),
            input_cost_per_million: 2.0,
            output_cost_per_million: 12.0,
            family: "Gemini 3.1",
            description: "Gemini 3 Pro (Preview) — retired, replaced by Gemini 3.1 Pro.",
            sort_order: 10,
            recommended: false,
            is_retired_generation: true,
            is_retired: true,
            deprecation_date: Some("2026-03-09"),
            supported_thinking_levels: &["low", "high"],
        },
    );
    m.insert(
        "gemini-3.1-flash-lite-preview",
        GeminiModelInfo {
            short_name: "Gemini 3.1 Flash Lite",
            context_window: 1_048_576,
            max_output: 65_536,
            supports_tools: true,
            supports_images: true,
            supports_thinking: true,
            tier: "flash-lite",
            preview: true,
            default_thinking_level: Some(GeminiThinkingLevel::Minimal),
            input_cost_per_million: 0.25,
            output_cost_per_million: 1.50,
            family: "Gemini 3.1",
            description: "Gemini 3.1 Flash-Lite (Preview) — shut down; use a stable Flash-Lite model.",
            sort_order: 11,
            recommended: false,
            is_retired_generation: true,
            is_retired: true,
            deprecation_date: Some("2026-05-25"),
            supported_thinking_levels: THINKING_MINIMAL_TO_HIGH,
        },
    );
    m.insert(
        "gemini-3-flash-preview",
        GeminiModelInfo {
            short_name: "Gemini 3 Flash",
            context_window: 1_048_576,
            max_output: 65_536,
            supports_tools: true,
            supports_images: true,
            supports_thinking: true,
            tier: "flash",
            preview: true,
            default_thinking_level: Some(GeminiThinkingLevel::High),
            input_cost_per_million: 0.50,
            output_cost_per_million: 3.0,
            family: "Gemini 3",
            description: "Gemini 3 Flash (Preview) — active preview; Gemini 3.6 Flash is the stable replacement.",
            sort_order: 12,
            recommended: false,
            is_retired_generation: true,
            is_retired: false,
            deprecation_date: None,
            supported_thinking_levels: THINKING_MINIMAL_TO_HIGH,
        },
    );
    m.insert(
        "gemini-2.5-pro",
        GeminiModelInfo {
            short_name: "Gemini 2.5 Pro",
            context_window: 1_048_576,
            max_output: 65_536,
            supports_tools: true,
            supports_images: true,
            supports_thinking: true,
            tier: "pro",
            preview: false,
            default_thinking_level: None,
            input_cost_per_million: 1.25,
            output_cost_per_million: 10.0,
            family: "Gemini 2.5",
            description: "Gemini 2.5 Pro — pro tier",
            sort_order: 20,
            recommended: false,
            is_retired_generation: true,
            is_retired: false,
            deprecation_date: None,
            supported_thinking_levels: THINKING_LOW_TO_HIGH,
        },
    );
    m.insert(
        "gemini-2.5-flash",
        GeminiModelInfo {
            short_name: "Gemini 2.5 Flash",
            context_window: 1_048_576,
            max_output: 65_536,
            supports_tools: true,
            supports_images: true,
            supports_thinking: true,
            tier: "flash",
            preview: false,
            default_thinking_level: None,
            input_cost_per_million: 0.30,
            output_cost_per_million: 2.50,
            family: "Gemini 2.5",
            description: "Gemini 2.5 Flash — flash tier",
            sort_order: 21,
            recommended: false,
            is_retired_generation: true,
            is_retired: false,
            deprecation_date: None,
            supported_thinking_levels: THINKING_LOW_TO_HIGH,
        },
    );
    m.insert(
        "gemini-2.5-flash-lite",
        GeminiModelInfo {
            short_name: "Gemini 2.5 Flash Lite",
            context_window: 1_048_576,
            max_output: 65_536,
            supports_tools: true,
            supports_images: true,
            supports_thinking: true,
            tier: "flash-lite",
            preview: false,
            default_thinking_level: None,
            input_cost_per_million: 0.10,
            output_cost_per_million: 0.40,
            family: "Gemini 2.5",
            description: "Gemini 2.5 Flash Lite — flash-lite tier",
            sort_order: 22,
            recommended: false,
            is_retired_generation: true,
            is_retired: false,
            deprecation_date: None,
            supported_thinking_levels: THINKING_LOW_TO_HIGH,
        },
    );
    m
});

/// Provider aliases resolve for persisted settings and API requests but do not
/// create duplicate rows in the model picker.
pub static GEMINI_MODEL_ALIASES: LazyLock<HashMap<&'static str, &'static str>> =
    LazyLock::new(|| {
        HashMap::from([
            ("gemini-flash-latest", "gemini-3.5-flash"),
            ("gemini-flash-lite-latest", "gemini-3.1-flash-lite"),
            ("gemini-pro-latest", "gemini-3.1-pro-preview"),
        ])
    });

/// Look up a Gemini model by ID.
#[must_use]
pub fn get_gemini_model(model_id: &str) -> Option<&'static GeminiModelInfo> {
    GEMINI_MODELS.get(model_id).or_else(|| {
        GEMINI_MODEL_ALIASES
            .get(model_id)
            .and_then(|canonical| GEMINI_MODELS.get(canonical))
    })
}

/// Get all known model IDs.
#[must_use]
pub fn all_gemini_model_ids() -> Vec<&'static str> {
    GEMINI_MODELS
        .keys()
        .chain(GEMINI_MODEL_ALIASES.keys())
        .copied()
        .collect()
}

impl GeminiModelInfo {
    /// Serialize this model to JSON for the `model.list` API response.
    #[allow(unused_results)]
    pub fn to_api_json(&self, id: &str) -> serde_json::Value {
        let mut obj = serde_json::json!({
            "id": id,
            "name": self.short_name,
            "shortName": self.short_name,
            "provider": "google",
            "providerDisplayName": "Google",
            "providerSortOrder": 2,
            "contextWindow": self.context_window,
            "maxOutput": self.max_output,
            "supportsThinking": self.supports_thinking,
            "supportsTools": self.supports_tools,
            "supportsImages": self.supports_images,
            "supportsDocuments": true,
            "inputCostPerMillion": self.input_cost_per_million,
            "outputCostPerMillion": self.output_cost_per_million,
            "tier": self.tier,
            "family": self.family,
            "description": self.description,
            "recommended": self.recommended,
            "isRetiredGeneration": self.is_retired_generation,
            "sortOrder": self.sort_order,
        });
        let map = obj.as_object_mut().unwrap();
        if self.preview {
            let _ = map.insert("isPreview".into(), serde_json::json!(true));
        }
        if let Some(ref level) = self.default_thinking_level {
            let _ = map.insert(
                "thinkingLevel".into(),
                serde_json::json!(level.to_api_string().to_lowercase()),
            );
        }
        if !self.supported_thinking_levels.is_empty() {
            let _ = map.insert(
                "supportedThinkingLevels".into(),
                serde_json::json!(self.supported_thinking_levels),
            );
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

/// All Gemini models serialized for the `model.list` API, sorted by `sort_order`.
pub fn all_gemini_models_api_json() -> Vec<serde_json::Value> {
    let mut entries: Vec<_> = GEMINI_MODELS.iter().collect();
    entries.sort_by_key(|(_, info)| info.sort_order);
    entries
        .into_iter()
        .map(|(id, info)| info.to_api_json(id))
        .collect()
}

/// Check if a model ID is a Gemini 3 model (uses `thinkingLevel` instead of `thinkingBudget`).
#[must_use]
pub fn is_gemini_3_model(model: &str) -> bool {
    get_gemini_model(model).map_or_else(
        || model.contains("gemini-3"),
        |info| info.family.starts_with("Gemini 3"),
    )
}
