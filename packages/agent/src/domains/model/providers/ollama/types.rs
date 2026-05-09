//! Ollama model registry and config types.
//!
//! Ollama runs local models via an `OpenAI` chat completions-compatible API.
//! No authentication required. Models: Gemma 4 family (E4B, 26B MoE).

use std::collections::HashMap;
use std::sync::LazyLock;

use crate::domains::model::providers::models::model_ids::{GEMMA4_26B, GEMMA4_E4B};
use crate::domains::model::providers::retry::StreamRetryConfig;

/// Default base URL for the Ollama API.
pub const DEFAULT_BASE_URL: &str = "http://localhost:11434";

/// Default max output tokens for Ollama models (conservative for local inference).
pub const DEFAULT_MAX_OUTPUT_TOKENS: u32 = 8_192;

/// Default context window size to request from Ollama.
///
/// Ollama defaults to 4,096 tokens if not specified, which is far too small
/// for Tron's system prompt + tool definitions + conversation. We request 16K
/// by default — enough for typical agent interactions without excessive memory.
/// Ollama will reload the model if the context size changes from what's loaded.
pub const DEFAULT_NUM_CTX: u32 = 16_384;

/// Ollama provider configuration.
#[derive(Clone, Debug)]
pub struct OllamaConfig {
    /// Model ID (e.g., `"gemma4:e4b"`).
    pub model: String,
    /// Override base URL (default: `http://localhost:11434`).
    pub base_url: Option<String>,
    /// Override max tokens.
    pub max_tokens: Option<u32>,
    /// Retry configuration.
    pub retry: Option<StreamRetryConfig>,
}

/// Ollama model information.
#[derive(Clone, Debug)]
pub struct OllamaModelInfo {
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
    /// Supports tool use.
    pub supports_tools: bool,
    /// Supports image inputs.
    pub supports_images: bool,
    /// Model description for the client UI.
    pub description: &'static str,
    /// Display sort order within the provider (lower = higher priority).
    pub sort_order: u16,
    /// Whether this model is recommended for new users.
    pub recommended: bool,
}

static OLLAMA_MODELS: LazyLock<HashMap<&'static str, OllamaModelInfo>> = LazyLock::new(|| {
    let mut m = HashMap::new();
    let _ = m.insert(
        GEMMA4_E4B,
        OllamaModelInfo {
            id: GEMMA4_E4B,
            name: "Gemma 4 E4B",
            short_name: "E4B",
            family: "Gemma 4",
            context_window: 65_536,
            max_output: 8_192,
            supports_thinking: true,
            supports_tools: true,
            supports_images: true,
            description: "Gemma 4 E4B — 4.5B effective dense model for edge/validation.",
            sort_order: 0,
            recommended: false,
        },
    );
    let _ = m.insert(
        GEMMA4_26B,
        OllamaModelInfo {
            id: GEMMA4_26B,
            name: "Gemma 4 26B",
            short_name: "26B",
            family: "Gemma 4",
            context_window: 65_536,
            max_output: 8_192,
            supports_thinking: true,
            supports_tools: true,
            supports_images: true,
            description: "Gemma 4 26B MoE — 3.8B active params, flagship local model.",
            sort_order: 1,
            recommended: true,
        },
    );
    m
});

/// Look up an Ollama model by ID.
pub fn get_ollama_model(id: &str) -> Option<&'static OllamaModelInfo> {
    OLLAMA_MODELS.get(id)
}

/// All known Ollama model IDs.
pub fn all_ollama_model_ids() -> Vec<&'static str> {
    OLLAMA_MODELS.keys().copied().collect()
}

impl OllamaModelInfo {
    /// Serialize this model to JSON for the `model.list` API response.
    pub fn to_api_json(&self, id: &str) -> serde_json::Value {
        // supportsThinking: true → iOS displays thinking blocks when they arrive.
        // supportsReasoning: false → no reasoning level picker (Gemma 4 thinking
        //   is always-on, not configurable).
        serde_json::json!({
            "id": id,
            "name": self.name,
            "provider": "ollama",
            "providerDisplayName": "Ollama",
            "providerSortOrder": 5,
            "contextWindow": self.context_window,
            "maxOutput": self.max_output,
            "supportsThinking": self.supports_thinking,
            "supportsImages": self.supports_images,
            "supportsDocuments": false,
            "inputCostPerMillion": 0.0,
            "outputCostPerMillion": 0.0,
            "tier": "local",
            "family": self.family,
            "description": self.description,
            "supportsReasoning": false,
            "recommended": self.recommended,
            "isLegacy": false,
            "sortOrder": self.sort_order,
        })
    }
}

/// All Ollama models serialized for the `model.list` API, sorted by `sort_order`.
///
/// This is the static (sync) version — all models are listed without availability info.
/// Prefer [`all_ollama_models_api_json_with_availability`] when an async context is available.
pub fn all_ollama_models_api_json() -> Vec<serde_json::Value> {
    let mut entries: Vec<_> = OLLAMA_MODELS.iter().collect();
    entries.sort_by_key(|(_, info)| info.sort_order);
    entries
        .into_iter()
        .map(|(id, info)| info.to_api_json(id))
        .collect()
}

