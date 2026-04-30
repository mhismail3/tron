//! `OpenAI` provider types, configuration, and model registry.
//!
//! Covers the Responses API types (not legacy Chat Completions).
//! The `OpenAI` provider uses auth-path-specific metadata: ChatGPT OAuth
//! targets the Codex backend, while API keys target the OpenAI Platform API.
//!
//! ## Size note
//!
//! ~50 serde structs/enums mirroring the OpenAI Responses API wire format.
//! These are data definitions, not logic — splitting them across files would
//! scatter a single API schema with no benefit.

use std::collections::HashMap;
use std::sync::LazyLock;

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Default base URL for the `OpenAI` Codex API.
pub const DEFAULT_BASE_URL: &str = "https://chatgpt.com/backend-api";

/// Default base URL for the `OpenAI` Platform API.
pub const DEFAULT_PLATFORM_BASE_URL: &str = "https://api.openai.com";

/// Default model.
pub const DEFAULT_MODEL: &str = "gpt-5.5";

/// Default max output tokens for unknown models.
pub const DEFAULT_MAX_OUTPUT_TOKENS: u32 = 128_000;

/// Maximum length for tool result output strings (16 KB).
///
/// The Codex endpoint has a per-output size limit. Results exceeding this
/// threshold are truncated with a `[truncated]` marker.
pub const TOOL_RESULT_MAX_LENGTH: usize = 16_384;

// ─────────────────────────────────────────────────────────────────────────────
// API Endpoint
// ─────────────────────────────────────────────────────────────────────────────

/// Which `OpenAI` API endpoint a resolved auth path targets.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ApiEndpoint {
    /// `ChatGPT` Codex backend (`chatgpt.com/backend-api/codex/responses`).
    #[default]
    Codex,
    /// Standard Platform API (`api.openai.com/v1/responses`).
    Platform,
}

impl ApiEndpoint {
    /// Default base URL for this endpoint.
    #[must_use]
    pub fn default_base_url(self) -> &'static str {
        match self {
            Self::Codex => DEFAULT_BASE_URL,
            Self::Platform => DEFAULT_PLATFORM_BASE_URL,
        }
    }

    /// URL path suffix for this endpoint.
    #[must_use]
    pub fn path(self) -> &'static str {
        match self {
            Self::Codex => "/codex/responses",
            Self::Platform => "/v1/responses",
        }
    }
}

/// Which `OpenAI` authentication path is active.
///
/// The same model slug can have different context windows, defaults, and
/// availability depending on whether Tron uses a ChatGPT subscription token or
/// a direct Platform API key.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum OpenAIAuthPath {
    /// Direct OpenAI Platform API key.
    PlatformApiKey,
    /// ChatGPT subscription OAuth token via the Codex backend.
    ChatGptCodex,
}

impl OpenAIAuthPath {
    /// Stable wire label for `model.list`.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::PlatformApiKey => "platform-api-key",
            Self::ChatGptCodex => "chatgpt-codex",
        }
    }

    /// Endpoint used by this auth path.
    #[must_use]
    pub fn endpoint(self) -> ApiEndpoint {
        match self {
            Self::PlatformApiKey => ApiEndpoint::Platform,
            Self::ChatGptCodex => ApiEndpoint::Codex,
        }
    }
}

impl From<&OpenAIAuth> for OpenAIAuthPath {
    fn from(auth: &OpenAIAuth) -> Self {
        match auth {
            OpenAIAuth::OAuth { .. } => Self::ChatGptCodex,
            OpenAIAuth::ApiKey { .. } => Self::PlatformApiKey,
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Authentication
// ─────────────────────────────────────────────────────────────────────────────

/// `OpenAI` authentication.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum OpenAIAuth {
    /// OAuth authentication (Codex endpoint).
    #[serde(rename = "oauth")]
    OAuth {
        /// OAuth tokens.
        tokens: crate::llm::auth::OAuthTokens,
    },
    /// API key authentication (Platform endpoint).
    #[serde(rename = "api_key")]
    ApiKey {
        /// API key.
        api_key: String,
    },
}

/// `OpenAI` API settings (optional overrides).
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenAIApiSettings {
    /// Base URL override.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub base_url: Option<String>,
    /// Token URL for OAuth refresh.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub token_url: Option<String>,
    /// OAuth client ID.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub client_id: Option<String>,
    /// Default reasoning effort.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default_reasoning_effort: Option<String>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Configuration
// ─────────────────────────────────────────────────────────────────────────────

/// `OpenAI` provider configuration.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenAIConfig {
    /// Model ID.
    pub model: String,
    /// Authentication.
    pub auth: OpenAIAuth,
    /// Max output tokens override.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_tokens: Option<u32>,
    /// Temperature override.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub temperature: Option<f64>,
    /// Base URL override.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub base_url: Option<String>,
    /// Reasoning effort override.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning_effort: Option<String>,
    /// Provider-specific settings.
    #[serde(default)]
    pub provider_settings: OpenAIApiSettings,
}

// ─────────────────────────────────────────────────────────────────────────────
// Reasoning
// ─────────────────────────────────────────────────────────────────────────────

/// Re-export from `crate::llm::provider` — the canonical definition lives at the shared boundary.
pub use crate::llm::provider::ReasoningEffort;

// ─────────────────────────────────────────────────────────────────────────────
// Model Registry
// ─────────────────────────────────────────────────────────────────────────────

/// Auth-path-specific metadata for an `OpenAI` model.
#[derive(Clone, Debug)]
#[allow(clippy::struct_excessive_bools)]
pub struct OpenAIModelProfile {
    /// Auth path this profile applies to.
    pub auth_path: OpenAIAuthPath,
    /// Which API endpoint this profile uses.
    pub api_endpoint: ApiEndpoint,
    /// Context window size in tokens.
    pub context_window: u64,
    /// Larger context window available through explicit provider opt-in, if known.
    pub max_context_window: Option<u64>,
    /// Maximum output tokens.
    pub max_output: u64,
    /// Whether the model supports tool use.
    pub supports_tools: bool,
    /// Whether the model supports image inputs.
    pub supports_images: bool,
    /// Whether the model supports reasoning.
    pub supports_reasoning: bool,
    /// Whether the model supports tool search (dynamic tool loading).
    pub supports_tool_search: bool,
    /// Whether the model supports computer use.
    pub supports_computer_use: bool,
    /// Whether the model supports text verbosity controls.
    pub supports_verbosity: bool,
    /// Default text verbosity.
    pub default_verbosity: Option<&'static str>,
    /// Supported reasoning effort levels.
    pub reasoning_levels: &'static [&'static str],
    /// Default reasoning effort level.
    pub default_reasoning_level: &'static str,
    /// Input cost per million tokens (USD), where applicable.
    pub input_cost_per_million: f64,
    /// Output cost per million tokens (USD), where applicable.
    pub output_cost_per_million: f64,
    /// Cache read cost per million tokens (USD), where applicable.
    pub cache_read_cost_per_million: Option<f64>,
    /// Whether this profile should be shown in `model.list` for the auth path.
    pub visible: bool,
}

/// Information about an `OpenAI` model.
#[derive(Clone, Debug)]
pub struct OpenAIModelInfo {
    /// Canonical model ID.
    pub id: &'static str,
    /// Display name.
    pub name: &'static str,
    /// Short name.
    pub short_name: &'static str,
    /// Model family (e.g., "GPT-5.3").
    pub family: &'static str,
    /// Model tier.
    pub tier: &'static str,
    /// Model description for the client UI.
    pub description: &'static str,
    /// Hidden aliases and snapshots accepted by the registry.
    pub aliases: &'static [&'static str],
    /// Per-auth-path profiles.
    pub profiles: Vec<OpenAIModelProfile>,
    /// Display sort order within the provider (lower = higher priority).
    pub sort_order: u16,
    /// Whether this model is recommended for new users.
    pub recommended: bool,
    /// Whether this is a legacy/older generation model.
    pub is_legacy: bool,
    /// Whether this model has been retired by the provider. Deprecated models
    /// remain in the registry so existing sessions can still be rendered and
    /// their costs/capabilities resolved, but they are surfaced as unavailable
    /// in the iOS picker via `isDeprecated`.
    pub is_deprecated: bool,
    /// Retirement date (ISO-8601), if deprecated.
    pub deprecation_date: Option<&'static str>,
    /// Replacement model for deprecated aliases.
    pub replacement_model: Option<&'static str>,
    /// Whether this model should be hidden from `model.list`.
    pub is_hidden: bool,
    /// Whether this model is a preview model.
    pub is_preview: bool,
    /// Knowledge cutoff date (ISO-8601), if known.
    pub knowledge_cutoff: Option<&'static str>,
}

