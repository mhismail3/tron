//! Content block types.
//!
//! These are the primitive building blocks that appear inside messages.
//! Extracted as a standalone module to break circular dependencies between
//! messages and tools (both reference content types).

use serde::{Deserialize, Serialize};

/// Text content block.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename = "text")]
pub struct TextContent {
    /// The text content.
    pub text: String,
}

/// Image content block (base64-encoded).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename = "image")]
pub struct ImageContent {
    /// Base64-encoded image data.
    pub data: String,
    /// MIME type (e.g. `image/png`).
    #[serde(rename = "mimeType")]
    pub mime_type: String,
}

/// Document content block (base64-encoded PDFs, etc.).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename = "document")]
pub struct DocumentContent {
    /// Base64-encoded document data.
    pub data: String,
    /// MIME type (e.g. `application/pdf`).
    #[serde(rename = "mimeType")]
    pub mime_type: String,
    /// Optional file name.
    #[serde(rename = "fileName", skip_serializing_if = "Option::is_none")]
    pub file_name: Option<String>,
}

/// Thinking content block (Claude extended thinking).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename = "thinking")]
pub struct ThinkingContent {
    /// The thinking text.
    pub thinking: String,
    /// Verification signature.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub signature: Option<String>,
}

/// Content that can appear in user messages.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum UserContent {
    /// Text content.
    #[serde(rename = "text")]
    Text {
        /// The text.
        text: String,
    },
    /// Image content.
    #[serde(rename = "image")]
    Image {
        /// Base64-encoded image data.
        data: String,
        /// MIME type.
        #[serde(rename = "mimeType")]
        mime_type: String,
    },
    /// Document content.
    #[serde(rename = "document")]
    Document {
        /// Base64-encoded document data.
        data: String,
        /// MIME type.
        #[serde(rename = "mimeType")]
        mime_type: String,
        /// Optional file name.
        #[serde(rename = "fileName", skip_serializing_if = "Option::is_none")]
        file_name: Option<String>,
    },
}

/// Content that can appear in assistant messages.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum AssistantContent {
    /// Text content.
    #[serde(rename = "text")]
    Text {
        /// The text.
        text: String,
    },
    /// Thinking content.
    #[serde(rename = "thinking")]
    Thinking {
        /// The thinking text.
        thinking: String,
        /// Verification signature.
        #[serde(skip_serializing_if = "Option::is_none")]
        signature: Option<String>,
    },
    /// Tool use content.
    #[serde(rename = "tool_use")]
    ToolUse {
        /// Tool call ID.
        id: String,
        /// Tool name.
        name: String,
        /// Tool arguments.
        arguments: serde_json::Map<String, serde_json::Value>,
        /// Thought signature (Gemini models).
        #[serde(rename = "thoughtSignature", skip_serializing_if = "Option::is_none")]
        thought_signature: Option<String>,
    },
}

/// Content that can appear in tool result messages.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ToolResultContent {
    /// Text content.
    #[serde(rename = "text")]
    Text {
        /// The text.
        text: String,
    },
    /// Image content.
    #[serde(rename = "image")]
    Image {
        /// Base64-encoded image data.
        data: String,
        /// MIME type.
        #[serde(rename = "mimeType")]
        mime_type: String,
    },
}

// ─────────────────────────────────────────────────────────────────────────────
// Convenience constructors
// ─────────────────────────────────────────────────────────────────────────────

impl TextContent {
    /// Create a new text content block.
    #[must_use]
    pub fn new(text: impl Into<String>) -> Self {
        Self { text: text.into() }
    }
}

impl ImageContent {
    /// Create a new image content block.
    #[must_use]
    pub fn new(data: impl Into<String>, mime_type: impl Into<String>) -> Self {
        Self {
            data: data.into(),
            mime_type: mime_type.into(),
        }
    }
}

impl ThinkingContent {
    /// Create a new thinking content block.
    #[must_use]
    pub fn new(thinking: impl Into<String>) -> Self {
        Self {
            thinking: thinking.into(),
            signature: None,
        }
    }
}

impl UserContent {
    /// Create a text user content block.
    #[must_use]
    pub fn text(text: impl Into<String>) -> Self {
        Self::Text { text: text.into() }
    }

    /// Create an image user content block.
    #[must_use]
    pub fn image(data: impl Into<String>, mime_type: impl Into<String>) -> Self {
        Self::Image {
            data: data.into(),
            mime_type: mime_type.into(),
        }
    }

    /// Returns `true` if this is text content.
    #[must_use]
    pub fn is_text(&self) -> bool {
        matches!(self, Self::Text { .. })
    }

