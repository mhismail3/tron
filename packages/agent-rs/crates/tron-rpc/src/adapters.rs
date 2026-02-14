//! ADAPTER(ios-compat): Temporary compatibility adapters for iOS client.
//!
//! This entire module exists to transform Rust server responses into the format
//! the iOS app currently expects. Every public function is tagged for future removal.
//!
//! To find all adapter usage:  `grep -rn "ADAPTER(ios-compat)" packages/agent-rs/`
//! To remove: delete this module, remove `pub mod adapters` from lib.rs,
//!            and revert each tagged call site (instructions inline at each site).

use std::collections::HashMap;

use serde_json::{json, Value};
use tron_core::tools::Tool;

/// ADAPTER(ios-compat): iOS splits tools on ":" to show name + description in context sheet.
///
/// Converts bare tool names like `["bash", "read"]` into formatted strings
/// like `["bash: Execute shell commands", "read: Read file contents"]`.
///
/// REMOVE: delete this function and revert call sites to use bare names.
pub fn adapt_tools_content(bare_names: &[String], tool_defs: &[Tool]) -> Vec<String> {
    let lookup: HashMap<&str, &str> = tool_defs
        .iter()
        .map(|t| (t.name.as_str(), t.description.as_str()))
        .collect();

    bare_names
        .iter()
        .map(|name| {
            if let Some(desc) = lookup.get(name.as_str()) {
                let first_line = desc.lines().next().unwrap_or(desc);
                let truncated = if first_line.len() > 120 {
                    format!("{}...", &first_line[..117])
                } else {
                    first_line.to_string()
                };
                format!("{name}: {truncated}")
            } else {
                name.clone()
            }
        })
        .collect()
}