const REASONING_NONE_TO_XHIGH: &[&str] = &["none", "low", "medium", "high", "xhigh"];
const REASONING_LOW_TO_XHIGH: &[&str] = &["low", "medium", "high", "xhigh"];
const REASONING_MEDIUM_TO_XHIGH: &[&str] = &["medium", "high", "xhigh"];
const REASONING_LOW_TO_HIGH: &[&str] = &["low", "medium", "high"];

#[allow(clippy::too_many_arguments)]
fn profile(
    auth_path: OpenAIAuthPath,
    context_window: u64,
    max_context_window: Option<u64>,
    max_output: u64,
    supports_images: bool,
    supports_tool_search: bool,
    supports_computer_use: bool,
    supports_verbosity: bool,
    default_verbosity: Option<&'static str>,
    reasoning_levels: &'static [&'static str],
    default_reasoning_level: &'static str,
    input_cost_per_million: f64,
    output_cost_per_million: f64,
    cache_read_cost_per_million: Option<f64>,
    visible: bool,
) -> OpenAIModelProfile {
    OpenAIModelProfile {
        auth_path,
        api_endpoint: auth_path.endpoint(),
        context_window,
        max_context_window,
        max_output,
        supports_tools: true,
        supports_images,
        supports_reasoning: true,
        supports_tool_search,
        supports_computer_use,
        supports_verbosity,
        default_verbosity,
        reasoning_levels,
        default_reasoning_level,
        input_cost_per_million,
        output_cost_per_million,
        cache_read_cost_per_million,
        visible,
    }
}

#[allow(clippy::too_many_arguments)]
fn model(
    id: &'static str,
    name: &'static str,
    short_name: &'static str,
    family: &'static str,
    tier: &'static str,
    description: &'static str,
    aliases: &'static [&'static str],
    profiles: Vec<OpenAIModelProfile>,
    sort_order: u16,
    recommended: bool,
    is_legacy: bool,
    is_deprecated: bool,
    deprecation_date: Option<&'static str>,
    replacement_model: Option<&'static str>,
    is_hidden: bool,
    is_preview: bool,
    knowledge_cutoff: Option<&'static str>,
) -> OpenAIModelInfo {
    OpenAIModelInfo {
        id,
        name,
        short_name,
        family,
        tier,
        description,
        aliases,
        profiles,
        sort_order,
        recommended,
        is_legacy,
        is_deprecated,
        deprecation_date,
        replacement_model,
        is_hidden,
        is_preview,
        knowledge_cutoff,
    }
}

fn gpt_55_platform() -> OpenAIModelProfile {
    profile(
        OpenAIAuthPath::PlatformApiKey,
        1_050_000,
        Some(1_050_000),
        128_000,
        true,
        true,
        true,
        true,
        Some("medium"),
        REASONING_NONE_TO_XHIGH,
        "medium",
        5.0,
        30.0,
        Some(0.50),
        true,
    )
}

fn gpt_55_codex() -> OpenAIModelProfile {
    profile(
        OpenAIAuthPath::ChatGptCodex,
        272_000,
        Some(272_000),
        128_000,
        true,
        false,
        true,
        true,
        Some("low"),
        REASONING_LOW_TO_XHIGH,
        "medium",
        5.0,
        30.0,
        Some(0.50),
        true,
    )
}

fn gpt_54_platform() -> OpenAIModelProfile {
    profile(
        OpenAIAuthPath::PlatformApiKey,
        1_050_000,
        Some(1_050_000),
        128_000,
        true,
        true,
        true,
        true,
        Some("medium"),
        REASONING_NONE_TO_XHIGH,
        "none",
        2.50,
        15.0,
        Some(0.25),
        true,
    )
}

fn gpt_54_codex() -> OpenAIModelProfile {
    profile(
        OpenAIAuthPath::ChatGptCodex,
        272_000,
        Some(1_000_000),
        128_000,
        true,
        false,
        true,
        true,
        Some("low"),
        REASONING_LOW_TO_XHIGH,
        "xhigh",
        2.50,
        15.0,
        Some(0.25),
        true,
    )
}

fn gpt_54_mini_platform() -> OpenAIModelProfile {
    profile(
        OpenAIAuthPath::PlatformApiKey,
        400_000,
        Some(400_000),
        128_000,
        true,
        true,
        true,
        true,
        Some("medium"),
        REASONING_NONE_TO_XHIGH,
        "medium",
        0.75,
        4.50,
        Some(0.075),
        true,
    )
}

fn gpt_54_mini_codex() -> OpenAIModelProfile {
    profile(
        OpenAIAuthPath::ChatGptCodex,
        272_000,
        Some(272_000),
        128_000,
        true,
        false,
        true,
        true,
        Some("medium"),
        REASONING_LOW_TO_XHIGH,
        "medium",
        0.75,
        4.50,
        Some(0.075),
        true,
    )
}

fn gpt_52_platform() -> OpenAIModelProfile {
    profile(
        OpenAIAuthPath::PlatformApiKey,
        400_000,
        Some(400_000),
        128_000,
        true,
        false,
        false,
        true,
        Some("medium"),
        REASONING_NONE_TO_XHIGH,
        "none",
        1.75,
        14.0,
        Some(0.175),
        true,
    )
}

fn gpt_53_codex_platform() -> OpenAIModelProfile {
    profile(
        OpenAIAuthPath::PlatformApiKey,
        400_000,
        Some(400_000),
        128_000,
        true,
        false,
        false,
        true,
        Some("medium"),
        REASONING_LOW_TO_XHIGH,
        "medium",
        1.75,
        14.0,
        Some(0.175),
        true,
    )
}

fn gpt_52_codex() -> OpenAIModelProfile {
    profile(
        OpenAIAuthPath::ChatGptCodex,
        272_000,
        Some(272_000),
        128_000,
        true,
        false,
        false,
        true,
        Some("low"),
        REASONING_LOW_TO_XHIGH,
        "medium",
        1.75,
        14.0,
        Some(0.175),
        true,
    )
}

fn legacy_codex_profile(
    max_output: u64,
    supports_images: bool,
    reasoning_levels: &'static [&'static str],
    default_reasoning_level: &'static str,
    input_cost_per_million: f64,
    output_cost_per_million: f64,
    cache_read_cost_per_million: f64,
    visible: bool,
) -> OpenAIModelProfile {
    profile(
        OpenAIAuthPath::ChatGptCodex,
        272_000,
        Some(272_000),
        max_output,
        supports_images,
        false,
        false,
        true,
        Some("low"),
        reasoning_levels,
        default_reasoning_level,
        input_cost_per_million,
        output_cost_per_million,
        Some(cache_read_cost_per_million),
        visible,
    )
}

