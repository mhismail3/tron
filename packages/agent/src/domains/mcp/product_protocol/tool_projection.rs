//! Conversion from MCP results into Tron model-call result payloads.

use serde_json::json;

use crate::domains::mcp::types::{McpContentBlock, McpToolResult};
use crate::shared::tools::{CapabilityResult, ToolResultBody};

/// Convert an MCP tool result to a `CapabilityResult` payload used by `execute`.
pub fn mcp_result_to_tron_result(
    result: &McpToolResult,
    server: &str,
    tool: &str,
) -> CapabilityResult {
    let content = if result.content.is_empty() {
        "(no output)".to_string()
    } else {
        let mut text_parts = Vec::new();
        for block in &result.content {
            match block {
                McpContentBlock::Text { text } => text_parts.push(text.clone()),
                McpContentBlock::Image { data, mime_type } => {
                    text_parts.push(format!("[Image: {mime_type}, {} bytes]", data.len()));
                }
                McpContentBlock::Resource { resource } => {
                    text_parts.push(format!("[Resource: {resource}]"));
                }
            }
        }
        text_parts.join("\n")
    };

    CapabilityResult {
        content: ToolResultBody::Blocks(vec![crate::shared::content::ToolResultContent::text(
            content,
        )]),
        details: Some(json!({
            "mcpServer": server,
            "mcpTool": tool,
        })),
        is_error: if result.is_error { Some(true) } else { None },
        stop_turn: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn converts_text_blocks() {
        let result = McpToolResult {
            content: vec![McpContentBlock::Text {
                text: "hello".to_owned(),
            }],
            is_error: false,
        };
        let converted = mcp_result_to_tron_result(&result, "server", "query");
        assert_eq!(converted.is_error, None);
        assert!(converted.details.unwrap()["mcpServer"] == "server");
    }
}
