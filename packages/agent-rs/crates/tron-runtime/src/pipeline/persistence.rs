//! Persistence helpers — build JSON structures for event payloads.
//!
//! These transform Rust types into the JSON shapes that the event store
//! and iOS client expect. The key fix: provider type is now **dynamic**
//! (not hardcoded to "anthropic").

use serde_json::{json, Value};
use tron_core::content::AssistantContent;
use tron_core::messages::TokenUsage;
use tron_llm::models::types::ProviderType;

/// Build a JSON content array from assistant content blocks.
///
/// Renames `arguments` → `input` on `tool_use` blocks (Anthropic API wire format
/// that iOS expects).
pub fn build_content_json(content: &[AssistantContent]) -> Vec<Value> {
    content.iter().map(content_block_to_json).collect()
}

/// Build `tokenUsage` JSON from a [`TokenUsage`] struct.
pub fn build_token_usage_json(usage: &TokenUsage) -> Value {
    let mut obj = json!({
        "inputTokens": usage.input_tokens,
        "outputTokens": usage.output_tokens,
    });
    let m = obj.as_object_mut().unwrap();
    if let Some(cr) = usage.cache_read_tokens {
        let _ = m.insert("cacheReadInputTokens".into(), json!(cr));
    }
    if let Some(cc) = usage.cache_creation_tokens {
        let _ = m.insert("cacheCreationInputTokens".into(), json!(cc));
    }
    obj
}

/// Build the nested `tokenRecord` structure for iOS compatibility.
///
/// Provider type is **dynamic** — uses the actual provider, not hardcoded "anthropic".
pub fn build_token_record(
    usage: &TokenUsage,
    provider_type: ProviderType,
    session_id: &str,
    turn: u32,
) -> Value {
    let now = chrono::Utc::now().to_rfc3339();
    let cr = usage.cache_read_tokens.unwrap_or(0);
    // New input = total input minus cached portion. cache_creation tokens are
    // NEW tokens written to cache (already part of non-cached input), so we
    // only subtract cache_read.
    let new_input = usage.input_tokens.saturating_sub(cr);

    json!({
        "source": {
            "rawInputTokens": usage.input_tokens,
            "rawOutputTokens": usage.output_tokens,
            "rawCacheReadTokens": cr,
            "rawCacheCreationTokens": usage.cache_creation_tokens.unwrap_or(0),
            "rawCacheCreation5mTokens": usage.cache_creation_5m_tokens.unwrap_or(0),
            "rawCacheCreation1hTokens": usage.cache_creation_1h_tokens.unwrap_or(0),
            "provider": provider_type.as_str(),
            "timestamp": now,
        },
        "computed": {
            "contextWindowTokens": usage.input_tokens + usage.output_tokens,
            "newInputTokens": new_input,
            "previousContextBaseline": 0,
            "calculationMethod": "default",
        },
        "meta": {
            "turn": turn,
            "sessionId": session_id,
            "extractedAt": now,
            "normalizedAt": now,
        }
    })
}

// ─── Internal helpers ────────────────────────────────────────────────────────

