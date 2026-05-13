//! Kimi model registry, auth, and config types.
//!
//! Kimi (Moonshot AI) uses an `OpenAI` chat completions-compatible API.
//! Models: K2.5 (flagship), K2 variants, and retired moonshot-v1.

use std::collections::HashMap;
use std::sync::LazyLock;

use crate::domains::model::providers::models::model_ids::{
    KIMI_K2_5, KIMI_K2_0711_PREVIEW, KIMI_K2_0905_PREVIEW, KIMI_K2_THINKING,
    KIMI_K2_THINKING_TURBO, KIMI_K2_TURBO_PREVIEW, MOONSHOT_V1_8K, MOONSHOT_V1_32K,
    MOONSHOT_V1_128K,
};
use crate::domains::model::providers::retry::StreamRetryConfig;

/// Default base URL for the Kimi API.
pub const DEFAULT_BASE_URL: &str = "https://api.moonshot.ai/v1";

/// Default max output tokens for Kimi K2 models.
pub const DEFAULT_MAX_OUTPUT_TOKENS: u32 = 32_768;

/// Kimi authentication — API key only (no OAuth).
#[derive(Clone, Debug)]
pub enum KimiAuth {
    /// API key authentication.
    ApiKey {
        /// The Kimi/Moonshot API key.
        api_key: String,
    },
}

/// Kimi provider configuration.
#[derive(Clone, Debug)]
pub struct KimiConfig {
    /// Model ID (e.g., `"kimi-k2.5"`).
    pub model: String,
    /// Authentication.
    pub auth: KimiAuth,
    /// Override max tokens.
    pub max_tokens: Option<u32>,
    /// Override base URL.
    pub base_url: Option<String>,
    /// Retry configuration.
    pub retry: Option<StreamRetryConfig>,
}

/// Kimi model information.
#[derive(Clone, Debug)]
pub struct KimiModelInfo {
    /// API model ID.
    pub id: &'static str,
    /// Human-readable name.
    pub name: &'static str,
    /// Short name for compact display.
    pub short_name: &'static str,
    /// Model family.
    pub family: &'static str,
    /// Context window in tokens.
    pub context_window: u64,
    /// Maximum output tokens.
    pub max_output: u32,
    /// Supports extended thinking.
    pub supports_thinking: bool,
    /// Supports capability invocation.
    pub supports_capabilities: bool,
    /// Supports image inputs.
    pub supports_images: bool,
    /// Input cost per million tokens (USD).
    pub input_cost_per_million: f64,
    /// Output cost per million tokens (USD).
    pub output_cost_per_million: f64,
    /// Cache read cost per million tokens (USD), if supported.
    pub cache_read_cost_per_million: Option<f64>,
    /// Model description for the client UI.
    pub description: &'static str,
    /// Display sort order within the provider (lower = higher priority).
    pub sort_order: u16,
    /// Whether this model is recommended for new users.
    pub recommended: bool,
    /// Whether this is a retired/older generation model.
    pub is_retired_generation: bool,
}