/// All Ollama models with live availability status from the local Ollama server.
///
/// Queries `GET /api/tags` to discover which models are actually pulled.
/// If Ollama is not running or unreachable, all models are marked unavailable
/// with an appropriate `unavailableReason`.
pub async fn all_ollama_models_api_json_with_availability(
    base_url: Option<&str>,
) -> Vec<serde_json::Value> {
    let base = base_url.unwrap_or(DEFAULT_BASE_URL);
    let pulled = query_pulled_models(base).await;

    let mut entries: Vec<_> = OLLAMA_MODELS.iter().collect();
    entries.sort_by_key(|(_, info)| info.sort_order);

    entries
        .into_iter()
        .map(|(id, info)| {
            let mut json = info.to_api_json(id);
            match &pulled {
                Ok(models) => {
                    let available = models.iter().any(|m| m == id);
                    json["available"] = serde_json::Value::Bool(available);
                    if !available {
                        json["unavailableReason"] = serde_json::Value::String(format!(
                            "Not installed — run: ollama pull {id}"
                        ));
                    }
                }
                Err(reason) => {
                    json["available"] = serde_json::Value::Bool(false);
                    json["unavailableReason"] = serde_json::Value::String(reason.clone());
                }
            }
            json
        })
        .collect()
}

/// Query Ollama's `/api/tags` endpoint for the list of pulled model names.
///
/// Returns `Ok(Vec<model_name>)` on success, `Err(reason)` if Ollama is
/// unreachable or returns an error.
async fn query_pulled_models(base_url: &str) -> Result<Vec<String>, String> {
    let url = format!("{base_url}/api/tags");
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(3))
        .build()
        .map_err(|e| format!("HTTP client error: {e}"))?;

    let resp = client
        .get(&url)
        .send()
        .await
        .map_err(|_| "Ollama is not running — install with: brew install ollama && brew services start ollama".to_string())?;

    if !resp.status().is_success() {
        return Err(format!("Ollama returned status {}", resp.status()));
    }

    let body: serde_json::Value = resp
        .json()
        .await
        .map_err(|e| format!("Failed to parse Ollama response: {e}"))?;

    let models = body["models"]
        .as_array()
        .map(|arr| {
            arr.iter()
                .filter_map(|m| m["name"].as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default();

    Ok(models)
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn get_ollama_model_e4b() {
        let m = get_ollama_model("gemma4:e4b").unwrap();
        assert_eq!(m.name, "Gemma 4 E4B");
        assert_eq!(m.context_window, 65_536);
        assert!(m.supports_thinking);
        assert!(m.supports_tools);
        assert!(m.supports_images);
        assert!(!m.recommended);
    }

    #[test]
    fn get_ollama_model_26b() {
        let m = get_ollama_model("gemma4:26b").unwrap();
        assert_eq!(m.name, "Gemma 4 26B");
        assert_eq!(m.context_window, 65_536);
        assert!(m.supports_thinking);
        assert!(m.supports_tools);
        assert!(m.supports_images);
        assert!(m.recommended);
    }

    #[test]
    fn get_ollama_model_unknown_returns_none() {
        assert!(get_ollama_model("nonexistent").is_none());
        assert!(get_ollama_model("gpt-5.3-codex").is_none());
    }

    #[test]
    fn all_ollama_model_ids_count() {
        let ids = all_ollama_model_ids();
        assert_eq!(ids.len(), 2);
        assert!(ids.contains(&"gemma4:e4b"));
        assert!(ids.contains(&"gemma4:26b"));
    }

    #[test]
    fn ollama_id_format() {
        for id in all_ollama_model_ids() {
            assert!(
                id.starts_with("gemma4:"),
                "Ollama model ID should start with 'gemma4:': {id}"
            );
        }
    }

    #[test]
    fn to_api_json_e4b() {
        let m = get_ollama_model("gemma4:e4b").unwrap();
        let j = m.to_api_json("gemma4:e4b");
        assert_eq!(j["id"], "gemma4:e4b");
        assert_eq!(j["name"], "Gemma 4 E4B");
        assert_eq!(j["provider"], "ollama");
        assert_eq!(j["providerDisplayName"], "Ollama");
        assert_eq!(j["contextWindow"], 65_536);
        assert_eq!(j["maxOutput"], 8_192);
        assert_eq!(j["supportsThinking"], true);
        assert_eq!(j["supportsImages"], true);
        assert_eq!(j["supportsDocuments"], false);
        assert_eq!(j["inputCostPerMillion"], 0.0);
        assert_eq!(j["outputCostPerMillion"], 0.0);
        assert_eq!(j["tier"], "local");
        assert_eq!(j["family"], "Gemma 4");
        assert_eq!(j["isLegacy"], false);
        assert_eq!(j["sortOrder"], 0);
        // Thinking is always-on but not configurable — no reasoning picker
        assert_eq!(j["supportsReasoning"], false);
        assert!(j.get("reasoningLevels").is_none());
    }

    #[test]
    fn all_ollama_models_api_json_sorted() {
        let models = all_ollama_models_api_json();
        assert_eq!(models.len(), 2);
        assert_eq!(models[0]["id"], "gemma4:e4b");
        assert_eq!(models[0]["sortOrder"], 0);
        assert_eq!(models[1]["id"], "gemma4:26b");
        assert_eq!(models[1]["sortOrder"], 1);
    }
}
