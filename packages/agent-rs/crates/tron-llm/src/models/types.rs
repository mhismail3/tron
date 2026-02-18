//! # Model Types
//!
//! Shared types for the model registry. Each provider has its own model info
//! struct with provider-specific fields, but they all implement [`Into<ModelInfo>`]
//! for unified queries.

use serde::{Deserialize, Serialize};

// Re-export from tron-core as the canonical Provider type.
pub use tron_core::messages::Provider;

/// Backward-compatible alias — use [`Provider`] in new code.
pub type ProviderType = Provider;

/// Model tier classification.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ModelTier {
    /// Anthropic Opus tier.
    Opus,
    /// Anthropic Sonnet tier.
    Sonnet,
    /// Anthropic Haiku tier.
    Haiku,
    /// `OpenAI` flagship tier (o-series).
    Flagship,
    /// `OpenAI` standard tier (gpt-4o).
    Standard,
    /// Google Pro tier.
    Pro,
    /// Google Flash tier.
    Flash,
    /// Google Flash Lite tier.
    FlashLite,
}

impl ModelTier {
    /// String label for this tier.
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Opus => "opus",
            Self::Sonnet => "sonnet",
            Self::Haiku => "haiku",
            Self::Flagship => "flagship",
            Self::Standard => "standard",
            Self::Pro => "pro",
            Self::Flash => "flash",
            Self::FlashLite => "flash-lite",
        }
    }
}

/// Unified model information for cross-provider queries.
///
/// Every provider's model info can be converted into this type
/// for use in the UI model catalog and provider factory.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelInfo {
    /// API model ID (e.g., `"claude-opus-4-6"`).
    pub id: String,
    /// Human-readable display name.
    pub name: String,
    /// Short name for compact display.
    pub short_name: String,
    /// Model family (e.g., `"Claude 4.6"`, `"GPT-5.3"`).
    pub family: String,
    /// Provider that serves this model.
    pub provider: ProviderType,
    /// Performance tier.
    pub tier: ModelTier,
    /// Context window size in tokens.
    pub context_window: u64,
    /// Maximum output tokens.
    pub max_output: u64,
    /// Whether the model supports extended thinking.
    pub supports_thinking: bool,
    /// Whether the model supports reasoning (`OpenAI`).
    pub supports_reasoning: bool,
    /// Whether the model supports tool use.
    pub supports_tools: bool,
    /// Whether the model supports image inputs.
    pub supports_images: bool,
    /// Input cost per million tokens (USD).
    pub input_cost_per_million: f64,
    /// Output cost per million tokens (USD).
    pub output_cost_per_million: f64,
    /// Cache read cost per million tokens (USD), if caching supported.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_read_cost_per_million: Option<f64>,
    /// Model description for UI display.
    pub description: String,
    /// Whether this is the recommended model in its tier.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub recommended: Option<bool>,
    /// Whether this is a legacy model.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub legacy: Option<bool>,
    /// Whether this is a preview model.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub preview: Option<bool>,
    /// Release date (ISO 8601).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub release_date: Option<String>,
}

/// Model capabilities for runtime feature detection.
#[derive(Clone, Debug, Default)]
#[allow(clippy::struct_excessive_bools)]
pub struct ModelCapabilities {
    /// Supports extended thinking (Anthropic).
    pub supports_thinking: bool,
    /// Supports adaptive thinking (Anthropic Opus 4.6).
    pub supports_adaptive_thinking: bool,
    /// Supports effort levels (Anthropic).
    pub supports_effort: bool,
    /// Available effort levels.
    pub effort_levels: Vec<String>,
    /// Default effort level.
    pub default_effort_level: Option<String>,
    /// Supports reasoning (`OpenAI`).
    pub supports_reasoning: bool,
    /// Available reasoning efforts.
    pub reasoning_levels: Vec<String>,
    /// Default reasoning effort.
    pub default_reasoning_level: Option<String>,
    /// Supports Gemini thinking levels (Gemini 3).
    pub supports_thinking_levels: bool,
    /// Available thinking levels (Gemini).
    pub thinking_levels: Vec<String>,
    /// Default thinking level (Gemini).
    pub default_thinking_level: Option<String>,
    /// Supports tool use.
    pub supports_tools: bool,
    /// Supports image inputs.
    pub supports_images: bool,
    /// Maximum output tokens.
    pub max_output: u64,
    /// Context window size.
    pub context_window: u64,
}

