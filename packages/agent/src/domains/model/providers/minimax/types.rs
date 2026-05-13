//! `MiniMax` model registry, auth, and config types.
//!
//! `MiniMax` exposes an Anthropic-compatible endpoint. Models: M2.7, M2.5, M2.1, M2
//! (plus highspeed variants). 204,800 context window, no image support.

use std::collections::HashMap;
use std::sync::LazyLock;

use crate::domains::model::providers::models::model_ids::{
    MINIMAX_M2, MINIMAX_M2_1, MINIMAX_M2_1_HIGHSPEED, MINIMAX_M2_5, MINIMAX_M2_5_HIGHSPEED,
    MINIMAX_M2_7, MINIMAX_M2_7_HIGHSPEED,
};
use crate::domains::model::providers::retry::StreamRetryConfig;

/// Default base URL for the `MiniMax` Anthropic-compatible API.
pub const DEFAULT_BASE_URL: &str = "https://api.minimax.io/anthropic";

/// Default max output tokens for `MiniMax` models.
pub const DEFAULT_MAX_OUTPUT_TOKENS: u32 = 16_000;

/// `MiniMax` authentication — API key only (no OAuth).
#[derive(Clone, Debug)]
pub enum MiniMaxAuth {
    /// API key authentication.
    ApiKey {
        /// The `MiniMax` API key.
        api_key: String,
    },
}

/// `MiniMax` provider configuration.
#[derive(Clone, Debug)]
pub struct MiniMaxConfig {
    /// Model ID (e.g., `"MiniMax-M2.5"`).
    pub model: String,
    /// Authentication.
    pub auth: MiniMaxAuth,
    /// Override max tokens.
    pub max_tokens: Option<u32>,
    /// Override base URL.
    pub base_url: Option<String>,
    /// Retry configuration.
    pub retry: Option<StreamRetryConfig>,
}

/// `MiniMax` model information.
#[derive(Clone, Debug)]
pub struct MiniMaxModelInfo {
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
    /// Model description for the client UI.
    pub description: &'static str,
    /// Display sort order within the provider (lower = higher priority).
    pub sort_order: u16,
    /// Whether this model is recommended for new users.
    pub recommended: bool,
    /// Whether this is a retired/older generation model.
    pub is_retired_generation: bool,
}