// Note: Kimi K2.5 supports vision (supports_images: true), while older
// models (K2-0905, Moonshot series) do not. The iOS AttachmentCapability
// system checks each model's supports_images flag individually.
static KIMI_MODELS: LazyLock<HashMap<&'static str, KimiModelInfo>> = LazyLock::new(|| {
    let mut m = HashMap::new();
    let _ = m.insert(
        KIMI_K2_5,
        KimiModelInfo {
            id: KIMI_K2_5,
            name: "Kimi K2.5",
            short_name: "K2.5",
            family: "Kimi K2",
            context_window: 262_144,
            max_output: 32_768,
            supports_thinking: true,
            supports_capabilities: true,
            supports_images: true,
            input_cost_per_million: 0.60,
            output_cost_per_million: 3.00,
            cache_read_cost_per_million: Some(0.10),
            description: "Kimi K2.5 — flagship model with vision and thinking.",
            sort_order: 0,
            recommended: true,
            is_retired_generation: false,
        },
    );
    let _ = m.insert(
        KIMI_K2_0905_PREVIEW,
        KimiModelInfo {
            id: KIMI_K2_0905_PREVIEW,
            name: "Kimi K2 0905 Preview",
            short_name: "K2 0905",
            family: "Kimi K2",
            context_window: 262_144,
            max_output: 32_768,
            supports_thinking: false,
            supports_capabilities: true,
            supports_images: false,
            input_cost_per_million: 0.60,
            output_cost_per_million: 2.50,
            cache_read_cost_per_million: Some(0.15),
            description: "Kimi K2 0905 Preview — capable general-purpose model.",
            sort_order: 1,
            recommended: false,
            is_retired_generation: false,
        },
    );
    let _ = m.insert(
        KIMI_K2_0711_PREVIEW,
        KimiModelInfo {
            id: KIMI_K2_0711_PREVIEW,
            name: "Kimi K2 0711 Preview",
            short_name: "K2 0711",
            family: "Kimi K2",
            context_window: 131_072,
            max_output: 32_768,
            supports_thinking: false,
            supports_capabilities: true,
            supports_images: false,
            input_cost_per_million: 0.60,
            output_cost_per_million: 2.50,
            cache_read_cost_per_million: Some(0.15),
            description: "Kimi K2 0711 Preview — 128K context model.",
            sort_order: 2,
            recommended: false,
            is_retired_generation: false,
        },
    );
    let _ = m.insert(
        KIMI_K2_TURBO_PREVIEW,
        KimiModelInfo {
            id: KIMI_K2_TURBO_PREVIEW,
            name: "Kimi K2 Turbo Preview",
            short_name: "K2 Turbo",
            family: "Kimi K2",
            context_window: 262_144,
            max_output: 32_768,
            supports_thinking: false,
            supports_capabilities: true,
            supports_images: false,
            input_cost_per_million: 1.15,
            output_cost_per_million: 8.00,
            cache_read_cost_per_million: Some(0.15),
            description: "Kimi K2 Turbo Preview — high-speed variant, 60-100 tok/s.",
            sort_order: 3,
            recommended: false,
            is_retired_generation: false,
        },
    );
    let _ = m.insert(
        KIMI_K2_THINKING,
        KimiModelInfo {
            id: KIMI_K2_THINKING,
            name: "Kimi K2 Thinking",
            short_name: "K2 Think",
            family: "Kimi K2",
            context_window: 262_144,
            max_output: 32_768,
            supports_thinking: true,
            supports_capabilities: true,
            supports_images: false,
            input_cost_per_million: 0.60,
            output_cost_per_million: 2.50,
            cache_read_cost_per_million: Some(0.15),
            description: "Kimi K2 Thinking — dedicated thinking model.",
            sort_order: 4,
            recommended: false,
            is_retired_generation: false,
        },
    );
    let _ = m.insert(
        KIMI_K2_THINKING_TURBO,
        KimiModelInfo {
            id: KIMI_K2_THINKING_TURBO,
            name: "Kimi K2 Thinking Turbo",
            short_name: "K2 Think Turbo",
            family: "Kimi K2",
            context_window: 262_144,
            max_output: 32_768,
            supports_thinking: true,
            supports_capabilities: true,
            supports_images: false,
            input_cost_per_million: 1.15,
            output_cost_per_million: 8.00,
            cache_read_cost_per_million: Some(0.15),
            description: "Kimi K2 Thinking Turbo — high-speed thinking model.",
            sort_order: 5,
            recommended: false,
            is_retired_generation: false,
        },
    );
    let _ = m.insert(
        MOONSHOT_V1_8K,
        KimiModelInfo {
            id: MOONSHOT_V1_8K,
            name: "Moonshot V1 8K",
            short_name: "V1 8K",
            family: "Moonshot V1",
            context_window: 8_192,
            max_output: 4_096,
            supports_thinking: false,
            supports_capabilities: false,
            supports_images: false,
            input_cost_per_million: 0.20,
            output_cost_per_million: 2.00,
            cache_read_cost_per_million: None,
            description: "Moonshot V1 8K — retired model.",
            sort_order: 6,
            recommended: false,
            is_retired_generation: true,
        },
    );
    let _ = m.insert(
        MOONSHOT_V1_32K,
        KimiModelInfo {
            id: MOONSHOT_V1_32K,
            name: "Moonshot V1 32K",
            short_name: "V1 32K",
            family: "Moonshot V1",
            context_window: 32_768,
            max_output: 4_096,
            supports_thinking: false,
            supports_capabilities: false,
            supports_images: false,
            input_cost_per_million: 1.00,
            output_cost_per_million: 3.00,
            cache_read_cost_per_million: None,
            description: "Moonshot V1 32K — retired model.",
            sort_order: 7,
            recommended: false,
            is_retired_generation: true,
        },
    );
    let _ = m.insert(
        MOONSHOT_V1_128K,
        KimiModelInfo {
            id: MOONSHOT_V1_128K,
            name: "Moonshot V1 128K",
            short_name: "V1 128K",
            family: "Moonshot V1",
            context_window: 131_072,
            max_output: 4_096,
            supports_thinking: false,
            supports_capabilities: false,
            supports_images: false,
            input_cost_per_million: 2.00,
            output_cost_per_million: 5.00,
            cache_read_cost_per_million: None,
            description: "Moonshot V1 128K — retired long-context model.",
            sort_order: 8,
            recommended: false,
            is_retired_generation: true,
        },
    );
    m
});