/// Static model registry.
// HashMap::insert returns the previous value, intentionally unused during
// one-time static registry construction.
#[allow(unused_results)]
pub static OPENAI_MODELS: LazyLock<HashMap<&'static str, OpenAIModelInfo>> = LazyLock::new(|| {
    let mut m = HashMap::new();

    m.insert(
        "gpt-5.5",
        model(
            "gpt-5.5",
            "GPT-5.5",
            "GPT-5.5",
            "GPT-5.5",
            "flagship",
            "Newest OpenAI frontier model for complex coding, computer use, knowledge work, and research workflows.",
            &["gpt-5.5-2026-04-23"],
            vec![gpt_55_codex(), gpt_55_platform()],
            0,
            true,
            false,
            false,
            None,
            None,
            false,
            false,
            Some("2025-12-01"),
        ),
    );

    m.insert(
        "gpt-5.4",
        model(
            "gpt-5.4",
            "GPT-5.4",
            "GPT-5.4",
            "GPT-5.4",
            "flagship",
            "OpenAI frontier model for professional coding and agentic workflows.",
            &["gpt-5.4-2026-03-05"],
            vec![gpt_54_codex(), gpt_54_platform()],
            2,
            false,
            false,
            false,
            None,
            None,
            false,
            false,
            Some("2025-08-31"),
        ),
    );

    m.insert(
        "gpt-5.4-pro",
        model(
            "gpt-5.4-pro",
            "GPT-5.4 Pro",
            "GPT-5.4 Pro",
            "GPT-5.4",
            "flagship",
            "Higher-compute GPT-5.4 variant for difficult professional work on the Platform API.",
            &["gpt-5.4-pro-2026-03-05"],
            vec![profile(
                OpenAIAuthPath::PlatformApiKey,
                1_050_000,
                Some(1_050_000),
                128_000,
                true,
                true,
                true,
                false,
                None,
                REASONING_MEDIUM_TO_XHIGH,
                "medium",
                30.0,
                180.0,
                None,
                true,
            )],
            3,
            false,
            false,
            false,
            None,
            None,
            false,
            false,
            Some("2025-08-31"),
        ),
    );

    m.insert(
        "gpt-5.4-mini",
        model(
            "gpt-5.4-mini",
            "GPT-5.4 Mini",
            "GPT-5.4 Mini",
            "GPT-5.4",
            "standard",
            "Fast GPT-5.4-class model for responsive coding tasks and subagents.",
            &["gpt-5.4-mini-2026-03-17"],
            vec![gpt_54_mini_codex(), gpt_54_mini_platform()],
            4,
            false,
            false,
            false,
            None,
            None,
            false,
            false,
            Some("2025-08-31"),
        ),
    );

    m.insert(
        "gpt-5.4-nano",
        model(
            "gpt-5.4-nano",
            "GPT-5.4 Nano",
            "GPT-5.4 Nano",
            "GPT-5.4",
            "standard",
            "Lowest-cost GPT-5.4-class model for simple high-volume tasks on the Platform API.",
            &["gpt-5.4-nano-2026-03-17"],
            vec![profile(
                OpenAIAuthPath::PlatformApiKey,
                400_000,
                Some(400_000),
                128_000,
                true,
                false,
                false,
                true,
                Some("medium"),
                REASONING_NONE_TO_XHIGH,
                "medium",
                0.20,
                1.25,
                Some(0.02),
                true,
            )],
            5,
            false,
            false,
            false,
            None,
            None,
            false,
            false,
            Some("2025-08-31"),
        ),
    );

    m.insert(
        "gpt-5.3-codex",
        model(
            "gpt-5.3-codex",
            "GPT-5.3 Codex",
            "GPT-5.3",
            "GPT-5.3",
            "flagship",
            "Agentic coding model for complex software engineering.",
            &[],
            vec![
                legacy_codex_profile(
                    128_000,
                    true,
                    REASONING_LOW_TO_XHIGH,
                    "medium",
                    1.75,
                    14.0,
                    0.175,
                    true,
                ),
                gpt_53_codex_platform(),
            ],
            6,
            false,
            true,
            false,
            None,
            None,
            false,
            false,
            Some("2025-08-31"),
        ),
    );

    m.insert(
        "gpt-5.3-codex-spark",
        model(
            "gpt-5.3-codex-spark",
            "GPT-5.3 Codex Spark",
            "GPT-5.3 Spark",
            "GPT-5.3",
            "standard",
            "Text-only research preview optimized for near-instant coding iteration.",
            &[],
            vec![legacy_codex_profile(
                32_000,
                false,
                REASONING_LOW_TO_HIGH,
                "low",
                1.75,
                14.0,
                0.175,
                false,
            )],
            7,
            false,
            true,
            false,
            None,
            None,
            true,
            true,
            None,
        ),
    );

    m.insert(
        "gpt-5.2",
        model(
            "gpt-5.2",
            "GPT-5.2",
            "GPT-5.2",
            "GPT-5.2",
            "flagship",
            "Previous OpenAI frontier model for professional coding and agentic tasks.",
            &["gpt-5.2-2025-12-11"],
            vec![gpt_52_codex(), gpt_52_platform()],
            10,
            false,
            true,
            false,
            None,
            None,
            false,
            false,
            Some("2025-08-31"),
        ),
    );

    m.insert(
        "gpt-5.2-codex",
        model(
            "gpt-5.2-codex",
            "GPT-5.2 Codex",
            "GPT-5.2",
            "GPT-5.2",
            "flagship",
            "Deprecated GPT-5.2 Codex alias; use gpt-5.2.",
            &[],
            vec![gpt_52_codex()],
            20,
            false,
            true,
            true,
            Some("2026-04-14"),
            Some("gpt-5.2"),
            true,
            false,
            None,
        ),
    );

    m.insert(
        "gpt-5.1-codex-max",
        model(
            "gpt-5.1-codex-max",
            "GPT-5.1 Codex Max",
            "GPT-5.1 Max",
            "GPT-5.1",
            "flagship",
            "Deprecated deep-reasoning Codex model; use gpt-5.2 or newer.",
            &[],
            vec![legacy_codex_profile(
                128_000,
                true,
                REASONING_LOW_TO_XHIGH,
                "high",
                1.25,
                10.0,
                0.125,
                true,
            )],
            30,
            false,
            true,
            true,
            Some("2026-04-14"),
            Some("gpt-5.2"),
            true,
            false,
            None,
        ),
    );

    m.insert(
        "gpt-5.1-codex-mini",
        model(
            "gpt-5.1-codex-mini",
            "GPT-5.1 Codex Mini",
            "GPT-5.1 Mini",
            "GPT-5.1",
            "standard",
            "Deprecated fast Codex model; use gpt-5.4-mini or newer.",
            &[],
            vec![legacy_codex_profile(
                128_000,
                true,
                REASONING_LOW_TO_HIGH,
                "low",
                0.25,
                2.0,
                0.025,
                true,
            )],
            31,
            false,
            true,
            true,
            Some("2026-04-14"),
            Some("gpt-5.4-mini"),
            true,
            false,
            None,
        ),
    );

    m
});

/// Look up model info by ID.
#[must_use]
pub fn get_openai_model(model_id: &str) -> Option<&'static OpenAIModelInfo> {
    let bare = strip_openai_provider_prefix(model_id);
    OPENAI_MODELS.get(bare).or_else(|| {
        OPENAI_MODELS
            .values()
            .find(|info| info.aliases.contains(&bare))
    })
}

/// Get all model IDs.
#[must_use]
pub fn all_openai_model_ids() -> Vec<&'static str> {
    let mut ids: Vec<&'static str> = OPENAI_MODELS.keys().copied().collect();
    for info in OPENAI_MODELS.values() {
        ids.extend(info.aliases.iter().copied());
    }
    ids.sort_unstable();
    ids
}

/// Strip a provider prefix accepted by the shared registry.
#[must_use]
pub fn strip_openai_provider_prefix(model_id: &str) -> &str {
    model_id
        .split_once('/')
        .map_or(model_id, |(_, model)| model)
}

/// Resolve a model ID to its canonical registry ID.
#[must_use]
pub fn canonical_openai_model_id(model_id: &str) -> Option<&'static str> {
    get_openai_model(model_id).map(|info| info.replacement_model.unwrap_or(info.id))
}

/// Resolve the request model ID sent to OpenAI.
///
/// Snapshot aliases are preserved so callers can intentionally pin behavior.
/// Deprecated compatibility IDs with a known replacement are upgraded before
/// the request hits the provider.
#[must_use]
pub fn openai_request_model_id(model_id: &str) -> String {
    let bare = strip_openai_provider_prefix(model_id);
    if let Some(info) = OPENAI_MODELS.get(bare)
        && let Some(replacement) = info.replacement_model
    {
        return replacement.to_string();
    }
    bare.to_string()
}

/// Look up the auth-path-specific profile for a model.
#[must_use]
pub fn get_openai_model_profile(
    model_id: &str,
    auth_path: OpenAIAuthPath,
) -> Option<(&'static OpenAIModelInfo, &'static OpenAIModelProfile)> {
    let info = get_openai_model(model_id)?;
    info.profile_for_auth_path(auth_path)
        .map(|profile| (info, profile))
}

/// Whether a model can be used with the active auth path.
#[must_use]
pub fn openai_model_available_for_auth_path(model_id: &str, auth_path: OpenAIAuthPath) -> bool {
    get_openai_model_profile(model_id, auth_path).is_some()
}

impl OpenAIModelInfo {
    /// Best profile when the caller has no auth-path context.
    ///
    /// Prefer the Codex profile because it is the smaller, subscription-safe
    /// context window. Platform-only models naturally fall back to Platform.
    #[must_use]
    pub fn default_profile(&self) -> &OpenAIModelProfile {
        self.profile_for_auth_path(OpenAIAuthPath::ChatGptCodex)
            .or_else(|| self.profile_for_auth_path(OpenAIAuthPath::PlatformApiKey))
            .or_else(|| self.profiles.first())
            .expect("OpenAI registry entries must have at least one profile")
    }

    /// Profile for an auth path.
    #[must_use]
    pub fn profile_for_auth_path(&self, auth_path: OpenAIAuthPath) -> Option<&OpenAIModelProfile> {
        self.profiles
            .iter()
            .find(|profile| profile.auth_path == auth_path)
    }

