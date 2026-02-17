//! Persistence helpers — build JSON structures for event payloads.
//!
//! These transform Rust types into the JSON shapes that the event store
//! and iOS client expect. Token normalization delegates to `tron-tokens`
//! for correct per-turn deltas.

use serde_json::{json, Value};
use tron_core::content::AssistantContent;
use tron_core::messages::TokenUsage;
use tron_llm::models::types::ProviderType;
use tron_llm::tokens::normalization::normalize_tokens;
use tron_llm::tokens::types::{TokenMeta, TokenSource};

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
    let m = obj.as_object_mut().expect("just created as object");
    if let Some(cr) = usage.cache_read_tokens {
        let _ = m.insert("cacheReadTokens".into(), json!(cr));
    }
    if let Some(cc) = usage.cache_creation_tokens {
        let _ = m.insert("cacheCreationTokens".into(), json!(cc));
    }
    obj
}

/// Build the nested `tokenRecord` structure for iOS compatibility.
///
/// Delegates to `tron_llm::tokens::normalize_tokens()` for correct per-turn
/// delta calculation using cross-turn baseline tracking.
pub fn build_token_record(
    usage: &TokenUsage,
    provider_type: ProviderType,
    session_id: &str,
    turn: u32,
    previous_baseline: u64,
) -> Value {
    let now = chrono::Utc::now().to_rfc3339();
    let source = TokenSource {
        provider: llm_to_core_provider(provider_type),
        timestamp: now.clone(),
        raw_input_tokens: usage.input_tokens,
        raw_output_tokens: usage.output_tokens,
        raw_cache_read_tokens: usage.cache_read_tokens.unwrap_or(0),
        raw_cache_creation_tokens: usage.cache_creation_tokens.unwrap_or(0),
        raw_cache_creation_5m_tokens: usage.cache_creation_5m_tokens.unwrap_or(0),
        raw_cache_creation_1h_tokens: usage.cache_creation_1h_tokens.unwrap_or(0),
    };
    let meta = TokenMeta {
        turn: u64::from(turn),
        session_id: session_id.to_string(),
        extracted_at: now,
        normalized_at: String::new(),
    };
    let record = normalize_tokens(source, previous_baseline, meta);
    serde_json::to_value(&record).unwrap_or_default()
}

/// Convert `tron_llm` provider type to `tron_core` provider type.
fn llm_to_core_provider(pt: ProviderType) -> tron_core::messages::ProviderType {
    match pt {
        ProviderType::Anthropic => tron_core::messages::ProviderType::Anthropic,
        ProviderType::OpenAi => tron_core::messages::ProviderType::OpenAi,
        ProviderType::Google => tron_core::messages::ProviderType::Google,
    }
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
        let _ = args.insert("command".into(), json!("ls"));
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
        let _ = args.insert("command".into(), json!("ls"));
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
        assert_eq!(json["cacheReadTokens"], 30);
        assert_eq!(json["cacheCreationTokens"], 10);
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
        assert!(json.get("cacheReadTokens").is_none());
        assert!(json.get("cacheCreationTokens").is_none());
    }

    // ── build_token_record ──────────────────────────────────────────

    #[test]
    fn build_token_record_uses_dynamic_provider() {
        let usage = TokenUsage {
            input_tokens: 100,
            output_tokens: 50,
            ..Default::default()
        };

        let anthropic = build_token_record(&usage, ProviderType::Anthropic, "sess-1", 1, 0);
        assert_eq!(anthropic["source"]["provider"], "anthropic");

        let google = build_token_record(&usage, ProviderType::Google, "sess-1", 1, 0);
        assert_eq!(google["source"]["provider"], "google");

        let openai = build_token_record(&usage, ProviderType::OpenAi, "sess-1", 1, 0);
        assert_eq!(openai["source"]["provider"], "openai");
    }

    #[test]
    fn build_token_record_nested_structure_matches_ios() {
        let usage = TokenUsage {
            input_tokens: 100,
            output_tokens: 50,
            ..Default::default()
        };
        let record = build_token_record(&usage, ProviderType::Anthropic, "sess-1", 3, 0);
        assert!(record.get("source").is_some());
        assert!(record.get("computed").is_some());
        assert!(record.get("meta").is_some());
        assert_eq!(record["meta"]["sessionId"], "sess-1");
        assert_eq!(record["meta"]["turn"], 3);
    }

    #[test]
    fn build_token_record_first_turn_all_new() {
        let usage = TokenUsage {
            input_tokens: 100,
            output_tokens: 50,
            cache_read_tokens: Some(10),
            cache_creation_tokens: Some(5),
            ..Default::default()
        };
        let record = build_token_record(&usage, ProviderType::Anthropic, "s1", 1, 0);
        // contextWindowTokens = input + cacheRead + cacheCreation
        assert_eq!(record["computed"]["contextWindowTokens"], 115);
        // Anthropic: newInputTokens = rawInputTokens only (non-cached)
        assert_eq!(record["computed"]["newInputTokens"], 100);
        assert_eq!(record["computed"]["previousContextBaseline"], 0);
        assert_eq!(record["computed"]["calculationMethod"], "anthropic_cache_aware");
    }

    #[test]
    fn build_token_record_second_turn_delta() {
        let usage = TokenUsage {
            input_tokens: 14,
            output_tokens: 149,
            cache_read_tokens: Some(9521),
            cache_creation_tokens: Some(200),
            ..Default::default()
        };
        // Previous baseline was 9521 (from turn 1 context window)
        let record = build_token_record(&usage, ProviderType::Anthropic, "s1", 2, 9521);
        assert_eq!(record["computed"]["contextWindowTokens"], 9735); // 14 + 9521 + 200
        // Anthropic: newInputTokens = rawInputTokens only (non-cached)
        assert_eq!(record["computed"]["newInputTokens"], 14);
        assert_eq!(record["computed"]["previousContextBaseline"], 9521);
    }

    #[test]
    fn build_token_record_context_shrink_zero_delta() {
        let usage = TokenUsage {
            input_tokens: 5000,
            output_tokens: 100,
            ..Default::default()
        };
        // Previous baseline was 10000, context shrank (compaction)
        let record = build_token_record(&usage, ProviderType::Anthropic, "s1", 3, 10_000);
        assert_eq!(record["computed"]["contextWindowTokens"], 5000);
        // Anthropic: newInputTokens = rawInputTokens only (non-cached)
        assert_eq!(record["computed"]["newInputTokens"], 5000);
    }

    #[test]
    fn build_token_record_google_direct_method() {
        let usage = TokenUsage {
            input_tokens: 5000,
            output_tokens: 200,
            ..Default::default()
        };
        let record = build_token_record(&usage, ProviderType::Google, "s1", 1, 0);
        assert_eq!(record["computed"]["contextWindowTokens"], 5000);
        assert_eq!(record["computed"]["calculationMethod"], "direct");
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
        let record = build_token_record(&usage, ProviderType::Anthropic, "s1", 1, 0);
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
        let record = build_token_record(&usage, ProviderType::Anthropic, "s1", 1, 0);
        assert_eq!(record["source"]["rawCacheReadTokens"], 0);
        assert_eq!(record["source"]["rawCacheCreationTokens"], 0);
    }

}
