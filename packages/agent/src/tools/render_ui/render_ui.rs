//! `RenderUI` tool — renders interactive UI from a component spec.
//!
//! Accepts a UI spec (flat format: `{ root, elements }`) and pushes it to the
//! render backend. The user sees the rendered UI in real-time via an
//! interactive WKWebView in the iOS app.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};

use crate::core::content::ToolResultContent;
use crate::core::tools::{Tool, ToolCategory, ToolResultBody, TronToolResult, error_result};
use crate::tools::errors::ToolError;
use crate::tools::traits::{ToolContext, TronTool};
use crate::tools::utils::schema::ToolSchemaBuilder;
use crate::tools::utils::validation::get_optional_string;
use super::provider::RenderUIProvider;

/// The `RenderUI` tool renders interactive UI via a pluggable render backend.
pub struct RenderUITool {
    provider: Arc<dyn RenderUIProvider>,
}

impl RenderUITool {
    /// Create a new `RenderUI` tool with the given provider.
    pub fn new(provider: Arc<dyn RenderUIProvider>) -> Self {
        Self { provider }
    }
}

#[async_trait]
impl TronTool for RenderUITool {
    fn name(&self) -> &str {
        "RenderUI"
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
        ToolSchemaBuilder::new(
            "RenderUI",
            "Render an interactive UI for the user.\n\n\
            Use this tool to create rich, interactive interfaces using web components.\n\
            The UI renders in a live preview that updates in real-time.\n\n\
            ## Spec Format\n\
            The spec uses a flat format with a `root` element ID and an `elements` map:\n\
            ```json\n\
            {\n\
              \"root\": \"main\",\n\
              \"elements\": {\n\
                \"main\": { \"type\": \"Card\", \"props\": { \"title\": \"Hello\" }, \"children\": [\"btn1\"] },\n\
                \"btn1\": { \"type\": \"Button\", \"props\": { \"label\": \"Click me\" } }\n\
              }\n\
            }\n\
            ```\n\n\
            ## Available Components\n\
            Card, Button, Input, Table, Badge, Alert, Dialog, Tabs, Accordion, Avatar,\n\
            Calendar, Checkbox, Collapsible, DataTable, DatePicker, DropdownMenu,\n\
            Form, HoverCard, Label, Menubar, NavigationMenu, Popover, Progress,\n\
            RadioGroup, ScrollArea, Select, Separator, Sheet, Skeleton, Slider,\n\
            Switch, Textarea, Toast, Toggle, Tooltip, Typography\n\n\
            ## Tips\n\
            - The renderer starts automatically — no manual setup needed\n\
            - To update an existing UI, call RenderUI again with the same canvasId\n\
            - The user sees the UI in real-time in the in-app browser\n\n\
            IMPORTANT: After calling this tool, do NOT output additional text.",
        )
        .required_property(
            "spec",
            json!({
                "type": "object",
                "description": "UI spec with `root` (string) and `elements` (object) keys"
            }),
        )
        .property(
            "canvasId",
            json!({"type": "string", "description": "Canvas ID for updates (auto-generated if omitted)"}),
        )
        .property(
            "title",
            json!({"type": "string", "description": "Title shown in the preview sheet toolbar"}),
        )
        .build()
    }

    async fn execute(
        &self,
        params: Value,
        _ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        // Validate spec
        let spec = match params.get("spec") {
            Some(s) if s.is_object() => s,
            _ => {
                return Ok(error_result(
                    "Missing required parameter: spec (must be an object)",
                ));
            }
        };

        // Validate spec has required keys
        if spec.get("root").and_then(Value::as_str).is_none() {
            return Ok(error_result(
                "Invalid spec: missing 'root' key (must be a string identifying the root element)",
            ));
        }
        if spec.get("elements").and_then(Value::as_object).is_none() {
            return Ok(error_result(
                "Invalid spec: missing 'elements' key (must be an object mapping element IDs to definitions)",
            ));
        }

        let title = get_optional_string(&params, "title");
        let canvas_id = get_optional_string(&params, "canvasId")
            .unwrap_or_else(|| generate_canvas_id(title.as_deref()));

        // Ensure server is running
        let _server_info = self.provider.ensure_running().await.map_err(|e| {
            ToolError::Internal {
                message: format!("Failed to start render backend: {e}"),
            }
        })?;

        // Push spec to server
        let result = self
            .provider
            .push_spec(&canvas_id, spec, title.as_deref())
            .await?;

        let summary = format!(
            "Rendered UI (canvas: {}): {} elements at {}",
            result.canvas_id, result.element_count, result.url
        );

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![ToolResultContent::text(summary)]),
            details: Some(json!({
                "canvasId": result.canvas_id,
                "url": result.url,
                "title": title,
                "elementCount": result.element_count,
            })),
            is_error: None,
            stop_turn: Some(true),
        })
    }
}

