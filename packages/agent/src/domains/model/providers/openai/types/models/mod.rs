//! OpenAI auth-path-aware model registry.

use super::{ApiEndpoint, OpenAIAuthPath};

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
    /// Whether this profile supports streaming Responses requests.
    pub supports_streaming: bool,
    /// Whether the model supports capability invocation.
    pub supports_capabilities: bool,
    /// Whether the model supports image inputs.
    pub supports_images: bool,
    /// Whether the model supports reasoning.
    pub supports_reasoning: bool,
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
    /// Provider aliases and snapshots accepted by the registry.
    pub aliases: &'static [&'static str],
    /// Per-auth-path profiles.
    pub profiles: Vec<OpenAIModelProfile>,
    /// Display sort order within the provider (lower = higher priority).
    pub sort_order: u16,
    /// Whether this model is recommended for new users.
    pub recommended: bool,
    /// Whether this is a retired/older generation model.
    pub is_retired_generation: bool,
    /// Whether this model has been retired by the provider. Retired models are
    /// provider metadata for routing, audit, and cost reporting; new selection
    /// surfaces mark them unavailable.
    pub is_retired: bool,
    /// Retirement date (ISO-8601), if retired.
    pub deprecation_date: Option<&'static str>,
    /// Suggested replacement model from the provider catalog.
    pub replacement_model: Option<&'static str>,
    /// Whether this model should be hidden from `model.list`.
    pub is_hidden: bool,
    /// Whether this model is a preview model.
    pub is_preview: bool,
    /// Knowledge cutoff date (ISO-8601), if known.
    pub knowledge_cutoff: Option<&'static str>,
}

const REASONING_NONE_TO_XHIGH: &[&str] = &["none", "low", "medium", "high", "xhigh"];
const REASONING_NONE_TO_HIGH: &[&str] = &["none", "low", "medium", "high"];
const REASONING_MINIMAL_TO_HIGH: &[&str] = &["minimal", "low", "medium", "high"];
const REASONING_LOW_TO_XHIGH: &[&str] = &["low", "medium", "high", "xhigh"];
const REASONING_MEDIUM_TO_XHIGH: &[&str] = &["medium", "high", "xhigh"];
const REASONING_LOW_TO_HIGH: &[&str] = &["low", "medium", "high"];
const REASONING_HIGH_ONLY: &[&str] = &["high"];
const NO_REASONING: &[&str] = &[];

#[allow(clippy::too_many_arguments)]
fn profile(
    auth_path: OpenAIAuthPath,
    context_window: u64,
    max_context_window: Option<u64>,
    max_output: u64,
    supports_streaming: bool,
    supports_capabilities: bool,
    supports_images: bool,
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
        supports_streaming,
        supports_capabilities,
        supports_images,
        supports_reasoning: !reasoning_levels.is_empty(),
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
    is_retired_generation: bool,
    is_retired: bool,
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
        is_retired_generation,
        is_retired,
        deprecation_date,
        replacement_model,
        is_hidden,
        is_preview,
        knowledge_cutoff,
    }
}

#[allow(clippy::too_many_arguments)]
fn platform_profile(
    context_window: u64,
    max_context_window: Option<u64>,
    max_output: u64,
    supports_streaming: bool,
    supports_capabilities: bool,
    supports_images: bool,
    supports_verbosity: bool,
    reasoning_levels: &'static [&'static str],
    default_reasoning_level: &'static str,
    input_cost_per_million: f64,
    output_cost_per_million: f64,
    cache_read_cost_per_million: Option<f64>,
    visible: bool,
) -> OpenAIModelProfile {
    profile(
        OpenAIAuthPath::PlatformApiKey,
        context_window,
        max_context_window,
        max_output,
        supports_streaming,
        supports_capabilities,
        supports_images,
        supports_verbosity,
        supports_verbosity.then_some("medium"),
        reasoning_levels,
        default_reasoning_level,
        input_cost_per_million,
        output_cost_per_million,
        cache_read_cost_per_million,
        visible,
    )
}

