//! `ReadHealth` tool — read-only `HealthKit` data via iOS.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};
use crate::core::tools::{Tool, ToolCategory, ToolResultBody, TronToolResult};

use crate::tools::errors::ToolError;
use crate::tools::traits::{DeviceDelegate, ToolContext, TronTool};
use crate::tools::utils::schema::ToolSchemaBuilder;
use crate::tools::utils::validation::validate_required_string;

/// Read-only `HealthKit` data access via iOS.
pub struct ReadHealthTool {
    delegate: Arc<dyn DeviceDelegate>,
}

impl ReadHealthTool {
    /// Create a new health data tool with the given device delegate.
    pub fn new(delegate: Arc<dyn DeviceDelegate>) -> Self {
        Self { delegate }
    }
}

#[async_trait]
impl TronTool for ReadHealthTool {
    fn name(&self) -> &str {
        "ReadHealth"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Custom
    }

    fn is_interactive(&self) -> bool {
        true
    }

    fn definition(&self) -> Tool {
        ToolSchemaBuilder::new(
            "ReadHealth",
            "Read health and fitness data from the user's iOS device (HealthKit).\n\n\
             Actions: today (daily summary), query (specific data type for date range), \
             workouts (recent workout sessions).\n\n\
             Read-only — never writes to HealthKit. Requires health permission on the device.",
        )
        .required_property(
            "action",
            json!({
                "type": "string",
                "enum": ["today", "query", "workouts"],
                "description": "Health data action"
            }),
        )
        .property(
            "dataType",
            json!({
                "type": "string",
                "enum": ["steps", "distance", "flights", "energy", "sleep", "heartRate", "restingHeartRate"],
                "description": "Data type for 'query' action"
            }),
        )
        .property(
            "dateRange",
            json!({
                "type": "object",
                "properties": {
                    "from": {"type": "string", "description": "Start date (ISO 8601)"},
                    "to": {"type": "string", "description": "End date (ISO 8601)"}
                },
                "description": "Date range for 'query'/'workouts' (defaults to last 7 days)"
            }),
        )
        .property("limit", json!({"type": "number", "description": "Max results for 'workouts'"}))
        .build()
    }

    async fn execute(&self, params: Value, ctx: &ToolContext) -> Result<TronToolResult, ToolError> {
        let action = match validate_required_string(&params, "action", "health action") {
            Ok(a) => a,
            Err(e) => return Ok(e),
        };

        let method = format!("health.{action}");
        let result = self
            .delegate
            .device_request(&ctx.session_id, &method, params.clone())
            .await?;

        // Include data in content so the LLM can see it (details is metadata-only)
        let content = serde_json::to_string_pretty(&result).unwrap_or_default();

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![crate::core::content::ToolResultContent::text(
                &content,
            )]),
            details: Some(json!({
                "action": action,
            })),
            is_error: None,
            stop_turn: None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tools::testutil::{extract_text, make_ctx};

    struct MockDeviceDelegate {
        last_session_id: std::sync::Mutex<Option<String>>,
        response: Value,
    }

    #[async_trait]
    impl DeviceDelegate for MockDeviceDelegate {
        async fn device_request(
            &self,
            session_id: &str,
            _method: &str,
            _params: Value,
        ) -> Result<Value, ToolError> {
            *self.last_session_id.lock().unwrap() = Some(session_id.to_string());
            Ok(self.response.clone())
        }
    }

    #[tokio::test]
    async fn today_summary() {
        let delegate = Arc::new(MockDeviceDelegate {
            last_session_id: std::sync::Mutex::new(None),
            response: json!({"steps": 8500, "distance": 6.2}),
        });
        let tool = ReadHealthTool::new(delegate.clone());
        let r = tool
            .execute(json!({"action": "today"}), &make_ctx())
            .await
            .unwrap();
        let text = extract_text(&r);
        assert!(text.contains("8500"), "should contain steps data: {text}");
        assert!(text.contains("6.2"), "should contain distance data: {text}");
        assert_eq!(
            *delegate.last_session_id.lock().unwrap(),
            Some("sess-1".into())
        );
    }

    #[tokio::test]
    async fn query_steps() {
        let delegate = Arc::new(MockDeviceDelegate {
            last_session_id: std::sync::Mutex::new(None),
            response: json!({"value": 10000, "unit": "count"}),
        });
        let tool = ReadHealthTool::new(delegate);
        let r = tool
            .execute(json!({"action": "query", "dataType": "steps"}), &make_ctx())
            .await
            .unwrap();
        let text = extract_text(&r);
        assert!(text.contains("10000"), "should contain value: {text}");
    }

    #[tokio::test]
    async fn workouts() {
        let delegate = Arc::new(MockDeviceDelegate {
            last_session_id: std::sync::Mutex::new(None),
            response: json!([
                {"type": "running", "duration": 1800, "distance": 5.0}
            ]),
        });
        let tool = ReadHealthTool::new(delegate);
        let r = tool
            .execute(json!({"action": "workouts"}), &make_ctx())
            .await
            .unwrap();
        let text = extract_text(&r);
        assert!(
            text.contains("running"),
            "should contain workout data: {text}"
        );
    }

    #[tokio::test]
    async fn missing_action_error() {
        let delegate = Arc::new(MockDeviceDelegate {
            last_session_id: std::sync::Mutex::new(None),
            response: json!(null),
        });
        let tool = ReadHealthTool::new(delegate);
        let r = tool.execute(json!({}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn tool_metadata() {
        let delegate = Arc::new(MockDeviceDelegate {
            last_session_id: std::sync::Mutex::new(None),
            response: json!(null),
        });
        let tool = ReadHealthTool::new(delegate);
        assert_eq!(tool.name(), "ReadHealth");
        assert!(tool.is_interactive());
    }
}
