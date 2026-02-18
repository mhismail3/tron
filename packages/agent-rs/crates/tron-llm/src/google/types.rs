//! Gemini API types, model registry, and configuration.
//!
//! Defines all types needed for the Google/Gemini provider:
//! - Safety settings (harm categories, thresholds)
//! - Authentication (OAuth with endpoint variants, API key)
//! - Provider configuration
//! - Gemini API request/response types
//! - Model registry with thinking support metadata

use std::collections::HashMap;
use std::sync::LazyLock;

use serde::{Deserialize, Serialize};

// ─────────────────────────────────────────────────────────────────────────────
// Thinking types
// ─────────────────────────────────────────────────────────────────────────────

/// Discrete thinking levels for Gemini 3 models.
///
/// Gemini 3 uses discrete levels; Gemini 2.5 uses numeric `thinking_budget`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum GeminiThinkingLevel {
    /// Minimal thinking.
    Minimal,
    /// Low thinking.
    Low,
    /// Medium thinking.
    Medium,
    /// High thinking.
    High,
}

impl GeminiThinkingLevel {
    /// Convert to the uppercase string format the Gemini API expects.
    #[must_use]
    pub fn to_api_string(&self) -> &'static str {
        match self {
            Self::Minimal => "MINIMAL",
            Self::Low => "LOW",
            Self::Medium => "MEDIUM",
            Self::High => "HIGH",
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Safety types
// ─────────────────────────────────────────────────────────────────────────────

/// Harm categories for safety settings.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum HarmCategory {
    /// Harassment content.
    #[serde(rename = "HARM_CATEGORY_HARASSMENT")]
    Harassment,
    /// Hate speech content.
    #[serde(rename = "HARM_CATEGORY_HATE_SPEECH")]
    HateSpeech,
    /// Sexually explicit content.
    #[serde(rename = "HARM_CATEGORY_SEXUALLY_EXPLICIT")]
    SexuallyExplicit,
    /// Dangerous content.
    #[serde(rename = "HARM_CATEGORY_DANGEROUS_CONTENT")]
    DangerousContent,
    /// Civic integrity content.
    #[serde(rename = "HARM_CATEGORY_CIVIC_INTEGRITY")]
    CivicIntegrity,
}

/// Threshold for blocking harmful content.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum HarmBlockThreshold {
    /// Don't block any content.
    #[serde(rename = "BLOCK_NONE")]
    BlockNone,
    /// Only block high-probability harm.
    #[serde(rename = "BLOCK_ONLY_HIGH")]
    BlockOnlyHigh,
    /// Block medium and above probability.
    #[serde(rename = "BLOCK_MEDIUM_AND_ABOVE")]
    BlockMediumAndAbove,
    /// Block low and above probability.
    #[serde(rename = "BLOCK_LOW_AND_ABOVE")]
    BlockLowAndAbove,
    /// Turn off safety filter entirely.
    #[serde(rename = "OFF")]
    Off,
}

/// Probability rating from API safety response.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum HarmProbability {
    /// Negligible probability.
    #[serde(rename = "NEGLIGIBLE")]
    Negligible,
    /// Low probability.
    #[serde(rename = "LOW")]
    Low,
    /// Medium probability.
    #[serde(rename = "MEDIUM")]
    Medium,
    /// High probability.
    #[serde(rename = "HIGH")]
    High,
}

/// Safety rating returned by the API.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SafetyRating {
    /// The harm category.
    pub category: HarmCategory,
    /// The probability level.
    pub probability: HarmProbability,
}

/// Safety setting for a specific harm category.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SafetySetting {
    /// The harm category.
    pub category: HarmCategory,
    /// The block threshold.
    pub threshold: HarmBlockThreshold,
}

/// Default safety settings for agentic use (all categories OFF).
pub fn default_safety_settings() -> Vec<SafetySetting> {
    vec![
        SafetySetting {
            category: HarmCategory::Harassment,
            threshold: HarmBlockThreshold::Off,
        },
        SafetySetting {
            category: HarmCategory::HateSpeech,
            threshold: HarmBlockThreshold::Off,
        },
        SafetySetting {
            category: HarmCategory::SexuallyExplicit,
            threshold: HarmBlockThreshold::Off,
        },
        SafetySetting {
            category: HarmCategory::DangerousContent,
            threshold: HarmBlockThreshold::Off,
        },
        SafetySetting {
            category: HarmCategory::CivicIntegrity,
            threshold: HarmBlockThreshold::Off,
        },
    ]
}

