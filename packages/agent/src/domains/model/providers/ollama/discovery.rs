//! Live Ollama endpoint discovery.
//!
//! `GET /api/tags` owns installed-model identity. A bounded parallel
//! `POST /api/show` pass supplies capabilities and model metadata. When show
//! metadata is missing, installed unknown models remain text-only, tool-free,
//! and 16K-context rather than inheriting optimistic defaults.

use futures::{StreamExt as _, stream};
use serde::Deserialize;
use serde_json::Value;

use super::types::{
    DEFAULT_MAX_OUTPUT_TOKENS, DEFAULT_NUM_CTX, OllamaModelInfo, get_known_ollama_model,
    replace_discovered_ollama_models,
};

const DISCOVERY_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(3);
const MAX_PARALLEL_SHOW_REQUESTS: usize = 8;

#[derive(Clone, Debug, Deserialize)]
struct TagsResponse {
    #[serde(default)]
    models: Vec<TagModel>,
}

#[derive(Clone, Debug, Deserialize)]
struct TagModel {
    #[serde(default)]
    name: String,
    #[serde(default)]
    model: String,
    digest: Option<String>,
    size: Option<u64>,
    #[serde(default)]
    details: ModelDetails,
}

#[derive(Clone, Debug, Default, Deserialize)]
struct ModelDetails {
    family: Option<String>,
    parameter_size: Option<String>,
    quantization_level: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize)]
struct ShowResponse {
    #[serde(default)]
    capabilities: Vec<String>,
    #[serde(default)]
    details: ModelDetails,
    #[serde(default)]
    model_info: serde_json::Map<String, Value>,
}

/// One complete provider discovery result.
#[derive(Clone, Debug)]
pub struct OllamaDiscovery {
    /// Whether `/api/tags` completed successfully.
    pub reachable: bool,
    /// Installed models enriched by `/api/show` where possible.
    pub models: Vec<OllamaModelInfo>,
    /// Actionable provider-level failure when unreachable.
    pub error: Option<String>,
}

fn normalize_endpoint(base_url: &str) -> String {
    base_url.trim().trim_end_matches('/').to_owned()
}

/// Query the configured Ollama endpoint and atomically refresh runtime model metadata.
pub async fn discover_ollama_models(base_url: &str) -> OllamaDiscovery {
    let endpoint = normalize_endpoint(base_url);
    let client = match reqwest::Client::builder()
        .timeout(DISCOVERY_TIMEOUT)
        .build()
    {
        Ok(client) => client,
        Err(error) => {
            replace_discovered_ollama_models(&[]);
            return OllamaDiscovery {
                reachable: false,
                models: Vec::new(),
                error: Some(format!("Could not prepare Ollama discovery: {error}")),
            };
        }
    };

    let tags = match query_tags(&client, &endpoint).await {
        Ok(tags) => tags,
        Err(error) => {
            replace_discovered_ollama_models(&[]);
            return OllamaDiscovery {
                reachable: false,
                models: Vec::new(),
                error: Some(error),
            };
        }
    };

    let endpoint_for_show = endpoint.clone();
    let client_for_show = client.clone();
    let mut models = stream::iter(tags.into_iter().map(move |tag| {
        let endpoint = endpoint_for_show.clone();
        let client = client_for_show.clone();
        async move {
            let name = if tag.model.trim().is_empty() {
                tag.name.clone()
            } else {
                tag.model.clone()
            };
            let show = query_show(&client, &endpoint, &name).await.ok();
            model_from_evidence(name, tag, show)
        }
    }))
    .buffer_unordered(MAX_PARALLEL_SHOW_REQUESTS)
    .collect::<Vec<_>>()
    .await;
    models.sort_by(|left, right| {
        left.sort_order
            .cmp(&right.sort_order)
            .then_with(|| left.name.cmp(&right.name))
    });
    replace_discovered_ollama_models(&models);

    OllamaDiscovery {
        reachable: true,
        models,
        error: None,
    }
}

