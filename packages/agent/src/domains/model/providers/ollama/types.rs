//! Ollama configuration and model metadata.
//!
//! Two current Gemma 4 variants carry built-in metadata so they remain
//! selectable when the local service is offline. Live `/api/tags` plus
//! `/api/show` discovery augments that baseline and admits any other installed
//! model only with conservative capabilities derived from Ollama itself.

use std::collections::HashMap;
use std::sync::{LazyLock, RwLock};

use crate::domains::model::routing::models::model_ids::{GEMMA4_26B, GEMMA4_E4B};

/// Default base URL for the Ollama API.
pub const DEFAULT_BASE_URL: &str = "http://localhost:11434";

/// Default max output tokens for Ollama models (conservative for local inference).
pub const DEFAULT_MAX_OUTPUT_TOKENS: u32 = 8_192;

/// Context used when Ollama cannot prove an installed model's actual limit.
pub const DEFAULT_NUM_CTX: u32 = 16_384;

/// Ollama provider configuration.
#[derive(Clone, Debug)]
pub struct OllamaConfig {
    /// Model ID as accepted by Ollama (for example `gemma4:e4b`).
    pub model: String,
    /// Override base URL (default: `http://localhost:11434`).
    pub base_url: Option<String>,
    /// Override max tokens.
    pub max_tokens: Option<u32>,
}

/// Model metadata used by routing, request construction, and `model.list`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OllamaModelInfo {
    /// Native Ollama model name.
    pub id: String,
    /// Human-readable name.
    pub name: String,
    /// Short name for compact display.
    pub short_name: String,
    /// Model family.
    pub family: String,
    /// Effective context window Tron requests by default.
    pub context_window: u64,
    /// Maximum context proven by model metadata.
    pub max_context_window: u64,
    /// Maximum output tokens Tron should request by default.
    pub max_output: u32,
    /// Supports separate thinking output.
    pub supports_thinking: bool,
    /// Supports tool invocation.
    pub supports_tools: bool,
    /// Supports image inputs.
    pub supports_images: bool,
    /// Supports audio inputs at the model level.
    pub supports_audio: bool,
    /// Model description for the client UI.
    pub description: String,
    /// Display sort order within the provider (lower = higher priority).
    pub sort_order: u16,
    /// Whether this model is recommended for new local sessions.
    pub recommended: bool,
    /// Evidence source for effective capabilities.
    pub metadata_source: String,
    /// Ollama-reported parameter size.
    pub parameter_size: Option<String>,
    /// Ollama-reported quantization level.
    pub quantization_level: Option<String>,
    /// Ollama content digest when installed.
    pub digest: Option<String>,
    /// Local bundle size when installed.
    pub size_bytes: Option<u64>,
}

static KNOWN_OLLAMA_MODELS: LazyLock<HashMap<&'static str, OllamaModelInfo>> = LazyLock::new(
    || {
        HashMap::from([
            (
                GEMMA4_E4B,
                OllamaModelInfo {
                    id: GEMMA4_E4B.to_owned(),
                    name: "Gemma 4 E4B".to_owned(),
                    short_name: "E4B".to_owned(),
                    family: "Gemma 4".to_owned(),
                    context_window: 65_536,
                    max_context_window: 131_072,
                    max_output: DEFAULT_MAX_OUTPUT_TOKENS,
                    supports_thinking: true,
                    supports_tools: true,
                    supports_images: true,
                    supports_audio: true,
                    description: "Gemma 4 E4B — efficient multimodal reasoning for laptops and edge systems.".to_owned(),
                    sort_order: 0,
                    recommended: false,
                    metadata_source: "built-in".to_owned(),
                    parameter_size: Some("8B (4.5B effective)".to_owned()),
                    quantization_level: None,
                    digest: None,
                    size_bytes: None,
                },
            ),
            (
                GEMMA4_26B,
                OllamaModelInfo {
                    id: GEMMA4_26B.to_owned(),
                    name: "Gemma 4 26B A4B".to_owned(),
                    short_name: "26B A4B".to_owned(),
                    family: "Gemma 4".to_owned(),
                    context_window: 65_536,
                    max_context_window: 262_144,
                    max_output: DEFAULT_MAX_OUTPUT_TOKENS,
                    supports_thinking: true,
                    supports_tools: true,
                    supports_images: true,
                    supports_audio: false,
                    description: "Gemma 4 26B A4B — 25.2B-parameter mixture-of-experts model with 3.8B active parameters.".to_owned(),
                    sort_order: 1,
                    recommended: true,
                    metadata_source: "built-in".to_owned(),
                    parameter_size: Some("26B (3.8B active)".to_owned()),
                    quantization_level: None,
                    digest: None,
                    size_bytes: None,
                },
            ),
        ])
    },
);

// INVARIANT: this cache contains only models observed through the configured
// Ollama endpoint. Discovery replaces it atomically so stale remote models are
// never retained after an endpoint switch or failed refresh.
static DISCOVERED_OLLAMA_MODELS: LazyLock<RwLock<HashMap<String, OllamaModelInfo>>> =
    LazyLock::new(|| RwLock::new(HashMap::new()));

fn bare_model_id(id: &str) -> &str {
    id.strip_prefix("ollama/").unwrap_or(id)
}

/// Look up an Ollama model by native or explicit `ollama/`-prefixed ID.
#[must_use]
pub fn get_ollama_model(id: &str) -> Option<OllamaModelInfo> {
    let id = bare_model_id(id);
    DISCOVERED_OLLAMA_MODELS
        .read()
        .ok()
        .and_then(|models| models.get(id).cloned())
        .or_else(|| KNOWN_OLLAMA_MODELS.get(id).cloned())
}

