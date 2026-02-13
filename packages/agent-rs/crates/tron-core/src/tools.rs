//! Tool definition and result types.
//!
//! Defines the schema for tools that the agent can invoke, plus the result
//! type returned by tool execution.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::content::ToolResultContent;

// ─────────────────────────────────────────────────────────────────────────────
// Tool schema
// ─────────────────────────────────────────────────────────────────────────────

/// JSON Schema-compatible parameter definition for a tool.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ToolParameterSchema {
    /// Top-level JSON Schema type.
    #[serde(rename = "type")]
    pub schema_type: String,
    /// Property definitions (when type is `object`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub properties: Option<serde_json::Map<String, Value>>,
    /// Required property names.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub required: Option<Vec<String>>,
    /// Description of the schema.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// Catch-all for additional JSON Schema properties.
    #[serde(flatten)]
    pub extra: serde_json::Map<String, Value>,
}

/// A tool definition that can be sent to the LLM.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Tool {
    /// Tool name (unique identifier).
    pub name: String,
    /// Human-readable description.
    pub description: String,
    /// JSON Schema for the tool's parameters.
    pub parameters: ToolParameterSchema,
}

// ─────────────────────────────────────────────────────────────────────────────
// Tool result
// ─────────────────────────────────────────────────────────────────────────────

/// Content in a tool result — either a plain string or structured content blocks.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum ToolResultBody {
    /// Plain text result.
    Text(String),
    /// Structured content blocks (text + images).
    Blocks(Vec<ToolResultContent>),
}

/// Result of a tool execution.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TronToolResult {
    /// The tool output content.
    pub content: ToolResultBody,
    /// Optional structured details (tool-specific metadata).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
    /// Whether the execution resulted in an error.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_error: Option<bool>,
    /// If true, stops the agent turn loop immediately after this tool executes.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stop_turn: Option<bool>,
}

/// Tool category for grouping.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ToolCategory {
    /// File system operations.
    Filesystem,
    /// Shell/command execution.
    Shell,
    /// Search operations.
    Search,
    /// Network/HTTP operations.
    Network,
    /// Custom/user-defined.
    Custom,
}

/// Execution contract: how the tool expects to be invoked.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ToolExecutionContract {
    /// Legacy: `execute(tool_call_id, params, signal)`.
    Contextual,
    /// Structured: `execute(params, options)`.
    Options,
}

// ─────────────────────────────────────────────────────────────────────────────
// Factory helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Create a simple text result.
#[must_use]
pub fn text_result(text: impl Into<String>, is_error: bool) -> TronToolResult {
    TronToolResult {
        content: ToolResultBody::Blocks(vec![ToolResultContent::text(text)]),
        details: None,
        is_error: if is_error { Some(true) } else { None },
        stop_turn: None,
    }
}

/// Create an error result.
#[must_use]
pub fn error_result(message: impl Into<String>) -> TronToolResult {
    text_result(message, true)
}

/// Create an image result with optional caption.
#[must_use]
pub fn image_result(
    data: impl Into<String>,
    mime_type: impl Into<String>,
    caption: Option<&str>,
) -> TronToolResult {
    let mut blocks: Vec<ToolResultContent> = Vec::new();
    if let Some(cap) = caption {
        blocks.push(ToolResultContent::text(cap));
    }
    blocks.push(ToolResultContent::image(data, mime_type));
    TronToolResult {
        content: ToolResultBody::Blocks(blocks),
        details: None,
        is_error: None,
        stop_turn: None,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn tool_serde_roundtrip() {
        let tool = Tool {
            name: "bash".into(),
            description: "Execute a shell command".into(),
            parameters: ToolParameterSchema {
                schema_type: "object".into(),
                properties: Some({
                    let mut m = serde_json::Map::new();
                    let _ = m.insert(
                        "command".into(),
                        json!({"type": "string", "description": "The command to run"}),
                    );
                    m
                }),
                required: Some(vec!["command".into()]),
                description: None,
                extra: serde_json::Map::new(),
            },
        };
        let json = serde_json::to_value(&tool).unwrap();
        let back: Tool = serde_json::from_value(json).unwrap();
        assert_eq!(tool, back);
    }

    #[test]
    fn text_result_success() {
        let r = text_result("output", false);
        assert!(r.is_error.is_none());
        assert!(r.stop_turn.is_none());
    }

    #[test]
    fn text_result_error() {
        let r = text_result("failed", true);
        assert_eq!(r.is_error, Some(true));
    }

    #[test]
    fn error_result_has_is_error() {
        let r = error_result("something went wrong");
        assert_eq!(r.is_error, Some(true));
    }

    #[test]
    fn image_result_without_caption() {
        let r = image_result("base64data", "image/png", None);
        match &r.content {
            ToolResultBody::Blocks(blocks) => {
                assert_eq!(blocks.len(), 1);
            }
            ToolResultBody::Text(_) => panic!("expected blocks"),
        }
    }

    #[test]
    fn image_result_with_caption() {
        let r = image_result("base64data", "image/png", Some("Screenshot"));
        match &r.content {
            ToolResultBody::Blocks(blocks) => {
                assert_eq!(blocks.len(), 2);
            }
            ToolResultBody::Text(_) => panic!("expected blocks"),
        }
    }

    #[test]
    fn tool_result_serde_text_body() {
        let r = TronToolResult {
            content: ToolResultBody::Text("plain output".into()),
            details: None,
            is_error: None,
            stop_turn: None,
        };
        let json = serde_json::to_value(&r).unwrap();
        assert_eq!(json["content"], "plain output");
        let back: TronToolResult = serde_json::from_value(json).unwrap();
        assert_eq!(r, back);
    }

    #[test]
    fn tool_result_serde_with_details() {
        let r = TronToolResult {
            content: ToolResultBody::Text("ok".into()),
            details: Some(json!({"bytes_written": 42})),
            is_error: None,
            stop_turn: Some(true),
        };
        let json = serde_json::to_value(&r).unwrap();
        assert_eq!(json["details"]["bytes_written"], 42);
        assert_eq!(json["stopTurn"], true);
    }

    #[test]
    fn tool_category_serde() {
        assert_eq!(
            serde_json::to_string(&ToolCategory::Filesystem).unwrap(),
            "\"filesystem\""
        );
        assert_eq!(
            serde_json::to_string(&ToolCategory::Shell).unwrap(),
            "\"shell\""
        );
    }

    #[test]
    fn tool_execution_contract_serde() {
        assert_eq!(
            serde_json::to_string(&ToolExecutionContract::Contextual).unwrap(),
            "\"contextual\""
        );
        assert_eq!(
            serde_json::to_string(&ToolExecutionContract::Options).unwrap(),
            "\"options\""
        );
    }
}