    /// Serialize this model to JSON for the `model.list` API response.
    pub fn to_api_json(&self, profile: &OpenAIModelProfile) -> serde_json::Value {
        let mut obj = serde_json::json!({
            "id": self.id,
            "canonicalModelId": self.id,
            "name": self.name,
            "provider": "openai-codex",
            "providerDisplayName": "OpenAI",
            "providerSortOrder": 1,
            "contextWindow": profile.context_window,
            "maxOutput": profile.max_output,
            "supportsThinking": false,
            "supportsImages": profile.supports_images,
            "supportsDocuments": false,
            "inputCostPerMillion": profile.input_cost_per_million,
            "outputCostPerMillion": profile.output_cost_per_million,
            "tier": self.tier,
            "family": self.family,
            "description": self.description,
            "supportsReasoning": profile.supports_reasoning,
            "reasoningLevels": profile.reasoning_levels,
            "defaultReasoningLevel": profile.default_reasoning_level,
            "recommended": self.recommended,
            "isLegacy": self.is_legacy,
            "sortOrder": self.sort_order,
            "apiEndpoint": profile.api_endpoint,
            "authPaths": [profile.auth_path.as_str()],
            "supportsVerbosity": profile.supports_verbosity,
        });
        if let Some(cache_read) = profile.cache_read_cost_per_million {
            let _ = obj.as_object_mut().unwrap().insert(
                "cacheReadCostPerMillion".into(),
                serde_json::json!(cache_read),
            );
        }
        if let Some(max_context) = profile.max_context_window {
            let _ = obj
                .as_object_mut()
                .unwrap()
                .insert("maxContextWindow".into(), serde_json::json!(max_context));
        }
        if let Some(verbosity) = profile.default_verbosity {
            let _ = obj
                .as_object_mut()
                .unwrap()
                .insert("defaultVerbosity".into(), serde_json::json!(verbosity));
        }
        if let Some(cutoff) = self.knowledge_cutoff {
            let _ = obj
                .as_object_mut()
                .unwrap()
                .insert("knowledgeCutoff".into(), serde_json::json!(cutoff));
        }
        if !self.aliases.is_empty() {
            let _ = obj
                .as_object_mut()
                .unwrap()
                .insert("aliasIds".into(), serde_json::json!(self.aliases));
        }
        if self.is_deprecated {
            let _ = obj
                .as_object_mut()
                .unwrap()
                .insert("isDeprecated".into(), serde_json::json!(true));
        }
        if let Some(date) = self.deprecation_date {
            let _ = obj
                .as_object_mut()
                .unwrap()
                .insert("deprecationDate".into(), serde_json::json!(date));
        }
        if let Some(replacement) = self.replacement_model {
            let _ = obj
                .as_object_mut()
                .unwrap()
                .insert("replacementModel".into(), serde_json::json!(replacement));
        }
        if self.is_hidden {
            let _ = obj
                .as_object_mut()
                .unwrap()
                .insert("isHidden".into(), serde_json::json!(true));
        }
        if self.is_preview {
            let _ = obj
                .as_object_mut()
                .unwrap()
                .insert("preview".into(), serde_json::json!(true));
        }
        obj
    }
}

/// All `OpenAI` models serialized for the active auth path, sorted by `sort_order`.
pub fn all_openai_models_api_json_for_auth_path(
    auth_path: OpenAIAuthPath,
) -> Vec<serde_json::Value> {
    let mut entries: Vec<_> = OPENAI_MODELS
        .values()
        .filter_map(|info| {
            let profile = info.profile_for_auth_path(auth_path)?;
            if info.is_hidden || !profile.visible {
                return None;
            }
            Some((info, profile))
        })
        .collect();
    entries.sort_by_key(|(info, _)| info.sort_order);
    entries
        .into_iter()
        .map(|(info, profile)| info.to_api_json(profile))
        .collect()
}

/// All `OpenAI` models serialized with the conservative Codex default.
pub fn all_openai_models_api_json() -> Vec<serde_json::Value> {
    all_openai_models_api_json_for_auth_path(OpenAIAuthPath::ChatGptCodex)
}

// ─────────────────────────────────────────────────────────────────────────────
// Responses API Request Types
// ─────────────────────────────────────────────────────────────────────────────

/// A message content block in the Responses API.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum MessageContent {
    /// Output text (assistant).
    #[serde(rename = "output_text")]
    OutputText {
        /// The text content.
        text: String,
    },
    /// Input text (user).
    #[serde(rename = "input_text")]
    InputText {
        /// The text content.
        text: String,
    },
    /// Input image (user).
    #[serde(rename = "input_image")]
    InputImage {
        /// Base64 data URL.
        image_url: String,
        /// Detail level.
        #[serde(skip_serializing_if = "Option::is_none")]
        detail: Option<String>,
    },
}

/// An input item for the Responses API.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ResponsesInputItem {
    /// Simple text input.
    #[serde(rename = "input_text")]
    InputText {
        /// The text content.
        text: String,
    },
    /// Message with role and content.
    #[serde(rename = "message")]
    Message {
        /// Role: "user", "assistant", or "developer".
        role: String,
        /// Content blocks.
        content: Vec<MessageContent>,
        /// Optional message ID (returned by API, omitted in requests).
        #[serde(skip_serializing_if = "Option::is_none")]
        id: Option<String>,
    },
    /// Function call (tool use by assistant).
    #[serde(rename = "function_call")]
    FunctionCall {
        /// Optional item ID (returned by API, omitted in requests).
        #[serde(skip_serializing_if = "Option::is_none")]
        id: Option<String>,
        /// Call ID.
        call_id: String,
        /// Function name.
        name: String,
        /// JSON-encoded arguments.
        arguments: String,
    },
    /// Function call output (tool result).
    #[serde(rename = "function_call_output")]
    FunctionCallOutput {
        /// Call ID this result corresponds to.
        call_id: String,
        /// Output string.
        output: String,
    },
}

/// Polymorphic tool entry for the Responses API.
///
/// Uses internally tagged serialization on `"type"` to discriminate variants.
/// GPT 5.4+ supports `ToolSearch` and `Computer` entries alongside functions.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ResponsesToolEntry {
    /// Standard function tool.
    #[serde(rename = "function")]
    Function {
        /// Function name.
        name: String,
        /// Function description.
        description: String,
        /// JSON Schema for parameters.
        parameters: Value,
        /// When `true`, the tool is available but not loaded into the prompt
        /// until the model's tool search selects it.
        #[serde(skip_serializing_if = "Option::is_none")]
        defer_loading: Option<bool>,
    },
    /// Tool search sentinel — enables the model to dynamically discover tools.
    #[serde(rename = "tool_search")]
    ToolSearch {},
    /// Computer use tool (stub — full implementation deferred).
    #[serde(rename = "computer")]
    Computer {
        /// Viewport width in pixels.
        #[serde(skip_serializing_if = "Option::is_none")]
        viewport_width: Option<u32>,
        /// Viewport height in pixels.
        #[serde(skip_serializing_if = "Option::is_none")]
        viewport_height: Option<u32>,
    },
}

/// Request body for the Responses API.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ResponsesRequest {
    /// Model ID.
    pub model: String,
    /// Input items.
    pub input: Vec<ResponsesInputItem>,
    /// System instructions.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub instructions: Option<String>,
    /// Whether to stream the response.
    pub stream: bool,
    /// Whether to store the conversation.
    pub store: bool,
    /// Temperature.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub temperature: Option<f64>,
    /// Tool definitions (functions, tool search, computer use).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tools: Option<Vec<ResponsesToolEntry>>,
    /// Max output tokens.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_output_tokens: Option<u32>,
    /// Reasoning configuration.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning: Option<ReasoningConfig>,
    /// Text output configuration.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<ResponseTextConfig>,
}

/// Reasoning configuration for the Responses API.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ReasoningConfig {
    /// Effort level.
    pub effort: String,
    /// Summary format (always "detailed").
    pub summary: String,
}

/// Text output configuration for the Responses API.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ResponseTextConfig {
    /// Verbosity level.
    pub verbosity: String,
}

// ─────────────────────────────────────────────────────────────────────────────
// Responses API SSE Event Types
// ─────────────────────────────────────────────────────────────────────────────

/// An output item from the Responses API.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct ResponsesOutputItem {
    /// Item type: `function_call`, `message`, `reasoning`, etc.
    #[serde(rename = "type")]
    pub item_type: OutputItemType,
    /// Item ID.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    /// Call ID (for `function_call` items).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub call_id: Option<String>,
    /// Function name (for `function_call` items).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// Function arguments (for `function_call` items).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub arguments: Option<String>,
    /// Content blocks (for message items).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content: Option<Vec<OutputContent>>,
    /// Reasoning summary parts.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summary: Option<Vec<OutputContent>>,
}

/// Content block within an output item.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct OutputContent {
    /// Content type.
    #[serde(rename = "type")]
    pub content_type: String,
    /// Text content.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
}

/// Usage information from the Responses API.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct ResponsesUsage {
    /// Input tokens.
    #[serde(default)]
    pub input_tokens: u64,
    /// Output tokens.
    #[serde(default)]
    pub output_tokens: u64,
}

/// Full response object (from `response.completed`).
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ResponsesResponse {
    /// Response ID.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    /// Output items.
    #[serde(default)]
    pub output: Vec<ResponsesOutputItem>,
    /// Usage information.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub usage: Option<ResponsesUsage>,
}