/// Look up only Tron's built-in Ollama metadata.
#[must_use]
pub(crate) fn get_known_ollama_model(id: &str) -> Option<OllamaModelInfo> {
    KNOWN_OLLAMA_MODELS.get(bare_model_id(id)).cloned()
}

/// Replace the endpoint-derived registry after one complete discovery pass.
pub(crate) fn replace_discovered_ollama_models(models: &[OllamaModelInfo]) {
    if let Ok(mut discovered) = DISCOVERED_OLLAMA_MODELS.write() {
        *discovered = models
            .iter()
            .cloned()
            .map(|model| (model.id.clone(), model))
            .collect();
    }
}

/// All built-in Ollama model IDs.
///
/// Installed models outside this baseline are intentionally runtime-owned and
/// therefore do not enter the compile-time cross-provider ID catalog.
#[must_use]
pub fn all_ollama_model_ids() -> Vec<&'static str> {
    vec![GEMMA4_E4B, GEMMA4_26B]
}

impl OllamaModelInfo {
    /// ID exposed to clients. Unknown local names remain explicitly provider
    /// scoped so synchronous routing can identify them after a restart.
    #[must_use]
    pub fn public_id(&self) -> String {
        if KNOWN_OLLAMA_MODELS.contains_key(self.id.as_str()) {
            self.id.clone()
        } else {
            format!("ollama/{}", self.id)
        }
    }

    /// Serialize this model to JSON for the `model.list` API response.
    #[must_use]
    pub fn to_api_json(
        &self,
        installed: bool,
        provider_reachable: bool,
        unavailable_reason: Option<&str>,
    ) -> serde_json::Value {
        let public_id = self.public_id();
        let mut value = serde_json::json!({
            "id": public_id,
            "canonicalModelId": self.id,
            "name": self.name,
            "shortName": self.short_name,
            "provider": "ollama",
            "providerDisplayName": "Ollama",
            "providerSortOrder": 5,
            "contextWindow": self.context_window,
            "maxContextWindow": self.max_context_window,
            "maxOutput": self.max_output,
            "supportsThinking": self.supports_thinking,
            "supportsImages": self.supports_images,
            "supportsDocuments": false,
            "supportsTools": self.supports_tools,
            "supportsAudio": self.supports_audio,
            "inputCostPerMillion": 0.0,
            "outputCostPerMillion": 0.0,
            "tier": "local",
            "family": self.family,
            "description": self.description,
            "supportsReasoning": false,
            "recommended": self.recommended,
            "isRetiredGeneration": false,
            "sortOrder": self.sort_order,
            "available": installed && provider_reachable,
            "installed": installed,
            "providerReachable": provider_reachable,
            "metadataSource": self.metadata_source,
            "parameterSize": self.parameter_size,
            "quantizationLevel": self.quantization_level,
            "digest": self.digest,
            "sizeBytes": self.size_bytes,
        });
        if let Some(reason) = unavailable_reason {
            value["unavailableReason"] = serde_json::Value::String(reason.to_owned());
        }
        value
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn built_in_gemma_metadata_matches_current_family() {
        let e4b = get_known_ollama_model(GEMMA4_E4B).unwrap();
        assert_eq!(e4b.context_window, 65_536);
        assert_eq!(e4b.max_context_window, 131_072);
        assert!(e4b.supports_audio);
        assert!(e4b.supports_tools);
        assert!(!e4b.recommended);

        let a4b = get_known_ollama_model(GEMMA4_26B).unwrap();
        assert_eq!(a4b.context_window, 65_536);
        assert_eq!(a4b.max_context_window, 262_144);
        assert!(!a4b.supports_audio);
        assert!(a4b.recommended);
    }

    #[test]
    fn unknown_models_use_explicit_provider_scoped_public_ids() {
        let model = OllamaModelInfo {
            id: "qwen3:8b".to_owned(),
            name: "qwen3:8b".to_owned(),
            short_name: "qwen3:8b".to_owned(),
            family: "qwen3".to_owned(),
            context_window: DEFAULT_NUM_CTX.into(),
            max_context_window: DEFAULT_NUM_CTX.into(),
            max_output: DEFAULT_MAX_OUTPUT_TOKENS,
            supports_thinking: false,
            supports_tools: false,
            supports_images: false,
            supports_audio: false,
            description: "Installed Ollama model.".to_owned(),
            sort_order: 100,
            recommended: false,
            metadata_source: "conservative".to_owned(),
            parameter_size: None,
            quantization_level: None,
            digest: None,
            size_bytes: None,
        };

        assert_eq!(model.public_id(), "ollama/qwen3:8b");
        let json = model.to_api_json(true, true, None);
        assert_eq!(json["id"], "ollama/qwen3:8b");
        assert_eq!(json["supportsTools"], false);
        assert_eq!(json["available"], true);
    }

    #[test]
    fn unavailable_metadata_distinguishes_installation_from_reachability() {
        let model = get_known_ollama_model(GEMMA4_E4B).unwrap();
        let json = model.to_api_json(false, true, Some("Not installed"));
        assert_eq!(json["providerReachable"], true);
        assert_eq!(json["installed"], false);
        assert_eq!(json["available"], false);
        assert_eq!(json["unavailableReason"], "Not installed");
    }
}