static MINIMAX_MODELS: LazyLock<HashMap<&'static str, MiniMaxModelInfo>> = LazyLock::new(|| {
    let mut m = HashMap::new();
    let _ = m.insert(
        MINIMAX_M2_7,
        MiniMaxModelInfo {
            id: MINIMAX_M2_7,
            name: "MiniMax M2.7",
            short_name: "M2.7",
            family: "MiniMax M2",
            context_window: 204_800,
            max_output: 128_000,
            supports_thinking: true,
            supports_capabilities: true,
            supports_images: false,
            input_cost_per_million: 0.3,
            output_cost_per_million: 1.2,
            description: "MiniMax M2.7 — latest and most capable MiniMax model.",
            sort_order: 0,
            recommended: true,
            is_retired_generation: false,
        },
    );
    let _ = m.insert(
        MINIMAX_M2_7_HIGHSPEED,
        MiniMaxModelInfo {
            id: MINIMAX_M2_7_HIGHSPEED,
            name: "MiniMax M2.7 Highspeed",
            short_name: "M2.7 HS",
            family: "MiniMax M2",
            context_window: 204_800,
            max_output: 128_000,
            supports_thinking: true,
            supports_capabilities: true,
            supports_images: false,
            input_cost_per_million: 0.3,
            output_cost_per_million: 1.2,
            description: "MiniMax M2.7 Highspeed — optimized for faster inference.",
            sort_order: 1,
            recommended: false,
            is_retired_generation: false,
        },
    );
    let _ = m.insert(
        MINIMAX_M2_5,
        MiniMaxModelInfo {
            id: MINIMAX_M2_5,
            name: "MiniMax M2.5",
            short_name: "M2.5",
            family: "MiniMax M2",
            context_window: 204_800,
            max_output: 128_000,
            supports_thinking: true,
            supports_capabilities: true,
            supports_images: false,
            input_cost_per_million: 0.3,
            output_cost_per_million: 1.2,
            description: "MiniMax M2.5 — capable general-purpose model.",
            sort_order: 2,
            recommended: false,
            is_retired_generation: false,
        },
    );
    let _ = m.insert(
        MINIMAX_M2_5_HIGHSPEED,
        MiniMaxModelInfo {
            id: MINIMAX_M2_5_HIGHSPEED,
            name: "MiniMax M2.5 Highspeed",
            short_name: "M2.5 HS",
            family: "MiniMax M2",
            context_window: 204_800,
            max_output: 128_000,
            supports_thinking: true,
            supports_capabilities: true,
            supports_images: false,
            input_cost_per_million: 0.3,
            output_cost_per_million: 1.2,
            description: "MiniMax M2.5 Highspeed — optimized for faster inference.",
            sort_order: 3,
            recommended: false,
            is_retired_generation: false,
        },
    );
    let _ = m.insert(
        MINIMAX_M2_1,
        MiniMaxModelInfo {
            id: MINIMAX_M2_1,
            name: "MiniMax M2.1",
            short_name: "M2.1",
            family: "MiniMax M2",
            context_window: 204_800,
            max_output: 128_000,
            supports_thinking: true,
            supports_capabilities: true,
            supports_images: false,
            input_cost_per_million: 0.3,
            output_cost_per_million: 1.2,
            description: "MiniMax M2.1 — capable general-purpose model.",
            sort_order: 4,
            recommended: false,
            is_retired_generation: false,
        },
    );
    let _ = m.insert(
        MINIMAX_M2_1_HIGHSPEED,
        MiniMaxModelInfo {
            id: MINIMAX_M2_1_HIGHSPEED,
            name: "MiniMax M2.1 Highspeed",
            short_name: "M2.1 HS",
            family: "MiniMax M2",
            context_window: 204_800,
            max_output: 128_000,
            supports_thinking: true,
            supports_capabilities: true,
            supports_images: false,
            input_cost_per_million: 0.3,
            output_cost_per_million: 1.2,
            description: "MiniMax M2.1 Highspeed — optimized for faster inference.",
            sort_order: 5,
            recommended: false,
            is_retired_generation: false,
        },
    );
    let _ = m.insert(
        MINIMAX_M2,
        MiniMaxModelInfo {
            id: MINIMAX_M2,
            name: "MiniMax M2",
            short_name: "M2",
            family: "MiniMax M2",
            context_window: 204_800,
            max_output: 128_000,
            supports_thinking: true,
            supports_capabilities: true,
            supports_images: false,
            input_cost_per_million: 0.3,
            output_cost_per_million: 1.2,
            description: "MiniMax M2 — foundation model.",
            sort_order: 6,
            recommended: false,
            is_retired_generation: false,
        },
    );
    m
});

/// Look up a `MiniMax` model by ID.
pub fn get_minimax_model(id: &str) -> Option<&'static MiniMaxModelInfo> {
    MINIMAX_MODELS.get(id)
}

/// All known `MiniMax` model IDs.
pub fn all_minimax_model_ids() -> Vec<&'static str> {
    MINIMAX_MODELS.keys().copied().collect()
}

impl MiniMaxModelInfo {
    /// Serialize this model to JSON for the `model.list` API response.
    pub fn to_api_json(&self, id: &str) -> serde_json::Value {
        serde_json::json!({
            "id": id,
            "name": self.name,
            "provider": "minimax",
            "providerDisplayName": "MiniMax",
            "providerSortOrder": 3,
            "contextWindow": self.context_window,
            "maxOutput": self.max_output,
            "supportsThinking": self.supports_thinking,
            "supportsImages": self.supports_images,
            "supportsDocuments": false,
            "inputCostPerMillion": self.input_cost_per_million,
            "outputCostPerMillion": self.output_cost_per_million,
            "tier": "flagship",
            "family": self.family,
            "description": self.description,
            "supportsReasoning": false,
            "recommended": self.recommended,
            "isLegacy": self.is_retired_generation,
            "sortOrder": self.sort_order,
        })
    }
}