    /// Returns `true` if this is image content.
    #[must_use]
    pub fn is_image(&self) -> bool {
        matches!(self, Self::Image { .. })
    }

    /// Returns the text if this is a text block, `None` otherwise.
    #[must_use]
    pub fn as_text(&self) -> Option<&str> {
        match self {
            Self::Text { text } => Some(text),
            _ => None,
        }
    }
}

impl AssistantContent {
    /// Create a text assistant content block.
    #[must_use]
    pub fn text(text: impl Into<String>) -> Self {
        Self::Text { text: text.into() }
    }

    /// Returns `true` if this is text content.
    #[must_use]
    pub fn is_text(&self) -> bool {
        matches!(self, Self::Text { .. })
    }

    /// Returns `true` if this is thinking content.
    #[must_use]
    pub fn is_thinking(&self) -> bool {
        matches!(self, Self::Thinking { .. })
    }

    /// Returns `true` if this is a tool use block.
    #[must_use]
    pub fn is_tool_use(&self) -> bool {
        matches!(self, Self::ToolUse { .. })
    }

    /// Returns the text if this is a text block, `None` otherwise.
    #[must_use]
    pub fn as_text(&self) -> Option<&str> {
        match self {
            Self::Text { text } => Some(text),
            _ => None,
        }
    }
}

impl ToolResultContent {
    /// Create a text tool result content block.
    #[must_use]
    pub fn text(text: impl Into<String>) -> Self {
        Self::Text { text: text.into() }
    }