// ─────────────────────────────────────────────────────────────────────────────
// Authentication types
// ─────────────────────────────────────────────────────────────────────────────

/// OAuth endpoint variants for Google authentication.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum GoogleOAuthEndpoint {
    /// Cloud Code Assist (production).
    #[default]
    CloudCodeAssist,
    /// Antigravity (sandbox/experimental).
    Antigravity,
}

/// Google provider authentication.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum GoogleAuth {
    /// OAuth authentication (preferred).
    Oauth {
        /// OAuth tokens.
        #[serde(flatten)]
        tokens: crate::auth::OAuthTokens,
        /// Which OAuth endpoint was used.
        #[serde(default)]
        endpoint: GoogleOAuthEndpoint,
        /// Project ID for `x-goog-user-project` header (Cloud Code Assist).
        #[serde(skip_serializing_if = "Option::is_none")]
        project_id: Option<String>,
    },
    /// API key authentication (fallback).
    ApiKey {
        /// The API key.
        api_key: String,
    },
}

// ─────────────────────────────────────────────────────────────────────────────
// Configuration
// ─────────────────────────────────────────────────────────────────────────────

/// Google provider configuration.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GoogleConfig {
    /// Model ID (e.g., `gemini-3-pro-preview`).
    pub model: String,
    /// Authentication.
    pub auth: GoogleAuth,
    /// Max output tokens override.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_tokens: Option<u32>,
    /// Temperature override.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub temperature: Option<f64>,
    /// Base URL override (only used with API key auth).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub base_url: Option<String>,
    /// Thinking level for Gemini 3 models.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thinking_level: Option<GeminiThinkingLevel>,
    /// Thinking budget in tokens for Gemini 2.5 models (0-32768).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thinking_budget: Option<u32>,
    /// Custom safety settings (defaults to OFF for agentic use).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub safety_settings: Option<Vec<SafetySetting>>,
    /// OAuth API settings for token refresh.
    #[serde(default)]
    pub provider_settings: GoogleApiSettings,
}

// ─────────────────────────────────────────────────────────────────────────────
// Gemini API types
// ─────────────────────────────────────────────────────────────────────────────

/// Content message in Gemini API format.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct GeminiContent {
    /// The role (`user` or `model`).
    pub role: String,
    /// Content parts.
    pub parts: Vec<GeminiPart>,
}

/// A content part in a Gemini message.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(untagged)]
pub enum GeminiPart {
    /// Text content (possibly with thinking metadata).
    Text {
        /// The text content.
        text: String,
        /// Whether this is a thinking/reasoning block.
        #[serde(skip_serializing_if = "Option::is_none")]
        thought: Option<bool>,
        /// Thought signature for multi-turn consistency (Gemini 3).
        #[serde(rename = "thoughtSignature", skip_serializing_if = "Option::is_none")]
        thought_signature: Option<String>,
    },
    /// Function call from the model.
    FunctionCall {
        /// The function call details.
        #[serde(rename = "functionCall")]
        function_call: FunctionCallData,
        /// Thought signature at part level (Gemini 3).
        #[serde(rename = "thoughtSignature", skip_serializing_if = "Option::is_none")]
        thought_signature: Option<String>,
    },
    /// Function response (tool result).
    FunctionResponse {
        /// The function response details.
        #[serde(rename = "functionResponse")]
        function_response: FunctionResponseData,
    },
    /// Inline binary data (images, PDFs).
    InlineData {
        /// The inline data details.
        #[serde(rename = "inlineData")]
        inline_data: InlineDataContent,
    },
}

/// Function call details.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct FunctionCallData {
    /// Function name.
    pub name: String,
    /// Function arguments.
    pub args: serde_json::Value,
}

/// Function response details.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct FunctionResponseData {
    /// Function name.
    pub name: String,
    /// Response data.
    pub response: serde_json::Value,
}