async fn query_tags(client: &reqwest::Client, endpoint: &str) -> Result<Vec<TagModel>, String> {
    let response = client
        .get(format!("{endpoint}/api/tags"))
        .send()
        .await
        .map_err(|error| {
            format!(
                "Ollama endpoint {endpoint} is unreachable. Start Ollama or correct the endpoint: {error}"
            )
        })?;
    if !response.status().is_success() {
        return Err(format!(
            "Ollama endpoint {endpoint} returned HTTP {} for /api/tags",
            response.status()
        ));
    }
    response
        .json::<TagsResponse>()
        .await
        .map(|body| body.models)
        .map_err(|error| format!("Ollama endpoint {endpoint} returned invalid model data: {error}"))
}

async fn query_show(
    client: &reqwest::Client,
    endpoint: &str,
    model: &str,
) -> Result<ShowResponse, String> {
    let response = client
        .post(format!("{endpoint}/api/show"))
        .json(&serde_json::json!({"model": model, "verbose": false}))
        .send()
        .await
        .map_err(|error| error.to_string())?;
    if !response.status().is_success() {
        return Err(format!("HTTP {}", response.status()));
    }
    response.json().await.map_err(|error| error.to_string())
}

fn model_from_evidence(name: String, tag: TagModel, show: Option<ShowResponse>) -> OllamaModelInfo {
    let mut model = get_known_ollama_model(&name).unwrap_or_else(|| OllamaModelInfo {
        id: name.clone(),
        name: name.clone(),
        short_name: name.clone(),
        family: tag
            .details
            .family
            .clone()
            .unwrap_or_else(|| "Installed Ollama".to_owned()),
        context_window: u64::from(DEFAULT_NUM_CTX),
        max_context_window: u64::from(DEFAULT_NUM_CTX),
        max_output: DEFAULT_MAX_OUTPUT_TOKENS,
        supports_thinking: false,
        supports_tools: false,
        supports_images: false,
        supports_audio: false,
        description: "Installed Ollama model; capabilities are limited to evidence reported by the configured endpoint.".to_owned(),
        sort_order: 100,
        recommended: false,
        metadata_source: "conservative".to_owned(),
        parameter_size: tag.details.parameter_size.clone(),
        quantization_level: tag.details.quantization_level.clone(),
        digest: tag.digest.clone(),
        size_bytes: tag.size,
    });

    model.digest = tag.digest;
    model.size_bytes = tag.size;
    model.parameter_size = tag.details.parameter_size.or(model.parameter_size);
    model.quantization_level = tag.details.quantization_level.or(model.quantization_level);
    if let Some(family) = tag.details.family.filter(|family| !family.is_empty()) {
        model.family = humanize_family(&family);
    }

    if let Some(show) = show {
        let capabilities = show
            .capabilities
            .iter()
            .map(|capability| capability.as_str())
            .collect::<std::collections::HashSet<_>>();
        model.supports_thinking = capabilities.contains("thinking");
        model.supports_tools = capabilities.contains("tools");
        model.supports_images = capabilities.contains("vision");
        model.supports_audio = capabilities.contains("audio");
        if let Some(context_window) = context_window_from_model_info(&show.model_info) {
            model.max_context_window = context_window;
            model.context_window = context_window.min(65_536);
        }
        model.parameter_size = show.details.parameter_size.or(model.parameter_size);
        model.quantization_level = show.details.quantization_level.or(model.quantization_level);
        if let Some(family) = show.details.family.filter(|family| !family.is_empty()) {
            model.family = humanize_family(&family);
        }
        model.metadata_source = "ollama-show".to_owned();
    }

    model
}

fn context_window_from_model_info(info: &serde_json::Map<String, Value>) -> Option<u64> {
    info.iter()
        .filter(|(key, _)| key.ends_with(".context_length"))
        .filter_map(|(_, value)| value.as_u64())
        .max()
}

fn humanize_family(family: &str) -> String {
    if family.eq_ignore_ascii_case("gemma4") {
        "Gemma 4".to_owned()
    } else {
        family.to_owned()
    }
}