/// All `MiniMax` models serialized for the `model.list` API, sorted by `sort_order`.
pub fn all_minimax_models_api_json() -> Vec<serde_json::Value> {
    let mut entries: Vec<_> = MINIMAX_MODELS.iter().collect();
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
    fn get_minimax_model_m2_7() {
        let m = get_minimax_model("MiniMax-M2.7").unwrap();
        assert_eq!(m.name, "MiniMax M2.7");
        assert_eq!(m.context_window, 204_800);
        assert!(m.supports_thinking);
        assert!(!m.supports_images);
        assert!(m.recommended);
    }

    #[test]
    fn get_minimax_model_m2_7_highspeed() {
        let m = get_minimax_model("MiniMax-M2.7-highspeed").unwrap();
        assert_eq!(m.short_name, "M2.7 HS");
        assert_eq!(m.context_window, 204_800);
    }

    #[test]
    fn get_minimax_model_m2_5() {
        let m = get_minimax_model("MiniMax-M2.5").unwrap();
        assert_eq!(m.name, "MiniMax M2.5");
        assert_eq!(m.context_window, 204_800);
        assert!(m.supports_thinking);
        assert!(!m.supports_images);
    }

    #[test]
    fn get_minimax_model_m2_5_highspeed() {
        let m = get_minimax_model("MiniMax-M2.5-highspeed").unwrap();
        assert_eq!(m.short_name, "M2.5 HS");
        assert_eq!(m.context_window, 204_800);
    }

    #[test]
    fn get_minimax_model_m2_1() {
        let m = get_minimax_model("MiniMax-M2.1").unwrap();
        assert_eq!(m.name, "MiniMax M2.1");
        assert_eq!(m.context_window, 204_800);
    }

    #[test]
    fn get_minimax_model_m2_1_highspeed() {
        let m = get_minimax_model("MiniMax-M2.1-highspeed").unwrap();
        assert_eq!(m.short_name, "M2.1 HS");
    }

    #[test]
    fn get_minimax_model_m2() {
        let m = get_minimax_model("MiniMax-M2").unwrap();
        assert_eq!(m.name, "MiniMax M2");
        assert_eq!(m.context_window, 204_800);
    }

    #[test]
    fn get_minimax_model_unknown_returns_none() {
        assert!(get_minimax_model("gpt-5").is_none());
    }

    #[test]
    fn all_minimax_model_ids_contains_expected() {
        let ids = all_minimax_model_ids();
        assert_eq!(ids.len(), 7);
        assert!(ids.contains(&"MiniMax-M2.7"));
        assert!(ids.contains(&"MiniMax-M2.5"));
        assert!(ids.contains(&"MiniMax-M2"));
    }

    #[test]
    fn minimax_no_image_support() {
        for id in all_minimax_model_ids() {
            let m = get_minimax_model(id).unwrap();
            assert!(!m.supports_images, "{id} should not support images");
        }
    }

    #[test]
    fn minimax_thinking_support() {
        for id in all_minimax_model_ids() {
            let m = get_minimax_model(id).unwrap();
            assert!(m.supports_thinking, "{id} should support thinking");
        }
    }

    #[test]
    fn minimax_tool_support() {
        for id in all_minimax_model_ids() {
            let m = get_minimax_model(id).unwrap();
            assert!(m.supports_capabilities, "{id} should support tools");
        }
    }

    #[test]
    fn minimax_pricing() {
        let m = get_minimax_model("MiniMax-M2.5").unwrap();
        assert!((m.input_cost_per_million - 0.3).abs() < f64::EPSILON);
        assert!((m.output_cost_per_million - 1.2).abs() < f64::EPSILON);
    }

    // ── to_api_json ───────────────────────────────────────────────────

    #[test]
    fn to_api_json_m2_5() {
        let m = get_minimax_model("MiniMax-M2.5").unwrap();
        let j = m.to_api_json("MiniMax-M2.5");
        assert_eq!(j["id"], "MiniMax-M2.5");
        assert_eq!(j["name"], "MiniMax M2.5");
        assert_eq!(j["provider"], "minimax");
        assert_eq!(j["contextWindow"], 204_800);
        assert_eq!(j["maxOutput"], 128_000);
        assert_eq!(j["supportsThinking"], true);
        assert_eq!(j["supportsImages"], false);
        assert_eq!(j["tier"], "flagship");
        assert_eq!(j["family"], "MiniMax M2");
        assert!(j["description"].is_string());
        assert_eq!(j["supportsReasoning"], false);
        assert_eq!(j["recommended"], false);
        assert_eq!(j["isLegacy"], false);
        assert_eq!(j["sortOrder"], 2);
    }

    #[test]
    fn all_minimax_models_api_json_sorted() {
        let models = all_minimax_models_api_json();
        assert_eq!(models.len(), 7);
        assert_eq!(models[0]["id"], "MiniMax-M2.7");
        assert_eq!(models[0]["sortOrder"], 0);
        assert_eq!(models[6]["id"], "MiniMax-M2");
        assert_eq!(models[6]["sortOrder"], 6);
    }
}