    /// Create an image tool result content block.
    #[must_use]
    pub fn image(data: impl Into<String>, mime_type: impl Into<String>) -> Self {
        Self::Image {
            data: data.into(),
            mime_type: mime_type.into(),
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Extract text helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Extract text from user content blocks.
pub fn extract_text_from_user_content(content: &[UserContent]) -> String {
    content
        .iter()
        .filter_map(|c| match c {
            UserContent::Text { text } => Some(text.as_str()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// Extract text from tool result content blocks.
pub fn extract_text_from_tool_result_content(content: &[ToolResultContent]) -> String {
    content
        .iter()
        .filter_map(|c| match c {
            ToolResultContent::Text { text } => Some(text.as_str()),
            ToolResultContent::Image { .. } => None,
        })
        .collect::<Vec<_>>()
        .join("\n")
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // -- TextContent --

    #[test]
    fn text_content_serde_roundtrip() {
        let tc = TextContent::new("hello");
        let json = serde_json::to_value(&tc).unwrap();
        assert_eq!(json, json!({"type": "text", "text": "hello"}));
        let back: TextContent = serde_json::from_value(json).unwrap();
        assert_eq!(back, tc);
    }

    // -- ImageContent --

    #[test]
    fn image_content_serde_roundtrip() {
        let ic = ImageContent::new("base64data", "image/png");
        let json = serde_json::to_value(&ic).unwrap();
        assert_eq!(
            json,
            json!({"type": "image", "data": "base64data", "mimeType": "image/png"})
        );
        let back: ImageContent = serde_json::from_value(json).unwrap();
        assert_eq!(back, ic);
    }

    // -- DocumentContent --

    #[test]
    fn document_content_without_filename() {
        let dc = DocumentContent {
            data: "pdfdata".into(),
            mime_type: "application/pdf".into(),
            file_name: None,
        };
        let json = serde_json::to_value(&dc).unwrap();
        assert_eq!(
            json,
            json!({"type": "document", "data": "pdfdata", "mimeType": "application/pdf"})
        );
    }

    #[test]
    fn document_content_with_filename() {
        let dc = DocumentContent {
            data: "pdfdata".into(),
            mime_type: "application/pdf".into(),
            file_name: Some("report.pdf".into()),
        };
        let json = serde_json::to_value(&dc).unwrap();
        assert_eq!(
            json,
            json!({"type": "document", "data": "pdfdata", "mimeType": "application/pdf", "fileName": "report.pdf"})
        );
    }

    // -- ThinkingContent --

    #[test]
    fn thinking_content_without_signature() {
        let tc = ThinkingContent::new("I think...");
        let json = serde_json::to_value(&tc).unwrap();
        assert_eq!(json, json!({"type": "thinking", "thinking": "I think..."}));
    }

    #[test]
    fn thinking_content_with_signature() {
        let tc = ThinkingContent {
            thinking: "deep thought".into(),
            signature: Some("sig123".into()),
        };
        let json = serde_json::to_value(&tc).unwrap();
        assert_eq!(
            json,
            json!({"type": "thinking", "thinking": "deep thought", "signature": "sig123"})
        );
    }

    // -- UserContent enum --

    #[test]
    fn user_content_text() {
        let uc = UserContent::text("hi");
        assert!(uc.is_text());
        assert!(!uc.is_image());
        assert_eq!(uc.as_text(), Some("hi"));
        let json = serde_json::to_value(&uc).unwrap();
        assert_eq!(json, json!({"type": "text", "text": "hi"}));
    }

    #[test]
    fn user_content_image() {
        let uc = UserContent::image("imgdata", "image/jpeg");
        assert!(uc.is_image());
        assert!(!uc.is_text());
        assert_eq!(uc.as_text(), None);
    }

    #[test]
    fn user_content_document() {
        let uc = UserContent::Document {
            data: "docdata".into(),
            mime_type: "application/pdf".into(),
            file_name: None,
        };
        assert!(!uc.is_text());
    }

    #[test]
    fn user_content_serde_roundtrip() {
        let items = vec![
            UserContent::text("hello"),
            UserContent::image("d", "image/png"),
        ];
        let json = serde_json::to_string(&items).unwrap();
        let back: Vec<UserContent> = serde_json::from_str(&json).unwrap();
        assert_eq!(items, back);
    }

    // -- AssistantContent enum --

    #[test]
    fn assistant_content_text() {
        let ac = AssistantContent::text("response");
        assert!(ac.is_text());
        assert!(!ac.is_thinking());
        assert!(!ac.is_tool_use());
        assert_eq!(ac.as_text(), Some("response"));
    }

    #[test]
    fn assistant_content_thinking() {
        let ac = AssistantContent::Thinking {
            thinking: "hmm".into(),
            signature: None,
        };
        assert!(ac.is_thinking());
    }

    #[test]
    fn assistant_content_tool_use() {
        let ac = AssistantContent::ToolUse {
            id: "call-1".into(),
            name: "bash".into(),
            arguments: serde_json::Map::new(),
            thought_signature: None,
        };
        assert!(ac.is_tool_use());
    }

    #[test]
    fn assistant_content_tool_use_serde() {
        let mut args = serde_json::Map::new();
        let _ = args.insert("command".into(), json!("ls"));
        let ac = AssistantContent::ToolUse {
            id: "call-1".into(),
            name: "bash".into(),
            arguments: args,
            thought_signature: None,
        };
        let json = serde_json::to_value(&ac).unwrap();
        assert_eq!(json["type"], "tool_use");
        assert_eq!(json["name"], "bash");
        assert_eq!(json["arguments"]["command"], "ls");
        let back: AssistantContent = serde_json::from_value(json).unwrap();
        assert_eq!(ac, back);
    }

    #[test]
    fn assistant_content_tool_use_rejects_input_alias() {
        let json = json!({
            "type": "tool_use",
            "id": "toolu_01abc",
            "name": "bash",
            "input": {"command": "ls"}
        });
        let err = serde_json::from_value::<AssistantContent>(json).unwrap_err();
        assert!(err.to_string().contains("arguments"));
    }

    // -- ToolResultContent enum --

    #[test]
    fn tool_result_content_text() {
        let trc = ToolResultContent::text("output");
        let json = serde_json::to_value(&trc).unwrap();
        assert_eq!(json, json!({"type": "text", "text": "output"}));
    }

    #[test]
    fn tool_result_content_image_serde() {
        let trc = ToolResultContent::image("imgdata", "image/png");
        let json = serde_json::to_value(&trc).unwrap();
        assert_eq!(
            json,
            json!({"type": "image", "data": "imgdata", "mimeType": "image/png"})
        );
        let back: ToolResultContent = serde_json::from_value(json).unwrap();
        assert_eq!(trc, back);
    }

    // -- extract_text helpers --

    #[test]
    fn extract_text_from_user_content_mixed() {
        let content = vec![
            UserContent::text("first"),
            UserContent::image("d", "image/png"),
            UserContent::text("second"),
        ];
        assert_eq!(extract_text_from_user_content(&content), "first\nsecond");
    }

    #[test]
    fn extract_text_from_user_content_empty() {
        let content: Vec<UserContent> = vec![];
        assert_eq!(extract_text_from_user_content(&content), "");
    }

    #[test]
    fn extract_text_from_tool_result_content_mixed() {
        let content = vec![
            ToolResultContent::text("line1"),
            ToolResultContent::image("d", "image/png"),
            ToolResultContent::text("line2"),
        ];
        assert_eq!(
            extract_text_from_tool_result_content(&content),
            "line1\nline2"
        );
    }
}