/// Inline binary data.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InlineDataContent {
    /// MIME type (e.g., `image/png`, `application/pdf`).
    pub mime_type: String,
    /// Base64-encoded data.
    pub data: String,
}

/// Tool definition for the Gemini API.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GeminiTool {
    /// Function declarations.
    pub function_declarations: Vec<FunctionDeclaration>,
}

/// A single function declaration.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct FunctionDeclaration {
    /// Function name.
    pub name: String,
    /// Function description.
    pub description: String,
    /// Parameter schema.
    pub parameters: serde_json::Value,
}

/// System instruction for the Gemini API.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SystemInstruction {
    /// Parts containing the system prompt.
    pub parts: Vec<SystemPart>,
}

/// A part of a system instruction.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SystemPart {
    /// Text content.
    pub text: String,
}

/// Thinking configuration for the Gemini API.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThinkingConfig {
    /// Thinking level for Gemini 3 (uppercase: `MINIMAL`, `LOW`, `MEDIUM`, `HIGH`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thinking_level: Option<String>,
    /// Thinking budget in tokens for Gemini 2.5 (0-32768).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thinking_budget: Option<u32>,
    /// Whether to include thoughts in the response.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub include_thoughts: Option<bool>,
}

/// Generation config for the Gemini API.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GenerationConfig {
    /// Max output tokens.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_output_tokens: Option<u32>,
    /// Temperature.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub temperature: Option<f64>,
    /// Top-P sampling.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub top_p: Option<f64>,
    /// Top-K sampling.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub top_k: Option<u32>,
    /// Stop sequences.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stop_sequences: Option<Vec<String>>,
}

/// Streaming response chunk from the Gemini API.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GeminiStreamChunk {
    /// Response candidates.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub candidates: Option<Vec<GeminiCandidate>>,
    /// Token usage metadata.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub usage_metadata: Option<UsageMetadata>,
    /// Error (if any).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<GeminiApiError>,
}

/// A response candidate.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GeminiCandidate {
    /// The content of this candidate.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content: Option<GeminiCandidateContent>,
    /// Finish reason (e.g., `STOP`, `MAX_TOKENS`, `SAFETY`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub finish_reason: Option<String>,
    /// Safety ratings.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub safety_ratings: Option<Vec<SafetyRating>>,
}

/// Content inside a candidate.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct GeminiCandidateContent {
    /// Content parts.
    #[serde(default)]
    pub parts: Vec<GeminiPart>,
    /// The role.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
}

/// Token usage metadata.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageMetadata {
    /// Prompt (input) token count.
    #[serde(default)]
    pub prompt_token_count: u32,
    /// Candidates (output) token count.
    #[serde(default)]
    pub candidates_token_count: u32,
    /// Total token count.
    #[serde(default)]
    pub total_token_count: u32,
}

/// API error in streaming response.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct GeminiApiError {
    /// Error code.
    pub code: i32,
    /// Error message.
    pub message: String,
}

// ─────────────────────────────────────────────────────────────────────────────
// Model registry
// ─────────────────────────────────────────────────────────────────────────────

/// Information about a Gemini model.
#[derive(Clone, Debug)]
pub struct GeminiModelInfo {
    /// Human-readable name.
    pub name: &'static str,
    /// Short display name.
    pub short_name: &'static str,
    /// Context window size in tokens.
    pub context_window: u32,
    /// Maximum output tokens.
    pub max_output: u32,
    /// Whether the model supports tool use.
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
    /// Input cost per 1K tokens.
    pub input_cost_per_1k: f64,
    /// Output cost per 1K tokens.
    pub output_cost_per_1k: f64,
}

