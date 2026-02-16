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
                let truncated = tron_core::text::truncate_with_suffix(first_line, 120, "...");
                format!("{name}: {truncated}")
            } else {
                name.clone()
            }
        })
        .collect()
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
                    let _ = obj.remove("arguments");
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

/// ADAPTER(tool-compat): Normalize `AskUserQuestion` options from strings to objects.
///
/// The LLM may still send string options `["A", "B"]` even though the schema
/// specifies object items. This normalizes them to `[{"label": "A"}, {"label": "B"}]`
/// so iOS can always parse structured option objects.
///
/// REMOVE: When the schema has been live long enough that LLMs always produce objects.
pub fn adapt_ask_user_options(options: &mut Value) {
    if let Some(arr) = options.as_array_mut() {
        for item in arr.iter_mut() {
            if let Some(s) = item.as_str().map(String::from) {
                *item = json!({"label": s});
            }
        }
    }
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

    // --- adapt_ask_user_options ---

    #[test]
    fn adapt_ask_user_string_options() {
        let mut options = json!(["A", "B"]);
        adapt_ask_user_options(&mut options);
        assert_eq!(options, json!([{"label": "A"}, {"label": "B"}]));
    }

    #[test]
    fn adapt_ask_user_object_options_passthrough() {
        let mut options = json!([{"label": "A"}, {"label": "B"}]);
        let expected = options.clone();
        adapt_ask_user_options(&mut options);
        assert_eq!(options, expected);
    }

    #[test]
    fn adapt_ask_user_mixed_options() {
        let mut options = json!(["A", {"label": "B"}]);
        adapt_ask_user_options(&mut options);
        assert_eq!(options, json!([{"label": "A"}, {"label": "B"}]));
    }

    #[test]
    fn adapt_ask_user_empty_array() {
        let mut options = json!([]);
        adapt_ask_user_options(&mut options);
        assert_eq!(options, json!([]));
    }
}