/// A Responses API SSE event.
///
/// Events are parsed from the SSE stream by matching on the `type` field.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct ResponsesSseEvent {
    /// Event type (e.g., [`SseEventType::OutputTextDelta`]).
    #[serde(rename = "type")]
    pub event_type: SseEventType,
    /// Text delta (for text and reasoning summary deltas).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub delta: Option<String>,
    /// Content index.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content_index: Option<u32>,
    /// Summary index (for reasoning summary deltas).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summary_index: Option<u32>,
    /// Output item (for `output_item.added` / `output_item.done`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub item: Option<ResponsesOutputItem>,
    /// Call ID (for `function_call_arguments.delta`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub call_id: Option<String>,
    /// Full response (for `response.completed`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub response: Option<ResponsesResponse>,
}

/// SSE event types from the Responses API.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum SseEventType {
    /// Streaming text content.
    #[serde(rename = "response.output_text.delta")]
    OutputTextDelta,
    /// New output item (tool call or reasoning started).
    #[serde(rename = "response.output_item.added")]
    OutputItemAdded,
    /// Output item finished.
    #[serde(rename = "response.output_item.done")]
    OutputItemDone,
    /// New reasoning summary part added.
    #[serde(rename = "response.reasoning_summary_part.added")]
    ReasoningSummaryPartAdded,
    /// Full reasoning text delta.
    #[serde(rename = "response.reasoning_text.delta")]
    ReasoningTextDelta,
    /// Streaming reasoning summary text.
    #[serde(rename = "response.reasoning_summary_text.delta")]
    ReasoningSummaryTextDelta,
    /// Streaming function call arguments.
    #[serde(rename = "response.function_call_arguments.delta")]
    FunctionCallArgsDelta,
    /// Tool search call started (hosted tool search).
    #[serde(rename = "response.tool_search_call.searching")]
    ToolSearchCallSearching,
    /// Tool search call completed (hosted tool search).
    #[serde(rename = "response.tool_search_call.completed")]
    ToolSearchCallCompleted,
    /// Computer call output (stub).
    #[serde(rename = "response.computer_call.completed")]
    ComputerCallCompleted,
    /// Final complete response.
    #[serde(rename = "response.completed")]
    Completed,
    /// Forward-compatible catch-all for unknown event types.
    #[default]
    #[serde(other)]
    Unknown,
}