/// ADAPTER(ios-compat): iOS reads `tokenRecord.source.rawXxxTokens` for the stats line.
///
/// Builds the nested token record structure that iOS `ConsolidatedAnalytics.extractTokenUsage()`
/// expects from both WebSocket `turn_end` events and persisted assistant message payloads.
///
/// REMOVE: delete this function; iOS should read `tokenUsage` directly.
pub fn build_token_record(
    input: u64,
    output: u64,
    cache_read: Option<u64>,
    cache_create: Option<u64>,
    provider: &str,
    session_id: &str,
    turn: u32,
) -> Value {
    let now = chrono::Utc::now().to_rfc3339();
    let cr = cache_read.unwrap_or(0);
    let cc = cache_create.unwrap_or(0);
    // Anthropic API: input/cacheRead/cacheCreation are MUTUALLY EXCLUSIVE.
    // input = non-cached new input only, cacheRead = reused from prior context,
    // cacheCreation = new tokens written to cache. Total context = sum of all three.
    let context_window = input + cr + cc;
    let new_input = input + cc;

    json!({
        "source": {
            "rawInputTokens": input,
            "rawOutputTokens": output,
            "rawCacheReadTokens": cr,
            "rawCacheCreationTokens": cc,
            "rawCacheCreation5mTokens": 0,
            "rawCacheCreation1hTokens": 0,
            "provider": provider,
            "timestamp": now,
        },
        "computed": {
            "contextWindowTokens": context_window,
            "newInputTokens": new_input,
            "previousContextBaseline": cr,
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

/// ADAPTER(ios-compat): iOS expects `input` not `arguments` on `tool_use` content blocks.
///
/// Persistence stores assistant content with `"input"` (Anthropic API wire format)
/// because iOS reads it directly. The Rust typed `AssistantContent::ToolUse` uses
/// `arguments` internally. Currently handled by:
///
/// 1. **Write path**: `tron_runtime::pipeline::persistence::build_content_json()` renames
///    `arguments` → `input` when persisting `message.assistant` events.
/// 2. **Read path**: `#[serde(alias = "input")]` on `AssistantContent::ToolUse.arguments`
///    allows deserialization from either field name during reconstruction.
///
/// REMOVE: When iOS is updated to read `arguments` natively, remove the alias from
/// `AssistantContent`, remove the rename in `build_content_json`, and delete this comment.
/// The Rust server should use `arguments` consistently; iOS adapts to the server's format.
pub fn adapt_assistant_content_for_ios(content: &mut [Value]) {
    for block in content.iter_mut() {
        if block.get("type").and_then(Value::as_str) == Some("tool_use") {
            if let Some(args) = block.get("arguments").cloned() {
                if let Some(obj) = block.as_object_mut() {
                    obj.remove("arguments");
                    let _ = obj.insert("input".into(), args);
                }
            }
        }
    }
}

/// ADAPTER(ios-compat): iOS expects `totalCount` in `skill.list` response.
///
/// Mutates the response JSON to add `totalCount` field alongside `skills` array.
///
/// REMOVE: delete this function; revert call site to `Ok(json!({ "skills": skills }))`.
pub fn adapt_skill_list(response: &mut Value) {
    if let Some(arr) = response.get("skills").and_then(Value::as_array) {
        response["totalCount"] = json!(arr.len());
    }
}

/// ADAPTER(ios-compat): iOS reads `tokenRecord` from `turn_end` events for stats display.
///
/// If `data` contains `tokenUsage`, extracts the fields and injects a `tokenRecord`
/// in the nested format iOS expects.
///
/// REMOVE: delete this function and its call site; iOS should read `tokenUsage` directly.
pub fn adapt_turn_end_data(data: &mut Value, session_id: &str, turn: u32) {
    let usage = &data["tokenUsage"];
    if usage.is_null() {
        return;
    }

    let input = usage["inputTokens"].as_u64().unwrap_or(0);
    let output = usage["outputTokens"].as_u64().unwrap_or(0);
    let cache_read = usage["cacheReadTokens"].as_u64();
    let cache_create = usage["cacheCreationTokens"].as_u64();

    data["tokenRecord"] = build_token_record(
        input,
        output,
        cache_read,
        cache_create,
        "anthropic",
        session_id,
        turn,
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use tron_core::tools::{Tool, ToolParameterSchema};

    fn make_tool(name: &str, desc: &str) -> Tool {
        Tool {
            name: name.into(),
            description: desc.into(),
            parameters: ToolParameterSchema {
                schema_type: "object".into(),
                properties: None,
                required: None,
                description: None,
                extra: serde_json::Map::new(),
            },
        }
    }

    // --- adapt_tools_content ---

    #[test]
    fn adapt_tools_content_adds_descriptions() {
        let names = vec!["bash".into(), "read".into()];
        let tools = vec![
            make_tool("bash", "Execute shell commands"),
            make_tool("read", "Read file contents"),
        ];
        let result = adapt_tools_content(&names, &tools);
        assert_eq!(result[0], "bash: Execute shell commands");
        assert_eq!(result[1], "read: Read file contents");
    }

    #[test]
    fn adapt_tools_content_unknown_passthrough() {
        let names = vec!["unknown_tool".into()];
        let tools = vec![make_tool("bash", "Execute shell commands")];
        let result = adapt_tools_content(&names, &tools);
        assert_eq!(result[0], "unknown_tool");
    }

    #[test]
    fn adapt_tools_content_empty() {
        let result = adapt_tools_content(&[], &[]);
        assert!(result.is_empty());
    }

    #[test]
    fn adapt_tools_content_multiline_description_uses_first_line() {
        let names = vec!["bash".into()];
        let tools = vec![make_tool("bash", "Execute shell commands\nWith great power comes great responsibility")];
        let result = adapt_tools_content(&names, &tools);
        assert_eq!(result[0], "bash: Execute shell commands");
    }

    // --- build_token_record ---

    #[test]
    fn build_token_record_has_source_computed_meta() {
        let record = build_token_record(100, 50, Some(10), Some(5), "anthropic", "s1", 1);
        assert!(record.get("source").is_some());
        assert!(record.get("computed").is_some());
        assert!(record.get("meta").is_some());
    }

    #[test]
    fn build_token_record_source_raw_fields() {
        let record = build_token_record(100, 50, Some(10), Some(5), "anthropic", "s1", 1);
        let source = &record["source"];
        assert_eq!(source["rawInputTokens"], 100);
        assert_eq!(source["rawOutputTokens"], 50);
        assert_eq!(source["rawCacheReadTokens"], 10);
        assert_eq!(source["rawCacheCreationTokens"], 5);
        assert_eq!(source["rawCacheCreation5mTokens"], 0);
        assert_eq!(source["rawCacheCreation1hTokens"], 0);
        assert_eq!(source["provider"], "anthropic");
        assert!(source["timestamp"].is_string());
    }

    #[test]
    fn build_token_record_cache_none_defaults_zero() {
        let record = build_token_record(100, 50, None, None, "anthropic", "s1", 1);
        assert_eq!(record["source"]["rawCacheReadTokens"], 0);
        assert_eq!(record["source"]["rawCacheCreationTokens"], 0);
    }

    #[test]
    fn build_token_record_computed_context_window() {
        let record = build_token_record(100, 50, Some(10), Some(5), "anthropic", "s1", 1);
        let computed = &record["computed"];
        // contextWindowTokens = input + cacheRead + cacheCreation (mutually exclusive)
        assert_eq!(computed["contextWindowTokens"], 115); // 100 + 10 + 5
        // newInputTokens = input + cacheCreation (non-cached-read = new content)
        assert_eq!(computed["newInputTokens"], 105); // 100 + 5
        assert_eq!(computed["previousContextBaseline"], 10); // cacheRead = prior context
        assert_eq!(computed["calculationMethod"], "default");
    }

    #[test]
    fn build_token_record_heavy_cache_read_nonzero_new_input() {
        // Simulates turn 2+: most input comes from cache, small new input
        let record = build_token_record(14, 149, Some(9521), Some(200), "anthropic", "s1", 2);
        let computed = &record["computed"];
        assert_eq!(computed["contextWindowTokens"], 9735); // 14 + 9521 + 200
        assert_eq!(computed["newInputTokens"], 214); // 14 + 200 (NOT 0)
        assert_eq!(computed["previousContextBaseline"], 9521);
    }

    #[test]
    fn build_token_record_meta_has_turn_and_session() {
        let record = build_token_record(100, 50, None, None, "anthropic", "sess-42", 3);
        let meta = &record["meta"];
        assert_eq!(meta["turn"], 3);
        assert_eq!(meta["sessionId"], "sess-42");
        assert!(meta["extractedAt"].is_string());
        assert!(meta["normalizedAt"].is_string());
    }

    // --- adapt_assistant_content_for_ios ---

    #[test]
    fn adapt_assistant_content_renames_arguments_to_input() {
        let mut content = vec![
            json!({"type": "text", "text": "I'll run that"}),
            json!({"type": "tool_use", "id": "tc1", "name": "bash", "arguments": {"cmd": "ls"}}),
        ];
        adapt_assistant_content_for_ios(&mut content);
        // text block unchanged
        assert_eq!(content[0]["text"], "I'll run that");
        // tool_use: arguments renamed to input
        assert!(content[1].get("arguments").is_none());
        assert_eq!(content[1]["input"]["cmd"], "ls");
    }

    #[test]
    fn adapt_assistant_content_already_has_input_unchanged() {
        let mut content = vec![
            json!({"type": "tool_use", "id": "tc1", "name": "bash", "input": {"cmd": "ls"}}),
        ];
        adapt_assistant_content_for_ios(&mut content);
        // Already has input, no arguments to rename
        assert_eq!(content[0]["input"]["cmd"], "ls");
    }

    // --- adapt_skill_list ---

    #[test]
    fn adapt_skill_list_adds_total_count() {
        let mut response = json!({ "skills": [{"name": "a"}, {"name": "b"}] });
        adapt_skill_list(&mut response);
        assert_eq!(response["totalCount"], 2);
    }

    #[test]
    fn adapt_skill_list_empty_skills() {
        let mut response = json!({ "skills": [] });
        adapt_skill_list(&mut response);
        assert_eq!(response["totalCount"], 0);
    }

    // --- adapt_turn_end_data ---

    #[test]
    fn adapt_turn_end_adds_token_record() {
        let mut data = json!({
            "turn": 2,
            "duration": 5000,
            "tokenUsage": {
                "inputTokens": 100,
                "outputTokens": 50,
                "cacheReadTokens": 10,
            }
        });
        adapt_turn_end_data(&mut data, "s1", 2);
        assert!(data["tokenRecord"]["source"]["rawInputTokens"].is_number());
        assert_eq!(data["tokenRecord"]["source"]["rawInputTokens"], 100);
        assert_eq!(data["tokenRecord"]["source"]["rawOutputTokens"], 50);
        assert_eq!(data["tokenRecord"]["source"]["rawCacheReadTokens"], 10);
    }

    #[test]
    fn adapt_turn_end_no_usage_noop() {
        let mut data = json!({ "turn": 1, "duration": 100 });
        adapt_turn_end_data(&mut data, "s1", 1);
        assert!(data.get("tokenRecord").is_none());
    }
}
