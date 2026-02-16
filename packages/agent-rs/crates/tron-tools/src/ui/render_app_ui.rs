//! `RenderAppUI` tool — renders custom UI in the iOS app.
//!
//! Accepts a UI component tree and renders it as a sheet in the app.
//! This is an interactive, turn-stopping tool.

use async_trait::async_trait;
use serde_json::{json, Value};
use tron_core::tools::{
    Tool, ToolCategory, ToolParameterSchema, ToolResultBody, TronToolResult, error_result,
};
use crate::errors::ToolError;
use crate::traits::{ToolContext, TronTool};
use crate::utils::validation::get_optional_string;

/// The `RenderAppUI` tool renders custom UI components in the iOS app.
pub struct RenderAppUITool;

impl RenderAppUITool {
    /// Create a new `RenderAppUI` tool.
    pub fn new() -> Self {
        Self
    }
}

impl Default for RenderAppUITool {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl TronTool for RenderAppUITool {
    fn name(&self) -> &str {
        "RenderAppUI"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Custom
    }

    fn is_interactive(&self) -> bool {
        true
    }

    fn stops_turn(&self) -> bool {
        true
    }

    fn definition(&self) -> Tool {
        Tool {
            name: "RenderAppUI".into(),
            description: "Render a native iOS UI interface for the user to interact with.\n\n\
Use this tool to create custom interfaces when you need to:\n\
- Build interactive forms or settings screens\n\
- Display structured data with charts, lists, or tables\n\
- Create multi-step wizards or workflows\n\
- Present options with buttons, toggles, or sliders\n\
- Show progress or status dashboards\n\n\
The UI renders as a native SwiftUI sheet on iOS with liquid glass styling.\n\n\
## Usage Pattern\n\
1. Call RenderAppUI with your UI definition\n\
2. The iOS app renders the UI as a sheet\n\
3. When user interacts: button taps return actionId, state changes return bindingId + value\n\
4. You can update the UI by calling RenderAppUI again with the same canvasId\n\n\
## Tips\n\
- Use semantic colors: \"primary\", \"secondary\", \"accent\", \"destructive\"\n\
- Keep UIs simple and focused on the task\n\
- Use Sections to group related controls\n\n\
IMPORTANT: After calling this tool, do NOT output additional text. The UI will be \
presented to the user, and their response will come back as a new message.".into(),
            parameters: ToolParameterSchema {
                schema_type: "object".into(),
                properties: Some({
                    let mut m = serde_json::Map::new();
                    let _ = m.insert("ui".into(), json!({"type": "object", "description": "Root UI component tree"}));
                    let _ = m.insert("canvasId".into(), json!({"type": "string", "description": "Canvas ID (auto-generated if omitted)"}));
                    let _ = m.insert("title".into(), json!({"type": "string", "description": "Sheet toolbar title"}));
                    let _ = m.insert("state".into(), json!({"type": "object", "description": "Initial binding values"}));
                    m
                }),
                required: Some(vec!["ui".into()]),
                description: None,
                extra: serde_json::Map::new(),
            },
        }
    }

    async fn execute(
        &self,
        params: Value,
        _ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let ui = match params.get("ui") {
            Some(u) if u.is_object() => u,
            _ => return Ok(error_result("Missing required parameter: ui (must be an object)")),
        };

        let title = get_optional_string(&params, "title");
        let canvas_id = get_optional_string(&params, "canvasId")
            .unwrap_or_else(|| generate_canvas_id(title.as_deref(), ui));
        let state = params.get("state").cloned();

        // Count interactive components
        let component_counts = count_components(ui);

        let summary = format!(
            "Rendered UI (canvas: {canvas_id}): {component_counts} components"
        );

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![
                tron_core::content::ToolResultContent::text(summary),
            ]),
            details: Some(json!({
                "canvasId": canvas_id,
                "title": title,
                "state": state,
                "componentCount": component_counts,
            })),
            is_error: None,
            stop_turn: Some(true),
        })
    }
}

