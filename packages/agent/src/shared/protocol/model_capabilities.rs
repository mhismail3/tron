//! Model-facing capability primitive definitions and result types.
//!
//! Providers still use their native "tool/function call" vocabulary at the
//! provider-protocol boundary, but the shared runtime speaks model capabilities
//! and canonical capability invocation results.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::shared::protocol::content::CapabilityResultContent;

// ─────────────────────────────────────────────────────────────────────────────
// ModelCapability schema
// ─────────────────────────────────────────────────────────────────────────────

/// JSON Schema-compatible parameter definition for a model capability.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct CapabilityParameterSchema {
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

/// A model-facing capability definition that can be sent to the LLM.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ModelCapability {
    /// Capability name (unique identifier).
    pub name: String,
    /// Human-readable description.
    pub description: String,
    /// JSON Schema for the capability's parameters.
    pub parameters: CapabilityParameterSchema,
}

// ─────────────────────────────────────────────────────────────────────────────
// Capability result
// ─────────────────────────────────────────────────────────────────────────────

/// Content in a capability result — either a plain string or structured content blocks.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum CapabilityResultBody {
    /// Plain text result.
    Text(String),
    /// Structured content blocks (text + images).
    Blocks(Vec<CapabilityResultContent>),
}

/// Result of a capability invocation.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CapabilityResult {
    /// Capability output content.
    pub content: CapabilityResultBody,
    /// Optional structured details (capability-specific metadata).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
    /// Whether the execution resulted in an error.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_error: Option<bool>,
    /// If true, stops the agent turn loop immediately after this invocation completes.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stop_turn: Option<bool>,
}

/// ModelCapability category for grouping.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CapabilityCategory {
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

// ─────────────────────────────────────────────────────────────────────────────
// Factory helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Create a simple text result.
#[must_use]
pub fn text_result(text: impl Into<String>, is_error: bool) -> CapabilityResult {
    CapabilityResult {
        content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(text)]),
        details: None,
        is_error: if is_error { Some(true) } else { None },
        stop_turn: None,
    }
}

/// Create an error result.
#[must_use]
pub fn error_result(message: impl Into<String>) -> CapabilityResult {
    text_result(message, true)
}

/// Create an image result with optional caption.
#[must_use]
pub fn image_result(
    data: impl Into<String>,
    mime_type: impl Into<String>,
    caption: Option<&str>,
) -> CapabilityResult {
    let mut blocks: Vec<CapabilityResultContent> = Vec::new();
    if let Some(cap) = caption {
        blocks.push(CapabilityResultContent::text(cap));
    }
    blocks.push(CapabilityResultContent::image(data, mime_type));
    CapabilityResult {
        content: CapabilityResultBody::Blocks(blocks),
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
    fn capability_serde_roundtrip() {
        let capability = ModelCapability {
            name: "execute".into(),
            description: "Execute a shell command".into(),
            parameters: CapabilityParameterSchema {
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
        let json = serde_json::to_value(&capability).unwrap();
        let back: ModelCapability = serde_json::from_value(json).unwrap();
        assert_eq!(capability, back);
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
            CapabilityResultBody::Blocks(blocks) => {
                assert_eq!(blocks.len(), 1);
            }
            CapabilityResultBody::Text(_) => panic!("expected blocks"),
        }
    }

    #[test]
    fn image_result_with_caption() {
        let r = image_result("base64data", "image/png", Some("Screenshot"));
        match &r.content {
            CapabilityResultBody::Blocks(blocks) => {
                assert_eq!(blocks.len(), 2);
            }
            CapabilityResultBody::Text(_) => panic!("expected blocks"),
        }
    }

    #[test]
    fn capability_result_serde_text_body() {
        let r = CapabilityResult {
            content: CapabilityResultBody::Text("plain output".into()),
            details: None,
            is_error: None,
            stop_turn: None,
        };
        let json = serde_json::to_value(&r).unwrap();
        assert_eq!(json["content"], "plain output");
        let back: CapabilityResult = serde_json::from_value(json).unwrap();
        assert_eq!(r, back);
    }

    #[test]
    fn capability_result_serde_with_details() {
        let r = CapabilityResult {
            content: CapabilityResultBody::Text("ok".into()),
            details: Some(json!({"bytes_written": 42})),
            is_error: None,
            stop_turn: Some(true),
        };
        let json = serde_json::to_value(&r).unwrap();
        assert_eq!(json["details"]["bytes_written"], 42);
        assert_eq!(json["stopTurn"], true);
    }

    #[test]
    fn capability_category_serde() {
        assert_eq!(
            serde_json::to_string(&CapabilityCategory::Filesystem).unwrap(),
            "\"filesystem\""
        );
        assert_eq!(
            serde_json::to_string(&CapabilityCategory::Shell).unwrap(),
            "\"shell\""
        );
    }
}
