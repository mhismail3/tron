//! Model-facing tool definitions and result types.
//!
//! Providers still use their native "tool/function call" vocabulary at the
//! provider-protocol boundary, but the shared runtime speaks model tools
//! and canonical tool invocation results.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::shared::protocol::content::ToolResultContent;
use crate::shared::server::failure::FailureEnvelope;

// ─────────────────────────────────────────────────────────────────────────────
// ModelTool schema
// ─────────────────────────────────────────────────────────────────────────────

/// JSON Schema-compatible parameter definition for a model tool.
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

/// A model-facing tool definition that can be sent to the LLM.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ModelTool {
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

/// Result of a tool invocation.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolResult {
    /// Tool output content.
    pub content: ToolResultBody,
    /// Optional structured details (tool-specific metadata).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
    /// Whether the execution resulted in an error.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_error: Option<bool>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Factory helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Create a simple text result.
#[must_use]
pub fn text_result(text: impl Into<String>, is_error: bool) -> ToolResult {
    ToolResult {
        content: ToolResultBody::Blocks(vec![ToolResultContent::text(text)]),
        details: None,
        is_error: if is_error { Some(true) } else { None },
    }
}

/// Create a canonical failure result.
#[must_use]
pub fn failure_result(failure: &FailureEnvelope) -> ToolResult {
    ToolResult {
        content: ToolResultBody::Blocks(vec![ToolResultContent::text(failure.message.clone())]),
        details: Some(failure.details_with_failure()),
        is_error: Some(true),
    }
}

/// Create an image result with optional caption.
#[must_use]
pub fn image_result(
    data: impl Into<String>,
    mime_type: impl Into<String>,
    caption: Option<&str>,
) -> ToolResult {
    let mut blocks: Vec<ToolResultContent> = Vec::new();
    if let Some(cap) = caption {
        blocks.push(ToolResultContent::text(cap));
    }
    blocks.push(ToolResultContent::image(data, mime_type));
    ToolResult {
        content: ToolResultBody::Blocks(blocks),
        details: None,
        is_error: None,
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
        let tool = ModelTool {
            name: "test_tool".into(),
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
        let back: ModelTool = serde_json::from_value(json).unwrap();
        assert_eq!(tool, back);
    }

    #[test]
    fn text_result_success() {
        let r = text_result("output", false);
        assert!(r.is_error.is_none());
    }

    #[test]
    fn text_result_error() {
        let r = text_result("failed", true);
        assert_eq!(r.is_error, Some(true));
    }

    #[test]
    fn failure_result_has_canonical_details() {
        let failure = FailureEnvelope::new(
            "RUNTIME_TOOL_ERROR",
            crate::shared::server::failure::FailureCategory::Tool,
            "something went wrong",
            false,
            false,
            crate::shared::server::failure::FailureOrigin::Tool,
        );
        let r = failure_result(&failure);
        assert_eq!(r.is_error, Some(true));
        assert_eq!(
            r.details.as_ref().unwrap()["failure"]["code"],
            "RUNTIME_TOOL_ERROR"
        );
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
        let r = ToolResult {
            content: ToolResultBody::Text("plain output".into()),
            details: None,
            is_error: None,
        };
        let json = serde_json::to_value(&r).unwrap();
        assert_eq!(json["content"], "plain output");
        let back: ToolResult = serde_json::from_value(json).unwrap();
        assert_eq!(r, back);
    }

    #[test]
    fn tool_result_serde_with_details() {
        let r = ToolResult {
            content: ToolResultBody::Text("ok".into()),
            details: Some(json!({"bytes_written": 42})),
            is_error: None,
        };
        let json = serde_json::to_value(&r).unwrap();
        assert_eq!(json["details"]["bytes_written"], 42);
    }
}