/// Model registry mapping model IDs to their metadata.
#[allow(unused_results)]
pub static GEMINI_MODELS: LazyLock<HashMap<&'static str, GeminiModelInfo>> = LazyLock::new(|| {
    let mut m = HashMap::new();
    m.insert(
        "gemini-3-pro-preview",
        GeminiModelInfo {
            name: "Gemini 3 Pro (Preview)",
            short_name: "Gemini 3 Pro",
            context_window: 1_048_576,
            max_output: 65_536,
            supports_tools: true,
            supports_images: true,
            supports_thinking: true,
            tier: "pro",
            preview: true,
            default_thinking_level: Some(GeminiThinkingLevel::High),
            input_cost_per_1k: 0.001_25,
            output_cost_per_1k: 0.005,
        },
    );
    m.insert(
        "gemini-3-flash-preview",
        GeminiModelInfo {
            name: "Gemini 3 Flash (Preview)",
            short_name: "Gemini 3 Flash",
            context_window: 1_048_576,
            max_output: 65_536,
            supports_tools: true,
            supports_images: true,
            supports_thinking: false,
            tier: "flash",
            preview: true,
            default_thinking_level: None,
            input_cost_per_1k: 0.000_075,
            output_cost_per_1k: 0.000_3,
        },
    );
    m.insert(
        "gemini-2.5-pro",
        GeminiModelInfo {
            name: "Gemini 2.5 Pro",
            short_name: "Gemini 2.5 Pro",
            context_window: 2_097_152,
            max_output: 16_384,
            supports_tools: true,
            supports_images: true,
            supports_thinking: true,
            tier: "pro",
            preview: false,
            default_thinking_level: Some(GeminiThinkingLevel::High),
            input_cost_per_1k: 0.001_25,
            output_cost_per_1k: 0.005,
        },
    );
    m.insert(
        "gemini-2.5-flash",
        GeminiModelInfo {
            name: "Gemini 2.5 Flash",
            short_name: "Gemini 2.5 Flash",
            context_window: 1_048_576,
            max_output: 16_384,
            supports_tools: true,
            supports_images: true,
            supports_thinking: true,
            tier: "flash",
            preview: false,
            default_thinking_level: Some(GeminiThinkingLevel::Low),
            input_cost_per_1k: 0.000_075,
            output_cost_per_1k: 0.000_3,
        },
    );
    m.insert(
        "gemini-2.5-flash-lite",
        GeminiModelInfo {
            name: "Gemini 2.5 Flash Lite",
            short_name: "Gemini 2.5 Flash Lite",
            context_window: 1_048_576,
            max_output: 8_192,
            supports_tools: true,
            supports_images: true,
            supports_thinking: false,
            tier: "flash-lite",
            preview: false,
            default_thinking_level: None,
            input_cost_per_1k: 0.000_037_5,
            output_cost_per_1k: 0.000_15,
        },
    );
    m
});

/// Look up a Gemini model by ID.
#[must_use]
pub fn get_gemini_model(model_id: &str) -> Option<&'static GeminiModelInfo> {
    GEMINI_MODELS.get(model_id)
}

/// Get all known model IDs.
#[must_use]
pub fn all_gemini_model_ids() -> Vec<&'static str> {
    GEMINI_MODELS.keys().copied().collect()
}

/// Check if a model ID is a Gemini 3 model (uses `thinkingLevel` instead of `thinkingBudget`).
#[must_use]
pub fn is_gemini_3_model(model: &str) -> bool {
    model.contains("gemini-3")
}

/// Default API base URL for API key authentication.
pub const DEFAULT_API_KEY_BASE_URL: &str = "https://generativelanguage.googleapis.com/v1beta";

/// Cloud Code Assist API endpoint.
pub const CLOUD_CODE_ASSIST_ENDPOINT: &str = "https://cloudcode-pa.googleapis.com";

/// Cloud Code Assist API version.
pub const CLOUD_CODE_ASSIST_VERSION: &str = "v1internal";

/// Antigravity API endpoint.
pub const ANTIGRAVITY_ENDPOINT: &str = "https://daily-cloudcode-pa.sandbox.googleapis.com";

/// Antigravity API version.
pub const ANTIGRAVITY_VERSION: &str = "v1internal";

/// Maximum tool result content length before truncation.
pub const TOOL_RESULT_MAX_LENGTH: usize = 16_384;

/// Default max output tokens when model info is not available.
pub const DEFAULT_MAX_OUTPUT_TOKENS: u32 = 4096;

/// Settings for Google OAuth token refresh.
///
/// These come from `GoogleProviderAuth` in auth storage and are needed
/// to refresh expired OAuth tokens.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GoogleApiSettings {
    /// Custom token URL (defaults to Google's standard OAuth URL).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub token_url: Option<String>,
    /// OAuth client ID (required for token refresh).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub client_id: Option<String>,
    /// OAuth client secret (required for token refresh).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub client_secret: Option<String>,
}

