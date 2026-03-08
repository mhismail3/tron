//! `SetClipboard` tool — copy text to the user's iOS clipboard.
//!
//! Fire-and-forget: iOS handles the clipboard write when it receives the
//! `tool_execution_start` event (same pattern as `OpenURL`).

use async_trait::async_trait;
use serde_json::{Value, json};
use tron_core::tools::{Tool, ToolCategory, ToolResultBody, TronToolResult};

use crate::errors::ToolError;
use crate::traits::{ToolContext, TronTool};
use crate::utils::schema::ToolSchemaBuilder;
use crate::utils::validation::{get_optional_string, validate_required_string};

/// Copy text to the user's iOS clipboard.
pub struct SetClipboardTool;

impl SetClipboardTool {
    pub fn new() -> Self {
        Self
    }
}

#[async_trait]
impl TronTool for SetClipboardTool {
    fn name(&self) -> &str {
        "SetClipboard"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Custom
    }

    fn is_interactive(&self) -> bool {
        true
    }

    fn definition(&self) -> Tool {
        ToolSchemaBuilder::new(
            "SetClipboard",
            "Copy text to the user's iOS clipboard for pasting into other apps.\n\n\
             Use when the user needs content ready to paste: code snippets, URLs, addresses, \
             extracted data, formatted text. The content appears on their clipboard immediately.",
        )
        .required_property(
            "content",
            json!({"type": "string", "description": "Text to copy to clipboard"}),
        )
        .property(
            "label",
            json!({"type": "string", "description": "Brief label describing what was copied (shown in UI)"}),
        )
        .build()
    }

    async fn execute(
        &self,
        params: Value,
        _ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let content = match validate_required_string(&params, "content", "clipboard content") {
            Ok(c) => c,
            Err(e) => return Ok(e),
        };

        let label = get_optional_string(&params, "label").unwrap_or_else(|| "Text".into());

        // Truncate display label for the tool result (content itself is unbounded)
        let display_label = if label.len() > 100 {
            format!("{}...", &label[..97])
        } else {
            label.clone()
        };

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![
                tron_core::content::ToolResultContent::text(format!(
                    "Copied to clipboard: {display_label}"
                )),
            ]),
            details: Some(json!({
                "content": content,
                "label": label,
            })),
            is_error: None,
            stop_turn: None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::{extract_text, make_ctx};
    use serde_json::json;

    #[tokio::test]
    async fn valid_clipboard_copy() {
        let tool = SetClipboardTool::new();
        let r = tool
            .execute(
                json!({"content": "hello world", "label": "Greeting"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        assert!(extract_text(&r).contains("Copied to clipboard"));
        assert_eq!(r.details.unwrap()["label"], "Greeting");
    }

    #[tokio::test]
    async fn missing_content_error() {
        let tool = SetClipboardTool::new();
        let r = tool
            .execute(json!({"label": "test"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn label_defaults_to_text() {
        let tool = SetClipboardTool::new();
        let r = tool
            .execute(json!({"content": "data"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.details.unwrap()["label"], "Text");
    }

    #[tokio::test]
    async fn tool_metadata() {
        let tool = SetClipboardTool::new();
        assert_eq!(tool.name(), "SetClipboard");
        assert_eq!(tool.category(), ToolCategory::Custom);
        assert!(tool.is_interactive());
        assert!(!tool.stops_turn());
    }

    #[tokio::test]
    async fn content_preserved_in_details() {
        let tool = SetClipboardTool::new();
        let content = "fn main() { println!(\"hello\"); }";
        let r = tool
            .execute(json!({"content": content}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.details.unwrap()["content"], content);
    }

    #[tokio::test]
    async fn empty_content_rejected() {
        let tool = SetClipboardTool::new();
        let r = tool
            .execute(json!({"content": ""}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }
}