/// Look up a Kimi model by ID.
pub fn get_kimi_model(id: &str) -> Option<&'static KimiModelInfo> {
    KIMI_MODELS.get(id)
}

/// All known Kimi model IDs.
pub fn all_kimi_model_ids() -> Vec<&'static str> {
    KIMI_MODELS.keys().copied().collect()
}

impl KimiModelInfo {
    /// Serialize this model to JSON for the `model.list` API response.
    pub fn to_api_json(&self, id: &str) -> serde_json::Value {
        serde_json::json!({
            "id": id,
            "name": self.name,
            "provider": "kimi",
            "providerDisplayName": "Kimi",
            "providerSortOrder": 4,
            "contextWindow": self.context_window,
            "maxOutput": self.max_output,
            "supportsThinking": self.supports_thinking,
            "supportsImages": self.supports_images,
            "supportsDocuments": false,
            "inputCostPerMillion": self.input_cost_per_million,
            "outputCostPerMillion": self.output_cost_per_million,
            "tier": if self.is_retired_generation { "retired" } else { "flagship" },
            "family": self.family,
            "description": self.description,
            "supportsReasoning": false,
            "recommended": self.recommended,
            "isLegacy": self.is_retired_generation,
            "sortOrder": self.sort_order,
        })
    }
}