/// Map standard Gemini model names to Antigravity endpoint model names.
#[must_use]
pub fn map_to_antigravity_model(model: &str) -> &str {
    match model {
        "gemini-3-pro-preview" => "gemini-3-pro-high",
        "gemini-3-flash-preview" => "gemini-3-pro-low",
        _ => model,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
#[allow(unused_results)]
mod tests {
    use super::*;

    // ── Thinking level ───────────────────────────────────────────────

    #[test]
    fn thinking_level_serde_roundtrip() {
        for (level, expected) in [
            (GeminiThinkingLevel::Minimal, "\"minimal\""),
            (GeminiThinkingLevel::Low, "\"low\""),
            (GeminiThinkingLevel::Medium, "\"medium\""),
            (GeminiThinkingLevel::High, "\"high\""),
        ] {
            let json = serde_json::to_string(&level).unwrap();
            assert_eq!(json, expected);
            let back: GeminiThinkingLevel = serde_json::from_str(&json).unwrap();
            assert_eq!(back, level);
        }
    }

    #[test]
    fn thinking_level_to_api_string() {
        assert_eq!(GeminiThinkingLevel::Minimal.to_api_string(), "MINIMAL");
        assert_eq!(GeminiThinkingLevel::Low.to_api_string(), "LOW");
        assert_eq!(GeminiThinkingLevel::Medium.to_api_string(), "MEDIUM");
        assert_eq!(GeminiThinkingLevel::High.to_api_string(), "HIGH");
    }

    // ── Safety types ─────────────────────────────────────────────────

    #[test]
    fn harm_category_serde() {
        let cat = HarmCategory::Harassment;
        let json = serde_json::to_string(&cat).unwrap();
        assert_eq!(json, "\"HARM_CATEGORY_HARASSMENT\"");
        let back: HarmCategory = serde_json::from_str(&json).unwrap();
        assert_eq!(back, cat);
    }

    #[test]
    fn safety_setting_serde() {
        let setting = SafetySetting {
            category: HarmCategory::HateSpeech,
            threshold: HarmBlockThreshold::Off,
        };
        let json = serde_json::to_value(&setting).unwrap();
        assert_eq!(json["category"], "HARM_CATEGORY_HATE_SPEECH");
        assert_eq!(json["threshold"], "OFF");
    }

    #[test]
    fn default_safety_settings_has_all_categories() {
        let settings = default_safety_settings();
        assert_eq!(settings.len(), 5);
        assert!(
            settings
                .iter()
                .all(|s| s.threshold == HarmBlockThreshold::Off)
        );
    }

    // ── Auth types ───────────────────────────────────────────────────

    #[test]
    fn auth_oauth_serde() {
        let auth = GoogleAuth::Oauth {
            tokens: crate::auth::OAuthTokens {
                access_token: "at".into(),
                refresh_token: "rt".into(),
                expires_at: 99999,
            },
            endpoint: GoogleOAuthEndpoint::CloudCodeAssist,
            project_id: Some("proj-123".into()),
        };
        let json = serde_json::to_value(&auth).unwrap();
        assert_eq!(json["type"], "oauth");
        assert_eq!(json["accessToken"], "at");
        assert_eq!(json["endpoint"], "cloud-code-assist");
        assert_eq!(json["project_id"], "proj-123");
    }

    #[test]
    fn auth_api_key_serde() {
        let auth = GoogleAuth::ApiKey {
            api_key: "key-123".into(),
        };
        let json = serde_json::to_value(&auth).unwrap();
        assert_eq!(json["type"], "api_key");
        assert_eq!(json["api_key"], "key-123");
    }

    #[test]
    fn oauth_endpoint_default() {
        assert_eq!(
            GoogleOAuthEndpoint::default(),
            GoogleOAuthEndpoint::CloudCodeAssist
        );
    }

    // ── Config ───────────────────────────────────────────────────────

    #[test]
    fn config_serde() {
        let config = GoogleConfig {
            model: "gemini-3-pro-preview".into(),
            auth: GoogleAuth::Oauth {
                tokens: crate::auth::OAuthTokens {
                    access_token: "at".into(),
                    refresh_token: "rt".into(),
                    expires_at: 99999,
                },
                endpoint: GoogleOAuthEndpoint::CloudCodeAssist,
                project_id: None,
            },
            max_tokens: Some(4096),
            temperature: None,
            base_url: None,
            thinking_level: Some(GeminiThinkingLevel::High),
            thinking_budget: None,
            safety_settings: None,
            provider_settings: GoogleApiSettings::default(),
        };
        let json = serde_json::to_value(&config).unwrap();
        assert_eq!(json["model"], "gemini-3-pro-preview");
        assert_eq!(json["maxTokens"], 4096);
        assert_eq!(json["thinkingLevel"], "high");
    }

    // ── Gemini API types ─────────────────────────────────────────────

    #[test]
    fn gemini_part_text_serde() {
        let part = GeminiPart::Text {
            text: "hello".into(),
            thought: None,
            thought_signature: None,
        };
        let json = serde_json::to_value(&part).unwrap();
        assert_eq!(json["text"], "hello");
        assert!(json.get("thought").is_none());
    }

    #[test]
    fn gemini_part_text_with_thinking() {
        let part = GeminiPart::Text {
            text: "thinking...".into(),
            thought: Some(true),
            thought_signature: Some("sig-abc".into()),
        };
        let json = serde_json::to_value(&part).unwrap();
        assert_eq!(json["thought"], true);
        assert_eq!(json["thoughtSignature"], "sig-abc");
    }

    #[test]
    fn gemini_part_function_call_serde() {
        let part = GeminiPart::FunctionCall {
            function_call: FunctionCallData {
                name: "bash".into(),
                args: serde_json::json!({"command": "ls"}),
            },
            thought_signature: Some("sig-123".into()),
        };
        let json = serde_json::to_value(&part).unwrap();
        assert_eq!(json["functionCall"]["name"], "bash");
        assert_eq!(json["thoughtSignature"], "sig-123");
    }

    #[test]
    fn gemini_part_function_response_serde() {
        let part = GeminiPart::FunctionResponse {
            function_response: FunctionResponseData {
                name: "tool_result".into(),
                response: serde_json::json!({"result": "ok"}),
            },
        };
        let json = serde_json::to_value(&part).unwrap();
        assert_eq!(json["functionResponse"]["name"], "tool_result");
    }

    #[test]
    fn gemini_part_inline_data_serde() {
        let part = GeminiPart::InlineData {
            inline_data: InlineDataContent {
                mime_type: "image/png".into(),
                data: "base64data".into(),
            },
        };
        let json = serde_json::to_value(&part).unwrap();
        assert_eq!(json["inlineData"]["mimeType"], "image/png");
    }

    #[test]
    fn gemini_tool_serde() {
        let tool = GeminiTool {
            function_declarations: vec![FunctionDeclaration {
                name: "bash".into(),
                description: "Run a command".into(),
                parameters: serde_json::json!({
                    "type": "object",
                    "properties": {"command": {"type": "string"}}
                }),
            }],
        };
        let json = serde_json::to_value(&tool).unwrap();
        assert_eq!(json["functionDeclarations"][0]["name"], "bash");
    }

    #[test]
    fn thinking_config_serde() {
        let config = ThinkingConfig {
            thinking_level: Some("HIGH".into()),
            thinking_budget: None,
            include_thoughts: Some(true),
        };
        let json = serde_json::to_value(&config).unwrap();
        assert_eq!(json["thinkingLevel"], "HIGH");
        assert_eq!(json["includeThoughts"], true);
        assert!(json.get("thinkingBudget").is_none());
    }

    #[test]
    fn stream_chunk_serde() {
        let chunk_json = serde_json::json!({
            "candidates": [{
                "content": {
                    "parts": [{"text": "hello"}],
                    "role": "model"
                },
                "finishReason": "STOP"
            }],
            "usageMetadata": {
                "promptTokenCount": 10,
                "candidatesTokenCount": 5,
                "totalTokenCount": 15
            }
        });
        let chunk: GeminiStreamChunk = serde_json::from_value(chunk_json).unwrap();
        let candidates = chunk.candidates.unwrap();
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].finish_reason.as_deref(), Some("STOP"));
        let usage = chunk.usage_metadata.unwrap();
        assert_eq!(usage.prompt_token_count, 10);
        assert_eq!(usage.candidates_token_count, 5);
    }

    #[test]
    fn stream_chunk_with_error() {
        let chunk_json = serde_json::json!({
            "error": {
                "code": 429,
                "message": "Rate limit exceeded"
            }
        });
        let chunk: GeminiStreamChunk = serde_json::from_value(chunk_json).unwrap();
        let error = chunk.error.unwrap();
        assert_eq!(error.code, 429);
        assert_eq!(error.message, "Rate limit exceeded");
    }

    // ── Model registry ───────────────────────────────────────────────

    #[test]
    fn model_gemini_3_pro() {
        let model = get_gemini_model("gemini-3-pro-preview").unwrap();
        assert_eq!(model.short_name, "Gemini 3 Pro");
        assert_eq!(model.context_window, 1_048_576);
        assert_eq!(model.max_output, 65_536);
        assert!(model.supports_thinking);
        assert_eq!(model.tier, "pro");
        assert!(model.preview);
        assert_eq!(
            model.default_thinking_level,
            Some(GeminiThinkingLevel::High)
        );
    }

    #[test]
    fn model_gemini_25_flash_lite() {
        let model = get_gemini_model("gemini-2.5-flash-lite").unwrap();
        assert!(!model.supports_thinking);
        assert_eq!(model.tier, "flash-lite");
        assert!(model.default_thinking_level.is_none());
    }

    #[test]
    fn model_unknown_returns_none() {
        assert!(get_gemini_model("gpt-4").is_none());
    }

    #[test]
    fn all_model_ids_has_expected() {
        let ids = all_gemini_model_ids();
        assert!(ids.contains(&"gemini-3-pro-preview"));
        assert!(ids.contains(&"gemini-2.5-pro"));
        assert!(ids.contains(&"gemini-2.5-flash-lite"));
        assert_eq!(ids.len(), 5);
    }

    #[test]
    fn is_gemini_3_model_check() {
        assert!(is_gemini_3_model("gemini-3-pro-preview"));
        assert!(is_gemini_3_model("gemini-3-flash-preview"));
        assert!(!is_gemini_3_model("gemini-2.5-pro"));
        assert!(!is_gemini_3_model("gemini-2.5-flash"));
    }

    // ── Generation config ────────────────────────────────────────────

    // ── GoogleApiSettings ───────────────────────────────────────────

    #[test]
    fn api_settings_default() {
        let settings = GoogleApiSettings::default();
        assert!(settings.token_url.is_none());
        assert!(settings.client_id.is_none());
        assert!(settings.client_secret.is_none());
    }

    #[test]
    fn api_settings_serde() {
        let settings = GoogleApiSettings {
            token_url: Some("https://custom.url/token".into()),
            client_id: Some("cid".into()),
            client_secret: Some("csec".into()),
        };
        let json = serde_json::to_value(&settings).unwrap();
        assert_eq!(json["tokenUrl"], "https://custom.url/token");
        assert_eq!(json["clientId"], "cid");
    }

    // ── map_to_antigravity_model ────────────────────────────────────

    #[test]
    fn antigravity_model_mapping() {
        assert_eq!(
            map_to_antigravity_model("gemini-3-pro-preview"),
            "gemini-3-pro-high"
        );
        assert_eq!(
            map_to_antigravity_model("gemini-3-flash-preview"),
            "gemini-3-pro-low"
        );
        assert_eq!(map_to_antigravity_model("gemini-2.5-pro"), "gemini-2.5-pro");
        assert_eq!(
            map_to_antigravity_model("gemini-2.5-flash"),
            "gemini-2.5-flash"
        );
        assert_eq!(map_to_antigravity_model("unknown-model"), "unknown-model");
    }

    // ── Generation config ────────────────────────────────────────────

    #[test]
    fn generation_config_serde_skips_none() {
        let config = GenerationConfig {
            max_output_tokens: Some(4096),
            temperature: None,
            top_p: None,
            top_k: None,
            stop_sequences: None,
        };
        let json = serde_json::to_value(&config).unwrap();
        assert_eq!(json["maxOutputTokens"], 4096);
        assert!(json.get("temperature").is_none());
        assert!(json.get("topP").is_none());
    }
}