/// Serialize known and installed Ollama models with provider-level availability.
pub async fn all_ollama_models_api_json_with_availability(
    base_url: &str,
) -> Vec<serde_json::Value> {
    let discovery = discover_ollama_models(base_url).await;
    let installed_by_id = discovery
        .models
        .iter()
        .map(|model| (model.id.as_str(), model))
        .collect::<std::collections::HashMap<_, _>>();

    let mut rows = Vec::new();
    for known_id in super::types::all_ollama_model_ids() {
        let model = installed_by_id.get(known_id).map_or_else(
            || get_known_ollama_model(known_id).expect("known Ollama model"),
            |model| (*model).clone(),
        );
        let installed = installed_by_id.contains_key(known_id);
        let reason = if discovery.reachable && !installed {
            Some(format!("Not installed — run: ollama pull {known_id}"))
        } else {
            discovery.error.clone()
        };
        rows.push(model.to_api_json(installed, discovery.reachable, reason.as_deref()));
    }

    for model in &discovery.models {
        if get_known_ollama_model(&model.id).is_none() {
            rows.push(model.to_api_json(true, true, None));
        }
    }
    rows
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domains::model::providers::ollama::types::get_ollama_model;
    use crate::domains::model::routing::models::model_ids::{GEMMA4_26B, GEMMA4_E4B};
    use wiremock::matchers::{body_json, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[tokio::test]
    async fn discovery_admits_installed_unknown_models_from_show_evidence() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/tags"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "models": [
                    {"name":"gemma4:e4b","model":"gemma4:e4b","digest":"gemma-digest","size":9000,"details":{"family":"gemma4","parameter_size":"8.0B","quantization_level":"Q4_K_M"}},
                    {"name":"qwen3:8b","model":"qwen3:8b","digest":"qwen-digest","size":4000,"details":{"family":"qwen3","parameter_size":"8B","quantization_level":"Q4_K_M"}}
                ]
            })))
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(path("/api/show"))
            .and(body_json(
                serde_json::json!({"model":"gemma4:e4b","verbose":false}),
            ))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "capabilities":["completion","vision","audio","tools","thinking"],
                "details":{"family":"gemma4","parameter_size":"8.0B","quantization_level":"Q4_K_M"},
                "model_info":{"gemma4.context_length":131072}
            })))
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(path("/api/show"))
            .and(body_json(
                serde_json::json!({"model":"qwen3:8b","verbose":false}),
            ))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "capabilities":["completion","tools","thinking"],
                "details":{"family":"qwen3","parameter_size":"8B","quantization_level":"Q4_K_M"},
                "model_info":{"qwen3.context_length":32768}
            })))
            .mount(&server)
            .await;

        let rows = all_ollama_models_api_json_with_availability(&server.uri()).await;
        let e4b = rows.iter().find(|row| row["id"] == GEMMA4_E4B).unwrap();
        assert_eq!(e4b["available"], true);
        assert_eq!(e4b["contextWindow"], 65_536);
        assert_eq!(e4b["maxContextWindow"], 131_072);
        assert_eq!(e4b["supportsAudio"], true);

        let dynamic = rows
            .iter()
            .find(|row| row["id"] == "ollama/qwen3:8b")
            .unwrap();
        assert_eq!(dynamic["canonicalModelId"], "qwen3:8b");
        assert_eq!(dynamic["supportsTools"], true);
        assert_eq!(dynamic["supportsImages"], false);
        assert_eq!(dynamic["metadataSource"], "ollama-show");
        assert!(get_ollama_model("qwen3:8b").is_some());

        let missing = rows.iter().find(|row| row["id"] == GEMMA4_26B).unwrap();
        assert_eq!(missing["providerReachable"], true);
        assert_eq!(missing["installed"], false);
    }

    #[tokio::test]
    async fn failed_discovery_marks_known_models_unreachable() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/tags"))
            .respond_with(ResponseTemplate::new(503))
            .mount(&server)
            .await;

        let rows = all_ollama_models_api_json_with_availability(&server.uri()).await;
        assert_eq!(rows.len(), 2);
        assert!(rows.iter().all(|row| row["providerReachable"] == false));
        assert!(rows.iter().all(|row| row["available"] == false));
        assert!(rows.iter().all(|row| {
            row["unavailableReason"]
                .as_str()
                .is_some_and(|reason| reason.contains("HTTP 503"))
        }));
    }
}
