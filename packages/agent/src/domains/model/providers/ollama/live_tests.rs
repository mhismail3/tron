//! Opt-in compatibility evidence against an operator-owned Ollama service.
//!
//! These tests never install, pull, start, stop, or remove Ollama or its models.
//! Run them explicitly with `TRON_OLLAMA_LIVE=1`; the configured endpoint may
//! be overridden with `TRON_OLLAMA_LIVE_ENDPOINT`.

use serde_json::{Value, json};

use super::discovery::discover_ollama_models;
use super::types::DEFAULT_BASE_URL;
use crate::domains::model::routing::models::model_ids::{GEMMA4_26B, GEMMA4_E4B};

const REQUEST_CONTEXT: u64 = 32_768;

// A valid one-pixel PNG. The assertion is compatibility, not visual quality.
const TEST_PNG: &str =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";

fn live_endpoint() -> String {
    assert_eq!(
        std::env::var("TRON_OLLAMA_LIVE").as_deref(),
        Ok("1"),
        "set TRON_OLLAMA_LIVE=1 to acknowledge use of the local Ollama service"
    );
    std::env::var("TRON_OLLAMA_LIVE_ENDPOINT")
        .unwrap_or_else(|_| DEFAULT_BASE_URL.to_owned())
        .trim_end_matches('/')
        .to_owned()
}

async fn post_chat(client: &reqwest::Client, endpoint: &str, body: Value) -> Value {
    let response = client
        .post(format!("{endpoint}/api/chat"))
        .json(&body)
        .send()
        .await
        .expect("Ollama chat request");
    let status = response.status();
    let text = response.text().await.expect("Ollama chat response body");
    assert!(status.is_success(), "Ollama returned {status}: {text}");
    serde_json::from_str(&text).expect("Ollama JSON response")
}

async fn assert_tool_call(client: &reqwest::Client, endpoint: &str, model: &str) {
    let response = post_chat(
        client,
        endpoint,
        json!({
            "model": model,
            "stream": false,
            "think": false,
            "messages": [{
                "role": "user",
                "content": "Call add_numbers exactly once with a=8 and b=9. Do not answer directly."
            }],
            "tools": [{
                "type": "function",
                "function": {
                    "name": "add_numbers",
                    "description": "Add two integers.",
                    "parameters": {
                        "type": "object",
                        "additionalProperties": false,
                        "properties": {
                            "a": {"type": "integer"},
                            "b": {"type": "integer"}
                        },
                        "required": ["a", "b"]
                    }
                }
            }],
            "options": {
                "num_ctx": REQUEST_CONTEXT,
                "num_predict": 128,
                "temperature": 0
            }
        }),
    )
    .await;
    let call = &response["message"]["tool_calls"][0]["function"];
    assert_eq!(call["name"], "add_numbers", "response: {response}");
    assert_eq!(call["arguments"]["a"], 8, "response: {response}");
    assert_eq!(call["arguments"]["b"], 9, "response: {response}");
}

async fn assert_structured_output(client: &reqwest::Client, endpoint: &str, model: &str) {
    let response = post_chat(
        client,
        endpoint,
        json!({
            "model": model,
            "stream": false,
            "think": false,
            "messages": [{
                "role": "user",
                "content": "Output only this JSON object with no markdown and no other keys: {\"sum\":17}. The response must match the requested schema exactly."
            }],
            "format": {
                "type": "object",
                "additionalProperties": false,
                "properties": {"sum": {"type": "integer"}},
                "required": ["sum"]
            },
            "options": {
                "num_ctx": REQUEST_CONTEXT,
                "num_predict": 64,
                "temperature": 0
            }
        }),
    )
    .await;
    let content = response["message"]["content"]
        .as_str()
        .expect("structured content");
    let value: Value = serde_json::from_str(content)
        .unwrap_or_else(|error| panic!("schema-conforming JSON ({error}); response: {response}"));
    assert_eq!(value["sum"], 17, "response: {response}");
}

async fn assert_image_input(client: &reqwest::Client, endpoint: &str, model: &str) {
    let response = post_chat(
        client,
        endpoint,
        json!({
            "model": model,
            "stream": false,
            "think": false,
            "messages": [{
                "role": "user",
                "content": "Acknowledge the attached image in five words or fewer.",
                "images": [TEST_PNG]
            }],
            "options": {
                "num_ctx": REQUEST_CONTEXT,
                "num_predict": 32,
                "temperature": 0
            }
        }),
    )
    .await;
    assert!(
        !response["message"]["content"]
            .as_str()
            .unwrap_or_default()
            .trim()
            .is_empty(),
        "response: {response}"
    );
}

async fn assert_loaded_context(client: &reqwest::Client, endpoint: &str, model: &str) {
    let response = client
        .get(format!("{endpoint}/api/ps"))
        .send()
        .await
        .expect("Ollama running-model request")
        .error_for_status()
        .expect("Ollama running-model status")
        .json::<Value>()
        .await
        .expect("Ollama running-model response");
    let loaded = response["models"]
        .as_array()
        .and_then(|models| {
            models.iter().find(|entry| {
                entry["name"].as_str() == Some(model) || entry["model"].as_str() == Some(model)
            })
        })
        .unwrap_or_else(|| panic!("{model} is not present in /api/ps: {response}"));
    assert!(
        loaded["context_length"].as_u64().unwrap_or_default() >= REQUEST_CONTEXT,
        "Ollama did not retain the requested context for {model}: {loaded}"
    );
}

#[tokio::test]
#[ignore = "requires operator-owned Ollama and installed Gemma 4 models"]
async fn installed_gemma4_models_support_trons_required_local_contract() {
    let endpoint = live_endpoint();
    let discovery = discover_ollama_models(&endpoint).await;
    assert!(
        discovery.reachable,
        "Ollama discovery: {:?}",
        discovery.error
    );

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(180))
        .build()
        .expect("Ollama live-test client");

    for model_id in [GEMMA4_E4B, GEMMA4_26B] {
        let evidence = discovery
            .models
            .iter()
            .find(|model| model.id == model_id)
            .unwrap_or_else(|| panic!("{model_id} is not installed at {endpoint}"));
        assert!(evidence.supports_tools, "{model_id} tool metadata");
        assert!(evidence.supports_thinking, "{model_id} thinking metadata");
        assert!(evidence.supports_images, "{model_id} image metadata");
        assert_eq!(evidence.metadata_source, "ollama-show");

        assert_tool_call(&client, &endpoint, model_id).await;
        assert_structured_output(&client, &endpoint, model_id).await;
        assert_image_input(&client, &endpoint, model_id).await;
        assert_loaded_context(&client, &endpoint, model_id).await;
    }
}