fn generate_canvas_id(title: Option<&str>) -> String {
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
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    #[allow(clippy::cast_possible_truncation)]
    let suffix = format!("{:08x}", now as u32);
    format!("{prefix}-{suffix}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tools::testutil::make_ctx;
    use crate::tools::render_ui::types::{RenderResult, RenderBackendInfo, RenderBackendStatus};

    /// Mock provider for testing.
    struct MockProvider {
        should_fail_ensure: bool,
        should_fail_push: bool,
    }

    impl MockProvider {
        fn ok() -> Arc<Self> {
            Arc::new(Self {
                should_fail_ensure: false,
                should_fail_push: false,
            })
        }

        fn fail_ensure() -> Arc<Self> {
            Arc::new(Self {
                should_fail_ensure: true,
                should_fail_push: false,
            })
        }

        fn fail_push() -> Arc<Self> {
            Arc::new(Self {
                should_fail_ensure: false,
                should_fail_push: true,
            })
        }
    }

    #[async_trait]
    impl RenderUIProvider for MockProvider {
        fn name(&self) -> &str { "mock" }

        async fn push_spec(
            &self,
            canvas_id: &str,
            spec: &Value,
            _title: Option<&str>,
        ) -> Result<RenderResult, ToolError> {
            if self.should_fail_push {
                return Err(ToolError::Internal {
                    message: "push failed".into(),
                });
            }
            let element_count = spec
                .get("elements")
                .and_then(Value::as_object)
                .map_or(0, |m| m.len());
            Ok(RenderResult {
                canvas_id: canvas_id.to_string(),
                url: format!("http://localhost:9250/canvas/{canvas_id}"),
                element_count,
            })
        }

        async fn push_chunk(&self, _: &str, _: &str) -> Result<(), ToolError> { Ok(()) }
        async fn complete_render(&self, canvas_id: &str) -> Result<RenderResult, ToolError> {
            Ok(RenderResult {
                canvas_id: canvas_id.to_string(),
                url: format!("http://localhost:9250/canvas/{canvas_id}"),
                element_count: 0,
            })
        }
        fn canvas_url(&self, canvas_id: &str) -> Option<String> {
            Some(format!("http://localhost:9250/canvas/{canvas_id}"))
        }
        fn get_status(&self) -> RenderBackendStatus {
            RenderBackendStatus::Running { base_url: "http://localhost:9250".into() }
        }
        async fn ensure_running(&self) -> Result<RenderBackendInfo, ToolError> {
            if self.should_fail_ensure {
                return Err(ToolError::Internal {
                    message: "backend failed to start".into(),
                });
            }
            Ok(RenderBackendInfo {
                base_url: "http://localhost:9250".into(),
                backend_id: "mock".into(),
            })
        }
        async fn shutdown(&self) {}
    }

    #[tokio::test]
    async fn valid_spec_returns_stop_turn() {
        let tool = RenderUITool::new(MockProvider::ok());
        let r = tool
            .execute(
                json!({
                    "spec": {
                        "root": "main",
                        "elements": {
                            "main": { "type": "Card", "props": { "title": "Hello" } }
                        }
                    }
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(r.stop_turn, Some(true));
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn canvas_id_in_details() {
        let tool = RenderUITool::new(MockProvider::ok());
        let r = tool
            .execute(
                json!({
                    "spec": { "root": "main", "elements": { "main": { "type": "Card" } } }
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        let d = r.details.unwrap();
        assert!(d["canvasId"].is_string());
        assert!(d["url"].is_string());
    }

    #[tokio::test]
    async fn canvas_id_auto_generated() {
        let tool = RenderUITool::new(MockProvider::ok());
        let r = tool
            .execute(
                json!({
                    "spec": { "root": "main", "elements": { "main": { "type": "Card" } } }
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        let d = r.details.unwrap();
        let canvas_id = d["canvasId"].as_str().unwrap();
        assert!(canvas_id.starts_with("canvas-"));
    }

    #[tokio::test]
    async fn canvas_id_preserved_when_provided() {
        let tool = RenderUITool::new(MockProvider::ok());
        let r = tool
            .execute(
                json!({
                    "spec": { "root": "main", "elements": { "main": { "type": "Card" } } },
                    "canvasId": "my-canvas"
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(r.details.unwrap()["canvasId"], "my-canvas");
    }

    #[tokio::test]
    async fn canvas_id_from_title() {
        let tool = RenderUITool::new(MockProvider::ok());
        let r = tool
            .execute(
                json!({
                    "spec": { "root": "main", "elements": { "main": { "type": "Card" } } },
                    "title": "My Dashboard"
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        let d = r.details.unwrap();
        let canvas_id = d["canvasId"].as_str().unwrap();
        assert!(canvas_id.starts_with("my-dashboard-"));
    }

    #[tokio::test]
    async fn missing_spec_error() {
        let tool = RenderUITool::new(MockProvider::ok());
        let r = tool.execute(json!({}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn spec_not_object_error() {
        let tool = RenderUITool::new(MockProvider::ok());
        let r = tool
            .execute(json!({"spec": "not-an-object"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn spec_missing_root_error() {
        let tool = RenderUITool::new(MockProvider::ok());
        let r = tool
            .execute(
                json!({"spec": {"elements": {"main": {"type": "Card"}}}}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn spec_missing_elements_error() {
        let tool = RenderUITool::new(MockProvider::ok());
        let r = tool
            .execute(json!({"spec": {"root": "main"}}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn element_count_in_details() {
        let tool = RenderUITool::new(MockProvider::ok());
        let r = tool
            .execute(
                json!({
                    "spec": {
                        "root": "main",
                        "elements": {
                            "main": { "type": "Card", "children": ["btn1"] },
                            "btn1": { "type": "Button" }
                        }
                    }
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(r.details.unwrap()["elementCount"], 2);
    }

    #[tokio::test]
    async fn ensure_running_failure_propagates() {
        let tool = RenderUITool::new(MockProvider::fail_ensure());
        let result = tool
            .execute(
                json!({
                    "spec": { "root": "main", "elements": { "main": { "type": "Card" } } }
                }),
                &make_ctx(),
            )
            .await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn push_spec_failure_propagates() {
        let tool = RenderUITool::new(MockProvider::fail_push());
        let result = tool
            .execute(
                json!({
                    "spec": { "root": "main", "elements": { "main": { "type": "Card" } } }
                }),
                &make_ctx(),
            )
            .await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn is_interactive_returns_true() {
        let tool = RenderUITool::new(MockProvider::ok());
        assert!(tool.is_interactive());
    }

    #[tokio::test]
    async fn stops_turn_returns_true() {
        let tool = RenderUITool::new(MockProvider::ok());
        assert!(tool.stops_turn());
    }

    #[tokio::test]
    async fn url_in_details() {
        let tool = RenderUITool::new(MockProvider::ok());
        let r = tool
            .execute(
                json!({
                    "spec": { "root": "main", "elements": { "main": { "type": "Card" } } },
                    "canvasId": "test-canvas"
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        let d = r.details.unwrap();
        assert_eq!(d["url"], "http://localhost:9250/canvas/test-canvas");
    }

    #[test]
    fn generate_canvas_id_without_title() {
        let id = generate_canvas_id(None);
        assert!(id.starts_with("canvas-"));
        assert!(id.len() > 10);
    }

    #[test]
    fn generate_canvas_id_with_title() {
        let id = generate_canvas_id(Some("My Cool Dashboard"));
        assert!(id.starts_with("my-cool-dashboard-"));
    }

    #[test]
    fn generate_canvas_id_truncates_long_titles() {
        let id = generate_canvas_id(Some("One Two Three Four Five"));
        assert!(id.starts_with("one-two-three-"));
    }
}