/// Output item types from the Responses API.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OutputItemType {
    /// Function call (tool use by assistant).
    FunctionCall,
    /// Message content.
    Message,
    /// Reasoning/thinking.
    Reasoning,
    /// Tool search call (hosted tool discovery).
    ToolSearchCall,
    /// Tool search output (hosted tool discovery result).
    ToolSearchOutput,
    /// Computer call (screenshot + action loop).
    ComputerCall,
    /// Forward-compatible catch-all for unknown item types.
    #[default]
    #[serde(other)]
    Unknown,
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn assert_float_eq(actual: f64, expected: f64) {
        assert!(
            (actual - expected).abs() < f64::EPSILON,
            "expected {expected}, got {actual}"
        );
    }

    // ── Model registry ─────────────────────────────────────────────────

    #[test]
    fn default_model_exists() {
        assert!(get_openai_model(DEFAULT_MODEL).is_some());
    }

    #[test]
    fn gpt_55_has_distinct_platform_and_codex_profiles() {
        let platform = get_openai_model_profile("gpt-5.5", OpenAIAuthPath::PlatformApiKey)
            .unwrap()
            .1;
        let codex = get_openai_model_profile("gpt-5.5", OpenAIAuthPath::ChatGptCodex)
            .unwrap()
            .1;
        assert_eq!(platform.context_window, 1_050_000);
        assert_eq!(codex.context_window, 272_000);
        assert_eq!(platform.max_output, 128_000);
        assert_eq!(codex.max_output, 128_000);
        assert_eq!(
            platform.reasoning_levels,
            &["none", "low", "medium", "high", "xhigh"]
        );
        assert_eq!(codex.reasoning_levels, &["low", "medium", "high", "xhigh"]);
        assert_eq!(platform.default_reasoning_level, "medium");
        assert_eq!(codex.default_reasoning_level, "medium");
        assert_eq!(platform.api_endpoint, ApiEndpoint::Platform);
        assert_eq!(codex.api_endpoint, ApiEndpoint::Codex);
        assert_float_eq(platform.input_cost_per_million, 5.0);
        assert_float_eq(platform.output_cost_per_million, 30.0);
        assert_eq!(platform.cache_read_cost_per_million, Some(0.50));
    }

    #[test]
    fn gpt_55_snapshot_alias_resolves_to_canonical() {
        let m = get_openai_model("openai/gpt-5.5-2026-04-23").unwrap();
        assert_eq!(m.id, "gpt-5.5");
        assert_eq!(
            canonical_openai_model_id("gpt-5.5-2026-04-23"),
            Some("gpt-5.5")
        );
        assert_eq!(
            openai_request_model_id("gpt-5.5-2026-04-23"),
            "gpt-5.5-2026-04-23"
        );
    }

    #[test]
    fn gpt_54_codex_default_differs_from_platform() {
        let platform = get_openai_model_profile("gpt-5.4", OpenAIAuthPath::PlatformApiKey)
            .unwrap()
            .1;
        let codex = get_openai_model_profile("gpt-5.4", OpenAIAuthPath::ChatGptCodex)
            .unwrap()
            .1;
        assert_eq!(platform.context_window, 1_050_000);
        assert_eq!(codex.context_window, 272_000);
        assert_eq!(codex.max_context_window, Some(1_000_000));
        assert_eq!(platform.default_reasoning_level, "none");
        assert_eq!(codex.default_reasoning_level, "xhigh");
        assert!(platform.reasoning_levels.contains(&"none"));
        assert!(!codex.reasoning_levels.contains(&"none"));
    }

    #[test]
    fn gpt_53_codex_has_distinct_platform_and_codex_profiles() {
        let platform = get_openai_model_profile("gpt-5.3-codex", OpenAIAuthPath::PlatformApiKey)
            .unwrap()
            .1;
        let codex = get_openai_model_profile("gpt-5.3-codex", OpenAIAuthPath::ChatGptCodex)
            .unwrap()
            .1;
        assert_eq!(platform.context_window, 400_000);
        assert_eq!(codex.context_window, 272_000);
        assert_eq!(platform.max_output, 128_000);
        assert_eq!(codex.max_output, 128_000);
        assert_eq!(platform.api_endpoint, ApiEndpoint::Platform);
        assert_eq!(codex.api_endpoint, ApiEndpoint::Codex);
    }

    #[test]
    fn platform_only_models_are_unavailable_on_codex_path() {
        assert!(get_openai_model("gpt-5.4-nano").is_some());
        assert!(openai_model_available_for_auth_path(
            "gpt-5.4-nano",
            OpenAIAuthPath::PlatformApiKey
        ));
        assert!(!openai_model_available_for_auth_path(
            "gpt-5.4-nano",
            OpenAIAuthPath::ChatGptCodex
        ));
        assert!(openai_model_available_for_auth_path(
            "gpt-5.4-pro",
            OpenAIAuthPath::PlatformApiKey
        ));
        assert!(!openai_model_available_for_auth_path(
            "gpt-5.4-pro",
            OpenAIAuthPath::ChatGptCodex
        ));
    }

    #[test]
    fn codex_catalog_models_use_272k_context() {
        for id in [
            "gpt-5.5",
            "gpt-5.4",
            "gpt-5.4-mini",
            "gpt-5.3-codex",
            "gpt-5.2",
        ] {
            let profile = get_openai_model_profile(id, OpenAIAuthPath::ChatGptCodex)
                .unwrap_or_else(|| panic!("{id} should have a Codex profile"))
                .1;
            assert_eq!(profile.context_window, 272_000, "{id}");
            assert_eq!(profile.max_output, 128_000, "{id}");
            assert_eq!(
                profile.reasoning_levels,
                &["low", "medium", "high", "xhigh"],
                "{id}"
            );
        }
    }

    #[test]
    fn gpt_54_mini_profiles_match_official_contexts() {
        let platform = get_openai_model_profile("gpt-5.4-mini", OpenAIAuthPath::PlatformApiKey)
            .unwrap()
            .1;
        let codex = get_openai_model_profile("gpt-5.4-mini", OpenAIAuthPath::ChatGptCodex)
            .unwrap()
            .1;
        assert_eq!(platform.context_window, 400_000);
        assert_eq!(codex.context_window, 272_000);
        assert_eq!(platform.default_reasoning_level, "medium");
        assert_eq!(codex.default_reasoning_level, "medium");
        assert_float_eq(platform.input_cost_per_million, 0.75);
        assert_float_eq(platform.output_cost_per_million, 4.5);
        assert_eq!(platform.cache_read_cost_per_million, Some(0.075));
    }

    #[test]
    fn model_gpt_51_codex_mini_compatibility_profile() {
        let m = get_openai_model("gpt-5.1-codex-mini").unwrap();
        let profile = m.default_profile();
        assert_eq!(m.tier, "standard");
        assert_eq!(profile.context_window, 272_000);
        assert_eq!(profile.max_output, 128_000);
        assert_eq!(profile.reasoning_levels, &["low", "medium", "high"]);
        assert_eq!(profile.default_reasoning_level, "low");
        assert_float_eq(profile.input_cost_per_million, 0.25);
        assert_float_eq(profile.output_cost_per_million, 2.0);
        assert_eq!(profile.cache_read_cost_per_million, Some(0.025));
    }

    #[test]
    fn model_gpt_53_codex_spark() {
        let m = get_openai_model("gpt-5.3-codex-spark").unwrap();
        let profile = m.default_profile();
        assert_eq!(profile.context_window, 272_000);
        assert_eq!(profile.max_output, 32_000);
        assert_eq!(m.tier, "standard");
        assert!(m.is_hidden);
        assert!(m.is_preview);
        assert!(!profile.visible);
        assert_eq!(profile.reasoning_levels, &["low", "medium", "high"]);
        assert_eq!(profile.default_reasoning_level, "low");
    }

    #[test]
    fn model_gpt_52_pricing_and_deprecated_alias_mapping() {
        let m = get_openai_model("gpt-5.2").unwrap();
        let profile = m.default_profile();
        assert_float_eq(profile.input_cost_per_million, 1.75);
        assert_float_eq(profile.output_cost_per_million, 14.0);
        assert_eq!(profile.cache_read_cost_per_million, Some(0.175));

        let alias = get_openai_model("gpt-5.2-codex").unwrap();
        assert!(alias.is_deprecated);
        assert!(alias.is_hidden);
        assert_eq!(alias.replacement_model, Some("gpt-5.2"));
        assert_eq!(canonical_openai_model_id("gpt-5.2-codex"), Some("gpt-5.2"));
        assert_eq!(openai_request_model_id("gpt-5.2-codex"), "gpt-5.2");
    }

    #[test]
    fn model_gpt_51_codex_max_pricing() {
        let m = get_openai_model("gpt-5.1-codex-max").unwrap();
        let profile = m.default_profile();
        assert_float_eq(profile.input_cost_per_million, 1.25);
        assert_float_eq(profile.output_cost_per_million, 10.0);
        assert_eq!(profile.cache_read_cost_per_million, Some(0.125));
    }

    // ── to_api_json ───────────────────────────────────────────────────

    #[test]
    fn to_api_json_has_required_fields() {
        let m = get_openai_model("gpt-5.4").unwrap();
        let j = m.to_api_json(
            m.profile_for_auth_path(OpenAIAuthPath::ChatGptCodex)
                .unwrap(),
        );
        assert_eq!(j["id"], "gpt-5.4");
        assert_eq!(j["canonicalModelId"], "gpt-5.4");
        assert_eq!(j["name"], "GPT-5.4");
        assert_eq!(j["provider"], "openai-codex");
        assert_eq!(j["contextWindow"], 272_000);
        assert_eq!(j["maxOutput"], 128_000);
        assert_eq!(j["supportsThinking"], false);
        assert_eq!(j["supportsImages"], true);
        assert!(j["inputCostPerMillion"].is_number());
        assert!(j["outputCostPerMillion"].is_number());
        assert!(j["cacheReadCostPerMillion"].is_number());
        assert_eq!(j["tier"], "flagship");
        assert_eq!(j["family"], "GPT-5.4");
        assert!(j["description"].is_string());
        assert_eq!(j["supportsReasoning"], true);
        assert!(j["reasoningLevels"].is_array());
        assert!(j["defaultReasoningLevel"].is_string());
        assert_eq!(j["recommended"], false);
        assert_eq!(j["isLegacy"], false);
        assert!(j["sortOrder"].is_number());
        assert_eq!(j["apiEndpoint"], "codex");
        assert_eq!(j["authPaths"], json!(["chatgpt-codex"]));
        assert_eq!(j["supportsVerbosity"], true);
        assert_eq!(j["defaultVerbosity"], "low");
        assert_eq!(j["maxContextWindow"], 1_000_000);
    }

    #[test]
    fn to_api_json_knowledge_cutoff_present() {
        let m = get_openai_model("gpt-5.3-codex").unwrap();
        let j = m.to_api_json(m.default_profile());
        assert_eq!(j["knowledgeCutoff"], "2025-08-31");
    }

    #[test]
    fn to_api_json_knowledge_cutoff_absent() {
        let m = get_openai_model("gpt-5.3-codex-spark").unwrap();
        let j = m.to_api_json(m.default_profile());
        assert!(j.get("knowledgeCutoff").is_none());
    }

    #[test]
    fn to_api_json_not_deprecated_no_field() {
        // Non-deprecated models must omit isDeprecated/deprecationDate so
        // the iOS client's default behavior (isDeprecatedModel == false)
        // remains a no-op.
        let m = get_openai_model("gpt-5.4").unwrap();
        let j = m.to_api_json(m.default_profile());
        assert!(j.get("isDeprecated").is_none());
        assert!(j.get("deprecationDate").is_none());
    }

    #[test]
    fn gpt_52_codex_deprecated_2026_04_14() {
        let m = get_openai_model("gpt-5.2-codex").unwrap();
        assert!(m.is_deprecated);
        assert_eq!(m.deprecation_date, Some("2026-04-14"));
        let j = m.to_api_json(m.default_profile());
        assert_eq!(j["isDeprecated"], true);
        assert_eq!(j["deprecationDate"], "2026-04-14");
        assert_eq!(j["replacementModel"], "gpt-5.2");
    }

    #[test]
    fn gpt_51_codex_max_deprecated_2026_04_14() {
        let m = get_openai_model("gpt-5.1-codex-max").unwrap();
        assert!(m.is_deprecated);
        assert_eq!(m.deprecation_date, Some("2026-04-14"));
    }

    #[test]
    fn gpt_51_codex_mini_deprecated_2026_04_14() {
        let m = get_openai_model("gpt-5.1-codex-mini").unwrap();
        assert!(m.is_deprecated);
        assert_eq!(m.deprecation_date, Some("2026-04-14"));
    }

    #[test]
    fn gpt_53_codex_not_deprecated() {
        // Regression guard: supported models must not be flipped accidentally.
        let m = get_openai_model("gpt-5.3-codex").unwrap();
        assert!(!m.is_deprecated);
        assert_eq!(m.deprecation_date, None);
    }

    #[test]
    fn all_openai_models_api_json_sorted() {
        let models = all_openai_models_api_json();
        assert_eq!(models.len(), 5);
        // First model in each family should have lowest sort_order
        assert_eq!(models[0]["id"], "gpt-5.5");
        assert_eq!(models[0]["sortOrder"], 0);
        assert!(models.iter().all(|m| m["apiEndpoint"] == "codex"));
        assert!(!models.iter().any(|m| m["id"] == "gpt-5.4-pro"));
        assert!(!models.iter().any(|m| m["id"] == "gpt-5.4-nano"));
        assert!(!models.iter().any(|m| m["id"] == "gpt-5.3-codex-spark"));
        assert!(!models.iter().any(|m| m["id"] == "gpt-5.2-codex"));
        assert!(!models.iter().any(|m| m["id"] == "gpt-5.1-codex-max"));
        assert!(!models.iter().any(|m| m["id"] == "gpt-5.1-codex-mini"));
    }

    #[test]
    fn platform_model_list_uses_platform_profile() {
        let models = all_openai_models_api_json_for_auth_path(OpenAIAuthPath::PlatformApiKey);
        assert_eq!(models.len(), 7);
        let gpt55 = models.iter().find(|m| m["id"] == "gpt-5.5").unwrap();
        assert_eq!(gpt55["contextWindow"], 1_050_000);
        assert_eq!(gpt55["apiEndpoint"], "platform");
        assert_eq!(gpt55["authPaths"], json!(["platform-api-key"]));
        assert!(models.iter().any(|m| m["id"] == "gpt-5.4-pro"));
        assert!(models.iter().any(|m| m["id"] == "gpt-5.4-nano"));
        let gpt53 = models.iter().find(|m| m["id"] == "gpt-5.3-codex").unwrap();
        assert_eq!(gpt53["contextWindow"], 400_000);
        assert_eq!(gpt53["apiEndpoint"], "platform");
    }

    #[test]
    fn to_api_json_legacy_model() {
        let m = get_openai_model("gpt-5.3-codex").unwrap();
        let j = m.to_api_json(m.default_profile());
        assert_eq!(j["isLegacy"], true);
    }

    #[test]
    fn model_unknown_returns_none() {
        assert!(get_openai_model("gpt-99").is_none());
    }

    #[test]
    fn all_model_ids_contains_expected() {
        let ids = all_openai_model_ids();
        assert!(ids.contains(&"gpt-5.5"));
        assert!(ids.contains(&"gpt-5.5-2026-04-23"));
        assert!(ids.contains(&"gpt-5.4-nano"));
        assert!(ids.contains(&"gpt-5.2"));
        assert!(ids.contains(&"gpt-5.3-codex"));
        assert!(ids.contains(&"gpt-5.2-codex"));
        assert!(ids.contains(&"gpt-5.1-codex-max"));
        assert!(ids.contains(&"gpt-5.1-codex-mini"));
    }

    // ── Reasoning effort ───────────────────────────────────────────────

    #[test]
    fn reasoning_effort_serde_roundtrip() {
        let effort = ReasoningEffort::High;
        let json = serde_json::to_string(&effort).unwrap();
        assert_eq!(json, r#""high""#);
        let back: ReasoningEffort = serde_json::from_str(&json).unwrap();
        assert_eq!(back, ReasoningEffort::High);
    }

    #[test]
    fn reasoning_effort_all_variants() {
        for (variant, expected) in [
            (ReasoningEffort::None, "none"),
            (ReasoningEffort::Low, "low"),
            (ReasoningEffort::Medium, "medium"),
            (ReasoningEffort::High, "high"),
            (ReasoningEffort::Xhigh, "xhigh"),
            (ReasoningEffort::Max, "max"),
        ] {
            assert_eq!(variant.as_str(), expected);
            assert_eq!(variant.to_string(), expected);
        }
    }

    // ── ApiEndpoint ────────────────────────────────────────────────────

    #[test]
    fn api_endpoint_serde_roundtrip() {
        let codex = ApiEndpoint::Codex;
        let json = serde_json::to_string(&codex).unwrap();
        assert_eq!(json, r#""codex""#);
        let back: ApiEndpoint = serde_json::from_str(&json).unwrap();
        assert_eq!(back, ApiEndpoint::Codex);

        let platform = ApiEndpoint::Platform;
        let json = serde_json::to_string(&platform).unwrap();
        assert_eq!(json, r#""platform""#);
        let back: ApiEndpoint = serde_json::from_str(&json).unwrap();
        assert_eq!(back, ApiEndpoint::Platform);
    }

    #[test]
    fn api_endpoint_default_is_codex() {
        assert_eq!(ApiEndpoint::default(), ApiEndpoint::Codex);
    }

    #[test]
    fn api_endpoint_path() {
        assert_eq!(ApiEndpoint::Codex.path(), "/codex/responses");
        assert_eq!(ApiEndpoint::Platform.path(), "/v1/responses");
    }

    #[test]
    fn api_endpoint_default_base_url() {
        assert_eq!(ApiEndpoint::Codex.default_base_url(), DEFAULT_BASE_URL);
        assert_eq!(
            ApiEndpoint::Platform.default_base_url(),
            DEFAULT_PLATFORM_BASE_URL
        );
    }

    #[test]
    fn gpt_54_uses_platform_endpoint() {
        let (_, profile) =
            get_openai_model_profile("gpt-5.4", OpenAIAuthPath::PlatformApiKey).unwrap();
        assert_eq!(profile.api_endpoint, ApiEndpoint::Platform);
    }

    #[test]
    fn gpt_54_pro_uses_platform_endpoint() {
        let (_, profile) =
            get_openai_model_profile("gpt-5.4-pro", OpenAIAuthPath::PlatformApiKey).unwrap();
        assert_eq!(profile.api_endpoint, ApiEndpoint::Platform);
    }

    #[test]
    fn codex_models_use_codex_endpoint() {
        for id in [
            "gpt-5.5",
            "gpt-5.4",
            "gpt-5.4-mini",
            "gpt-5.3-codex",
            "gpt-5.3-codex-spark",
            "gpt-5.2",
            "gpt-5.2-codex",
            "gpt-5.1-codex-max",
            "gpt-5.1-codex-mini",
        ] {
            let (_, profile) = get_openai_model_profile(id, OpenAIAuthPath::ChatGptCodex)
                .unwrap_or_else(|| panic!("expected Codex for {id}"));
            assert_eq!(
                profile.api_endpoint,
                ApiEndpoint::Codex,
                "expected Codex for {id}"
            );
        }
    }

    // ── Auth ───────────────────────────────────────────────────────────

    #[test]
    fn auth_oauth_serde() {
        let auth = OpenAIAuth::OAuth {
            tokens: crate::llm::auth::OAuthTokens {
                access_token: "at".into(),
                refresh_token: "rt".into(),
                expires_at: 99999,
            },
        };
        let json = serde_json::to_value(&auth).unwrap();
        assert_eq!(json["type"], "oauth");
        assert_eq!(json["tokens"]["accessToken"], "at");
    }

    #[test]
    fn auth_api_key_serde() {
        let auth = OpenAIAuth::ApiKey {
            api_key: "sk-test-123".into(),
        };
        let json = serde_json::to_value(&auth).unwrap();
        assert_eq!(json["type"], "api_key");
        assert_eq!(json["api_key"], "sk-test-123");

        let back: OpenAIAuth = serde_json::from_value(json).unwrap();
        assert!(matches!(back, OpenAIAuth::ApiKey { api_key } if api_key == "sk-test-123"));
    }

    // ── Config ─────────────────────────────────────────────────────────

    #[test]
    fn config_serde() {
        let config = OpenAIConfig {
            model: "gpt-5.3-codex".into(),
            auth: OpenAIAuth::OAuth {
                tokens: crate::llm::auth::OAuthTokens {
                    access_token: "at".into(),
                    refresh_token: "rt".into(),
                    expires_at: 99999,
                },
            },
            max_tokens: Some(4096),
            temperature: None,
            base_url: None,
            reasoning_effort: Some("high".into()),
            provider_settings: OpenAIApiSettings::default(),
        };
        let json = serde_json::to_value(&config).unwrap();
        assert_eq!(json["model"], "gpt-5.3-codex");
        assert_eq!(json["maxTokens"], 4096);
        assert_eq!(json["reasoningEffort"], "high");
    }

    // ── Responses API types ────────────────────────────────────────────

    #[test]
    fn responses_input_text_serde() {
        let item = ResponsesInputItem::InputText {
            text: "hello".into(),
        };
        let json = serde_json::to_value(&item).unwrap();
        assert_eq!(json["type"], "input_text");
        assert_eq!(json["text"], "hello");
    }

    #[test]
    fn responses_input_message_serde() {
        let item = ResponsesInputItem::Message {
            role: "user".into(),
            content: vec![MessageContent::InputText {
                text: "hello".into(),
            }],
            id: None,
        };
        let json = serde_json::to_value(&item).unwrap();
        assert_eq!(json["type"], "message");
        assert_eq!(json["role"], "user");
        assert_eq!(json["content"][0]["type"], "input_text");
    }

    #[test]
    fn responses_function_call_serde() {
        let item = ResponsesInputItem::FunctionCall {
            id: None,
            call_id: "call_abc".into(),
            name: "bash".into(),
            arguments: r#"{"cmd":"ls"}"#.into(),
        };
        let json = serde_json::to_value(&item).unwrap();
        assert_eq!(json["type"], "function_call");
        assert_eq!(json["call_id"], "call_abc");
        assert_eq!(json["name"], "bash");
    }

    #[test]
    fn responses_function_call_output_serde() {
        let item = ResponsesInputItem::FunctionCallOutput {
            call_id: "call_abc".into(),
            output: "file.txt".into(),
        };
        let json = serde_json::to_value(&item).unwrap();
        assert_eq!(json["type"], "function_call_output");
        assert_eq!(json["call_id"], "call_abc");
        assert_eq!(json["output"], "file.txt");
    }

    // ── ResponsesToolEntry ───────────────────────────────────────────

    #[test]
    fn tool_entry_function_serde() {
        let entry = ResponsesToolEntry::Function {
            name: "bash".into(),
            description: "Run commands".into(),
            parameters: json!({"type": "object"}),
            defer_loading: None,
        };
        let json = serde_json::to_value(&entry).unwrap();
        assert_eq!(json["type"], "function");
        assert_eq!(json["name"], "bash");
        assert!(json.get("defer_loading").is_none());

        let back: ResponsesToolEntry = serde_json::from_value(json).unwrap();
        assert!(matches!(back, ResponsesToolEntry::Function { .. }));
    }

    #[test]
    fn tool_entry_function_with_defer_loading() {
        let entry = ResponsesToolEntry::Function {
            name: "read_file".into(),
            description: "Read a file".into(),
            parameters: json!({"type": "object"}),
            defer_loading: Some(true),
        };
        let json = serde_json::to_value(&entry).unwrap();
        assert_eq!(json["defer_loading"], true);
    }

    #[test]
    fn tool_entry_tool_search_serde() {
        let entry = ResponsesToolEntry::ToolSearch {};
        let json = serde_json::to_value(&entry).unwrap();
        assert_eq!(json["type"], "tool_search");

        let back: ResponsesToolEntry = serde_json::from_value(json).unwrap();
        assert!(matches!(back, ResponsesToolEntry::ToolSearch {}));
    }

    #[test]
    fn tool_entry_computer_serde() {
        let entry = ResponsesToolEntry::Computer {
            viewport_width: Some(1280),
            viewport_height: Some(720),
        };
        let json = serde_json::to_value(&entry).unwrap();
        assert_eq!(json["type"], "computer");
        assert_eq!(json["viewport_width"], 1280);

        let back: ResponsesToolEntry = serde_json::from_value(json).unwrap();
        assert!(matches!(back, ResponsesToolEntry::Computer { .. }));
    }

    #[test]
    fn tool_entry_computer_minimal_serde() {
        let entry = ResponsesToolEntry::Computer {
            viewport_width: None,
            viewport_height: None,
        };
        let json = serde_json::to_value(&entry).unwrap();
        assert_eq!(json["type"], "computer");
        assert!(json.get("viewport_width").is_none());
    }

    #[test]
    fn tool_entry_serde_roundtrip_all_variants() {
        let entries = vec![
            ResponsesToolEntry::Function {
                name: "bash".into(),
                description: "Run".into(),
                parameters: json!({}),
                defer_loading: Some(true),
            },
            ResponsesToolEntry::ToolSearch {},
            ResponsesToolEntry::Computer {
                viewport_width: Some(1024),
                viewport_height: Some(768),
            },
        ];
        let json = serde_json::to_string(&entries).unwrap();
        let back: Vec<ResponsesToolEntry> = serde_json::from_str(&json).unwrap();
        assert_eq!(back.len(), 3);
        assert!(matches!(&back[0], ResponsesToolEntry::Function { .. }));
        assert!(matches!(&back[1], ResponsesToolEntry::ToolSearch {}));
        assert!(matches!(&back[2], ResponsesToolEntry::Computer { .. }));
    }

    // ── SSE event types for tool search ──────────────────────────────

    #[test]
    fn sse_tool_search_event_deserializes() {
        let json = json!({ "type": "response.tool_search_call.searching" });
        let event: ResponsesSseEvent = serde_json::from_value(json).unwrap();
        assert_eq!(event.event_type, SseEventType::ToolSearchCallSearching);
    }

    #[test]
    fn sse_tool_search_completed_deserializes() {
        let json = json!({ "type": "response.tool_search_call.completed" });
        let event: ResponsesSseEvent = serde_json::from_value(json).unwrap();
        assert_eq!(event.event_type, SseEventType::ToolSearchCallCompleted);
    }

    #[test]
    fn output_item_type_tool_search_call() {
        let json = json!({ "type": "tool_search_call" });
        let item: ResponsesOutputItem = serde_json::from_value(json).unwrap();
        assert_eq!(item.item_type, OutputItemType::ToolSearchCall);
    }

    #[test]
    fn output_item_type_computer_call() {
        let json = json!({ "type": "computer_call" });
        let item: ResponsesOutputItem = serde_json::from_value(json).unwrap();
        assert_eq!(item.item_type, OutputItemType::ComputerCall);
    }

    #[test]
    fn responses_request_serde() {
        let req = ResponsesRequest {
            model: "gpt-5.3-codex".into(),
            input: vec![ResponsesInputItem::InputText {
                text: "hello".into(),
            }],
            instructions: Some("Be helpful".into()),
            stream: true,
            store: false,
            temperature: None,
            tools: None,
            max_output_tokens: Some(16384),
            reasoning: Some(ReasoningConfig {
                effort: "medium".into(),
                summary: "detailed".into(),
            }),
            text: Some(ResponseTextConfig {
                verbosity: "low".into(),
            }),
        };
        let json = serde_json::to_value(&req).unwrap();
        assert_eq!(json["model"], "gpt-5.3-codex");
        assert!(json["stream"].as_bool().unwrap());
        assert!(!json["store"].as_bool().unwrap());
        assert_eq!(json["reasoning"]["effort"], "medium");
        assert_eq!(json["reasoning"]["summary"], "detailed");
        assert_eq!(json["text"]["verbosity"], "low");
    }

    // ── SSE event types ────────────────────────────────────────────────

    #[test]
    fn sse_text_delta() {
        let json = json!({
            "type": "response.output_text.delta",
            "delta": "Hello ",
            "content_index": 0,
        });
        let event: ResponsesSseEvent = serde_json::from_value(json).unwrap();
        assert_eq!(event.event_type, SseEventType::OutputTextDelta);
        assert_eq!(event.delta.as_deref(), Some("Hello "));
        assert_eq!(event.content_index, Some(0));
    }

    #[test]
    fn sse_output_item_added_function_call() {
        let json = json!({
            "type": "response.output_item.added",
            "item": {
                "type": "function_call",
                "call_id": "call_abc",
                "name": "bash",
            },
        });
        let event: ResponsesSseEvent = serde_json::from_value(json).unwrap();
        assert_eq!(event.event_type, SseEventType::OutputItemAdded);
        let item = event.item.unwrap();
        assert_eq!(item.item_type, OutputItemType::FunctionCall);
        assert_eq!(item.call_id.as_deref(), Some("call_abc"));
        assert_eq!(item.name.as_deref(), Some("bash"));
    }

    #[test]
    fn sse_output_item_added_reasoning() {
        let json = json!({
            "type": "response.output_item.added",
            "item": { "type": "reasoning" },
        });
        let event: ResponsesSseEvent = serde_json::from_value(json).unwrap();
        let item = event.item.unwrap();
        assert_eq!(item.item_type, OutputItemType::Reasoning);
    }

    #[test]
    fn sse_reasoning_summary_delta() {
        let json = json!({
            "type": "response.reasoning_summary_text.delta",
            "delta": "Thinking about...",
            "summary_index": 0,
        });
        let event: ResponsesSseEvent = serde_json::from_value(json).unwrap();
        assert_eq!(event.event_type, SseEventType::ReasoningSummaryTextDelta);
        assert_eq!(event.delta.as_deref(), Some("Thinking about..."));
    }

    #[test]
    fn sse_function_call_args_delta() {
        let json = json!({
            "type": "response.function_call_arguments.delta",
            "call_id": "call_abc",
            "delta": r#"{"cmd":"#,
        });
        let event: ResponsesSseEvent = serde_json::from_value(json).unwrap();
        assert_eq!(event.event_type, SseEventType::FunctionCallArgsDelta);
        assert_eq!(event.call_id.as_deref(), Some("call_abc"));
    }

    #[test]
    fn sse_completed() {
        let json = json!({
            "type": "response.completed",
            "response": {
                "id": "resp_123",
                "output": [],
                "usage": { "input_tokens": 100, "output_tokens": 50 },
            },
        });
        let event: ResponsesSseEvent = serde_json::from_value(json).unwrap();
        assert_eq!(event.event_type, SseEventType::Completed);
        let resp = event.response.unwrap();
        assert_eq!(resp.id.as_deref(), Some("resp_123"));
        let usage = resp.usage.unwrap();
        assert_eq!(usage.input_tokens, 100);
        assert_eq!(usage.output_tokens, 50);
    }

    #[test]
    fn sse_unknown_event_type_deserializes() {
        let json = json!({
            "type": "response.new_feature.delta",
        });
        let event: ResponsesSseEvent = serde_json::from_value(json).unwrap();
        assert_eq!(event.event_type, SseEventType::Unknown);
    }

    #[test]
    fn output_item_type_unknown_deserializes() {
        let json = json!({
            "type": "new_item_type",
        });
        let item: ResponsesOutputItem = serde_json::from_value(json).unwrap();
        assert_eq!(item.item_type, OutputItemType::Unknown);
    }

    #[test]
    fn message_content_input_text() {
        let mc = MessageContent::InputText {
            text: "hello".into(),
        };
        let json = serde_json::to_value(&mc).unwrap();
        assert_eq!(json["type"], "input_text");
    }

    #[test]
    fn message_content_input_image() {
        let mc = MessageContent::InputImage {
            image_url: "data:image/png;base64,abc".into(),
            detail: Some("auto".into()),
        };
        let json = serde_json::to_value(&mc).unwrap();
        assert_eq!(json["type"], "input_image");
        assert_eq!(json["detail"], "auto");
    }

    #[test]
    fn output_item_function_call() {
        let item = ResponsesOutputItem {
            item_type: OutputItemType::FunctionCall,
            call_id: Some("call_abc".into()),
            name: Some("bash".into()),
            arguments: Some(r#"{"cmd":"ls"}"#.into()),
            ..Default::default()
        };
        let json = serde_json::to_value(&item).unwrap();
        assert_eq!(json["type"], "function_call");
        assert_eq!(json["call_id"], "call_abc");
    }

    #[test]
    fn reasoning_config_serde() {
        let rc = ReasoningConfig {
            effort: "high".into(),
            summary: "detailed".into(),
        };
        let json = serde_json::to_value(&rc).unwrap();
        assert_eq!(json["effort"], "high");
        assert_eq!(json["summary"], "detailed");
        let back: ReasoningConfig = serde_json::from_value(json).unwrap();
        assert_eq!(back.effort, "high");
    }
}