fn generate_canvas_id(title: Option<&str>, _ui: &Value) -> String {
    let prefix = title.map_or_else(
        || "canvas".into(),
        |t| {
            t.split_whitespace()
                .take(3)
                .map(str::to_lowercase)
                .collect::<Vec<_>>()
                .join("-")
        },
    );

    // Generate 8-char hex suffix using timestamp + hash
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    #[allow(clippy::cast_possible_truncation)]
    let suffix = format!("{:08x}", now as u32);
    format!("{prefix}-{suffix}")
}

fn count_components(ui: &Value) -> usize {
    match ui {
        Value::Object(map) => {
            let mut count = 1;
            if let Some(children) = map.get("children").and_then(Value::as_array) {
                for child in children {
                    count += count_components(child);
                }
            }
            count
        }
        Value::Array(arr) => arr.iter().map(count_components).sum(),
        _ => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_ctx() -> ToolContext {
        ToolContext {
            tool_call_id: "call-1".into(),
            session_id: "sess-1".into(),
            working_directory: "/tmp".into(),
            cancellation: tokio_util::sync::CancellationToken::new(),
            subagent_depth: 0,
            subagent_max_depth: 0,
        }
    }

    #[tokio::test]
    async fn valid_ui_returns_stop_turn() {
        let tool = RenderAppUITool::new();
        let r = tool.execute(json!({"ui": {"type": "VStack", "children": []}}), &make_ctx()).await.unwrap();
        assert_eq!(r.stop_turn, Some(true));
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn is_interactive_returns_true() {
        let tool = RenderAppUITool::new();
        assert!(tool.is_interactive());
    }

    #[tokio::test]
    async fn stops_turn_returns_true() {
        let tool = RenderAppUITool::new();
        assert!(tool.stops_turn());
    }

    #[tokio::test]
    async fn canvas_id_auto_generated() {
        let tool = RenderAppUITool::new();
        let r = tool.execute(json!({"ui": {"type": "VStack"}}), &make_ctx()).await.unwrap();
        let d = r.details.unwrap();
        let canvas_id = d["canvasId"].as_str().unwrap();
        assert!(canvas_id.starts_with("canvas-"));
        assert!(canvas_id.len() > 10);
    }

    #[tokio::test]
    async fn canvas_id_preserved() {
        let tool = RenderAppUITool::new();
        let r = tool.execute(json!({"ui": {"type": "VStack"}, "canvasId": "my-canvas"}), &make_ctx()).await.unwrap();
        assert_eq!(r.details.unwrap()["canvasId"], "my-canvas");
    }

    #[tokio::test]
    async fn title_extracted() {
        let tool = RenderAppUITool::new();
        let r = tool.execute(json!({"ui": {"type": "VStack"}, "title": "My Form"}), &make_ctx()).await.unwrap();
        let d = r.details.unwrap();
        assert_eq!(d["title"], "My Form");
        let canvas_id = d["canvasId"].as_str().unwrap();
        assert!(canvas_id.starts_with("my-form-"));
    }

    #[tokio::test]
    async fn missing_ui_error() {
        let tool = RenderAppUITool::new();
        let r = tool.execute(json!({}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn state_forwarded() {
        let tool = RenderAppUITool::new();
        let r = tool.execute(json!({"ui": {"type": "VStack"}, "state": {"count": 0}}), &make_ctx()).await.unwrap();
        let d = r.details.unwrap();
        assert_eq!(d["state"]["count"], 0);
    }

    #[tokio::test]
    async fn component_count_in_details() {
        let tool = RenderAppUITool::new();
        let r = tool.execute(json!({
            "ui": {"type": "VStack", "children": [
                {"type": "Button"},
                {"type": "TextField"}
            ]}
        }), &make_ctx()).await.unwrap();
        let d = r.details.unwrap();
        assert_eq!(d["componentCount"], 3); // VStack + 2 children
    }
}