/// Grouping of models by category for UI display.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ModelCategory {
    /// Category name (e.g., `"Latest"`, `"Legacy"`).
    pub name: String,
    /// Category description.
    pub description: String,
    /// Models in this category.
    pub models: Vec<ModelInfo>,
}

/// Calculate the cost in USD for a given model and token counts.
#[allow(clippy::cast_precision_loss)]
pub fn calculate_cost(
    input_cost_per_million: f64,
    output_cost_per_million: f64,
    input_tokens: u64,
    output_tokens: u64,
) -> f64 {
    let input_cost = (input_tokens as f64 / 1_000_000.0) * input_cost_per_million;
    let output_cost = (output_tokens as f64 / 1_000_000.0) * output_cost_per_million;
    input_cost + output_cost
}

/// Format a token count for display (e.g., `200000` -> `"200K"`, `1000000` -> `"1M"`).
#[allow(
    clippy::cast_precision_loss,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss
)]
pub fn format_context_window(tokens: u64) -> String {
    if tokens >= 1_000_000 {
        let m = tokens as f64 / 1_000_000.0;
        if (m - m.round()).abs() < f64::EPSILON {
            format!("{}M", m as u64)
        } else {
            format!("{m:.1}M")
        }
    } else if tokens >= 1_000 {
        let k = tokens as f64 / 1_000.0;
        if (k - k.round()).abs() < f64::EPSILON {
            format!("{}K", k as u64)
        } else {
            format!("{k:.1}K")
        }
    } else {
        tokens.to_string()
    }
}

