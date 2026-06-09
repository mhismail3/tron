//! Gemini API types and configuration.
//!
//! Defines all types needed for the Google/Gemini provider:
//! - Safety settings (harm categories, thresholds)
//! - Authentication (OAuth with endpoint variants, API key)
//! - Provider configuration
//! - Gemini API request/response types
//! - Re-exported model registry with thinking support metadata

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

/// Google provider authentication.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum GoogleAuth {
    /// OAuth authentication (Bearer token against standard Gemini API).
    Oauth {
        /// OAuth tokens.
        #[serde(flatten)]
        tokens: crate::domains::auth::credentials::OAuthTokens,
        /// Project ID for `x-goog-user-project` header.
        #[serde(skip_serializing_if = "Option::is_none")]
        project_id: Option<String>,
    },
    /// API key authentication.
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
    /// Function response (capability result).
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

/// ModelCapability definition for the Gemini API.
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
    /// Thinking configuration (Gemini 2.5 and 3 thinking-capable models).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thinking_config: Option<ThinkingConfig>,
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
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageMetadata {
    /// Prompt (input) token count.
    #[serde(default)]
    pub prompt_token_count: u32,
    /// Token count for cached prompt content.
    #[serde(default)]
    pub cached_content_token_count: u32,
    /// Candidates (output) token count.
    #[serde(default)]
    pub candidates_token_count: u32,
    /// Token count for tool-use prompt scaffolding.
    #[serde(default)]
    pub tool_use_prompt_token_count: u32,
    /// Thinking token count.
    #[serde(default)]
    pub thoughts_token_count: u32,
    /// Total token count.
    #[serde(default)]
    pub total_token_count: u32,
    /// Modality breakdown for prompt tokens.
    #[serde(default)]
    pub prompt_tokens_details: Vec<ModalityTokenCount>,
    /// Modality breakdown for cached prompt tokens.
    #[serde(default)]
    pub cache_tokens_details: Vec<ModalityTokenCount>,
    /// Modality breakdown for generated candidate tokens.
    #[serde(default)]
    pub candidates_tokens_details: Vec<ModalityTokenCount>,
    /// Modality breakdown for tool-use prompt tokens.
    #[serde(default)]
    pub tool_use_prompt_tokens_details: Vec<ModalityTokenCount>,
}

/// Gemini token count for a modality.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModalityTokenCount {
    /// Modality name.
    #[serde(default)]
    pub modality: String,
    /// Token count for the modality.
    #[serde(default)]
    pub token_count: u32,
}

/// API error in streaming response.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct GeminiApiError {
    /// Error code.
    pub code: i32,
    /// Error message.
    pub message: String,
}

mod models;

pub use models::{
    GEMINI_MODELS, GeminiModelInfo, all_gemini_model_ids, all_gemini_models_api_json,
    get_gemini_model, is_gemini_3_model,
};

/// Default API base URL (used for both API key and OAuth authentication).
pub const DEFAULT_API_KEY_BASE_URL: &str = "https://generativelanguage.googleapis.com/v1beta";

/// Maximum capability result content length before truncation.
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

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests;