#[allow(clippy::too_many_arguments)]
fn platform_reasoning_profile(
    context_window: u64,
    max_output: u64,
    supports_capabilities: bool,
    supports_images: bool,
    reasoning_levels: &'static [&'static str],
    default_reasoning_level: &'static str,
    input_cost_per_million: f64,
    output_cost_per_million: f64,
    cache_read_cost_per_million: Option<f64>,
) -> OpenAIModelProfile {
    platform_profile(
        context_window,
        Some(context_window),
        max_output,
        true,
        supports_capabilities,
        supports_images,
        true,
        reasoning_levels,
        default_reasoning_level,
        input_cost_per_million,
        output_cost_per_million,
        cache_read_cost_per_million,
        true,
    )
}

#[allow(clippy::too_many_arguments)]
fn platform_text_profile(
    context_window: u64,
    max_output: u64,
    supports_capabilities: bool,
    supports_images: bool,
    input_cost_per_million: f64,
    output_cost_per_million: f64,
    cache_read_cost_per_million: Option<f64>,
) -> OpenAIModelProfile {
    platform_profile(
        context_window,
        Some(context_window),
        max_output,
        true,
        supports_capabilities,
        supports_images,
        false,
        NO_REASONING,
        "none",
        input_cost_per_million,
        output_cost_per_million,
        cache_read_cost_per_million,
        true,
    )
}

#[allow(clippy::too_many_arguments)]
fn platform_non_streaming_profile(
    context_window: u64,
    max_output: u64,
    supports_capabilities: bool,
    supports_images: bool,
    reasoning_levels: &'static [&'static str],
    default_reasoning_level: &'static str,
    input_cost_per_million: f64,
    output_cost_per_million: f64,
) -> OpenAIModelProfile {
    platform_profile(
        context_window,
        Some(context_window),
        max_output,
        false,
        supports_capabilities,
        supports_images,
        false,
        reasoning_levels,
        default_reasoning_level,
        input_cost_per_million,
        output_cost_per_million,
        None,
        false,
    )
}

#[allow(clippy::too_many_arguments)]
fn codex_profile(
    max_output: u64,
    supports_images: bool,
    reasoning_levels: &'static [&'static str],
    default_reasoning_level: &'static str,
    input_cost_per_million: f64,
    output_cost_per_million: f64,
    cache_read_cost_per_million: f64,
    visible: bool,
) -> OpenAIModelProfile {
    codex_profile_with_max_context(
        Some(272_000),
        max_output,
        supports_images,
        reasoning_levels,
        default_reasoning_level,
        input_cost_per_million,
        output_cost_per_million,
        cache_read_cost_per_million,
        visible,
    )
}

#[allow(clippy::too_many_arguments)]
fn codex_profile_with_max_context(
    max_context_window: Option<u64>,
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
        max_context_window,
        max_output,
        true,
        true,
        supports_images,
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

mod catalog;

pub use catalog::OPENAI_MODELS;

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
    get_openai_model(model_id).map(|info| info.id)
}

/// Resolve the request model ID sent to OpenAI.
///
/// Explicit model IDs are sent as configured. Entitlement, availability, and
/// provider retirement state are reported explicitly instead of silently
/// downgrading to another model.
#[must_use]
pub fn openai_request_model_id(model_id: &str) -> String {
    strip_openai_provider_prefix(model_id).to_string()
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
    get_openai_model_profile(model_id, auth_path).is_some_and(|(info, profile)| {
        !info.is_hidden && profile.visible && profile.supports_streaming
    })
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
            "isLegacy": self.is_retired_generation,
            "sortOrder": self.sort_order,
            "apiEndpoint": profile.api_endpoint,
            "authPaths": [profile.auth_path.as_str()],
            "supportsStreaming": profile.supports_streaming,
            "supportsCapabilityPrimitives": profile.supports_capabilities,
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
        if self.is_retired {
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
            if info.is_hidden || !profile.visible || !profile.supports_streaming {
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