/// Format a cost per million tokens for display (e.g., `3.0` -> `"$3/M"`).
#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
pub fn format_model_pricing(cost_per_million: f64) -> String {
    if (cost_per_million - cost_per_million.round()).abs() < f64::EPSILON {
        format!("${}/M", cost_per_million as u64)
    } else {
        format!("${cost_per_million:.2}/M")
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn provider_type_as_str() {
        assert_eq!(ProviderType::Anthropic.as_str(), "anthropic");
        assert_eq!(ProviderType::OpenAi.as_str(), "openai");
        assert_eq!(ProviderType::Google.as_str(), "google");
    }

    #[test]
    fn provider_type_display() {
        assert_eq!(ProviderType::Anthropic.to_string(), "anthropic");
        assert_eq!(ProviderType::Google.to_string(), "google");
    }

    #[test]
    fn provider_type_from_str() {
        assert_eq!(
            "anthropic".parse::<ProviderType>().unwrap(),
            ProviderType::Anthropic
        );
        assert_eq!(
            "openai".parse::<ProviderType>().unwrap(),
            ProviderType::OpenAi
        );
        assert_eq!(
            "openai-codex".parse::<ProviderType>().unwrap(),
            ProviderType::OpenAiCodex
        );
        assert_eq!(
            "google".parse::<ProviderType>().unwrap(),
            ProviderType::Google
        );
        assert!("nonexistent".parse::<ProviderType>().is_err());
    }

    #[test]
    fn provider_type_serde_roundtrip() {
        let pt = ProviderType::Anthropic;
        let json = serde_json::to_string(&pt).unwrap();
        assert_eq!(json, "\"anthropic\"");
        let back: ProviderType = serde_json::from_str(&json).unwrap();
        assert_eq!(back, pt);
    }

    #[test]
    fn provider_type_minimax_as_str() {
        assert_eq!(ProviderType::MiniMax.as_str(), "minimax");
    }

    #[test]
    fn provider_type_minimax_display() {
        assert_eq!(ProviderType::MiniMax.to_string(), "minimax");
    }

    #[test]
    fn provider_type_minimax_from_str() {
        assert_eq!(
            "minimax".parse::<ProviderType>().unwrap(),
            ProviderType::MiniMax
        );
    }

    #[test]
    fn provider_type_minimax_serde_roundtrip() {
        let pt = ProviderType::MiniMax;
        let json = serde_json::to_string(&pt).unwrap();
        assert_eq!(json, "\"minimax\"");
        let back: ProviderType = serde_json::from_str(&json).unwrap();
        assert_eq!(back, pt);
    }

    #[test]
    fn model_tier_as_str() {
        assert_eq!(ModelTier::Opus.as_str(), "opus");
        assert_eq!(ModelTier::FlashLite.as_str(), "flash-lite");
    }

    #[test]
    fn calculate_cost_basic() {
        // Claude Opus 4.6: $15/M input, $75/M output
        let cost = calculate_cost(15.0, 75.0, 1000, 500);
        let expected = (1000.0 / 1_000_000.0) * 15.0 + (500.0 / 1_000_000.0) * 75.0;
        assert!((cost - expected).abs() < 1e-10);
    }

    #[test]
    fn calculate_cost_zero_tokens() {
        assert!((calculate_cost(15.0, 75.0, 0, 0)).abs() < f64::EPSILON);
    }

    #[test]
    fn format_context_window_thousands() {
        assert_eq!(format_context_window(200_000), "200K");
        assert_eq!(format_context_window(128_000), "128K");
    }

    #[test]
    fn format_context_window_millions() {
        assert_eq!(format_context_window(1_000_000), "1M");
        assert_eq!(format_context_window(2_097_152), "2.1M");
    }

    #[test]
    fn format_context_window_small() {
        assert_eq!(format_context_window(500), "500");
    }

    #[test]
    fn format_model_pricing_whole() {
        assert_eq!(format_model_pricing(15.0), "$15/M");
        assert_eq!(format_model_pricing(3.0), "$3/M");
    }

    #[test]
    fn format_model_pricing_decimal() {
        assert_eq!(format_model_pricing(0.25), "$0.25/M");
        assert_eq!(format_model_pricing(1.50), "$1.50/M");
    }

    #[test]
    fn model_info_serde_roundtrip() {
        let info = ModelInfo {
            id: "claude-opus-4-6".into(),
            name: "Claude Opus 4.6".into(),
            short_name: "Opus 4.6".into(),
            family: "Claude 4.6".into(),
            provider: ProviderType::Anthropic,
            tier: ModelTier::Opus,
            context_window: 200_000,
            max_output: 128_000,
            supports_thinking: true,
            supports_reasoning: false,
            supports_tools: true,
            supports_images: true,
            input_cost_per_million: 15.0,
            output_cost_per_million: 75.0,
            cache_read_cost_per_million: Some(1.5),
            description: "Most capable".into(),
            recommended: Some(true),
            legacy: None,
            preview: None,
            release_date: Some("2025-01-01".into()),
        };
        let json = serde_json::to_string(&info).unwrap();
        let back: ModelInfo = serde_json::from_str(&json).unwrap();
        assert_eq!(back.id, "claude-opus-4-6");
        assert_eq!(back.provider, ProviderType::Anthropic);
        assert_eq!(back.context_window, 200_000);
    }

    #[test]
    fn model_info_skips_none_fields() {
        let info = ModelInfo {
            id: "test".into(),
            name: "Test".into(),
            short_name: "T".into(),
            family: "Test".into(),
            provider: ProviderType::Anthropic,
            tier: ModelTier::Sonnet,
            context_window: 100_000,
            max_output: 8000,
            supports_thinking: false,
            supports_reasoning: false,
            supports_tools: true,
            supports_images: true,
            input_cost_per_million: 3.0,
            output_cost_per_million: 15.0,
            cache_read_cost_per_million: None,
            description: "Test model".into(),
            recommended: None,
            legacy: None,
            preview: None,
            release_date: None,
        };
        let val = serde_json::to_value(&info).unwrap();
        assert!(val.get("cacheReadCostPerMillion").is_none());
        assert!(val.get("recommended").is_none());
        assert!(val.get("legacy").is_none());
    }
}