/// All Kimi models serialized for the `model.list` API, sorted by `sort_order`.
pub fn all_kimi_models_api_json() -> Vec<serde_json::Value> {
    let mut entries: Vec<_> = KIMI_MODELS.iter().collect();
    entries.sort_by_key(|(_, info)| info.sort_order);
    entries
        .into_iter()
        .map(|(id, info)| info.to_api_json(id))
        .collect()
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn get_kimi_model_k2_5() {
        let m = get_kimi_model("kimi-k2.5").unwrap();
        assert_eq!(m.name, "Kimi K2.5");
        assert_eq!(m.context_window, 262_144);
        assert!(m.supports_thinking);
        assert!(m.supports_images);
        assert!(m.supports_capabilities);
        assert!(m.recommended);
        assert!(!m.is_retired_generation);
    }

    #[test]
    fn get_kimi_model_k2_0905() {
        let m = get_kimi_model("kimi-k2-0905-preview").unwrap();
        assert_eq!(m.context_window, 262_144);
        assert!(!m.supports_thinking);
        assert!(!m.supports_images);
        assert!(m.supports_capabilities);
    }

    #[test]
    fn get_kimi_model_k2_0711() {
        let m = get_kimi_model("kimi-k2-0711-preview").unwrap();
        assert_eq!(m.context_window, 131_072);
        assert!(!m.supports_thinking);
    }

    #[test]
    fn get_kimi_model_k2_turbo() {
        let m = get_kimi_model("kimi-k2-turbo-preview").unwrap();
        assert_eq!(m.context_window, 262_144);
        assert!(!m.supports_thinking);
        assert!(m.supports_capabilities);
    }

    #[test]
    fn get_kimi_model_k2_thinking() {
        let m = get_kimi_model("kimi-k2-thinking").unwrap();
        assert!(m.supports_thinking);
        assert!(m.supports_capabilities);
        assert!(!m.supports_images);
    }

    #[test]
    fn get_kimi_model_k2_thinking_turbo() {
        let m = get_kimi_model("kimi-k2-thinking-turbo").unwrap();
        assert!(m.supports_thinking);
        assert!(m.supports_capabilities);
    }

    #[test]
    fn get_kimi_model_moonshot_v1_8k() {
        let m = get_kimi_model("moonshot-v1-8k").unwrap();
        assert_eq!(m.context_window, 8_192);
        assert_eq!(m.max_output, 4_096);
        assert!(!m.supports_thinking);
        assert!(!m.supports_capabilities);
        assert!(!m.supports_images);
        assert!(m.is_retired_generation);
    }

    #[test]
    fn get_kimi_model_moonshot_v1_32k() {
        let m = get_kimi_model("moonshot-v1-32k").unwrap();
        assert_eq!(m.context_window, 32_768);
        assert_eq!(m.max_output, 4_096);
        assert!(m.is_retired_generation);
    }

    #[test]
    fn get_kimi_model_moonshot_v1_128k() {
        let m = get_kimi_model("moonshot-v1-128k").unwrap();
        assert_eq!(m.context_window, 131_072);
        assert_eq!(m.max_output, 4_096);
        assert!(m.is_retired_generation);
    }

    #[test]
    fn get_kimi_model_unknown_returns_none() {
        assert!(get_kimi_model("gpt-5").is_none());
    }

    #[test]
    fn all_kimi_model_ids_count() {
        let ids = all_kimi_model_ids();
        assert_eq!(ids.len(), 9);
        assert!(ids.contains(&"kimi-k2.5"));
        assert!(ids.contains(&"kimi-k2-thinking"));
        assert!(ids.contains(&"moonshot-v1-128k"));
    }

    #[test]
    fn kimi_vision_only_k2_5() {
        for id in all_kimi_model_ids() {
            let m = get_kimi_model(id).unwrap();
            if id == "kimi-k2.5" {
                assert!(m.supports_images, "{id} should support images");
            } else {
                assert!(!m.supports_images, "{id} should not support images");
            }
        }
    }

    #[test]
    fn kimi_thinking_support() {
        let thinking_models = ["kimi-k2.5", "kimi-k2-thinking", "kimi-k2-thinking-turbo"];
        for id in all_kimi_model_ids() {
            let m = get_kimi_model(id).unwrap();
            if thinking_models.contains(&id) {
                assert!(m.supports_thinking, "{id} should support thinking");
            } else {
                assert!(!m.supports_thinking, "{id} should not support thinking");
            }
        }
    }

    #[test]
    fn kimi_tool_support() {
        for id in all_kimi_model_ids() {
            let m = get_kimi_model(id).unwrap();
            if id.starts_with("kimi-") {
                assert!(m.supports_capabilities, "{id} should support tools");
            } else {
                assert!(!m.supports_capabilities, "{id} should not support tools");
            }
        }
    }

    #[test]
    fn kimi_retired_generation_flag() {
        for id in all_kimi_model_ids() {
            let m = get_kimi_model(id).unwrap();
            if id.starts_with("moonshot-") {
                assert!(m.is_retired_generation, "{id} should be retired-generation");
            } else {
                assert!(
                    !m.is_retired_generation,
                    "{id} should not be retired-generation"
                );
            }
        }
    }

    #[test]
    fn kimi_pricing() {
        let m = get_kimi_model("kimi-k2.5").unwrap();
        assert!((m.input_cost_per_million - 0.60).abs() < f64::EPSILON);
        assert!((m.output_cost_per_million - 3.00).abs() < f64::EPSILON);
        assert!((m.cache_read_cost_per_million.unwrap() - 0.10).abs() < f64::EPSILON);

        let m = get_kimi_model("moonshot-v1-8k").unwrap();
        assert!((m.input_cost_per_million - 0.20).abs() < f64::EPSILON);
        assert!((m.output_cost_per_million - 2.00).abs() < f64::EPSILON);
        assert!(m.cache_read_cost_per_million.is_none());
    }

    #[test]
    fn kimi_cache_read_pricing() {
        for id in all_kimi_model_ids() {
            let m = get_kimi_model(id).unwrap();
            if id.starts_with("kimi-") {
                assert!(
                    m.cache_read_cost_per_million.is_some(),
                    "{id} should have cache pricing"
                );
            } else {
                assert!(
                    m.cache_read_cost_per_million.is_none(),
                    "{id} should not have cache pricing"
                );
            }
        }
    }

    #[test]
    fn to_api_json_k2_5() {
        let m = get_kimi_model("kimi-k2.5").unwrap();
        let j = m.to_api_json("kimi-k2.5");
        assert_eq!(j["id"], "kimi-k2.5");
        assert_eq!(j["name"], "Kimi K2.5");
        assert_eq!(j["provider"], "kimi");
        assert_eq!(j["contextWindow"], 262_144);
        assert_eq!(j["maxOutput"], 32_768);
        assert_eq!(j["supportsThinking"], true);
        assert_eq!(j["supportsImages"], true);
        assert_eq!(j["tier"], "flagship");
        assert_eq!(j["family"], "Kimi K2");
        assert!(j["description"].is_string());
        assert_eq!(j["supportsReasoning"], false);
        assert_eq!(j["recommended"], true);
        assert_eq!(j["isLegacy"], false);
        assert_eq!(j["sortOrder"], 0);
    }

    #[test]
    fn to_api_json_retired_tier() {
        let m = get_kimi_model("moonshot-v1-8k").unwrap();
        let j = m.to_api_json("moonshot-v1-8k");
        assert_eq!(j["tier"], "retired");
        assert_eq!(j["isLegacy"], true);
    }

    #[test]
    fn all_kimi_models_api_json_sorted() {
        let models = all_kimi_models_api_json();
        assert_eq!(models.len(), 9);
        assert_eq!(models[0]["id"], "kimi-k2.5");
        assert_eq!(models[0]["sortOrder"], 0);
        assert_eq!(models[8]["id"], "moonshot-v1-128k");
        assert_eq!(models[8]["sortOrder"], 8);
    }
}