fn content_block_to_json(block: &AssistantContent) -> Value {
    match block {
        AssistantContent::Text { text } => {
            json!({ "type": "text", "text": text })
        }
        AssistantContent::Thinking {
            thinking,
            signature,
        } => {
            let mut obj = json!({ "type": "thinking", "thinking": thinking });
            if let Some(sig) = signature {
                obj["signature"] = json!(sig);
            }
            obj
        }
        AssistantContent::ToolUse {
            id,
            name,
            arguments,
            thought_signature,
        } => {
            // Rename "arguments" → "input" for iOS/Anthropic API wire format
            let mut obj = json!({
                "type": "tool_use",
                "id": id,
                "name": name,
                "input": Value::Object(arguments.clone()),
            });
            if let Some(sig) = thought_signature {
                obj["thoughtSignature"] = json!(sig);
            }
            obj
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Map};

    // ── build_content_json ───────────────────────────────────────────

    #[test]
    fn build_content_json_text_only() {
        let content = vec![AssistantContent::text("Hello world")];
        let json = build_content_json(&content);
        assert_eq!(json.len(), 1);
        assert_eq!(json[0]["type"], "text");
        assert_eq!(json[0]["text"], "Hello world");
    }

    #[test]
    fn build_content_json_tool_use_renames_arguments_to_input() {
        let mut args = Map::new();
        args.insert("command".into(), json!("ls"));
        let content = vec![AssistantContent::ToolUse {
            id: "id1".into(),
            name: "bash".into(),
            arguments: args,
            thought_signature: None,
        }];
        let json = build_content_json(&content);
        assert!(
            json[0].get("input").is_some(),
            "must rename arguments to input"
        );
        assert!(
            json[0].get("arguments").is_none(),
            "must not have arguments key"
        );
        assert_eq!(json[0]["input"]["command"], "ls");
    }

    #[test]
    fn build_content_json_thinking_block() {
        let content = vec![AssistantContent::Thinking {
            thinking: "let me think".into(),
            signature: Some("sig".into()),
        }];
        let json = build_content_json(&content);
        assert_eq!(json[0]["type"], "thinking");
        assert_eq!(json[0]["thinking"], "let me think");
        assert_eq!(json[0]["signature"], "sig");
    }

    #[test]
    fn build_content_json_thinking_no_signature() {
        let content = vec![AssistantContent::Thinking {
            thinking: "hmm".into(),
            signature: None,
        }];
        let json = build_content_json(&content);
        assert_eq!(json[0]["type"], "thinking");
        assert!(json[0].get("signature").is_none());
    }

    #[test]
    fn build_content_json_mixed_content() {
        let mut args = Map::new();
        args.insert("command".into(), json!("ls"));
        let content = vec![
            AssistantContent::text("I'll run that command"),
            AssistantContent::ToolUse {
                id: "tc1".into(),
                name: "bash".into(),
                arguments: args,
                thought_signature: None,
            },
        ];
        let json = build_content_json(&content);
        assert_eq!(json.len(), 2);
        assert_eq!(json[0]["type"], "text");
        assert_eq!(json[1]["type"], "tool_use");
    }

    #[test]
    fn build_content_json_tool_use_with_thought_signature() {
        let content = vec![AssistantContent::ToolUse {
            id: "tc1".into(),
            name: "bash".into(),
            arguments: Map::new(),
            thought_signature: Some("gemini-sig".into()),
        }];
        let json = build_content_json(&content);
        assert_eq!(json[0]["thoughtSignature"], "gemini-sig");
    }

    // ── build_token_usage_json ───────────────────────────────────────

    #[test]
    fn build_token_usage_json_all_fields() {
        let usage = TokenUsage {
            input_tokens: 100,
            output_tokens: 50,
            cache_read_tokens: Some(30),
            cache_creation_tokens: Some(10),
            ..Default::default()
        };
        let json = build_token_usage_json(&usage);
        assert_eq!(json["inputTokens"], 100);
        assert_eq!(json["outputTokens"], 50);
        assert_eq!(json["cacheReadInputTokens"], 30);
        assert_eq!(json["cacheCreationInputTokens"], 10);
    }

    #[test]
    fn build_token_usage_json_no_cache() {
        let usage = TokenUsage {
            input_tokens: 100,
            output_tokens: 50,
            ..Default::default()
        };
        let json = build_token_usage_json(&usage);
        assert_eq!(json["inputTokens"], 100);
        assert_eq!(json["outputTokens"], 50);
        assert!(json.get("cacheReadInputTokens").is_none());
        assert!(json.get("cacheCreationInputTokens").is_none());
    }

    // ── build_token_record ──────────────────────────────────────────

    #[test]
    fn build_token_record_uses_dynamic_provider() {
        let usage = TokenUsage {
            input_tokens: 100,
            output_tokens: 50,
            ..Default::default()
        };

        let anthropic = build_token_record(&usage, ProviderType::Anthropic, "sess-1", 1);
        assert_eq!(anthropic["source"]["provider"], "anthropic");

        let google = build_token_record(&usage, ProviderType::Google, "sess-1", 1);
        assert_eq!(google["source"]["provider"], "google");

        let openai = build_token_record(&usage, ProviderType::OpenAi, "sess-1", 1);
        assert_eq!(openai["source"]["provider"], "openai");
    }

    #[test]
    fn build_token_record_nested_structure_matches_ios() {
        let usage = TokenUsage {
            input_tokens: 100,
            output_tokens: 50,
            ..Default::default()
        };
        let record = build_token_record(&usage, ProviderType::Anthropic, "sess-1", 3);
        assert!(record.get("source").is_some());
        assert!(record.get("computed").is_some());
        assert!(record.get("meta").is_some());
        assert_eq!(record["meta"]["sessionId"], "sess-1");
        assert_eq!(record["meta"]["turn"], 3);
    }

    #[test]
    fn build_token_record_computed_fields() {
        let usage = TokenUsage {
            input_tokens: 100,
            output_tokens: 50,
            cache_read_tokens: Some(10),
            cache_creation_tokens: Some(5),
            ..Default::default()
        };
        let record = build_token_record(&usage, ProviderType::Anthropic, "s1", 1);
        assert_eq!(record["computed"]["contextWindowTokens"], 150); // 100 + 50
        // newInputTokens = input - cache_read (cache_creation is new tokens, not deducted)
        assert_eq!(record["computed"]["newInputTokens"], 90); // 100 - 10
        assert_eq!(record["computed"]["previousContextBaseline"], 0);
        assert_eq!(record["computed"]["calculationMethod"], "default");
    }

    #[test]
    fn build_token_record_source_raw_fields() {
        let usage = TokenUsage {
            input_tokens: 200,
            output_tokens: 100,
            cache_read_tokens: Some(30),
            cache_creation_tokens: Some(20),
            cache_creation_5m_tokens: Some(5),
            cache_creation_1h_tokens: Some(3),
            ..Default::default()
        };
        let record = build_token_record(&usage, ProviderType::Anthropic, "s1", 1);
        let source = &record["source"];
        assert_eq!(source["rawInputTokens"], 200);
        assert_eq!(source["rawOutputTokens"], 100);
        assert_eq!(source["rawCacheReadTokens"], 30);
        assert_eq!(source["rawCacheCreationTokens"], 20);
        assert_eq!(source["rawCacheCreation5mTokens"], 5);
        assert_eq!(source["rawCacheCreation1hTokens"], 3);
        assert!(source["timestamp"].is_string());
    }

    #[test]
    fn build_token_record_cache_none_defaults_zero() {
        let usage = TokenUsage {
            input_tokens: 100,
            output_tokens: 50,
            ..Default::default()
        };
        let record = build_token_record(&usage, ProviderType::Anthropic, "s1", 1);
        assert_eq!(record["source"]["rawCacheReadTokens"], 0);
        assert_eq!(record["source"]["rawCacheCreationTokens"], 0);
    }
}
